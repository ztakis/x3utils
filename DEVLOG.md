# DEVLOG

Short development notes for decisions, test results, and context that should
survive machine switches and chat history loss.

## 2026-07-01

- Added root `AGENTS.md` guidance in the `_Codex` reference folder for
  repo-wide agent behavior.
- Decided `AGENTS.md` should live at the repo root for automatic discovery.
- Noted that the C45 Tcl configs are the key hardware-control layer.
- Decided shared GUI/orchestration code should preserve Tcl/OpenOCD as the
  hardware-control layer rather than reimplementing target, reset, halt, and
  flash semantics.
- Added durable planning notes for hardware testing continuity.

## 2026-07-02

- Used local `docs/wiki` drafts to bootstrap the GitHub wiki.
- Current wiki source of truth is the GitHub wiki repository, not old local
  `docs/wiki` drafts.

## 2026-07-13

- Flutter GUI is now the active Windows path.
- Python refactor planning is obsolete; do not revive it as the default
  direction.
- Workstation context:
  - Home primary has Windows, Linux Mint, and Mac.
  - Work secondary has Windows, Linux Mint, and Mac.
  - Helper laptop dual-boots Windows/Linux.
  - Current machine is the home primary Linux Mint PC and is the intended first
    `x3utils_flutter` AppImage build box unless this changes.
  - Work Linux Mint reportedly received similar Flutter/dev prep, a build, and
    local VS Code debug setup earlier on 2026-07-13 in another Codex session;
    recheck exact state before treating it as a release machine.
- Development sync policy:
  - `.vscode/` is intentionally local/ignored because Windows, Linux, and macOS
    workstation settings differ.
  - Keep cross-machine and AI handoff state in tracked docs such as
    `DEVLOG.md`, `docs/testing.md`, and `AGENTS.md`.
- CLI/GUI direction:
  - CLI target is v1.7.0 for Windows, Linux, and macOS.
  - CLI should keep the existing A/B/C/D order, with Windows mode D
    Power-race behavior ported to Bash for Linux/macOS.
  - After v1.7.0, CLI is expected to become mostly stable maintenance/helper
    tooling and a behavior reference for the GUI.
  - Port order: finish Bash CLI mode D parity first, solve Bash RDP race
    behavior next, then port the settled behavior into Flutter.
  - Flutter GUI is allowed to diverge from CLI labels/order; it may abandon
    ABCD labels in favor of human connection-mode names. Do not force the GUI
    back to CLI taxonomy merely for parity.
- Linux CLI v1.7.0 first-draft port started from Windows CLI v1.7.0:
  - Added launcher/config mode D (`RACE=true`) Power-race plumbing.
  - Added Linux `at32f415xx_race.cfg` and `race_grade.sh`.
  - Ported mode D race branches for dump, flash, SHU compat, flash-only, slot0,
    and read-only RDP Check.
  - Dry checks passed: `bash -n x3utils_linux/*.sh`,
    `bash -n x3utils_linux/special/*.sh`,
    `bash -n x3utils_linux/special/rdp/*.sh`, and `git diff --check`.
  - Hardware validation on home primary Linux Mint:
    - Mode A full flash with forced backup passed using `zt3_vcu_rescue.bin`.
    - Mode D dump passed; caught on attempt 175 and validated 131072 bytes.
    - Mode D SHU-compatible flow passed; dump caught on attempt 154, host patch
      validated, flash caught on attempt 1 and verified.
    - Mode D normal flash passed; backup caught on attempt 110, flash caught on
      attempt 1 and verified.
    - Mode D `special/rdp/rdp_check.sh -l` passed; caught on attempt 115 and
      reported NOT PROTECTED with FAP=0xA5 / FAP_COMP=0x5A.
    - Mode D `special/flash_only.sh` passed with `zt3_vcu_rescue.bin`; one run
      also confirmed adapter-missing recovery by printing `x` symbols until the
      ST-LINK was available, then erased/wrote/verified successfully.
    - Mode D `special/flash_slot0.sh` passed with `gt3_vcu_v1.7.0.bin`; backup
      caught on attempt 124, slot0 flash caught on attempt 1, wrote 61440 bytes
      and verified 60868 bytes. This wrote/verified byte-count difference is
      also seen cross-platform and is treated as acceptable when OpenOCD exits
      successfully with `verified`.
  - Firmware-slot context: these controllers keep firmware in slot0/slot1; OTA
    writes slot1 then promotes/copies to slot0. `flash_slot0` writes only the
    slot0 firmware area at 0x08001000 and intentionally preserves user/identity
    data after slot1.
  - GUI lesson from CLI race testing: after a race catch, erase/write/verify can
    happen quickly and quietly. The CLI is correct but stressful; the Flutter GUI
    should show a clear post-catch state such as "CAUGHT - hold power", then live
    Erasing/Writing/Verifying progress with a "do not disconnect" cue.
  - Destructive RDP testbed validation then passed in launcher mode D:
    - `special/rdp/fap_enable.sh -l -y` programmed FAP=0x00 after one missed
      race attempt and one manual retry.
    - `special/rdp/rdp_check.sh -l` then reported READ PROTECTED.
    - `special/rdp/fap_clear.sh -l -y` restored FAP=0xA5 after a retry; after
      power-cycle, `rdp_check.sh -l` reported NOT PROTECTED with blank flash.
    - `special/rdp/rescue_unlock.sh -l -y` also restored FAP=0xA5 after one
      missed race attempt and one retry; after power-cycle, `rdp_check.sh -l`
      reported NOT PROTECTED with blank flash.
  - Fixed the `rescue_unlock.sh -l` plain-mode warning guard so launcher mode D
    no longer prints the misleading "Launcher mode is A (plain)" warning.
  - Hardware observation: `rdp_check.sh -l` may sometimes read option-byte state
    with only SWDIO/SWCLK/GND connected, likely due to residual or SWD-provided
    power. Treat this as an observed testbed quirk, not supported wiring; dump,
    flash, FAP writes, and rescue still require clean target power.
- Power-race result handling was improved before this handoff:
  - OpenOCD output evidence is collected in `openocd_runner.dart`.
  - Flash success requires `wrote` plus `verified`.
  - Dump success requires `dumped`.
  - The race watchdog avoids stale timeout lines after success.
- Next Flutter task: make the real OpenOCD progress checklist generic across
  modes.
  - Rename/generalize `_advanceRaceStage(line)` to something like
    `_advanceOpenOcdStage(line)`.
  - Call it from `_onRealLine()` so all real OpenOCD modes share evidence-driven
    progress.
  - Preserve guided C45 hold/count/release prompt parsing.
  - Map `target halted` / race catch to `Connect`.
  - Map `flash 'at32f415xx' found` to `Probe` / `Probe flash`.
  - Map `dumped` to `Read`, `erased` to `Erase`, `wrote` to `Write`, and
    `verified` to `Verify`.
  - Manually mark app-side stages such as dump validation, compat patch success,
    and forced backup validation where useful.
  - Keep verdicts stricter than progress UI; do not green-light without the
    required evidence.
- Flutter Linux RDP parity pass:
  - Followed the Windows GUI RDP model: Dart writes `RACE=true` for shell RDP
    config when Power-race is selected, Linux `rdp_lib.sh` resolves that as
    launcher D, and Linux `rdp_check.sh` auto-hammers only the read-only check.
  - Rescue/option-byte rewrite remains on the safer manual retry loop, matching
    Windows GUI behavior.
  - The Linux Flutter RDP console labels are intentionally GUI-neutral mode
    names (`Power-race`, `C45 genuine`, etc.), not CLI launcher letters. GUI
    visible labels remain C=Power-race and D=C45 genuine.

## 2026-07-14

- Flutter GUI checklist/progress planning:
  - Current checklist progress is useful but too tied to display labels and
    specific modes. Avoid making English stage labels the logic keys.
  - Keep OpenOCD/Tcl/script output as the source of truth. Parse many low-level
    signals, but show only a few readable user-facing facts.
  - Prefer a simpler checklist with macro phases such as Backup, Flash, and
    Verify. Use the mini status line for intermediate confirmed facts such as
    "Backup in progress", "Backup completed", "Backup verified", "Writing
    firmware", and "Firmware verified".
  - Delays should be presentation-only, never slowing OpenOCD or hardware
    operations. The UI may queue already-confirmed facts and display them at a
    readable pace before the final Done/Failed screen.
  - Preserve full raw OpenOCD output in the console for debugging.
  - Final verdicts should be short and evidence-based, for example:
    "Backup is safe. Flash failed before verification. Retry flashing.",
    "Write started, but verification did not complete. Retry required.", or
    "Backup validation failed. Flash was not attempted."
  - Future skeleton should separate action plan, connection strategy, evidence
    parser, progress presenter, and final verdict.
  - C45 guided prompts and Power-race attempts should drive the hero/operator
    state, but once the chip is connected the checklist should be driven by the
    same typed progress events as other real OpenOCD modes.
  - Add typed progress IDs/events later so parser code marks facts such as
    connect, detect flash, read flash, validate backup, erase, write, and verify
    without searching display text.
  - Add a non-race OpenOCD supervisor/timeout later. Distinguish explicit Tcl
    `shutdown error` failures from runner timeouts/hangs so the GUI can give a
    short retry verdict without over-explaining.
