*README in progress ...*  

# x3utils

### Web App

- **[x3utils-web v2.0.0 BETA](https://x3utils-web.pages.dev/)** — runs in the browser, nothing to install. Experimental. Needs a WebUSB-capable browser (Chrome or Edge on desktop or Android); Firefox and Safari will not work.

### Downloads

- **[GUI v1.3.0](https://github.com/ztakis/x3utils/releases/tag/gui-v1.3.0)** — desktop app for Windows, Linux and macOS. Recommended for most users.
- **[CLI v1.8.1](https://github.com/ztakis/x3utils/releases/tag/v1.8.1)** — the scripts, for terminal users.

<h2></h2>

### ST-LINK utilities for X3 / 3rd-generation scooters.

<img width="718" height="840" alt="image" src="https://github.com/user-attachments/assets/0a8a94e9-04bd-4903-9615-b1933d6d3e52" />
<br><br>

<img width="518" height="653" alt="image" src="https://github.com/user-attachments/assets/79a4be07-d7a0-4c44-9aa1-7484f07f5430" />

### Supported models: ZT3 Pro, Max G3, F3 / F3 Pro.

> [!WARNING]
> This tool talks directly to the scooter VCU. A bad connection, wrong file, or interrupted flash can leave the controller unusable until recovered. Always make a full dump first and keep the backup somewhere safe.

> [!CAUTION]
> **SHU compatibility firmware limits:** Do not use Flash SHU Compatible with F3/G3 VCU 1.6.3 or newer, or ZT3 VCU 1.5.9 or newer. GT3 is not supported by Flash SHU Compatible at any version (its own limit, VCU 1.7.2, is listed for reference only). SHU compat saves the original backup first, but using it on newer firmware may require restoring that backup.

## Quick Start

**Watch the quick video first.**

[![Quick video guide](docs/media/video_thumbnail.JPG)](https://youtu.be/kAfJ35vDyJ8)

This short video shows the normal Windows + clone ST-LINK flow: launcher on one side, test board and C45 timing on the other.

<!-- Need the full explanation? Watch the long version: -->

<!-- *Long YouTube walkthrough: coming soon.* -->

<!-- [Youtube video coming soon..](https://www.youtube.com/watch?v=VIDEO_ID) -->

Quick steps:

1. Download the latest x3utils release.
2. Open `x3utils_win`.
3. Run `launcher.bat`.
4. Select `B - C45 / Clone ST-Link`.
5. Run option `2` first to make a full 128 KB backup.
6. Do not flash anything until the dump works.

If option `2` works, your ST-LINK connection is probably good enough for the next steps.

## What This Tool Does

### The launcher has five main actions:

`[1] Flash SHU compatible`

Dumps your current VCU firmware, patches it, and flashes it back for SHU-compatible workflows such as flashing from repo or changing serial. Use at your own risk.
[More info >](https://github.com/ztakis/x3utils/wiki/33.-SHU-compatible-workflow)

`[2] Run Full Memory Dump (128 KB)`

Makes a full backup. Run this first.
[More info >](https://github.com/ztakis/x3utils/wiki/30.-Backups-and-flashing-safely)

`[3] Flash Loaded File to Chip`

Flashes the `.bin` file selected with option `4`.
<!-- [More info >](https://github.com/ztakis/x3utils/wiki) -->

`[4] Load / Change Target .bin File`

Selects the `.bin` file to flash. Normal firmware files must be exactly 128 KB.
<!-- [More info >](https://github.com/ztakis/x3utils/wiki) -->

`[5] Exit`

Closes the utility.

### Connection Modes

`A - Default / Blinker buttons`

Use this when SWD is available, either normally or by holding the turn indicator buttons during power-up.
[More info >](https://github.com/ztakis/x3utils/wiki/11.-Default-SWD-and-blinker-buttons)

`B - C45 / Clone ST-Link`

Most common mode. Use this with clone ST-LINK adapters. The launcher tells you when to touch C45 to `GND`.
[More info >](https://github.com/ztakis/x3utils/wiki/12.-Clone-ST-LINK-C45-mode)

`C - C45 / Genuine ST-Link`

Use this with a genuine ST-LINK adapter and its reset pin connected to the MCU reset line at C45.
[More info >](https://github.com/ztakis/x3utils/wiki/13.-Genuine-ST-LINK-reset-mode)

## More Documentation

- [Windows guide](x3utils_win/README.md)
- [Linux guide](x3utils_linux/README.md)
- [macOS guide](x3utils_mac/README.md)
- [Wiki home](https://github.com/ztakis/x3utils/wiki)
