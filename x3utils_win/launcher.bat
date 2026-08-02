@echo off
setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
set /p VERSION=<"%SCRIPT_DIR%VERSION"

:: Validate config.cmd exists
if not exist "%~dp0config.cmd" (
    echo [%CL_R%FAIL%CL_NC%] Missing config.cmd
    pause
    exit /b 1
)
call "%~dp0config.cmd"
if errorlevel 1 goto :fail_exit

set "dragged_file="
set "display_name="

:: Initial settings
set "timeout_val=%CONNECT_TIMEOUT%"

:: Detect current radio state from config.cmd TARGET line
call :detect_radio

:menu_loop
cls
echo   * * * * * * * * * * * * * * * * * * * * * * * * *
echo   *         __                                    *
echo   *          /                                    *
echo   *        D/              ST-LINK utilities      *
echo   *        /                for X3 scooters       *
echo   *       /                     v%VERSION%            *
echo   *      /\________/""                            *
echo   *    ^(o^)         ^(o^)                            *
echo   * * * * * * * * * * * * * * * * * * * * * * * * *
echo.


:: Show dragged file if present
if not "%dragged_file%"=="" (
    echo  [LOADED] Target File:
    echo           %CL_Y%"%display_name%"%CL_NC%
) else (
    echo  [LOADED] No file loaded
)
echo.

echo  [ %CL_C%Actions - Press 1-7 to execute%CL_NC% ]
echo   [1] Check Connection
echo   [2] Backup Full Memory (128 KB)
echo   [3] Backup + Flash Loaded File
echo   [4] Flash Slot 0
echo   [5] Load / Change Target .bin File
echo   [6] Advanced
echo   [7] Exit
echo.
echo  [ %CL_C%Connection Options - Press A, B, C, or D to change%CL_NC% ]
if "%current_radio%"=="A" (echo   [%CL_C%X%CL_NC%] A - Default / Blinker buttons) else (echo   [ ] A - Default / Blinker buttons)
if "%current_radio%"=="B" (echo   [%CL_Y%X%CL_NC%] B - C45 / Clone ST-Link) else (echo   [ ] B - C45 / Clone ST-Link)
if "%current_radio%"=="C" (echo   [%CL_M%X%CL_NC%] C - C45 / Genuine ST-Link) else (echo   [ ] C - C45 / Genuine ST-Link)
if "%current_radio%"=="D" (echo   [%CL_G%X%CL_NC%] D - Power-race / no reset line) else (echo   [ ] D - Power-race / no reset line)
echo.
if "%current_radio%"=="B" (
    echo  [ %CL_C%Configuration%CL_NC% ]
    echo   T. Set countdown timer ^(Current: %timeout_val%s^)
    echo.
)
if "%current_radio%"=="B" goto :menu_choice_B
choice /c 1234567ABCD /n /m "> Press a key (1-7, A-D): "
goto :menu_choice_done
:menu_choice_B
choice /c 1234567ABCDT /n /m "> Press a key (1-7, A-D, or T): "
:menu_choice_done
set "key=%errorlevel%"

:: Handle A, B, C, D Radio Toggles (Errorlevels 8, 9, 10, 11)
if %key% equ 8 (call :set_radio A & goto :menu_loop)
if %key% equ 9 (call :set_radio B & goto :menu_loop)
if %key% equ 10 (call :set_radio C & goto :menu_loop)
if %key% equ 11 (call :set_radio D & goto :menu_loop)

:: Handle changing the Timeout variable (Errorlevel 12, B menu only)
if %key% equ 12 (
    echo.
    set /p "timeout_val=Enter new countdown timer value (0-60): "
    :: Validate: must be a number between 0 and 60
    echo !timeout_val!| findstr /r "^[0-9][0-9]*$" >nul
    if errorlevel 1 (
        echo.
        echo [%CL_R%FAIL%CL_NC%] Invalid value. Please enter a number between 0 and 60.
        set "timeout_val=%CONNECT_TIMEOUT%"
        pause
        goto :menu_loop
    )
    if !timeout_val! GTR 60 (
        echo.
        echo [%CL_R%FAIL%CL_NC%] Value out of range. Please enter a number between 0 and 60.
        set "timeout_val=%CONNECT_TIMEOUT%"
        pause
        goto :menu_loop
    )
    call :set_timeout
    goto :menu_loop
)

