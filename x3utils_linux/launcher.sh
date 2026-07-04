#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION=$(<"$SCRIPT_DIR/VERSION")

dragged_file=""
display_name=""

# --- VALIDATE config.sh exists ---
if [[ ! -f "$SCRIPT_DIR/config.sh" ]]; then
    echo -e "[${CL_R}FAIL${CL_NC}] Missing config.sh"
    exit 1
fi

# --- ENSURE config.sh is writable ---
if [[ ! -w "$SCRIPT_DIR/config.sh" ]]; then
    chmod u+w "$SCRIPT_DIR/config.sh"
    if [[ ! -w "$SCRIPT_DIR/config.sh" ]]; then
        echo -e "[${CL_R}FAIL${CL_NC}] config.sh is not writable and could not be fixed."
        echo "       Run: chmod u+w config.sh"
        exit 1
    fi
fi

source "$SCRIPT_DIR/config.sh"

# --- RADIO GROUP: detect current TARGET from config.sh ---
detect_radio() {
    if grep -q 'at32f415xx_c45\.cfg' "$SCRIPT_DIR/config.sh"; then
        echo "B"
    elif grep -q 'at32f415xx_nrst\.cfg' "$SCRIPT_DIR/config.sh"; then
        echo "C"
    else
        echo "A"
    fi
}

# --- RADIO GROUP: write new TARGET to config.sh ---
set_radio() {
    local new_radio="$1"
    local new_cfg tmp

    [[ "$new_radio" == "$current_radio" ]] && return 0

    case "$new_radio" in
        A) new_cfg="at32f415xx.cfg" ;;
        B) new_cfg="at32f415xx_c45.cfg" ;;
        C) new_cfg="at32f415xx_nrst.cfg" ;;
    esac

    tmp="$SCRIPT_DIR/config.tmp"
    sed "s|target/[^\"]*\.cfg|target/$new_cfg|" "$SCRIPT_DIR/config.sh" > "$tmp"

    if [[ ! -f "$tmp" ]]; then
        echo
        echo -e "[${CL_R}FAIL${CL_NC}] Could not write config update. config.sh unchanged."
        read -rp "Press ENTER to continue..."
        return 1
    fi

    mv "$tmp" "$SCRIPT_DIR/config.sh"
    chmod +x "$SCRIPT_DIR/config.sh"

    # Verify the change took effect
    local check
    check=$(detect_radio)
    if [[ "$check" != "$new_radio" ]]; then
        echo
        echo -e "[${CL_R}FAIL${CL_NC}] config.sh did not update correctly."
        read -rp "Press ENTER to continue..."
        return 1
    fi

    current_radio="$new_radio"
    # Keep in-memory TARGET in sync
    TARGET="target/$new_cfg"
}

# --- TIMEOUT: write new CONNECT_TIMEOUT to config.sh ---
set_timeout() {
    local new_val="$1"
    local tmp="$SCRIPT_DIR/config.tmp"

    sed "s|CONNECT_TIMEOUT=[0-9]*|CONNECT_TIMEOUT=$new_val|" "$SCRIPT_DIR/config.sh" > "$tmp"

    if [[ ! -f "$tmp" ]]; then
        echo
        echo -e "[${CL_R}FAIL${CL_NC}] Could not write config update. config.sh unchanged."
        read -rp "Press ENTER to continue..."
        return 1
    fi

    mv "$tmp" "$SCRIPT_DIR/config.sh"
    chmod +x "$SCRIPT_DIR/config.sh"
    timeout_val="$new_val"
}

current_radio=$(detect_radio)
timeout_val="$CONNECT_TIMEOUT"

