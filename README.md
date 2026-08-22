
*README in progress ...*

<table><tr><td>

### Latest Downloads

- **[GUI v2.0.0-BETA](https://github.com/ztakis/x3utils/releases/tag/gui-v2.0.0-beta)** — pre-release desktop & phone apps
<br><br>
- **[GUI v1.3.0](https://github.com/ztakis/x3utils/releases/tag/gui-v1.3.0)** — desktop app for Windows, Linux and macOS. Recommended for most users.
- **[CLI v1.8.1](https://github.com/ztakis/x3utils/releases/tag/v1.8.1)** — the scripts, for terminal users.

### Web App

Needs Chrome or Edge — Firefox and Safari have no WebUSB, and ***no iPhone or iPad browser will work***.

- **[x3utils-web v2.0.0 BETA](https://x3utils-web.pages.dev/)** — desktop browsers. Experimental.
- **[x3utils-mobile v2.0.0 BETA](https://x3utils-web.pages.dev/m/)** — Android phones, Chrome. A subset of the desktop tools, same layout as the Android app.

> [!CAUTION]
> **SHU compatibility firmware limits:** Do not use Flash SHU Compatible with F3/G3 VCU 1.6.3 or newer, or ZT3 VCU 1.5.9 or newer. GT3 is not supported by Flash SHU Compatible at any version (its own limit, VCU 1.7.2, is listed for reference only). SHU compat saves the original backup first, but using it on newer firmware may require restoring that backup.

</td></tr></table>

<!-- <h2></h2> -->

# x3utils

### ST-LINK utilities for X3 / 3rd-generation scooters.

*Supported models: ZT3 Pro, Max G3, F3 / F3 Pro*

<table><tr>
<td><img width="718" height="804" alt="x3utils desktop" src="docs/media/x3utils-desktop.png" /></td>
<td><img width="388" height="804" alt="x3utils android" src="docs/media/android-c45.jpg" /></td>
</tr></table>

## What This Tool Does

x3utils talks to the scooter VCU over ST-LINK / SWD. It makes full firmware backups, flashes firmware, runs SHU-compatible patch flashing, and checks or rescues a locked chip. The GUI covers Windows, Linux, and macOS; the CLI scripts do the same job from a terminal.

> [!WARNING]
> This tool talks directly to the scooter VCU. A bad connection, wrong file, or interrupted flash can leave the controller unusable until recovered. Always make a full dump first and keep the backup somewhere safe.

## Quick Start

**Watch the quick video first.**

[![Quick video guide](docs/media/video_thumbnail.JPG)](https://youtu.be/kAfJ35vDyJ8)

This video shows the older CLI flow, not the current GUI. A GUI walkthrough is planned.

1. Download the latest release for your platform.
2. Make a full backup before you flash anything.
3. Follow the guide for your platform: [Windows](x3utils_win/README.md), [Linux](x3utils_linux/README.md), [macOS](x3utils_mac/README.md).

## CLI Scripts

<img width="518" height="653" alt="x3utils CLI" src="docs/media/x3utils-cli.png" />

The original CLI scripts still work and cover the same operations as the GUI, for anyone who prefers the terminal.

## More Documentation

- [Windows guide](x3utils_win/README.md)
- [Linux guide](x3utils_linux/README.md)
- [macOS guide](x3utils_mac/README.md)
- [Wiki home](https://github.com/ztakis/x3utils/wiki)