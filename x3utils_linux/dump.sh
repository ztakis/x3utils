#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load configuration settings
CONFIG_FILE="$SCRIPT_DIR/config.sh"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "[${CL_R}FAIL${CL_NC}] Missing config.sh"
    exit 1
fi

source "$CONFIG_FILE"

echo
echo "======================================================="
echo "        Press ENTER to dump current chip data"
echo "              to your backup folder."
echo "======================================================="
echo

read -rp ""

# Set up backup directory
backup_dir="$SCRIPT_DIR/backup"

if [[ ! -d "$backup_dir" ]]; then
    mkdir -p "$backup_dir" || {
        echo
        echo -e "[${CL_R}FAIL${CL_NC}] Failed to create backup directory."
        exit 1
    }
fi

echo

# Timestamp generation
timestamp=$(date +"%Y-%m-%d_%H-%M-%S")

if [[ -z "$timestamp" ]]; then
    echo
    echo -e "[${CL_R}FAIL${CL_NC}] Failed to generate timestamp."
    exit 1
fi

# Final dump path
dump_file="$backup_dir/dump_${timestamp}.bin"

echo "Output File:"
echo "       \"$dump_file\""
echo

echo "======================================================="
echo "        Executing Full 128 KB Memory Dump..."
echo "======================================================="
echo

# IMPORTANT:
# No unlock operation during dump phase.
# If the target is read-protected, dumping should fail
# safely without erasing firmware contents.

if [[ "$TARGET" == "target/at32f415xx_c45.cfg" ]]; then
    "$OPENOCD_BIN" -s "$SCRIPTS_DIR" -d0 \
        -f "$TARGET" \
        -c "guided_connect {$CONNECT_TIMEOUT}" \
        -c "dump_image {$dump_file} 0x08000000 0x20000" \
        -c "exit"
else
    "$OPENOCD_BIN" -s "$SCRIPTS_DIR" -d0 \
        -f "$INTERFACE" \
        -f "$TARGET" \
        -c "init" \
        -c "reset halt" \
		-c "flash probe 0" \
        -c "dump_image {$dump_file} 0x08000000 0x20000" \
        -c "exit"
fi

# Validate bin file
source "$SCRIPT_DIR/validate_bin.sh" "$dump_file"
if [[ "$VALIDATE_RESULT" != "OK" ]]; then
    echo -e "[${CL_R}FAIL${CL_NC}] $VALIDATE_MSG"
    read -rp "Aborting..."
    exit 1
fi

echo
echo -e "[ ${CL_G}OK${CL_NC} ] Dump completed successfully!"
echo -e "[ ${CL_G}OK${CL_NC} ] Verified file size: $EXPECTED_SIZE bytes."
echo -e "[ ${CL_G}OK${CL_NC} ] Backup stored in:"
echo "       \"$dump_file\""

mkdir -p "$HOME/.x3utils_backup"
cp "$dump_file" "$HOME/.x3utils_backup/dump_${timestamp}.bin"
echo -e "[ ${CL_G}OK${CL_NC} ] Secondary backup stored in:"
echo "       \"$HOME/.x3utils_backup/dump_${timestamp}.bin\""

echo
read -rp "Press ENTER to continue..."
