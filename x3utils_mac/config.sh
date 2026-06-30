#!/bin/bash

# --- COLORS ---
export CL_NC="\033[0m"
export CL_R="\033[1;31m"
export CL_G="\033[1;32m"
export CL_Y="\033[1;33m"
export CL_M="\033[1;35m"
export CL_C="\033[1;36m"
export D="============================================================"

# --- OPENOCD CONFIGURATION ---

CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- ARCHITECTURE DETECTION ---
# Picks the correct bundled xpack-openocd build for this Mac.
# Mirrors the detection in installer.sh -- keep both in sync.
ARCH="$(uname -m)"

case "$ARCH" in
    arm64)
        OPENOCD_ROOT="$CONFIG_DIR/xpack-openocd-0.12.0-7-darwin-arm64"
        ;;
    x86_64)
        OPENOCD_ROOT="$CONFIG_DIR/xpack-openocd-0.12.0-7-darwin-x64"
        ;;
    *)
        echo -e "[${CL_R}FAIL${CL_NC}] Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

OPENOCD_BIN="$OPENOCD_ROOT/bin/openocd"
SCRIPTS_DIR="$OPENOCD_ROOT/openocd/scripts"

INTERFACE="interface/stlink.cfg"
TARGET="target/artery/at32f4x.cfg"

CONNECT_TIMEOUT=3

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
