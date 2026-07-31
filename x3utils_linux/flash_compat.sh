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
echo -e "${CL_R}ATTENTION${CL_NC}"
echo "SHU compat cannot be used with recent VCU firmware."
echo "Only continue if your installed firmware is older than:"
echo
echo "  F3 VCU  1.6.3"
echo "  G3 VCU  1.6.3"
echo "  ZT3 VCU 1.5.9"
echo "  GT3 VCU 1.7.2 - for reference only:"
echo "  x3utils does not support SHU compatible on GT3 at any version"
echo
echo "Continuing will be enabled in 5 seconds..."
sleep 5
echo

# Prompt user confirmation
while true; do
    read -rp "I understand. Continue with SHU-compatible flash? [Y/N]: " user_choice

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
    compat_dir="$SCRIPT_DIR/compat"
    mkdir -p "$compat_dir" || {
        echo
        echo -e "[${CL_R}FAIL${CL_NC}] Failed to create compat directory."
        exit 1
    }

    timestamp=$(date +"%Y-%m-%d_%H-%M-%S")
    if [[ -z "$timestamp" ]]; then
        echo
        echo -e "[${CL_R}FAIL${CL_NC}] Failed to generate timestamp."
        exit 1
    fi

    raw_dump="$compat_dir/dump_${timestamp}.bin"
    patched_dump="$compat_dir/dump_${timestamp}_patched.bin"

    echo
    echo "$D"
    echo -e "   ${CL_M}SHU-compat power-race (mode D)${CL_NC}"
    echo -e "   ${CL_M}2 catches: dump, then flash${CL_NC}"
    echo "$D"
    echo "   You'll catch the window TWICE:"
    echo "   1. read the current firmware"
    echo "   2. flash the patched version"
    echo -e "   ${CL_C}Ctrl+C to stop.${CL_NC}"
    echo -e "   Live: .=searching  ${CL_Y}N${CL_NC}=noisy, hold steadier"
    echo -e "         ${CL_G}H${CL_NC}=almost    ${CL_R}x${CL_NC}=probe/USB gone"
    echo

    race_dbg_log="${TMPDIR:-/tmp}/x3utils_race_debug.log"
    race_last="${TMPDIR:-/tmp}/x3utils_race_last.log"
    if [[ "${RACE_DEBUG:-false}" == "true" ]]; then
        rm -f "$race_dbg_log"
        race_v="-d2"
    else
        race_v="-d0"
    fi

    echo "$D"
    echo "   Stage 1/3: catch + dump current firmware."
    echo -e "   ${CL_C}Apply POWER now...${CL_NC}"
    echo "$D"
    race_tries=0
    while true; do
        race_tries=$((race_tries + 1))
        "$OPENOCD_BIN" $race_v -s "$SCRIPTS_DIR" -f "target/at32f415xx_race.cfg" \
            -c "race_connect" \
            -c "dump_image {$raw_dump} 0x08000000 0x20000" \
            -c "exit" > "$race_last" 2>&1
        [[ $? -eq 0 ]] && break
        if [[ "${RACE_DEBUG:-false}" == "true" ]]; then
            { echo "=== dump attempt $race_tries ==="; cat "$race_last"; } >> "$race_dbg_log"
        fi
        bash "$SCRIPT_DIR/race_grade.sh" "$race_last"
    done
    echo
    echo
    echo -e "[ ${CL_G}CAUGHT${CL_NC} ] Firmware dumped on attempt $race_tries."

    source "$SCRIPT_DIR/validate_bin.sh" "$raw_dump"
    if [[ "$VALIDATE_RESULT" != "OK" ]]; then
        echo -e "[${CL_R}FAIL${CL_NC}] $VALIDATE_MSG"
        echo "       Cannot patch what we cannot read (read-protected?). Aborting."
        exit 1
    fi
    echo -e "[ ${CL_G}OK${CL_NC} ] Current firmware read + verified: \"$raw_dump\""

    echo
    echo "$D"
    echo "   Stage 2/3: injecting SHU patch (no hardware)"
    echo "$D"

    python3 <<EOF
from pathlib import Path
import sys

raw_path = Path(r"$raw_dump")
patched_path = Path(r"$patched_dump")

try:
    data = bytearray(raw_path.read_bytes())
    patch = bytes.fromhex("FE801CB2D1EF41A6A41731F5A06824F0")
    offset = 0x1420
    data[offset:offset + len(patch)] = patch
    if data[offset:offset + len(patch)] != patch:
        sys.exit(1)
    patched_path.write_bytes(data)
except Exception:
    sys.exit(1)
