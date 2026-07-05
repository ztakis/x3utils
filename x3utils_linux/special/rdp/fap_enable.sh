#!/bin/bash
#
# fap_enable.sh — TESTBED ONLY: turn AT32F415 read protection (FAP) ON.
#
# Purpose: this build's OpenOCD at32f4xx driver can only DISABLE access
# protection, not enable it. To validate the "READ PROTECTED" branch of
# rdp_check.sh we need a way to actually set FAP on a sacrificial part.
#
# It does so by programming the FAP option byte to a non-0xA5 value using
# raw flash-controller register writes (the STM32F1-compatible AT32F415
# flash controller at 0x40022000, option/USD area at 0x1FFFF800).
#
# !!! DESTRUCTIVE — DO NOT run on a board you care about !!!
#   - It erases the option bytes and enables read protection.
#   - Protection latches only after a power cycle / pin reset.
#   - Recover with:  at32f4xx disable_access_protection 0  (mass-erases flash)
#
# AT32 FAP has no permanent-lock state, so a protected part is always
# recoverable via the disable command above (unlike STM32F4 RDP level 2).
#
# Usage: ./fap_enable.sh [--yes]
#   --yes   skip the interactive confirmation

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../../config.sh"
[[ -f "$CONFIG_FILE" ]] || { echo "[FAIL] Missing config.sh"; exit 1; }
source "$CONFIG_FILE"

TEST_TARGET="target/at32f415xx.cfg"
LOG_DIR="$SCRIPT_DIR/../../backup"
RUN_ID="$(date +"%Y-%m-%d_%H-%M-%S")"
LOG_FILE="$LOG_DIR/fap_enable_${RUN_ID}.log"
mkdir -p "$LOG_DIR" || { echo -e "[${CL_R}FAIL${CL_NC}] cannot create $LOG_DIR"; exit 1; }

# --- AT32F415 flash controller (STM32F1-compatible) -----------------------
FLASH_UNLOCK=0x40022004      # KEYR      — unlock main flash
FLASH_USD_UNLOCK=0x40022008  # OPTKEYR   — unlock option/USD programming
FLASH_STS=0x4002200C         # SR        — bit0 = busy
FLASH_CTRL=0x40022010        # CR
KEY1=0x45670123
KEY2=0xCDEF89AB
USD_ADDR=0x1FFFF800          # FAP is the low byte here
# CR bit fields:  OPTWRE=0x200  OPTPG=0x10  OPTER=0x20  STRT=0x40  LOCK=0x80

SKIP_CONFIRM=0
[[ "$1" == "--yes" ]] && SKIP_CONFIRM=1

echo
echo "$D"
echo -e "   ${CL_R}TESTBED ONLY${CL_NC} — enable AT32F415 read protection (FAP)"
echo "$D"
echo
echo -e "[${CL_Y}WARN${CL_NC}] This ERASES the option bytes and turns read protection ON."
echo "       Only run this on a sacrificial testbed part."
echo "       Recovery: at32f4xx disable_access_protection 0  (mass-erases flash)"
echo
echo "Target config:  $TEST_TARGET"
echo "Log file:       $LOG_FILE"
echo

if [[ $SKIP_CONFIRM -eq 0 ]]; then
    read -r -p "Type ENABLE-FAP to proceed: " reply
    if [[ "$reply" != "ENABLE-FAP" ]]; then
        echo -e "[${CL_Y}WARN${CL_NC}] Aborted — nothing was written."
        exit 1
    fi
fi

echo
echo -e "[${CL_C}....${CL_NC}] Programming FAP option byte to 0x00 (protected) ..."

"$OPENOCD_BIN" -s "$SCRIPTS_DIR" -d0 \
    -f "$INTERFACE" \
    -f "$TEST_TARGET" \
    -c "init" \
    -c "reset halt" \
    -c "mww $FLASH_UNLOCK $KEY1" \
    -c "mww $FLASH_UNLOCK $KEY2" \
    -c "mww $FLASH_USD_UNLOCK $KEY1" \
    -c "mww $FLASH_USD_UNLOCK $KEY2" \
    -c "mww $FLASH_CTRL 0x220" \
    -c "mww $FLASH_CTRL 0x260" \
    -c "sleep 200" \
    -c "mww $FLASH_CTRL 0x210" \
    -c "mwh $USD_ADDR 0xFF00" \
    -c "sleep 200" \
    -c "mww $FLASH_CTRL 0x80" \
    -c "echo {--- FAP cell after programming (low byte should NOT be a5): ---}" \
    -c "mdw $USD_ADDR 1" \
    -c "shutdown" 2>&1 | tee -a "$LOG_FILE"
rc=${PIPESTATUS[0]}

echo
if [[ $rc -ne 0 ]]; then
    echo -e "[${CL_R}FAIL${CL_NC}] OpenOCD exited with code $rc — see log."
    exit "$rc"
fi

fap_line="$(grep -Ei "^0x1ffff800:" "$LOG_FILE" | tail -n 1 || true)"
if [[ -n "$fap_line" ]]; then
    word="$(awk '{print $2}' <<< "$fap_line")"
    if [[ "$word" =~ ^[0-9a-fA-F]{8}$ ]]; then
        fap=$((16#$word & 0xff))
        if [[ $fap -eq 0xA5 ]]; then
            printf "[%bWARN%b] FAP cell still reads 0xA5 — programming did not take. Retry.\n" "$CL_Y" "$CL_NC"
        else
            printf "[ %bOK%b ] FAP cell now reads 0x%02X (non-0xA5 = protected once latched).\n" "$CL_G" "$CL_NC" "$fap"
        fi
    fi
fi

echo
echo -e "[${CL_Y}NEXT${CL_NC}] Protection latches on reload. POWER-CYCLE the board now,"
echo "       then run ./rdp_check.sh — it should report READ PROTECTED."
echo "       To recover: ./fap_clear.sh   (or disable_access_protection 0)"
echo
exit 0
