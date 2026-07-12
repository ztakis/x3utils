@echo off
setlocal

:: Load configuration settings
if not exist "%~dp0config.cmd" (
    echo [%CL_R%FAIL%CL_NC%] Missing config.cmd
    goto :fail_exit
)

call "%~dp0config.cmd"
if errorlevel 1 goto :fail_exit

:: Prompt user for confirmation before proceeding with flash operation
:prompt_loop
set "user_choice="
set /p "user_choice=Do you want to flash SHU compatible? [Y/N]: "

if /i "%user_choice%"=="y" goto :do_flash
if /i "%user_choice%"=="yes" goto :do_flash
if /i "%user_choice%"=="n" goto :cancel_flash
if /i "%user_choice%"=="no" goto :cancel_flash

:: Invalid input, prompt again
echo.
echo Invalid entry. Please type Y for Yes or N for No.
echo.
goto :prompt_loop

:cancel_flash
echo.
echo Flash cancelled by user.
goto :end

:do_flash

:: Mode D: SHU-compat power-race - two catches (read current FW, then flash patched).
if /i "%RACE%"=="true" goto :race_compat

:: Set up 'compatible' directory for dumps
set "compat_dir=%~dp0compat"
if not exist "%compat_dir%" (
    mkdir "%compat_dir%"
    if errorlevel 1 (
        echo.
        echo [%CL_R%FAIL%CL_NC%] Failed to create compat directory.
        goto :fail_exit
    )
)

:: Cross-regional timestamp generation
for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyy-MM-dd_HH-mm-ss"') do (
    set "timestamp=%%i"
)

if "%timestamp%"=="" (
    echo.
    echo [%CL_R%FAIL%CL_NC%] Failed to generate timestamp.
    goto :fail_exit
)

:: Build final paths for raw and patched dumps
set "raw_dump=%compat_dir%\dump_%timestamp%.bin"
set "patched_dump=%compat_dir%\dump_%timestamp%_patched.bin"

:: OpenOCD prefers forward slashes
set "norm_raw_dump=%raw_dump:\=/%"
set "norm_patched_dump=%patched_dump:\=/%"

echo.
echo %D%
echo               Step 1: Dumping Current Memory
echo %D%
echo.
echo Output File:
echo        "%raw_dump%"
echo.

:: IMPORTANT:
:: No unlock operation during dump phase.
:: If the target is read-protected, dumping should fail
:: safely without erasing firmware contents.

:cdump_attempt
if "%TARGET%"=="target\at32f415xx_c45.cfg" (
    "%OPENOCD_BIN%" -s "%SCRIPTS_DIR%" -d0 ^
        -f "%TARGET%" ^
        -c "guided_connect {%CONNECT_TIMEOUT%}" ^
        -c "dump_image {%norm_raw_dump%} 0x08000000 0x20000" ^
        -c "exit"
) else (
    "%OPENOCD_BIN%" -s "%SCRIPTS_DIR%" -d0 ^
        -f "%INTERFACE%" ^
        -f "%TARGET%" ^
        -c "init" ^
        -c "reset halt" ^
        -c "flash probe 0" ^
        -c "dump_image {%norm_raw_dump%} 0x08000000 0x20000" ^
        -c "exit"
)

:: On success continue; on ANY failure offer a re-seat retry (read-only, always safe).
if not errorlevel 1 goto :cdump_ok
echo.
echo [%CL_Y%WARN%CL_NC%] OpenOCD could not read the chip - nothing was changed.
echo        Most often this is lost SWD / nRST-C45 contact mid-connect. Re-seat the
echo        probe and the contact (touch the contact point, NOT on top of the cap),
echo        keep it steady. (A read-protected chip will keep failing - then press Q.)
echo.
set "retry_choice="
set /p "retry_choice=%CL_C%Press ENTER to retry, or type Q to quit: %CL_NC%"
if /i "%retry_choice%"=="q" goto :fail_exit
echo.
goto :cdump_attempt

:cdump_ok

:: Validate bin file
call "%~dp0validate_bin.cmd" "%raw_dump%"
if not "%VALIDATE_RESULT%"=="OK" (
    echo [%CL_R%FAIL%CL_NC%] %VALIDATE_MSG%
    goto :fail_exit
)

echo [ %CL_G%OK%CL_NC% ] Raw dump verified successfully.
echo.

:: Create secondary AppData backup location
set "appdata_backup=%LOCALAPPDATA%\x3utils_backup"

