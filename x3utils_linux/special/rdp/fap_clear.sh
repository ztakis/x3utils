#!/bin/bash
#
# fap_clear.sh — remove AT32F415 read protection (FAP), restore a pristine,
# fully-unprotected option area (FAP=0xA5, WRP/SSB/Data = 0xFF).
#
# WHY NOT the driver's disable_access_protection?
#   On this OpenOCD build that command reads the current USD, overrides only
#   the FAP byte, and writes the rest back. When run on a still-protected
#   part the USD reads back masked to 0x00, so it programs the write-protect
#   (WRP) and SSB bytes to 0x00 — leaving the chip WRITE-protected after the
#   "unlock" (observed on hardware: flash then fails with "write protected").
#
#   Instead we rewrite the option area deterministically with raw register
#   writes: erase the USD (all cells -> 0xFF, i.e. WRP unprotected), then
#   program ONLY the FAP half-word to 0xA5. Nothing is read-then-written, so
#   there is no masked-read hazard regardless of the prior protection state.
#
# On a genuinely read-protected part, moving FAP back to 0xA5 forces the
# hardware mass-erase of main flash at the next reload (you cannot lift read
# protection and keep the code). On an already-unprotected part this simply
# restores clean option bytes.
#
# Protection latches on RELOAD — power-cycle (POR) or pin reset after running.
#
# Usage: ./fap_clear.sh [--yes]

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../../config.sh"
[[ -f "$CONFIG_FILE" ]] || { echo "[FAIL] Missing config.sh"; exit 1; }
source "$CONFIG_FILE"

TEST_TARGET="target/at32f415xx.cfg"
LOG_DIR="$SCRIPT_DIR/../../backup"
RUN_ID="$(date +"%Y-%m-%d_%H-%M-%S")"
LOG_FILE="$LOG_DIR/fap_clear_${RUN_ID}.log"
mkdir -p "$LOG_DIR" || { echo -e "[${CL_R}FAIL${CL_NC}] cannot create $LOG_DIR"; exit 1; }

# --- AT32F415 flash controller (STM32F1-compatible) -----------------------
FLASH_UNLOCK=0x40022004      # KEYR    — unlock main flash
FLASH_USD_UNLOCK=0x40022008  # OPTKEYR — unlock option/USD programming
FLASH_CTRL=0x40022010        # CR
KEY1=0x45670123
KEY2=0xCDEF89AB
USD_ADDR=0x1FFFF800          # FAP is the low byte here
# CR fields:  USDULKS=0x200  USDPRGM=0x10  USDERS=0x20  ERSTR=0x40  OPLK=0x80

SKIP_CONFIRM=0
[[ "$1" == "--yes" ]] && SKIP_CONFIRM=1

echo
echo "$D"
echo "   Clear AT32F415 read/write protection — restore pristine option bytes"
echo "$D"
echo
echo -e "[${CL_Y}WARN${CL_NC}] On a read-protected part this triggers a hardware MASS-ERASE"
echo "       of main flash on reload (by design — you cannot keep the code)."
echo "Log file:  $LOG_FILE"
echo

if [[ $SKIP_CONFIRM -eq 0 ]]; then
    read -r -p "Type CLEAR-FAP to proceed: " reply
    if [[ "$reply" != "CLEAR-FAP" ]]; then
        echo -e "[${CL_Y}WARN${CL_NC}] Aborted — nothing changed."
        exit 1
    fi
fi

echo
echo -e "[${CL_C}....${CL_NC}] Rewriting option area: erase USD, program FAP=0xA5 ..."

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
    -c "mwh $USD_ADDR 0x5AA5" \
    -c "sleep 200" \
    -c "mww $FLASH_CTRL 0x80" \
    -c "echo {--- option area after rewrite (expect ffff5aa5 ffffffff ffffffff ffffffff): ---}" \
    -c "mdw $USD_ADDR 8" \
    -c "shutdown" 2>&1 | tee -a "$LOG_FILE"
rc=${PIPESTATUS[0]}

echo
if [[ $rc -ne 0 ]]; then
    echo -e "[${CL_R}FAIL${CL_NC}] OpenOCD exited with code $rc — see log."
    exit "$rc"
fi

# Verify the freshly-programmed cells: FAP half-word = 0x5AA5, WRP words = 0xFFFFFFFF.
opt_line="$(grep -Ei "^0x1ffff800:" "$LOG_FILE" | tail -n 1 || true)"
if [[ -n "$opt_line" ]]; then
    w0="$(awk '{print $2}' <<< "$opt_line")"   # @0x1FFFF800: FAP/SSB
    w2="$(awk '{print $4}' <<< "$opt_line")"   # @0x1FFFF808: WRP0/WRP1
    fap_hw="$(printf '%s' "$w0" | tail -c 4)"   # low half-word = FAP/nFAP
    if [[ "${fap_hw,,}" == "5aa5" ]]; then
        echo -e "[ ${CL_G}OK${CL_NC} ] FAP half-word programmed to 0x5AA5 (read protection cleared)."
    else
        echo -e "[${CL_Y}WARN${CL_NC}] FAP half-word reads 0x${fap_hw}, expected 0x5AA5 — re-run."
    fi
    if [[ "${w2,,}" == "ffffffff" ]]; then
        echo -e "[ ${CL_G}OK${CL_NC} ] WRP bytes are 0xFF (write protection cleared)."
    else
        echo -e "[${CL_Y}WARN${CL_NC}] WRP word reads 0x${w2}, expected 0xFFFFFFFF — re-run."
    fi
fi

echo
echo -e "[${CL_Y}NEXT${CL_NC}] POWER-CYCLE the board, then run ./rdp_check.sh to confirm NOT PROTECTED."
echo
exit 0
