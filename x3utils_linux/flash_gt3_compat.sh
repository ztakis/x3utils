#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load configuration settings
CONFIG_FILE="$SCRIPT_DIR/config.sh"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "[${CL_R}FAIL${CL_NC}] Missing config.sh"
    exit 1
fi

source "$CONFIG_FILE"

bin_file_path="$SCRIPT_DIR/special/gt3_vcu_v1.7.0.bin"

# Check file existence
if [[ ! -f "$bin_file_path" ]]; then
    echo -e "[${CL_R}FAIL${CL_NC}] File does not exist."
    exit 1
fi

bin_file=$(basename "$bin_file_path")

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
echo "======================================================="
echo "      Step 1: Invoking External Backup Script..."
echo "======================================================="
echo

if [[ ! -f "$SCRIPT_DIR/dump.sh" ]]; then
    echo -e "[${CL_R}FAIL${CL_NC}] External component dump.sh was not found."
    exit 1
fi

if ! bash "$SCRIPT_DIR/dump.sh"; then
    echo -e "[${CL_R}FAIL${CL_NC}] Backup script reported an error!"
    exit 1
fi

echo
echo "======================================================="
echo "     Step 2: Starting flash process via OpenOCD..."
echo "======================================================="
echo

# Run OpenOCD flash using relative configuration mappings
# Still no unlock operation.
# We assume the target is not read-protected.

if [[ "$TARGET" == "target/at32f415xx_c45.cfg" ]]; then
    "$OPENOCD_BIN" -s "$SCRIPTS_DIR" -d0 \
        -f "$TARGET" \
        -c "guided_flash_connect {$CONNECT_TIMEOUT}" \
        -c "flash write_image erase {$bin_file_path} 0x08001000 bin" \
        -c "verify_image {$bin_file_path} 0x08001000 bin" \
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
