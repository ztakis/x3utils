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
| 2026-07-31 | Windows 11 Greek / W11GR | ZT3 VCU test board | ST-LINK | A / Default SWD | Installed GUI v1.2.3 BETA4 — in-place upgrade, single-log RDP Check and destructive Rescue | pass | Installed `x3utils-setup-1.2.3.exe` over the previous per-user installation rather than uninstalling first. Inno's upgrade cleanup removed the legacy runtime `special\rdp\config.cmd`; the packaged `rescue.cfg` correctly remained, and neither subsequent GUI RDP action recreated `config.cmd`. Every new run produced one complete GUI log and no new `_toolkit` companion. The 13:27 Check recorded `ffff5aa5`, consistent FAP `0xA5`/comp `0x5A`, readable main flash and `NOT PROTECTED`, exit 0. Rescue at 13:33 passed `-Launcher`, `-Target target\at32f415xx.cfg`, timeout 3, `-NoToolkitLog` and `-Yes`; it halted the target, erased/reprogrammed the option area, read back `ffff5aa5`, reported `Rewrite sent`, and exited 0. After the required power-cycle, the 13:34 Check first hit `Error: open failed`; the GUI retry path then connected, recovered the same complete USD/main-flash evidence, reported `NOT PROTECTED`, and exited 0. This closes the BETA4 installed-upgrade, read-only-bundle, single-log Check and Rescue acceptance on Windows; the destructive result is confirmed by the separate post-rescue Check rather than Rescue's process exit alone. Evidence copies: `I:\SCOOTER\__bins4tests\W11GR\logs\rdp_check\rdp_check_2026-07-31_13-27-24.log`, `...\rdp_rescue\rdp_rescue_2026-07-31_13-33-34.log`, and `...\rdp_check\rdp_check_2026-07-31_13-34-10.log`. |
| 2026-07-31 | Windows 11 Greek / ACP 1253, Greek-script account name | ZT3 VCU test board (`SCOOTER_VCU_xxU2`, serial cleared) | ST-LINK | A / Default SWD | Installed GUI v1.2.3 BETA3 — ACP-safe paths and guarded action sweep | pass for ACP/path and flash behavior; RDP logging remains TBD | Maintainer handoff: ten saved logs plus two screenshots. This is the installed Inno package, not the dev tree: every OpenOCD command resolves the bundled backend through `%LOCALAPPDATA%\Programs\x3utils\native\windows\oocd\scripts`. Every hardware transcript records `BETA3 Windows path mode: ACP-safe · code page 1253`. Backup dumped and promoted 131072 B under the default x3utils root, with the second copy successfully written through the Greek-script profile to `%LOCALAPPDATA%\x3utils_backup`. Backup + Flash and Flash Only both accepted the rescue image from `%USERPROFILE%\Desktop`, erased, wrote and verified 131072 B, exit 0. SHU compatible dumped, promoted, patched, reflashed and verified 131072 B, exit 0. ZIP3 import decrypted a 58460 B ZT3/VCU payload under the default x3utils root; guarded slot 0 backed up first, matched ZT3 identity, wrote and verified the exact 58460 B payload. A second guarded slot-0 run from deeper under `%USERPROFILE%\Desktop` likewise backed up, matched identity and verified 58220 B, exit 0. The larger `wrote` figures on these two `write_image` runs are the existing flash-page rounding; `verified` carries the exact input size. Three refusal paths also behaved correctly: a GT3 slot bin against the ZT3 target stopped after its mandatory backup and before any write; the screenshot at 11:48 shows CP1253 refusing `ü` (`U+00FC`, character 51) in a `Prüfung` path; and the 11:49 screenshot shows Backup + Flash refusing a 58436 B slot bin because that action requires 131072 B. Check protection itself passed with complete evidence (`ffff5aa5`, FAP `0xA5`/comp `0x5A`, readable main flash, `NOT PROTECTED`, exit 0), but the maintainer explicitly does NOT accept the RDP logging behavior: GUI and CLI show the same logging issue on all three OSs, to be handled as a separate cross-platform task. |
| 2026-07-29 | macOS 15.7.7 / Intel x86_64 | ZT3 VCU test board (generic replacement, `SCOOTER_VCU_xxU2`) | ST-LINK | A / Default SWD | GUI v1.2.2 — x3utils root, RDP toolkit log, auto-retry and the Windows-scoped ASCII guard | pass | Closes the macOS half of the v1.2.2 handoff. Two rounds: the dev tree (`-s .../x3utils_flutter/native/macos/oocd/scripts`, 20:09–20:11) and then the PACKAGED universal app copied to `~/Desktop/x3utils.app` (20:15–20:17). Four actions — Check connection, Backup, guarded Flash slot 0, Check protection. ROOT: dumps staged as `.bin.part` and promoted, `~/x3utils/backup/dump_…20-10-15.bin` and `…20-16-34.bin` (131072 B each, 1.995 s), 2nd copies in `~/Library/Application Support/x3utils_backup`, logs under `~/x3utils/logs/{check,flash_slot0,rdp_check}`, and NOTHING newer than 19:00 under `~/Documents/x3utils` — the regression check. RDP LOG: the macOS-specific risk (config.sh written at the temp run root, scripts loading `../../config.sh`) did NOT bite — `X3UTILS_RDP_LOG_DIR` reached the script from the packaged bundle and both files landed in `~/x3utils/logs/rdp_check/`, `rdp_check_2026-07-29_20-15-55.log` (1603 B, UTF-8) and `rdp_check_toolkit_2026-07-29_20-15-55.log` (622 B, ASCII — the UTF-16LE is Windows-only, as Linux also found). Identical stamp, the fourth colliding pair in a row. Verdict `ffff5aa5`, FAP `0xA5`/comp `0x5A`, readable flash, NOT PROTECTED. AUTO-RETRY, first macOS hardware exercise: `Error: open failed` at 20:15:06, `auto-retry 1 of 10`, failed again at 20:15:09, `auto-retry 2 of 10`, then connected at 20:15:12 — recovered without a click, on the packaged app. The dev round retried once the same way (20:09:03 → 20:09:06). ASCII GUARD: guarded Flash slot 0 took `~/Desktop/bins4tests/gen_test_bins/Prüfung/16a_slot_zt3_vcu_SYNTHETIC.bin` through the real brace-quoted `write_image erase` AND `verify_image` command path — wrote 58436 B in 21.6 s, verified 58436 B, exit 0, both rounds. Identity gate passed on the way through (target `SCOOTER_VCU_xxU2`/zt3 vs `n/a (slot bin)`). Exec bits survived packaging: `rdp_check.sh`, `rescue_unlock.sh`, `rdp_lib.sh` and `oocd/bin/openocd` all `-rwxr-xr-x` in the bundle, and the packaged `rdp_check.sh` is byte-identical to the source tree. Every macOS log shows `[at32f4x.cpu] halted due to debug-request` and `flash 'artery' found` — never the literal `target halted`, never `at32f415xx` — which is the hardware proof behind the auto-retry gate widening. EXTENDED SWEEP the same evening (20:30–20:36, packaged app), which closes the action gap this row originally left open. Flash only, full scope, restored the board from `zt3_vcu_rescue.bin` — erased 131072 B in 0.748 s, wrote 131072 B in 47.365 s, verified in 3.303 s, exit 0. SHU compat created `~/x3utils/compat/` for the first time on macOS: dump staged and promoted to `compat_…20-32-10.bin`, signature patched at `0x1420` to `…_patched.bin`, reflashed and verified, exit 0 — and the optional auto-zip3 correctly REFUSED (`no trustworthy BLE firmware-length record`), the same guard that fired on Linux, which is part of the pass rather than a failure. Full Backup + Flash dumped, promoted, matched identity and reflashed the rescue image, exit 0. UMLAUT ROOT THROUGH SETTINGS, the destination half of the ASCII-guard bug that Linux only proved on the source side: Browse accepted `~/Desktop/bins4tests/gen_test_bins/Prüfung/x3utils` as the root, a Backup dumped and promoted into `Prüfung/x3utils/backup/`, and the log followed to `Prüfung/x3utils/logs/dump/` — while the 2nd copy still went to `~/Library/Application Support/x3utils_backup`, outside the custom root, which is the invariant. macOS stores that root NFD-normalised (`Pru\U0308fung`, `u` + U+0308, not the NFC `ü`), because the file picker returns decomposed paths; OpenOCD accepted those bytes. ZIP3 (20:43–20:44) closed the last subfolder and brought the sweep to TEN ACTIONS, matching Linux exactly — and across THREE different model/component combinations, all with `enforceModel=true`: Make zip3 from a full dump whose source identity read `SCOOTER_VCU_xxG3 (model g3)`, packed as g3/VCU, 60356 B payload; Make zip3 from a payload bin reading `SCOOTER_MCU_0001 · serial n/a (slot bin)`, packed as zt3/MCU, 59028 B, output named from the source file, hence its 2026-07-19 stamp; and Unpack zip3, which inspected `zt3_VCU_2026-07-21_23-47-01 · zt3/VCU · 58460 bytes` before writing — the same figure the Linux row recorded. So model/component preselection from source identity was exercised on three combos, not just repeated on one. The g3 source reported a non-generic serial, not reproduced here — full serials do not go in these public files, and a non-generic one is in any case not evidence that the device is real. Re-running the zt3/MCU pack at 20:52 onto its own output fired the existing-file collision dialog, which named the exact path and warned that Replace permanently overwrites; Cancel was taken and the existing package was verified untouched — same 59484 B, same 20:44:22 mtime — with the console logging `make zip3 cancelled: existing package kept`. Note unpack logs into `logs/make_zip3/` along with the other two; the three-way slice/pack/unpack split shares one log folder, so someone hunting for unpack logs will not find a folder by that name. SETTINGS ROW now fully exercised, which had been carried past three sweeps on every platform: Browse (the umlaut root above), Reveal, and Reset — and Reset REMOVES the `flutter.x3utilsRoot` key outright rather than writing the default path, which is the "blank restores the per-OS default" behavior `x3utils_root_test.dart` pins, and means a future default change would follow the user. The brace refusal was confirmed live on the Flash Only screen — `Path contains an unsupported character: { or }.` with the file rejected and the field left at "No firmware chosen". Taken with the accepted `Prüfung` root, that demonstrates ON THE RUNNING macOS APP the thing the unit tests pin and a later cleanup would re-merge: the two halves of `validateOpenOcdPath` are separately scoped — non-ASCII accepted off Windows, braces refused everywhere. Final state: all five root subfolders created, no `.bin.part` orphans anywhere, nothing under `~/Documents/x3utils` newer than 19:00. TESTBED IDENTITY CHANGED during this run — the rescue image cleared the serial, so the board reads `SCOOTER_VCU_xxU2 · serial: cleared` instead of its previous generic-replacement serial (model zt3), and later identity-gate tests compare cleared against cleared. NO ROW ON FILE for these, which is not the same as untested — the maintainer reports having exercised `Keep it` and a restore from `.bin` previously: the `Keep it` modal branch, the pre-flash-backup abort, the all-`0xFF` blank verdict, and the red refusal line in Settings. Gatekeeper/quarantine is the one genuinely established as unobserved, because the testbed has assessments disabled — see the note below the table. The slot 0 fixture is a synthetic unbootable payload, which is why the sweep began with a restore. |
| 2026-07-29 | Linux Mint home primary / x86_64 | ZT3 VCU test board | ST-LINK | A / Default SWD | GUI v1.2.2 rebuilt AppImage — non-ASCII path guard scoped to Windows | pass | Guarded Flash slot 0 from `~/Desktop/bins4tests/gen_test_bins/Prüfung/16a_slot_zt3_vcu_SYNTHETIC.bin`, the behaviour-pinning umlaut-directory fixture, which the pre-scoping build refused at selection. It was accepted, identity read as ZT3 · VCU, and OpenOCD then received the umlaut path inside the brace-quoted `flash write_image erase … 0x08001000 bin` AND `verify_image` commands and handled both — wrote 59392 B (2 KB page rounding of the 58436 B file), verified 58436 B, exit 0. Stronger than the offline probe recorded under Non-Hardware Port Checks: that one proved a jimtcl `open`, this is the real command path on hardware through write and verify. The guards on the way through behaved: pre-flash backup and 2nd copy taken first, and the identity gate passed on matching `SCOOTER_VCU_xxU2` banners. Incidental — the first Check connection hit `Error: open failed` and `auto-retry 1 of 10` recovered it, the usual hand-held SWD contact. The synthetic payload is unbootable by design, so the board was left needing a reflash from `zt3_vcu_rescue.bin`. |
| 2026-07-29 | Linux Mint home primary / x86_64 | ZT3 VCU test board | ST-LINK | A / Default SWD | GUI v1.2.2 packaged AppImage — x3utils root + RDP toolkit log, full action sweep | pass | Run from `dist/x3utils-1.2.2-x86_64.AppImage`, so the bundle was the read-only squashfs mount (`/tmp/.mount_x3utilEbvxJV`), not the dev tree. Exec bits survived packaging — `special/rdp/rdp_check.sh`, `rescue_unlock.sh` and `oocd/bin/openocd` were all `-rwxr-xr-x` inside the mount, so the standing bundle gotcha did not bite. Ten actions wrote under `~/x3utils` into all five expected subfolders: Check connection, Backup, SHU compat, Backup + Flash, guarded Flash slot 0, Flash only, Check protection, Make zip3 from a full dump and from a payload bin, and Unpack zip3. 2nd copies for all four dumps went to `~/.x3utils_backup`, outside the root. No `~/Documents/x3utils` was created at any point, which is the regression check. RDP log: `X3UTILS_RDP_LOG_DIR` reached the script even from the read-only mount, via the runner's temp-copy `config.sh`, and the script's own `Log file:`/`Full log:` lines named the root — both files landed in `~/x3utils/logs/rdp_check/`, `rdp_check_2026-07-29_18-29-33.log` (1548 B, UTF-8) and `rdp_check_toolkit_2026-07-29_18-29-33.log` (592 B, ASCII on Linux, not the UTF-16LE of the Windows pair). Identical stamp, the third pair in a row to collide on the second. Two guards fired correctly and are part of the pass: compat's auto-zip3 refused for want of a trustworthy BLE firmware-length record, and guarded slot 0 refused a GT3 payload against a ZT3 target. Closes the Linux half of the v1.2.2 handoff; macOS is the only platform still owed. |
| 2026-07-29 | Windows home primary | ZT3 VCU test board | ST-LINK | A / Default SWD | GUI v1.2.2 packaged installer — root folder + RDP toolkit log | pass | `flutter build windows --release` then Inno Setup 6.7.1 produced `x3utils-setup-1.2.2.exe`; the compile listing confirms the edited `native\windows\special\rdp\rdp.ps1` was packaged and that the gitignored runtime `config.cmd` was excluded. On the per-user install (`%LOCALAPPDATA%\Programs\x3utils`, no UAC): the installed `rdp.ps1` carries the `_toolkit` change, `config.cmd` was absent until the first run, and Check protection from the installed app wrote BOTH logs into `C:\x3utils\logs\rdp_check` (`rdp_check_2026-07-29_17-56-25.log` + `rdp_check_toolkit_2026-07-29_17-56-24.log` — one second apart, so the folder now shows why the suffix is needed). Nothing newer than the pre-fix `17-10-25` file appeared under `Documents\x3utils`, which is the regression check. This supersedes the offline-only status of the Windows half of the RDP log fix; Linux and macOS are still owed. |
| 2026-07-29 | Windows home primary | ZT3 VCU test board | ST-LINK | A / Default SWD | GUI v1.2.2 x3utils root folder, full action sweep | pass with one defect found and fixed | Check connection, Backup, SHU compat (auto-zip3 refused on the first run for lack of trustworthy ZP, then produced the package on the second after a BLE-derived slot 0 was in place), Backup + Flash, guarded Flash slot 0 from a zip3 import, Check protection, and Make zip3 all wrote under `C:\x3utils` in the five expected subfolders; 2nd copies went to `%LOCALAPPDATA%\x3utils_backup`. Explorer showed exactly `backup, compat, logs, packed_zip3, unpacked_zip3`. Defect: Check protection also wrote the RDP toolkit's own transcript to `Documents\x3utils\logs\rdp_check\`, with the SAME basename as the console log (`rdp_check_2026-07-29_17-10-25.log`, identical second). Fixed the same session via `X3UTILS_RDP_LOG_DIR` plus a `_toolkit` filename suffix in the bundled scripts; the Windows fix is offline-verified only, so this row does not cover the fixed behavior on hardware. |
| 2026-07-29 | Linux Mint home primary / x86_64 | AT32F415 X3 testbed, empty flash | ST-LINK | A / Default SWD | Flutter v1.2.1 invalid-backup handling (Backup) + restore from `.bin` | pass | The board read back all zeros, so Backup took the evidence path rather than the short-read one: staged `.bin.part`, no `.bin` created, and the trash move worked. Maintainer reported no behavioral difference from the Windows runs below. Per-run figures were not captured. First real exercise of the freedesktop trash path (`~/.local/share/Trash` `files/` + `info/*.trashinfo`). The board was then restored from a `.bin` on this machine and passed. FAP was reported not enabled, so the all-zero read here was an empty chip rather than a masked one — the verdict keys on the byte pattern, not on the chip's protection state. |
| 2026-07-29 | macOS | AT32F415 X3 testbed, empty flash | ST-LINK | A / Default SWD | Flutter v1.2.1 invalid-backup handling (Backup) | pass | Same all-zero read and same behavior as the Linux row above, with no difference from the Windows runs. Per-run figures were not captured. First real exercise of the `~/.Trash` move. |
| 2026-07-29 | Windows home primary | AT32F415 X3 testbed, deliberately FAP'd via CLI `rdp.ps1 -Enable` | ST-LINK | A / Default SWD | Flutter v1.2.1 masked-read evidence path (Backup) | pass | The dump completed normally — 131072 bytes in 1.97 s, exit 0, `xPSR/pc/msp` all zero — and inspection returned the masked verdict. No `.bin` was created; the file stayed `.bin.part`. The screen named the readout-protection signature and pointed at Check protection, the console logged `chip finding, file left at →`, and the single button read `Dismiss` rather than "Back to setup". The cleanup modal used the finding title, and `Move to Recycle Bin` moved it and showed the note. Still to cover: `Keep it`, the pre-flash-backup abort, the all-0xFF blank verdict after a rescue erase, and the Linux/macOS trash moves. |
| 2026-07-29 | Windows home primary | AT32F415 X3 testbed | ST-LINK | A / Default SWD | Flutter v1.2.1 invalid-backup handling (Backup) | pass | Contact pulled mid-dump after `target halted`. OpenOCD exited 1 with 28672 of 131072 bytes read. The file stayed `dump_2026-07-29_00-41-51.bin.part`; no `.bin` was created. The cleanup modal stated the shortfall and the identity-in-the-last-4-KB reason, `Move to Recycle Bin` removed it from the backup folder, and the failure screen showed the note. Console recorded `incomplete read left at` then the move. Still to cover on hardware: `Keep it`, the pre-flash-backup abort, a read-protected board's all-zero evidence path, and the Linux/macOS trash moves. |
| 2026-07-26 | Linux Mint home primary / x86_64 | No target | disconnected | selected GUI mode | Flutter v1.2.1 debug RDP retry failure flow | pass | Maintainer checked the corrected debug build and reported the issue fixed. This validates the live disconnected-adapter failure presentation in the debug build; no protection rewrite reached hardware. The generated AppImage contains the same corrected scripts but was not used for this check. |
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
- Confirm output file exists in `<x3utils folder>/backup`.
- Confirm secondary backup exists if that option is enabled.
- Confirm validator accepts the dumped file.
- Confirm no `.bin.part` file is left behind after a successful dump.
- Note whether read protection or connection timing affected the run.

