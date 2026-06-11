
README in progress ...

<img width="612" height="395" alt="image" src="https://github.com/user-attachments/assets/7ac5664d-2e74-4f52-8409-343e17787d9d" />

# Main Menu

**[1] Flash SHU compatible (ZT3, G3, F3/F3Pro)**  
This option dumps your current vcu firmware, patches it and then flashes it back,
so that you can use SHU to flash from repo, change serial etc.

**[2] Flash SHU compatible (GT3 - Experimental)**  
Same as above for GT3 — experimental, use with caution.

**[3] Run Full Memory Dump (128 KB)**  
Reads and saves the entire 128 KB flash memory to a backup file.
Recommended before making any changes.

**[4] Flash Loaded File to Chip**  
Flash the file selected in option 5 to the device.

**[5] Load / Change Target .bin File**  
Select the .bin file you want to flash. Do this before using option 4.

**[A] [ ] Alternative target configuration (connect-under-reset)**  
Toggles alt target mode. Currently is configured for connect-under-reset.
The setting is persistent — it stays active across sessions until toggled off.

**[6] Exit**  
Close the utility.

**Options [1], [2] and [4] force a full backup first**

<br />

## Connection procedure - needs update

To use the scripts, you need to enter special mode:  
* Remove all power from the dash, like disconnect main cable (julet).
* Connect st-link pins correctly and in a secure way but not the 3.3V pin.
* Plug st-link to usb.
* Hold both blinker buttons & keep holding.
* Plug in main power cable.
* You can now release the blinker buttons.
* As a connection test, run option [3] in Launcher script, or the dump.bat(sh) script directly.

<br />

Main cable connectors

<img width="288" height="200" alt="rsz_zt3" src="https://github.com/user-attachments/assets/a59aa2a8-e809-4a37-8c9c-a0f1ed13e7d3" />
<img width="254" height="200" alt="rsz_g3" src="https://github.com/user-attachments/assets/2ab575c5-9338-4d6a-9041-74aa619f8460" />
<img width="433" height="200" alt="rsz_julet_4" src="https://github.com/user-attachments/assets/510cfc8c-c3ff-4a59-92da-0f1ac024fe9a" />
<br /><br />

You can also ground the blinker connectors instead of pressing the buttons.

<img width="771" height="665" alt="rsz_420260605_103335" src="https://github.com/user-attachments/assets/7042371e-f17b-4a1f-bef5-1ef7dc5cc3dc" />
<img width="688" height="442" alt="rsz_20260605_103345" src="https://github.com/user-attachments/assets/74a37a88-610f-456e-98a1-fef830fb5a37" />
<br /><br />

ST-LINK pinout for G3/F3

<img width="667" height="443" alt="g3" src="https://github.com/user-attachments/assets/e40bea51-4374-4d9d-bd09-cbbc52b15e85" />
<br /><br />

ST-LINK pinout for ZT3

<img width="2244" height="1024" alt="ZT3" src="https://github.com/user-attachments/assets/871d3c47-254d-4872-bf83-a824e4387cff" />
<br /><br />

ST-LINK pinout for X3 MCU

<img width="800" height="286" alt="x3_mcu" src="https://github.com/user-attachments/assets/6d536191-0fbe-464a-8e86-58a8f21566fc" />
