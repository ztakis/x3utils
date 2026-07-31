# x3utils macOS Guide

This is the macOS guide for x3utils.

Important expectation check: this is **not** a `.dmg` app and there is no drag-to-Applications installer. The macOS version is a terminal-based tool, like the Linux version, but with an installer script that prepares the bundled OpenOCD build.

If you only want the shortest path, follow the beginner steps below. If you already use Homebrew and Terminal, jump to the advanced quick start.

> [!CAUTION]
> **SHU compatibility firmware limits:** Do not use Flash SHU Compatible with F3/G3 VCU 1.6.3 or newer, GT3 VCU 1.7.2 or newer, or ZT3 VCU 1.5.9 or newer. SHU compat saves the original backup first, but using it on newer firmware may require restoring that backup.

## Beginner Path

1. Install Homebrew from:

```text
https://brew.sh
```

At the end of the Homebrew install, read the last lines carefully. Homebrew may print one or two commands that add `brew` to your shell path.

If you are not sure what that means, use the simple fix:

1. close Terminal;
2. log out of macOS;
3. log back in;
4. open Terminal again.

Then check:

```bash
brew --version
```

If that prints a Homebrew version, continue.

2. Download and unzip x3utils.
3. Open the `x3utils_mac` folder in Finder.
4. Right-click inside the folder and choose `New Terminal at Folder`.

If you do not see that option:

1. Open the `Terminal` app.
2. Type `cd ` with a space after it.
3. Drag the `x3utils_mac` folder into the Terminal window.
4. Press `ENTER`.

Then run:

```bash
chmod +x installer.sh
./installer.sh
./launcher.sh
```

The installer checks your Mac type, installs required Homebrew packages, sets executable permissions, and tests the bundled OpenOCD.

## Advanced Quick Start

From the repository root:

```bash
cd x3utils_mac
chmod +x installer.sh
./installer.sh
./launcher.sh
```

If Homebrew packages are already installed, `brew install` will usually skip or confirm them.

## What The Installer Does

`installer.sh`:

- detects Apple Silicon (`arm64`) or Intel (`x86_64`);
- selects the matching bundled xPack OpenOCD folder;
- checks that Homebrew exists;
- installs `hidapi`, `libusb`, and `python`;
- runs `chmod +x` on scripts and OpenOCD;
- tests that bundled OpenOCD can start.

Bundled OpenOCD folders:

```text
xpack-openocd-0.12.0-7-darwin-arm64
xpack-openocd-0.12.0-7-darwin-x64
```

## Homebrew

Homebrew is required by the current macOS installer.

Check if it is installed:

```bash
brew --version
```

If that fails, install Homebrew first:

```text
https://brew.sh
```

After installing Homebrew, close Terminal and open it again. If `brew` is still not recognized, log out of macOS and log back in.

Advanced users can also add Homebrew to the current shell manually.

Apple Silicon:

```bash
eval "$(/opt/homebrew/bin/brew shellenv)"
```

Intel Mac:

```bash
eval "$(/usr/local/bin/brew shellenv)"
```

If that works, follow the final PATH instructions printed by the Homebrew installer so the change is saved for future terminals.

The installer runs:

```bash
brew install hidapi libusb python
```

## Checking The ST-LINK On macOS

Use System Information:

1. Hold `Option`.
2. Click the Apple menu.
3. Choose `System Information`.
4. Open `USB`.
5. Plug and unplug the ST-LINK and check whether the USB list changes.

From Terminal, you can also run:

```bash
system_profiler SPUSBDataType
```

If the ST-LINK does not appear:

- try another USB cable;
- try another USB port or hub;
- avoid charge-only USB cables;
- check the adapter on another computer if possible.

## Running The Launcher

After installation:

```bash
./launcher.sh
```

Run macOS scripts from Terminal. If something fails, keep the terminal open and copy the exact error text.

## Launcher Menus (v1.8.1)

The main menu is:

1. Check Connection
2. Backup Full Memory (128 KB)
3. Flash SHU Compatible
4. Backup + Flash Loaded File
5. Load / Change Target `.bin` File
6. Advanced
7. Exit

Option 4 uses the file loaded with Option 5. The SHU-compatible and Advanced
flash actions keep their own prompts and do not reuse that loaded file.

The selected connection mode is saved in `config.sh`:

- A — Default / blinker buttons
- B — C45 / clone ST-LINK, with the guided hold/count/release flow
- C — C45 / genuine ST-LINK using nRST
- D — Power-race using fresh xPack OpenOCD processes to catch power-on

Mode B also exposes `T` to change the guided countdown timeout.

### Advanced Menu

1. Flash Only — No Backup
2. Flash Slot 0
3. Check Protection
4. Unlock / Rescue — Mass Erase
5. Back

Flash Only is deliberately dangerous because it skips the forced backup. It is
also the correct recovery path after rescue has left a confirmed blank chip;
the normal backup-required flash path rejects an all-`0xFF` dump.

Check Protection is read-only. Unlock / Rescue rewrites protection options and
can mass-erase main flash. It requires the explicit `UNLOCK` confirmation.
Both CLI actions honor launcher modes A/B/C/D. Flutter has its own separate
Mode-D protection block; that GUI restriction does not apply to this CLI.

### macOS Power-Race Timing

Mode D is a best-effort power-on catch. macOS uses upstream xPack OpenOCD,
which starts more slowly than the OEM OpenOCD builds used on Windows/Linux.
Each dot is printed after one complete missed attempt, so pauses and uneven dot
timing are normal.