## Invalid Backup Test

Pull the SWD contact mid-dump, after `target halted`, to produce a short read.
Repeat for Backup and for Backup + Flash.

- Confirm `<x3utils folder>/backup` gets a `.bin.part` file and no new `.bin`.
- Confirm the failure screen names the shortfall (`n of 131072 bytes`).
- Confirm the cleanup modal appears, and that `Keep it` leaves the file exactly
  where it is.
- Confirm `Move to Recycle Bin` / `Move to Trash` removes it from `backup/` and
  that it is recoverable from the OS trash.
- Confirm Backup + Flash aborted before any erase or write.
- On a read-protected board, confirm the full-size all-zero read gets the
  finding wording ("This read is a finding, not a backup"), points at Check
  protection, and offers `Dismiss` rather than "Back to setup".
- Right after a rescue mass erase, before reflashing, confirm the all-`0xFF`
  blank verdict behaves the same way.

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

## x3utils Folder Test

No hardware needed; Settings plus one Backup run.

- Confirm a fresh install shows the per-OS default (`C:\x3utils`, `~/x3utils`)
  with the "default location" hint, and that creating it needs no elevation.
- Run one Backup and confirm `backup/` appears under the shown folder, and that
  Save log puts the log under `logs/` in the same tree.
- Confirm `Browse…` to a writable folder switches the path and that a later run
  writes there; confirm `Reset` returns to the default.
