#!/bin/bash

# --- OPENOCD CONFIGURATION ---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OPENOCD_BIN="$SCRIPT_DIR/oocd/bin/openocd"
SCRIPTS_DIR="$SCRIPT_DIR/oocd/scripts"

INTERFACE="interface/stlink.cfg"
TARGET="target/at32f415xx_alt.cfg"

# --- COMMON SETTINGS ---

EXPECTED_SIZE=131072

# --- VALIDATION ---

if [[ ! -f "$OPENOCD_BIN" ]]; then
    echo "[FAIL] OpenOCD binary not found."
    echo "       Expected: $OPENOCD_BIN"
    exit 1
fi

if [[ ! -x "$OPENOCD_BIN" ]]; then
    echo "[FAIL] OpenOCD binary is not executable."
    echo "       Run: chmod +x $OPENOCD_BIN"
    exit 1
fi

if [[ ! -d "$SCRIPTS_DIR" ]]; then
    echo "[FAIL] OpenOCD scripts directory not found."
    echo "       Expected: $SCRIPTS_DIR"
    exit 1
fi
