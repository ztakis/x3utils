*README in progress ...*  

**[Check the wiki (in progress too)](https://github.com/ztakis/x3utils/wiki)** 
<br /><br />

<img width="523" height="627" alt="image" src="https://github.com/user-attachments/assets/48831706-540a-465d-aedc-6bb2c93d3cc0" />

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

Check the link for more info: [ST-LINK pinouts](https://github.com/ztakis/x3utils/wiki/1.-ST%E2%80%90LINK-pinouts)  
<br /><br />

# Default connection procedure

In this mode we assume that SWD is enabled & available.  

If SWD is not available, you might need to enter [Special mode](https://github.com/ztakis/x3utils/wiki/6.-Special-mode-(blinker-buttons))  
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

Check the link for more info: [Using a genuine ST-Link](https://github.com/ztakis/x3utils/wiki/Connect%E2%80%90under%E2%80%90reset-mode-using-a-genuine-ST%E2%80%90Link)
<br /><br />

#
