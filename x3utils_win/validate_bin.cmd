@echo off
:: validate_bin.cmd — Shared .bin file validation
:: Usage: call validate_bin.cmd "full_path_to_file"
:: Output variables:
::   VALIDATE_RESULT  = OK | FAIL
::   VALIDATE_MSG     = Error description (if FAIL)
::   BIN_FILE_NAME    = Filename only (e.g. firmware.bin)
::   BIN_NORMALIZED_PATH = Forward-slash path for OpenOCD

set "VALIDATE_RESULT=FAIL"
set "VALIDATE_MSG="
set "BIN_FILE_NAME="
set "BIN_NORMALIZED_PATH="

set "_vbin_path=%~1"

:: 1. Check if path is empty
if "%_vbin_path%"=="" (
    set "VALIDATE_MSG=No file provided."
    exit /b 1
)

:: 2. Check file exists
if not exist "%_vbin_path%" (
    set "VALIDATE_MSG=File does not exist."
    exit /b 1
)

:: 3. Reject { or } in path
for %%C in ("{" "}") do (
    echo(%_vbin_path%| findstr /L /C:"%%~C" >nul
    if not errorlevel 1 (
        set "VALIDATE_MSG=Path contains unsupported character: %%~C. Please rename."
        exit /b 1
    )
)

:: 4. Reject non-ASCII characters
for /f "delims=" %%R in ('powershell -NoProfile -Command ^
    "if ('%_vbin_path%' -match '[^\x00-\x7F]') { 'NON_ASCII' } else { 'OK' }"') do (
    set "_vbin_ascii=%%R"
)
if "%_vbin_ascii%"=="NON_ASCII" (
    set "VALIDATE_MSG=Path contains non-ASCII characters. Please rename using only English letters."
    exit /b 1
)

:: 5. Validate .bin extension
set "_vbin_ext="
for %%A in ("%_vbin_path%") do set "_vbin_ext=%%~xA"
if /i not "%_vbin_ext%"==".bin" (
    set "VALIDATE_MSG=Invalid file type "%_vbin_ext%", only .bin is allowed."
    exit /b 1
)

:: 6. Validate exact size (128 KB = 131072 bytes)
set "_vbin_size="
for %%i in ("%_vbin_path%") do set "_vbin_size=%%~zi"
if not "%_vbin_size%"=="131072" (
    set "VALIDATE_MSG=Invalid file size. Expected: 131072 bytes, Got: %_vbin_size% bytes."
    exit /b 1
)

:: 7. Reject all-zero (or single unique byte) content
set "_vbin_allzero="
for /f %%i in ('powershell -NoProfile -Command "$bytes=[System.IO.File]::ReadAllBytes($env:_vbin_path); ($bytes | Select-Object -Unique).Count -eq 1"') do set "_vbin_allzero=%%i"
if "%_vbin_allzero%"=="True" (
    set "VALIDATE_MSG=Bin file contains only zeros or a single repeated byte."
    exit /b 1
)

:: All checks passed
for %%i in ("%_vbin_path%") do set "BIN_FILE_NAME=%%~nxi"
set "BIN_NORMALIZED_PATH=%_vbin_path:\=/%"
set "VALIDATE_RESULT=OK"
set "VALIDATE_MSG="
exit /b 0
