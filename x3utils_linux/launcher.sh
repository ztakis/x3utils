#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION=$(<"$SCRIPT_DIR/VERSION")

dragged_file=""
display_name=""

while true; do
    clear

    echo "======================================================================="
    echo "             ST-LINK UTILITIES FOR X3 scooters - v$VERSION"
    echo "======================================================================="
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
    echo " [6] Exit"
    echo
    echo "======================================================================="
    echo

    read -rp "Select an option [1-6]: " choice

    case "$choice" in
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
            echo "======================================================="
            echo " Please enter the path to your .bin file"
            echo "======================================================="
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
            echo "       Please choose 1, 2, 3, 4, 5 or 6."
            sleep 2
            ;;
    esac
done
