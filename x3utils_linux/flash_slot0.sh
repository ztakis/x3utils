#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load configuration settings
CONFIG_FILE="$SCRIPT_DIR/config.sh"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "[${CL_R}FAIL${CL_NC}] Missing config.sh"
    exit 1
fi

source "$CONFIG_FILE"

bin_file_path="$1"

# Detect direct execution without argument
if [[ -z "$bin_file_path" ]]; then
    echo "$D"
    echo "     No file detected. Please enter your .bin file path"
    echo "$D"
    echo

    read -rp "File path: " bin_file_path
fi

# Remove all surrounding quote characters
bin_file_path="${bin_file_path//\"/}"
bin_file_path="${bin_file_path//\'/}"

source "$SCRIPT_DIR/validate_bin.sh" "$bin_file_path" nosize
if [[ "$VALIDATE_RESULT" != "OK" ]]; then
    echo -e "[${CL_R}FAIL${CL_NC}] $VALIDATE_MSG"
    exit 1
fi
bin_file="$BIN_FILE_NAME"
bin_file_path="$BIN_FILE_PATH"

echo
# Prompt confirmation
while true; do
    read -rp "Do you want to flash [$bin_file]? [Y/N]: " user_choice

    case "${user_choice,,}" in
        y|yes)
            break
            ;;
        n|no)
            echo
            echo "Flash cancelled by user."
            echo
            read -rp "Press ENTER to continue..."
            exit 0
            ;;
        *)
            echo
            echo "Invalid entry. Please type Y for Yes or N for No."
            echo
            ;;
    esac
done

if [[ "${RACE:-false}" == "true" ]]; then
    echo
    echo "$D"
    echo -e "   ${CL_M}Power-race slot0 flash (mode D)${CL_NC}"
    echo -e "   ${CL_M}Backup, then flash slot0 (2 catches)${CL_NC}"
    echo "$D"
    echo "   Stage 1 backs up current firmware."
    echo "   Stage 2 flashes slot0:"
    echo "       [$bin_file]"
    echo
    echo "$D"
    echo "   Stage 1/2: backup current firmware (dump.sh)"
    echo "$D"
    if [[ ! -f "$SCRIPT_DIR/dump.sh" ]]; then
        echo -e "[${CL_R}FAIL${CL_NC}] dump.sh not found - cannot back up. Aborting."
        exit 1
    fi
    bash "$SCRIPT_DIR/dump.sh"
    if [[ $? -ne 0 ]]; then
        echo
        echo -e "[${CL_R}FAIL${CL_NC}] Backup (dump.sh) failed - aborting flash for safety."
        exit 1
    fi

    echo
    echo "$D"
    echo "   Stage 2/2: flash slot0."
    echo "   Respawn until caught, then write+verify."
    echo "$D"
    echo "   Hammering connects."
    echo -e "   ${CL_C}Apply POWER now${CL_NC}; cut and re-apply on a miss."
    echo "   When symbols pause, it CAUGHT."
    echo "   Hold power steady; do NOT replug."
    echo "   Write/verify may be quiet for a few seconds."
    echo -e "   ${CL_C}Ctrl+C to stop.${CL_NC}"
    echo -e "   Live: .=searching  ${CL_Y}N${CL_NC}=noisy, hold steadier"
    echo -e "         ${CL_G}H${CL_NC}=almost    ${CL_R}x${CL_NC}=probe/USB gone"
    echo
    race_dbg_log="${TMPDIR:-/tmp}/x3utils_race_debug.log"
    race_last="${TMPDIR:-/tmp}/x3utils_race_last.log"
    if [[ "${RACE_DEBUG:-false}" == "true" ]]; then
        race_v="-d2"
    else
        race_v="-d0"
    fi
    race_tries=0
    while true; do
        race_tries=$((race_tries + 1))
        "$OPENOCD_BIN" $race_v -s "$SCRIPTS_DIR" -f "target/at32f415xx_race.cfg" \
            -c "race_connect" \
            -c "flash write_image erase {$bin_file_path} 0x08001000 bin" \
            -c "verify_image {$bin_file_path} 0x08001000 bin" \
            -c "exit" > "$race_last" 2>&1
        [[ $? -eq 0 ]] && break
        if [[ "${RACE_DEBUG:-false}" == "true" ]]; then
            { echo "=== slot0 attempt $race_tries ==="; cat "$race_last"; } >> "$race_dbg_log"
        fi
        bash "$SCRIPT_DIR/race_grade.sh" "$race_last"
    done
    echo
    echo
    echo -e "[ ${CL_G}CAUGHT${CL_NC} ] Slot0 flashed on attempt $race_tries - stages:"
    echo "$D"
    grep -Ei "halted|erase|wrote|verified" "$race_last" || true
    echo "$D"
    echo
    echo -e "[ ${CL_G}OK${CL_NC} ] Slot0 flashed and verified: $bin_file"
    echo "       Backup was taken by dump.sh above."
    echo
    read -rp "Press ENTER to continue..."
    echo
    exit 0
