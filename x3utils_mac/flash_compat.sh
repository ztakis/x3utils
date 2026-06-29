#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load configuration settings
CONFIG_FILE="$SCRIPT_DIR/config.sh"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "[${CL_R}FAIL${CL_NC}] Missing config.sh"
    exit 1
fi

source "$CONFIG_FILE"

# Prompt user confirmation
while true; do
    read -rp "Do you want to flash SHU compatible? [Y/N]: " user_choice
    user_choice_lc="$(echo "$user_choice" | tr '[:upper:]' '[:lower:]')"

    case "${user_choice_lc}" in
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

# Set up compat directory
compat_dir="$SCRIPT_DIR/compat"

if [[ ! -d "$compat_dir" ]]; then
    mkdir -p "$compat_dir" || {
        echo
        echo -e "[${CL_R}FAIL${CL_NC}] Failed to create compat directory."
        exit 1
    }
fi

# Timestamp generation
timestamp=$(date +"%Y-%m-%d_%H-%M-%S")

if [[ -z "$timestamp" ]]; then
    echo
    echo -e "[${CL_R}FAIL${CL_NC}] Failed to generate timestamp."
    exit 1
fi

# Build file paths
raw_dump="$compat_dir/dump_${timestamp}.bin"
patched_dump="$compat_dir/dump_${timestamp}_patched.bin"

echo
echo "======================================================="
echo "           Step 1: Dumping Current Memory"
echo "======================================================="
echo
echo "Output File:"
echo "       \"$raw_dump\""
echo

# IMPORTANT:
# No unlock operation during dump phase.
# If the target is read-protected, dumping should fail
# safely without erasing firmware contents.

if [[ "$TARGET" == "target/artery/at32f4x_c45.cfg" ]]; then
    "$OPENOCD_BIN" -s "$SCRIPTS_DIR" -d0 \
        -f "$TARGET" \
        -c "guided_connect {$CONNECT_TIMEOUT}" \
        -c "dump_image {$raw_dump} 0x08000000 0x20000" \
        -c "exit"
else
    "$OPENOCD_BIN" -s "$SCRIPTS_DIR" -d0 \
        -f "$INTERFACE" \
        -f "$TARGET" \
        -c "init" \
        -c "reset halt" \
        -c "flash probe 0" \
        -c "dump_image {$raw_dump} 0x08000000 0x20000" \
        -c "exit"
fi

if [[ $? -ne 0 ]]; then
    echo
    echo -e "[${CL_R}FAIL${CL_NC}] OpenOCD failed during memory dump."
    echo "Check:"
    echo "       ST-Link connection"
    echo "       Board power"
    echo "       Read protection state"
    exit 1
fi

# Ensure dump exists
if [[ ! -f "$raw_dump" ]]; then
    echo
    echo -e "[${CL_R}FAIL${CL_NC}] Raw dump file was not created."
    exit 1
fi

# Verify raw dump size
dump_size=$(stat -f%z "$raw_dump")

if [[ "$dump_size" != "$EXPECTED_SIZE" ]]; then
    echo
    echo -e "[${CL_R}FAIL${CL_NC}] Raw dump integrity verification failed."
    echo "       Expected: $EXPECTED_SIZE bytes"
    echo "       Actual:   $dump_size bytes"
    exit 1
fi

# Ensure dump file is not all the same byte value
unique_bytes=$(od -An -tx1 "$raw_dump" | tr -s ' \n' '\n' | grep -E '^[0-9a-f]{2}$' | sort -u | wc -l)

if [ "$unique_bytes" -eq 1 ]; then
    echo
    echo -e "[${CL_R}FAIL${CL_NC}] Dump file contains only a single repeated byte value."
    echo "       nRST was not released correctly during step 2."
    echo "       Please try again."
    exit 1
fi

echo
echo -e "[ ${CL_G}OK${CL_NC} ] Raw dump verified successfully."

mkdir -p "$HOME/Library/Application Support/x3utils_backup"
cp "$raw_dump" "$HOME/Library/Application Support/x3utils_backup/dump_${timestamp}.bin"
echo -e "[ ${CL_G}OK${CL_NC} ] Secondary backup stored in:"
echo "       \"$HOME/Library/Application Support/x3utils_backup/dump_${timestamp}.bin\""
echo

read -rp "Press ENTER to continue..."

echo
echo "======================================================="
echo "         Step 2: Injecting Patch Sequence"
echo "======================================================="
echo

python3 <<EOF
from pathlib import Path
import sys

raw_path = Path(r"$raw_dump")
patched_path = Path(r"$patched_dump")

try:
    data = bytearray(raw_path.read_bytes())

    patch = bytes.fromhex(
        "FE801CB2D1EF41A6A41731F5A06824F0"
    )

    offset = 0x1420

    data[offset:offset + len(patch)] = patch

    # Verification
    if data[offset:offset + len(patch)] != patch:
        sys.exit(1)

    patched_path.write_bytes(data)

except Exception:
    sys.exit(1)
EOF

if [[ $? -ne 0 ]]; then
    echo
    echo -e "[${CL_R}FAIL${CL_NC}] Binary patch process failed."
    exit 1
fi

# Ensure patched file exists
if [[ ! -f "$patched_dump" ]]; then
    echo
    echo -e "[${CL_R}FAIL${CL_NC}] Patched dump file was not created."
    exit 1
fi

# Verify patched file size
patched_size=$(stat -f%z "$patched_dump")

if [[ "$patched_size" != "$EXPECTED_SIZE" ]]; then
    echo
    echo -e "[${CL_R}FAIL${CL_NC}] Patched binary integrity verification failed."
    echo "       Expected: $EXPECTED_SIZE bytes"
    echo "       Actual:   $patched_size bytes"
    exit 1
fi

echo -e "[ ${CL_G}OK${CL_NC} ] Patch injection completed successfully."
echo
read -rp "Press ENTER to continue..."

echo
echo "======================================================="
echo "         Step 3: Flashing Modified Firmware"
echo "======================================================="
echo

# Run OpenOCD flash using relative configuration mappings
# Still no unlock operation.
# We assume the target is not read-protected.

if [[ "$TARGET" == "target/artery/at32f4x_c45.cfg" ]]; then
    "$OPENOCD_BIN" -s "$SCRIPTS_DIR" -d0 \
        -f "$TARGET" \
        -c "guided_flash_connect {$CONNECT_TIMEOUT}" \
        -c "do_flash_and_verify {$patched_dump}" \
        -c "exit"
else
    "$OPENOCD_BIN" -s "$SCRIPTS_DIR" -d0 \
        -f "$INTERFACE" \
        -f "$TARGET" \
        -c "init" \
        -c "reset halt" \
        -c "flash erase_address 0x08000000 0x20000" \
        -c "flash write_bank 0 {$patched_dump}" \
        -c "verify_image {$patched_dump} 0x08000000" \
        -c "exit"
fi

if [[ $? -ne 0 ]]; then
    echo
    echo -e "[${CL_R}FAIL${CL_NC}] OpenOCD failed during flashing."
    echo "Check:"
    echo "       ST-Link connection"
    echo "       Board power"
    echo "       Flash protection state"
    exit 1
fi

echo
echo
echo -e "[ ${CL_G}OK${CL_NC} ] Flashing completed successfully!"
echo
echo
read -rp "Press ENTER to continue..."
echo