- Flutter GUI progress UI decision:
  - Removed checklist rows from the active hero flow for all actions and modes.
  - Real OpenOCD/Tcl output remains visible in the console and still drives final
    success/failure evidence, but the hero now uses a single busy spinner plus
    concise operator text instead of pretending to have precise per-step
    checklist timing.
  - Deferred accurate typed progress/checklists to a later version that can
    coordinate with Tcl/OpenOCD events cleanly.
  - Kept guided C45 hold/count/release hero prompts as the special live operator
    flow.
  - Kept presentation delays only around the busy/result transition; they do not
    slow OpenOCD or hardware operations.
  - Mode A and Mode B were manually passed across the main actions after the
    spinner cleanup.
  - RDP/protection actions are now treated as best-effort tools. Power-race mode
    shows a Not supported warning instead of launching RDP, because protection
    checks/rescue need a stable OpenOCD session.
  - SHU compatibility patch messaging was simplified to neutral operator text:
    "SHU patch applied. Flashing it back to the chip..."

## 2026-07-15

- Prepped GUI release v1.1.2 (`app_controller.dart`, Linux runner window setup,
  macOS main menu).
- Generated macOS app icons from the shared `x3utils_flutter/icon.png` via
  `tool/gen_icon.dart`, which also refreshes the Windows `app_icon.ico`. Use that
  tool rather than hand-editing per-platform icon assets.

## 2026-07-16

- Flutter GUI v1.1.3: fail closed when the OpenOCD backend is missing.
  - Origin: a Discord user cloned the repo, added Android tooling, and built a
    phone proof-of-concept with no bundled OpenOCD. v1.1.2 fell back to Linux
    paths on Android, failed to find OpenOCD, then ran in simulation and
    reported green `target halted`, `== Check connection OK ==`, and
    `== SHU compatible OK ==` with no hardware attached at all. Screenshot
    confirmed. That is why v1.1.3 fails closed: a UI port to an unbundled
    platform must never be able to produce success evidence.
  - Note the console did label those runs `(simulated)` and still showed green
    verdicts. Labelling is not a sufficient safeguard; the verdict path is.
  - Removed the prototype simulation fallback from `app_controller.dart`.
    Previously, a missing OpenOCD made the app run as a demo dry-run and emit
    fake `target halted` / PASS / OK output. That could produce a green verdict
    with no hardware evidence, which violates the evidence-based verdict rule.
  - Actions now fail with an OpenOCD missing / cannot-run message when no runner
    exists. Unknown action ids fail instead of being simulated. Unsupported
    platforms are explicit instead of silently falling back to Linux paths.
  - Verified with `flutter analyze` and an installed-package smoke test that
    renamed the bundled Windows OpenOCD folder.
  - Bumped package, app, and installer to 1.1.3.
  - Scope call: this is a hotfix and it is enough. The shipped GUIs bundle their
    own OpenOCD, so the backend is found beside the exe and someone has to
    actively mess with the bundle (or port to an unbundled platform) to hit this
    at all. Do not build more machinery around it now.
  - Possible later cleanup, not queued work: `OpenOcdPaths.find()` only checks
    that the binary and scripts dir exist, never that the binary runs, and the
    resulting `openOcdStatus` is consumed only as an LED colour in `main.dart`
    while the full action UI boots regardless. A future maturity pass could
    probe the backend at startup (executable, `--version` sane) and gate the
    action surface instead of failing at press time. Revisit when the app is
    more settled.
  - Demo mode was considered and rejected. A simulated run is a convenience,
    but its worst case is a user believing a controller was flashed when nothing
    was connected. If UI-only iteration is ever needed, do it as a compile-time
    dev harness excluded from release builds, never a runtime mode a user can
    reach.
- Progress UI is now settled; this closes the 2026-07-14 deferral.
  - The progress checklist is dropped as a direction, not merely postponed. The
    active flow is a single busy spinner plus hero eyebrow text.
  - `_advanceRaceStage` was renamed to `_advanceOpenOcdStage` and is still called
    from the real-line handler for all real OpenOCD modes, but it no longer
    behaves as a stage parser. Every marker (`target halted`, `dumped`, `erased`,
    `wrote`, `verified`) hits one branch that flips the UI into the run state on
    the first hit and refreshes `_lastProgressAt` for the race watchdog. Later
    markers change nothing on screen. It is a liveness detector now.
  - Hero eyebrow text is per-action, not per-stage: `_runEyebrow()` switches on
    the action id (`Backing up`, `Flashing`, ...), plus a few explicit
    `_showOpenOcdProgress(eyebrow: ...)` calls in the orchestration.
  - So there is no per-step progress left in the app. The typed progress
    IDs/events idea from 2026-07-14 is not on the roadmap; building it would be
    new work, not resuming half-done work. Revisit only if a concrete need
    appears.
  - Presentation delays after real testing, all presentation-only and never in
    front of an OpenOCD call: `_minBusyVisible` 1000 ms, `_minAfterLastProgress`
    2500 ms, combined with max rather than sum (worst case 2500 ms, not 3500),
    and a 900 ms readable pause after the SHU patch message.
  - Guiding principle from this pass: pacing the display of an already-confirmed
    fact is presentation and is fine; showing a fact that real output has not
    confirmed is faking and is not. The v1.1.3 fail-closed work and these delays
    are two sides of that same rule.
  - `AGENTS.md` was updated to match, since it still described the checklist as
    current intended work and would have sent a fresh agent to rebuild the UI
    that was just deliberately removed.
- macOS status.
  - Flutter macOS GUI: an unsigned build was tested. The only friction is the
    Gatekeeper "open anyway" step. Earlier signing/notarization estimates were
    too pessimistic; unsigned distribution looks viable. Still TBD, not
    committed.
  - macOS CLI v1.7.0 Power-race port is implemented in-tree, following the
    settled Linux v1.7.0 behavior while preserving macOS system Bash 3.2,
    architecture-aware xPack paths, `stat -f`, Application Support backups, and
    the upstream OpenOCD `artery` flash-driver name.
  - Added launcher mode D, `RACE` / optional `RACE_DEBUG`, shared race grading,
    race branches for dump/full flash/SHU compat/flash-only/slot0, and
    launcher-D support for the RDP writers/rescue tools. The read-only macOS
    RDP check remains guided-only.
  - Added identical `target/artery/at32f4x_race.cfg` files to both arm64 and x64
    bundled xPack script trees.
  - First real macOS mode-D dump passed on Intel: caught on attempt 75,
    validated 131072 bytes, and created both backup copies.
  - Additional dump tests completed successfully on attempts 312 and 110.
    During a temporary live-catch experiment, SWD also halted on attempts 31,
    6, and 105 without the dump completing.
  - Electrical conclusion: with only SWDIO/SWCLK/GND connected, touching or
    loosely connecting the 3V3 Dupont lead can parasitically power the target
    through the probe/user enough to halt, and sometimes enough to dump.
    Software cannot prove stable intentional 3V3 from an SWD halt.
  - Reverted the temporary Tcl live-catch marker and shell monitor. Mode D stays
    aligned with Windows/Linux as a best-effort respawn strategy: live grade
    symbols while searching, operator warning before the run, and CAUGHT/OK only
    after the complete OpenOCD action succeeds. A failed flash remains
    recoverable by reflashing.
  - macOS `rdp_check.sh -l` was tested at `-d0` and `-d2`. Stock xPack OpenOCD
    completed repeated reads of both `0x1FFFF800` and `0x08000000` but did not
    provide the Linux loop's reliable `target halted` catch signal.
  - Disabled `-l` / `--launcher` for the macOS read-only RDP check instead of
    adding a platform-specific verdict heuristic. Run it without `-l` to use
    the existing guided rescue connection. RDP writer/rescue launcher paths
    remain unchanged.
  - Dry verification passed on macOS Intel: all scripts passed system
    `/bin/bash` 3.2 syntax, `git diff --check` passed, mode persistence and race
    classification checks passed, and bundled x64 OpenOCD parsed the race
    config then shut down without `init`.
  - Real hardware validation remains outstanding before treating macOS CLI
    v1.7.0 as released.
- Sequencing decision for the next stretch of work:
  1. Hardware-validate the macOS CLI v1.7.0 mode D port.
  2. Then add mode D / Power-race to the Flutter GUI.
  3. Then cut a GUI release at whatever v1.1.x it lands on.
  - Superseded later on 2026-07-16: Flutter Power-race connection and macOS
    packaging are now implemented and tested; GUI Power-race write flows still
    need separate hardware coverage.
- Release status (a version bump in this log does not mean released):
  - GUI v1.1.2 is released for Windows and Linux only. The macOS GUI has
    never been released.
  - GUI v1.1.3 is bumped in-tree but not released.
  - Intent: release all three OSes together at whatever v1.1.x it lands on,
    after the macOS CLI v1.7.0 port and the GUI Power-race work.
  - CLI for reference: Windows and Linux are released at v1.7.0; macOS CLI is
    bumped to v1.7.0 in-tree with hardware validation and release still pending.
