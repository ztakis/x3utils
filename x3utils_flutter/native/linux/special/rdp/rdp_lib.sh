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
#                         C nrst, D power-race when RACE=true. Faster on a
#                         cooperative board (esp. Mode C auto-reset), but Mode A
#                         can't reach a locked board.
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
    CONN_RACE=0
    if [[ "${USE_LAUNCHER:-0}" -eq 1 ]]; then
        if [[ "${RACE:-false}" == "true" ]]; then
            OOCD_PRE=(-f "target/at32f415xx_race.cfg")
            OOCD_CONNECT=(-c "race_connect")
            CONN_MODE="Power-race — respawn"
            CONN_RACE=1
        elif [[ "$TARGET" == *_c45.cfg ]]; then
            OOCD_PRE=(-f "$TARGET")                                  # c45 bundles the interface
            OOCD_CONNECT=(-c "guided_connect {$CONNECT_TIMEOUT}")
            CONN_MODE="C45 clone — guided connect-under-reset"
        elif [[ "$TARGET" == *_nrst.cfg ]]; then
            OOCD_PRE=(-f "$INTERFACE" -f "$TARGET")
            OOCD_CONNECT=(-c "init" -c "reset halt")
            CONN_MODE="C45 genuine — ST-Link reset"
        else
            OOCD_PRE=(-f "$INTERFACE" -f "$TARGET")
            OOCD_CONNECT=(-c "init" -c "reset halt")
            CONN_MODE="Default SWD — plain"
        fi
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
    [[ "${USE_LAUNCHER:-0}" -eq 1 && "${RACE:-false}" != "true" && "$TARGET" != *_c45.cfg && "$TARGET" != *_nrst.cfg ]]
}
