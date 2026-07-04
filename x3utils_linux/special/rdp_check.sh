#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_FILE="$SCRIPT_DIR/../config.sh"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[FAIL] Missing config.sh"
    exit 1
fi

source "$CONFIG_FILE"

# Hardware testbed probe for AT32F415 access/read-protection behavior.
# This deliberately uses the normal target config, not the C45 guided target.
TEST_TARGET="target/at32f415xx.cfg"
LOG_DIR="$SCRIPT_DIR/../backup"
RUN_ID="$(date +"%Y-%m-%d_%H-%M-%S")"
LOG_FILE="$LOG_DIR/rdp_check_${RUN_ID}.log"
HEAD_DUMP_FILE="$LOG_DIR/rdp_check_head_${RUN_ID}.bin"

mkdir -p "$LOG_DIR" || {
    echo -e "[${CL_R}FAIL${CL_NC}] Failed to create log directory."
    exit 1
}

run_openocd_test() {
    local name="$1"
    shift

    echo
    echo "$D"
    echo "RDP check: $name"
    echo "$D"

    {
        echo
        echo "$D"
        echo "RDP check: $name"
        echo "$D"
    } >> "$LOG_FILE"

    "$OPENOCD_BIN" -s "$SCRIPTS_DIR" -d0 \
        -f "$INTERFACE" \
        -f "$TEST_TARGET" \
        "$@" \
        -c "shutdown" 2>&1 | tee -a "$LOG_FILE"

    local rc=${PIPESTATUS[0]}
    if [[ $rc -eq 0 ]]; then
        echo -e "[ ${CL_G}OK${CL_NC} ] $name"
    else
        echo -e "[${CL_Y}WARN${CL_NC}] $name exited with code $rc"
    fi

    return 0
}

