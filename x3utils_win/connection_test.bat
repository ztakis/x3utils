@echo off
setlocal

:: --------------------------------------------------------------------------
:: connection_test.bat
:: Read-only ST-LINK and target connection check.
:: Uses the connection mode currently selected in launcher.bat.
:: --------------------------------------------------------------------------

if not exist "%~dp0config.cmd" (
    echo [FAIL] Missing config.cmd
    goto :fail_exit
)

call "%~dp0config.cmd"
if errorlevel 1 goto :fail_exit

set "race_last=%TEMP%\x3utils_race_last.log"

echo.
echo %D%
echo              Testing ST-LINK connection...
echo %D%
echo.
echo    This test reads no firmware and writes nothing.
echo.

:check_attempt
if /i "%RACE%"=="true" goto :race_check

:: --------------------------------------------------------------------------
:: Modes A, B and C
:: --------------------------------------------------------------------------

if "%TARGET%"=="target\at32f415xx_c45.cfg" (
    echo    Mode: B - C45 / Clone ST-Link
    echo.

    "%OPENOCD_BIN%" -s "%SCRIPTS_DIR%" -d0 ^
        -f "%TARGET%" ^
        -c "guided_connect {%CONNECT_TIMEOUT%}" ^
        -c "flash probe 0" ^
        -c "exit"
) else (
    if "%TARGET%"=="target\at32f415xx_nrst.cfg" (
        echo    Mode: C - C45 / Genuine ST-Link
    ) else (
        echo    Mode: A - Default / Blinker buttons
    )
    echo.

    "%OPENOCD_BIN%" -s "%SCRIPTS_DIR%" -d0 ^
        -f "%INTERFACE%" ^
        -f "%TARGET%" ^
        -c "adapter speed 1000" ^
        -c "init" ^
        -c "reset halt" ^
        -c "flash probe 0" ^
        -c "exit"
)

set "openocd_result=%errorlevel%"

if not "%openocd_result%"=="0" goto :check_failed
goto :check_ok

:: --------------------------------------------------------------------------
:: Mode D - Power-race
::
:: OpenOCD init is one-shot, so every missed connection requires a fresh
:: process. A successful verdict requires flash-probe evidence, not only a
:: halted core or exit code 0.
:: --------------------------------------------------------------------------

:race_check
echo    Mode: D - Power-race / no reset line
echo.
echo    Hammering connection attempts.
echo    %CL_C%Apply POWER now%CL_NC%; if it misses, cut and re-apply POWER.
echo    Each power-ON is a fresh connection window.
echo.
echo    %CL_C%Ctrl+C to stop.%CL_NC%
echo    Live: .=searching  %CL_Y%N%CL_NC%=noisy, hold steadier
echo          %CL_G%H%CL_NC%=almost    %CL_R%x%CL_NC%=probe/USB gone
echo.

set /a race_tries=0

set OOCD_RACE=-s "%SCRIPTS_DIR%" -d0 ^
 -f "target\at32f415xx_race.cfg" ^
 -c "race_connect" ^
 -c "flash probe 0" ^
 -c "exit"

:race_loop
set /a race_tries+=1

"%OPENOCD_BIN%" %OOCD_RACE% >"%race_last%" 2>&1

if errorlevel 1 (
    findstr /i /c:"open failed" "%race_last%" >nul
    if not errorlevel 1 goto :adapter_retry
    call "%~dp0race_grade.cmd"
    goto :race_loop
)

findstr /i /c:"flash 'at32f415xx' found" "%race_last%" >nul
if errorlevel 1 (
    call "%~dp0race_grade.cmd"
    goto :race_loop
)

echo.
echo.
type "%race_last%"
echo.
echo [ %CL_G%CONNECTED%CL_NC% ] Target answered on attempt %race_tries%.
goto :end

:: --------------------------------------------------------------------------
:: Retry prompts and verdicts
:: --------------------------------------------------------------------------

:check_ok
echo.
echo [ %CL_G%CONNECTED%CL_NC% ] ST-LINK and target answered correctly.
echo [ %CL_G%OK%CL_NC% ] Flash bank detected.
echo.
echo    You can continue with backup or flashing.
goto :end

:check_failed
echo.
echo [ %CL_Y%RETRY%CL_NC% ] Could not connect to the ST-LINK and target.

:target_retry_prompt
echo.
echo        Check the ST-LINK USB connection, selected mode, and SWD contacts.
echo        For C45, touch the metal contact point, not the capacitor body.
echo.
set "retry_choice="
set /p "retry_choice=%CL_C%Press ENTER to retry, or type Q to quit: %CL_NC%"
if /i "%retry_choice%"=="q" goto :fail_exit
echo.
goto :check_attempt

:adapter_retry
echo.
echo [ %CL_Y%WAIT%CL_NC% ] ST-LINK adapter not found.
echo.
echo        Plug or reconnect the ST-LINK.
echo        Close another program if it is using the adapter.
echo.
set "retry_choice="
set /p "retry_choice=%CL_C%Press ENTER to retry, or type Q to quit: %CL_NC%"
if /i "%retry_choice%"=="q" goto :fail_exit
echo.
goto :check_attempt

:fail_exit
if exist "%race_last%" del "%race_last%" >nul 2>&1
echo.
pause
exit /b 1

:end
if exist "%race_last%" del "%race_last%" >nul 2>&1
echo.
pause
exit /b 0