if not exist "%appdata_backup%" (
    mkdir "%appdata_backup%"
)

:: Copy verified dump to AppData
copy /Y "%raw_dump%" "%appdata_backup%\dump_%timestamp%.bin" >nul

if errorlevel 1 (
    echo.
    echo [%CL_R%WARN%CL_NC%] Failed to create AppData backup copy.
) else (
    echo [ %CL_G%OK%CL_NC% ] Secondary backup stored in:
    echo        "%appdata_backup%\dump_%timestamp%.bin"
)
echo.
pause

echo.
echo %D%
echo               Step 2: Injecting Patch Sequence
echo %D%
echo.

powershell -NoProfile -Command ^
"$b = [System.IO.File]::ReadAllBytes($env:raw_dump); ^
$h = 'FE801CB2D1EF41A6A41731F5A06824F0'; ^
$hx = New-Object byte[] ($h.Length / 2); ^
for ($i = 0; $i -lt $hx.Length; $i++) { ^
    $hx[$i] = [Convert]::ToByte($h.Substring($i * 2, 2), 16) ^
} ^
[Array]::Copy($hx, 0, $b, 0x1420, $hx.Length); ^
for ($i = 0; $i -lt $hx.Length; $i++) { ^
    if ($b[0x1420 + $i] -ne $hx[$i]) { ^
        exit 1 ^
    } ^
} ^
[System.IO.File]::WriteAllBytes($env:patched_dump, $b); ^
exit 0"

if errorlevel 1 (
    echo.
    echo [%CL_R%FAIL%CL_NC%] Binary patch process failed.
    goto :fail_exit
)

:: Validate patched bin file
call "%~dp0validate_bin.cmd" "%patched_dump%"
if not "%VALIDATE_RESULT%"=="OK" (
    echo [%CL_R%FAIL%CL_NC%] %VALIDATE_MSG%
    goto :fail_exit
)

echo [ %CL_G%OK%CL_NC% ] Patch injection completed successfully.
echo.
pause

echo.
echo %D%
echo              Step 3: Flashing Modified Firmware
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
        -c "do_flash_and_verify {%norm_patched_dump%}" ^
        -c "exit"
) else (
    "%OPENOCD_BIN%" -s "%SCRIPTS_DIR%" -d0 ^
        -f "%INTERFACE%" ^
        -f "%TARGET%" ^
        -c "init" ^
        -c "reset halt" ^
        -c "flash erase_address 0x08000000 0x20000" ^
        -c "flash write_bank 0 {%norm_patched_dump%}" ^
        -c "verify_image {%norm_patched_dump%} 0x08000000" ^
        -c "exit"
)

:: On success continue; on ANY failure offer a re-seat retry (safe to repeat:
:: guided_flash_connect halts and erase precedes write, so no half-write hazard).
:: This retries the FLASH only - the dump/patch above are not re-run.
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
echo [ %CL_G%OK%CL_NC% ] Flashing completed successfully!
echo.
goto :end

:: =========================================================================
:: Mode D - SHU-compat power-race. Three stages, TWO catches (the patch is
:: host-side). Stage 1 races a dump of the chip's own FW; stage 2 patches it
:: (0x1420 signature); stage 3 races a flash of the patched image.
:: =========================================================================
:race_compat
set "compat_dir=%~dp0compat"
if not exist "%compat_dir%" mkdir "%compat_dir%"
for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyy-MM-dd_HH-mm-ss"') do set "timestamp=%%i"
set "raw_dump=%compat_dir%\dump_%timestamp%.bin"
set "patched_dump=%compat_dir%\dump_%timestamp%_patched.bin"
set "norm_raw_dump=%raw_dump:\=/%"
set "norm_patched_dump=%patched_dump:\=/%"
echo.
echo %D%
echo    %CL_M%SHU-compat power-race (mode D) - 2 catches: dump, then flash%CL_NC%
echo %D%
echo    You'll catch the window TWICE: once to read the current firmware, once
echo    to flash the patched version. %CL_C%Ctrl+C to stop.%CL_NC%
echo    Live: .=searching  %CL_Y%N%CL_NC%=noisy, hold steadier  %CL_G%H%CL_NC%=almost  %CL_R%x%CL_NC%=probe/USB gone
echo.
:: Graded live symbols via the shared race_grade.cmd; RACE_DEBUG appends each
:: attempt's verbose output to race_dbg_log. Both catches (dump + flash) capture
:: to race_last and classify the same way. Set up once for both.
set "race_dbg_log=%TEMP%\x3utils_race_debug.log"
set "race_last=%TEMP%\x3utils_race_last.log"
if /i "%RACE_DEBUG%"=="true" (
    if exist "%race_dbg_log%" del "%race_dbg_log%"
    set "race_v=-d2"
) else (
    set "race_v=-d0"
)
echo %D%
echo    Stage 1/3: catch + dump current firmware. %CL_C%Apply POWER now...%CL_NC%
echo %D%
set /a race_tries=0
:rc_dump_loop
set /a race_tries+=1
"%OPENOCD_BIN%" %race_v% -s "%SCRIPTS_DIR%" -f "target\at32f415xx_race.cfg" ^
    -c "race_connect" ^
    -c "dump_image {%norm_raw_dump%} 0x08000000 0x20000" ^
    -c "exit" > "%race_last%" 2>&1
