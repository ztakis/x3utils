#!/bin/bash
#
# race_grade.sh - shared power-race attempt classifier.
#
# Called by dump.sh / flash.sh / flash_compat.sh and special flash tools after a
# missed attempt. Reads the supplied attempt log and prints one live symbol:
#   x  ST-Link/probe gone from USB
#   H  target halted, near catch
#   N  Cortex-M4 seen but not halted, noisy/marginal contact
#   .  not connected/searching

attempt_log="${1:-${race_last:-}}"

if [[ -z "$attempt_log" || ! -f "$attempt_log" ]]; then
    printf "."
    exit 0
fi

if grep -q "open failed" "$attempt_log"; then
    printf "%b" "${CL_R}x${CL_NC}"
    sleep 1
    exit 0
fi

if grep -q "target halted" "$attempt_log"; then
    printf "%b" "${CL_G}H${CL_NC}"
    exit 0
fi

if grep -q "Cortex-M4" "$attempt_log"; then
    printf "%b" "${CL_Y}N${CL_NC}"
    exit 0
fi

printf "."
exit 0