:: Handle 1-7 GOTO jumps (Errorlevels 1-7)
if %key% equ 1 goto :opt_check
if %key% equ 2 goto :opt_dump
if %key% equ 3 goto :opt_flash
if %key% equ 4 goto :opt_slot0
if %key% equ 5 goto :opt_load
if %key% equ 6 goto :advanced_menu
if %key% equ 7 goto :exit_menu

goto :menu_loop

:: ----------------------------------------------------
:: Radio group detection / writing
:: ----------------------------------------------------

:: Reads config.cmd TARGET line and sets current_radio to A, B, or C
:detect_radio
set "current_radio=A"
for /f "tokens=*" %%L in ('findstr /i "TARGET" "%~dp0config.cmd"') do (
    echo %%L | findstr /i "at32f415xx_c45.cfg" >nul && set "current_radio=B"
    echo %%L | findstr /i "at32f415xx_nrst.cfg" >nul && set "current_radio=C"
)
:: RACE=true (mode D) overrides the TARGET-based detection.
findstr /i "RACE=true" "%~dp0config.cmd" >nul && set "current_radio=D"
exit /b 0

:: Writes the chosen radio option's .cfg into config.cmd's TARGET line
:set_radio
set "new_radio=%~1"
if "%new_radio%"=="%current_radio%" exit /b 0

if "%new_radio%"=="A" set "new_cfg=at32f415xx.cfg"
if "%new_radio%"=="B" set "new_cfg=at32f415xx_c45.cfg"
if "%new_radio%"=="C" set "new_cfg=at32f415xx_nrst.cfg"
if "%new_radio%"=="D" set "new_cfg=at32f415xx.cfg"

:: Mode D drives Dump via the RACE flag; A/B/C clear it.
if "%new_radio%"=="D" (set "race_val=true") else (set "race_val=false")

powershell -NoProfile -Command "(Get-Content '%~dp0config.cmd') -replace 'target\\[^\\]+\.cfg', 'target\%new_cfg%' -replace 'RACE=\w+', 'RACE=%race_val%' | Set-Content '%~dp0config.tmp' -Encoding Ascii"

:: Verify temp file was written before replacing
if not exist "%~dp0config.tmp" (
    echo.
    echo [%CL_R%FAIL%CL_NC%] Could not write config update. config.cmd unchanged.
    pause
    exit /b 1
)
move /y "%~dp0config.tmp" "%~dp0config.cmd" >nul

:: Confirm the change actually took effect
call :detect_radio
if not "%current_radio%"=="%new_radio%" (
    echo.
    echo [%CL_R%FAIL%CL_NC%] config.cmd did not update correctly.
    pause
    exit /b 1
)
exit /b 0

:: Writes the new timeout value into config.cmd's CONNECT_TIMEOUT line
:set_timeout
powershell -NoProfile -Command "(Get-Content '%~dp0config.cmd') -replace 'CONNECT_TIMEOUT=\d+', 'CONNECT_TIMEOUT=!timeout_val!' | Set-Content '%~dp0config.tmp' -Encoding Ascii"

if not exist "%~dp0config.tmp" (
    echo.
    echo [%CL_R%FAIL%CL_NC%] Could not write config update. config.cmd unchanged.
    pause
    exit /b 1
)
move /y "%~dp0config.tmp" "%~dp0config.cmd" >nul
exit /b 0

:: ----------------------------------------------------
:: Action Labels
:: ----------------------------------------------------

:: Call connection_test.bat
:opt_check
echo.
echo Launching Connection Check...
echo.
if exist "%~dp0connection_test.bat" (
    call "%~dp0connection_test.bat"
) else (
    echo [%CL_R%FAIL%CL_NC%] Could not find connection_test.bat.
    pause
)
goto :menu_loop

:: Call flash_slot0.bat
:opt_slot0
echo.
echo Launching Flash Slot 0...
echo.
if exist "%~dp0flash_slot0.bat" (
    call "%~dp0flash_slot0.bat"
) else (
    echo [%CL_R%FAIL%CL_NC%] Could not find flash_slot0.bat.
    pause
)
goto :menu_loop

