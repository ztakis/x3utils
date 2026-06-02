#!/bin/bash

# --- OPENOCD CONFIGURATION ---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ARCH="$(uname -m)"

if [[ "$ARCH" == "arm64" ]]; then
    OPENOCD_ROOT="$SCRIPT_DIR/xpack-openocd-0.12.0-7-darwin-arm64"
else
    OPENOCD_ROOT="$SCRIPT_DIR/xpack-openocd-0.12.0-7-darwin-x64"
fi

OPENOCD_BIN="$OPENOCD_ROOT/bin/openocd"
SCRIPTS_DIR="$OPENOCD_ROOT/openocd/scripts"

INTERFACE="interface/stlink.cfg"
TARGET="target/artery/at32f4x.cfg"

# --- COMMON SETTINGS ---

EXPECTED_SIZE=131072
