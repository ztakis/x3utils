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
    echo "======================================================="
    echo "  No file detected. Please enter your .bin file path"
    echo "======================================================="
    echo

    read -rp "File path: " bin_file_path
fi

# Remove all surrounding quote characters
bin_file_path="${bin_file_path//\"/}"
bin_file_path="${bin_file_path//\'/}"

# Resolve full path
bin_file_path="$(realpath "$bin_file_path" 2>/dev/null)"

# Check if path is empty
if [[ -z "$bin_file_path" ]]; then
    echo -e "[${CL_R}FAIL${CL_NC}] No file provided."
    exit 1
fi

# Check file existence
if [[ ! -f "$bin_file_path" ]]; then
    echo -e "[${CL_R}FAIL${CL_NC}] File does not exist."
    exit 1
fi

# Reject unsupported characters in user-supplied path
if [[ "$bin_file_path" =~ [{}] ]]; then
    echo -e "[${CL_R}FAIL${CL_NC}] Path contains unsupported character: { or }"
    echo "       Please rename."
    exit 1
fi

# Validate extension
extension="${bin_file_path##*.}"
extension="$(echo "$extension" | tr '[:upper:]' '[:lower:]')"

if [[ "$extension" != "bin" ]]; then
    echo -e "[${CL_R}FAIL${CL_NC}] Invalid file type .$extension, only .bin is allowed."
    exit 1
fi

# Get file size and name
bin_file_size=$(stat -f%z "$bin_file_path")
bin_file=$(basename "$bin_file_path")

# Validate exact size
if [[ "$bin_file_size" != "$EXPECTED_SIZE" ]]; then
    echo -e "[${CL_R}FAIL${CL_NC}] Invalid file size."
    echo "       Expected: $EXPECTED_SIZE bytes"
    echo "       Got:      $bin_file_size bytes"
    exit 1
fi

# Ensure bin file is not all the same byte value
unique_bytes=$(od -An -tx1 "$bin_file_path" | tr -s ' \n' '\n' | grep -E '^[0-9a-f]{2}$' | sort -u | wc -l)

if [ "$unique_bytes" -eq 1 ]; then
    echo
    echo -e "[${CL_R}FAIL${CL_NC}] Bin file contains only a single repeated byte value."
    echo "       Please try again."
    exit 1
fi

echo
# Prompt confirmation
while true; do
    read -rp "Do you want to flash [$bin_file]? [Y/N]: " user_choice
    user_choice_lc="$(echo "$user_choice" | tr '[:upper:]' '[:lower:]')"

    case "$user_choice_lc" in
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
echo "======================================================="
echo "     Step 2: Starting flash process via OpenOCD..."
echo "======================================================="
echo

# Run OpenOCD flash using relative configuration mappings
# Still no unlock operation.
# We assume the target is not read-protected.
# TCL curly brace quoting as a defensive measure against any special characters in the path.

if [[ "$TARGET" == "target/artery/at32f4x_c45.cfg" ]]; then
    "$OPENOCD_BIN" -s "$SCRIPTS_DIR" -d0 \
        -f "$TARGET" \
        -c "guided_flash_connect {$CONNECT_TIMEOUT}" \
        -c "flash erase_address 0x08000000 0x20000" \
        -c "flash write_bank 0 {$bin_file_path}" \
        -c "verify_image {$bin_file_path} 0x08000000" \
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

# Check OpenOCD result
if [[ $? -ne 0 ]]; then
    echo
    echo -e "[${CL_R}FAIL${CL_NC}] OpenOCD failed during flashing."
    echo "       Check hardware connections."
    exit 1
fi

echo
echo
echo -e "[ ${CL_G}OK${CL_NC} ] Flashing completed and verified successfully!"
echo
echo
read -rp "Press ENTER to continue..."
echo
