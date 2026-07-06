@echo off
setlocal

:: Load configuration settings
if not exist "%~dp0..\config.cmd" (
    echo [%CL_R%FAIL%CL_NC%] Missing config.cmd
    goto :fail_exit
)

call "%~dp0..\config.cmd"
if errorlevel 1 goto :fail_exit

set "bin_file_path=%~dp0gt3_vcu_v1.7.0.bin"

if not exist "%bin_file_path%" (
    echo [%CL_R%FAIL%CL_NC%] Binary file not found:
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
