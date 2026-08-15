#!/bin/bash

# Read-only ST-LINK and target connection check.
# Uses the connection mode currently selected in launcher.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.sh"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[FAIL] Missing config.sh"
    exit 1
fi

source "$CONFIG_FILE"

race_last="${TMPDIR:-/tmp}/x3utils_race_last.log"
trap 'rm -f "$race_last"' EXIT

echo
echo "$D"
echo "             Testing ST-LINK connection..."
echo "$D"
echo
echo "   This test reads no firmware and writes nothing."
echo

while true; do
    # Modes A, B and C keep OpenOCD output live so guided C45 prompts remain
    # interactive. Their exit status is enough because flash probe is the last
    # hardware operation before exit.
    if [[ "${RACE:-false}" != "true" ]]; then
        if [[ "$TARGET" == "target/artery/at32f4x_c45.cfg" ]]; then
            echo "   Mode: B - C45 / Clone ST-Link"
            echo

            "$OPENOCD_BIN" -s "$SCRIPTS_DIR" -d0 \
                -f "$TARGET" \
                -c "guided_connect {$CONNECT_TIMEOUT}" \
                -c "flash probe 0" \
                -c "exit"
        else
            if [[ "$TARGET" == "target/artery/at32f4x_nrst.cfg" ]]; then
                echo "   Mode: C - C45 / Genuine ST-Link"
            else
                echo "   Mode: A - Default / Blinker buttons"
            fi
            echo

            "$OPENOCD_BIN" -s "$SCRIPTS_DIR" -d0 \
                -f "$INTERFACE" \
                -f "$TARGET" \
                -c "adapter speed 1000" \
                -c "init" \
                -c "reset halt" \
                -c "flash probe 0" \
                -c "exit"
        fi

        openocd_result=$?
        if [[ $openocd_result -eq 0 ]]; then
            echo
            echo -e "[ ${CL_G}CONNECTED${CL_NC} ] ST-LINK and target answered correctly."
            echo -e "[ ${CL_G}OK${CL_NC} ] Flash bank detected."
            echo
            echo "   You can continue with backup or flashing."
            echo
            read -rp "Press ENTER to continue..."
            exit 0
        fi

        echo
        echo -e "[${CL_Y}RETRY${CL_NC}] Could not connect to the ST-LINK and target."
        echo
        echo "       Check the ST-LINK USB connection, selected mode, and SWD contacts."
        echo "       For C45, touch the metal contact point, not the capacitor body."
        echo
        read -rp "$(echo -e "${CL_C}Press ENTER to retry, or type Q to quit: ${CL_NC}")" retry_choice
        retry_choice_lc="$(echo "$retry_choice" | tr '[:upper:]' '[:lower:]')"
        if [[ "$retry_choice_lc" == "q" ]]; then
            exit 1
        fi
        echo
        continue
    fi

    # Mode D needs a fresh OpenOCD process for every missed power-on window.
    # A successful verdict requires the expected flash-probe evidence, not only
    # a halted core or exit status 0.
    echo "   Mode: D - Power-race / no reset line"
    echo
    echo "   Hammering connection attempts."
    echo -e "   ${CL_C}Apply POWER now${CL_NC}; if it misses, cut and re-apply POWER."
    echo "   Each power-ON is a fresh connection window."
    echo
    echo -e "   ${CL_C}Ctrl+C to stop.${CL_NC}"
    echo -e "   Live: .=searching  ${CL_Y}N${CL_NC}=noisy, hold steadier"
    echo -e "         ${CL_G}H${CL_NC}=almost    ${CL_R}x${CL_NC}=probe/USB gone"
    echo

    race_tries=0
    while true; do
        race_tries=$((race_tries + 1))

        "$OPENOCD_BIN" -s "$SCRIPTS_DIR" -d0 \
            -f "target/artery/at32f4x_race.cfg" \
            -c "race_connect" \
            -c "flash probe 0" \
            -c "exit" > "$race_last" 2>&1
        openocd_result=$?

        if [[ $openocd_result -ne 0 ]]; then
            if grep -qi "open failed" "$race_last"; then
                echo
                echo
                echo -e "[${CL_Y}WAIT${CL_NC}] ST-LINK adapter not found."
                echo
                echo "       Plug or reconnect the ST-LINK."
                echo "       Close another program if it is using the adapter."
                echo
                read -rp "$(echo -e "${CL_C}Press ENTER to retry, or type Q to quit: ${CL_NC}")" retry_choice
                retry_choice_lc="$(echo "$retry_choice" | tr '[:upper:]' '[:lower:]')"
                if [[ "$retry_choice_lc" == "q" ]]; then
                    exit 1
                fi
                echo
                break
            fi

            bash "$SCRIPT_DIR/race_grade.sh" "$race_last"
            continue
        fi

        if ! grep -qi "flash 'artery' found" "$race_last"; then
            bash "$SCRIPT_DIR/race_grade.sh" "$race_last"
            continue
        fi

        echo
        echo
        cat "$race_last"
        echo
        echo -e "[ ${CL_G}CONNECTED${CL_NC} ] Target answered on attempt $race_tries."
        echo
        read -rp "Press ENTER to continue..."
        exit 0
    done
done