- Flutter macOS Power-race plumbing:
  - Added the vetted macOS CLI v1.7.0
    `target/artery/at32f4x_race.cfg` unchanged to the GUI's universal macOS
    OpenOCD bundle.
  - The existing shared Flutter respawn runner now resolves that artery config
    for Power-race check, dump, full flash, SHU compatibility, flash-only, and
    slot-0 flows on macOS.
  - RDP/protection actions remain intentionally unsupported in Power-race.
  - Non-hardware verification passed: the GUI race cfg is byte-identical to
    both macOS CLI architecture copies, bundled universal OpenOCD parsed it
    without `init`, `flutter analyze` passed, and the macOS debug app built.
  - The existing widget smoke test still fails on two unrelated desktop-row
    overflows at its default 800x600 viewport.
  - Later hardware testing passed the packaged Power-race connection check on
    attempt 78. GUI Power-race dump/flash/compat/slot0 write-path validation
    remains separate release coverage.
- Added `x3utils_flutter/tool/package_macos.sh` for repeatable macOS packaging.
  - Builds Flutter's universal release app.
  - Embeds the complete `native/macos` backend at
    `Contents/MacOS/native/macos`, matching `OpenOcdPaths.find()`.
  - Verifies version consistency, required backend files, x86_64 + arm64
    slices, the app signature, and a no-hardware parse of the Power-race cfg.
  - Produces a versioned app folder and ZIP under `x3utils_flutter/dist/`.
  - First end-to-end v1.1.3 package run passed on Intel macOS; the existing
    v1.1.2 app under `~/Applications` was inspected but not replaced.
- macOS icon investigation confirmed the packaged app already contained the
  correct lightning icon; the stale Flutter logo was a Dock/Launchpad cache.
  The temporary icon-identity rename and build-number bump were reverted.
- Flutter macOS RDP packaging fix:
  - Real packaged testing found `rdp_check.sh --launcher` failed immediately
    with `Missing config.sh`.
  - The shared runner had written config beside `special/rdp`, matching Linux,
    while the macOS CLI-derived scripts intentionally load `../../config.sh`.
  - macOS now writes config at the temporary run root; Linux keeps its existing
    beside-script config. Toolkit setup failures no longer receive the generic
    SWD/C45 re-seat hint.
  - Added a fake-OpenOCD regression test for the packaged-tree layout; it
    confirms the root config is found and a complete read-only verdict reaches
    Flutter without hardware.
  - Verification passed before the follow-up: Bash syntax, targeted Flutter
    test, `flutter analyze`, and universal package build.
- Follow-up correction: the Flutter GUI must honor its selected A/B/C
  connection mode for Check protection. The CLI's blanket macOS `-l` disable
  was too broad for the GUI because Power-race is already blocked before the
  script runs. Restored `--launcher` for Flutter macOS RDP checks while keeping
  the corrected root-level config placement. The regression test now covers
  launcher A, B, and C selection.
  - Follow-up verification passed: targeted A/B/C regression test,
    `flutter analyze`, Bash syntax, and universal package rebuild.
- Session closeout — packaged Flutter macOS v1.1.3:
  - Correct custom icon and 1200x800 initial window confirmed. The earlier
    Flutter icon was Dock/Launchpad cache; a fresh install fixed it.
  - Packaged Default SWD Check connection passed on real hardware.
  - Packaged Power-race Check connection passed on real hardware, caught on
    attempt 78, detected the `artery` flash bank, and exited 0.
  - Power-race Check protection correctly showed Not supported and launched no
    RDP hardware command.
  - Check protection passed on real hardware in launcher A and launcher B.
    Mode B preserved the guided hold/count/release flow. Both read FAP=0xA5,
    FAP_COMP=0x5A, and readable main flash, producing NOT PROTECTED.
  - C45 Genuine launcher C protection check was not hardware-tested in this
    session.
  - Renaming embedded `oocd` confirmed fail-closed behavior: OpenOCD missing,
    action FAIL, no simulation or false success. Restore the name and relaunch
    because backend discovery happens at startup.
  - `AGENTS.md`, `docs/testing.md`, and the Flutter README now record the
    settled package layout, RDP platform distinction, tests, and cache note.

## 2026-07-17

- Flutter GUI v1.1.3 Apple Silicon smoke check:
  - The macOS GUI package was also quick-tested on Apple Silicon.
  - Treat this as packaging/runtime sanity coverage, not full hardware
    validation unless separately recorded.
- macOS CLI v1.7.0 mode D is hardware-validated. Flash times were the usual long
  ones, consistent with the other platforms and not a regression. This closes the
  "real hardware validation remains outstanding" item from 2026-07-16.
- Deliberately not tagged. The published v1.7.0 tag points at 5ceb18e
  (2026-07-15), which predates the port and still has x3utils_mac/VERSION at
  1.6.6, so the macOS scripts are in no tag. The CLI ships scripts, so the
  release asset is the source: attaching them to the existing v1.7.0 release
  would publish code absent from the tag, and the tag would stop describing what
  shipped. That differs from adding a late build artifact of already-tagged
  source, which is normal. Moving a published tag is not an option. Fold macOS
  into the next CLI tag instead.

## 2026-07-18

- Flutter GUI: added zip3 firmware import (Flash slot 0 -> Choose .zip):
  decrypt -> validate -> flash. All new work is Dart-only; no CLI or firmware
  changes. GUI bumped to v1.2.0 BETA (was 1.1.3), not yet tagged/released.
- New engine files (ports of the ScooterHacking tools, MIT, credited in
  `x3utils_flutter/README.md`):
  - `lib/engine/ninebot_tea.dart` - Dart port of NinebotTEA (TEA cipher).
    Verified byte-identical to the Python reference over 15 vectors incl. the
    128 KB image. Decrypt output equals `ninebottea decrypt` exactly, including
    NinebotTEA's 0-7 trailing pad bytes; the bin is flashed as-is (same as the
    ecosystem), so the pad is not a defect.
  - `lib/engine/pack_zip3.dart` - port of fw-zip-package-v3 `pack.py`
    (`makeZipV3`) plus the inverse `unpackV3`. zip3 is treated strictly as
    encrypted + MD5'd: require `FIRM.bin.enc` and `md5.enc`, verify the md5
    before decrypt. The plain-`FIRM.bin` path was dropped - no point for zip3.
- Two-layer package validation:
  - Model gate (`lib/engine/device_spec.dart`): accept ONLY models
    {zt3, g3, gt3, f3} x types {MCU, VCU}; reject other models and any BLE/BMS.
    Fail-closed, case-insensitive, runs before decrypt. Verified in-app: BMS and
    BLE reject by type; g2 (gen 2) rejects by model. Kept in CODE, not a runtime
    config, on purpose - it is a bricking-risk allow-list; per-model records so
    device-side validation can grow off them later.
  - Banner (payload) check: firmware carries a fixed 16-byte ASCII banner
    `SCOOTER_<TYPE>_<CODE>` at bin offset 0x400. TYPE in {VCU,MCU}. MCU code is
    always `0001` (confirms type, not model). VCU code is per-model:
    zt3=xxU2, g3=xxG3, gt3=xGT3, f3=xxF3 (gt3<->xGT3 confirmed against a real
    gt3/VCU info.json; codes are version-independent). `verifyBanner`
    cross-checks info.json - type always, model for VCU. HARD reject: a mismatch
    is rejected (red), same path as the model gate - a mislabeled package never
    loads. Proven safe first: a pass over the full jsb.by firmware set (99 files,
    bins + decrypted zips, all 4 models x VCU/MCU) found every banner matching
    its model, 0 mismatches / 0 undecodable, so hard-blocking cannot reject a
    legit image. (BLE/BMS use a different non-SCOOTER banner but never reach the
    check - the model gate rejects those types first.) Superseded the initial
    soft/amber warning after this proof.
- Hardware/human validation: a real gt3/VCU package flashed to slot 0; the
  flashed slot-0 region (0x08001000+) byte-matched the decrypted bin (MD5 equal)
  and the bootloader [0,0x1000) was unchanged. Confirms decrypt -> slot-0 flash
  is correct. v1.2.0 stays BETA until more hardware coverage is routine.
- Storage / logging:
  - Decrypted bins are kept persistently in `Documents/x3utils/unpacked_zip3/`
    (timestamped) so they can be re-flashed later via Choose .bin.
  - The zip import runs outside a `start()` run, so it flushes its own log to
    `logs/zip3_import/` when Save log is on - rejections and banner warnings are
    now persisted (previously console-only). `logToFile` stays opt-in (off by
    default), which is why the logs folder can look empty.
- Versioning:
  - BETA is a separate `kAppStage` in `lib/theme.dart`, deliberately kept OUT of
    the four numeric version strings (VERSION, pubspec, kAppVersion, installer
    AppVer) so they stay byte-equal - `package_macos.sh` asserts that match and a
    space would also break the mac plist.
  - New `tool/version.dart` is the single sync authority for all 7 version spots
    (check mode fails on drift; set mode writes them and bumps the build). Use it
    instead of hand-editing.
- Correction: the earlier "gf3" model was a typo; the real model is `gt3`
  (banner `xGT3`), confirmed by a real info.json. Fixed in device_spec and the
  rejection messages.

## 2026-07-19

- Pre-flash safety, second layer: slot-0 size window + a device-side target-ID
  guard. Dart-only; the flashing brains (OpenOCD/Tcl) are unchanged.
