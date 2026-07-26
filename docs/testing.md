# Testing Notes

This repo is tested manually on real testbed boards that can be reflashed
repeatedly. There is no full CI replacement for these hardware checks.

Use this file to keep hardware test context portable across Windows, Linux,
macOS, work machines, home machines, and separate chat sessions.

## Testbed Boards

| Name | Chip / Board | ST-LINK | Usual Mode | Notes |
| --- | --- | --- | --- | --- |
| TBD | AT32F415 / X3 VCU | Clone ST-LINK | C45 clone | Main repeated-flash board |
| TBD | AT32F415 / X3 VCU | Genuine ST-LINK | Genuine nRST | Genuine adapter coverage |
| TBD | AT32F415 / X3 VCU | ST-LINK | Default / blinker buttons | SWD/default-mode coverage |
| TBD | AT32F415 / X3 VCU | ST-LINK | Power-race | Power-cycle catch coverage |

## Workstations

| Name | OS | Architecture | OpenOCD Source | Notes |
| --- | --- | --- | --- | --- |
| TBD | Windows | TBD | bundled `x3utils_win/oocd` / Flutter bundle |  |
| TBD | Linux | TBD | bundled `x3utils_linux/oocd` |  |
| TBD | macOS | arm64 or x86_64 | bundled xPack OpenOCD |  |

## Standard Hardware Checklist

Record one row per meaningful test run.

