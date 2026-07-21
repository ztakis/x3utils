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
# UNLOCK_REWRITE erases the USD then reprograms FAP from scratch, so re-running
# after a failed/partial attempt is idempotent. The UNLOCK confirmation above is
# asked once and is not repeated on retry.
run_rescue_rewrite() {
    "$OPENOCD_BIN" -s "$SCRIPTS_DIR" -d0 \
        "${OOCD_PRE[@]}" \
        "${OOCD_CONNECT[@]}" \
        "${UNLOCK_REWRITE[@]}" \
        -c "echo {--- option area after rewrite (masked 0x00 until reload if still protected) ---}" \
        -c "mdw 0x1FFFF800 8" \
        -c "echo {X3UTILS_RESCUE_SEQUENCE_COMPLETE}" \
        -c "shutdown"
}

if [[ "${CONN_RACE:-0}" -eq 1 ]]; then
    # Mode D needs a fresh xPack OpenOCD process for every missed power-on
    # window. Keep only the current attempt and require action-specific evidence
    # before reporting success; an exit status or halt alone is insufficient.
    rescue_last="${TMPDIR:-/tmp}/x3utils_rescue_last.log"
    trap 'rm -f "$rescue_last"' EXIT

    echo -e "[${CL_C}race${CL_NC}] Power-race: hammering the rescue - cut & re-apply power. Ctrl+C to stop."
    echo -e "       Live: .=searching  ${CL_Y}N${CL_NC}=noisy, hold steadier"
    echo -e "             ${CL_G}H${CL_NC}=almost    ${CL_R}x${CL_NC}=probe/USB gone"
    echo

    rescue_tries=0
    while true; do
        rescue_tries=$((rescue_tries + 1))
        run_rescue_rewrite > "$rescue_last" 2>&1
        rescue_result=$?

        if [[ $rescue_result -eq 0 ]] &&
            grep -Eqi '^0x1ffff800:[[:space:]]+[0-9a-f]{8}' "$rescue_last" &&
            grep -q 'X3UTILS_RESCUE_SEQUENCE_COMPLETE' "$rescue_last"; then
            echo
            echo
            cat "$rescue_last"
            echo
            echo -e "[ ${CL_G}OK${CL_NC} ] Rescue sequence completed on attempt $rescue_tries."
            break
        fi

        bash "$SCRIPT_DIR/../../race_grade.sh" "$rescue_last"
    done
else
    # Keep output direct so guided grounding prompts remain interactive.
    while true; do
        run_rescue_rewrite
        [[ $? -eq 0 ]] && break

        echo
        echo -e "[${CL_Y}WARN${CL_NC}] Rescue rewrite failed or did not complete."
        echo "       Usually lost SWD / nRST-C45 contact mid-connect. Re-seat the ST-Link and"
        echo "       the nRST/C45 contact, check grounding/release timing, keep it steady. The"
        echo "       rewrite re-erases and reprograms, so a retry is safe."
        echo
        read -rp "$(echo -e "${CL_C}Press ENTER to retry, or type Q to quit: ${CL_NC}")" retry_choice
        retry_choice_lc="$(echo "$retry_choice" | tr '[:upper:]' '[:lower:]')"
        if [[ "$retry_choice_lc" == "q" ]]; then
            exit 1
        fi
        echo
    done
fi

echo

if [[ "${CONN_RACE:-0}" -ne 1 ]]; then
    echo -e "[ ${CL_G}OK${CL_NC} ] Rescue sequence sent."
fi
echo -e "[${CL_Y}NEXT${CL_NC}] POWER-CYCLE the board (POR), then verify with ./rdp_check.sh"
echo "       — it should report NOT PROTECTED. Then re-flash normally."
echo
exit 0
