#!/bin/bash
#
# fap_clear.sh — remove AT32F415 read/write protection, restoring a pristine
# option area (FAP=0xA5, WRP/SSB/Data = 0xFF). Bench counterpart to fap_enable.
#
# Uses the shared deterministic rewrite (UNLOCK_REWRITE in rdp_lib.sh): erase
# the USD, program ONLY the FAP half-word to 0xA5, leaving the rest erased.
# Nothing is read-then-written, so there is no masked-read hazard — unlike the
# driver's disable_access_protection, which can leave a still-protected part
# WRITE-protected.
#
# Connection (see rdp_lib.sh):
#   default        guided connect-under-reset (rescue.cfg) — reaches any board.
#   -l/--launcher  honor the launcher-selected mode in config.sh.
#
# On a read-protected part, restoring FAP=0xA5 forces a hardware MASS-ERASE of
# main flash on reload. Protection latches on RELOAD — power-cycle afterwards.
#
# Usage: ./fap_clear.sh [--yes] [-l|--launcher]

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../../config.sh"
[[ -f "$CONFIG_FILE" ]] || { echo "[FAIL] Missing config.sh"; exit 1; }
source "$CONFIG_FILE"
source "$SCRIPT_DIR/rdp_lib.sh"

SKIP_CONFIRM=0
USE_LAUNCHER=0
for a in "$@"; do
    case "$a" in
        --yes|-y)      SKIP_CONFIRM=1 ;;
        -l|--launcher) USE_LAUNCHER=1 ;;
    esac
done

resolve_connect

echo
echo "$D"
echo "   Clear AT32F415 read/write protection — restore pristine option bytes"
echo "$D"
echo
echo -e "[${CL_C}INFO${CL_NC}] Connect: $CONN_MODE"
echo -e "[${CL_Y}WARN${CL_NC}] On a read-protected part this triggers a hardware MASS-ERASE"
echo "       of main flash on reload (by design — you cannot keep the code)."
echo

if [[ $SKIP_CONFIRM -eq 0 ]]; then
    read -r -p "Type CLEAR-FAP to proceed: " reply
    if [[ "$reply" != "CLEAR-FAP" ]]; then
        echo -e "[${CL_Y}WARN${CL_NC}] Aborted — nothing changed."
        exit 1
    fi
fi

echo
echo -e "[${CL_C}....${CL_NC}] Connecting and rewriting option area (FAP=0xA5) ..."
# On success continue; on ANY failure offer a re-seat retry. UNLOCK_REWRITE erases
# the USD then reprograms FAP from scratch, so re-running after a failed/partial
# attempt is idempotent (no half-write hazard). The CLEAR-FAP confirm above is asked
# once and is NOT repeated on retry.
while true; do
    "$OPENOCD_BIN" -s "$SCRIPTS_DIR" -d0 \
        "${OOCD_PRE[@]}" \
        "${OOCD_CONNECT[@]}" \
        "${UNLOCK_REWRITE[@]}" \
        -c "echo {--- option area after rewrite (masked 0x00 until reload if still protected) ---}" \
        -c "mdw 0x1FFFF800 8" \
        -c "shutdown"
    [[ $? -eq 0 ]] && break

    echo
    echo -e "[${CL_Y}WARN${CL_NC}] Option-area rewrite failed or did not complete."
    echo "       Usually lost SWD / nRST-C45 contact mid-connect. Re-seat the probe and"
    echo "       the contact (touch the contact point, NOT on top of the cap), keep it"
    echo "       steady. The rewrite re-erases and reprograms, so a retry is safe."
    echo
    read -rp "$(echo -e "${CL_C}Press ENTER to retry, or type Q to quit: ${CL_NC}")" retry_choice
    if [[ "${retry_choice,,}" == "q" ]]; then
        exit 1
    fi
    echo
done

echo

echo -e "[ ${CL_G}OK${CL_NC} ] Rewrite sent."
echo -e "[${CL_Y}NEXT${CL_NC}] POWER-CYCLE the board, then run ./rdp_check.sh to confirm NOT PROTECTED."
echo
exit 0
