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

set "dragged_file="
set "display_name="

:: Initial settings
set "timeout_val=%CONNECT_TIMEOUT%"

:: Detect current radio state from config.cmd TARGET line
call :detect_radio

:menu_loop
cls
echo  ============================================================
echo           ST-LINK UTILITIES FOR X3 scooters - %VERSION%
echo  ============================================================
echo.

:: Show dragged file if present
if not "%dragged_file%"=="" (
    echo  [LOADED] Target File:
    echo           %CL_Y%"%display_name%"%CL_NC%
) else (
    echo  [LOADED] No file loaded
)
echo.

echo  [ %CL_C%Actions - Press 1-5 to execute%CL_NC% ]
echo   [1] Flash SHU compatible (ZT3, G3, F3/F3Pro)
echo   [2] Run Full Memory Dump (128 KB)
echo   [3] Flash Loaded File to Chip
echo   [4] Load / Change Target .bin File
echo   [5] Exit
echo.
echo  [ %CL_C%Connection Options - Press A, B, or C to change%CL_NC% ]
if "%current_radio%"=="A" (echo   [%CL_C%X%CL_NC%] A - Default / Blinker buttons) else (echo   [ ] A - Default / Blinker buttons)
if "%current_radio%"=="B" (echo   [%CL_Y%X%CL_NC%] B - C45 / Clone ST-Link) else (echo   [ ] B - C45 / Clone ST-Link)
if "%current_radio%"=="C" (echo   [%CL_M%X%CL_NC%] C - C45 / Genuine ST-Link) else (echo   [ ] C - C45 / Genuine ST-Link)
echo.
if "%current_radio%"=="B" (
    echo  [ %CL_C%Configuration%CL_NC% ]
    echo   T. Set countdown timer ^(Current: %timeout_val%s^)
    echo.
)
if "%current_radio%"=="B" goto :menu_choice_B
choice /c 12345ABC /n /m "> Press a key (1-5, A-C): "
goto :menu_choice_done
:menu_choice_B
choice /c 12345ABCT /n /m "> Press a key (1-5, A-C, or T): "
:menu_choice_done
set "key=%errorlevel%"

:: Handle A, B, C Radio Toggles (Errorlevels 6, 7, 8)
if %key% equ 6 (call :set_radio A & goto :menu_loop)
if %key% equ 7 (call :set_radio B & goto :menu_loop)
if %key% equ 8 (call :set_radio C & goto :menu_loop)

:: Handle changing the Timeout variable (Errorlevel 9)
if %key% equ 9 (
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

:: Handle 1-5 GOTO jumps (Errorlevels 1-5)
if %key% equ 1 goto :opt_compat
if %key% equ 2 goto :opt_dump
if %key% equ 3 goto :opt_flash
if %key% equ 4 goto :opt_load
if %key% equ 5 goto :exit_menu

goto :menu_loop

:: ----------------------------------------------------
:: Radio group detection / writing
:: ----------------------------------------------------

:: Reads config.cmd TARGET line and sets current_radio to A, B, or C
:detect_radio
set "current_radio=A"
for /f "tokens=*" %%L in ('findstr /i "TARGET" "%~dp0config.cmd"') do (
    echo %%L | findstr /i "at32f415_c45.cfg" >nul && set "current_radio=B"
    echo %%L | findstr /i "at32f415_nrst.cfg" >nul && set "current_radio=C"
)
exit /b 0

:: Writes the chosen radio option's .cfg into config.cmd's TARGET line
:set_radio
set "new_radio=%~1"
if "%new_radio%"=="%current_radio%" exit /b 0

if "%new_radio%"=="A" set "new_cfg=at32f415.cfg"
if "%new_radio%"=="B" set "new_cfg=at32f415_c45.cfg"
if "%new_radio%"=="C" set "new_cfg=at32f415_nrst.cfg"

powershell -NoProfile -Command "(Get-Content '%~dp0config.cmd') -replace 'target\\[^\\]+\.cfg', 'target\%new_cfg%' | Set-Content '%~dp0config.tmp' -Encoding Ascii"

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
:: Action Labels (logic carried over from original script)
:: ----------------------------------------------------

:: Call flash_compat.bat
:opt_compat
echo.
echo Launching Flash SHU compatible...
echo.
if exist "%~dp0flash_compat.bat" (
    call "%~dp0flash_compat.bat"
) else (
    echo [%CL_R%FAIL%CL_NC%] Could not find flash_compat.bat.
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
    echo        Please select Option [4] to load a file.
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
echo =======================================================
echo  Please Drag and Drop your .bin file directly here 
echo  and press ENTER.
echo =======================================================
echo.

set /p "dragged_file=Drop file here (or type 'back'): "
if /i "%dragged_file%"=="back" goto :menu_loop
for %%A in ("%dragged_file%") do (
    set "dragged_file=%%~fA"
)
if "%dragged_file%"=="" goto :menu_loop
if not exist "%dragged_file%" (
    echo.
    echo [%CL_R%FAIL%CL_NC%] File does not exist.
    pause
    set "dragged_file="
    set "display_name="
    goto :menu_loop
)
for %%C in ("{" "}") do (
    echo(%dragged_file%| findstr /L /C:"%%~C" >nul
    if not errorlevel 1 (
        echo [%CL_R%FAIL%CL_NC%] Path contains unsupported character: %%~C
        echo        Please rename.
        pause
        set "dragged_file="
        set "display_name="
        goto :menu_loop
    )
)
for /f "delims=" %%R in ('powershell -NoProfile -Command ^
    "if ('%dragged_file%' -match '[^\x00-\x7F]') { 'NON_ASCII' } else { 'OK' }"') do (
    set "ascii_result=%%R"
)
if "%ascii_result%"=="NON_ASCII" (
    echo [%CL_R%FAIL%CL_NC%] Path contains non-ASCII characters.
    echo        Path: %dragged_file%
    echo        Please rename using only English letters.
    pause
    set "dragged_file="
    set "display_name="
    goto :menu_loop
)
set "extension="
for %%A in ("%dragged_file%") do (
    set "extension=%%~xA"
)
if /i not "%extension%"==".bin" (
    echo.
    echo [%CL_R%FAIL%CL_NC%] Only .bin files are allowed.
    pause
    set "dragged_file="
    set "display_name="
    goto :menu_loop
)
for %%i in ("%dragged_file%") do set "display_name=%%~nxi"
goto :menu_loop

:: Exit option
:exit_menu
cls
echo.
echo Exiting utility. Bye!
timeout /t 2 >nul
exit /b 0
