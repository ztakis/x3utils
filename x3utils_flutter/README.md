# x3utils_flutter

The cross-platform **Flutter GUI** for x3utils — a dark, game-like desktop app
for flashing the **AT32F415** VCU on X3-family e-scooters over an ST-LINK.

It's a front-end over the same bundled **OpenOCD** + `rdp` toolkit the
field-proven `x3utils_win` / `x3utils_linux` / `x3utils_mac` scripts use — the
flashing brains stay in OpenOCD + the `.cfg` procs; this app is the shell.

The full GUI runs on Windows, Linux, macOS, and Web. Android currently has an
experimental read-only surface for **Default SWD → Check connection** over a
direct ST-LINK USB-OTG connection. The command logic is shared Dart, with a
vetted native OpenOCD/RDP bundle retained for each desktop OS.

## What it does

Connection modes: **Default SWD** · **Power-race** (respawn connect) ·
**C45 clone** (guided hold/release) · **C45 genuine** (nRST).

Actions:

- **Check connection** — read-only probe
- **Backup** — full 128 KB dump, validated
- **SHU compatible** — dump → patch the chip's own firmware → flash back
- **Backup + Flash** / **Flash Only** — flash a `.bin`, either the full image or
  slot 0 only (slot 0 is identity-safe, and accepts a zip3/zip3.2 package too)
- **Check protection** / **Unlock / rescue** — read-protection (FAP) verdict + WRP-safe rescue

Plus: firmware validation (size / all-zeros / write-protected diagnostics),
mandatory backup-first, re-seat retry, a resizable/pinnable OpenOCD console with
copy + opt-in per-run log files, and persisted settings (connection, backup
folder / filename prefix / second-copy, and accent theme).

## Requirements

- **Flutter SDK** (stable) + Dart
- **Windows:** Visual Studio 2022 with the *Desktop development with C++* workload
- **macOS:** Xcode + CocoaPods
- **Linux:** clang + GTK dev libs (`flutter doctor` lists specifics). Native
  swdart packaging/testing also requires the distribution's libusb 1.0 runtime
  (Debian/Ubuntu/Mint: `libusb-1.0-0`) and ST-LINK USB permissions, normally
  installed from `native/linux/oocd/contrib/60-openocd.rules`.
- **Android:** a phone or tablet with USB-host/OTG support. Android asks for
  per-device permission and talks directly to one supported ST-LINK through
  `android.hardware.usb`; it does not use OpenOCD, BLE, or a serial adapter.

Run `flutter doctor` and resolve anything for your target OS.

## Build & run

```bash
flutter pub get
flutter run -d windows      # or: macos | linux
flutter build windows --release
flutter build apk --debug   # source-build check; not OTG hardware evidence
./tool/package_macos.sh     # universal app + embedded OpenOCD + ZIP
```

The release output is in `build/<os>/…`. For distribution, place a copy of the
per-OS `native/<os>/` folder where `OpenOcdPaths.find()` can reach it. The
macOS packaging script handles this automatically by embedding it at
`x3utils.app/Contents/MacOS/native/macos`, then ad-hoc signing and verifying the
complete app. Its output is written under `dist/` as a versioned app folder and
`x3utils-<version>-macos-universal.zip`.

### macOS package details

`tool/package_macos.sh` is the supported macOS distribution path. It:

- builds Flutter's universal x86_64 + arm64 release;
- embeds `native/macos` under `Contents/MacOS/native/macos`;
- preserves executable permissions for OpenOCD and RDP scripts;
- verifies the app, Flutter framework, OpenOCD, and support dylib architectures;
- ad-hoc signs and validates the complete app;
- parses the packaged Power-race config without connecting to hardware;
- creates the versioned `.app` folder and ZIP in `dist/`.

The app uses the generated lightning `AppIcon` and a 1200x800 initial window.
If Dock or Launchpad shows an old Flutter icon while Finder shows the correct
one, that is macOS icon caching. Remove the old app and install the fresh
package; do not change the icon identity as a cache workaround.

## v1.1.3 missing-backend hotfix

The app must never fake a hardware success when OpenOCD is missing. In v1.1.3,
if the bundled backend cannot be found, actions fail closed with `OpenOCD
missing`, `Cannot run <action>`, and `Last connect: FAIL`. The console must not
show simulated `target halted`, `PASS`, or `OK` lines.

This is especially important for source builds, unsupported platforms, and
release packaging smoke tests. Android is never treated as Linux: it selects
the direct swdart USB-host backend and currently advertises only Default-SWD
Check. Backup, flashing, SHU, protection/recovery, C45, nRST and Power-race all
fail closed before hardware until each Android path is implemented and tested.
Other unsupported OS targets fail as unsupported backends.

To smoke-test an installed Windows package, temporarily rename:

```powershell
%LOCALAPPDATA%\Programs\x3utils\native\windows\oocd
```

Launch the app and run **Check connection**. Expected result: a red
missing-OpenOCD failure, no simulated console output. Rename the folder back
before normal use.

On macOS, the equivalent backend is:

```text
x3utils.app/Contents/MacOS/native/macos/oocd
```