if not errorlevel 1 goto :rc_dumped
if /i "%RACE_DEBUG%"=="true" ( >>"%race_dbg_log%" echo(=== dump attempt %race_tries% === & type "%race_last%" >>"%race_dbg_log%" )
call "%~dp0race_grade.cmd"
goto :rc_dump_loop
:rc_dumped
echo.
echo.
echo [ %CL_G%CAUGHT%CL_NC% ] Firmware dumped on attempt %race_tries%.
call "%~dp0validate_bin.cmd" "%raw_dump%"
if not "%VALIDATE_RESULT%"=="OK" (
    echo [%CL_R%FAIL%CL_NC%] %VALIDATE_MSG%
    echo        Cannot patch what we cannot read ^(read-protected?^). Aborting.
    goto :fail_exit
)
echo [ %CL_G%OK%CL_NC% ] Current firmware read + verified: "%raw_dump%"

echo.
echo %D%
echo    Stage 2/3: injecting SHU patch (no hardware)
echo %D%
powershell -NoProfile -Command ^
"$b = [System.IO.File]::ReadAllBytes($env:raw_dump); ^
$h = 'FE801CB2D1EF41A6A41731F5A06824F0'; ^
$hx = New-Object byte[] ($h.Length / 2); ^
for ($i = 0; $i -lt $hx.Length; $i++) { ^
    $hx[$i] = [Convert]::ToByte($h.Substring($i * 2, 2), 16) ^
} ^
[Array]::Copy($hx, 0, $b, 0x1420, $hx.Length); ^
for ($i = 0; $i -lt $hx.Length; $i++) { ^
    if ($b[0x1420 + $i] -ne $hx[$i]) { ^
        exit 1 ^
    } ^
} ^
[System.IO.File]::WriteAllBytes($env:patched_dump, $b); ^
exit 0"
if errorlevel 1 (
    echo [%CL_R%FAIL%CL_NC%] Binary patch process failed.
    goto :fail_exit
)
call "%~dp0validate_bin.cmd" "%patched_dump%"
if not "%VALIDATE_RESULT%"=="OK" (
    echo [%CL_R%FAIL%CL_NC%] %VALIDATE_MSG%
    goto :fail_exit
)
echo [ %CL_G%OK%CL_NC% ] Patched image ready: "%patched_dump%"

echo.
echo %D%
echo    Stage 3/3: catch + flash patched firmware. %CL_C%Cut and re-apply POWER...%CL_NC%
echo %D%
set /a race_tries=0
:rc_flash_loop
set /a race_tries+=1
"%OPENOCD_BIN%" %race_v% -s "%SCRIPTS_DIR%" -f "target\at32f415xx_race.cfg" ^
    -c "race_connect" ^
    -c "flash erase_address 0x08000000 0x20000" ^
    -c "flash write_bank 0 {%norm_patched_dump%}" ^
    -c "verify_image {%norm_patched_dump%} 0x08000000" ^
    -c "exit" > "%race_last%" 2>&1
if not errorlevel 1 goto :rc_flashed
if /i "%RACE_DEBUG%"=="true" ( >>"%race_dbg_log%" echo(=== flash attempt %race_tries% === & type "%race_last%" >>"%race_dbg_log%" )
call "%~dp0race_grade.cmd"
goto :rc_flash_loop
:rc_flashed
echo.
echo.
echo [ %CL_G%CAUGHT%CL_NC% ] Patched firmware flashed + verified on attempt %race_tries%.
echo [ %CL_G%OK%CL_NC% ] SHU-compat complete. Original firmware backed up:
echo        "%raw_dump%"
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
