#!/bin/bash

# Initial settings
current_radio="A"
timeout_val="5"

while true; do
    clear
    echo "===================================================="
    echo "                    MY MENU"
    echo "===================================================="
    echo ""
    echo "[ Radio Options - Press A, B, or C to change ]"
    
    if [ "$current_radio" = "A" ]; then echo "   [X] Option A"; else echo "   [ ] Option A"; fi
    if [ "$current_radio" = "B" ]; then echo "   [X] Option B"; else echo "   [ ] Option B"; fi
    if [ "$current_radio" = "C" ]; then echo "   [X] Option C"; else echo "   [ ] Option C"; fi
    
    echo ""
    echo "[ Configuration ]"
    echo "   T. Set Timeout (Current: ${timeout_val}s)"
    echo ""
    echo "[ Actions - Press 1-5 to execute ]"
    echo "   1. Execute Task 1"
    echo "   2. Execute Task 2"
    echo "   3. Execute Task 3"
    echo "   4. Execute Task 4"
    echo "   5. Exit"
    echo ""

    read -n 1 -s -p "Press a key (1-5, A-C, or T): " key

    case "$key" in
        [aA])
            current_radio="A"
            ;;
        [bB])
            current_radio="B"
            ;;
        [cC])
            current_radio="C"
            ;;
        [tT])
            echo ""
            echo ""
            read -p "Enter new timeout display value (0-60): " timeout_val
            ;;
        1)
            echo ""
            echo ""
            echo "Executing Task 1..."
            echo "Radio: $current_radio | Timeout Var: ${timeout_val}s"
            read -p "Press [Enter] to continue..."
            ;;
        2)
            echo ""
            echo ""
            echo "Executing Task 2..."
            echo "Radio: $current_radio | Timeout Var: ${timeout_val}s"
            read -p "Press [Enter] to continue..."
            ;;
        3)
            echo ""
            echo ""
            echo "Executing Task 3..."
            read -p "Press [Enter] to continue..."
            ;;
        4)
            echo ""
            echo ""
            echo "Executing Task 4..."
            read -p "Press [Enter] to continue..."
            ;;
        5)
            echo ""
            echo ""
            echo "Exiting..."
            sleep 1
            exit 0
            ;;
        *)
            # Refresh if an invalid key is pressed
            ;;
    esac
done
