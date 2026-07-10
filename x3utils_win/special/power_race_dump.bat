@echo off
setlocal enabledelayedexpansion

:: -----------------------------------------------------------------------------
:: power_race_dump.bat  -  RESPAWN power-race + full 128 KB dump in one shot.
::
:: Same respawn race as power_race_connect.bat, but the launch that catches the
:: post-power-on SWD window ALSO dumps the whole flash in that same session. Once
:: init+halt land, the core is frozen so SWD stays up and the read finishes at
:: leisure. READ-ONLY - no erase, write, or unlock.
::
:: Setup: 12V OFF, ST-Link on USB (3V3-to-board removed). Start this, then apply
:: 12V; if it misses, cut and re-apply 12V (each power-ON = a fresh window).
:: Ctrl+C to stop.
::
:: EXPERIMENTAL / bench tool. Uses special\at32f415xx_race.cfg. Not in the launcher.
:: -----------------------------------------------------------------------------

if not exist "%~dp0..\config.cmd" ( echo Missing config.cmd & goto :fail_exit )
call "%~dp0..\config.cmd"
if errorlevel 1 goto :fail_exit

set "RACE_CFG=%~dp0at32f415xx_race.cfg"
if not exist "%RACE_CFG%" (
    echo [%CL_R%FAIL%CL_NC%] Missing at32f415xx_race.cfg beside this script.
    goto :fail_exit
)

:: Reuse the normal backup folder (x3utils_win\backup).
set "backup_dir=%~dp0..\backup"
if not exist "%backup_dir%" mkdir "%backup_dir%"

for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyy-MM-dd_HH-mm-ss"') do set "timestamp=%%i"
set "dump_file=%backup_dir%\race_dump_%timestamp%.bin"
set "norm_dump_file=%dump_file:\=/%"

echo.
echo %D%
echo    %CL_M%Power-race DUMP  (RESPAWN - read-only)%CL_NC%
echo %D%
echo    Hammering connects; the one that catches the window dumps 128 KB.
echo    %CL_C%Apply 12V now%CL_NC%; if it misses, cut and re-apply. %CL_C%Ctrl+C to stop.%CL_NC%
echo    Output: "%dump_file%"
echo.

set /a attempts=0

:race_loop
set /a attempts+=1
"%OPENOCD_BIN%" -s "%SCRIPTS_DIR%" -d0 -f "%RACE_CFG%" ^
    -c "init" -c "halt" ^
    -c "dump_image {%norm_dump_file%} 0x08000000 0x20000" ^
    -c "exit" >nul 2>&1
if not errorlevel 1 goto :caught
<nul set /p "=."
set /a "m=attempts %% 50"
if !m!==0 echo    [!attempts! tries]
goto :race_loop

:caught
echo.
echo.
echo [ %CL_G%CAUGHT%CL_NC% ] Connected + dumped on attempt %attempts%.

:: Validate: all-zeros/one-byte = read-protected mask; wrong size = partial read.
call "%~dp0..\validate_bin.cmd" "%dump_file%"
if not "%VALIDATE_RESULT%"=="OK" (
    echo [%CL_Y%WARN%CL_NC%] %VALIDATE_MSG%
    echo        The connect worked, but the read looks bad. A read-protected chip
    echo        dumps all-zeros - clear FAP first with the rdp tool, then re-race.
    goto :end
)

echo [ %CL_G%OK%CL_NC% ] Verified %EXPECTED_SIZE% bytes.
echo [ %CL_G%OK%CL_NC% ] Saved: "%dump_file%"

:: Secondary copy, mirroring dump.bat.
set "appdata_backup=%LOCALAPPDATA%\x3utils_backup"
if not exist "%appdata_backup%" mkdir "%appdata_backup%"
copy /Y "%dump_file%" "%appdata_backup%\race_dump_%timestamp%.bin" >nul
if not errorlevel 1 echo [ %CL_G%OK%CL_NC% ] Copy:  "%appdata_backup%\race_dump_%timestamp%.bin"
goto :end

:fail_exit
echo.
echo [%CL_R%FAIL%CL_NC%] Aborted.
echo.
pause
exit /b 1

:end
echo.
pause
exit /b 0
