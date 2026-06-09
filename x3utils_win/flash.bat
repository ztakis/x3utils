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

set "bin_file_path=%~1"

:: Detect double-click (No file passed as an argument)
if "%bin_file_path%"=="" (
    echo =======================================================
    echo  No file detected. Please Drag and Drop your .bin file 
    echo  directly into this window and press ENTER.
    echo =======================================================
    echo.
    set /p "bin_file_path=Drop file here: "
)

:: Strip any accidental outer quotes from the input
for %%A in ("%bin_file_path%") do (
    set "bin_file_path=%%~fA"
    set "extension=%%~xA"
)

:: Check if a file path is still empty
if "%bin_file_path%"=="" (
    echo [FAIL] No file provided.
    goto :fail_exit
)

if not exist "%bin_file_path%" (
    echo [FAIL] File does not exist.
    goto :fail_exit
)

:: Reject unsupported characters in user-supplied path
for %%C in ("{" "}") do (
    echo(%bin_file_path%| findstr /L /C:"%%~C" >nul
    if not errorlevel 1 (
        echo [FAIL] Path contains unsupported character: %%~C
        echo        Please rename.
        pause
        goto :fail_exit
    )
)

:: Reject non-ASCII characters in user-supplied path
for /f "delims=" %%R in ('powershell -NoProfile -Command ^
    "if ('%bin_file_path%' -match '[^\x00-\x7F]') { 'NON_ASCII' } else { 'OK' }"') do (
    set "ascii_result=%%R"
)

if "%ascii_result%"=="NON_ASCII" (
    echo [FAIL] Path contains non-ASCII characters.
    echo        Path: %bin_file_path%
    echo        Please rename using only English letters.
    goto :fail_exit
)
echo [ OK ] Path contains only ASCII characters.

:: Validate the extension
if /i not "%extension%"==".bin" (
    echo [FAIL] Invalid file type "%extension%", only .bin is allowed.
    goto :fail_exit
)
echo [ OK ] File extension is valid.

:: Get file size and name in a single loop
for %%i in ("%bin_file_path%") do (
    set "bin_file_size=%%~zi"
    set "bin_file=%%~nxi"
)

:: Validate the exact size (128 KB = 131072 bytes)
if not "%bin_file_size%"=="%EXPECTED_SIZE%" (
    echo [FAIL] Invalid file size.
    echo        Expected: %EXPECTED_SIZE% bytes
    echo        Got:      %bin_file_size% bytes
    goto :fail_exit
)
echo [ OK ] File size matches expected size: %EXPECTED_SIZE% bytes.

:: Normalize path for OpenOCD
set "normalized_path=%bin_file_path:\=/%"
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
    -c "flash erase_address 0x08000000 0x20000" ^
    -c "flash write_bank 0 {%normalized_path%}" ^
    -c "verify_image {%normalized_path%} 0x08000000" ^
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
