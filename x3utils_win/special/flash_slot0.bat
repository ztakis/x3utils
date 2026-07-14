@echo off
setlocal

:: Load configuration settings
if not exist "%~dp0..\config.cmd" (
    echo [%CL_R%FAIL%CL_NC%] Missing config.cmd
    goto :fail_exit
)

call "%~dp0..\config.cmd"
if errorlevel 1 goto :fail_exit

set "bin_file_path=%~1"

:: Detect double-click (No file passed as an argument)
if "%bin_file_path%"=="" (
    echo %D%
    echo    %CL_Y%No file detected. Please Drag and Drop your .bin file 
    echo    directly into this window and press ENTER.%CL_NC%
    echo %D%
    echo.
    set /p "bin_file_path=Drop file here: "
)

:: Strip any accidental outer quotes from the input
for %%A in ("%bin_file_path%") do (
    set "bin_file_path=%%~fA"
    set "extension=%%~xA"
)

:: Validate bin file
call "%~dp0..\validate_bin.cmd" "%bin_file_path%" nosize
if not "%VALIDATE_RESULT%"=="OK" (
    echo [%CL_R%FAIL%CL_NC%] %VALIDATE_MSG%
    goto :fail_exit
)
set "bin_file=%BIN_FILE_NAME%"
set "normalized_path=%BIN_NORMALIZED_PATH%"
echo.

:: Prompt user confirmation before flashing
:prompt_loop
set "user_choice="
set /p "user_choice=Do you want to flash [%bin_file%]? [Y/N]: "
if /i "%user_choice%"=="y" goto :do_flash
if /i "%user_choice%"=="yes" goto :do_flash
if /i "%user_choice%"=="n" goto :cancel_flash
if /i "%user_choice%"=="no" goto :cancel_flash
echo.
echo Invalid entry. Please type Y for Yes or N for No.
echo.
goto :prompt_loop

:: Handle user cancellation
:cancel_flash
echo.
echo Flash cancelled by user.
goto :end


:do_flash

:: Mode D: power-race slot0 flash - backup (dump.bat) then inline race-flash of
:: slot0. Skips the single-connect A/B/C path below.
if /i "%RACE%"=="true" goto :race_slot0

:: External call to dump.bat
echo.
echo %D%
echo           Step 1: Invoking External Backup Script...
echo %D%
echo.

if exist "%~dp0..\dump.bat" (
    call "%~dp0..\dump.bat"
) else (
    echo [%CL_R%FAIL%CL_NC%] External component dump.bat was not found.
    goto :fail_exit
)

:: Catch any errorcodes or connection abort errors generated inside dump.bat
if errorlevel 1 (
    echo.
    echo [%CL_R%FAIL%CL_NC%] Backup script reported an error! Aborting flash sequence for hardware safety.
    goto :fail_exit
)

echo.
echo %D%
echo         Step 2: Starting flash process via OpenOCD...
echo %D%
echo.

:: Run OpenOCD flash using relative configuration mappings
:: Still no unlock operation.
:: We assume the target is not read-protected.

:flash_attempt
if  "%TARGET%"=="target\at32f415xx_c45.cfg" (
    "%OPENOCD_BIN%" -s "%SCRIPTS_DIR%" -d0 ^
        -f "%TARGET%" ^
        -c "guided_flash_connect {%CONNECT_TIMEOUT%}" ^
        -c "do_flash_and_verify_slot0 {%normalized_path%}" ^
        -c "exit"
) else (
    "%OPENOCD_BIN%" -s "%SCRIPTS_DIR%" -d0 ^
        -f "%INTERFACE%" ^
        -f "%TARGET%" ^
        -c "init" ^
        -c "reset halt" ^
        -c "flash write_image erase {%normalized_path%} 0x08001000 bin" ^
        -c "verify_image {%normalized_path%} 0x08001000 bin" ^
        -c "exit"
)

:: On success continue; on ANY failure offer a re-seat retry (safe to repeat:
:: guided_flash_connect halts and write_image erase re-erases, so no half-write hazard).
:: This retries the FLASH only - the successful backup above is not re-run.
if not errorlevel 1 goto :flash_ok
echo.
echo [%CL_Y%WARN%CL_NC%] OpenOCD failed - nothing was verified.
echo        Most often this is lost SWD / nRST-C45 contact mid-connect. Re-seat
echo        the probe and the contact (touch the contact point, NOT on top of the
echo        cap), keep it steady. Erase runs before write, so a retry is safe.
echo.
set "retry_choice="
set /p "retry_choice=%CL_C%Press ENTER to retry, or type Q to quit: %CL_NC%"
if /i "%retry_choice%"=="q" goto :fail_exit
echo.
goto :flash_attempt

