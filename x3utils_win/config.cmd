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

:: --- COLORS ---
for /f %%a in ('echo prompt $E^| cmd') do set "ESC=%%a"
set "CL_NC=%ESC%[0m"
set "CL_R=%ESC%[1;31m"
set "CL_G=%ESC%[1;32m"
set "CL_Y=%ESC%[1;33m"
set "CL_M=%ESC%[1;35m"
set "CL_C=%ESC%[1;36m"
set "D=^============================================================"

:: --- OPENOCD CONFIGURATION ---
set "OPENOCD_BIN=%~dp0oocd\bin\openocd.exe"
set "SCRIPTS_DIR=%~dp0oocd\scripts"
set "INTERFACE=interface\stlink.cfg"
set "TARGET=target\at32f415xx_c45.cfg"

:: Connection mode D (power-race): true = Dump uses the respawn power-race connect
:: (target\at32f415xx_c45.cfg). Set by the launcher radio; A/B/C reset it false.
set "RACE=false"

:: Power-race DEBUG (diagnostic only). true = each catch attempt's full verbose
:: OpenOCD output is APPENDED to a log (with a per-attempt header) WHILE the dots
:: keep printing - operator feedback is never suppressed (the lesson from the old
:: firehose). Read the log tail after a "dots-keep-moving-never-catches" stretch
:: to see the failure signature: genuine window miss ("init mode failed - unable
:: to connect") vs a marginal catch that connects then bails. false for normal use.
set "RACE_DEBUG=false"

set "CONNECT_TIMEOUT=3"

:: --- COMMON SETTINGS ---
set "EXPECTED_SIZE=131072"

:: --- VALIDATE ---
:: Validate OpenOCD binary exists
if not exist "%OPENOCD_BIN%" (
    echo [%CL_R%FAIL%CL_NC%] OpenOCD binary not found.
    echo        Expected: %OPENOCD_BIN%
    exit /b 1
)

:: Validate OpenOCD scripts directory exists
if not exist "%SCRIPTS_DIR%" (
    echo [%CL_R%FAIL%CL_NC%] OpenOCD scripts directory not found.
    echo        Expected: %SCRIPTS_DIR%
    exit /b 1
)