- Confirm nothing was moved: the previous tree still holds its old files.
- Confirm a folder the app cannot write to, or one with `{`/`}` (and non-ASCII
  on Windows), is refused in Settings with the reason shown and the setting
  unchanged.
- Confirm the reveal action opens the folder once it exists.
- Confirm the 2nd copy still goes to its own hidden location outside the root.
- On Windows, run Check protection with Save log enabled and confirm the one
  complete console log lands at `<root>/logs/rdp_check/rdp_check_<stamp>.log`.
  No `rdp_check_toolkit_*` or runtime `config.cmd` may appear. Linux/macOS still
  use their existing paired console/toolkit logs. Nothing may appear under
  `Documents/x3utils` on any platform.

## Non-Hardware Port Checks

| Date | OS | Scope | Result | Notes |
| --- | --- | --- | --- | --- |
| 2026-07-31 | Windows 11 | Flutter v1.2.3 BETA4 Windows RDP direct-parameter and single-log handoff | pass (non-hardware build/package) | `RdpRunner` now passes `-Launcher`, target, timeout, log directory, optional race, GUI `-NoToolkitLog`, and Rescue `-Yes` directly to the bundled PowerShell script; it never creates or mutates `config.cmd`. The Windows-only runner fixture covered A/B/C/D plus Rescue and pinned a contradictory stale config's bytes and timestamp. A second test ran the real bundled `rdp.ps1` against a copied non-hardware system executable: GUI mode created no toolkit directory and printed no `Log file`/`Full log`, while hand-run mode created exactly one non-empty `rdp_check_toolkit_*` file. Version state is `1.2.3+10 BETA4`; the BETA3-only path bypass is retired and its old preference is ignored. The focused RDP file passed 5/5, the focused root/version-gate file passed 20/20, and the final full Flutter suite passed 197/197; PowerShell parsed cleanly, `flutter analyze` and `git diff --check` passed. `flutter build windows --release` succeeded. Inno Setup 6.7.1 compiled `x3utils-setup-1.2.3.exe`, explicitly included the updated `rdp.ps1`, parsed both exact-delete sections, and did not package the ignored source `config.cmd`. The installed upgrade and real Check/Rescue behavior subsequently passed on W11GR; that stronger evidence is recorded in the hardware table above. |
| 2026-07-29 | macOS 15.7.7 / Intel x86_64 | Non-ASCII path probe against the bundled xPack OpenOCD | pass | The macOS half of the probe the Linux row below asked for, so the `Platform.isWindows` gate now rests on measurement here too rather than on the POSIX-argv reasoning alone. Same shape as the Linux probe, no hardware: `-f <dir>/probe.cfg` (read) and a brace-quoted jimtcl `open`/`puts`/`close` (write), through `Prüfung/` (German umlaut), `Δοκιμή/` (Greek), `MEMORY_G3_С45/` (the founding U+0421 Cyrillic homoglyph) and `zip⚡3/` (emoji), plus an ASCII control. Run twice — against `native/macos/oocd/bin/openocd` and against the packaged app's own copy, which is a separate re-signed file. ALL TEN CHECKS PASSED each time. Superseded on the same evening by the stronger hardware evidence in the macOS row of the hardware table, where the `Prüfung/` path went through the real `write_image erase` / `verify_image` commands; the probe is kept because it covers the read path and the emoji/Greek/Cyrillic shapes the hardware run did not. `flutter analyze` clean and 177/177 tests pass on this machine, matching the Linux and Windows counts. |
| 2026-07-29 | Linux Mint home primary / x86_64 | Non-ASCII path guard scoped to Windows, with the OpenOCD probe behind it | pass | The probe the DEVLOG asked for, so Linux is now BINARY-proven rather than layer-proven. Bundled `native/linux/oocd/bin/openocd`, no hardware: `-f <dir>/probe.cfg` (read) and a jimtcl `open`/`puts`/`close` (write), each through four directory names — `Prüfung/` (German umlaut), `Δοκιμή/` (Greek), `MEMORY_G3_С45/` (the founding U+0421 Cyrillic homoglyph) and `zip⚡3/` (emoji). All eight succeeded, so the guard was refusing paths its own binary opens correctly. `Firmware.validateOpenOcdPath` now gates the non-ASCII half on `Platform.isWindows`; braces stay unconditional. Windows behaviour is byte-identical including the message, so the Windows sweep and installer of the same day stay valid. Off Windows this was a dead end, not a nuisance: a `/home/Jörg` user was refused every dump because the default `~/x3utils` root carries the username, was told to pick another folder, and then had every folder they own refused too — plus firmware selection from their own home. `tool/gen_test_bins.dart`'s `Prüfung/` verdict scoped to Windows in the same change. 177 tests pass (was 174), `flutter analyze` clean. Hardware-confirmed the same evening on the rebuilt AppImage — see the Flash slot 0 row in the hardware table, where the umlaut path went through `write_image` and `verify_image` for real. macOS still rests on the POSIX-argv reasoning — run the same probe against the xPack build during its pass. |
| 2026-07-29 | Windows home primary | RDP toolkit log follows the x3utils root | pass (offline) | `rdp.ps1` parses clean; its real `Get-RdpConfig` and `New-LogPath` were AST-extracted from the shipped bundled file and run: the backslash path parses out of config.cmd, a supplied dir is created and yields `rdp_check_toolkit_<stamp>.log`, and an absent one still falls back to the old Documents path for a hand-run outside the GUI. `bash -n` clean on both unix `rdp_check.sh` copies; their runtime path is NOT covered, because `rdp_runner_test.dart` no-ops on Windows — one Check protection run each is still owed on Linux and macOS. Full suite 174/174 and `flutter analyze` clean. Only files under `x3utils_flutter/native/` changed; the standalone CLIs were not touched. |
| 2026-07-29 | Windows home primary | Flutter x3utils root folder (replaces the Backup folder setting) | pass | Offline only. `flutter analyze` clean and the full suite passed 174/174, including the new `test/x3utils_root_test.dart` (all five outputs follow the root under fixed names, 2nd copy outside it, blank restores the per-OS default, labels create nothing, a stored `backupFolder` is not adopted). Incidental confirmation of the Windows default's ACLs: the test run created `C:\x3utils\unpacked_zip3` from a non-elevated process with no UAC prompt. Not covered by tests and still owed on the running app: the Browse/Reset row, the red refusal line for an unwritable or brace-bearing pick, and Reveal. No hardware command ran. |
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

