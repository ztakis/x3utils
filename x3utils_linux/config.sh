#!/bin/bash

# --- OPENOCD CONFIGURATION ---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OPENOCD_BIN="$SCRIPT_DIR/oocd/bin/openocd"
SCRIPTS_DIR="$SCRIPT_DIR/oocd/scripts"

INTERFACE="interface/stlink.cfg"
TARGET="target/at32f415xx.cfg"

# --- COMMON SETTINGS ---

EXPECTED_SIZE=131072
