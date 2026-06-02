#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load configuration settings
CONFIG_FILE="$SCRIPT_DIR/config.sh"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[FAIL] Missing config.sh"
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
        echo "[FAIL] Failed to create backup directory."
        exit 1
    }
fi

echo

# Timestamp generation
timestamp=$(date +"%Y-%m-%d_%H-%M-%S")

if [[ -z "$timestamp" ]]; then
    echo
    echo "[FAIL] Failed to generate timestamp."
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

"$OPENOCD_BIN" -s "$SCRIPTS_DIR" \
    -f "$INTERFACE" \
    -f "$TARGET" \
    -c "init" \
    -c "reset halt" \
    -c "flash probe 0" \
    -c "dump_image $dump_file 0x08000000 0x20000" \
    -c "exit"

# Ensure dump file exists
if [[ ! -f "$dump_file" ]]; then
    echo
    echo "[FAIL] Dump file was not created on disk."
    exit 1
fi

# Verify dump size integrity
dump_size=$(stat -f%z "$dump_file")

if [[ "$dump_size" != "$EXPECTED_SIZE" ]]; then
    echo
    echo "[FAIL] Memory dump integrity verification failed."
    echo "       Expected: $EXPECTED_SIZE bytes"
    echo "       Actual:   $dump_size bytes"
    exit 1
fi

echo
echo "[ OK ] Dump completed successfully!"
echo "[ OK ] Verified file size: $EXPECTED_SIZE bytes."
echo "[ OK ] Backup stored in:"
echo "       \"$dump_file\""

echo
read -rp "Press ENTER to continue..."