summarize_results() {
    local usd_line fap_word fap fap_comp ssb ssb_comp
    local flash_dump_ok vector_read_ok
    local prot_block_count not_protected_count protected_count
    local adapter_open_failed
    local msp_word reset_word head_hash
    local warnings=0

    usd_line="$(grep -E "^0x1ffff800:" "$LOG_FILE" | tail -n 1 || true)"
    vector_read_ok="$(grep -E "^0x08000000:" "$LOG_FILE" | tail -n 1 || true)"
    flash_dump_ok="$(grep -E "dumped 256 bytes" "$LOG_FILE" | tail -n 1 || true)"
    adapter_open_failed="$(grep -E "Error: open failed" "$LOG_FILE" | head -n 1 || true)"
    read -r prot_block_count not_protected_count protected_count < <(
        awk '
            /^[[:space:]]*#[[:space:]]*[0-9]+:/ {
                total++
                if ($0 ~ /not protected$/)
                    notp++
                else if ($0 ~ /protected$/)
                    prot++
            }
            END { print total + 0, notp + 0, prot + 0 }
        ' "$LOG_FILE"
    )

    echo
    echo "$D"
    echo "RDP check summary"
    echo "$D"

    if [[ -n "$adapter_open_failed" ]]; then
        echo -e "[${CL_Y}WARN${CL_NC}] OpenOCD could not open the ST-Link adapter."
        echo "       Replug/check the ST-Link, target power, USB permissions, and cable."
        echo
        echo -e "[${CL_Y}WARN${CL_NC}] Verdict: ST-Link was not opened; no protection conclusion."
        return 1
    elif [[ $prot_block_count -gt 0 && $protected_count -eq 0 ]]; then
        echo -e "[ ${CL_G}OK${CL_NC} ] flash info reports all $not_protected_count/$prot_block_count protection blocks not protected."
    elif [[ $prot_block_count -gt 0 ]]; then
        echo -e "[${CL_Y}WARN${CL_NC}] flash info reports $protected_count/$prot_block_count protection blocks protected."
        echo "       Review the log for the full protection-block table."
        warnings=$((warnings + 1))
    else
        echo -e "[${CL_Y}WARN${CL_NC}] flash info did not report a protection-block table."
        warnings=$((warnings + 1))
    fi

    if [[ -n "$usd_line" ]]; then
        fap_word="$(awk '{print $2}' <<< "$usd_line")"
        fap=$((16#$fap_word & 0xff))
        fap_comp=$(((16#$fap_word >> 8) & 0xff))
        ssb=$(((16#$fap_word >> 16) & 0xff))
        ssb_comp=$(((16#$fap_word >> 24) & 0xff))

        printf "[ %bOK%b ] USD @ 0x1FFFF800 = %s\n" "$CL_G" "$CL_NC" "$fap_word"
        printf "       FAP=0x%02X FAP_COMP=0x%02X SSB=0x%02X SSB_COMP=0x%02X\n" \
            "$fap" "$fap_comp" "$ssb" "$ssb_comp"

        if [[ $((fap ^ fap_comp)) -eq 0xff && $((ssb ^ ssb_comp)) -eq 0xff ]]; then
            echo -e "[ ${CL_G}OK${CL_NC} ] USD complement bytes are consistent."
        else
            echo -e "[${CL_Y}WARN${CL_NC}] USD complement bytes do not match expected inverses."
            warnings=$((warnings + 1))
        fi

        if [[ $fap -eq 0xA5 ]]; then
            echo -e "[ ${CL_G}OK${CL_NC} ] FAP byte is 0xA5, matching Artery OpenOCD's disable-access-protection value."
        else
            printf "[%bWARN%b] FAP byte is 0x%02X, not 0xA5.\n" "$CL_Y" "$CL_NC" "$fap"
            warnings=$((warnings + 1))
        fi
    else
        echo -e "[${CL_Y}WARN${CL_NC}] Could not read or find USD/FAP output in the log."
        warnings=$((warnings + 1))
    fi

    if [[ -n "$vector_read_ok" ]]; then
        echo -e "[ ${CL_G}OK${CL_NC} ] Flash vector read succeeded."
        msp_word="$(awk '{print $2}' <<< "$vector_read_ok")"
        reset_word="$(awk '{print $3}' <<< "$vector_read_ok")"
        echo "       MSP=0x$msp_word RESET=0x$reset_word"
    else
        echo -e "[${CL_Y}WARN${CL_NC}] Flash vector read did not produce an obvious result."
        warnings=$((warnings + 1))
    fi

    if [[ -n "$flash_dump_ok" ]]; then
        echo -e "[ ${CL_G}OK${CL_NC} ] 256-byte flash dump succeeded."
        echo "       $HEAD_DUMP_FILE"
        if [[ -f "$HEAD_DUMP_FILE" ]] && command -v sha256sum >/dev/null 2>&1; then
            head_hash="$(sha256sum "$HEAD_DUMP_FILE" | awk '{print $1}')"
            echo "       sha256=$head_hash"
        fi
    else
        echo -e "[${CL_Y}WARN${CL_NC}] 256-byte flash dump did not report success."
        warnings=$((warnings + 1))
    fi

    echo
    if [[ $warnings -eq 0 ]]; then
        echo -e "[ ${CL_G}OK${CL_NC} ] Verdict: target is readable and FAP appears disabled."
    else
        echo -e "[${CL_Y}WARN${CL_NC}] Verdict: protection state is inconclusive; review the log."
    fi

    return "$warnings"
}

echo
echo "$D"
echo "              AT32F415 RDP / FAP hardware check"
echo "$D"
echo
echo "Target config:"
echo "       $TEST_TARGET"
echo
echo "Log file:"
echo "       $LOG_FILE"
echo

run_openocd_test "command surface" \
    -c "help at32f4xx" \
    -c "usage flash info" \
    -c "usage flash protect"

run_openocd_test "connect, halt, probe, flash info" \
    -c "init" \
    -c "reset halt" \
    -c "flash probe 0" \
    -c "flash info 0"

run_openocd_test "read USD / FAP option area" \
    -c "init" \
    -c "reset halt" \
    -c "flash probe 0" \
    -c "mdw 0x1FFFF800 4"

run_openocd_test "read flash vector words" \
    -c "init" \
    -c "reset halt" \
    -c "flash probe 0" \
    -c "mdw 0x08000000 8"

run_openocd_test "small flash dump smoke test" \
    -c "init" \
    -c "reset halt" \
    -c "flash probe 0" \
    -c "dump_image {$HEAD_DUMP_FILE} 0x08000000 0x100"

summary_rc=0
summarize_results || summary_rc=$?

echo
echo "$D"
echo "RDP check complete."
echo "$D"
echo
echo "Review log:"
echo "       $LOG_FILE"
echo

exit "$summary_rc"
