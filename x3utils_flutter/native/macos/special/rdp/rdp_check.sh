#!/bin/bash
#
# rdp_check.sh — AT32F415 read-protection (FAP) detector, v2
#
# Goal: answer one question against real hardware — is the chip read
# protected (Flash Access Protection enabled) or not?
#
# Unlike rdp_check.sh this script makes an explicit, decisive verdict:
#   - NOT PROTECTED   FAP byte is the unlocked value and flash reads back.
#   - READ PROTECTED  FAP byte is set, OR the chip connects at SWD but
#                     refuses to return real flash/option data.
#   - INCONCLUSIVE    adapter/target could not be reached, or the signals
#                     disagree (e.g. FAP says unlocked but flash won't read).
#
# The read-protection control on AT32F415 is the FAP byte, the low byte of
# the USD word at 0x1FFFF800. Artery's OpenOCD uses 0xA5 as the
# "disable access protection" value; any other value means protected.
#
# Write/erase protection (the "flash info" per-block table) is a DIFFERENT
# mechanism and is reported here only as extra context, never as the verdict.
#
# Exit codes:
#   0  not read protected (readable)
#   2  read protected
#   3  inconclusive / could not determine

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_FILE="$SCRIPT_DIR/../../config.sh"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[FAIL] Missing config.sh"
    exit 1
fi

source "$CONFIG_FILE"

source "$SCRIPT_DIR/rdp_lib.sh"

USE_LAUNCHER=0
for a in "$@"; do
    case "$a" in
        -l|--launcher) USE_LAUNCHER=1 ;;
    esac
done
resolve_connect

# The GUI sets X3UTILS_RDP_LOG_DIR in config.sh so this transcript lands in the
# x3utils folder beside the run's console log; run by hand, it stays local.
# `_toolkit` in the name: the GUI writes its own rdp_check_<stamp>.log in that
# same folder and the two stamps can land on the same second.
LOG_DIR="${X3UTILS_RDP_LOG_DIR:-$SCRIPT_DIR/../../backup}"
RUN_ID="$(date +"%Y-%m-%d_%H-%M-%S")"
LOG_FILE="$LOG_DIR/rdp_check_toolkit_${RUN_ID}.log"

# FAP byte value that means "access/read protection disabled" on Artery AT32.
FAP_UNLOCKED=0xA5

mkdir -p "$LOG_DIR" || {
    echo -e "[${CL_R}FAIL${CL_NC}] Failed to create log directory."
    exit 1
}

# Returns 0 (true) if the output shows the adapter/target could not be opened,
# or a guided connect-under-reset failed — a connection problem, not a
# protection state.
adapter_unreachable() {
    grep -Eq "open failed|unable to open|no device found|Error: init mode failed|Error connecting DP|Could not initialize the debug port|Could not re-examine target|Adapter init failed" <<< "$1"
}

echo
echo "$D"
echo "          AT32F415 read-protection (FAP) check"
echo "$D"
echo
echo "Connect mode:   $CONN_MODE"
echo "Log file:       $LOG_FILE"
echo

# Connect (guided by default), then read the FAP/USD word and the flash vector
# table. Output is tee'd (NOT $()-captured) so the interactive grounding prompts
# stay visible. Each attempt is captured to its OWN temp file and parsed from that
# alone — a stale failed attempt must never pollute the verdict — while the
# persistent log keeps the full history of every attempt.
#
# Connection-only retry: a lost SWD/nRST-C45 contact (adapter unreachable) offers a
# re-seat retry. This is READ-ONLY, so retrying never changes the chip. It keys on
# the CONNECTION signal only — a genuinely READ-PROTECTED part connects fine and
# returns masked data, which is a valid verdict, NOT a retry condition.
attempt=0
scan=""
while true; do
    attempt=$((attempt + 1))
    echo -e "[${CL_C}....${CL_NC}] Connecting and reading FAP/USD @ 0x1FFFF800 and flash @ 0x08000000 ..."
    attempt_log="$(mktemp "${TMPDIR:-/tmp}/rdp_check_attempt.XXXXXX")"
    { echo; echo "$D"; echo "RDP check session $RUN_ID (attempt $attempt)"; echo "$D"; } >> "$attempt_log"
    "$OPENOCD_BIN" -s "$SCRIPTS_DIR" -d0 \
        "${OOCD_PRE[@]}" \
        "${OOCD_CONNECT[@]}" \
        -c "flash probe 0" \
        -c "mdw 0x1FFFF800 1" \
        -c "mdw 0x08000000 4" \
        -c "shutdown" 2>&1 | tee -a "$attempt_log"
    cat "$attempt_log" >> "$LOG_FILE"   # fold into the persistent log (full history)
    scan="$(cat "$attempt_log")"        # parse THIS attempt only
    rm -f "$attempt_log"

    # Retry ONLY on a connection-level failure — never on a protection verdict.
    if adapter_unreachable "$scan"; then
        echo
        echo -e "[${CL_Y}WARN${CL_NC}] Adapter/target could not be reached — nothing was read."
        echo "       Most often this is lost SWD / nRST-C45 contact mid-connect. Re-seat the"
        echo "       probe and the contact (touch the contact point, NOT on top of the cap),"
        echo "       keep it steady. (Read-only check — retrying never changes the chip.)"
        echo
        # Bash hides read -p prompts when Flutter redirects stdin through a pipe.
        echo -e "${CL_C}Press ENTER to retry, or type Q to quit: ${CL_NC}"
        read -r retry_choice
        retry_choice_lc="$(echo "$retry_choice" | tr '[:upper:]' '[:lower:]')"
        if [[ "$retry_choice_lc" == "q" ]]; then
            break   # keep this failed scan -> verdict prints INCONCLUSIVE, exit 3
        fi
        echo
        continue
    fi
    break
