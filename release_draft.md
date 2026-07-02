## x3utils v1.6.5


### Summary

- Safer C45 flashing, better validation/backups, cleaner packages, macOS is back and a little launcher personality.

### Highlights

- Improved C45 / clone ST-Link flashing reliability with safer OpenOCD TCL error handling.
- Added shared `.bin` validation across flashing, dumping, launcher, and SHU compatibility workflows.
- Added secondary backup storage outside the x3utils folder for extra safety.
- Added extra tools under the `special/` folder.
- Cleaned up and reorganized bundled OpenOCD files for the release packages.
- Re-added macOS support,  for Apple Silicon and Intel Macs.

### C45 / Clone ST-Link Improvements

The C45 target scripts now handle errors more safely during guided connect-under-reset and flashing.

Failures during adapter initialization, DEMCR write, target re-examine, halt, erase, write, or verify now stop the process with an error instead of continuing silently. Flash and verify operations are wrapped inside TCL helper procedures so the launcher/scripts can correctly detect failed OpenOCD operations.

This is especially important for C45 / clone ST-Link flashing, where a bad connection or interrupted flash should fail clearly.

### macOS Support

macOS support has been brought back after falling behind the Windows and Linux packages.

The macOS package includes bundled OpenOCD builds for:

- Apple Silicon / `arm64`
- Intel / `x86_64`

The tool automatically selects the correct OpenOCD build for the current Mac architecture.

macOS C45 flashing can be slower than Windows/Linux, so the tool now warns users to wait up to 1 minute for the flash operation to finish and not interrupt the process.

### Validation and Backup Improvements

Added shared validation scripts:

- Windows: `validate_bin.cmd`
- Linux/macOS: `validate_bin.sh`

Validation checks include:

- file exists
- `.bin` extension
- expected 128 KB size
- unsupported path characters
- repeated-byte / invalid dump detection
- non-ASCII path detection on Windows

The validator also supports a `nosize` option, allowing future workflows to use valid `.bin` files with custom sizes.

Dump and compatibility flows now verify generated files before continuing.

Secondary backups are now also stored in:

- Windows: `%LOCALAPPDATA%\x3utils_backup`
- Linux: `~/.x3utils_backup`
- macOS: `~/Library/Application Support/x3utils_backup`

### Launcher and Script Updates

- Added a new retro ASCII art scooter mascot/banner to the launchers.
- Updated launcher menus and connection option handling.
- Updated C45 target names to the newer `at32f415xx_*` naming.
- Improved error messages when flash or backup scripts fail.
- Centralized OpenOCD binary and scripts directory validation in config files.
- Added OpenOCD executable permission checks on Linux/macOS.

### Special Tools

Extra tools are now available in the `special/` folder:

- `flash_only` - flash without the forced backup step
- `flash_slot0` - experimental slot-0 flashing
- `flash_gt3_compat` - experimental GT3 SHU compatibility tool

These are intended for advanced users and special cases.

### Notes

As always, make a backup before flashing and do not interrupt the process once flashing has started.