- Slot-0 size window (firmware.dart): the DECRYPTED slot bin must fall within
  [slot0MinBytes, slot0MaxBytes] - PROVISIONAL 50 KB..64 KB placeholders, the
  two numbers to tune once the exact slot-0 region spec is confirmed. Hard
  reject outside. Replaces the old 0x1F000 (whole app-region) cap, which would
  have let an oversize slot bin overrun slot 1 / identity and break the
  identity-safe guarantee. Every observed real firmware is ~57-61 KB, well
  inside the window.
- Device-side target-ID guard (device_spec.checkTargetMatch + _runFlash): after
  the mandatory backup, read the TARGET's current slot-0 banner from the fresh
  dump at offset 0x1400 and compare it to the incoming firmware's banner (0x400
  for a slot bin, 0x1400 for a full image). Confirmed mismatch -> abort BEFORE
  the write, keep the backup. Blank/unreadable target -> allowed (we couldn't ID
  it: blank chip / rescue / unknown fw), so first-flash still works. Scope:
  backup+flash and flash_slot0 (they dump first). flash_only skips it (no
  backup, by design - the deliberate operator override). SHU compat is a
  separate path and untouched (it reflashes the chip's own patched fw, so a
  mismatch is impossible).
- Hardware-validated on a real target: model swap (zt3 target xxU2 <- g3 fw
  xxG3) hard-stopped on BOTH backup+flash and flash_slot0; type swap (VCU target
  <- MCU fw 0001) hard-stopped on flash_slot0. Each backed up first, wrote
  nothing, kept the backup, set Last connect FAIL, and (Save log on) recorded
  the "target mismatch" line in the action's own log (logs/flash_backup,
  logs/flash_slot0). The 0x1400 offset math is confirmed against real dumps.
- KNOWN LIMITATION - the banner is FIRMWARE identity, not HARDWARE identity. A
  device someone already mis-flashed (e.g. an F3 running G3 VCU fw) reads as the
  wrong model, so the guard would BLOCK the corrective right-model flash - it
  cannot tell "wrong fw onto right device" from "right fw onto a broken device".
  Today's workaround is the flash_only override (skips the check; operator takes
  responsibility, though it is a full-image reflash).
- Serial-based "match all" guard (IMPLEMENTED, unit-verified 8/8; hardware
  validation of the serial-clash cases still pending - needs a mis-serialed
  device on the bench). Rationale: the serial is WRITABLE via the BLE app and
  G3/F3/F3pro VCU hardware is IDENTICAL, so a consistently tampered device (BLE
  serial changed + matching fw - e.g. an F3 wearing a G3 serial and G3 fw) is
  undetectable; that is the origin of the "dumbass" dumps. So the guard does not
  try to out-clever tampering: it requires EVERY readable identity signal to
  agree and blocks any disagreement, forcing the operator to resolve it.
  Signals: target slot-0 banner + target serial (user space 0x1F020, backup copy
  0x1F420, 15 ASCII chars, 3-char prefix -> model: 1K1=zt3, 1CG=g3, 1EF=f3/F3pro,
  03S=gt3; the serial survives a slot flash), loaded banner (+ loaded serial for
  a full image). All models must agree AND all types must agree (type comes from
  banners only; the serial is model-only). Any clash -> block, INCLUDING a target
  contradicting itself (serial f3 vs slot-0 g3 = the mis-flashed / half-tampered
  state). Nothing readable -> couldn't ID -> allowed (first flash / rescue). To
  correct a rejected mis-flashed device, use the flash_only override. Caveats:
  plaintext flash so this defends ACCIDENTS not forgery; CPU UID is unique but
  does not decode to model (unused); BLE exposes model+type authoritatively but
  is out of scope for an SWD tool.
- Built the flash_only deliberate-override dialog (closes the "not yet built"
  item from earlier today). Placement decision: the gate is on ENTERING the
  action from the left pane (`_showFlashOnlyWarning` in main.dart), not on the
  CTA — a first CTA-press version was built and then moved after review. The
  warning fires every time Flash Only is entered (leaving and returning
  re-warns; re-clicking the already-selected tile does not), Cancel keeps the
  previous selection, and its confirm button (`_CountdownPillButton`) counts
  down 5 s before it becomes tappable. Once inside, the hero behaves as before:
  the CTA keeps the original instant hard confirm, so multiple flashes in one
  visit are not re-gated. Scope: flash_only ONLY — rdp_rescue keeps its instant
  hard confirm. Both dialog texts now name BOTH skipped safeguards (no backup,
  no target-match guard). Presentation-only friction in front of user consent,
  not in front of an OpenOCD call. `dart format`, `flutter analyze`, and a
  debug build pass; the maintainer ran the debug build and confirmed the
  selection-gate flow is the intended behavior.
- Serial guard "not working" — ROOT-CAUSED, then PARKED (no code change).
  Bench report: serial-clash cases never blocked. Findings from real dumps:
  - ABSENCE IS NOT MISMATCH: the guard only compares signals it could READ
    (DEVLOG "nothing readable → allowed" applies per-signal, not just to the
    all-blank case). This is forced by the one-loop design that serves both
    128 KB full images and slot bins (slot bins structurally lack serial +
    0x1400 banner, so no signal can be mandatory).
  - The serial offsets are INCOMPLETE, layout is fw/model-dependent: G3 keeps
    its real serial at 0x1F020/0x1F420 (as coded), but the zt3 bench unit kept
    its REAL serial at 0x1C020 (unread by the guard) with only a near-default
    `1K1E0000000001x` at 0x1F020. In v1.5.5 the 0x1C000 page holds CODE, so
    0x1C020 as a source would need a strict 15-char shape check; scanning the
    user window is out.
  - The proximate cause on the bench: zt3_vcu_v1.5.5_rescue.bin (full image,
    zt3 banner, blank serial regions, code at 0x1C000) was flashed and ERASED
    every serial record. The guard passed it CORRECTLY — all readable signals
    agreed (zt3→zt3) — after which no serial existed to clash. The degradation
    is silent: the "check skipped" note only fires when NOTHING is readable.
  - Identified gaps (PARKED, undecided): (1) identity-erasure hard-confirm
    (target has serial, incoming full image blank), (2) serial-cloning notice
    (the reverse), (3) full image with no readable banner → hard block,
    (4) log which identity signals were gathered so a degraded check is
    visible. Also: the "unit-verified 8/8" tests were a scratch harness, not
    committed — they can't be re-run and they baked in the wrong offset
    assumption.
- flash_only slot-0 scope — DESIGNED (discussion only, NOT built). Decision:
  a scope control INSIDE flash_only, NOT a new tile (clutter, no CLI
  counterpart) and NOT a skip-backup toggle in flash_slot0 (would flip a safe
  action dangerous via a mode switch, fighting the entry-gate model). Both
  scopes share the safety class (no backup, no guard); slot 0 only narrows
  blast radius (identity-safe) — it becomes the recommended corrective for
  guard-blocked mis-flashed devices, replacing the full-image workaround.
  Settled spec: one entry warning, once, same text both scopes; segmented
  "Full image | Slot 0 only", default full; Choose .zip greyed until slot-0
  scope (hint shown) since zip3 → slot bin; ANY scope flip clears the loaded
  firmware (simple rule "for now"); scope recorded in the log line; firmware
  bar goes TWO-LINE (filename alone on line 1, buttons on line 2) — also
  fixes the existing filename squeeze on flash_slot0's single 460 px row.
  Layout chosen from a clickable mockup (app palette, sample filenames):
  Variant A — scope control ABOVE the bar (reading order scope → file → CTA),
  START FLASH CTA on the RIGHT.
- flash_only slot-0 follow-up — REOPENED and PARKED (discussion only, NOT
  approved for implementation). The earlier "settled" no-backup design above
  must not be built as-is. Its motivating recovery case is a controller that
  was intentionally or accidentally flashed with another model's firmware:
  the installed banner (and possibly serial) then describes the WRONG model,
  so the normal target-match guard blocks the legitimate corrective firmware.
  The operator first needs known-good firmware to boot; separate BLE tools can
  repair a wrong serial afterwards.
  - Source validation should stay strict. A full bin must remain exactly 128 KB;
    a slot bin stays inside its safe slot-size window; zip3 must remain a
    readable encrypted package with valid MD5/decryption and internally
    consistent metadata/payload banner. Corrupt or deliberately mislabeled
    source packages are not required for this recovery and should not become
    accepted merely because the action is an override.
  - The useful override is TARGET identity enforcement, not incoming-firmware
    validation. ST-LINK identifies the MCU but cannot authoritatively identify
    the scooter model or whether the physical target should receive VCU versus
    MCU firmware. CPU UID is unique per chip but has no known model mapping.
    Installed flash evidence is still useful, but must be worded as e.g.
    "Installed firmware claims G3 VCU", never "Target is G3 VCU".
  - New direction to consider: make this an interactive recovery-flash flow.
    Take and save the normal 128 KB pre-flash dump, validate that dump, gather
    every readable installed banner/serial signal, and present them beside the
    incoming firmware identity and an OPERATOR-DECLARED physical model/type.
    Unlike Backup + Flash, contradictions would be explained for an informed
    continue/abort decision instead of automatically blocking. Structural
    source failures and an incoming MCU/VCU contradiction against the
    operator's declaration may still need to hard-block. If continued, write
    the selected full-image or slot-0 scope and record all evidence plus the
    override decision in the action log.
  - This changes the meaning of "Flash Only": it would actually back up first,
    but would not enforce the normal target verdict. A clearer user-facing name
    such as "Recovery flash" may be appropriate; the existing CLI flash_only
    can remain genuinely backup-free. Unresolved: naming/action placement,
    whether backup failure always aborts or offers a separately gated blind
    recovery, exact hard-fail versus advisory rules, operator model/type UI,
    confirmation copy, controller state model, and deterministic identity-case
    tests. No decision yet.
  - Mockup correction only: the earlier Variant A was misleadingly phone-like.
    Prefer Variant B integrated into the existing centered desktop hero: a
    wider two-line firmware bar, filename on row 1, single-line scope and file
    buttons on row 2, centered ZIP hint, and the existing CTA centered below.
    Local layout prototype: `x3utils_flutter/design/flash-only-slot0-centered.html`.
    This prototype explores layout only and is not a workflow specification.