while true; do

    clear
    echo
    echo "  * * * * * * * * * * * * * * * * * * * * * * * * * "
    echo "  *         __                                    * "
    echo "  *          /                                    * "
    echo "  *        D/               ST-LINK utilities     * "
    echo "  *        /                 for X3 scooters      * "
    echo "  *       /                       $VERSION          * "
    echo "  *      /\________/\"\"                            * "
    echo "  *    (o)         (o)                            * "
    echo "  * * * * * * * * * * * * * * * * * * * * * * * * * "
    echo

    if [[ -n "$dragged_file" ]]; then
        echo " [LOADED] Target File:"
        echo -e "          ${CL_Y}\"$display_name\"${CL_NC}"
    else
        echo " [LOADED] No file loaded"
    fi

    echo
    echo -e " [ ${CL_C}Actions - Enter 1-5 to execute${CL_NC} ]"
    echo "  [1] Flash SHU compatible (ZT3, G3, F3/F3Pro)"
    echo "  [2] Run Full Memory Dump (128 KB)"
    echo "  [3] Flash Loaded File to Chip"
    echo "  [4] Load / Change Target .bin File"
    echo "  [5] Exit"
    echo
    echo -e " [ ${CL_C}Connection Options - Enter A, B, or C to change${CL_NC} ]"
    if [[ "$current_radio" == "A" ]]; then
        echo -e "  [${CL_C}X${CL_NC}] A - Default / Blinker buttons"
    else
        echo "  [ ] A - Default / Blinker buttons"
    fi
    if [[ "$current_radio" == "B" ]]; then
        echo -e "  [${CL_Y}X${CL_NC}] B - C45 / Clone ST-Link"
    else
        echo "  [ ] B - C45 / Clone ST-Link"
    fi
    if [[ "$current_radio" == "C" ]]; then
        echo -e "  [${CL_M}X${CL_NC}] C - C45 / Genuine ST-Link"
    else
        echo "  [ ] C - C45 / Genuine ST-Link"
    fi
    echo

    if [[ "$current_radio" == "B" ]]; then
        echo -e " [ ${CL_C}Configuration${CL_NC} ]"
        echo "  [T] Set countdown timer (Current: ${timeout_val}s)"
        echo
    fi

    read -rp "> Enter option: " choice

    case "$choice" in

        a|A) set_radio A ;;
        b|B) set_radio B ;;
        c|C) set_radio C ;;

        t|T)
            if [[ "$current_radio" != "B" ]]; then
                echo
                echo -e "[${CL_R}FAIL${CL_NC}] Invalid selection."
                sleep 2
                continue
            fi
            echo
            read -rp "Enter new countdown timer value (0-60): " new_timeout
            if ! [[ "$new_timeout" =~ ^[0-9]+$ ]] || (( new_timeout > 60 )); then
                echo
                echo -e "[${CL_R}FAIL${CL_NC}] Invalid value. Please enter a number between 0 and 60."
                read -rp "Press ENTER to continue..."
            else
                set_timeout "$new_timeout"
            fi
            ;;

        1)
            echo
            echo "Launching Flash SHU compatible (ZT3/G3/F3/F3Pro)..."
            echo
            if [[ -f "$SCRIPT_DIR/flash_compat.sh" ]]; then
                bash "$SCRIPT_DIR/flash_compat.sh"
                if [[ $? -ne 0 ]]; then
                    echo -e "[${CL_R}FAIL${CL_NC}] Flash script reported an error!"
                    read -rp "Press ENTER to continue..."
                fi
            else
                echo -e "[${CL_R}FAIL${CL_NC}] Could not find flash_compat.sh."
                read -rp "Press ENTER to continue..."
            fi
            ;;

        2)
            echo
            echo "Launching Full Memory Dump Utility..."
            echo
            if [[ -f "$SCRIPT_DIR/dump.sh" ]]; then
                bash "$SCRIPT_DIR/dump.sh"
                if [[ $? -ne 0 ]]; then
                    echo -e "[${CL_R}FAIL${CL_NC}] Backup script reported an error!"
                    read -rp "Press ENTER to continue..."
                fi
            else
                echo -e "[${CL_R}FAIL${CL_NC}] Could not find dump.sh."
                read -rp "Press ENTER to continue..."
            fi
            ;;

        3)
            if [[ -z "$dragged_file" ]]; then
                echo
                echo -e "[${CL_R}FAIL${CL_NC}] You cannot flash without loading a file first."
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
                if [[ $? -ne 0 ]]; then
                    read -rp "Press ENTER to continue..."
                fi
            else
                echo -e "[${CL_R}FAIL${CL_NC}] Could not find flash.sh."
                read -rp "Press ENTER to continue..."
            fi
            ;;

        4)
            echo
            echo "$D"
            echo "          Please enter the path to your .bin file"
            echo "$D"
            echo

            read -rp "File path (or type 'back'): " input_file

            if [[ "$input_file" == "back" ]]; then
                continue
            fi

            # Remove surrounding single or double quotes
            input_file="${input_file//\"/}"
            input_file="${input_file//\'/}"

            # Validate bin file
            source "$SCRIPT_DIR/validate_bin.sh" "$input_file"
            if [[ "$VALIDATE_RESULT" != "OK" ]]; then
                echo -e "[${CL_R}FAIL${CL_NC}] $VALIDATE_MSG"
                read -rp "Press ENTER to continue..."
                dragged_file=""
                display_name=""
                continue
            fi

            dragged_file="$BIN_FILE_PATH"
            display_name="$BIN_FILE_NAME"
            ;;

        5)
            clear
            echo
            echo "Exiting utility. Bye!"
            sleep 1
            exit 0
            ;;

        *)
            echo
            echo -e "[${CL_R}FAIL${CL_NC}] Invalid selection."
            echo "       Please choose 1-5, A-C$(  [[ "$current_radio" == "B" ]] && echo ", or T")."
            sleep 1
            ;;

    esac
done