:flash_ok
echo.
echo [ %CL_G%OK%CL_NC% ] Flashing completed and verified successfully!
echo.
goto :end

:: -------------------------------------------------------------------------
:: Mode D - power-race slot0 flash. Two visible stages, each its own catch:
::   Stage 1  call dump.bat  -> back up current firmware (its own race catch)
::   Stage 2  respawn flash   -> write_image erase slot0 @0x08001000 + verify,
::                              INLINE (same op as the A/B/C path above, via the
::                              race respawn connect + graded dots). Identity-safe:
::                              only slot0, never the bootloader/identity region.
:: Aborts if the backup reads zeros (locked chip) BY DESIGN. write_image erase
:: re-erases slot0, so a re-caught retry is safe.
:: -------------------------------------------------------------------------
:race_slot0
echo.
echo %D%
echo    %CL_M%Power-race slot0 flash (mode D)%CL_NC%
echo    %CL_M%Backup, then flash slot0 (2 catches)%CL_NC%
echo %D%
echo    Stage 1 backs up current firmware.
echo    Stage 2 flashes slot0:
echo        [%bin_file%]
echo.
echo %D%
echo    Stage 1/2: backup current firmware (dump.bat)
echo %D%
if not exist "%~dp0..\dump.bat" (
    echo [%CL_R%FAIL%CL_NC%] dump.bat not found - cannot back up. Aborting.
    goto :fail_exit
)
call "%~dp0..\dump.bat"
if errorlevel 1 (
    echo.
    echo [%CL_R%FAIL%CL_NC%] Backup ^(dump.bat^) failed - aborting flash for safety.
    goto :fail_exit
)

echo.
echo %D%
echo    Stage 2/2: flash slot0.
echo    Respawn until caught, then write+verify.
echo %D%
echo    Hammering connects.
echo    %CL_C%Apply POWER now%CL_NC%; cut and re-apply on a miss.
echo    When symbols pause, it CAUGHT.
echo    Hold power steady; do NOT replug.
echo    Write/verify may be quiet for a few seconds.
echo    %CL_C%Ctrl+C to stop.%CL_NC%
echo    Live: .=searching  %CL_Y%N%CL_NC%=noisy, hold steadier
echo          %CL_G%H%CL_NC%=almost    %CL_R%x%CL_NC%=probe/USB gone
echo.
set "race_dbg_log=%TEMP%\x3utils_race_debug.log"
set "race_last=%TEMP%\x3utils_race_last.log"
if /i "%RACE_DEBUG%"=="true" ( set "race_v=-d2" ) else ( set "race_v=-d0" )
set OOCD_RACE=-s "%SCRIPTS_DIR%" -f "target\at32f415xx_race.cfg" ^
 -c "race_connect" ^
 -c "flash write_image erase {%normalized_path%} 0x08001000 bin" ^
 -c "verify_image {%normalized_path%} 0x08001000 bin" ^
 -c "exit"
set /a race_tries=0
:race_slot0_loop
set /a race_tries+=1
"%OPENOCD_BIN%" %race_v% %OOCD_RACE% > "%race_last%" 2>&1
if not errorlevel 1 goto :race_slot0_ok
if /i "%RACE_DEBUG%"=="true" ( >>"%race_dbg_log%" echo(=== slot0 attempt %race_tries% === & type "%race_last%" >>"%race_dbg_log%" )
call "%~dp0..\race_grade.cmd"
goto :race_slot0_loop

:race_slot0_ok
echo.
echo.
echo [ %CL_G%CAUGHT%CL_NC% ] Slot0 flashed on attempt %race_tries% - stages:
echo %D%
type "%race_last%" | findstr /i "halted erase wrote verified"
echo %D%
echo.
echo [ %CL_G%OK%CL_NC% ] Slot0 flashed and verified: %bin_file%
echo        Backup was taken by dump.bat above.
goto :end

:fail_exit
echo.
echo [%CL_R%FAIL%CL_NC%] Operation aborted.
echo.
pause
exit /b 1

:end
echo.
pause
exit /b 0