- Current-round closeout — flash_only full/slot-0 source rules IMPLEMENTED.
  This is the deliberately simple no-backup action for now; the richer
  interactive Recovery action above remains a separate future project. This
  draft supersedes the follow-up's proposed package-banner consistency rule
  for flash_only only; guarded Backup + Flash / Flash slot 0 behavior stays
  unchanged.
  - UI/layout: one `Flash Only` action with `Full image | Slot 0 only`, default
    full. Scope changes clear the selected firmware. ZIP choice is available
    only for slot 0. Use the corrected centered Variant B layout: wider
    two-line firmware bar, filename on row 1, single-line scope/file buttons on
    row 2, centered ZIP hint, and the existing centered CTA. Record scope in
    the run log.
  - Full-image `.bin` hard checks: selected path exists; `.bin` extension;
    existing OpenOCD path guards (`{}` and the Windows non-ASCII restriction);
    exactly 131072 bytes; non-empty and not one repeated byte. No ZIP input for
    full-image scope.
  - Slot-0 `.bin` hard checks: the same existence/extension/path/content checks,
    with final file size inside the newly set slot window
    [51200, 65536] bytes rather than exactly 128 KB.
  - Slot-0 zip3 hard checks, in order: file exists and has `.zip` extension;
    reject files larger than `70 * 1024` bytes BEFORE `readAsBytes()` (a wrong
    1 GB ZIP previously crashed the app); readable ZIP; valid `info.json` with
    schemaVersion 1 and a firmware record; declared firmware type exists and is
    VCU or MCU, case-insensitive (BLE, BMS, missing, or unknown types reject);
    `FIRM.bin.enc` exists; `firmware.md5.enc` exists and matches; NinebotTEA
    decrypt plus its plaintext checksum passes; persistent output filename is
    ASCII-sanitized; output write succeeds; decrypted output passes the same
    repeated-byte and [51200, 65536]-byte slot checks. The size check is on the
    final decrypted bytes, including NinebotTEA's canonical trailing padding.
    A rejected ZIP selection clears any previously selected firmware.
  - Informational only in flash_only: display `info.json`'s model/type as
    "Package says ...". Do NOT enforce the supported-model allow-list, compare
    package metadata to the decrypted payload banner, require a recognized
    payload banner, inspect target banner/serial, or run the target-match guard.
    Consequently a structurally valid model-mislabeled package can pass, but a
    package declaring BLE/BMS cannot. The existing entry warning remains the
    operator-responsibility gate: no backup and no target guard.
  - Archive survey used for the cap: 49 ZIPs in the local firmware mirror;
    18 VCU packages were 56849..61948 bytes and 11 MCU packages were
    59273..59692 bytes. Largest VCU/MCU package was 61948 bytes; `70 * 1024`
    leaves 9732 bytes of headroom. Ten BMS packages were 57502..65251 bytes, so
    the explicit type gate is necessary; ten BLE packages were
    403616..1847282 bytes. Some valid VCU/MCU packages contain three archive
    entries, so exact entry-count validation is intentionally not required.
  - Implementation keeps guarded `flash_slot0` strict while giving flash_only
    its informational model/banner policy. The selected scope is transient,
    resets to Full image on each Flash Only entry, clears firmware on every
    scope flip, dispatches through the existing full/slot OpenOCD argument
    builders, and logs the chosen scope. ZIP claims remain visible in the bar
    and import result. The Flash Only warning dialog was widened for its
    existing single-line desktop buttons.
  - Verification: `dart format`, `flutter analyze`, 12 Flutter tests, and a
    Windows debug build pass. New tests cover the exact full/slot size edges,
    70 KiB pre-read rejection, permissive model/banner handling, retained
    guarded-slot enforcement, BLE/BMS rejection, MD5 enforcement, transient
    scope clearing, and the desktop warning/scope flow. No OpenOCD command or
    hardware flash was run at implementation time.
  - Windows hardware validation (2026-07-19, v1.2.0 BETA, Default SWD) passed
    all three normal Flash Only paths: a 131072-byte full-image `.bin` erased,
    wrote, and verified; a slot-0 `.bin` wrote and verified at `0x08001000`;
    and a VCU ZIP3 imported/decrypted, displayed its package claim, then wrote
    and verified at `0x08001000`. The controller booted normally after the
    tests. A second MCU ZIP3 also imported/decrypted and displayed `ZT3 · MCU`.
  - Negative selection checks confirmed that a 507367-byte ZIP is rejected by
    the 71680-byte pre-read cap and a package declaring BMS is rejected by the
    VCU/MCU type gate, both before OpenOCD starts. Full-size `.bin` in slot-0
    scope and slot-size `.bin` in full-image scope are also rejected. Those
    `.bin` picker failures use the existing app-wide red status strip and do
    not create log entries; this is retained behavior, not specific to Flash
    Only. The centered ZIP helper and persistent `Package says ...` claim now
    use the same brightness/contrast treatment as `No firmware chosen`, at 12
    pixels instead of the original 11-pixel muted treatment, after the
    hardware-test UI showed the information line was borderline invisible;
    loaded filenames remain left-aligned for long-name handling.
- Mainstream guard DECIDED + IMPLEMENTED: BANNERS ENFORCE, SERIALS INFORM.
  Serial-based blocking is deliberately RETIRED — do not rebuild it without a
  new decision. The decision arc that got here: the parked serial guard kept
  producing wrong answers on real hardware (zt3 real serial at 0x1C020 unread,
  near-default at 0x1F020), enforcement design ballooned into a four-state ×
  pairing matrix + per-model generic-string list, and the key domain fact
  arrived: `1K1E0000000001` is the FACTORY serial of a replacement ZT3 (EU)
  VCU — the Ninebot app owns provisioning (rewrites 0x1F020/0x1F420 with the
  bound serial on part replacement; a CLEARED serial region forces the same
  flow at first connect, which is why rescue bins clear user space). SWD
  cannot be authoritative about serials, so the tool stopped pretending.
  - Enforced (hard): `checkTargetMatch` blocks on firmware-BANNER model/type
    disagreement only (the hardware-validated cases keep blocking). NEW
    selection-time gate `checkIncomingBin`: Backup + Flash and Flash slot 0
    reject a picked .bin with no readable SCOOTER banner at its expected
    offset (0x1400 full / 0x400 slot) — not recognizable firmware; the
    rejection text points at Flash Only, which stays permissive by design for
    crafted/rescue images (e.g. zt3_vcu_v1.5.5_rescue.bin).
  - Informational (never blocks): every Choose .bin selection now shows a
    firmware-bar identity note via the flash_only "Package says" strip
    pattern, generalized — banner model/type plus serial state. Serial
    classification: real (shape-valid 14-char [0-9A-Za-z], prefix→model
    decode still displayed), generic (exact known factory strings,
    `kGenericSerials` — ZT3 EU `1K1E0000000001`, G3 `1CGC0000000001`; add as
    observed), cleared (both copies uniformly 0x00/0xFF), none. AMBER treatment for generic and
    cleared (generic shows the full string per decision) and for a
    serial-vs-banner model contradiction; the compact Backup + Flash bar
    gained the note line it never had. Run-time: target + firmware identity
    log lines after the backup dump (degraded-signal visibility, closing the
    old parked gap 4), plus a serial-change note (replaced / cleared /
    written / reverted-to-generic) in the log and appended to the success
    message. Restoring the device's own backup and slot writes stay silent.
  - 0x1C020 is NOT read (display-only candidate for later); the earlier
    "crafted bin → hard block" stance was consciously relaxed to warn-only
    because a rescue-flashed, never-provisioned device has a GENUINE dump
    with blank serials — warn-only has no false blocks.
  - Committed deterministic tests replace the never-committed 2026-07 scratch
    harness: test/target_identity_test.dart (26 tests — classification,
    banner-only blocking incl. "serial disagreement no longer blocks",
    selection gate, display facts, change notes) with the real offsets.
  - Verification: `dart format`, `flutter analyze`, the Flutter tests, and a
    Windows debug build pass. First hardware run (same day, Windows bench):
    Backup + Flash of G3 VCU fw onto the zt3 target showed the informational
    `Firmware says: G3 · VCU` strip on load, allowed continue, backed up,
    then hard-stopped on the banner guard with the FAILED screen — exactly
    the designed behavior. The run log also validated the new identity lines
    (`target identity` / `firmware identity`) and the cleared-serial change
    note.
  - Bench round 2 CORRECTIONS from that log (maintainer-confirmed):
    - The serial is 14 CHARS, not 15 — the bench read one char too many
      because the 15th byte is adjacent memory bleeding into the read (the
      earlier `…x` in these notes was the same artifact). `kSerialLength` is
      now 14 and a regression test pins the stray-byte case.
    - Confirmed real/generic pairs for ZT3 and G3 (a normal per-unit serial
      vs the factory replacement-part serial). Both generics are in
      `kGenericSerials`, so the bench unit now classifies as generic
      replacement instead of real.
    - Tense fix: the serial-change note printed pre-write read "device
      serial cleared (was …)" on a run the guard then BLOCKED — it claimed
      an action that never happened. Now tense-free `device serial: A →
      cleared (…)`, honest in both the pre-write log and the success
      message (same "unconfirmed fact" principle as the progress-UI rule).
    - After corrections: `flutter analyze` clean, 39 Flutter tests pass.
  - Bench round 3 (same night) validated the SUCCESS path: Backup + Flash of
    a genuine ZT3 dump onto the generic-serial bench unit showed the neutral
    strip (`Firmware says: ZT3 · VCU · serial <zt3-serial> → ZT3`),
    flashed & verified, and the DONE screen carried a `Note: device serial:
    <generic> → <zt3-serial>` change line — the replacement-part restore
    scenario end-to-end, with the 14-char generic classification visible.
    PARKED (maintainer, nitpick tier, do not start unprompted): a second
    pass on result-message wording plus colored/highlighted key words in
    result text. Still wanting bench eyes: the amber strip states
    (generic/cleared incoming image) and the bannerless-bin selection
    rejection.

