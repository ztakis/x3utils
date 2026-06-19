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

# Ensure dump file exists
if [[ ! -f "$dump_file" ]]; then
    echo
    echo -e "[${CL_R}FAIL${CL_NC}] Dump file was not created on disk."
    exit 1
fi

# Verify dump size integrity
dump_size=$(stat -c%s "$dump_file")

if [[ "$dump_size" != "$EXPECTED_SIZE" ]]; then
    echo
    echo -e "[${CL_R}FAIL${CL_NC}] Memory dump integrity verification failed."
    echo "       Expected: $EXPECTED_SIZE bytes"
    echo "       Actual:   $dump_size bytes"
    exit 1
fi

# Ensure dump file is not all the same byte value
unique_bytes=$(od -An -tx1 "$dump_file" | tr -s ' \n' '\n' | grep -E '^[0-9a-f]{2}$' | sort -u | wc -l)

if [ "$unique_bytes" -eq 1 ]; then
    echo
    echo -e "[${CL_R}FAIL${CL_NC}] Dump file contains only a single repeated byte value."
    echo "       nRST was not released correctly during step 2."
    echo "       Please try again."
    exit 1
fi

# --- Header sanity check (ARM Cortex-M vector table @ 0x08000000) ---
sp_bytes=$(dd if="$dump_file" bs=1 skip=0 count=4 2>/dev/null | od -An -v -tx1 | tr -d ' \n')
pc_bytes=$(dd if="$dump_file" bs=1 skip=4 count=4 2>/dev/null | od -An -v -tx1 | tr -d ' \n')

# Convert little-endian hex to integer
sp_val=$(( 0x${sp_bytes:6:2}${sp_bytes:4:2}${sp_bytes:2:2}${sp_bytes:0:2} ))
pc_val=$(( 0x${pc_bytes:6:2}${pc_bytes:4:2}${pc_bytes:2:2}${pc_bytes:0:2} ))

SRAM_START=$((0x20000000))
SRAM_END=$((0x20008000))     # AT32F415CBT7: 32 KB SRAM
FLASH_START=$((0x08000000))
FLASH_END=$((0x08020000))    # AT32F415CBT7: 128 KB flash

header_valid=1

if (( sp_val < SRAM_START || sp_val >= SRAM_END )); then
    header_valid=0
fi

if (( pc_val < FLASH_START || pc_val >= FLASH_END )); then
    header_valid=0
fi

if (( (pc_val & 1) == 0 )); then
    header_valid=0
fi

if [[ "$header_valid" -eq 0 ]]; then
    echo
    echo -e "[${CL_R}FAIL${CL_NC}] Invalid vector table header."
    echo "       Stack pointer: 0x$(printf '%08x' "$sp_val")"
    echo "       Reset vector:  0x$(printf '%08x' "$pc_val")"
    echo "       This does not look like valid firmware."
    exit 1
fi

# --- Percentage-based dominant byte check (fallback safety net) ---
total_bytes=$(stat -c%s "$dump_file")
dominant_count=$(od -An -v -tx1 "$dump_file" | tr -s ' \n' '\n' | grep -E '^[0-9a-f]{2}$' | sort | uniq -c | sort -rn | head -1 | awk '{print $1}')
dominant_pct=$(( dominant_count * 100 / total_bytes ))

if (( dominant_pct >= 95 )); then
    echo
    echo -e "[${CL_R}FAIL${CL_NC}] Suspicious dump: ${dominant_pct}% of bytes are identical."
    echo "       This dump looks blank or corrupted."
    exit 1
fi

echo
echo -e "[ ${CL_G}OK${CL_NC} ] Dump completed successfully!"
echo -e "[ ${CL_G}OK${CL_NC} ] Verified file size: $EXPECTED_SIZE bytes."
echo -e "[ ${CL_G}OK${CL_NC} ] Backup stored in:"
echo "       \"$dump_file\""

echo
read -rp "Press ENTER to continue..."
