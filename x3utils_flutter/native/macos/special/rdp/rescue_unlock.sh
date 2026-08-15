#!/bin/bash
#
# rescue_unlock.sh — LAST-RESORT protection rescue for AT32F415 (advanced users).
#
# Connection (see rdp_lib.sh):
#   default        universal manual connect-under-reset (rescue.cfg guided_rescue)
#                  — reaches locked / corrupted / debug-hostile boards.
#   -l/--launcher  honor the launcher-selected mode in config.sh instead.
#
# The FAP=0xA5 option-rewrite (UNLOCK_REWRITE) clears BOTH read (FAP) and write
# (WRP) protection deterministically — no masked-read hazard.
#
# !!! DESTRUCTIVE !!!
#   Restoring FAP=0xA5 on a read-protected part forces a hardware MASS-ERASE of
#   main flash on reload. Protection latches on RELOAD — power-cycle afterwards.
#
# Usage: ./rescue_unlock.sh [--yes] [-l|--launcher]

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
echo -e "   ${CL_R}LAST-RESORT UNLOCK${CL_NC} — AT32F415 read/write protection rescue"
echo "$D"
echo
echo -e "[${CL_C}INFO${CL_NC}] Connect: $CONN_MODE"
if [[ $USE_LAUNCHER -eq 0 ]]; then
    echo "       You will be asked to ground nRST/C45 by hand (works with any ST-Link)."
elif launcher_mode_is_plain; then
    echo -e "[${CL_Y}WARN${CL_NC}] Launcher mode is A (plain). A locked/corrupted board usually will"
    echo "       NOT answer plain connect — drop -l to use the guided rescue, or set B/C."
fi
echo
echo -e "[${CL_Y}WARN${CL_NC}] This rewrites the option bytes to pristine (FAP=0xA5, WRP=off)."
echo -e "[${CL_Y}WARN${CL_NC}] On a read-protected part it MASS-ERASES main flash on reload."
echo

if [[ $SKIP_CONFIRM -eq 0 ]]; then
    read -r -p "Type UNLOCK to wipe protection (anything else aborts): " reply
    if [[ "$reply" != "UNLOCK" ]]; then
        echo -e "[${CL_Y}WARN${CL_NC}] Aborted — nothing changed."
        exit 1
    fi
fi

# One session: connect, then the shared option-area rewrite + readback.
# Run OpenOCD directly (no pipe) so any interactive grounding prompt is reliable.
# On success continue; on ANY failure offer a re-seat retry. UNLOCK_REWRITE erases
# the USD then reprograms FAP from scratch, so re-running after a failed/partial
# attempt is idempotent. The UNLOCK confirm above is asked once and is NOT repeated
# on retry.
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
    echo -e "[${CL_Y}WARN${CL_NC}] Rescue rewrite failed or did not complete."
    echo "       Usually lost SWD / nRST-C45 contact mid-connect. Re-seat the ST-Link and"
    echo "       the nRST/C45 contact, check grounding/release timing, keep it steady. The"
    echo "       rewrite re-erases and reprograms, so a retry is safe."
    echo
    # Bash hides read -p prompts when Flutter redirects stdin through a pipe.
    echo -e "${CL_C}Press ENTER to retry, or type Q to quit: ${CL_NC}"
    read -r retry_choice
    retry_choice_lc="$(echo "$retry_choice" | tr '[:upper:]' '[:lower:]')"
    if [[ "$retry_choice_lc" == "q" ]]; then
        exit 1
    fi
    echo
done

echo

echo -e "[ ${CL_G}OK${CL_NC} ] Rescue sequence sent."
echo -e "[${CL_Y}NEXT${CL_NC}] POWER-CYCLE the board (POR), then verify with ./rdp_check.sh"
echo "       — it should report NOT PROTECTED. Then re-flash normally."
echo
exit 0
