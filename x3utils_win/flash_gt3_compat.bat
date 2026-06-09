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

set "bin_file_path=%~dp0special\gt3_vcu_v1.7.0.bin"

if not exist "%bin_file_path%" (
    echo [FAIL] Binary file not found:
    echo        %bin_file_path%
    goto :fail_exit
)

for %%i in ("%bin_file_path%") do (
    set "bin_file=%%~nxi"
)

set "normalized_path=%bin_file_path:\=/%"

echo.
echo Binary file: %bin_file%
echo Location: %bin_file_path%
echo Flash address: 0x08001000
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

:: External call to dump.bat
echo.
echo =======================================================
echo       Step 1: Invoking External Backup Script...
echo =======================================================
echo.

if exist "%~dp0dump.bat" (
    call "%~dp0dump.bat"
) else (
    echo [FAIL] External component dump.bat was not found.
    goto :fail_exit
)

:: Catch any errorcodes or connection abort errors generated inside dump.bat
if errorlevel 1 (
    echo.
    echo [FAIL] Backup script reported an error! Aborting flash sequence for hardware safety.
    goto :fail_exit
)

echo.
echo =======================================================
echo      Step 2: Starting flash process via OpenOCD...
echo =======================================================

:: Run OpenOCD flash using relative configuration mappings
:: Still no unlock operation.
:: We assume the target is not read-protected.

"%OPENOCD_BIN%" -s "%SCRIPTS_DIR%" ^
    -f "%INTERFACE%" ^
    -f "%TARGET%" ^
    -c "init" ^
    -c "reset halt" ^
    -c "flash write_image erase {%normalized_path%} 0x08001000 bin" ^
    -c "verify_image {%normalized_path%} 0x08001000 bin" ^
    -c "reset run" ^
    -c "exit"

:: Check if OpenOCD execution was successful
if errorlevel 1 (
    echo.
    echo [FAIL] OpenOCD failed with error code %errorlevel%. Check hardware connections.
    goto :fail_exit
)

echo.
echo [ OK ] Flashing completed and verified successfully!
echo.
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
