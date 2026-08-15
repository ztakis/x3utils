#!/bin/bash

set -e

echo "======================================="
echo " X3 Utilities macOS Installer"
echo "======================================="
echo

# Ensure script runs from its own directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

setup_brew_path() {
    local brew_bin="$1"
    local profile="$HOME/.zprofile"
    local shellenv_line="eval \"\$($brew_bin shellenv)\""
    local answer

    echo "[WARN] Homebrew was found, but the 'brew' command is not active in this Terminal."
    echo "       Found: $brew_bin"
    echo
    echo "Note: the command is 'brew', not 'homebrew'."
    echo
    if ! read -rp "Add Homebrew to ~/.zprofile and continue? [Y/N]: " answer; then
        answer=""
        echo
    fi

    case "$answer" in
        y|Y|yes|YES|Yes)
            touch "$profile"

            if ! grep -Fq "$shellenv_line" "$profile"; then
                {
                    echo
                    echo "$shellenv_line"
                } >> "$profile"
            fi

            eval "$("$brew_bin" shellenv)"

            if command -v brew >/dev/null 2>&1; then
                echo
                echo "[ OK ] Homebrew PATH configured for this Terminal."
                echo "       It will also be available in new Terminal windows."
                echo
            else
                echo
                echo "[FAIL] Tried to configure Homebrew PATH, but 'brew' is still unavailable."
                echo "       Close Terminal, reopen it, and run ./installer.sh again."
                exit 1
            fi
            ;;
        *)
            echo
            echo "[FAIL] Homebrew is installed but not active in this Terminal."
            echo
            echo "Run these commands manually, then rerun ./installer.sh:"
            echo
            echo "    echo '$shellenv_line' >> ~/.zprofile"
            echo "    $shellenv_line"
            echo
            echo "Then check:"
            echo
            echo "    brew --version"
            echo
            exit 1
            ;;
    esac
}

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

# Check Homebrew, including the common case where it is installed but not in PATH.
if ! command -v brew >/dev/null 2>&1; then
    if [[ -x /opt/homebrew/bin/brew ]]; then
        setup_brew_path "/opt/homebrew/bin/brew"
    elif [[ -x /usr/local/bin/brew ]]; then
        setup_brew_path "/usr/local/bin/brew"
    else
        echo "[FAIL] Homebrew is not installed."
        echo
        echo "Install Homebrew first:"
        echo "https://brew.sh"
        echo
        echo "After installing, follow Homebrew's 'Next steps' commands."
        echo "Then run:"
        echo "    brew --version"
        echo
        echo "Note: the command is 'brew', not 'homebrew'."
        exit 1
    fi
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
