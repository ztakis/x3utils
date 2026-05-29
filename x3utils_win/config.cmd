@echo off

:: --- OPENOCD CONFIGURATION ---

set "OPENOCD_BIN=%~dp0oocd\at32f415\bin\openocd.exe"
set "SCRIPTS_DIR=%~dp0oocd\at32f415\scripts"
set "INTERFACE=interface\stlink.cfg"
set "TARGET=target\at32f415.cfg"

:: --- COMMON SETTINGS ---

set "EXPECTED_SIZE=131072"
