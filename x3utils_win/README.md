# x3utils Windows Guide

This page is only for Windows-specific usage: how to start the scripts, how to check that Windows sees the ST-LINK, and how to use the `.bat` files directly.

For wiring, connection modes, C45, backups, and flashing safety, use the main README and wiki.

> [!CAUTION]
> **SHU compatibility firmware limits:** Do not use Flash SHU Compatible with F3/G3 VCU 1.6.3 or newer, or ZT3 VCU 1.5.9 or newer. GT3 is not supported by Flash SHU Compatible at any version (its own limit, VCU 1.7.2, is listed for reference only). SHU compat saves the original backup first, but using it on newer firmware may require restoring that backup.

## Start From Explorer

1. Download and unzip x3utils.
2. Open the `x3utils_win` folder.
3. Double-click `launcher.bat`.

`START with Launcher.txt` is only a reminder. The real launcher is:

```text
launcher.bat
```

If Windows asks whether you trust the file, choose to run it only if you downloaded x3utils from the expected GitHub repository.

## Start From Terminal

You can also run the launcher from Command Prompt, PowerShell, or Windows Terminal.

Open a terminal in the `x3utils_win` folder and run:

```powershell
.\launcher.bat
```

If you are not already in the folder:

```powershell
cd C:\path\to\x3utils_win
.\launcher.bat
```

Running from a terminal is useful because you can copy error text more easily.

## ST-LINK In Device Manager

Before blaming the scripts, check whether Windows can see the adapter.

1. Plug in the ST-LINK.
2. Right-click Start.
3. Open `Device Manager`.
4. Look for the ST-LINK under USB devices, Universal Serial Bus devices, or connected debug/programmer devices.

What you want:

- the adapter appears when plugged in;
- it disappears when unplugged;
- it does not have a yellow warning icon.

If it does not appear:

- try another USB cable;
- try another USB port;
- avoid charge-only USB cables;
- check whether the adapter needs an ST-LINK driver;
- reconnect the adapter after installing a driver.

If it appears with a warning icon:

- unplug and reconnect it;
- try reinstalling the ST-LINK driver;
- try another USB port;
- reboot Windows if the driver was just installed.

## Driver Notes

Clone ST-LINK adapters vary. Some work immediately, some need a driver, and some are just poor quality.

The launcher cannot fix a driver problem. If OpenOCD cannot see the adapter at all, solve the Windows/USB driver issue first.

Useful signs that the driver side is probably okay:

- Device Manager reacts when the ST-LINK is plugged in;
- OpenOCD starts instead of immediately failing to find an adapter;
- option `1` gets as far as trying to connect to the target.

## Launcher Menus (v1.8.1)

The main menu is:

1. Check Connection
2. Backup Full Memory (128 KB)
3. Backup + Flash Loaded File
4. Flash Slot 0
5. Load / Change Target `.bin` File
6. Advanced
7. Exit

Option 3 uses the file loaded with Option 5. Flash Slot 0 and the Advanced
flash actions keep their own prompts and do not reuse that loaded file.

Option 5 accepts only a full 128 KB (131072-byte) image, so its file cannot be
used for Flash Slot 0, which takes a slot-sized payload instead. Flash Slot 0
asks for its own file for that reason.

The selected connection mode is saved in `config.cmd`:

- A — Default / blinker buttons
- B — C45 / clone ST-LINK, with the guided hold/count/release flow
- C — C45 / genuine ST-LINK using nRST
- D — Power-race using fresh OpenOCD processes to catch power-on

Mode B also exposes `T` to change the guided countdown timeout.

### Advanced Menu

1. Flash SHU Compatible
2. Flash Only — No Backup
3. Check Protection
4. Unlock / Rescue — Mass Erase
5. Back

Flash Only is deliberately dangerous because it skips the forced backup. It is
also the correct recovery path after rescue has left a confirmed blank chip;
the normal backup-required flash path rejects an all-`0xFF` dump.

Check Protection is read-only. Unlock / Rescue rewrites protection options and
can mass-erase main flash. It requires the explicit `UNLOCK` confirmation.
Both actions honor launcher modes A/B/C/D.

## Folder And Path Tips

Keep the folder path simple.

Good:

```text
C:\x3utils\x3utils_win
C:\Users\YourName\Downloads\x3utils\x3utils_win
```

Avoid:

```text
C:\very long path\with {braces}\firmware.bin
C:\Users\Name With Non-English Characters\Desktop\firmware.bin
```

