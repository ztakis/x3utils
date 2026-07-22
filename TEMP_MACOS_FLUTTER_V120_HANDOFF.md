# TEMPORARY: macOS Flutter v1.2.0 Test Handoff

Delete this file after the macOS results are recorded in `docs/testing.md` and
`DEVLOG.md`.

## Scope arriving from Linux

The current Flutter source is still v1.2.0 BETA. The Linux pass added or
confirmed:

- strict guarded-firmware banners: known VCU codes only (`xxU2`, `xxG3`,
  `xGT3`, `xxF3`) and exact MCU code `0001`;
- fail-closed target matching after the mandatory backup, including VCU/MCU
  and cross-model VCU rejection;
- SHA-256 rechecks at Start and again after the backup so a selected guarded
  firmware file cannot be replaced before the write;
- Make zip3's best-effort workflow and safety wording: ZP is written by BLE,
  can remain stale after an ST-Link slot-0 write, and must never be guessed;
- Linux Nemo reveal now starts detached, so its Snackbar is immediate;
- Linux `tool/window_size.sh`, matching the Windows diagnostic helper;
- tests for the compatibility matrix, guarded ZIP3/banner behavior, digest
  rechecks, and pinned Make zip3 failures.

The MCU banner cannot identify the model. ZT3/GT3/G3 share MCU hardware, but F3
does not; the common `SCOOTER_MCU_0001` banner cannot protect an F3 MCU swap.
Flash Only remains the warned expert override.

Make zip3 is optional. Its intended input is a fresh full ST-Link backup taken
immediately after the current firmware was installed through BLE, before any
ST-Link firmware write. A structurally valid ZP can be stale and x3utils cannot
detect that. A created package still needs acceptance testing in the BLE app.

## Known baseline before macOS testing

- Linux live test: ZT3 VCU target plus selected GT3 VCU firmware performed the
  mandatory backup, then aborted before writing and kept the backup.
- Linux live test: a dump without a trustworthy BLE ZP length record stopped
  Make zip3 with the new fail-closed explanation.
- All 90 non-UI Flutter tests passed. After the final wording change, the 27
  Make zip3 engine tests passed and `flutter analyze` was clean.
- `flutter build linux --release` passed before the final copy-only UI edit.
- The existing `test/widget_test.dart` 1024x768 smoke has two known test-harness
  failures: a 1 px status-bar Row overflow and Advanced rail taps that remain
  off-screen. The focused Make zip3 widget case therefore misses the rail item
  before it can open the notice. Do not attribute those two failures to macOS.
- No macOS package has been built from this change set yet.

## macOS dry/package checks

From `x3utils_flutter/`:

```bash
flutter test test/confirmed_file_writer_test.dart \
  test/desktop_path_display_test.dart \
  test/flash_only_validation_test.dart \
  test/pack_zip3_dump_test.dart \
  test/rdp_runner_test.dart \
  test/target_identity_test.dart
flutter analyze
./tool/package_macos.sh
```

The package script must produce the versioned universal ZIP under `dist/` and
pass its x86_64/arm64 slice, deep ad-hoc signature, embedded backend, and
Power-race cfg checks. Use this script rather than a plain macOS release build.

## Packaged-app UI checks

- Confirm v1.2.0 BETA and the correct app icon.
- Confirm the startup content area is 1024x768 and there is no visible layout
  overflow at the bottom status bar.
- Exercise a result-path folder button. Finder should open/select the item and
  the Snackbar should appear promptly. macOS uses `open`/`open -R`; the Linux
  detached-process fix does not change this path.
- Open Make zip3 and review the full notice at 1024x768. It must explain fresh
  after-BLE backup, stale ZP, refusal to guess, BLE acceptance testing, and
  operator-selected Type/Model.
- Confirm a missing/invalid ZP dump shows the new fail-closed message without
  layout clipping.
- Confirm a known fresh BLE backup can create a package, its result path opens,
  and the BLE app accepts it through Load from file. Keep acceptance as a test
  result, not a promise made by x3utils.

## Hardware safety checks

Use only the normal testbed and firmware whose identities are known.

- Guarded Flash slot 0: deliberately select a known cross-model VCU image. The
  app should make and preserve the pre-flash backup, identify both models, and
  abort before any erase/write command.
- Repeat one VCU-versus-MCU mismatch if useful; it must also abort after backup.
- Run a matching guarded case only if an actual write is intended. Success must
  still require real OpenOCD write/verify evidence.
- Confirm Flash Only remains permissive only behind its existing expert warning.
- Recheck A/B/C connection behavior and guided C45 prompts. Mode D remains a
  connection strategy; its verdicts still require the normal evidence.
- Check protection must remain blocked before script launch in Power-race mode.
  macOS A/B/C protection checks must still pass `--launcher` and use the
  root-level temporary `config.sh` layout.

## Closeout

Record architecture, package artifact, dry checks, each hardware action, and
any remaining limitation in `docs/testing.md` and `DEVLOG.md`. Then delete this
temporary handoff before the final macOS-tested commit (or in the immediate
follow-up commit if it was needed to move the work between machines).
