@echo off

:: --- OPENOCD CONFIGURATION ---
set "OPENOCD_BIN=%~dp0oocd\at32f415\bin\openocd.exe"
set "SCRIPTS_DIR=%~dp0oocd\at32f415\scripts"
set "INTERFACE=interface\stlink.cfg"
set "TARGET=target\at32f415_alt.cfg"

set "CONNECT_TIMEOUT=7"

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
