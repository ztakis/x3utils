#!/bin/bash

set -e

echo "======================================="
echo " X3 Utilities macOS Installer"
echo "======================================="
echo

# Ensure script runs from its own directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Detect architecture
ARCH="$(uname -m)"

echo "[INFO] Detected architecture: $ARCH"

if [[ "$ARCH" == "arm64" ]]; then
    echo "[INFO] Apple Silicon detected."
    OPENOCD_ROOT="$SCRIPT_DIR/xpack-openocd-0.12.0-7-darwin-arm64"
elif [[ "$ARCH" == "x86_64" ]]; then
    echo "[INFO] Intel Mac detected."
    OPENOCD_ROOT="$SCRIPT_DIR/xpack-openocd-0.12.0-7-darwin-x64"
else
    echo "[FAIL] Unsupported architecture: $ARCH"
    exit 1
fi

OPENOCD_BIN="$OPENOCD_ROOT/bin/openocd"

echo

# Verify bundled OpenOCD exists
if [[ ! -f "$OPENOCD_BIN" ]]; then
    echo "[FAIL] Bundled OpenOCD binary missing."
    echo "       Expected:"
    echo "       $OPENOCD_BIN"
    exit 1
fi

echo "[ OK ] Bundled OpenOCD located."
echo

# Check Homebrew
if ! command -v brew >/dev/null 2>&1; then
    echo "[FAIL] Homebrew is not installed."
    echo
    echo "Install Homebrew first:"
    echo "https://brew.sh"
    exit 1
fi

echo "[ OK ] Homebrew detected."
echo

echo "[INFO] Installing required dependencies..."
echo

brew install hidapi libusb python

echo
echo "[INFO] Setting executable permissions..."
echo

chmod +x *.sh
chmod +x "$OPENOCD_BIN"

echo
echo "[INFO] Testing bundled OpenOCD..."
echo

if "$OPENOCD_BIN" --version >/dev/null 2>&1; then
    echo "[ OK ] Bundled OpenOCD executable works."
else
    echo "[FAIL] Bundled OpenOCD launch test failed."
    exit 1
fi

echo
echo "======================================="
echo " INSTALLATION COMPLETE"
echo "======================================="
echo
echo "[ OK ] X3 Utilities is ready."
echo
echo "Run:"
echo "    ./launcher.sh"
echo