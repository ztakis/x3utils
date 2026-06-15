@echo off
setlocal

:: Load configuration settings
if not exist "%~dp0config.cmd" (
    echo [FAIL] Missing config.cmd
    goto :fail_exit
)

call "%~dp0config.cmd"

:: Validate OpenOCD binary exists
if not exist "%OPENOCD_BIN%" (
    echo [FAIL] OpenOCD binary not found.
    echo        Expected: %OPENOCD_BIN%
    goto :fail_exit
)

:: Validate OpenOCD scripts directory exists
if not exist "%SCRIPTS_DIR%" (
    echo [FAIL] OpenOCD scripts directory not found.
    echo        Expected: %SCRIPTS_DIR%
    goto :fail_exit
)

echo.
echo =======================================================
echo         Press ENTER to dump current chip data
echo               to your backup folder.
echo =======================================================
echo.
pause

:: Set up backup directory for dumps
set "backup_dir=%~dp0backup"
if not exist "%backup_dir%" (
    mkdir "%backup_dir%"
    if errorlevel 1 (
        echo.
        echo [FAIL] Failed to create backup directory.
        goto :fail_exit
    )
)

echo.

:: Cross-regional timestamp generation
for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyy-MM-dd_HH-mm-ss"') do (
    set "timestamp=%%i"
)

if "%timestamp%"=="" (
    echo.
    echo [FAIL] Failed to generate timestamp.
    goto :fail_exit
)

:: Set final dump path
set "dump_file=%backup_dir%\dump_%timestamp%.bin"

:: OpenOCD prefers forward slashes
set "norm_dump_file=%dump_file:\=/%"

echo Output File:
echo        "%dump_file%"
echo.

echo =======================================================
echo         Executing Full 128 KB Memory Dump...
echo =======================================================
echo.

:: IMPORTANT:
:: No unlock operation during dump phase.
:: If the target is read-protected, dumping should fail
:: safely without erasing firmware contents.

"%OPENOCD_BIN%" -s "%SCRIPTS_DIR%" ^
    -f "%INTERFACE%" ^
    -f "%TARGET%" ^
    -c "init" ^
    -c "reset halt" ^
    -c "flash probe 0" ^
    -c "dump_image {%norm_dump_file%} 0x08000000 0x20000" ^
    -c "exit"

:: Validate OpenOCD exit state
if errorlevel 1 (
    echo.
    echo [FAIL] OpenOCD encountered an error reading the chip memory.
    echo        Check ST-Link wiring, power, and target state.
    goto :fail_exit
)

:: Ensure dump file actually exists
if not exist "%dump_file%" (
    echo.
    echo [FAIL] Dump file was not created on disk.
    goto :fail_exit
)

:: Verify dump size integrity
for %%i in ("%dump_file%") do (
    set "dump_size=%%~zi"
)

if not "%dump_size%"=="%EXPECTED_SIZE%" (
    echo.
    echo [FAIL] Memory dump integrity verification failed.
    echo        Expected: %EXPECTED_SIZE% bytes
    echo        Actual:   %dump_size% bytes
    goto :fail_exit
)

:: Ensure dump file is not all zeros (indicating a failed read)
for /f %%i in ('powershell -NoProfile -Command "$bytes = [System.IO.File]::ReadAllBytes('%dump_file%'); ($bytes | Select-Object -Unique).Count -eq 1"') do set "all_zeros=%%i"

if "%all_zeros%"=="True" (
    echo.
    echo [FAIL] Dump file contains only zeros.
    echo        Please try again.
    goto :fail_exit
)

echo.
echo [ OK ] Dump completed successfully!
echo [ OK ] Verified file size: %EXPECTED_SIZE% bytes.
echo [ OK ] Backup stored in:
echo        "%dump_file%"
goto :end


:fail_exit
echo.
echo [FAIL] Operation aborted.
echo.
pause
exit /b 1

:end
echo.
pause
exit /b 0