Protection Check keeps retrying until one attempt contains the flash-bank, FAP,
and main-flash evidence needed for a verdict. After `UNLOCK` is confirmed,
Rescue similarly uses fresh attempts and reports success only after option-area
readback and rewrite-completion evidence.

## Direct Script Usage

Most users should use `launcher.sh`, but the lower-level scripts can be run directly.

### Check Connection Directly

```bash
./connection_test.sh
```

This uses the connection mode currently saved in `config.sh`. It connects,
halts, and probes the flash bank without dumping or writing firmware.

### Dump Directly

```bash
./dump.sh
```

This uses the connection mode currently saved in `config.sh`.

### Flash A File Directly

```bash
./flash.sh /path/to/firmware.bin
```

If no path is supplied, `flash.sh` asks for one.

`flash.sh` validates the file, asks for confirmation, runs a backup first, then flashes and verifies.

### SHU Compatible Directly

```bash
./flash_compat.sh
```

This uses `python3` for the patch step and the connection mode currently saved in `config.sh`.

### Advanced Scripts Directly

```bash
./special/flash_only.sh
./special/flash_slot0.sh
./special/rdp/rdp_check.sh -l
./special/rdp/rescue_unlock.sh -l
```

The flash scripts prompt for their own file. `-l` tells the RDP tools to honor
the launcher mode saved in `config.sh`; without `-l`, they use the standalone
guided rescue connection. Rescue is destructive and still requires `UNLOCK`.

Protection Check saves one complete, ANSI-free transcript per run under
`special/rdp/logs/`. Existing logs under `backup/` are left where they are;
Rescue retains its console-only behavior.

## Important Detail For Direct Scripts

The launcher saves the selected connection mode by editing:

```text
config.sh
```

If you run `connection_test.sh`, `dump.sh`, `flash.sh`, or `flash_compat.sh`
directly, they use the last connection mode selected in the launcher.

If you are not sure:

1. run `./launcher.sh`;
2. select `A`, `B`, `C`, or `D`;
3. exit or continue from the launcher;
4. then run the direct script.

## Files In This Folder

`installer.sh`

Prepares macOS dependencies and executable permissions.

`launcher.sh`

Main terminal menu.

`connection_test.sh`

Runs a read-only ST-LINK and target connection check using the saved mode.

`dump.sh`

Runs a full 128 KB dump using the saved connection mode.

`flash.sh`

Flashes a selected `.bin` file after validating it and forcing a backup first.

`flash_compat.sh`

Dumps, patches with `python3`, and flashes back for SHU-compatible workflows.

`validate_bin.sh`

Shared macOS `.bin` validator used by flashing scripts.

`race_grade.sh`

Power-race attempt classifier used by mode D.

`config.sh`

Selects the correct bundled OpenOCD build and stores the selected connection
mode, target configuration, and timeout.

`xpack-openocd-*`

Bundled OpenOCD builds for Apple Silicon and Intel Macs. Each bundle includes
the macOS-specific upstream Artery target configs, including mode D's
`target/artery/at32f4x_race.cfg`.

`special/`

Advanced Flash Only, Slot 0, and protection/rescue scripts. Read
`special/notes.txt` before using anything there.

## Common macOS Problems

`Homebrew is not installed`

Install Homebrew from `https://brew.sh`, then rerun:

```bash
./installer.sh
```

`brew: command not found`

Homebrew may be installed, but Terminal does not know where to find it yet.

Beginner fix:

1. close Terminal;
2. log out of macOS;
3. log back in;
4. open Terminal;
5. run `brew --version`.

Advanced quick fix for Apple Silicon:

```bash
eval "$(/opt/homebrew/bin/brew shellenv)"
```

Advanced quick fix for Intel Mac:

```bash
eval "$(/usr/local/bin/brew shellenv)"
```

Then rerun:

```bash
./installer.sh
```

`Unsupported architecture`

The bundled macOS OpenOCD builds currently support `arm64` and `x86_64`.

`OpenOCD binary is not executable`

Run:

```bash
chmod +x xpack-openocd-0.12.0-7-darwin-*/bin/openocd
```

or rerun:

```bash
./installer.sh
```

`Permission denied` when running a script

Run:

```bash
chmod +x *.sh
```

macOS blocks a downloaded script or binary

If macOS shows a security warning, open `System Settings`, check `Privacy & Security`, and allow the blocked item if you trust this x3utils download.

ST-LINK does not appear in USB devices

Check cable, port, hub, and adapter. macOS cannot use an adapter that does not appear as a USB device.

`python3: command not found`

Run:

```bash
brew install python
```

`config.sh is not writable`

Run:

```bash
chmod u+w config.sh
```

Mode-D dots pause or move unevenly

This is normal with xPack OpenOCD. Each dot represents a finished attempt, not
a timed animation. Apply power as prompted and let the fresh-process loop keep
trying.

`Bin file contains only a single repeated byte value` after rescue

A successful protection rescue can leave main flash blank (`0xFF`). The normal
Backup + Flash path rejects that dump by design. Use Advanced → Flash Only to
restore a known-good full 128 KB image, then return to normal backup-required
operations.

Terminal output is hard to read after failure

Run the script from Terminal instead of double-clicking it. Copy the exact error text when asking for help.

## More Help

- [Main README](../README.md)
- [Wiki home](https://github.com/ztakis/x3utils/wiki)
- [macOS quick start wiki page](https://github.com/ztakis/x3utils/wiki/04.-macOS-quick-start)
- [Troubleshooting](https://github.com/ztakis/x3utils/wiki/10.-Troubleshooting)