## 2026-07-20

- BLE-OTA vs SWD-slot0 dump comparison (real bench, zt3 VCU 1.5.2 Compat).
  Compared two full 128 KB dumps of the same device: `shu152` taken after a
  BLE flash of the repo's v1.5.2 Compat zip, `stl152` after an x3utils
  slot0-zip flash of the local firmware mirror's zt3 VCU 1.5.2 (Compat)
  package. Result: byte-identical across all 131072 bytes EXCEPT a
  single contiguous 20-byte block at 0x0F36C-0x0F37F, present (real data) in
  the BLE dump, blank 0xFF in the slot0 dump.
- Provenance conclusion: the FIRMWARE is the same. The decrypted mirror
  payload (`FIRM_1.5.2 (Compat).bin`, 58220 bytes) is byte-identical to the
  slot0 region [0x1000, 0x0F36C) of BOTH dumps, and the mirror's
  FIRM.bin.enc MD5 matches its own info.json. So "repo zip ==
  local mirror" is CONFIRMED at the payload level; the two dumps differ only
  by flash METHOD, not firmware.
- The 20-byte trailer is NOT firmware: the payload is exactly 58220 bytes and
  ends at 0x0F36C, so the trailer sits PAST the image in the erased slot tail.
  Written by the BLE OTA path; SWD slot0-flash (raw decrypted payload only)
  does not write it. It looks like BLE OTA integrity/bookkeeping metadata, not
  firmware. Field use: a lone 20-byte block at the slot tail is a fingerprint
  of BLE-OTA provenance vs a clean SWD slot0 flash.
- Boot outcome: the slot0-flashed device (missing the trailer) BOOTS and runs
  normally. Confirms the Compat bootloader does not gate boot on that trailer;
  the trailer is OTA-side bookkeeping, harmless to omit.
- "Make zip3" packer: PARKED (do not build unprompted). It was a nice-to-have
  ONLY if painless. It isn't: the encryption/packaging half is already covered by
  the standalone `ninebottea` CLI, so the packer's only real value-add is trimming
  the slot0 payload to its exact length -- and that trim is the unsolved hard part
  (see next bullet). A feature whose sole delta is the unsolved step isn't worth it.
  Revisit ONLY if a reliable trim algorithm turns up (per-model is acceptable);
  then rethink the implementation. Frozen design if it ever proceeds: Advanced,
  offline, slot0 bin in -> VCU/MCU zip3 out for BLE "Load from file"; one code fix
  = makeZipV3.allowedTypeFlags stale {DRV,BMS,BLE} -> x3 {VCU,MCU} (mirror info.json
  says type "VCU"). makeZipV3 is already ported in
  x3utils_flutter/lib/engine/pack_zip3.dart. Operating model behind it: BLE+zip3 =
  routine loop, ST-Link/x3utils = backup-once + recovery only.
- Dump -> zip3 extraction: INVESTIGATED and DROPPED (not deferred), now with
  hard evidence. Anchor found: slot1 vector table sits at dump 0x10000, so slot0
  region = [0x1000,0x10000); user/identity at 0x1F000 (measured via full-vs-
  _cleared diff on g3_dash dumps). But exact firmware-END is NOT recoverable from
  a dump: a BLE-OTA flash leaves slot0 past the live payload full of
  non-deterministic OTA junk fill (repeating 8-byte blocks e.g.
  `80 A5 71 58 4C 18 DD EC`, `02 60 25 53 D9 05 FF 60`), and a stale tail can
  MIMIC a real end-signature (g3's `...3D C1` residue sat at 0xFF80 across four
  different versions whose true ends were far earlier; e.g. 1.5.6-100 really ends
  at 0xF084 = its 57476-byte mirror length, junk after). Backward-scan, trailing
  0x00/0xFF trim, and per-model tail signatures all fail. So the packer takes a
  CLEAN source bin only; the whole-region [0x1000,0x10000) cut is the sole
  deterministic dump fallback (boots, non-canonical, carries junk).
- Post-payload junk has a CONSISTENT cross-model shape: payload -> fixed 12-byte
  trailer -> repeating 8-byte junk block (fill constant varies per dump) ->
  erased 00/FF. Tempting as a trim rule (payload_end = junk_start - 12), but junk-
  based scanning does NOT generalize (DEAD ENDS, do not retry): (a) BACKWARD scan
  for the last periodic run hits STALE tail from a prior longer flash -> g3
  1.5.6-100 returns 61316 not its true 57476; (b) FORWARD scan for the first
  periodic run false-positives on a period-8 run INSIDE the firmware at 0x1066;
  (c) when junk is only one 8-byte period before 0xFF the run is too short to detect.
- *** BREAKTHROUGH (supersedes the "exact end is unrecoverable" verdict above) ***
  The device STORES its own firmware length. Near the top of flash there is an
  "update config" page with an ASCII "ZP" magic (0x5A 0x50). At record+8 a LE u32
  holds the ENCRYPTED length (8-aligned); the exact plain payload = that - 4.
  So dump -> exact payload is DETERMINISTIC, no trimming/heuristics:
    read u32 @ ZP+8 ; payload_len = u32 - 4 ; firmware = dump[0x1000 : 0x1000+len].
  Found at flash 0x1F800 on every dump checked. Validated BYTE-EXACT vs mirror on
  4 real dumps, both models AND both types: g3 VCU 1.5.6-100 (57476), g3 VCU 1.5.15
  (61316), zt3 VCU 1.5.2 shu152 (58220), zt3 MCU 1.4.3 (58868). Model/type-independent.
  CAVEATS before trusting in a shipping tool: (1) needs confirmation on genuinely
  UNTOUCHED fresh-flash full dumps; (2) f3/gt3 unchecked; (3) MANDATORY fail-closed
  guard, proven necessary by a len=0 case (naive read gives -4): accept only if
  magic=="ZP" AND len!=0 AND (len-4)%8==4 AND (len-4) in the slot0 window, else refuse
  and require a clean source bin. NB the ZP page sits in the user/identity zone that
  the `_cleared` twins zero -> extract from a NON-cleared dump.
- UPDATE (2026-07-20, later): PRISTINE-DUMP GATE CLEARED for g3 VCU. Four dumps
  taken immediately after a BLE/SHU flash from repo -- shu_1.4.8, shu_1.5.6_100,
  shu_1.5.13, shu_1.5.15 in x3utils/backup/ -- ALL have a valid ZP record (non-zero,
  mod8=4) and their ZP-derived payload is BYTE-EXACT to the mirror. So the ZP length
  is reliably committed on clean captures. The earlier 21-33-11 len=0 is therefore a
  TOUCHED/non-standard dump, NOT a normal failure mode -> guard rejects it correctly.
  Running tally: 8 byte-exact (4 certified-pristine), both models + both types.
  f3/gt3 gate: NO hardware to test (user has no f3/gt3 units) -> unverifiable, but
  NOT a hard blocker: the fail-closed guard refuses an unknown/absent ZP and the
  (len-4)%8==4 check rejects a different-semantics record instead of mis-cutting;
  f3/gt3 mirror payloads are ≡4 (mod 8) too, consistent with the mechanism. zt3+MCU
  can be re-run clean-room on request (already pass, not yet pristine-certified).
  This effectively un-parks the dump->slot0 path for the "Make zip3" packer, with
  f3/gt3 covered by the guard rather than by an (impossible) empirical test.
