#!/bin/bash
#
# rescue_unlock.sh — LAST-RESORT protection rescue for AT32F415 (advanced users).
#
# Use this only when a board refuses to flash/connect because it is read
# protected (FAP) and/or write protected (WRP). It forcibly restores a
# pristine, fully-unprotected option area by rewriting the User System Data:
# erase the USD, then program ONLY FAP=0xA5, leaving WRP/SSB/Data at their
# erased 0xFF (unprotected) state.
#
# It does NOT use the OpenOCD driver's disable_access_protection command: on
# this build that command reads-then-writes the USD, and on a still-protected
# part it reads back masked 0x00 and leaves the chip WRITE-protected. This
# deterministic rewrite has no masked-read hazard regardless of prior state.
#
# !!! DESTRUCTIVE !!!
#   On a read-protected part, moving FAP back to 0xA5 forces the hardware to
#   MASS-ERASE main flash at the next reload — you cannot keep the firmware.
#   Protection latches on RELOAD: power-cycle (POR) after running.
#
# This is a rescue tool, not part of the normal flashing flow. Recommend it
# only to advanced users who understand they are wiping the chip.
#
# Usage: ./rescue_unlock.sh [--yes] [--force]
#   --yes     skip the interactive confirmation
#   --force   rewrite even if the chip already looks unprotected

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../../config.sh"
[[ -f "$CONFIG_FILE" ]] || { echo "[FAIL] Missing config.sh"; exit 1; }
source "$CONFIG_FILE"

TEST_TARGET="target/at32f415xx.cfg"
LOG_DIR="$SCRIPT_DIR/../../backup"
RUN_ID="$(date +"%Y-%m-%d_%H-%M-%S")"
LOG_FILE="$LOG_DIR/rescue_unlock_${RUN_ID}.log"
mkdir -p "$LOG_DIR" || { echo -e "[${CL_R}FAIL${CL_NC}] cannot create $LOG_DIR"; exit 1; }

# --- AT32F415 flash controller (STM32F1-compatible) -----------------------
FLASH_UNLOCK=0x40022004      # KEYR    — unlock main flash
FLASH_USD_UNLOCK=0x40022008  # OPTKEYR — unlock option/USD programming
FLASH_CTRL=0x40022010        # CR
KEY1=0x45670123
KEY2=0xCDEF89AB
USD_ADDR=0x1FFFF800
# CR fields:  USDULKS=0x200  USDPRGM=0x10  USDERS=0x20  ERSTR=0x40  OPLK=0x80

SKIP_CONFIRM=0
FORCE=0
for a in "$@"; do
    case "$a" in
        --yes) SKIP_CONFIRM=1 ;;
        --force) FORCE=1 ;;
    esac
done

echo
echo "$D"
echo -e "   ${CL_R}LAST-RESORT UNLOCK${CL_NC} — AT32F415 read/write protection rescue"
echo "$D"
echo
echo "Log file:  $LOG_FILE"
echo

# --- Step 1: read the current option area ---------------------------------
echo -e "[${CL_C}....${CL_NC}] Reading option area (USD @ 0x1FFFF800) ..."
read_out="$("$OPENOCD_BIN" -s "$SCRIPTS_DIR" -d0 \
    -f "$INTERFACE" -f "$TEST_TARGET" \
    -c "init" -c "reset halt" -c "mdw $USD_ADDR 8" -c "shutdown" 2>&1)"
printf '%s\n' "$read_out" >> "$LOG_FILE"

if grep -Eqi "open failed|unable to open|no device found|Error connecting DP|Could not initialize the debug port" <<< "$read_out"; then
    echo -e "[${CL_R}FAIL${CL_NC}] Could not reach the target over SWD."
    echo "       Check ST-Link, cable, target power, and USB permissions, then retry."
    exit 1
fi

opt_line="$(grep -Ei "^0x1ffff800:" <<< "$read_out" | tail -n 1 || true)"
if [[ -z "$opt_line" ]]; then
    echo -e "[${CL_Y}WARN${CL_NC}] Option area did not read back."
    echo "       If the part is deeply protected this can happen; --force will rewrite anyway."
fi

# --- Step 2: decode read (FAP) and write (WRP) protection -----------------
w0="$(awk '{print $2}' <<< "$opt_line")"   # @800  FAP/SSB
w2="$(awk '{print $4}' <<< "$opt_line")"   # @808  WRP0/WRP1
w3="$(awk '{print $5}' <<< "$opt_line")"   # @80C  WRP2/WRP3