The Windows validator rejects some paths because OpenOCD command quoting is sensitive. If a file path fails validation, move the `.bin` file to a simple folder and try again.

## Direct Script Usage

Most users should use `launcher.bat`, but the lower-level scripts can be run directly.

### Check Connection Directly

From `x3utils_win`:

```powershell
.\connection_test.bat
```

This uses the connection mode currently saved in `config.cmd`. It connects,
halts, and probes the flash bank without dumping or writing firmware.

### Dump Directly

From `x3utils_win`:

```powershell
.\dump.bat
```

This uses the connection mode currently saved in `config.cmd`.

### Flash A File Directly

You can drag and drop a `.bin` file onto:

```text
flash.bat
```

or run it from terminal:

```powershell
.\flash.bat C:\path\to\firmware.bin
```

`flash.bat` validates the file, asks for confirmation, runs a backup first, then flashes and verifies.

### Flash Slot 0 Directly

From `x3utils_win`:

```powershell
.\flash_slot0.bat
.\flash_slot0.bat C:\path\to\firmware.bin
```

Backs up first, then writes slot 0 only. Without an argument it prompts for the
file. This uses the connection mode currently saved in `config.cmd`.

### Advanced Scripts Directly

```powershell
.\special\flash_compat.bat
.\special\flash_only.bat
powershell -NoProfile -ExecutionPolicy Bypass -File .\special\rdp\rdp.ps1 -Check -Launcher
powershell -NoProfile -ExecutionPolicy Bypass -File .\special\rdp\rdp.ps1 -Rescue -Launcher
```

The flash scripts prompt for their own file. `-Launcher` tells the RDP toolkit
to honor the launcher mode saved in `config.cmd`; without it, the toolkit uses
its standalone guided rescue connection. Rescue is destructive and still
requires `UNLOCK`.

The RDP toolkit saves one complete, ANSI-free transcript per run under
`special\rdp\logs\`. Existing logs under `backup\` are left where they are.

## Important Detail For Direct Scripts

The launcher saves the selected connection mode by editing:

```text
config.cmd
```

If you run `connection_test.bat`, `dump.bat`, `flash.bat`, `flash_slot0.bat`, or
`special\flash_compat.bat` directly, they use the last connection mode selected
in the launcher.

So if you are not sure:

1. run `launcher.bat`;
2. select `A`, `B`, `C`, or `D`;
3. exit or continue from the launcher;
4. then run the direct script.

## Files In This Folder

`launcher.bat`

Main menu. Recommended for most users.

`connection_test.bat`

Runs a read-only ST-LINK and target connection check using the saved mode.

`dump.bat`

Runs a full 128 KB dump using the saved connection mode.

`flash.bat`

Flashes a selected `.bin` file after validating it and forcing a backup first.

`flash_slot0.bat`

Backs up first, then writes slot 0 only. Boot, slot 1, and user data stay
untouched.

`validate_bin.cmd`

Shared Windows `.bin` validator used by flashing scripts.

`race_grade.cmd`

Power-race attempt classifier used by mode D.

`config.cmd`

Stores OpenOCD paths, selected target configuration, colors, and mode timeout.

`oocd\`

Bundled OpenOCD for Windows.

`special\`

Advanced SHU Compatible, Flash Only, and protection/rescue scripts. Read
`special\notes.txt` before using anything there.

## Common Windows Problems

`OpenOCD binary not found`

The folder is incomplete. Re-download or re-extract x3utils and make sure this file exists:

```text
x3utils_win\oocd\bin\openocd.exe
```

`config.cmd did not update correctly`

The folder may not be writable. Move x3utils somewhere normal, such as Downloads or `C:\x3utils`, and try again.

`Path contains non-ASCII characters`

Move the `.bin` file to a simple path using English letters and numbers.

`Path contains unsupported character`

Rename the file or folder. Avoid `{` and `}` in paths.

`Bin file contains only a single repeated byte value` after rescue

A successful protection rescue can leave main flash blank (`0xFF`). The normal
Backup + Flash path rejects that dump by design. Use Advanced → Flash Only to
restore a known-good full 128 KB image, then return to normal backup-required
operations.

Terminal closes too fast

Run the script from PowerShell or Windows Terminal instead of double-clicking it. That lets you read and copy the error.

## More Help

- [Main README](../README.md)
- [Wiki home](https://github.com/ztakis/x3utils/wiki)
- [Windows quick start wiki page](https://github.com/ztakis/x3utils/wiki/02.-Windows-quick-start)
- [Troubleshooting](https://github.com/ztakis/x3utils/wiki/10.-Troubleshooting)