- Post-payload trailer sizing (2026-07-20): measured via the exact ZP boundary, the
  trailer past the payload is DEVICE-FAMILY-DEPENDENT, NOT universal: 12 bytes on
  g3 VCU / zt3 VCU 1.5.5 / zt3 MCU 1.4.3, but only 4 bytes on ZT3Pro; f3/gt3
  untested. Do NOT hardcode a size. It is IRRELEVANT to extraction -- the packer
  trims at the ZP-derived payload boundary (byte-exact on every model incl.
  ZT3Pro), so the trailer sits past it; only a trim-by-counting-the-trailer
  approach would care about the size. Its exact identity is unresolved device-side
  bookkeeping (content-derived, varies per firmware) -> FW-internals, deferred,
  and irrelevant to the packer. The payload+trailer unit appears TWICE per dump
  -- slot0_end (0x1000+len) and slot1_end (0x10000+len), one slot (0xF000) apart
  -- and is byte-exact between them on a fresh flash, so extraction can be
  cross-checked slot0 vs slot1.
- Reference corpus: a local g3_dash dumps folder = BLE-from-repo full dumps of
  g3 VCU 1.5.15 / 1.5.6-100 / 1.6.1 / 1.6.2, each with a user-space-cleared twin
  (identity zeroed at 0x1F000). slot0 heads of 1.5.15 (61316 B) and 1.5.6-100
  (57476 B) are byte-EXACT to the mirror = stock; 1.6.1/1.6.2 are newer than the
  mirror snapshot. Length invariant across the whole mirror: decrypted fw length
  is always ≡ 4 (mod 8) (enc is 8-aligned, plain = enc - 4) — cheap cut-validity
  gate. zt3 VCU 1.5.2 tail signature `5A D6 7E B1 13 12 7A 00` is a zt3-VCU build
  constant, NOT universal (g3/f3/gt3 and all MCU differ), so no cross-model trim.

## 2026-07-21

- Make zip3 packer — ENGINE built + verified (Dart-only, offline; no CLI or
  firmware change). Un-parks the dump->zip3 path via the ZP length record. The
  GUI action + dropdowns are a SEPARATE next pass; nothing is wired into the app
  yet.
- New/changed engine files:
  - `lib/engine/zp_extract.dart` (NEW): `Zp.payloadFromDump` — deterministic
    exact slot-0 payload from a full 128 KB dump via the device's own ZP length
    record. Fail-closed guard (magic "ZP", non-zero length, payload length
    ≡ 4 mod 8, inside the slot window, fits the dump); otherwise it refuses and
    demands a clean bin — never a guessed trim.
  - `lib/engine/pack_zip3.dart`: fixed `makeZipV3.allowedTypeFlags` (stale
    {DRV,BMS,BLE} -> {VCU,MCU}); added `PackV3.detect` (dropdown preselect) and
    `PackV3.buildZip3FromDump` (operator-declared identity -> encrypted v3
    package).
  - `lib/engine/firmware.dart`: `defaultZip3Name` + `packedZip3Path` (output
    under `Documents/x3utils/packed_zip3`).
- Design settled with the maintainer this session:
  - Offline Advanced action "Make zip3", placed after Flash slot 0 / before
    Check protection. Reuses the firmware picker for ONE 128 KB dump; the
    connection mode is ignored (left at its last state). 64 KB slot-bin input is
    deferred to a separate discussion.
  - IDENTITY IS OPERATOR-DECLARED, ninebottea-style. A Type dropdown (VCU/MCU —
    a dropdown, not a toggle, so a future type can be added) drives a Model
    dropdown ({zt3, g3, gt3, f3}). `detect()` PRESELECTS from the banner: the
    type always, and the VCU model from its banner code. The MCU model dropdown
    STARTS EMPTY and the operator must pick it — an MCU has no model identity
    (banner is 0001 on every model, and an MCU dump holds only a generic MCU
    part serial, never a 1K1/1CG/1EF/03S model serial; verified on a real zt3
    MCU dump). Background selection-vs-detection mismatch WARNINGS are an
    advanced nice-to-have, deferred; plain preselection is in.
  - `compatible` is computed like the real packages: VCU is model-specific
    (`<model>_VCU_AT32`); MCU is model-agnostic and always ships on the generic
    `x3_MCU_AT32` board (its `model` field is still a concrete label).
    `enforceModel` is an operator checkbox, default on. `displayName` defaults to
    `<model>_<TYPE>_<timestamp>`, is editable, and becomes the output filename.
  - Why MCU is generic at the board level: MCU hardware is shared across
    ZT3/G3/GT3 (F3/F3pro nearly the same). The maintainer has field-flashed g3
    MCU firmware onto ZT3 MCU hardware — it boots and runs, just with different
    behaviour, no lockup.
- Verification (offline, no hardware):
  - `flutter analyze` clean; full suite 59/59 (20 new zip3 engine tests plus the
    existing ones). New tests cover the ZP guard rejections, `detect` preselect
    (including MCU -> empty model), operator VCU/MCU builds, the enforceModel
    toggle, displayName default/override, the unpack round-trip, and
    unsupported-selection / ZP-guard propagation.
  - Byte-exact proof against the local firmware mirror (throwaway test, not
    committed): a real g3 VCU dump -> `buildZip3FromDump` reproduced the shipped
    package's encrypted member byte-for-byte. This works because the ZP payload
    length is ≡ 4 (mod 8), so NinebotTEA encrypt is the exact inverse of decrypt
    — the output is a genuine BLE-loadable package, not just a valid-looking one.
- Next: the GUI "Make zip3" action (dropdowns, enforce checkbox, editable
  displayName, offline flow). Then weigh a version note (GUI is v1.2.0 BETA).
- Make zip3 — GUI ACTION built + wired (Dart/Flutter only; the engine is
  unchanged except the SHU-key gate below). Offline Advanced action placed after
  Flash slot 0.
  - Reuses the firmware picker for ONE full 128 KB dump; the connection mode is
    ignored. A `PACKAGE IDENTITY` form holds Type (VCU/MCU) + Model
    ({zt3,g3,gt3,f3}) dropdowns preselected from the dump banner via
    `PackV3.detect` (type always; VCU model from its code; MCU model starts empty
    — the operator picks it), an Enforce-model checkbox (default on), and an
    editable displayName (blank -> `defaultZip3Name` `<model>_<TYPE>_<ts>`).
    Output lands in `Documents/x3utils/packed_zip3`.
  - `canStart` gates the CTA: a dump loaded AND both dropdowns chosen.
    `_runMakeZip3` runs before the OpenOCD runner guard (offline); a
    `FormatException` surfaces as the FAILED result; logs go to
    `logs/make_zip3` when Save log is on.
  - The generic bolt hero placeholder is hidden in Make zip3's idle state (space
    reclaimed — it isn't a flash action). Busy/OK/fail badges are unaffected.
  - Entry intro on the rail tile: an untimed "what is this for" modal (like the
    Flash Only gate but NO countdown; package icon, not the bolt). It explains
    the offline repackage flow, the repo-only requirement + the
    necessary-not-sufficient caveat (amber), and the operator-declared identity.
- SHU-key gate (repo-only) — Make zip3 refuses OEM/stock dumps.
  - The 16 bytes at flash 0x1420 are the SHU/default firmware key (==
    `NinebotTea.defaultKey` == `CompatPatch.signature`, the bytes flash_compat
    writes). `CompatPatch.keyState(dump)` classifies them: default key =
    repo/Compat fw; all-`0xFF` = the NEWER repo default (so repo fw does NOT
    always carry the signature — do not assume it does); anything else =
    OEM/stock production key. `buildZip3FromDump` stops fail-closed when
    `!bleFlashable` (i.e. OEM).
  - IMPORTANT: the gate is NECESSARY, NOT SUFFICIENT. A present key only rules
    out the obvious OEM case; it does NOT guarantee SHU BLE will accept the
    package — confirm by actually loading the file.
  - Making an OEM dump SHU-flashable by rewriting the 0x1420 key is UNRESOLVED
    (suspected enough for older firmware, NOT newer), so it is not automated;
    OEM is simply refused. The stop in `buildZip3FromDump` is where any future
    patch step would slot in.
  - Operating model behind the tool (a nice-to-have, not core): flash from repo
    (SHU) -> ST-Link full backup -> mod the bin -> Make zip3 -> BLE "Load from
    file" -> keep a local repo of zip3s. ST-Link/x3utils stays backup-once +
    recovery.
- Verification: `dart format`, `flutter analyze` clean; 67 Flutter tests (was
  59) — +7 key-gate tests (`keyState` three-way, `bleFlashable`, and pack
  accepts key/blank + refuses OEM) and +1 widget test (Make zip3 intro + form).
  Windows debug build compiles. End-to-end GUI validation on real g3 VCU 1.5.13
  and 1.5.15 SHU dumps: banner detect preselected VCU/G3, the ZP record cut the
  exact payload (56820 B for 1.5.13), packages wrote to `packed_zip3` and reload
  via Choose .bin. BLE "Load from file" acceptance is the remaining real-world
  proof — the offline path cannot self-verify it. Version unchanged: v1.2.0 BETA.

