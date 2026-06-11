#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION=$(<"$SCRIPT_DIR/VERSION")

dragged_file=""
display_name=""

# --- VALIDATE config.sh exists ---
if [[ ! -f "$SCRIPT_DIR/config.sh" ]]; then
    echo "[FAIL] Missing config.sh"
    exit 1
fi

# --- ENSURE config.sh is writable ---
if [[ ! -w "$SCRIPT_DIR/config.sh" ]]; then
    chmod u+w "$SCRIPT_DIR/config.sh"
    if [[ ! -w "$SCRIPT_DIR/config.sh" ]]; then
        echo "[FAIL] config.sh is not writable and could not be fixed."
        echo "       Run: chmod u+w config.sh"
        exit 1
    fi
fi

# Detect current ALT state from config.sh
detect_alt() {
    if grep -q 'TARGET="target/at32f415xx_alt\.cfg"' "$SCRIPT_DIR/config.sh"; then
        echo "X"
    else
        echo " "
    fi
}

# Toggle ALT: swap TARGET filename in config.sh
toggle_alt() {
    local tmp="$SCRIPT_DIR/config.tmp"

    if [[ "$ALT" == " " ]]; then
        sed 's|at32f415xx\.cfg|at32f415xx_alt.cfg|' "$SCRIPT_DIR/config.sh" > "$tmp"
    else
        sed 's|at32f415xx_alt\.cfg|at32f415xx.cfg|' "$SCRIPT_DIR/config.sh" > "$tmp"
    fi

    if [[ ! -f "$tmp" ]]; then
        echo
        echo "[FAIL] Could not write config update. config.sh unchanged."
        read -rp "Press ENTER to continue..."
        return
    fi

    mv "$tmp" "$SCRIPT_DIR/config.sh"

    # Verify the change took effect
    local new_alt
    new_alt=$(detect_alt)
    if [[ "$new_alt" == "$ALT" ]]; then
        echo
        echo "[FAIL] config.sh did not update correctly."
        read -rp "Press ENTER to continue..."
        return
    fi

    ALT="$new_alt"
}

ALT=$(detect_alt)

while true; do
    clear

    echo "==============================================================="
    echo "          ST-LINK UTILITIES FOR X3 scooters - v$VERSION"
    echo "==============================================================="
    echo

    if [[ -n "$dragged_file" ]]; then
        echo " [LOADED] Target File:"
        echo "          \"$display_name\""
    else
        echo " [LOADED] No file loaded"
    fi

    echo
    echo " [1] Flash SHU compatible (ZT3, G3, F3/F3Pro)"
    echo " [2] Flash SHU compatible (GT3 - Experimental)"
    echo " [3] Run Full Memory Dump (128 KB)"
    echo " [4] Flash Loaded File to Chip"
    echo " [5] Load / Change Target .bin File"
    echo
    if [[ "$ALT" == "X" ]]; then
        echo -e " \033[33m[A] [X] Alternative target configuration (connect-under-reset)\033[0m"
    else
        echo " [A] [ ] Alternative target configuration (connect-under-reset)"
    fi
    echo
    echo " [6] Exit"
    echo
    echo "==============================================================="
    echo

    read -rp "Select an option [1-6, A]: " choice

    case "$choice" in
        a|A)
            toggle_alt
            ;;
        1)
            echo
            echo "Launching Flash SHU compatible (ZT3/G3/F3/F3Pro)..."
            echo

            if [[ -f "$SCRIPT_DIR/flash_compat.sh" ]]; then
                bash "$SCRIPT_DIR/flash_compat.sh"
            else
                echo "[FAIL] Could not find flash_compat.sh."
                read -rp "Press ENTER to continue..."
            fi
            ;;
        2)
            echo
            echo "Launching Flash GT3 SHU compatible..."
            echo

            if [[ -f "$SCRIPT_DIR/flash_gt3_compat.sh" ]]; then
                bash "$SCRIPT_DIR/flash_gt3_compat.sh"
            else
                echo "[FAIL] Could not find flash_gt3_compat.sh."
                read -rp "Press ENTER to continue..."
            fi
            ;;
        3)
            echo
            echo "Launching Full Memory Dump Utility..."
            echo

            if [[ -f "$SCRIPT_DIR/dump.sh" ]]; then
                bash "$SCRIPT_DIR/dump.sh"
            else
                echo "[FAIL] Could not find dump.sh."
                read -rp "Press ENTER to continue..."
            fi
            ;;
        4)
            if [[ -z "$dragged_file" ]]; then
                echo
                echo "[FAIL] You cannot flash without loading a file first."
                echo "       Please select Option [5] to load a file."
                echo
                read -rp "Press ENTER to continue..."
                continue
            fi

            echo
            echo "Launching Flash Utility for:"
            echo "       \"$display_name\""
            echo

            if [[ -f "$SCRIPT_DIR/flash.sh" ]]; then
                bash "$SCRIPT_DIR/flash.sh" "$dragged_file"
            else
                echo "[FAIL] Could not find flash.sh."
                read -rp "Press ENTER to continue..."
            fi
            ;;
        5)
            echo
            echo "======================================================"
            echo "       Please enter the path to your .bin file"
            echo "======================================================"
            echo

            read -rp "File path (or type 'back'): " input_file

            if [[ "$input_file" == "back" ]]; then
                continue
            fi

            # Remove surrounding single or double quotes
            input_file="${input_file//\"/}"
            input_file="${input_file//\'/}"

            if [[ -z "$input_file" ]]; then
                continue
            fi

            if [[ ! -f "$input_file" ]]; then
                echo
                echo "[FAIL] File does not exist."
                read -rp "Press ENTER to continue..."
                dragged_file=""
                display_name=""
                continue
            fi

            if [[ "$input_file" =~ [{}] ]]; then
                echo "[FAIL] Path contains unsupported character: { or }"
                echo "       Please rename."
                read -rp "Press ENTER to continue..."
                dragged_file=""
                display_name=""
                continue
            fi

            extension="${input_file##*.}"

            if [[ "${extension,,}" != "bin" ]]; then
                echo
                echo "[FAIL] Only .bin files are allowed."
                read -rp "Press ENTER to continue..."
                dragged_file=""
                display_name=""
                continue
            fi

            dragged_file="$(readlink -f "$input_file" 2>/dev/null || echo "$input_file")"
            display_name="$(basename "$dragged_file")"
            ;;
        6)
            clear
            echo
            echo "Exiting utility. Bye!"
            sleep 2
            exit 0
            ;;
        *)
            echo
            echo "[FAIL] Invalid selection."
            echo "       Please choose 1-6 or A."
            sleep 2
            ;;
    esac
done
