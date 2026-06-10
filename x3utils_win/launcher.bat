@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set /p VERSION=<"%SCRIPT_DIR%VERSION"

set "dragged_file="
set "display_name="

:menu_top
cls
echo ==============================================================
echo           ST-LINK UTILITIES FOR X3 scooters - %VERSION%          
echo ==============================================================
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
echo  [1] Flash SHU compatible (ZT3, G3, F3/F3Pro)
echo  [2] Flash SHU compatible (GT3 - Experimental)
echo  [3] Run Full Memory Dump (128 KB)
echo  [4] Flash Loaded File to Chip
echo  [5] Load / Change Target .bin File
echo  [6] Exit
echo.
echo ==============================================================
echo.

:: Get user choice
set "choice="
set /p "choice=Select an option [1-6]: "
if "%choice%"=="" goto :menu_top
if "%choice%"=="1" goto :opt_compat
if "%choice%"=="2" goto :opt_gt3_compat
if "%choice%"=="3" goto :opt_dump
if "%choice%"=="4" goto :opt_flash
if "%choice%"=="5" goto :opt_load
if "%choice%"=="6" goto :exit_menu

:: Invalid choice handling
echo.
echo [FAIL] Invalid selection.
echo        Please choose 1, 2, 3, 4, 5 or 6.
timeout /t 2 >nul
goto :menu_top

:: Call flash_compat.bat
:opt_compat
echo.
echo Launching Flash SHU compatible...
echo.
if exist "%~dp0flash_compat.bat" (
    call "%~dp0flash_compat.bat"
) else (
    echo [FAIL] Could not find flash_compat.bat.
    pause
)
goto :menu_top
    
:: Call flash_gt3_compat.bat
:opt_gt3_compat
echo.
echo Launching Flash GT3 SHU compatible...
echo.
if exist "%~dp0flash_gt3_compat.bat" (
    call "%~dp0flash_gt3_compat.bat"
) else (
    echo [FAIL] Could not find flash_gt3_compat.bat.
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
    echo        Please select Option [5] to load a file.
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
for %%A in ("%dragged_file%") do (
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
for %%C in ("{" "}") do (
    echo(%dragged_file%| findstr /L /C:"%%~C" >nul
    if not errorlevel 1 (
        echo [FAIL] Path contains unsupported character: %%~C
        echo        Please rename.
        pause
        set "dragged_file="
        set "display_name="
        goto :menu_top
    )
)
for /f "delims=" %%R in ('powershell -NoProfile -Command ^
    "if ('%dragged_file%' -match '[^\x00-\x7F]') { 'NON_ASCII' } else { 'OK' }"') do (
    set "ascii_result=%%R"
)
if "%ascii_result%"=="NON_ASCII" (
    echo [FAIL] Path contains non-ASCII characters.
    echo        Path: %dragged_file%
    echo        Please rename using only English letters.
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
