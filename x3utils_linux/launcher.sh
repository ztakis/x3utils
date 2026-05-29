#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

dragged_file=""
display_name=""

while true; do
    clear

    echo "======================================================================="
    echo "               ST-LINK UTILITIES FOR X3 scooters - v1.0"
    echo "======================================================================="
    echo

    if [[ -n "$dragged_file" ]]; then
        echo " [LOADED] Target File:"
        echo "          \"$display_name\""
    else
        echo " [LOADED] No file loaded"
    fi

    echo
    echo " [1] Flash SHU compatible"
    echo " [2] Run Full Memory Dump (128 KB)"
    echo " [3] Flash Loaded File to Chip"
    echo " [4] Load / Change Target .bin File"
    echo " [5] Exit"
    echo
    echo "======================================================================="
    echo

    read -rp "Select an option [1-5]: " choice

    case "$choice" in
        1)
            echo
            echo "Launching Flash SHU compatible..."
            echo

            if [[ -f "$SCRIPT_DIR/flash_cmp.sh" ]]; then
                bash "$SCRIPT_DIR/flash_cmp.sh"
            else
                echo "[FAIL] Could not find flash_cmp.sh."
                read -rp "Press ENTER to continue..."
            fi
            ;;

        2)
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

        3)
            if [[ -z "$dragged_file" ]]; then
                echo
                echo "[FAIL] You cannot flash without loading a file first."
                echo "       Please select Option [4] to load a file."
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

        4)
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
            input_file="${input_file%\'}"
            input_file="${input_file#\'}"

            input_file="${input_file%\"}"
            input_file="${input_file#\"}"

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

            dragged_file="$(realpath "$input_file")"
            display_name="$(basename "$dragged_file")"
            ;;

        5)
            clear
            echo
            echo "Exiting utility. Bye!"
            sleep 2
            exit 0
            ;;

        *)
            echo
            echo "[FAIL] Invalid selection."
            echo "       Please choose 1, 2, 3, 4 or 5."
            sleep 2
            ;;
    esac
done
