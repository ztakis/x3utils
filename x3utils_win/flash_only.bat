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

set "bin_file_path=%~1"

:: Detect double-click (No file passed as an argument)
if "%bin_file_path%"=="" (
    echo =======================================================
    echo  %CL_Y%No file detected. Please Drag and Drop your .bin file 
    echo  directly into this window and press ENTER.%CL_NC%
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
    echo [%CL_R%FAIL%CL_NC%] No file provided.
    goto :fail_exit
)

if not exist "%bin_file_path%" (
    echo [%CL_R%FAIL%CL_NC%] File does not exist.
    goto :fail_exit
)

:: Reject unsupported characters in user-supplied path
for %%C in ("{" "}") do (
    echo(%bin_file_path%| findstr /L /C:"%%~C" >nul
    if not errorlevel 1 (
        echo [%CL_R%FAIL%CL_NC%] Path contains unsupported character: %%~C
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
    echo [%CL_R%FAIL%CL_NC%] Path contains non-ASCII characters.
    echo        Path: %bin_file_path%
    echo        Please rename using only English letters.
    goto :fail_exit
)

:: Validate the extension
if /i not "%extension%"==".bin" (
    echo [%CL_R%FAIL%CL_NC%] Invalid file type "%extension%", only .bin is allowed.
    goto :fail_exit
)

:: Get file size and name in a single loop
for %%i in ("%bin_file_path%") do (
    set "bin_file_size=%%~zi"
    set "bin_file=%%~nxi"
)

:: Validate the exact size (128 KB = 131072 bytes)
if not "%bin_file_size%"=="%EXPECTED_SIZE%" (
    echo [%CL_R%FAIL%CL_NC%] Invalid file size.
    echo        Expected: %EXPECTED_SIZE% bytes
    echo        Got:      %bin_file_size% bytes
    goto :fail_exit
)

:: Ensure bin file is not all zeros
for /f %%i in ('powershell -NoProfile -Command "$bytes = [System.IO.File]::ReadAllBytes('%bin_file_path%'); ($bytes | Select-Object -Unique).Count -eq 1"') do set "all_zeros=%%i"

if "%all_zeros%"=="True" (
    echo.
    echo [%CL_R%FAIL%CL_NC%] Bin file contains only zeros.
    echo        Please try again.
    goto :fail_exit
)

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

echo.
echo =======================================================
echo          Starting flash process via OpenOCD...
echo =======================================================
echo.

:: Run OpenOCD flash using relative configuration mappings
:: Still no unlock operation.
:: We assume the target is not read-protected.

if  "%TARGET%"=="target\at32f415_alt.cfg" (
    "%OPENOCD_BIN%" -s "%SCRIPTS_DIR%" -d0 ^
        -f "%TARGET%" ^
        -c "guided_flash_connect {%CONNECT_TIMEOUT%}" ^
        -c "flash erase_address 0x08000000 0x20000" ^
        -c "flash write_bank 0 {%normalized_path%}" ^
        -c "verify_image {%normalized_path%} 0x08000000" ^
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

:: Check if OpenOCD execution was successful
if errorlevel 1 (
    echo.
    echo [%CL_R%FAIL%CL_NC%] OpenOCD failed with error code %errorlevel%. Check hardware connections.
    goto :fail_exit
)

echo.
echo [ %CL_G%OK%CL_NC% ] Flashing completed and verified successfully!
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