| Date | OS | Board | ST-LINK | Mode | Action | Result | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| TBD | TBD | TBD | TBD | TBD | dump / flash / compat / slot0 / rdp | pass / fail |  |
| 2026-07-24 | Windows home primary | ZT3 VCU test board | ST-LINK | A / Default SWD | Flutter v1.2.0 SHU compatible with the "Attempt to also make zip3" checkbox ticked | pass | Compat flash completed green (TOOK 0:07). With the checkbox on, the run emitted three co-located files under one shared timestamp in `Documents/x3utils/compat/` — `compat_<ts>.bin` (backup), `compat_<ts>_patched.bin`, and `compat_<ts>_patched.zip` — and showed the "BLE-loadable zip3 saved beside the backup" note. The checkbox-produced `_patched.zip` was then loaded through the BLE app's Load from file, recognized as `zt3 / VCU`, flashed 57.4 KB, and reported "Firmware flashed successfully". End-to-end proven: compat flash → auto zip3 → BLE load → PASS. VCU path; MCU auto-skip not exercised here. |
| 2026-07-24 | macOS 15.7.7 / Intel x86_64 | ZT3 VCU test board | ST-LINK | A / Default SWD | Flutter v1.2.0 BETA packaged Check connection + matching Backup + Flash | pass | The packaged universal app used its embedded xPack OpenOCD backend. Check connection halted the target, found the `artery` flash bank at `0x08000000`, and exited 0. The guarded run saved `/Users/akis/Documents/x3utils/backup/dump_2026-07-24_00-48-46.bin` plus its secondary copy, identified matching ZT3 VCU target and genuine firmware, erased and wrote 131072 bytes in 47.788 s, verified 131072 bytes in 3.303 s, exited 0, and completed green. This closes the minimum macOS hardware smoke; the broader Windows matrix was not repeated. |
| 2026-07-24 | Linux Mint home primary / x86_64 | ZT3 VCU test board | ST-LINK | A / Default SWD | Flutter v1.2.0 BETA packaged Check connection + matching Backup + Flash | pass | Maintainer confirmed the final AppImage used its real packaged OpenOCD backend for an evidence-backed connection PASS and one genuine matching guarded full-image run. A fresh pre-flash backup was created, then the write and verify evidence and green completion screen all passed. Save log was not enabled, so the exact firmware and backup paths are unavailable in a per-run log. This closes the minimum Linux hardware smoke; the broader Windows matrix was not repeated. |
| 2026-07-23 | Windows home primary | AT32F415 X3 testbed | ST-LINK | A / Default SWD | Flutter v1.2.0 BETA Backup + Flash | pass | Windows debug build: repeated-byte, wrong-size, unknown-banner, and missing-banner full images stopped at selection before hardware. Genuine G3 VCU and MCU full images each created and displayed the mandatory backup, then aborted before write against the installed ZT3 VCU. Re-flashing the fresh matching ZT3 backup created another pre-flash backup, wrote the full image, and verified in 7 s. |
| 2026-07-23 | Windows home primary | AT32F415 X3 testbed | ST-LINK | A / Default SWD | Flutter v1.2.0 BETA guarded Flash slot 0 `.bin` / ZIP3 | pass | Windows debug build: a missing-banner slot `.bin` was rejected before hardware; genuine G3 VCU and MCU `.bin` selections each created and displayed the pre-flash backup, then aborted before write against the installed ZT3 VCU; a matching ZT3 VCU `.bin` backed up, wrote, and verified slot 0 in 4 s. A valid G3 VCU ZIP3 decrypted and then followed the same backed-up mismatch abort; a matching ZT3 VCU ZIP3 decrypted, backed up, wrote, and verified slot 0 in 4 s. |
| 2026-07-23 | Windows home primary | AT32F415 X3 testbed | ST-LINK | A / Default SWD | Flutter v1.2.0 BETA Flash Only full / slot 0 / ZIP3 | pass | Windows debug build: after the new compatibility-warning modal, a full 131072-byte VCU `.bin` erased, wrote, and verified in 7 s; a VCU slot-0 `.bin` wrote and verified in 4 s; and a valid VCU ZIP3 decrypted, then wrote and verified at slot 0 in 4 s. All three correctly stated that no backup was taken. This proves the Flash Only workflow and write verification, not compatibility with the connected controller. |
| 2026-07-13 | Linux Mint home primary | AT32F415 testbed | Clone ST-LINK | A | full flash with backup | pass | Baseline using `zt3_vcu_rescue.bin`; dump, erase, write, verify all completed. |
| 2026-07-13 | Linux Mint home primary | AT32F415 testbed | Clone ST-LINK | D | dump / full flash / SHU compat | pass | Power-race caught and verified dump, forced-backup flash, and SHU compat patch+flash. |
| 2026-07-13 | Linux Mint home primary | AT32F415 testbed | Clone ST-LINK | D | special flash-only / slot0 | pass | `flash_only.sh` recovered from adapter-missing `x` symbols; `flash_slot0.sh` wrote slot0 and verified successfully. OpenOCD reported 61440 written vs 60868 verified for the slot image, matching cross-platform behavior. |
| 2026-07-13 | Linux Mint home primary | AT32F415 testbed | Clone ST-LINK | D | RDP check / FAP enable / FAP clear / rescue unlock | pass | `rdp_check.sh -l` detected unlocked, protected, and unlocked-again states. FAP writers/rescue may miss the first race and then succeed on manual retry. |
| 2026-07-21 | Linux Mint home primary | AT32F415 testbed | ST-LINK test setup | A/B/C/D | CLI v1.8.0 Check Connection | pass | A and C halted and probed normally; B kept the guided hold/count/release prompts live; D reported a missing adapter, retried, then caught and confirmed the flash bank on attempt 218. A/B/C reported the stable board fingerprint PC `0x08000120`, MSP `0x20000550`. |
| 2026-07-21 | Linux Mint home primary | AT32F415 testbed | ST-LINK | A | CLI v1.8.0 integrated launcher | pass | Full dump, protection check, SHU-compatible flash, backup + loaded-file flash, Advanced flash-only, and Advanced slot0 all passed. Advanced rescue launched with `-l`, displayed the plain-mode and mass-erase warnings, and was intentionally aborted at the `UNLOCK` confirmation; no destructive rescue action ran. |
| 2026-07-22 | Linux Mint home primary | ZT3 VCU target | ST-LINK | selected GUI mode | Flutter v1.2.0 guarded Flash slot 0 mismatch | pass | After the mandatory backup, the target identified as ZT3 VCU while the selected firmware identified as GT3 VCU. The app aborted before the write, warned that incompatible firmware can brick the controller, and kept the pre-flash backup. |
| 2026-07-21 | macOS Intel | AT32F415 testbed | ST-LINK test setup | A/B/C/D | CLI v1.8.0 Check Connection | pass | A halted and probed normally; B preserved the guided hold/count/release prompts; C recovered from transient examination errors, halted, and probed; D caught and confirmed the `artery` flash bank on attempt 197. A/B/C reported PC `0x08000120`, MSP `0x20000550`. |
| 2026-07-21 | macOS Intel | AT32F415 testbed | ST-LINK | A | CLI v1.8.0 integrated launcher | pass | Backup + loaded-file flash (`zt3_vcu_rescue.bin`), SHU-compatible dump/patch/flash, Advanced flash-only, and Advanced slot0 all wrote and verified successfully. Protection check read FAP `0xA5`/complement `0x5A` and readable flash, reporting NOT PROTECTED. Rescue displayed the plain-mode and mass-erase warnings and was intentionally aborted before `UNLOCK`; no mass erase ran. |
| 2026-07-21 | macOS Intel | AT32F415 testbed | ST-LINK | D | CLI v1.8.0 protection check | pass | xPack Power-race caught on attempt 403, detected the `artery` flash bank, read FAP `0xA5`/complement `0x5A` and readable vectors, then reported NOT PROTECTED. The first port incorrectly waited for Linux OEM's literal `target halted`; macOS now stops on complete RDP evidence. |
| 2026-07-21 | macOS Intel | AT32F415 testbed | ST-LINK | D | CLI v1.8.0 rescue unlock / post-POR check | pass | `rescue_unlock.sh -l -y` caught on attempt 18, completed the option rewrite, read back `ffff5aa5`, and emitted the completion marker. After power-cycle, `rdp_check.sh -l` caught on attempt 2, confirmed FAP `0xA5`/complement `0x5A`, and found readable blank `0xFF` main flash—the warned mass erase occurred. |
| 2026-07-21 | macOS Intel | AT32F415 testbed | ST-LINK | A | CLI v1.8.0 post-rescue recovery | pass | Backup + Flash safely aborted because the mass-erased backup was correctly rejected as single-byte `0xFF` content. Advanced Flash Only then erased, wrote, and verified the full 131072-byte `zt3_vcu_rescue.bin`, restoring normal firmware. |
| 2026-07-16 | macOS Intel | AT32F415 testbed | Clone ST-LINK | D | full dump | pass | Three successful validated 131072-byte dumps: attempts 75, 312, and 110. During experimentation, SWD could halt on attempts 31, 6, and 105 without the dump completing, consistent with marginal/parasitic powering. The live-catch experiment was reverted; mode D remains best-effort and reports success only after the complete action. |
| 2026-07-16 | macOS Intel | AT32F415 testbed | Clone ST-LINK | A | Flutter packaged Check connection | pass | Packaged v1.1.3 app detected the target and reported PASS using embedded universal OpenOCD. |
| 2026-07-16 | macOS Intel | AT32F415 testbed | Clone ST-LINK | D | Flutter packaged Check connection | pass | Power-race caught on attempt 78, detected the `artery` flash bank at `0x08000000`, exited 0, and produced an evidence-backed PASS. |
| 2026-07-16 | macOS Intel | AT32F415 testbed | Clone ST-LINK | D | Flutter Check protection | pass | Action was blocked as Not supported before launching the RDP toolkit; no hardware command ran. |
| 2026-07-16 | macOS Intel | AT32F415 testbed | Clone ST-LINK | A | Flutter Check protection | pass | `rdp_check.sh --launcher` used launcher A, read FAP=0xA5/FAP_COMP=0x5A and readable flash, then reported NOT PROTECTED. |
| 2026-07-16 | macOS Intel | AT32F415 testbed | Clone ST-LINK | B | Flutter Check protection | pass | Guided C45 hold/count/release completed; FAP and main-flash evidence produced NOT PROTECTED. |
| 2026-07-16 | macOS Intel | packaged app | n/a | n/a | Missing-backend smoke test | pass | Renamed embedded `oocd`; app failed closed with OpenOCD missing, no simulation and no false hardware evidence. Backend is resolved at startup, so restore the name and relaunch. |

