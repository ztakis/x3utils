*README in progress ...*  

**[Check the wiki (in progress too)](https://github.com/ztakis/x3utils/wiki)** 
<br /><br />

<img width="567" height="535" alt="terminal4" src="https://github.com/user-attachments/assets/1248fe25-7a34-4b01-b2d7-100b0c89a941" />

# Main Menu

**[1] Flash SHU compatible (ZT3, G3, F3/F3Pro)**  
This option dumps your current vcu firmware, patches it and then flashes it back,  
so that you can use SHU to flash from repo, change serial etc.

**[2] Run Full Memory Dump (128 KB)**  
Reads and saves the entire 128 KB flash memory to a backup file.  
Recommended before making any changes.

**[3] Flash Loaded File to Chip**  
Flash the file selected in option 5 to the device.

**[4] Load / Change Target .bin File**  
Select the .bin file you want to flash. Do this before using option 4.

**[5] Exit**  
Close the utility.

**Options [1] and [3] force a full backup first**
<br /><br />

**[A] Default mode (SWD available) / Hold blinker buttons**  
This mode assumes that the chip's st-link interface (SWD) is available.  
In many cases, holding the blinker buttons before powering the chip
is enought for this mode to work.

**[B] C45 / Clone ST-Link (connect-under-reset)**  
This is a connect-under-reset mode using a clone ST-Link.

**[C] C45 / Genuine ST-Link (connect-under-reset)**  
This is a connect-under-reset mode using a genuine ST-Link.

*The mode settings above are persistent — stay active across sessions until switched.

**[T] Set countdow timer**  
Set countdown timer (0-60sec) for "option B".

<br />

## ST-LINK pinouts

<img width="667" height="443" alt="g3" src="https://github.com/user-attachments/assets/e40bea51-4374-4d9d-bd09-cbbc52b15e85" />

ST-LINK pinout for G3/F3  
<br />

<img width="486" height="628" alt="image" src="https://github.com/user-attachments/assets/6daf3c14-ad6c-463f-8675-a1c00fc49457" />

ST-LINK pinout for new G3  
<br />

<img width="2244" height="1024" alt="ZT3" src="https://github.com/user-attachments/assets/871d3c47-254d-4872-bf83-a824e4387cff" />

ST-LINK pinout for ZT3  
<br />

<img width="800" height="286" alt="x3_mcu" src="https://github.com/user-attachments/assets/6d536191-0fbe-464a-8e86-58a8f21566fc" />

ST-LINK pinout for X3 MCU
<br /><br />

# Default connection procedure

**In this mode we assume that SWD is enabled & available.**  
<br />
If SWD is not available, you might need to enter special mode:  
* Remove all power from the dash, like disconnect main cable (julet).
* Connect st-link pins correctly and in a secure way but not the 3.3V pin.
* Plug st-link to USB.
* Hold both blinker buttons & keep holding.
* Plug in main power cable.
* You can now release the blinker buttons.
* As a connection test, run option [2] in Launcher script, or the dump.bat(sh) script directly.  

***It is possible that latest firmwares have disabled this scpecial mode.***  
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

# Connect-under-reset mode using a clone ST-Link

This a guided connect-under-reset procedure, where the user grounds and releases C45  
following on screen prompts.  
<br />
<img width="594" height="796" alt="image" src="https://github.com/user-attachments/assets/afbff8ce-2ff7-4534-bbaa-4ea43c558885" />
<br /><br />
<img width="365" height="400" alt="7" src="https://github.com/user-attachments/assets/53c5ccf4-cc61-4ab3-935c-187bc2bd4bfe" />
<img width="1428" height="964" alt="image" src="https://github.com/user-attachments/assets/d591110c-1ac4-4e9c-849d-8442738f4258" />
<img width="999" height="505" alt="image" src="https://github.com/user-attachments/assets/747f79e4-8409-400c-bc68-3d5b1e5e70aa" />

<br /><br />


# Connect-under-reset mode using a genuine ST-Link

Check the link for more info

[Using a genuine ST-Link](https://github.com/ztakis/x3utils/wiki/Connect%E2%80%90under%E2%80%90reset-mode-using-a-genuine-ST%E2%80%90Link)