fi

echo
echo "$D"
echo "          Step 1: Invoking External Backup Script..."
echo "$D"
echo

if [[ -f "$SCRIPT_DIR/dump.sh" ]]; then
    bash "$SCRIPT_DIR/dump.sh"
else
    echo -e "[${CL_R}FAIL${CL_NC}] External component dump.sh was not found."
    exit 1
fi

# Catch backup script failure
if [[ $? -ne 0 ]]; then
    echo
    echo -e "[${CL_R}FAIL${CL_NC}] Backup script reported an error!"
    echo "       Aborting flash sequence for hardware safety."
    exit 1
fi

echo
echo "$D"
echo "        Step 2: Starting flash process via OpenOCD..."
echo "$D"
echo

# Run OpenOCD flash using relative configuration mappings
# Still no unlock operation.
# We assume the target is not read-protected.
# TCL curly brace quoting as a defensive measure against any special characters in the path.
#
# AT32 branch: erase/write/verify are wrapped inside do_flash_and_verify
# in the .cfg. Any failure there calls 'shutdown error' (exit code 1),
# which the errorlevel gate below catches. This keeps the interactive
# guided_flash_connect prompts on the live console (no redirect) while
# still failing hard on a mid-write link drop or verify mismatch.

# On success continue; on ANY failure offer a re-seat retry (safe to repeat:
# guided_flash_connect halts and write_image erase re-erases, so no half-write hazard).
# This retries the FLASH only - the successful backup above is not re-run.
while true; do
    if [[ "$TARGET" == "target/at32f415xx_c45.cfg" ]]; then
        "$OPENOCD_BIN" -s "$SCRIPTS_DIR" -d0 \
            -f "$TARGET" \
            -c "guided_flash_connect {$CONNECT_TIMEOUT}" \
            -c "do_flash_and_verify_slot0 {$bin_file_path}" \
            -c "exit"
    else
        "$OPENOCD_BIN" -s "$SCRIPTS_DIR" -d0 \
            -f "$INTERFACE" \
            -f "$TARGET" \
            -c "init" \
            -c "reset halt" \
            -c "flash write_image erase {$bin_file_path} 0x08001000 bin" \
            -c "verify_image {$bin_file_path} 0x08001000 bin" \
            -c "exit"
    fi

    # On success, continue past the retry loop
    [[ $? -eq 0 ]] && break

    echo
    echo -e "[${CL_Y}WARN${CL_NC}] OpenOCD failed - nothing was verified."
    echo "       Most often this is lost SWD / nRST-C45 contact mid-connect. Re-seat"
    echo "       the probe and the contact (touch the contact point, NOT on top of the"
    echo "       cap), keep it steady. Erase runs before write, so a retry is safe."
    echo
    read -rp "$(echo -e "${CL_C}Press ENTER to retry, or type Q to quit: ${CL_NC}")" retry_choice
    if [[ "${retry_choice,,}" == "q" ]]; then
        exit 1
    fi
    echo
done

echo
echo -e "[ ${CL_G}OK${CL_NC} ] Flashing completed and verified successfully!"
echo
echo
read -rp "Press ENTER to continue..."
echo
