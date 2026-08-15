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
echo "$D"
echo "           Press ENTER to dump current chip data"
echo "                  to your backup folder."
echo "$D"
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

# Mode D: power-race respawn dump. Skips the single-connect path below.
if [[ "${RACE:-false}" == "true" ]]; then
    echo "$D"
    echo -e "   ${CL_M}Power-race dump (mode D) - respawn, read-only${CL_NC}"
    echo "$D"
    echo "   Hammering connects."
    echo -e "   ${CL_C}Apply POWER now${CL_NC}; if it misses, cut and"
    echo "   re-apply POWER. Each power-ON is a fresh window."
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
    race_tries=0
    while true; do
        race_tries=$((race_tries + 1))
        "$OPENOCD_BIN" $race_v -s "$SCRIPTS_DIR" -f "target/artery/at32f4x_race.cfg" \
            -c "race_connect" \
            -c "dump_image {$dump_file} 0x08000000 0x20000" \
            -c "exit" > "$race_last" 2>&1
        [[ $? -eq 0 ]] && break
        if [[ "${RACE_DEBUG:-false}" == "true" ]]; then
            { echo "=== attempt $race_tries ==="; cat "$race_last"; } >> "$race_dbg_log"
        fi
        bash "$SCRIPT_DIR/race_grade.sh" "$race_last"
    done
    echo
    echo
    echo -e "[ ${CL_G}CAUGHT${CL_NC} ] Connected + dumped on attempt $race_tries."
else
echo "$D"
echo "             Executing Full 128 KB Memory Dump..."
echo "$D"
echo

# IMPORTANT:
# No unlock operation during dump phase.
# If the target is read-protected, dumping should fail
# safely without erasing firmware contents.

# On success continue; on ANY failure offer a re-seat retry (read-only, always safe).
while true; do
    if [[ "$TARGET" == "target/artery/at32f4x_c45.cfg" ]]; then
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

    # On success, continue past the retry loop
    [[ $? -eq 0 ]] && break

    echo
    echo -e "[${CL_Y}WARN${CL_NC}] OpenOCD could not read the chip - nothing was changed."
    echo "       Most often this is lost SWD / nRST-C45 contact mid-connect. Re-seat the"
    echo "       probe and the contact (touch the contact point, NOT on top of the cap),"
    echo "       keep it steady. (A read-protected chip will keep failing - then press Q.)"
    echo
    read -rp "$(echo -e "${CL_C}Press ENTER to retry, or type Q to quit: ${CL_NC}")" retry_choice
    retry_choice_lc="$(echo "$retry_choice" | tr '[:upper:]' '[:lower:]')"
    if [[ "$retry_choice_lc" == "q" ]]; then
        exit 1
    fi
    echo
done
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

mkdir -p "$HOME/Library/Application Support/x3utils_backup"
cp "$dump_file" "$HOME/Library/Application Support/x3utils_backup/dump_${timestamp}.bin"
echo -e "[ ${CL_G}OK${CL_NC} ] Secondary backup stored in:"
echo "       \"$HOME/Library/Application Support/x3utils_backup/dump_${timestamp}.bin\""

echo
read -rp "Press ENTER to continue..."