## Dump Test

- Select the intended connection mode.
- Run full 128 KB dump.
- Confirm output file exists in the platform backup folder.
- Confirm secondary backup exists if that option is enabled.
- Confirm validator accepts the dumped file.
- Note whether read protection or connection timing affected the run.

## Full Flash Test

- Validate the input `.bin` first.
- Confirm backup behavior is the intended one for the selected action.
- Confirm erase/write/verify completes.
- Confirm OpenOCD exits with success.
- Confirm board remains recoverable after the flash.

## SHU Compat Test

- Confirm raw dump is created.
- Confirm secondary backup is created if that option is enabled.
- Confirm patch injection succeeds.
- Confirm patched file is exactly `131072` bytes.
- Confirm flash and verify complete.
- Confirm the board remains recoverable.

## C45 Clone Guided Test

- Confirm operator prompt asks to ground nRST/C45.
- Confirm countdown honors the selected timeout.
- Confirm OpenOCD connects while nRST is held low.
- Confirm operator prompt asks to release nRST.
- Confirm target re-examines and halts.
- Confirm dump or flash proceeds after the guided flow.

## Power-Race Test

- Confirm live UI shows attempts and race tier changes.
- Confirm adapter-gone cases are visible to the user.
- Confirm caught attempts stream the winning OpenOCD output.
- Confirm stale timeout lines do not appear after a successful run.
- Confirm dump success requires `dumped`.
- Confirm flash success requires `wrote` plus `verified`.

