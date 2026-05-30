@echo off
setlocal

set "dragged_file="
set "display_name="

:menu_top
cls
echo =======================================================================
echo                ST-LINK UTILITIES FOR X3 scooters - v1.1
echo =======================================================================
echo.

:: Show dragged file if present
if not "%dragged_file%"=="" (
    echo  [LOADED] Target File:
    echo           "%display_name%"
) else (
    echo  [LOADED] No file loaded
)

:: Show menu options
echo.
echo  [1] Flash SHU compatible (Not GT3/GT3 Pro)
echo  [2] Run Full Memory Dump (128 KB)
echo  [3] Flash Loaded File to Chip
echo  [4] Load / Change Target .bin File
echo  [5] Exit
echo.
echo =======================================================================
echo.

:: Get user choice
set "choice="
set /p "choice=Select an option [1-5]: "
if "%choice%"=="" goto :menu_top
if "%choice%"=="1" goto :opt_cmp
if "%choice%"=="2" goto :opt_dump
if "%choice%"=="3" goto :opt_flash
if "%choice%"=="4" goto :opt_load
if "%choice%"=="5" goto :exit_menu

:: Invalid choice handling
echo.
echo [FAIL] Invalid selection.
echo        Please choose 1, 2, 3, 4 or 5.
timeout /t 2 >nul
goto :menu_top

:: Call flash_cmp.bat
:opt_cmp
echo.
echo Launching Flash SHU compatible...
echo.
if exist "%~dp0flash_cmp.bat" (
    call "%~dp0flash_cmp.bat"
) else (
    echo [FAIL] Could not find flash_cmp.bat.
    pause
)
goto :menu_top

:: Call dump.bat
:opt_dump
echo.
echo Launching Full Memory Dump Utility...
echo.
if exist "%~dp0dump.bat" (
    call "%~dp0dump.bat"
) else (
    echo [FAIL] Could not find dump.bat.
    pause
)
goto :menu_top

:: Call flash.bat
:opt_flash
if "%dragged_file%"=="" (
    echo.
    echo [FAIL] You cannot flash without loading a file first.
    echo        Please select Option [4] to load a file.
    echo.
    pause
    goto :menu_top
)
echo.
echo Launching Flash Utility for:
echo        "%display_name%"
echo.
:: Pass the loaded file path as an argument to flash.bat
if exist "%~dp0flash.bat" (
    call "%~dp0flash.bat" "%dragged_file%"
) else (
    echo [FAIL] Could not find flash.bat.
    pause
)
goto :menu_top

:: Load bin file by drag n drop or cancel
:opt_load
echo.
echo =======================================================
echo  Please Drag and Drop your .bin file directly here 
echo  and press ENTER.
echo =======================================================
echo.

set /p "dragged_file=Drop file here (or type 'back'): "
if /i "%dragged_file%"=="back" goto :menu_top
for %%A in (%dragged_file%) do (
    set "dragged_file=%%~fA"
)
if "%dragged_file%"=="" goto :menu_top
if not exist "%dragged_file%" (
    echo.
    echo [FAIL] File does not exist.
    pause
    set "dragged_file="
    set "display_name="
    goto :menu_top
)
set "extension="
for %%A in ("%dragged_file%") do (
    set "extension=%%~xA"
)
if /i not "%extension%"==".bin" (
    echo.
    echo [FAIL] Only .bin files are allowed.
    pause
    set "dragged_file="
    set "display_name="
    goto :menu_top
)
for %%i in ("%dragged_file%") do set "display_name=%%~nxi"
goto :menu_top

:: Exit option
:exit_menu
cls
echo.
echo Exiting utility. Bye!
timeout /t 2 >nul
exit /b 0
