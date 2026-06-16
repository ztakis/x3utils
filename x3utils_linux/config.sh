#!/bin/bash

# --- COLORS ---
export CL_NC="\033[0m"
export CL_R="\033[1;31m"
export CL_G="\033[1;32m"
export CL_Y="\033[1;33m"
export CL_M="\033[1;35m"
export CL_C="\033[1;36m"


# --- OPENOCD CONFIGURATION ---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OPENOCD_BIN="$SCRIPT_DIR/oocd/bin/openocd"
SCRIPTS_DIR="$SCRIPT_DIR/oocd/scripts"

INTERFACE="interface/stlink.cfg"
TARGET="target/at32f415xx.cfg"

CONNECT_TIMEOUT=7

# --- COMMON SETTINGS ---

EXPECTED_SIZE=131072

# --- VALIDATION ---

if [[ ! -f "$OPENOCD_BIN" ]]; then
    echo -e "[${CL_R}FAIL${CL_NC}] OpenOCD binary not found."
    echo "       Expected: $OPENOCD_BIN"
    exit 1
fi

if [[ ! -x "$OPENOCD_BIN" ]]; then
    echo -e "[${CL_R}FAIL${CL_NC}] OpenOCD binary is not executable."
    echo "       Run: chmod +x $OPENOCD_BIN"
    exit 1
fi

if [[ ! -d "$SCRIPTS_DIR" ]]; then
    echo -e "[${CL_R}FAIL${CL_NC}] OpenOCD scripts directory not found."
    echo "       Expected: $SCRIPTS_DIR"
    exit 1
fi
