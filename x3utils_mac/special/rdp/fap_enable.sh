#!/bin/bash
#
# fap_enable.sh — TESTBED ONLY: turn AT32F415 read protection (FAP) ON.
#
# Purpose: this build's OpenOCD at32f4xx driver can only DISABLE access
# protection, not enable it. To validate the "READ PROTECTED" branch of
# rdp_check.sh we need a way to actually set FAP on a sacrificial part. It
# programs the FAP option byte to a non-0xA5 value via raw flash-controller
# register writes (STM32F1-compatible AT32F415 controller at 0x40022000,
# USD/option area at 0x1FFFF800).
#
# Connection (see rdp_lib.sh):
#   default        guided connect-under-reset (rescue.cfg).
#   -l/--launcher  honor the launcher-selected mode in config.sh.
#
# !!! DESTRUCTIVE — DO NOT run on a board you care about !!!
#   Erases the option bytes and enables read protection. Latches on reload
#   (power-cycle). Recover with ./fap_clear.sh (or ./rescue_unlock.sh).
#
# Usage: ./fap_enable.sh [--yes] [-l|--launcher]

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
        --yes)         SKIP_CONFIRM=1 ;;
        -l|--launcher) USE_LAUNCHER=1 ;;
    esac
done

resolve_connect

# Enable-protection sequence: erase USD, program FAP half-word 0xFF00
# (FAP=0x00 / nFAP=0xFF), leaving WRP/SSB/Data erased. Mirrors UNLOCK_REWRITE
# but writes a non-0xA5 FAP. Testbed-specific, so it lives here (not rdp_lib).
FAP_ENABLE=(
    -c "echo {--- erase USD, program FAP=0x00 (protected) ---}"
    -c "mww 0x40022004 0x45670123"
    -c "mww 0x40022004 0xCDEF89AB"
    -c "mww 0x40022008 0x45670123"
    -c "mww 0x40022008 0xCDEF89AB"
    -c "mww 0x40022010 0x220"
    -c "mww 0x40022010 0x260"
    -c "sleep 200"
    -c "mww 0x40022010 0x210"
    -c "mwh 0x1FFFF800 0xFF00"
    -c "sleep 200"
    -c "mww 0x40022010 0x80"
)

echo
echo "$D"
echo -e "   ${CL_R}TESTBED ONLY${CL_NC} — enable AT32F415 read protection (FAP)"
echo "$D"
echo
echo -e "[${CL_C}INFO${CL_NC}] Connect: $CONN_MODE"
echo -e "[${CL_Y}WARN${CL_NC}] This ERASES the option bytes and turns read protection ON."
echo "       Only run this on a sacrificial testbed part. Recover: ./fap_clear.sh"
echo

if [[ $SKIP_CONFIRM -eq 0 ]]; then
    read -r -p "Type ENABLE-FAP to proceed: " reply
    if [[ "$reply" != "ENABLE-FAP" ]]; then
        echo -e "[${CL_Y}WARN${CL_NC}] Aborted — nothing was written."
        exit 1
    fi
fi

echo
echo -e "[${CL_C}....${CL_NC}] Connecting and programming FAP=0x00 ..."
"$OPENOCD_BIN" -s "$SCRIPTS_DIR" -d0 \
    "${OOCD_PRE[@]}" \
    "${OOCD_CONNECT[@]}" \
    "${FAP_ENABLE[@]}" \
    -c "echo {--- FAP cell after programming (low byte should NOT be a5) ---}" \
    -c "mdw 0x1FFFF800 1" \
    -c "shutdown"
rc=$?

echo
if [[ $rc -ne 0 ]]; then
    echo -e "[${CL_R}FAIL${CL_NC}] Session exited with code $rc — see output above."
    exit "$rc"
fi

echo -e "[ ${CL_G}OK${CL_NC} ] Programming sent."
echo -e "[${CL_Y}NEXT${CL_NC}] POWER-CYCLE the board, then run ./rdp_check.sh — it should"
echo "       report READ PROTECTED. To recover: ./fap_clear.sh"
echo
exit 0