done

usd_out="$scan"
flash_out="$scan"

# --- Analyse connectivity -------------------------------------------------
adapter_failed=0
if adapter_unreachable "$usd_out" && adapter_unreachable "$flash_out"; then
    adapter_failed=1
fi

# --- Analyse FAP ----------------------------------------------------------
fap_read=0
fap=""; fap_comp=""; ssb=""; ssb_comp=""; usd_word=""
usd_line="$(grep -Ei "^0x1ffff800:" <<< "$usd_out" | tail -n 1 || true)"
if [[ -n "$usd_line" ]]; then
    usd_word="$(awk '{print $2}' <<< "$usd_line")"
    if [[ "$usd_word" =~ ^[0-9a-fA-F]{8}$ ]]; then
        fap=$((16#$usd_word & 0xff))
        fap_comp=$(((16#$usd_word >> 8) & 0xff))
        ssb=$(((16#$usd_word >> 16) & 0xff))
        ssb_comp=$(((16#$usd_word >> 24) & 0xff))
        fap_read=1
    fi
fi

fap_unlocked=0
fap_comp_ok=0
if [[ $fap_read -eq 1 ]]; then
    [[ $fap -eq $FAP_UNLOCKED ]] && fap_unlocked=1
    [[ $((fap ^ fap_comp)) -eq 0xff ]] && fap_comp_ok=1
fi

# --- Analyse main-flash readability ---------------------------------------
# Ground truth confirmed on hardware (see backup logs):
#   MSP in SRAM (0x2xxxxxxx) -> firmware present, readable   -> NOT protected
#   all 0xFFFFFFFF           -> flash blank/erased but READABLE -> NOT protected
#   all 0x00000000           -> access protection masking the bus -> protected
#   bus error                -> read refused                  -> protected/fault
flash_state="unknown"   # firmware | blank | masked | error | unknown
msp=""; reset_vec=""
vec_line="$(grep -Ei "^0x08000000:" <<< "$flash_out" | tail -n 1 || true)"
flash_err="$(grep -Ei "Error:.*(read|access|memory)|access denied|Failed to read" <<< "$flash_out" | head -n 1 || true)"
if [[ -n "$flash_err" ]]; then
    flash_state="error"
elif [[ -n "$vec_line" ]]; then
    msp="$(awk '{print $2}' <<< "$vec_line")"
    reset_vec="$(awk '{print $3}' <<< "$vec_line")"
    words="$(awk '{$1=""; print}' <<< "$vec_line")"
    if [[ "$msp" =~ ^2[0-9a-fA-F]{7}$ ]]; then
        flash_state="firmware"
    elif [[ "$words" =~ ^[[:space:]]*(ffffffff[[:space:]]*)+$ ]]; then
        flash_state="blank"
    elif [[ "$words" =~ ^[[:space:]]*(00000000[[:space:]]*)+$ ]]; then
        flash_state="masked"
    fi
fi

# Derived signals for the verdict.
flash_accessible=0   # bus works and returned real data (firmware or blank)
flash_blocked=0      # reads masked to 0x00 or refused
case "$flash_state" in
    firmware|blank) flash_accessible=1 ;;
    masked|error)   flash_blocked=1 ;;
esac

# --- Report evidence ------------------------------------------------------
echo
echo "$D"
echo "Evidence"
echo "$D"

if [[ $adapter_failed -eq 1 ]]; then
    echo -e "[${CL_Y}WARN${CL_NC}] Adapter/target could not be opened at the SWD/USB level."
    echo "       Check ST-Link, cable, target power, and USB permissions."
fi

if [[ $fap_read -eq 1 ]]; then
    printf "[ %bOK%b ] USD @ 0x1FFFF800 = %s\n" "$CL_G" "$CL_NC" "$usd_word"
    printf "       FAP=0x%02X FAP_COMP=0x%02X SSB=0x%02X SSB_COMP=0x%02X\n" \
        "$fap" "$fap_comp" "$ssb" "$ssb_comp"
    if [[ $((fap ^ fap_comp)) -eq 0xff ]]; then
        echo "       FAP complement byte is consistent."
    else
        echo "       FAP complement byte is inconsistent (option area may be unusual)."
    fi
else
    echo -e "[${CL_Y}WARN${CL_NC}] Could not read a valid FAP/USD word."
fi

case "$flash_state" in
    firmware)
        echo -e "[ ${CL_G}OK${CL_NC} ] Main flash readable — firmware present (MSP=0x$msp RESET=0x$reset_vec)." ;;
    blank)
        echo -e "[ ${CL_G}OK${CL_NC} ] Main flash readable but blank/erased (all 0xFF) — ready to program." ;;
    masked)
        echo -e "[${CL_Y}WARN${CL_NC}] Main-flash reads return all 0x00 — the access-protection masking pattern." ;;
    error)
        echo -e "[${CL_Y}WARN${CL_NC}] Main-flash read was refused: $flash_err" ;;
    *)
        echo -e "[${CL_Y}WARN${CL_NC}] Main-flash read was inconclusive."
        [[ -n "$vec_line" ]] && echo "       Got: $vec_line" ;;
esac

# --- Verdict --------------------------------------------------------------
echo
echo "$D"
echo "Verdict"
echo "$D"

rc=3
if [[ $adapter_failed -eq 1 ]]; then
    echo -e "[${CL_Y}????${CL_NC}] INCONCLUSIVE: could not reach the chip; fix the connection and retry."
    rc=3
elif [[ $flash_accessible -eq 1 && $fap_read -eq 1 && $fap_unlocked -eq 0 ]]; then
    # Contradiction guard: the FAP byte read back non-0xA5 (looks protected) but main
    # flash returned real data (firmware or blank 0xFF). A truly read-protected AT32F415
    # masks the bus to 0x00 and can NEVER return readable flash, so it is the option-area
    # read that glitched here, not the chip. Readable flash is physically decisive.
    echo -e "[ ${CL_G}OK${CL_NC} ] NOT PROTECTED: main flash reads back normally."
    printf "       (Note: FAP byte read as 0x%02X, not 0x%02X — but a protected part cannot\n" "$fap" "$FAP_UNLOCKED"
    echo "       return readable flash, so that was a glitched option read; re-run to confirm.)"
    rc=0
elif [[ $fap_read -eq 1 && $fap_unlocked -eq 0 ]]; then
    # FAP byte is authoritative when flash does not contradict it: a non-0xA5 value here
    # means protected (flash is masked/blocked or unclassifiable — NOT provably readable,
    # or the contradiction guard above would have caught it).
    printf "[%bPROT%b] READ PROTECTED: FAP=0x%02X (not the unlocked value 0x%02X).\n" \
        "$CL_R" "$CL_NC" "$fap" "$FAP_UNLOCKED"
    rc=2
elif [[ $fap_read -eq 1 && $fap_unlocked -eq 1 && $fap_comp_ok -eq 1 ]]; then
    # Option area read back cleanly with the unlocked value + valid complement.
    # This is authoritative regardless of whether flash holds code or is blank.
    if [[ "$flash_state" == "blank" ]]; then
        echo -e "[ ${CL_G}OK${CL_NC} ] NOT PROTECTED: FAP is unlocked (0xA5); main flash is blank/erased (ready to program)."
    else
        echo -e "[ ${CL_G}OK${CL_NC} ] NOT PROTECTED: FAP is unlocked (0xA5) and flash reads back normally."
    fi
    rc=0
elif [[ $fap_read -eq 1 && $fap_unlocked -eq 1 ]]; then
    # Low byte is 0xA5 but its complement is wrong — a genuine unlocked part has
    # a consistent 0xA5/0x5A pair, so this looks like a masked/garbled read.
    if [[ $flash_blocked -eq 1 ]]; then
        echo -e "[${CL_R}PROT${CL_NC}] READ PROTECTED (likely): FAP low byte is 0xA5 but its complement is"
        echo "       invalid and flash reads are masked — a protected part hiding the option area."
        rc=2
    else
        echo -e "[${CL_Y}????${CL_NC}] INCONCLUSIVE: FAP byte 0xA5 but complement inconsistent; re-seat and retry."
        rc=3
    fi
else
    # FAP word could not be parsed at all, but the adapter was reachable.
    if [[ $flash_accessible -eq 1 ]]; then
        echo -e "[ ${CL_G}OK${CL_NC} ] NOT PROTECTED: flash reads back normally (FAP word not parsed)."
        rc=0
    elif [[ $flash_blocked -eq 1 ]]; then
        echo -e "[${CL_R}PROT${CL_NC}] READ PROTECTED (likely): chip connects at SWD but returns masked/no"
        echo "       option or flash data — the classic locked-chip fingerprint."
        rc=2
    else
        echo -e "[${CL_Y}????${CL_NC}] INCONCLUSIVE: could not read option area or classify flash; retry."
        rc=3
    fi
fi

echo
echo "Full log: $LOG_FILE"
echo

exit "$rc"
