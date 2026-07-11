@echo off
setlocal enabledelayedexpansion

:: -----------------------------------------------------------------------------
:: power_race_connect.bat  -  CONNECT ONLY, corner-case "power-race" RESPAWN.
::
:: For AT32 parts whose firmware disables SWD shortly after boot AND where nRST /
:: C45 cannot be reached. It relaunches a fast fail-fast SWD connect over and over
:: while you cycle the board's POWER. The launch that lands in the brief
:: post-power-on window (before FW disables SWD) connects and HALTS the core.
::
:: Why respawn: openocd's init (the DAP/SWD connect) is one-shot and needs the
:: chip already alive - it can't be spammed in one session. Repeated fresh launches
:: are the only way to catch a power-on window.
::
:: READ-ONLY: connect + halt only. No erase, write, or unlock. openocd exits after
:: each attempt, so a CAUGHT connection here is a proof-of-catch - to actually
:: dump/flash you chain that op into the connect (ask for the dump variant).
::
:: HOW TO USE:
::   1) Board POWER OFF. ST-Link on USB, its 3V3 to the board removed.
::   2) Start this script - it begins hammering (one dot per attempt).
::   3) Apply POWER. If it misses, cut POWER and re-apply - each power-ON is a fresh
::      window. Repeat until it prints CAUGHT.   Ctrl+C to stop.
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

echo.
echo %D%
echo    %CL_M%Power-race connect  (RESPAWN - connect-only, read-only)%CL_NC%
echo %D%
echo    Hammering fresh SWD connects. %CL_C%Apply POWER now%CL_NC%; if it misses, cut
echo    POWER and re-apply (each power-ON is a new window). %CL_C%Ctrl+C to stop.%CL_NC%
echo.

set /a attempts=0

:race_loop
set /a attempts+=1
"%OPENOCD_BIN%" -s "%SCRIPTS_DIR%" -d0 -f "%RACE_CFG%" ^
    -c "init" -c "halt" -c "exit" >nul 2>&1
if not errorlevel 1 goto :caught
<nul set /p "=."
set /a "m=attempts %% 50"
if !m!==0 echo    [!attempts! tries]
goto :race_loop

:caught
echo.
echo.
echo [ %CL_G%CAUGHT%CL_NC% ] Connected + halted on attempt %attempts%.
echo        The power-race works on this hardware. openocd has exited (the hold
echo        is released), so to actually read/write you must chain the op into
echo        the connect - ask for the dump variant next.
echo.
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