## Non-Hardware Port Checks

| Date | OS | Scope | Result | Notes |
| --- | --- | --- | --- | --- |
| 2026-07-26 | Windows home primary | Flutter v1.2.1 three-way ZIP3 Slice / Pack / Unpack | pass | Offline-only verification. The focused ZIP3 engine, controller, confirmed-write, and widget suite passed 86/86; `flutter analyze` and `git diff --check` were clean. Coverage includes strict 128 KB Slice routing; VCU/MCU/BMS/BLE Pack metadata and round trips; rejection of full dumps, non-byte-exact NinebotTEA lengths, VCU/MCU ceiling violations, and missing/unsupported/contradictory banner evidence; page-state isolation; and the three-position locked workspace. After disabling the outdated entry modal, the widget suite passed 3/3 and the analyzer remained clean. No packaged-app build, BLE operation, or hardware command was run. |
| 2026-07-25 | Windows home primary | Flutter v1.2.1 Pack / Unpack zip3 offline validation | pass | `flutter analyze` was clean; the focused ZIP3, confirmed-write, and widget suite passed 65/65. A temporary private-corpus probe passed 3/3: real BMS and BLE packages decrypted, including a roughly 1.85 MB BLE archive; 13 malformed packages were rejected at their intended gates; and a valid VCU package with an extra padding member was accepted by the extraction-only policy. Tests also confirm flash ZIP import remains VCU/MCU-only and size-gated. No packaged-app build, BLE operation, or hardware command was run. |
| 2026-07-24 | macOS 15.7.7 / Intel x86_64 | Flutter v1.2.0 BETA minimum packaged validation | pass | The focused test set and `flutter analyze` passed. `tool/package_macos.sh` produced `dist/x3utils-1.2.0-macos-universal.zip` and passed the x86_64/arm64, deep-signature, embedded-backend, RDP-script, and Power-race-cfg checks. The packaged app opened at 1024x768 and passed the truncated-full refusal, ZT3/VCU Make zip3 preselection and creation, unchanged existing output after Replace/Cancel, valid ZIP3 round-trip import with matching evidence cancelled before flash, and prompt Finder reveal. Saved app logs corroborate the 58460-byte package creation, existing-package Cancel, and 58460-byte decrypted import. The generated package is structurally accepted by x3utils, not yet BLE-proven. Minimum macOS validation is closed. |
| 2026-07-24 | Linux Mint home primary / x86_64 | Flutter v1.2.0 BETA minimum packaged validation | pass | Maintainer confirmed the focused tests and `flutter analyze` passed, and `tool/build_appimage.sh` produced and launched `dist/x3utils-1.2.0-x86_64.AppImage` with the real Linux payload. The packaged smoke passed at 1024x768: truncated-full rejection, ZT3/VCU Make zip3 preselection and creation, unchanged existing output after Replace/Cancel, valid ZIP3 round-trip import with matching JSON/banner evidence cancelled before flash, and prompt Linux file-manager reveal. Local artifacts corroborate the round trip: `platform_make_zip3_test.zip` and two identical 58460-byte decrypted imports, including one created after the final AppImage build. Minimum Linux and macOS validation is closed. |
| 2026-07-23 | Windows home primary | Flutter v1.2.0 BETA Make zip3 desktop UI, output safety, and round-trip | pass | Genuine ZT3 VCU and MCU dumps created packages, with MCU model chosen manually. Existing-output Cancel preserved size, timestamp, and SHA-256; Replace rewrote the file. Real OEM-key and length-zero-ZP dumps plus conflicting synthetic ZP records were refused; a single relocated record produced the expected 58436-byte payload. A package created from the genuine VCU dump re-imported through Flash Only with valid MD5/decryption and matching ZT3/VCU JSON/banner evidence, then was cancelled before flash. The focused Make zip3 suite passed 31/31 after simplifying the SHU-key message. This is desktop structural validation; BLE Load-from-file acceptance remains pending. |
| 2026-07-23 | Windows home primary | Flutter v1.2.0 BETA Flash Only validation and compatibility-warning UI | pass | Manual debug-build checks covered raw full/slot `.bin` selection, hard size stops, banner/serial/ZP findings, multi-finding modal layout, valid ZIP3 import, and hard ZIP3 rejection for BLE/BMS, MD5 failure, unsupported model, inconsistent JSON, and JSON/banner disagreement. The focused `flash_only_validation_test.dart` plus `firmware_inspection_test.dart` run passed 28 tests; `flutter analyze` was clean. Synthetic inputs were never flashed; the three genuine hardware writes are recorded separately above. |
| 2026-07-23 | Windows home primary | ZP extraction hardening + test-bin additions | pass | `Zp.payloadFromDump` now prefers the authoritative `0x1F800` record and requires unanimity from the page scan otherwise; conflicting records refuse instead of first-candidate-wins. `flutter test test/pack_zip3_dump_test.dart` passed 31/31 (4 new: decoy-vs-authoritative, guard-failing decoy, relocated accept, conflict refuse); `flutter analyze` clean. The real engine was run against the generated ZP fixtures and real rescue/OEM corpus images: all verdicts matched the manifest, including the previously silent decoy case now extracting the correct payload. Test-bin set grew to 40 (`8e`/`8f` wrong-component 128K bins, `12d` conflict, `12e` relocated). No hardware command ran. |
| 2026-07-23 | Windows home primary | Test-bin corpus survey + `tool/gen_test_bins.dart` | pass | Byte survey of the private test-bin corpus (untracked, outside the repo) confirmed banner/key/ZP layout facts against real dumps. The new deterministic generator wrote 36 validation test bins plus `gen_manifest.csv` (knob turned, expected verdict, SHA-256). Structural checks confirmed banners, key states, slot-1 copies, and ZP records at the measured offsets; zip3 mutation cases were functionally spot-checked (schemaVersion, relabeled model with valid MD5, real MD5 mismatch, missing info.json). No hardware command ran. |
| 2026-07-22 | Linux Mint home primary | Flutter v1.2.0 Linux/AppImage UI | pass | The AppImage built and launched at 1024x768 client size (1024x800 outer). The new `tool/window_size.sh` reported PID/title/outer/client/position correctly. Nemo reveal returned immediately and showed its Snackbar without waiting for the Nemo window to close. |
| 2026-07-22 | Linux Mint home primary | Flutter firmware guards and Make zip3 | pass with known UI-test limitation | All 90 non-UI tests passed, including the strict supported-banner matrix, guarded-file digest rechecks, and fail-closed Make zip3 cases; the final Make zip3 wording's focused 27 tests also passed. `flutter analyze` and the Linux release build passed. Live UI confirmed that a missing/invalid BLE ZP record is rejected rather than guessed. The existing 1024x768 widget smoke remains blocked by a 1 px status-bar overflow and off-screen Advanced rail taps. |
| 2026-07-21 | Linux Mint home primary | CLI v1.8.0 Linux port | pass | All Linux shell scripts passed `bash -n`; ShellCheck reported no error-severity findings; `git diff --check` passed; launcher main/Advanced navigation smoke test passed without hardware access. Remaining ShellCheck output is shared-source analysis and existing style guidance. |
| 2026-07-21 | macOS Intel | CLI v1.8.0 macOS port | pass | All macOS shell scripts passed `bash -n`; `git diff --check`, launcher main/Advanced navigation, executable-permission checks, A/B/C/D RDP resolver construction, and arm64/x64 target-asset checks passed. Bundled xPack OpenOCD launched and reported its version. ShellCheck was unavailable on this machine. |
| 2026-07-16 | macOS Intel | CLI v1.7.0 Power-race port | pass | System Bash 3.2 syntax passed for all macOS scripts; `git diff --check` passed; arm64/x64 race configs are identical; x64 bundled OpenOCD parsed `target/artery/at32f4x_race.cfg` and shut down without `init`. The temporary live-catch monitor was reverted after hardware showed that SWD halt cannot prove stable external 3V3 power. The macOS read-only RDP check does not support `-l`; mode-D flash validation remains required. |
| 2026-07-16 | macOS Intel | Flutter v1.1.3 package | pass | `tool/package_macos.sh` built a universal app, embedded `native/macos`, verified architecture slices and deep ad-hoc signature, parsed the packaged race cfg without `init`, and produced a ZIP. |
| 2026-07-16 | macOS Intel | Flutter RDP temporary-tree regression | pass | `flutter test test/rdp_runner_test.dart` used fake OpenOCD to confirm macOS root-level `config.sh`, `--launcher`, and A/B/C mode selection. `flutter analyze` passed. |
| 2026-07-17 | macOS Apple Silicon | Flutter v1.1.3 package smoke check | pass | Quick-tested the macOS GUI package on Apple Silicon for basic packaged-app/runtime sanity. Full hardware coverage remains recorded separately. |