### macOS Gatekeeper / first-launch note — UNTESTED, and untestable on the
### current testbed

- The macOS app is AD-HOC signed and not notarized: `codesign -dv` reports
  `Signature=adhoc`, `TeamIdentifier=not set`, and `tool/package_macos.sh` runs
  `codesign --force --deep --sign -` with no notarization or stapling step.
- Every macOS run recorded above bypassed Gatekeeper without anyone intending
  to. The maintainer's Mac reports `spctl --status` = **assessments disabled**,
  and the tested `~/Desktop/x3utils.app` carried no `com.apple.quarantine`
  attribute because the zip was produced and unzipped locally. `spctl -a -vv`
  returns `accepted (override=security disabled)` — the override, not a real
  verdict.
- So no hardware row on this page says anything about what a user sees on first
  launch, and none can be made to while assessments are disabled.
- The 2026-07-01 DEVLOG entry judging unsigned distribution viable because "the
  only friction is the Gatekeeper open anyway step" was formed on this same
  machine and inherits the same blind spot. It is not a measurement.
- To actually test: `sudo spctl --master-enable`, then move the zip onto the
  machine the way a user would — browser download or AirDrop, NOT a local unzip
  — so it carries the quarantine attribute, and open it. Confirm with
  `xattr -l` that the quarantine flag is present before drawing any conclusion.
- Expected to be worse than the old note assumes: this testbed is macOS 15.7.7,
  and macOS 15 removed the Control-click → Open bypass for un-notarized apps,
  leaving System Settings → Privacy & Security → "Open Anyway". Verify on the
  machine rather than trusting this line.

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