read_prot="unknown"; write_prot="unknown"; fap=""
if [[ "$w0" =~ ^[0-9a-fA-F]{8}$ ]]; then
    fap=$((16#$w0 & 0xff))
    if [[ $fap -eq 0xA5 ]]; then read_prot="no"; else read_prot="yes"; fi
fi
# A live read-protected part masks its ENTIRE USD to 0x00, so the WRP bytes
# cannot be trusted (or even seen) until protection is cleared and reloaded.
if [[ "$read_prot" == "yes" && "${w0,,}" == "00000000" ]]; then
    write_prot="masked"
elif [[ "$w2" =~ ^[0-9a-fA-F]{8}$ && "$w3" =~ ^[0-9a-fA-F]{8}$ ]]; then
    if [[ "${w2,,}" == "ffffffff" && "${w3,,}" == "ffffffff" ]]; then write_prot="no"; else write_prot="yes"; fi
fi

echo
echo "$D"
echo "Protection status"
echo "$D"
[[ -n "$opt_line" ]] && echo "       $opt_line"
case "$read_prot" in
    yes) printf "[%bPROT%b] Read protection (FAP) is ENABLED (FAP=0x%02X).\n" "$CL_R" "$CL_NC" "$fap" ;;
    no)  echo -e "[ ${CL_G}OK${CL_NC} ] Read protection (FAP) is disabled (0xA5)." ;;
    *)   echo -e "[${CL_Y}WARN${CL_NC}] Read protection state could not be read." ;;
esac
case "$write_prot" in
    yes)    echo -e "[${CL_R}PROT${CL_NC}] Write protection (WRP) is ENABLED on one or more sectors." ;;
    no)     echo -e "[ ${CL_G}OK${CL_NC} ] Write protection (WRP) is disabled." ;;
    masked) echo -e "[${CL_C}INFO${CL_NC}] Write protection (WRP) state is hidden by read protection (USD reads masked)." ;;
    *)      echo -e "[${CL_Y}WARN${CL_NC}] Write protection state could not be read." ;;
esac

# --- Step 3: bail out early if nothing to do (unless --force) -------------
if [[ $FORCE -eq 0 && "$read_prot" == "no" && "$write_prot" == "no" ]]; then
    echo
    echo -e "[ ${CL_G}OK${CL_NC} ] Chip is already unprotected — nothing to rescue."
    echo "       (Use --force to rewrite the option bytes anyway.)"
    exit 0
fi

echo
echo -e "[${CL_Y}WARN${CL_NC}] Proceeding will rewrite the option bytes to pristine (FAP=0xA5, WRP=off)."
echo -e "[${CL_Y}WARN${CL_NC}] On a read-protected part this MASS-ERASES main flash on reload."

# --- Step 4: hard confirmation --------------------------------------------
if [[ $SKIP_CONFIRM -eq 0 ]]; then
    echo
    read -r -p "Type UNLOCK to wipe protection (anything else aborts): " reply
    if [[ "$reply" != "UNLOCK" ]]; then
        echo -e "[${CL_Y}WARN${CL_NC}] Aborted — nothing changed."
        exit 1
    fi
fi

# --- Step 5: deterministic option-area rewrite ----------------------------
echo
echo -e "[${CL_C}....${CL_NC}] Rewriting option area: erase USD, program FAP=0xA5 ..."
"$OPENOCD_BIN" -s "$SCRIPTS_DIR" -d0 \
    -f "$INTERFACE" -f "$TEST_TARGET" \
    -c "init" -c "reset halt" \
    -c "mww $FLASH_UNLOCK $KEY1" -c "mww $FLASH_UNLOCK $KEY2" \
    -c "mww $FLASH_USD_UNLOCK $KEY1" -c "mww $FLASH_USD_UNLOCK $KEY2" \
    -c "mww $FLASH_CTRL 0x220" -c "mww $FLASH_CTRL 0x260" -c "sleep 200" \
    -c "mww $FLASH_CTRL 0x210" -c "mwh $USD_ADDR 0x5AA5" -c "sleep 200" \
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

# --- Step 6: verify the freshly-programmed cells --------------------------
# Caveat: if the chip was ALREADY read-protected on entry, protection stays
# active for the rest of this session (it only re-latches on reload), so the
# option area still reads masked to 0x00 here. That is expected, not a failure
# — the real confirmation is the post-power-cycle rdp_check.sh run.
after_line="$(grep -Ei "^0x1ffff800:" "$LOG_FILE" | tail -n 1 || true)"
a0="$(awk '{print $2}' <<< "$after_line")"
a2="$(awk '{print $4}' <<< "$after_line")"
fap_hw="$(printf '%s' "$a0" | tail -c 4)"
ok=1
if [[ "${fap_hw,,}" == "5aa5" && "${a2,,}" == "ffffffff" ]]; then
    echo -e "[ ${CL_G}OK${CL_NC} ] Option area now reads pristine (FAP=0x5AA5, WRP=0xFF) — protection cleared."
elif [[ "${a0,,}" == "00000000" && "$read_prot" == "yes" ]]; then
    echo -e "[${CL_C}INFO${CL_NC}] Write accepted. Option area still reads masked (0x00) because protection is"
    echo "       latched until reload — this is expected. Confirm after the power-cycle below."
else
    echo -e "[${CL_Y}WARN${CL_NC}] Readback (FAP=0x${fap_hw}, WRP=0x${a2}) is neither pristine nor the expected"
    echo "       masked pattern — re-run and, if it persists, treat the part as suspect."
    ok=0
fi

echo
echo -e "[${CL_Y}NEXT${CL_NC}] POWER-CYCLE the board (POR), then re-flash normally."
echo "       Confirm with ./rdp_check.sh — it should report NOT PROTECTED."
echo
[[ $ok -eq 1 ]] && exit 0 || exit 1