### macOS mode-D RDP check note

- The standalone macOS CLI accepts `rdp_check.sh -l` in launcher modes A/B/C/D.
  Mode D uses fresh xPack OpenOCD processes and keeps the final verdict gated
  on actual FAP/main-flash evidence; it does not treat a halt alone as a green
  protection verdict. Hardware caught on attempt 403 and reported NOT PROTECTED
  from valid option-byte and main-flash evidence.
- Mode-D `rescue_unlock.sh -l` uses the same fresh-process hammer strategy after
  the explicit `UNLOCK` confirmation. It requires option-area readback plus an
  end-of-sequence marker before reporting success. Hardware completed on attempt
  18; the post-POR check completed on attempt 2 and confirmed unlocked option
  bytes plus the expected blank main flash after mass erase.
- Flutter separately blocks Power-race RDP before script launch, so its macOS
  RDP check continues to use `--launcher` only for modes A, B, and C.

## Regression Notes

Use this section for failures that should be remembered.

### YYYY-MM-DD

- Issue:
- Platform:
- Board:
- Reproduction:
- Fix or workaround:

### 2026-07-13

- Issue: `rescue_unlock.sh -l` printed the launcher-A plain-mode warning while
  actually using launcher-D power-race.
- Platform: Linux Mint home primary.
- Board: AT32F415 testbed with clone ST-LINK.
- Reproduction: Set launcher to D, run `special/rdp/rescue_unlock.sh -l -y`.
- Fix or workaround: `rdp_lib.sh` now excludes `RACE=true` from
  `launcher_mode_is_plain`.

