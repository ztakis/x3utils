*README in progress ...*  

# x3utils

![Launcher menu](docs/media/launcher-menu.png)

### ST-LINK utilities for X3 (3rd-gen) scooter VCUs & MCUs.

This project helps you dump, back up, patch, and flash the 128 KB VCU firmware used on supported third-generation models. It is built around simple menu launchers for Windows, Linux, and macOS, with OpenOCD bundled inside the repository.

### Supported models: ZT3 Pro, Max G3, F3/F3 Pro

> [!WARNING]
> This tool talks directly to the scooter VCU through ST-LINK. A bad file, weak wiring, wrong mode, or interrupted flash can leave the controller unusable until recovered. Always make a full dump first and keep a copy somewhere safe. Use at your own risk.

## Quick Start

1. Download or clone this repository.
2. Open the folder for your platform:
   - `x3utils_win`
   - `x3utils_linux`
   - `x3utils_mac`
3. Connect your ST-LINK to the VCU.
4. Start the launcher.
5. Select the correct connection mode: `A`, `B`, or `C`.
6. Run option `2` to make a full 128 KB dump before flashing anything.

For wiring, connection modes, and platform setup, use the [wiki](https://github.com/ztakis/x3utils/wiki).

## Most Common Example

**Windows + clone ST-LINK + C45 mode**

This is the usual setup for most users because clone ST-LINK adapters are cheap and easy to find.

> **Video placeholder:** add short video here showing clone ST-LINK wiring, C45-to-GND timing, and a successful option `2` full dump.

1. Open `x3utils_win` and start `launcher.bat`.
2. Select mode [`B - C45 / Clone ST-Link`](https://github.com/ztakis/x3utils/wiki/07.-Clone-ST-Link-C45-guide).
3. Connect `SWDIO`, `SWCLK`, and `GND`.
4. Be ready to touch C45 to `GND` when the launcher asks.
5. Run option `2` first and make sure the full dump succeeds.

If option `2` works, your wiring and connection mode are probably good enough for the next steps.

## Launcher Menu

### Actions

`[1] Flash SHU compatible (ZT3, G3, F3/F3Pro)`

Dumps the current VCU firmware, patches it, and flashes it back so the firmware can be used with SHU-compatible workflows such as flashing from repo or changing serial. This is use-at-your-own-risk.

`[2] Run Full Memory Dump (128 KB)`

Reads the full 128 KB flash memory and saves a backup. Run this first.

`[3] Flash Loaded File to Chip`

Flashes the `.bin` file selected with option `4`.

`[4] Load / Change Target .bin File`

Selects the `.bin` file to flash. Files must be exactly 128 KB.

`[5] Exit`

Closes the utility.

Options `1` and `3` force a backup before flashing.

### Connection Modes

[`[A] Default / Blinker buttons`](https://github.com/ztakis/x3utils/wiki/05.-Connection-modes)

Use this when the SWD interface is available. This may work because the firmware leaves SWD enabled, or because the VCU is powered while holding the turn indicator buttons to enter a service mode where SWD is available.

[`[B] C45 / Clone ST-Link`](https://github.com/ztakis/x3utils/wiki/07.-Clone-ST-Link-C45-guide)

Connect-under-reset mode for common clone ST-LINK adapters. Many clones do not have a working reset pin, so the launcher guides you to connect C45 to GND at the right moments.

[`[C] C45 / Genuine ST-Link`](https://github.com/ztakis/x3utils/wiki/08.-Genuine-ST-Link-guide)

Connect-under-reset mode for genuine ST-LINK adapters. The genuine reset pin is connected to the MCU nRST line, which is available at capacitor C45 on these VCUs.

[`[T] Set countdown timer`](https://github.com/ztakis/x3utils/wiki/07.-Clone-ST-Link-C45-guide)

Only shown in mode `B`. Changes the countdown used during the manual C45-to-GND guided connection.

Connection mode settings are persistent. The selected mode stays active until you change it.

## Platform Notes

### Windows

Unzip the project, open `x3utils_win`, and double-click `launcher.bat`.

The file `START with Launcher.txt` is only a reminder. The real launcher is `launcher.bat`.

### Linux

Open a terminal in `x3utils_linux` and run:

```bash
chmod +x *.sh oocd/bin/openocd
./launcher.sh
```

Linux may also need udev rules and USB/HID dependencies. See the wiki for details.

### macOS

Open a terminal in `x3utils_mac` and run:

```bash
chmod +x installer.sh
./installer.sh
./launcher.sh
```

The macOS build includes bundled xPack OpenOCD folders for Apple Silicon and Intel Macs. The installer chooses the correct one.

## More Documentation

- [Wiki home](https://github.com/ztakis/x3utils/wiki)
- [ST-LINK pinouts](https://github.com/ztakis/x3utils/wiki/01.-ST-LINK-pinouts)
- [Connection modes](https://github.com/ztakis/x3utils/wiki/05.-Connection-modes)
- [Special mode / blinker buttons](https://github.com/ztakis/x3utils/wiki/16.-Special-mode-(blinker-buttons))