:: Call dump.bat
:opt_dump
echo.
echo Launching Full Memory Dump Utility...
echo.
if exist "%~dp0dump.bat" (
    call "%~dp0dump.bat"
) else (
    echo [%CL_R%FAIL%CL_NC%] Could not find dump.bat.
    pause
)
goto :menu_loop

:: Call flash.bat
:opt_flash
if "%dragged_file%"=="" (
    echo.
    echo [%CL_R%FAIL%CL_NC%] You cannot flash without loading a file first.
    echo        Please select Option [5] to load a file.
    echo.
    pause
    goto :menu_loop
)
echo.
echo Launching Flash Utility for:
echo        "%display_name%"
echo.
:: Pass the loaded file path as argument to flash.bat
if exist "%~dp0flash.bat" (
    call "%~dp0flash.bat" "%dragged_file%"
) else (
    echo [%CL_R%FAIL%CL_NC%] Could not find flash.bat.
    pause
)
goto :menu_loop

:: Load bin file by drag n drop or cancel
:opt_load
echo.
echo %D%
echo   Please Drag and Drop your .bin file directly here
echo   and press ENTER.
echo %D%
echo.

set /p "dragged_file=Drop file here (or type 'back'): "
if /i "%dragged_file%"=="back" goto :menu_loop
for %%A in ("%dragged_file%") do (
    set "dragged_file=%%~fA"
)

call "%~dp0validate_bin.cmd" "%dragged_file%"
if not "%VALIDATE_RESULT%"=="OK" (
    echo [%CL_R%FAIL%CL_NC%] %VALIDATE_MSG%
    pause
    set "dragged_file="
    set "display_name="
    goto :menu_loop
)
set "display_name=%BIN_FILE_NAME%"
goto :menu_loop

:: ----------------------------------------------------
:: Advanced submenu
:: ----------------------------------------------------

:advanced_menu
cls
echo.
echo %D%
echo                    Advanced Actions
echo %D%
echo.
echo   [1] Flash SHU Compatible (ZT3, G3, F3/F3Pro)
echo   [2] Flash Only - No Backup
echo   [3] Check Protection
echo   [4] Unlock / Rescue - Mass Erase
echo   [5] Back
echo.
choice /c 12345 /n /m "> Press a key (1-5): "
set "advanced_key=%errorlevel%"

if %advanced_key% equ 1 goto :advanced_compat
if %advanced_key% equ 2 goto :advanced_flash_only
if %advanced_key% equ 3 goto :advanced_rdp_check
if %advanced_key% equ 4 goto :advanced_rdp_rescue
if %advanced_key% equ 5 goto :menu_loop
goto :advanced_menu

:advanced_compat
echo.
echo Launching Flash SHU compatible...
echo.
if exist "%~dp0special\flash_compat.bat" (
    call "%~dp0special\flash_compat.bat"
) else (
    echo [%CL_R%FAIL%CL_NC%] Could not find special\flash_compat.bat.
    pause
)
goto :advanced_menu

:advanced_flash_only
echo.
echo Launching Flash Only...
echo.
if exist "%~dp0special\flash_only.bat" (
    call "%~dp0special\flash_only.bat"
) else (
    echo [%CL_R%FAIL%CL_NC%] Could not find special\flash_only.bat.
    pause
)
goto :advanced_menu

:advanced_rdp_check
echo.
echo Launching Protection Check...
echo.
if exist "%~dp0special\rdp\rdp.ps1" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0special\rdp\rdp.ps1" -Check -Launcher
) else (
    echo [%CL_R%FAIL%CL_NC%] Could not find special\rdp\rdp.ps1.
)
echo.
pause
goto :advanced_menu

:advanced_rdp_rescue
echo.
echo Launching Unlock / Rescue...
echo.
if exist "%~dp0special\rdp\rdp.ps1" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0special\rdp\rdp.ps1" -Rescue -Launcher
) else (
    echo [%CL_R%FAIL%CL_NC%] Could not find special\rdp\rdp.ps1.
)
echo.
pause
goto :advanced_menu

:fail_exit
echo.
echo [%CL_R%FAIL%CL_NC%] Operation aborted.
echo.
pause
exit /b 1

:exit_menu
cls
echo.
echo Exiting utility. Bye!
timeout /t 2 >nul
exit /b 0
