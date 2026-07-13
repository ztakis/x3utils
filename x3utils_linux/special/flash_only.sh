#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load configuration settings
CONFIG_FILE="$SCRIPT_DIR/../config.sh"

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

source "$SCRIPT_DIR/../validate_bin.sh" "$bin_file_path"
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
echo

if [[ "${RACE:-false}" == "true" ]]; then
    echo
    echo "$D"
    echo -e "   ${CL_M}Power-race flash-only (mode D) - respawn erase+write+verify, no backup${CL_NC}"
    echo "$D"
    echo -e "   Hammering connects. ${CL_C}Apply POWER now${CL_NC}; cut and re-apply POWER on a miss."
    echo -e "   When the symbols pause it CAUGHT and is flashing [$bin_file] - ~5s quiet is"
    echo -e "   normal. ${CL_C}Do NOT replug mid-flash${CL_NC}: a stalled write fails and retries by"
    echo -e "   itself, and erase precedes write so a retry is safe. ${CL_C}Ctrl+C to stop.${CL_NC}"
    echo -e "   Live: .=searching  ${CL_Y}N${CL_NC}=noisy, hold steadier  ${CL_G}H${CL_NC}=almost  ${CL_R}x${CL_NC}=probe/USB gone"
    echo
    race_dbg_log="${TMPDIR:-/tmp}/x3utils_race_debug.log"
    race_last="${TMPDIR:-/tmp}/x3utils_race_last.log"
    if [[ "${RACE_DEBUG:-false}" == "true" ]]; then
        rm -f "$race_dbg_log"
        race_v="-d2"
    else
        race_v="-d0"
    fi
    race_tries=0
    while true; do
        race_tries=$((race_tries + 1))
        "$OPENOCD_BIN" $race_v -s "$SCRIPTS_DIR" -f "target/at32f415xx_race.cfg" \
            -c "race_connect" \
            -c "flash erase_address 0x08000000 0x20000" \
            -c "flash write_bank 0 {$bin_file_path}" \
            -c "verify_image {$bin_file_path} 0x08000000" \
            -c "exit" > "$race_last" 2>&1
        [[ $? -eq 0 ]] && break
        if [[ "${RACE_DEBUG:-false}" == "true" ]]; then
            { echo "=== flash attempt $race_tries ==="; cat "$race_last"; } >> "$race_dbg_log"
        fi
        bash "$SCRIPT_DIR/../race_grade.sh" "$race_last"
    done
    echo
    echo
    echo -e "[ ${CL_G}CAUGHT${CL_NC} ] Flashed on attempt $race_tries - stages:"
    echo "$D"
    grep -Ei "halted|erased|wrote|verified" "$race_last" || true
    echo "$D"
    echo
    echo -e "[ ${CL_G}OK${CL_NC} ] Flashed and verified: $bin_file"
    echo
    read -rp "Press ENTER to continue..."
    echo
    exit 0
fi

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

# Wrapped in a re-seat-and-retry loop: the #1 field failure is losing the
# hand-held SWD / nRST-C45 contact mid-connect, not logic. guided_flash_connect
# halts before flashing and do_flash_and_verify ERASES before it writes, so
# re-running a failed attempt is idempotent - there is no half-write hazard.
while true; do
    if [[ "$TARGET" == "target/at32f415xx_c45.cfg" ]]; then
        "$OPENOCD_BIN" -s "$SCRIPTS_DIR" -d0 \
            -f "$TARGET" \
            -c "guided_flash_connect {$CONNECT_TIMEOUT}" \
            -c "do_flash_and_verify {$bin_file_path}" \
            -c "exit"
    else
        "$OPENOCD_BIN" -s "$SCRIPTS_DIR" -d0 \
            -f "$INTERFACE" \
            -f "$TARGET" \
            -c "init" \
            -c "reset halt" \
            -c "flash erase_address 0x08000000 0x20000" \
            -c "flash write_bank 0 {$bin_file_path}" \
            -c "verify_image {$bin_file_path} 0x08000000" \
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
