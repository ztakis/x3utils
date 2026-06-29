@echo off
setlocal

:: Load configuration settings
if not exist "%~dp0config.cmd" (
    echo [%CL_R%FAIL%CL_NC%] Missing config.cmd
    goto :fail_exit
)

call "%~dp0config.cmd"
if errorlevel 1 goto :fail_exit

echo.
echo ============================================================
echo            Press ENTER to dump current chip data
echo                   to your backup folder.
echo ============================================================
echo.
pause

:: Set up backup directory for dumps
set "backup_dir=%~dp0backup"
if not exist "%backup_dir%" (
    mkdir "%backup_dir%"
    if errorlevel 1 (
        echo.
        echo [%CL_R%FAIL%CL_NC%] Failed to create backup directory.
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
    echo [%CL_R%FAIL%CL_NC%] Failed to generate timestamp.
    goto :fail_exit
)

:: Set final dump path
set "dump_file=%backup_dir%\dump_%timestamp%.bin"

:: OpenOCD prefers forward slashes
set "norm_dump_file=%dump_file:\=/%"

echo Output File:
echo        "%dump_file%"
echo.

echo ============================================================
echo             Executing Full 128 KB Memory Dump...
echo ============================================================
echo.

:: IMPORTANT:
:: No unlock operation during dump phase.
:: If the target is read-protected, dumping should fail
:: safely without erasing firmware contents.

if "%TARGET%"=="target\at32f415xx_c45.cfg" (
    "%OPENOCD_BIN%" -s "%SCRIPTS_DIR%" -d0 ^
        -f "%TARGET%" ^
        -c "guided_connect {%CONNECT_TIMEOUT%}" ^
        -c "dump_image {%norm_dump_file%} 0x08000000 0x20000" ^
        -c "exit"
) else (
    "%OPENOCD_BIN%" -s "%SCRIPTS_DIR%" -d0 ^
        -f "%INTERFACE%" ^
        -f "%TARGET%" ^
        -c "init" ^
        -c "reset halt" ^
        -c "flash probe 0" ^
        -c "dump_image {%norm_dump_file%} 0x08000000 0x20000" ^
        -c "exit"
)

:: Validate OpenOCD exit state
if errorlevel 1 (
    echo.
    echo [%CL_R%FAIL%CL_NC%] OpenOCD encountered an error reading the chip memory.
    echo        Check ST-Link wiring, power, and target state.
    goto :fail_exit
)

:: Validate dumped bin file
call "%~dp0validate_bin.cmd" "%dump_file%"
if not "%VALIDATE_RESULT%"=="OK" (
    echo [%CL_R%FAIL%CL_NC%] %VALIDATE_MSG%
    goto :fail_exit
)

echo.
echo [ %CL_G%OK%CL_NC% ] Dump completed successfully!
echo [ %CL_G%OK%CL_NC% ] Verified file size: %EXPECTED_SIZE% bytes.
echo [ %CL_G%OK%CL_NC% ] Backup stored in:
echo        "%dump_file%"

:: Create secondary AppData backup location
set "appdata_backup=%LOCALAPPDATA%\x3utils_backup"

if not exist "%appdata_backup%" (
    mkdir "%appdata_backup%"
)

:: Copy verified dump to AppData
copy /Y "%dump_file%" "%appdata_backup%\dump_%timestamp%.bin" >nul

if errorlevel 1 (
    echo.
    echo [%CL_R%WARN%CL_NC%] Failed to create AppData backup copy.
) else (
    echo [ %CL_G%OK%CL_NC% ] Secondary backup stored in:
    echo        "%appdata_backup%\dump_%timestamp%.bin"
)
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