EOF

    if [[ $? -ne 0 ]]; then
        echo -e "[${CL_R}FAIL${CL_NC}] Binary patch process failed."
        exit 1
    fi

    source "$SCRIPT_DIR/validate_bin.sh" "$patched_dump"
    if [[ "$VALIDATE_RESULT" != "OK" ]]; then
        echo -e "[${CL_R}FAIL${CL_NC}] $VALIDATE_MSG"
        exit 1
    fi
    echo -e "[ ${CL_G}OK${CL_NC} ] Patched image ready: \"$patched_dump\""

    echo
    echo "$D"
    echo "   Stage 3/3: catch + flash patched firmware."
    echo -e "   ${CL_C}Keep POWER on; waiting for the flash catch...${CL_NC}"
    echo "   Once caught, hold power steady and do NOT replug."
    echo "$D"
    race_tries=0
    while true; do
        race_tries=$((race_tries + 1))
        "$OPENOCD_BIN" $race_v -s "$SCRIPTS_DIR" -f "target/at32f415xx_race.cfg" \
            -c "race_connect" \
            -c "flash erase_address 0x08000000 0x20000" \
            -c "flash write_bank 0 {$patched_dump}" \
            -c "verify_image {$patched_dump} 0x08000000" \
            -c "exit" > "$race_last" 2>&1
        [[ $? -eq 0 ]] && break
        if [[ "${RACE_DEBUG:-false}" == "true" ]]; then
            { echo "=== flash attempt $race_tries ==="; cat "$race_last"; } >> "$race_dbg_log"
        fi
        bash "$SCRIPT_DIR/race_grade.sh" "$race_last"
    done
    echo
    echo
    echo -e "[ ${CL_G}CAUGHT${CL_NC} ] Patched firmware flashed + verified on attempt $race_tries."
    echo -e "[ ${CL_G}OK${CL_NC} ] SHU-compat complete. Original firmware backed up:"
    echo "       \"$raw_dump\""
    echo
    read -rp "Press ENTER to continue..."
    echo
    exit 0
fi

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
echo "$D"
echo "              Step 1: Dumping Current Memory"
echo "$D"
echo
echo "Output File:"
echo "       \"$raw_dump\""
echo

# IMPORTANT:
# No unlock operation during dump phase.
# If the target is read-protected, dumping should fail
# safely without erasing firmware contents.

# On success continue; on ANY failure offer a re-seat retry (read-only, always safe).
while true; do
    if [[ "$TARGET" == "target/at32f415xx_c45.cfg" ]]; then
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

    # On success, continue past the retry loop
    [[ $? -eq 0 ]] && break

    echo
    echo -e "[${CL_Y}WARN${CL_NC}] OpenOCD could not read the chip - nothing was changed."
    echo "       Most often this is lost SWD / nRST-C45 contact mid-connect. Re-seat the"
    echo "       probe and the contact (touch the contact point, NOT on top of the cap),"
    echo "       keep it steady. (A read-protected chip will keep failing - then press Q.)"
    echo
    read -rp "$(echo -e "${CL_C}Press ENTER to retry, or type Q to quit: ${CL_NC}")" retry_choice
    if [[ "${retry_choice,,}" == "q" ]]; then
        exit 1
    fi
    echo
done

# Validate bin file
source "$SCRIPT_DIR/validate_bin.sh" "$raw_dump"
if [[ "$VALIDATE_RESULT" != "OK" ]]; then
    echo -e "[${CL_R}FAIL${CL_NC}] $VALIDATE_MSG"
    read -rp "Aborting..."
    exit 1
fi

echo
echo -e "[ ${CL_G}OK${CL_NC} ] Raw dump verified successfully."

mkdir -p "$HOME/.x3utils_backup"
cp "$raw_dump" "$HOME/.x3utils_backup/dump_${timestamp}.bin"
echo -e "[ ${CL_G}OK${CL_NC} ] Secondary backup stored in:"
echo "       \"$HOME/.x3utils_backup/dump_${timestamp}.bin\""
echo

read -rp "Press ENTER to continue..."

echo
echo "$D"
echo "              Step 2: Injecting Patch Sequence"
echo "$D"
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
patched_size=$(stat -c%s "$patched_dump")

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
echo "$D"
echo "             Step 3: Flashing Modified Firmware"
echo "$D"
echo

# Run OpenOCD flash using relative configuration mappings
# Still no unlock operation.
# We assume the target is not read-protected.

# On success continue; on ANY failure offer a re-seat retry (safe to repeat:
# guided_flash_connect halts and erase precedes write, so no half-write hazard).
# This retries the FLASH only - the dump/patch above are not re-run.
while true; do
    if [[ "$TARGET" == "target/at32f415xx_c45.cfg" ]]; then
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
echo -e "[ ${CL_G}OK${CL_NC} ] Flashing completed successfully!"
echo
echo
read -rp "Press ENTER to continue..."
echo
