@echo off

:: --- ENSURE ANSI/VT COLOR CODES RENDER IN THIS CONSOLE ---
set "VT_NEEDS_FIX=0"
reg query "HKCU\Console" /v VirtualTerminalLevel >nul 2>nul
if errorlevel 1 (
    set "VT_NEEDS_FIX=1"
) else (
    set "VT_LEVEL="
    for /f "tokens=3" %%A in ('reg query "HKCU\Console" /v VirtualTerminalLevel 2^>nul') do set "VT_LEVEL=%%A"
    if not "%VT_LEVEL%"=="0x1" set "VT_NEEDS_FIX=1"
)
if "%VT_NEEDS_FIX%"=="1" (
    reg add "HKCU\Console" /v VirtualTerminalLevel /t REG_DWORD /d 1 /f >nul 2>nul
)

:: --- OPENOCD CONFIGURATION ---
set "OPENOCD_BIN=%~dp0oocd\at32f415\bin\openocd.exe"
set "SCRIPTS_DIR=%~dp0oocd\at32f415\scripts"
set "INTERFACE=interface\stlink.cfg"
set "TARGET=target\at32f415_c45.cfg"

set "CONNECT_TIMEOUT=3"

:: --- COMMON SETTINGS ---
set "EXPECTED_SIZE=131072"

:: --- ANSI COLORS ---
for /f %%a in ('echo prompt $E^| cmd') do set "ESC=%%a"
set "CL_NC=%ESC%[0m"
set "CL_R=%ESC%[1;31m"
set "CL_G=%ESC%[1;32m"
set "CL_Y=%ESC%[1;33m"
set "CL_M=%ESC%[1;35m"
set "CL_C=%ESC%[1;36m"
