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
call "%~dp0..\validate_bin.cmd" "%bin_file_path%"
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
echo.

:: Mode D: power-race flash-only (respawn erase+write+verify, no backup). Skips
:: the single-connect A/B/C path below.
if /i "%RACE%"=="true" goto :race_flash_only

:: Run OpenOCD flash using relative configuration mappings.
:: Still no unlock operation. We assume the target is not read-protected.
::
:: Wrapped in a re-seat-and-retry loop: the #1 field failure is losing the
:: hand-held SWD / nRST-C45 contact mid-connect, not logic. guided_flash_connect
:: halts before flashing and do_flash_and_verify ERASES before it writes, so
:: re-running a failed attempt is idempotent - there is no half-write hazard.
:flash_attempt

if  "%TARGET%"=="target\at32f415xx_c45.cfg" (
    "%OPENOCD_BIN%" -s "%SCRIPTS_DIR%" -d0 ^
        -f "%TARGET%" ^
        -c "guided_flash_connect {%CONNECT_TIMEOUT%}" ^
        -c "do_flash_and_verify {%normalized_path%}" ^
        -c "exit"
) else (
    "%OPENOCD_BIN%" -s "%SCRIPTS_DIR%" -d0 ^
        -f "%INTERFACE%" ^
        -f "%TARGET%" ^
        -c "init" ^
        -c "reset halt" ^
        -c "flash erase_address 0x08000000 0x20000" ^
        -c "flash write_bank 0 {%normalized_path%}" ^
        -c "verify_image {%normalized_path%} 0x08000000" ^
        -c "exit"
)

:: On success continue; on ANY failure offer a re-seat retry (safe to repeat).
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
:: Mode D - power-race flash-only. Respawn fresh openocd launches until one
:: lands in a post-power-on window, then erase+write+verify. NO backup - this
:: is the escape-hatch flash step (take a backup with dump.bat first if you
:: want one). Erase precedes write, so a re-caught retry is safe. Graded live
:: symbols come from the shared race_grade.cmd (. N H x). This is the isolated
:: flash step - hammer it alone to chase the marginal-write algorithm stall.
:: -------------------------------------------------------------------------
:race_flash_only
echo.
echo %D%
echo    %CL_M%Power-race flash-only (mode D)%CL_NC%
echo    %CL_M%Erase + write + verify, no backup%CL_NC%
echo %D%
echo    Hammering connects.
echo    %CL_C%Apply POWER now%CL_NC%; cut and re-apply on a miss.
echo    When symbols pause, it CAUGHT.
echo    Hold power steady; do NOT replug.
echo    Erase/write/verify may be quiet for a few seconds.
echo    %CL_C%Ctrl+C to stop.%CL_NC%
echo    Live: .=searching  %CL_Y%N%CL_NC%=noisy, hold steadier
echo          %CL_G%H%CL_NC%=almost    %CL_R%x%CL_NC%=probe/USB gone
echo.
set "race_dbg_log=%TEMP%\x3utils_race_debug.log"
set "race_last=%TEMP%\x3utils_race_last.log"
if /i "%RACE_DEBUG%"=="true" (
    if exist "%race_dbg_log%" del "%race_dbg_log%"
    set "race_v=-d2"
) else (
    set "race_v=-d0"
)
set OOCD_RACE=-s "%SCRIPTS_DIR%" -f "target\at32f415xx_race.cfg" ^
 -c "race_connect" ^
 -c "flash erase_address 0x08000000 0x20000" ^
 -c "flash write_bank 0 {%normalized_path%}" ^
 -c "verify_image {%normalized_path%} 0x08000000" ^
 -c "exit"
set /a race_tries=0
:rfo_loop
set /a race_tries+=1
"%OPENOCD_BIN%" %race_v% %OOCD_RACE% > "%race_last%" 2>&1
if not errorlevel 1 goto :rfo_ok
if /i "%RACE_DEBUG%"=="true" ( >>"%race_dbg_log%" echo(=== flash attempt %race_tries% === & type "%race_last%" >>"%race_dbg_log%" )
call "%~dp0..\race_grade.cmd"
goto :rfo_loop

:rfo_ok
echo.
echo.
echo [ %CL_G%CAUGHT%CL_NC% ] Flashed on attempt %race_tries% - stages:
echo %D%
type "%race_last%" | findstr /i "halted erased wrote verified"
echo %D%
echo.
echo [ %CL_G%OK%CL_NC% ] Flashed and verified: %bin_file%
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
