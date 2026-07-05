#!/bin/bash
#
# rdp_lib.sh — shared helpers for the special/rdp/ tools.
# Source AFTER config.sh (needs INTERFACE, TARGET, CONNECT_TIMEOUT, CL_* , D).
#
# Connection model (uniform across all rdp tools):
#   default (no flag)  -> rescue.cfg guided_rescue: universal manual
#                         connect-under-reset. Works on ANY board (clone or
#                         genuine ST-Link, running/locked/blank FW) because it
#                         halts the core before firmware runs.
#   -l / --launcher    -> honor the launcher-selected mode in config.sh
#                         ($TARGET): A plain init, B guided_connect (c45),
#                         C nrst. Faster on a cooperative board (esp. Mode C
#                         auto-reset), but Mode A can't reach a locked board.
#
# resolve_connect sets, for the caller to expand into its OpenOCD call:
#   OOCD_PRE[]      the -f arguments
#   OOCD_CONNECT[]  the connect -c arguments
#   CONN_MODE       human-readable label

_CLIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESCUE_CFG="$_CLIB_DIR/rescue.cfg"

# Deterministic option-area rewrite: erase USD, program ONLY FAP=0x5AA5
# (FAP=0xA5 / nFAP=0x5A), leaving WRP/SSB/Data at erased 0xFF (unprotected).
# Raw flash-controller writes, so it works after ANY connect method.
UNLOCK_REWRITE=(
    -c "echo {--- erase USD, program FAP=0xA5 ---}"
    -c "mww 0x40022004 0x45670123"
    -c "mww 0x40022004 0xCDEF89AB"
    -c "mww 0x40022008 0x45670123"
    -c "mww 0x40022008 0xCDEF89AB"
    -c "mww 0x40022010 0x220"
    -c "mww 0x40022010 0x260"
    -c "sleep 200"
    -c "mww 0x40022010 0x210"
    -c "mwh 0x1FFFF800 0x5AA5"
    -c "sleep 200"
    -c "mww 0x40022010 0x80"
)

resolve_connect() {
    if [[ "${USE_LAUNCHER:-0}" -eq 1 ]]; then
        case "$TARGET" in
            *_c45.cfg)
                OOCD_PRE=(-f "$TARGET")                                  # c45 bundles the interface
                OOCD_CONNECT=(-c "guided_connect {$CONNECT_TIMEOUT}")
                CONN_MODE="launcher B — guided connect-under-reset (c45)"
                ;;
            *_nrst.cfg)
                OOCD_PRE=(-f "$INTERFACE" -f "$TARGET")
                OOCD_CONNECT=(-c "init" -c "reset halt")
                CONN_MODE="launcher C — ST-Link reset (connect-under-reset)"
                ;;
            *)
                OOCD_PRE=(-f "$INTERFACE" -f "$TARGET")
                OOCD_CONNECT=(-c "init" -c "reset halt")
                CONN_MODE="launcher A — plain (SWD already available)"
                ;;
        esac
    else
        [[ -f "$RESCUE_CFG" ]] || { echo -e "[${CL_R}FAIL${CL_NC}] Missing rescue.cfg beside the rdp tools"; exit 1; }
        OOCD_PRE=(-f "$RESCUE_CFG")
        OOCD_CONNECT=(-c "guided_rescue {$CONNECT_TIMEOUT}")
        CONN_MODE="default — guided connect-under-reset (rescue.cfg)"
    fi
}

# True when -l is active AND the launcher mode is A (plain) — a foot-gun for
# rescue, since plain connect can't reach the locked board you're rescuing.
launcher_mode_is_plain() {
    [[ "${USE_LAUNCHER:-0}" -eq 1 && "$TARGET" != *_c45.cfg && "$TARGET" != *_nrst.cfg ]]
}