### 2026-07-13

- Issue: `rdp_check.sh -l` can sometimes report option-byte state with only
  SWDIO/SWCLK/GND connected and no explicit 3V3 jumper.
- Platform: Linux Mint home primary.
- Board: AT32F415 testbed with clone ST-LINK.
- Reproduction: Run mode-D RDP check while target power is not intentionally
  connected.
- Fix or workaround: Treat as a testbed observation only, likely residual or
  SWD-provided power. Do not document as supported wiring; write/flash/rescue
  flows still require clean target power.

### 2026-07-16

- Issue: Packaged Flutter macOS RDP check failed with `Missing config.sh`.
- Platform: macOS Intel, packaged Flutter v1.1.3.
- Reproduction: Run Check protection; Flutter copied `special/rdp` to a
  temporary tree but wrote config beside the scripts while macOS scripts load
  `../../config.sh`.
- Fix or workaround: Write macOS config at the temporary run root. Linux keeps
  config beside its scripts. Added a fake-OpenOCD regression test.

### 2026-07-16

- Issue: Dock/Launchpad displayed Flutter's old icon although Finder and the
  app bundle contained the correct lightning icon.
- Platform: macOS Intel.
- Reproduction: Replace an app with the same bundle identifier after changing
  its icon.
- Fix or workaround: Treat as macOS icon cache. Trashing the old app and
  installing fresh resolved it. Do not rename `AppIcon` or bump versions solely
  as a cache workaround.

### 2026-07-21

- Issue: macOS CLI Mode-D `rdp_check.sh -l` kept respawning after complete FAP
  and main-flash reads.
- Platform: macOS Intel CLI v1.8.0 with bundled xPack OpenOCD.
- Reproduction: Select launcher Mode D and run Advanced Check Protection.
- Fix or workaround: Linux OEM OpenOCD prints `target halted`, but xPack at
  `-d0` does not. Grade the attempt from action-specific flash-bank, FAP, and
  main-flash evidence. Hardware retest passed on attempt 403. Mode-D rescue now
  also respawns and requires rewrite/readback completion evidence; destructive
  hardware validation completed on attempt 18, with the post-POR unlocked/blank
  state confirmed on attempt 2.