Renaming it and relaunching the app must produce the same fail-closed result.
The backend is resolved during app startup, so restore the directory name and
relaunch before normal use.

## Protection checks by connection mode

The GUI honors the selected protection-check connection mode:

- **Default SWD** — plain init/reset halt.
- **C45 Clone** — guided hold/count/release flow.
- **C45 Genuine** — hardware nRST.
- **Power-race** — intentionally blocked; RDP/protection work requires a
  stable session.

The GUI identifies modes by name only. The CLI launchers still letter their
menus A/B/C/D; those letters are a CLI convention and are deliberately not
mirrored here, because the GUI's rail order differs from the launcher order.

On macOS, Flutter writes `config.sh` at its temporary RDP run root because the
macOS CLI-derived scripts load it via `../../config.sh`. Linux keeps config
beside its temporary RDP scripts. This platform-specific layout must be
preserved.

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
  macos/  linux/       per-OS OpenOCD + special/rdp shell toolkit
design/flash-studio.html   the original visual mockup / spec
```

`OpenOcdPaths.find()` walks up from the executable to resolve
`native/<os>/oocd`. In the packaged macOS app the executable is under
`Contents/MacOS`, so the backend is embedded directly beneath that directory.

## Native backend layout

The Dart orchestration is shared; each OS supplies its native backend:

1. Place the OS's OpenOCD in `native/<os>/oocd/` (macOS uses the universal
   xPack build; its Artery cfgs live at `target/artery/at32f4x*`, including the
   Power-race `_race.cfg` variant handled by `cfg.dart`).
2. Place the OS's protection toolkit under `native/<os>/special/rdp/`.
3. Build/package for the target OS and test against hardware.

## Versioning

Version lives in four places — **keep them in sync**: `VERSION`,
`pubspec.yaml` (`version:`), and `kAppVersion` in `lib/theme.dart` (drives the
UI). Current: **2.1.7**. Also in installer/x3utils.iss `AppVer`. The release
channel is a separate `kAppStage` in `lib/theme.dart` (`BETA`, or `''` for
stable), kept out of those four strings so they stay byte-equal.

Don't edit those by hand — use the sync tool, which manages all 7 spots
(the five x.y.z strings + the pubspec build number + `kAppStage`):

```
dart run tool/version.dart                 # check: report all, fail on drift
dart run tool/version.dart 1.2.1           # set version everywhere (+build bump)
dart run tool/version.dart 1.2.1 --stage BETA
dart run tool/version.dart --stage ""      # keep version, clear the channel
```

## Hardware stress tests

Two destructive loader tests live in `test/hardware/`. Both refuse to run
without their guarded launcher, capture the board's full flash before the first
erase, stop on the first failure, and never retry after an erase. They leave the
target halted — power-cycle it afterwards.

```
dart run tool/swdart_loader_stress.dart --confirm-sacrificial --cycles 20
dart run tool/swdart_mcu_stress.dart    --confirm-sacrificial --cycles 100
```

The first targets a sacrificial **CBT7 (VCU)**, the second a sacrificial
**RBT7 (MCU)**. Each is gated to its own IDCODE and refuses any other part.

The MCU one is not a duplicate. The MCU firmware runs an ADC ring buffer at
`0x20000FA8`, inside the loader's staging window at `0x20000800`; the VCU has
active DMA too but its buffers sit outside that window. A regression in the
reset catch therefore corrupts flash on the MCU and is invisible on the VCU. Per
cycle it asserts the baseline `VTOR` is `0x00000000`, no DMA channel was live at
staging, no staged chunk was restaged, all 16 loader chunks completed in order
(so a silent fall back to direct word writes cannot pass), and an independent
fresh-session readback matches the golden.

Its log-parsing checks are themselves unit-tested and run in the normal suite,
so a change to the engine's log wording fails fast instead of quietly making the
stress test blind.

Runs write a transcript, `summary.json` and the golden image under
`build/loader_stress/` or `build/mcu_loader_stress/`.

## Safety

Flashing writes to a real vehicle controller. Write actions back up first and
verify; a read-protected chip is detected and rescue uses the deterministic,
WRP-safe option-byte rewrite (never the driver `unlock`). Still — use the right
`.bin` for your model, and keep the SWD/C45 contact steady.

## Credits

The zip3 firmware import (**Choose .zip** → decrypt → flash slot 0) is a Dart
port of two open-source [ScooterHacking](https://scooterhacking.org) projects,
used under the MIT License:

- **[NinebotTEA](https://github.com/scooterhacking/NinebotTEA)** — the TEA
  cipher for Ninebot / Xiaomi scooter firmware. Ported to Dart in
  [`lib/engine/ninebot_tea.dart`](lib/engine/ninebot_tea.dart).
  © 2024 ScooterHacking · MIT.
- **[fw-zip-package-v3](https://github.com/scooterhacking/fw-zip-package-v3)** —
  the v3 firmware `.zip` package format and `pack.py`. Ported to Dart in
  [`lib/engine/pack_zip3.dart`](lib/engine/pack_zip3.dart) (pack + strict
  encrypted/MD5 unpack). By ScooterHacking · MIT.

Thanks to the ScooterHacking community (<hi@scooterhacking.org>) for building and
open-sourcing these tools.
