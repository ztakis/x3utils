# x3utils

ST-LINK utilities for X3 / 3rd-generation scooter VCUs.

Supported models: ZT3 Pro, Max G3, F3 / F3 Pro.

> [!WARNING]
> This tool talks directly to the scooter VCU. A bad connection, wrong file, or interrupted flash can leave the controller unusable until recovered. Always make a full dump first and keep the backup somewhere safe.

## Sent Here From Discord?

Most users only need the Windows + clone ST-LINK guide.

**Watch the video first.**

> Video placeholder: Windows + clone ST-LINK + C45 mode, showing wiring, C45-to-GND timing, and a successful option `2` full dump.

Quick version:

1. Download the latest x3utils release.
2. Open `x3utils_win`.
3. Run `launcher.bat`.
4. Select `B - C45 / Clone ST-Link`.
5. Run option `2` first to make a full 128 KB backup.
6. Do not flash anything until the dump works.

If option `2` works, your ST-LINK connection is probably good enough for the next steps.

## What This Tool Does

- makes a full 128 KB VCU backup;
- flashes a selected 128 KB `.bin` file;
- patches current firmware for SHU-compatible workflows;
- supports normal SWD, blinker-button service mode, clone ST-LINK C45 mode, and genuine ST-LINK reset mode.

## Which Guide Should I Use?

Most people:

- [Windows guide](../x3utils_win/README.md)
- [Clone ST-LINK C45 guide](wiki/07.-Clone-ST-Link-C45-guide.md)
- [ST-LINK pinouts](wiki/01.-ST-LINK-pinouts.md)

Other platforms:

- [Linux guide](../x3utils_linux/README.md)
- [macOS guide](../x3utils_mac/README.md)

More help:

- [Connection modes](wiki/05.-Connection-modes.md)
- [Special mode / blinker buttons](wiki/06.-Special-mode-blinker-buttons.md)
- [Troubleshooting](wiki/10.-Troubleshooting.md)

## Launcher Menu

`[1] Flash SHU compatible`

Dumps your current VCU firmware, patches it, and flashes it back for SHU-compatible workflows such as flashing from repo or changing serial. Use at your own risk.

`[2] Run Full Memory Dump (128 KB)`

Makes a full backup. Run this first.

`[3] Flash Loaded File to Chip`

Flashes the `.bin` file selected with option `4`.

`[4] Load / Change Target .bin File`

Selects the `.bin` file to flash. Normal firmware files must be exactly 128 KB.

`[5] Exit`

Closes the utility.

## Connection Modes

`A - Default / Blinker buttons`

Use this when SWD is available, either normally or by holding the turn indicator buttons during power-up.

`B - C45 / Clone ST-Link`

Most common mode. Use this with clone ST-LINK adapters. The launcher tells you when to touch C45 to `GND`.

`C - C45 / Genuine ST-Link`

Use this with a genuine ST-LINK adapter and its reset pin connected to the MCU reset line at C45.

## For Tinkerers And Developers

This repo vendors OpenOCD and uses platform-specific launch scripts for Windows, Linux, and macOS. The hardware-facing OpenOCD logic lives in the target `.cfg` files, especially the C45 connect-under-reset configs.

Useful docs:

- [Wiki drafts](wiki/Home.md)
- [Testing notes](testing.md)
- [Python refactor notes](python-refactor.md)
- [Agent/developer guidance](../AGENTS.md)
