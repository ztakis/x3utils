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

source "$SCRIPT_DIR/../validate_bin.sh" "$bin_file_path" nosize
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
echo "$D"
echo "          Step 1: Invoking External Backup Script..."
echo "$D"
echo

if [[ -f "$SCRIPT_DIR/../dump.sh" ]]; then
    bash "$SCRIPT_DIR/../dump.sh"
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

# Check OpenOCD result
if [[ $? -ne 0 ]]; then
    echo
    echo -e "[${CL_R}FAIL${CL_NC}] OpenOCD failed during flashing."
    echo "       Check hardware connections."
    exit 1
fi

echo
echo -e "[ ${CL_G}OK${CL_NC} ] Flashing completed and verified successfully!"
echo
echo
read -rp "Press ENTER to continue..."
echo
