@echo off
setlocal

:: Load configuration settings
if not exist "%~dp0config.cmd" (
    echo [%CL_R%FAIL%CL_NC%] Missing config.cmd
    goto :fail_exit
)

call "%~dp0config.cmd"

:: Validate OpenOCD binary exists
if not exist "%OPENOCD_BIN%" (
    echo [%CL_R%FAIL%CL_NC%] OpenOCD binary not found.
    echo        Expected: %OPENOCD_BIN%
    goto :fail_exit
)

:: Validate OpenOCD scripts directory exists
if not exist "%SCRIPTS_DIR%" (
    echo [%CL_R%FAIL%CL_NC%] OpenOCD scripts directory not found.
    echo        Expected: %SCRIPTS_DIR%
    goto :fail_exit
)

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
echo ============================================================
echo              Step 1: Dumping Current Memory
echo ============================================================
echo.
echo Output File:
echo        "%raw_dump%"
echo.

:: IMPORTANT:
:: No unlock operation during dump phase.
:: If the target is read-protected, dumping should fail
:: safely without erasing firmware contents.

if "%TARGET%"=="target\at32f415_c45.cfg" (
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

if errorlevel 1 (
    echo.
    echo [%CL_R%FAIL%CL_NC%] OpenOCD failed during memory dump.
    echo Check:
    echo        Check ST-Link connection, board power,
    echo        and read protection state.
    goto :fail_exit
)

:: Ensure dump file actually exists
if not exist "%raw_dump%" (
    echo.
    echo [%CL_R%FAIL%CL_NC%] Raw dump file was not created.
    goto :fail_exit
)

:: Verify dump size integrity
for %%i in ("%raw_dump%") do (
    set "dump_size=%%~zi"
)

if not "%dump_size%"=="%EXPECTED_SIZE%" (
    echo.
    echo [%CL_R%FAIL%CL_NC%] Raw dump integrity verification failed.
    echo        Expected: %EXPECTED_SIZE% bytes
    echo        Actual:   %dump_size% bytes
    goto :fail_exit
)

:: Ensure dump file is not all zeros
for /f %%i in ('powershell -NoProfile -Command "$bytes = [System.IO.File]::ReadAllBytes('%raw_dump%'); ($bytes | Select-Object -Unique).Count -eq 1"') do set "all_zeros=%%i"

if "%all_zeros%"=="True" (
    echo.
    echo [%CL_R%FAIL%CL_NC%] Dump file contains only zeros.
    echo        nRST was not released correctly during step 2.
    echo        Please try again.
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
echo ============================================================
echo              Step 2: Injecting Patch Sequence
echo ============================================================
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

:: Ensure patched file actually exists
if not exist "%patched_dump%" (
    echo.
    echo [%CL_R%FAIL%CL_NC%] Patched dump file was not created.
    goto :fail_exit
)

:: Verify patched file size integrity
for %%i in ("%patched_dump%") do (
    set "patched_size=%%~zi"
)

if not "%patched_size%"=="%EXPECTED_SIZE%" (
    echo.
    echo [%CL_R%FAIL%CL_NC%] Patched binary integrity verification failed.
    echo        Expected: %EXPECTED_SIZE% bytes
    echo        Actual:   %patched_size% bytes
    goto :fail_exit
)

echo [ %CL_G%OK%CL_NC% ] Patch injection completed successfully.
echo.
pause

echo.
echo ============================================================
echo             Step 3: Flashing Modified Firmware
echo ============================================================
echo.

:: Run OpenOCD flash using relative configuration mappings
:: Still no unlock operation.
:: We assume the target is not read-protected.

if  "%TARGET%"=="target\at32f415_c45.cfg" (
    "%OPENOCD_BIN%" -s "%SCRIPTS_DIR%" -d0 ^
        -f "%TARGET%" ^
        -c "guided_flash_connect {%CONNECT_TIMEOUT%}" ^
        -c "flash erase_address 0x08000000 0x20000" ^
        -c "flash write_bank 0 {%norm_patched_dump%}" ^
        -c "verify_image {%norm_patched_dump%} 0x08000000" ^
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

if errorlevel 1 (
    echo.
    echo [%CL_R%FAIL%CL_NC%] OpenOCD failed during flashing.
    echo Check:
    echo        Check ST-Link connection, board power,
    echo        and flash protection state.
    goto :fail_exit
)

echo.
echo [ %CL_G%OK%CL_NC% ] Flashing completed successfully!
echo.
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