- Windows CLI v1.8.0 launcher baseline completed and hardware-tested.
  - `connection_test.bat` is the new read-only action. It uses direct OpenOCD
    output for A/B/C so the C45 hold/count/release Tcl prompts remain live; D
    reuses the established respawn loop and `race_grade.cmd` attempt grading.
  - Connection checking passed on hardware in all four modes: A Default SWD,
    B C45 Clone with `guided_connect`, C C45 Genuine/nRST, and D Power-race.
    Failure/retry behavior was also exercised before successful reconnects.
  - `launcher.bat` now mirrors the GUI action order: Check connection, Backup,
    SHU compatible, Backup + Flash, Load/change file, Advanced, Exit.
  - The Advanced submenu exposes standalone Flash Only and Flash Slot 0 prompts,
    plus protection Check and Unlock/Rescue using the launcher-selected mode.
    CLI protection actions intentionally do not block Power-race.
  - Full Windows launcher testing completed with PASS. Standalone script entry
    points remain supported; no directory-layout refactor was made.
  - Windows CLI version is now 1.8.0. Linux/macOS remain 1.7.0 until their ports
    and platform hardware checks are completed. Flutter remains v1.2.0 BETA and
    is versioned independently as the primary feature path.
  - Next port order: Linux first, then macOS. See temporary root handoff
    `CLI_V180_PORT_HANDOFF.md`; delete it after both ports are complete.

- Linux CLI v1.8.0 launcher port completed and hardware-tested.
  - Added the read-only `connection_test.sh` with live A/B/C output and a fresh
    OpenOCD process per Power-race attempt. Mode D requires flash-bank evidence,
    not only a halted core or exit status 0.
  - The launcher now mirrors the Windows v1.8.0 action order and exposes the
    Advanced Flash Only, Slot 0, protection check, and rescue entry points.
    Standalone flash tools keep their own file prompts; protection tools receive
    `-l` so they honor the selected launcher mode.
  - Check Connection passed on real hardware in modes A/B/C/D. Mode B preserved
    the guided hold/count/release prompts. Mode D exercised the missing-adapter
    prompt, then caught and confirmed the flash bank on attempt 218. A/B/C
    reported PC `0x08000120`, MSP `0x20000550` on the test board.
  - Integrated launcher regression in mode A passed for full dump, protection
    check, SHU-compatible flash, backup + loaded-file flash, flash-only, and
    slot0. Rescue launcher wiring and warnings were verified, then the operator
    aborted at the `UNLOCK` confirmation; no mass erase was performed.
  - Guided Tcl success banners now report the confirmed fact
    `Connected.  Target halted.` instead of predicting the next dump/flash
    action.
  - All Linux scripts passed `bash -n`; ShellCheck had no error-level findings;
    `git diff --check` and non-hardware launcher navigation passed. Linux CLI is
    now v1.8.0. macOS remains v1.7.0 pending its port and hardware checks.

- macOS CLI v1.8.0 launcher port completed and hardware-tested.
  - Added the read-only `connection_test.sh` using the bundled architecture-
    selected xPack OpenOCD and macOS `target/artery/at32f4x*.cfg` paths. Modes
    A/B/C keep live output; Mode D respawns OpenOCD and requires the expected
    `flash 'artery' found` evidence.
  - The launcher now uses the settled seven-action order and Advanced submenu.
    Standalone Flash Only and Slot 0 retain their own prompts; protection and
    rescue receive `-l` and honor launcher modes A/B/C/D. The CLI supports Mode
    D RDP while Flutter retains its separate pre-launch Mode-D block.
  - Check Connection passed on hardware in A/B/C/D. Mode B preserved guided
    hold/count/release prompts; C recovered from transient examination errors;
    D confirmed the flash bank on attempt 197.
  - Mode-D protection check exposed one xPack/OEM output difference: xPack at
    `-d0` completes the flash/FAP/vector reads without Linux OEM's literal
    `target halted` marker. The macOS loop now stops on complete action-specific
    evidence; hardware retest caught on attempt 403 and correctly reported NOT
    PROTECTED. Mode-D rescue uses the same fresh-process hammer strategy after
    `UNLOCK`, gated by option-area readback and an end-of-sequence marker.
    Destructive hardware validation caught on attempt 18 and read back
    `ffff5aa5`; after power-cycle, the RDP check caught on attempt 2 and confirmed
    FAP=0xA5 with readable blank flash, proving the warned mass erase occurred.
    The normal backup-required flash path then safely refused the all-`0xFF`
    blank dump; Advanced Flash Only wrote and verified all 131072 bytes of
    `zt3_vcu_rescue.bin`, restoring the board.
  - Integrated Mode-A launcher testing passed for backup + loaded-file flash,
    SHU-compatible dump/patch/flash, Advanced flash-only, Advanced slot0, and
    protection check. Rescue warnings were verified and the action was aborted
    before `UNLOCK`; no mass erase ran. All writes showed real verify evidence.
  - All macOS shell scripts passed `bash -n`; `git diff --check`, launcher
    navigation, permissions, RDP resolver construction, and arm64/x64 target
    asset checks passed. ShellCheck was unavailable. macOS CLI is now v1.8.0;
    Flutter remains independently versioned at v1.2.0 BETA.
  - Updated the Linux and macOS platform READMEs for the v1.8.0 main/Advanced
    menus, direct-script entry points, A/B/C/D RDP launcher behavior, rescue
    warnings, and blank-chip recovery. The macOS guide also records xPack's
    slower uneven Mode-D cadence and the evidence required for check/rescue.

## 2026-07-22

Flutter GUI polish pass (no engine/hardware behavior change). Windows-tested;
Linux/macOS get the same code but were not rebuilt this session.

- Hero card layout / "zones": defined and locked each content-pane zone to one
  job — header = "what this does" (immutable `action.name` + `action.sub`);
  eyebrow = state/telemetry; big title = the state/outcome; message = the one
  live fact; input; action; status bar. Confirmed no live header/hero
  description duplication (header reads the immutable model `sub`; the hero
  computes its own text). Added an invariant comment at `heroTitle`/`heroMessage`
  in `app_controller.dart`: non-idle stages fall back to the mutable `title`/`sub`
  seeded in `_goIdle`, so every non-idle transition must go through `_set()` or
  the hero would re-echo the header.
- Eyebrow redesigned so it stops duplicating the title. Chosen blend (maintainer
  picked "1+3" after discussion; "just remove the eyebrow" was rejected because
  it earns its keep as the `STEP 1/2/3 OF 3` counter in the guided C45 connect):
  - idle → STAKES, colour-coded: READ-ONLY (green) / WRITES FLASH (amber) /
    SLOT 0 ONLY (green) / OFFLINE (green) / ERASES FLASH (red). New `heroEyebrow`
    + `stakesColor` getters + `_stakes` map keyed on actionId (+ flashOnlyScope).
  - live run → an elapsed clock `M:SS` (1 s ticker). Guided steps + power-race
    `ATTEMPT n` are untouched (they fall through to the stored eyebrow).
  - result → outcome fact: `Took M:SS` on success, `Exit n · M:SS` on failure.
  - Honesty guards (per the never-fabricate rule): duration/exit are only shown
    when a real process was actually timed — run clock started/stopped at BOTH
    the OpenOCD core (`_runRealCore`) and the RDP core. Offline Make zip3 keeps
    DONE, input-validation aborts keep FAILED, and a zero exit code is suppressed
    (no misleading `Exit 0` on a judged failure).
- Shared hero block width: new `kHeroBlockWidth = 500` (theme.dart) applied to
  the warning/result callout, firmware bar (both variants), identity form, and
  result-path box so they align edge-to-edge (amber callout was 520 vs 460 boxes).
- Make zip3 no longer needs a scrollbar: trimmed hero vertical rhythm (card
  padding 28→18 top / 12→16 bottom; inter-block gaps 20→14, 14→12, 26→16). Hero
  content stays vertically centred (a top-anchor experiment was tried and
  reverted — it dumped short screens at the top).
- Startup window standardized to 1024x768 (4:3) on ALL three OSes: Windows
  `main.cpp` (outer), Linux `my_application.cc`, macOS `MainMenu.xib` contentRect
  (was 1040x752; the AGENTS "1200x800" note was stale). Windows number is outer,
  Linux/macOS are content, so those two get ~30px more usable height. AGENTS.md
  updated to the all-platform rule.
- Make zip3 "Replace existing package?" confirm dialog: dropped the useless
  copy-to-clipboard button (`DesktopPathDisplay(action: DesktopPathAction.none)`);
  path stays readable as text + tooltip.
- Added `tool/window_size.ps1` — reads a running window's outer/client rect to
  size the startup window against real screens.
- Follow-up review found and fixed two polish defects: `AppController.dispose()`
  now cancels the elapsed ticker before disposing the notifier, and the macOS
  XIB content-view frame now matches its 1024x768 `contentRect`. `flutter
  analyze` passed after both corrections.
- Kept the eyebrow timer model after review. Windows/Linux operations normally
  complete within about 10 seconds, while macOS can be noticeably slower; the
  elapsed clock gives the operator reassurance beyond the spinner. Guided C45
  and Power-race labels still take precedence. Timing stays scoped to the
  current real OpenOCD/RDP process for now, and will be reconsidered only after
  more real-use feedback suggests a better presentation.
