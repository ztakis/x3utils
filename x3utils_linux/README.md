# x3utils Linux Guide

This page is for Linux-specific setup and terminal usage.

It assumes you are comfortable with a shell. Hardware wiring, connection modes, C45, and flashing safety are covered in the main README and wiki.

## Quick Start

From the repository root:

```bash
cd x3utils_linux
chmod +x *.sh oocd/bin/openocd
./launcher.sh
```

If `config.sh` is not writable, the launcher will try to fix it with `chmod u+w config.sh`.

## Dependencies

The bundled OpenOCD binary is included, but the system still needs USB/HID support and Python for the SHU-compatible patch path.

Common packages:

- `python3`
- `usbutils`
- `hidapi` / `libhidapi-hidraw0`
- udev rules for ST-LINK access without root

### Debian / Ubuntu / Mint

```bash
sudo apt update
sudo apt install python3 usbutils libhidapi-hidraw0
```

### Fedora

```bash
sudo dnf install python3 usbutils hidapi
```

### Arch / Manjaro

```bash
sudo pacman -S python usbutils hidapi
```

Package names can vary slightly by distro version. If `hidapi` is not found, search your distro packages for `hidapi` or `libhidapi`.

## udev Rules

If OpenOCD cannot access the ST-LINK as your normal user, install the bundled OpenOCD udev rules.

From `x3utils_linux`:

```bash
sudo cp oocd/contrib/60-openocd.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger
```

Then unplug and reconnect the ST-LINK.

If your distro uses a `plugdev` group for USB programmer access, make sure your user is in the required group, then log out and back in.

## Check That Linux Sees The ST-LINK

Before debugging x3utils, check the adapter at the OS level.

```bash
lsusb
```

Plug and unplug the ST-LINK and confirm the list changes.

For live kernel messages:

```bash
dmesg -w
```

Then plug in the ST-LINK and watch for USB attach messages.

If the adapter does not appear:

- try another USB cable;
- try another USB port;
- avoid charge-only USB cables;
- check the adapter on another machine if possible.

## Running From Terminal

Always run Linux scripts from a terminal:

```bash
./launcher.sh
```

If a script fails, keep the terminal open and copy the exact error text.

If `openocd` is not executable:

```bash
chmod +x oocd/bin/openocd
```

If scripts are not executable:

```bash
chmod +x *.sh
```

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

`launcher.sh`

Main terminal menu. Recommended for most users.

`connection_test.sh`

Runs a read-only ST-LINK and target connection check using the saved mode.

`dump.sh`

Runs a full 128 KB dump using the saved connection mode.

`flash.sh`

Flashes a selected `.bin` file after validating it and forcing a backup first.

`flash_compat.sh`

Dumps, patches with `python3`, and flashes back for SHU-compatible workflows.

`validate_bin.sh`

Shared Linux `.bin` validator used by flashing scripts.

`race_grade.sh`

Power-race attempt classifier used by mode D.

`config.sh`

Stores OpenOCD paths, selected target configuration, colors, and mode timeout.

`oocd/`

Bundled OpenOCD for Linux.

`special/`

Experimental / advanced scripts. Read `special/notes.txt` before using anything there.

## Common Linux Problems

`OpenOCD binary is not executable`

Run:

```bash
chmod +x oocd/bin/openocd
```

`Permission denied` when running a script

Run:

```bash
chmod +x *.sh
```

OpenOCD cannot access the ST-LINK

Install/reload udev rules, reconnect the adapter, and verify it appears in `lsusb`.

`python3: command not found`

Install Python with your distro package manager.

`config.sh is not writable`

Run:

```bash
chmod u+w config.sh
```

`Path contains unsupported character`

Rename the file or folder. Avoid `{` and `}` in paths.

Terminal output is hard to read after failure

Run the direct script from a normal terminal and copy the full output. Avoid launching scripts from a file manager if it closes the terminal window.

## More Help

- [Main README](../README.md)
- [Wiki home](https://github.com/ztakis/x3utils/wiki)
- [Linux quick start wiki page](https://github.com/ztakis/x3utils/wiki/03.-Linux-quick-start)
- [Troubleshooting](https://github.com/ztakis/x3utils/wiki/10.-Troubleshooting)
