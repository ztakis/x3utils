@echo off
:: ==========================================================================
:: race_grade.cmd - shared power-race attempt classifier (the lego brick).
:: Called by dump.bat / flash.bat / flash_compat.bat after a MISSED attempt.
:: Reads the just-captured attempt log (%race_last%) and prints ONE colored
:: live symbol so the operator sees WHY it missed, not an anonymous dot.
::
:: Classify on whether the CORE was actually reached ("Cortex-M4 ... detected"
:: needs live SWD to the chip) - NOT on which error string happened, because
:: examination-failed / init-mode-failed never reach the core and so must read
:: as "not connected" even though they are different errors:
::   x  open failed   = the ST-Link itself is gone from USB   -> back off ~1s
::   H  target halted  = core reached AND frozen               = near-catch
::   N  Cortex-M4 seen but not halted                          = on pad, marginal
::   .  none of the above                                      = not connected
::
:: %race_last% and the CL_* colors come from the caller's environment
:: (config.cmd sets the colors; the caller's loop sets race_last).
:: ==========================================================================
:: (backoff uses ping-to-loopback for ~1s, not timeout: timeout aborts when stdin
::  isn't an interactive console; ping needs no stdin and always works.)
findstr /c:"open failed" "%race_last%" >nul && ( <nul set /p "=%CL_R%x%CL_NC%" & ping -n 2 127.0.0.1 >nul & exit /b )
findstr /c:"target halted" "%race_last%" >nul && ( <nul set /p "=%CL_G%H%CL_NC%" & exit /b )
findstr /c:"Cortex-M4" "%race_last%" >nul && ( <nul set /p "=%CL_Y%N%CL_NC%" & exit /b )
<nul set /p "=."
exit /b
