# x3utils_flutter

The cross-platform **Flutter GUI** for x3utils — a dark, game-like desktop app
for flashing the **AT32F415** VCU on X3-family e-scooters over an ST-LINK.

It's a front-end over the same bundled **OpenOCD** + `rdp` toolkit the
field-proven `x3utils_win` / `x3utils_linux` / `x3utils_mac` scripts use — the
flashing brains stay in OpenOCD + the `.cfg` procs; this app is the shell.

> Windows-first, but written to be cross-platform (macOS / Linux). The command
> logic is OS-agnostic Dart; each OS just needs its native binaries bundled.

## What it does

Connection modes: **A** Default SWD · **B** C45 clone (guided hold/release) ·
**C** C45 genuine (nRST).

Actions:

- **Check connection** — read-only probe
- **Backup** — full 128 KB dump, validated
- **SHU compatible** — dump → patch the chip's own firmware → flash back
- **Backup + Flash** / **Flash Only** / **Flash slot 0** — flash a `.bin` (slot 0 is identity-safe)
- **Check protection** / **Unlock / rescue** — read-protection (FAP) verdict + WRP-safe rescue

Plus: firmware validation (size / all-zeros / write-protected diagnostics),
mandatory backup-first, re-seat retry, a resizable/pinnable OpenOCD console with
copy + opt-in per-run log files, and persisted settings (connection, backup
folder / filename prefix / second-copy, and accent theme).

## Requirements

- **Flutter SDK** (stable) + Dart
- **Windows:** Visual Studio 2022 with the *Desktop development with C++* workload
- **macOS:** Xcode + CocoaPods
- **Linux:** clang + GTK dev libs (`flutter doctor` lists specifics)

Run `flutter doctor` and resolve anything for your target OS.

## Build & run

```bash
flutter pub get
flutter run -d windows      # or: macos | linux
flutter build windows --release
```

The release output is in `build/<os>/…`. For distribution, place a copy of the
per-OS `native/<os>/` folder next to the executable (see below).

## Layout

```
lib/
  main.dart            UI: title bar · rail · hero stage · console · settings
  models.dart          connection modes, actions, chips, stage states
  app_controller.dart  the workflow state machine + settings (ChangeNotifier)
  theme.dart           palette, accent themes, version constant
  engine/
    openocd_paths.dart  locates native/<os>/oocd
    openocd_runner.dart builds + streams the openocd commands
    cfg.dart            per-OS cfg paths (Win/Linux at32f415xx*, macOS artery/at32f4x*)
    rdp_runner.dart     shells rdp.ps1 (Windows) / rdp_*.sh (mac/Linux)
    firmware.dart       .bin validation, backup/compat/log paths
native/
  windows/             oocd/ (openocd.exe + scripts) + special/rdp/ (rdp.ps1)
  macos/  linux/       (added during the respective port)
design/flash-studio.html   the original visual mockup / spec
```

`OpenOcdPaths.find()` walks up from the executable to resolve
`native/<os>/oocd`, so it works both in a dev build (deep under `build/`) and a
packaged build (next to the exe).

## Adding macOS / Linux

The Dart is OS-agnostic; a port is mostly binaries + scaffolding:

1. `flutter create --platforms=macos .` (or `linux`) to generate the runner.
2. Drop the OS's OpenOCD into `native/<os>/oocd/` (macOS uses the xpack build,
   arm64 + x64; its Artery cfg lives at `target/artery/at32f4x*` — already
   handled by `cfg.dart`).
3. Drop the OS's `special/rdp/*.sh` + `rescue.cfg` into `native/<os>/special/rdp/`.
4. `flutter build <os>` and test against hardware.

## Versioning

Version lives in three places — **keep them in sync**: `VERSION`,
`pubspec.yaml` (`version:`), and `kAppVersion` in `lib/theme.dart` (drives the
UI). Current: **0.9.0**.

## Safety

Flashing writes to a real vehicle controller. Write actions back up first and
verify; a read-protected chip is detected and rescue uses the deterministic,
WRP-safe option-byte rewrite (never the driver `unlock`). Still — use the right
`.bin` for your model, and keep the SWD/C45 contact steady.
