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
- Guarded firmware compatibility was tightened after reviewing its user-facing
  failures on Linux. Backup + Flash and Flash slot 0 now accept only the four
  known VCU banner codes (`xxU2`, `xxG3`, `xGT3`, `xxF3`) or exact shared MCU
  banner `SCOOTER_MCU_0001`; unknown codes no longer pass merely because they
  match the 16-byte banner shape. After the mandatory backup, a missing or
  unsupported target banner now fails closed instead of claiming compatibility.
  Known VCU cross-model swaps (including G3/F3) and MCU/VCU swaps abort; MCU/MCU
  remains allowed because ZT3/GT3/G3 share MCU hardware, with an explicit note
  that the common banner cannot identify the model or protect F3's different
  MCU hardware. Flash Only remains the warned expert override.
- Guarded selections now keep a SHA-256 of the accepted firmware and recheck the
  file at Start and after the backup, aborting before write if it changed. The
  same strict banner parser backs guarded ZIP3 payload validation; Flash Only's
  intentionally permissive ZIP3 behavior is unchanged.
- Make zip3 now describes its actual best-effort role: preserve local BLE-loadable
  copies of repo firmware, including versions that may later disappear, from a
  fresh full ST-Link backup taken immediately after a BLE flash. BLE writes the
  payload length to ZP; an ST-Link slot-0 write does not, so a structurally valid
  ZP can be stale and that cannot be detected from the dump alone. The intro now
  states that limitation, says a created package must still be accepted by the
  BLE app, and notes that Flash slot 0 can also consume it. Missing/invalid ZP
  evidence stops with the fresh-after-BLE instruction rather than suggesting an
  unsupported slot bin or promising a guessed result. The SHU-key rejection is
  shorter while preserving the older-repo caveat, and the generic fallback says
  "create" rather than "write" package.
- Linux dry validation: all 90 non-UI Flutter tests passed, `flutter analyze`
  was clean, and `flutter build linux --release` passed. No hardware command was
  run by the coding agent. The pre-existing `test/widget_test.dart` smoke suite
  still fails at its 1024x768 harness on a 1 px status-bar overflow plus
  off-screen Advanced rail taps. After the Make zip3 copy update, its focused
  widget test remains blocked by those same two failures before it can open the
  notice; the engine's 27 focused tests pass and `flutter analyze` remains clean.
- Linux maintainer closeout: live UI confirmed that a ZT3 VCU target plus
  selected GT3 VCU firmware saves the mandatory backup and aborts before the
  slot-0 write, and that Make zip3 rejects a dump without trustworthy BLE ZP
  evidence with the revised wording. `docs/testing.md` records those results,
  the AppImage/window-size check, and the fixed immediate Nemo reveal feedback.
  The minimum Linux/macOS package/UI/hardware campaign is now closed and
  recorded in `docs/testing.md` plus the 2026-07-24 DEVLOG entries below.
  `AGENTS.md` also records the strict guarded-banner,
  digest-recheck, MCU limitation, and stale-ZP/Make-zip3 safety contracts so a
  later implementation pass does not weaken them.

## 2026-07-23

- Byte-surveyed the private local test-bin corpus (real full dumps, cleared
  rescue images, and the repo firmware mirror; the corpus is untracked and
  outside the repository) to ground validation test data in hardware truth
  rather than code assumptions. Confirmed: banner offsets and codes match the
  app exactly; BMS/BLE bins carry no SCOOTER banner anywhere; every VCU/MCU
  slot payload is congruent to 4 (mod 8); the ZP length record (magic plus LE
  u32 at +8, payload = value − 4) cross-matched repo payload sizes byte-exactly.
- New layout facts recorded from the survey:
  - Real dumps repeat the slot-0 banner in slot 1: VCU at `0x10400`; the single
    MCU dump shows its copy at `0x10C00`, suggesting MCU slot 1 starts at
    `0x10800` (one-dump evidence, unresolved).
  - The firmware key region is 16 bytes at payload offset `0x420` (`0x1420` in
    a full image) followed by a 6-byte device rand at `0x430`; the cleared
    state is 22 x `0xFF`. Real OEM keys are 16-char lowercase-alphanumeric
    ASCII. The rand is device-unique identity material; like serials, real
    key/rand values must stay out of tracked files.
  - One old repo VCU build (G3 1.4.8) still carries a donor key+rand; some old
    builds are believed patched not to check the key at all (the old F3 case).
    No corpus file carries the SHU default key — only the app's own compat
    patch produces that state.
  - Three real ZP states exist: a valid record; magic present with length 0
    (rescue images); and an all-`0xFF` identity page (cleared rescues).
  - Observed slot payload sizes span 56372–61436 bytes, comfortably inside the
    code's provisional 50–64 KiB window; the window edges have no real-file
    coverage and tightening the window remains an open decision.
- Policy decisions: Make zip3 refuses any firmware key that is not the SHU
  default or blank `0xFF`, with no allowlist, even for known repo builds that
  may in fact be BLE-flashable — Flash Only remains the warned operator
  override, mirroring the guarded-vs-expert split used for banners. The key
  check stays 16 bytes for now; extending to the 22-byte key+rand region would
  need new classification rules. Make zip3 stays pass-through and never
  rewrites the key or rand (it assumes the BLE flash of a prepared repo bin
  already replaced the OEM key).
- Added `x3utils_flutter/tool/gen_test_bins.dart`, a deterministic generator
  for the validation test-bin set. Its layout constants are corpus-derived on
  purpose and must not be refactored to import `lib/engine`: the generator is
  an independent statement of the layout, so an engine constant that drifts
  from hardware fails a test instead of silently agreeing with the code under
  test. Each synthetic differs from its accept baseline by exactly one knob.
  Output groups: degenerates, full-image identity/key/ZP/banner cases, the
  slot-size window ladder, zip3 mutations derived from a known-good package,
  and path/extension cases (36 files), plus `gen_manifest.csv` as the oracle
  (knob turned, expected verdict, SHA-256; UTF-8 BOM so Excel renders the
  umlaut path row). Synthetics carry random unbootable payloads and an ASCII
  do-not-flash marker; unmodified real corpus files are copied in to pin
  constants and formats. The non-ASCII path case uses a German umlaut folder
  name, matching the most common x3utils user locale.
- Two manifest rows intentionally pin current behavior rather than desired
  behavior: the ZP scan's first-candidate-wins order (a plausible decoy record
  wins today) and the exact-64-KiB slot-size window edge passing. Update those
  expectations in the same change that hardens either area.
- Generated output was verified structurally (banners, key states, slot-1
  copies, and ZP records at the measured offsets) and the zip3 mutations were
  functionally spot-checked (schemaVersion, relabeled model with still-valid
  MD5, real MD5 mismatch, missing info.json). No hardware command ran.
  `docs/testing.md` records the non-hardware check; `AGENTS.md` records the
  generator contract.
- Follow-ups the same day, anticipating the message-truth testing pass:
  - Added wrong-component 128 KB test bins (`8e` BLE-style, `8f` BMS-style,
    no SCOOTER banner anywhere) because an oversized BLE zip is rejected by
    the container size gate with a misleading "too large" message before the
    truthful "unsupported component" gate can fire; at 128 KB the size gates
    cannot catch a wrong-component bin and the banner gate's message is the
    honest one. The old-repo donor-key refusal wording ("usually OEM/stock")
    was ruled a corner case and stays as is.
  - Hardened `Zp.payloadFromDump` against its one silent-wrong case: a stray
    guard-passing `ZP` earlier in the identity page used to win by scan order
    and extract the wrong payload without any error. The authoritative
    `0x1F800` record (every real dump surveyed) now wins outright; otherwise
    the page scan requires unanimity and conflicting candidates refuse with a
    truthful "conflicting ZP length records" message. A single relocated
    record is still accepted, preserving tolerance. Four new engine tests
    cover decoy-vs-authoritative, guard-failing decoys, relocation, and
    conflict refusal (31 pass, analyzer clean); the real engine was also run
    against the generated fixtures and the real rescue/OEM corpus images with
    unchanged verdicts. Test-bin set is now 40 files: `12a` expects the
    correct payload with the decoy ignored, new `12d` (conflict → refuse) and
    `12e` (relocated → accept); the AGENTS pinned-behavior note retires the
    ZP scan-order pin, leaving only the 64 KiB window edge.
- Finalized the Flutter Flash Only validation and confirmation flow.
  - Structurally valid raw full-image and slot-0 `.bin` files remain the expert
    override: a compatibility-warning modal lists the observed banner, serial,
    and ZP evidence, collects every finding, states what was not checked, and
    still offers Cancel or Flash anyway. The modal never claims that no other
    problems exist and never claims compatibility with the connected controller.
  - ZIP3 is no longer permissive in Flash Only. Every ZIP import now hard-fails
    objective package problems before loading: malformed or unsupported
    metadata, BLE/BMS type, unsupported X3 model, missing or inconsistent
    `compatible`, MD5/TEA integrity failure, unsupported payload banner, or
    disagreement between JSON and the decrypted firmware banner. This
    supersedes the previous note that Flash Only's ZIP3 behavior was unchanged;
    the expert override applies to raw firmware and unknown target suitability,
    not to a broken or mislabeled integrity-bearing package.
  - User-facing mismatch text now names the evidence sources directly: JSON
    fields for internal metadata disagreement, and JSON versus firmware banner
    for payload disagreement. The shared Snackbar keeps the `Package rejected:`
    prefix. BLE/BMS wording stays short and uses VCU/MCU terminology.
  - Windows debug-build UI validation covered raw-bin size stops and
    banner/serial/ZP findings, multi-finding modal layout, valid ZIP import, and
    representative ZIP hard failures. The focused Flash Only and inspection
    suites passed 28 tests and `flutter analyze` was clean.
  - Windows hardware validation (AT32F415 X3 testbed, ST-LINK, Default SWD)
    passed all three post-modal Flash Only paths: full 128 KB VCU `.bin`
    erase/write/verify in 7 s, VCU slot-0 `.bin` write/verify in 4 s, and valid
    VCU ZIP3 decrypt plus slot-0 write/verify in 4 s. No backup was taken, as
    advertised. These runs prove the Flash Only workflow and write verification,
    not firmware suitability for the connected controller. Synthetic fixtures
    were never flashed. Guarded-action regression and other-platform checks
    remain separate follow-up work.
- Completed the Windows guarded Flash slot 0 regression on the same debug build
  and AT32F415 X3 testbed using ST-LINK / Default SWD.
  - Selection rejected a slot-sized `.bin` with no supported banner before any
    hardware action.
  - Genuine G3 VCU and MCU `.bin` inputs each triggered the mandatory backup,
    identified the installed target as ZT3 VCU, preserved and displayed the
    backup path, and aborted before write with the correct model/type mismatch.
    A matching ZT3 VCU `.bin` then backed up, wrote, and verified slot 0 in 4 s.
  - A valid G3 VCU ZIP3 decrypted successfully, then followed the same backed-up
    target-mismatch abort without writing. A matching ZT3 VCU ZIP3 decrypted,
    backed up, wrote, and verified slot 0 in 4 s.
  - This closes the guarded `.bin` and ZIP3 paths on the Windows debug build:
    selection gates stay transient, while failures discovered after Start keep
    the durable hero result and saved-backup path. Shared malformed-ZIP cases
    were not repeated because they use the already-validated import gate.
    Other-platform guarded regressions remain pending.
- Completed the Windows Backup + Flash regression on the same debug build and
  AT32F415 X3 testbed using ST-LINK / Default SWD.
  - Repeated-byte, wrong-size, unsupported-banner, and missing-banner full
    images stopped at selection before any backup or write.
  - Genuine G3 VCU and MCU full images were accepted at selection, created and
    displayed the mandatory backup, then aborted before write against the
    installed ZT3 VCU with the correct model/type mismatch.
  - Re-flashing the fresh matching ZT3 backup created another pre-flash backup,
    wrote the full image, and verified successfully in 7 s.
- Completed the Windows Make zip3 desktop validation.
  - Genuine ZT3 VCU and MCU dumps created packages; MCU required the operator to
    choose the model. A repeated output name showed the Replace dialog: Cancel
    preserved size, timestamp, and SHA-256, while Replace rewrote the file.
  - A real OEM-key dump, a real length-zero ZP dump, and conflicting synthetic
    ZP records failed with the intended durable explanations. A single
    relocated ZP record succeeded and extracted the expected 58436-byte
    payload.
  - A package created from the genuine ZT3 VCU dump re-imported through Flash
    Only, passed MD5/decryption, and showed matching ZT3/VCU JSON and firmware
    banner evidence; it was cancelled before flashing. This is desktop
    structural validation, not BLE Load-from-file acceptance.
  - Removed the temporary macOS-only handoff and established the minimum
    Linux/macOS validation plan later closed in `docs/testing.md` and the
    2026-07-24 entries below: focused tests and packaging, one packaged offline
    smoke, and one matching guarded hardware write per OS, with a stop rule
    against replaying the Windows matrix.

## 2026-07-24

- Closed the Flutter v1.2.0 BETA minimum Linux validation on the Linux Mint
  home-primary x86_64 workstation.
  - The focused tests and analyzer passed, and the final
    `x3utils-1.2.0-x86_64.AppImage` built and launched with its real Linux
    payload.
  - The packaged 1024x768 smoke passed the truncated-input refusal, Make zip3
    creation and unchanged-output Cancel check, ZIP3 round-trip import with
    matching ZT3/VCU evidence, and prompt Linux file-manager reveal. Local
    package/import artifacts corroborate the round trip.
  - The packaged backend produced an evidence-backed Check connection PASS,
    followed by one genuine matching guarded Backup + Flash under Default SWD
    with a fresh backup, write evidence, verify evidence, and green completion.
    Per-run Save log was off, so exact firmware and backup paths were not
    retained in a log.
  - The stop rule applies: the exhaustive Windows matrix was not replayed.
    Linux is complete; macOS is the remaining platform.
- Closed the Flutter v1.2.0 BETA minimum macOS validation on the macOS 15.7.7
  Intel x86_64 workstation.
  - The focused tests and analyzer passed. `tool/package_macos.sh` produced
    `x3utils-1.2.0-macos-universal.zip` and passed its universal architecture,
    deep-signature, embedded-backend, RDP-script, and Power-race cfg checks.
  - The packaged 1024x768 smoke passed the truncated-input refusal, Make zip3
    creation and unchanged-output Cancel check, ZIP3 round-trip import with
    matching ZT3/VCU evidence, and prompt Finder reveal. Saved app logs confirm
    the 58460-byte package creation, existing-package Cancel, and ZIP3 import.
  - The packaged backend produced an evidence-backed Check connection PASS.
    One matching guarded Backup + Flash under Default SWD then created a fresh
    131072-byte backup, wrote 131072 bytes of genuine ZT3 VCU firmware, verified
    131072 bytes, and completed green. The saved run log records the backup,
    secondary copy, write, verify, and clean OpenOCD exits.
  - The stop rule applies: the exhaustive Windows matrix was not replayed.
    Minimum Linux and macOS validation is complete.
- Added an optional "Attempt to also make zip3" checkbox under the Make SHU
  compatible action (Flutter GUI, off by default).
  - When it is ticked and the compat flash succeeds, the just-flashed patched
    image is repackaged as a BLE-loadable zip3 via the existing packer. The
    patched image always carries the default SHU key at 0x1420 by construction,
    so the packer's key gate passes trivially.
  - The package is co-located with its source run and shares the run timestamp,
    so one compat run leaves three files together: `compat_<ts>.bin` (raw
    backup), `compat_<ts>_patched.bin`, and `compat_<ts>_patched.zip`.
  - VCU only: the banner declares the model, so identity is derived, not
    guessed. An MCU compat run silently skips the zip (its dump carries no model
    identity). Best-effort throughout: any packaging failure is swallowed and
    can never demote the compat flash's PASS.
  - Build/analyzer clean (`dart format`, `flutter analyze`). Hardware-validated
    on the Windows testbed under Default SWD: a ticked compat run flashed
    SHU-compatible firmware green and emitted the trio co-located under one
    shared timestamp (`compat_<ts>.bin` / `_patched.bin` / `_patched.zip`), with
    the "saved beside the backup" note shown. Full loop then closed on hardware:
    that checkbox-produced `_patched.zip` was loaded through the BLE app's Load
    from file, recognized as zt3/VCU, flashed (57.4 KB), and reported "Firmware
    flashed successfully". End-to-end proven: compat flash -> auto zip3 -> BLE
    load -> PASS.
- BLE acceptance investigation (why a repackaged slot-0 does or does not load
  through the BLE app), settled by byte comparisons plus real BLE flashes.
  Supersedes an earlier same-day note in this entry that wrongly concluded "BLE
  requires the default SHU key at 0x1420" - that conclusion was overturned.
  - Test that started it (ZT3 VCU 1.5.8, a version NOT in the repo mirror): a
    compat-patched dump (default SHU key written at 0x1420, real device identity
    intact) repackaged to a zip3 BLE-flashes. The same dump with the key AND the
    following 6 identity bytes blanked to 0xFF does NOT BLE-flash. The two
    images differ only in those 22 bytes at 0x1420-0x1435.
  - But blank is not the discriminator. Every repo package inspected - VCU
    1.4.11 / 1.4.15 / 1.5.2 and MCU 1.5.2 - is blank at BOTH the key (payload
    0x420) and the 6 identity bytes (0x430), and those BLE-flash routinely. So a
    blank key+identity is clearly acceptable in general; the artificial "cleared"
    1.5.8 failing is the odd one out, not the repo norm.
  - BLE writes the payload verbatim and re-provisions nothing: the repo MCU
    1.5.2 payload matches the post-flash dump byte-for-byte (59028/59028). Repo
    flashing also wipes an OEM device's key region (a stock MCU carried an OEM
    ASCII-token key there; after a repo BLE flash it is all-0xFF).
  - Root cause. Blank-key repo firmware still loads because the repo build is
    prepared to pass the device's acceptance check regardless of key state - a
    property beyond the key/identity bytes. The specific mechanism is a third
    party's and is intentionally left out of this public log. That is the
    "something else" beyond clearing the key.
  - Resulting model: acceptance is passed EITHER by presenting the real SHU key
    (what flash_compat writes) OR by using a maintainer repo build that is
    already prepared to pass regardless of key. A synthetic cleared bin is
    neither - a blank key on an un-prepared build - so it is rejected. That is
    why the compat/defkey repackage loads and the hand-cleared one does not.
  - Consequences for the tools (no code change, and now for a concrete reason):
    - The standalone Make zip3 blank-key gate stays as-is. Its intended source
      is a fresh dump taken right after BLE-installing repo firmware, which is
      already a prepared repo build, so a blank-key repackage of it loads. Only
      a synthetic cleared bin fails, and the gate does not need to distinguish
      them.
    - The compat -> zip3 checkbox is a sound, independent recipe: it takes the
      other road (writes the real key), so it loads whether or not the source is
      a prepared repo build.
  - Limits: characterized on one version-pair (MCU); no repo 1.5.8 exists to
    diff the VCU that failed, so the VCU specifics are not established. Identity
    bytes and the OEM token value are kept out of this file on purpose.

## 2026-07-25

- Prepared Flutter GUI v1.2.1 and refactored Make zip3 into the offline
  Pack / Unpack zip3 workspace.
  - Pack retains the existing working dump-to-ZIP3 flow. Unpack now inspects a
    selected package, suggests
    `<model>_<type>_<normalized-source-filename>.bin`, permits editing that
    filename, and writes through the existing Cancel/Replace confirmation flow
    to `Documents/x3utils/unpacked_zip3`.
  - Unpack rechecks the selected ZIP digest at Start and validates the package
    again before writing. It accepts internally consistent X3 VCU, MCU, BMS,
    and BLE packages without the flash path's archive or slot-size limits.
    Schema 1, `FIRM.bin.enc`, `md5.enc`, TEA checksum, supported model,
    compatible-board consistency, and VCU/MCU payload-banner checks remain
    mandatory. Flash ZIP import remains VCU/MCU-only and size-gated.
  - Package details now show Model, Type, JSON `displayName`, payload size,
    `enforceModel`, and encryption. The editable output field has increased
    height and the details panel uses balanced spacing.
  - Offline verification passed: `flutter analyze` was clean and the focused
    ZIP3, confirmed-write, and widget suite passed 65/65. A temporary private
    corpus probe passed 3/3: real BMS and BLE packages (including a roughly
    1.85 MB BLE archive) decrypted, 13 malformed packages failed at their
    intended validation gates, and a valid VCU package with an extra padding
    member remained acceptable to the extraction-only path.
  - No packaged-app build, BLE operation, or hardware command was run for this
    v1.2.1 change.

## 2026-07-26

- Replaced the mixed Make zip3 input policy with a three-page `ZIP3 tools`
  workspace: Slice / Pack / Unpack.
  - Slice is the strict v1.2.0 path: exactly 128 KB, ZP-derived payload, and
    the existing SHU-key gate.
  - Pack treats the selected `.bin` as the complete payload. It supports VCU,
    MCU, BMS, and BLE with corpus-confirmed compatible-board metadata:
    `<model>_VCU_AT32`, `x3_MCU_AT32`, `x3_BMS`, and `<model>_BLE`.
    Flash ZIP import remains independently restricted to VCU/MCU.
  - Pack rejects a detected full 128 KB controller dump, input whose length is
    not `8n + 4` (NinebotTEA would add zero padding), unsupported/missing or
    contradictory VCU/MCU banner evidence, and VCU/MCU payloads beyond the
    61436/59388-byte physical ceilings. Selection-time objective checks run
    again inside the build at Start.
  - BMS/BLE carry no known equivalent `SCOOTER_...` banner. Their Type and
    Model remain manual; observed corpus size ranges are not treated as
    identity. Pack does not apply ZP or SHU-key checks.
  - The vertical page transition remains rail-controlled and non-scrollable.
    Slice and Pack clear their shared transient input/identity state on page
    changes; Unpack keeps its independent state. The rail subtitle is
    `slice · pack · unpack`. The outdated "What Pack zip3 is for" entry modal
    is disabled pending a rewrite for all three workflows.
  - Offline verification: the focused ZIP3/controller/widget/output suite
    passed 86/86 and `flutter analyze` was clean. After the final modal-only
    removal, the widget suite passed 3/3 and `flutter analyze` remained clean;
    `git diff --check` passed. No packaged-app build, BLE operation, or
    hardware command was run.
- Pack form polish (same day): Model dropdown now precedes Type (reads like
  the banner, "G3 VCU"); the Package name box was measured in a widget test
  and set to the dropdowns' exact 44 px (contentPadding vertical 11 → 12);
  a Pack payload source now suggests `<model>_<TYPE>_<source-filename>` — the
  Unpack suggestion's shape — while Slice dumps keep the timestamp default. The
  blank-name default at Start and the form hint share one controller getter
  (`zip3DefaultName`) so they cannot disagree.
- Correction to the name-box height fix above: the padding-math approach
  (vertical 12 "measured to 44 px") only held under the test framework's Ahem
  font — on a real Windows build the box still rendered short of the
  dropdowns. Root cause: an InputDecorator's height follows font metrics,
  which differ per platform font, so padding can never pin it. Replaced with
  the structural fix: the name field now sits in the same fixed 44 px
  container the dropdowns use (focus border painted manually via a
  FocusNode), with the "Package name" label and output-folder hint moved to
  a caption line below. Heights now match by construction on every platform.
- ZIP3 hero fit: a cleared-serial dump rendered a three-line amber callout
  that pushed the CTA off a 768 px window. Root cause was relevance, not
  layout — Slice emits slot 0 and Pack consumes a complete payload; neither
  includes the full-dump serial pair at 0x1F020. The ZIP3 form
  now shows `BinIdentity.bannerSummary` (banner only, never amber) and logs
  the full identity line instead; every long/amber note on that page was
  serial-derived, so this covers the category rather than one string. Guarded
  flash paths keep the full summary with its warnings. Also trimmed the
  packer's pre-CTA gap to 18 px and made the name caption one line.
- Method note for future layout work: absolute pixel measurements taken in
  `flutter test` are NOT valid for fit decisions. The test environment uses
  the Ahem font (square glyphs), so text is much wider than real Segoe UI and
  headings wrap that would not wrap on a real build. Widget tests are fine
  for structure and relative behavior; judge fit on a real packaged build.
- Flutter RDP retry-screen fix and Linux/macOS handoff:
  - With ST-LINK absent, Check protection and Unlock / rescue reached their
    shell retry prompt but Flutter kept showing the busy retry screen instead
    of the standard red failure screen. The maintainer reproduced the same
    pre-fix behavior on Windows, Linux, and macOS.
  - The shared fix is in `x3utils_flutter/lib/app_controller.dart`: an RDP
    retry prompt now enters the normal red failure state; Retry resumes the
    already-waiting RDP process; Dismiss terminates it; and late stdout/stderr
    diagnostics preserve the full re-seat/Retry callout regardless of stream
    ordering.
  - Windows Flutter additionally needs
    `x3utils_flutter/native/windows/special/rdp/rdp.ps1` to print the retry
    prompt before promptless `Read-Host`, because `Read-Host` hides its own
    prompt under Flutter's redirected stdio. The separate `x3utils_win` CLI
    release tree is intentionally unchanged.
  - Correction after macOS retest: Bash suppresses `read -p` prompts when
    Flutter launches the script with redirected stdin. The macOS
    `rdp_check.sh` and `rescue_unlock.sh` retry loops now print the prompt
    explicitly before a promptless `read`, matching the Windows redirected-
    stdio workaround. Linux still needs its packaged retry flow rechecked.
  - Windows live-UI retest was reported fixed. `flutter analyze`,
    `git diff --check`, Dart formatting, and both relevant PowerShell parse
    checks passed; no hardware command was run by the agent. Linux/macOS
    post-fix packaged validation remains pending.
  - Minimum Linux/macOS closeout: rebuild with the normal platform packaging
    script, keep ST-LINK disconnected, and exercise both Check protection and
    Unlock / rescue. Confirm the red failure callout is stable across repeated
    Retry presses, Retry resumes the waiting process, and Dismiss returns to
    idle. Never test rescue with a reachable target unless a destructive mass
    erase is explicitly intended. Record completed platform results in
    `docs/testing.md`.
  - macOS live-UI retest after the explicit Bash prompt fix was reported
    fixed. Linux handoff: its Flutter-native `rdp_check.sh` and
    `rescue_unlock.sh` still use `read -p`, so apply the same explicit
    `echo` followed by promptless `read` before packaged testing. Add
    redirected-stdio coverage for both verbs, then rebuild normally and repeat
    the disconnected-ST-LINK Retry/Dismiss checks above. Do not exercise rescue
    with a reachable target.
  - Linux code handoff completed: both Flutter-native scripts now print the
    retry prompt before a promptless `read`. The redirected-stdio runner test
    covers Check and Rescue with fake OpenOCD, observes the prompt while the
    process waits, sends Continue, and passes. `bash -n`, ShellCheck error
    checks, `flutter analyze`, `git diff --check`, the focused test, and the
    normal AppImage build passed; the generated AppImage contains both updated
    executable scripts. The disconnected-ST-LINK packaged live-UI
    Retry/Dismiss check remains pending and is not recorded as hardware
    validation.
  - Linux live-UI follow-up: the maintainer checked the corrected debug build
    with ST-LINK disconnected and reported the retry failure flow fixed. This
    closes the Linux debug-build behavior check without exercising a protection
    rewrite. The generated AppImage was not used for that live check, so a
    packaged smoke remains optional rather than claimed complete.

## 2026-07-28

- Added GUI auto-retry ("the third hand") for v1.2.1. On a failure screen the
  Retry button counts itself down and presses itself, so a lost SWD / C45
  contact can be recovered without letting go of the probe. Planning notes and
  the full rationale live in `docs/plan-retry.md`.
  - Settings gained an `Auto-retry` stepper (0-10 s, ship default 3, `0` shows
    `off` and restores the previous manual-only behavior exactly). Same
    session-value plus persisted-startup-default plumbing as `Hold countdown`.
  - Bounded at 10 attempts, counted rather than timed: a retry re-runs the
    action, so attempt duration varies by mode and by the pre-connect countdown.
    A wall-clock bound would give a different number of attempts per mode with
    nothing on screen showing the remaining budget.
  - While armed the primary button is an inert `Retrying in N...  (k of 10)`
    readout and `Dismiss` is the live control. Enter no longer fires the primary
    on the fail stage while armed, matching the existing rule that running
    stages ignore Enter.
  - Armed from one place: the `StageState.fail` transition inside `_set()` in
    `lib/app_controller.dart`. No action code path knows the feature exists.
  - Nothing about the run is special-cased. The automatic press calls the same
    `retry()` the button calls, including replaying the pre-connect countdown.
    A real press is treated as fresh intent and restarts the attempt budget.
  - Eligibility gate, which is the only real logic here: auto-retry arms only
    when the run never got past connect. `lastConnect` cannot be used for this
    because `_finishReal` overwrites it with `FAIL` on any failure, so a sticky
    per-run `_sawTargetProgress` flag carries the fact instead (named
    `_sawTargetHalted` and keyed on that one line until it was widened on
    2026-07-29, below). Also excluded:
    validation/policy failures, `_failCannotRun` (nothing launched, so a retry
    cannot help), `rdp_check` and `rdp_rescue` (a stdin prompt is not a re-run
    and needs its own pass), and Power-race, which has its own respawn loop and
    by construction never reaches the fail state on a failed connect.
  - Scope note: an earlier draft limited this to the four Standard actions and
    modes A/B. That narrowing was a budget decision, and hooking the fail state
    removed the budget argument, so the action and mode filters collapsed into
    the two exclusions above. Advanced `flash_only` / `flash_slot0` are in
    scope; a failed connect writes nothing there either.
  - `flutter analyze` clean, 146 tests pass, `git diff --check` clean. New
    focused tests in `x3utils_flutter/test/auto_retry_test.dart` cover arming on
    a connect failure, declining after `target halted`, `0` disabling it,
    Power-race, and Dismiss disarming.
  - Test-writing trap worth remembering: constructing `AppController` WITHOUT an
    injected runner makes it find the real bundled OpenOCD, and `start()` then
    drives whatever hardware is attached. One throwaway probe did exactly that
    during this work (read-only check, nothing written). Unit tests must always
    inject a scripted runner; the `_cannotRun` guard is deliberately left
    untested for this reason.
- Maintainer hardware results on Windows, mode A (Default SWD):
  - Auto-retry recovered a real failure end to end: the loop was running, the
    ST-LINK was plugged in and the SWD contact re-seated mid-loop, and the run
    passed without a click.
  - Both failure texts are treated alike and should be: `open failed` means the
    adapter never enumerated, `init mode failed` means the adapter is fine and
    the target is not answering. Neither got past connect, neither writes
    anything, and both are fixed by the operator's hands.
  - The 10-attempt cap was observed stopping the loop and handing back the
    manual Retry.
  - `Auto-retry = 0` confirmed to restore the plain manual prompt.
  - The eligibility gate was confirmed twice with auto-retry set to 3: pulling
    the cable mid-dump, after `target halted`, correctly did NOT arm a retry.
    One of the two died between `flash probe` and the first block, so a run that
    had connected but written nothing at all still correctly declined.
- Parked (not implemented): invalid-backup handling for the plain Backup action.
  - Failed dumps leave a file in the backup folder with normal timestamped
    naming. Observed sizes from the tests above were 32768 and 0 bytes,
    alongside a genuine 131072-byte backup. The app called both runs failed; it
    just leaves the evidence looking legitimate.
  - This matters more than the file size suggests: identity lives at 0x1F000,
    the last 4 KB, so a truncated dump can never contain it. A partial backup is
    not a degraded backup, it is not a backup.
  - Agreed direction: dump to `<name>.bin.part` and rename to `.bin` only after
    validation passes, so a failed read can never occupy a real backup name and
    cannot be offered by a `.bin` file picker. Then warn the user explicitly and
    offer to move the invalid file to the OS trash.
  - Maintainer decision: NO real deletion. Move to the recycle bin / trash.
    Per-OS mechanism: PowerShell `Microsoft.VisualBasic.FileIO.FileSystem`
    `SendToRecycleBin` on Windows (the Windows build already shells out to
    PowerShell for `rdp.ps1`), the freedesktop `~/.local/share/Trash` spec plus
    a `.trashinfo` file on Linux, and a `~/.Trash` move on macOS. Avoid the
    Finder `osascript` route on macOS because it trips the automation
    permission prompt. If the trash move fails, fail closed: leave the `.part`
    file, say where it is, and never fall back to a hard delete.
  - Two verdicts, not one: a wrong-size file is an incomplete read and is
    worthless. A full-size all-zeros dump is the FAP / readout-protection
    signature, is valid evidence, and must NOT inherit the "invalid, bin it?"
    flow; it should point at RDP check instead.
- Pre-existing cosmetic bug noticed while reading dump logs: a failed Backup
  reports `OpenOCD: connection check failed`. In `_openOcdExitFallback` the
  `flash probe` branch is tested before the `dump_image` branch and dump args
  contain both, so a failed dump gets the check-connection wording instead of
  "dump did not complete". Unrelated to auto-retry.
- Mode B (C45 Clone) interaction with auto-retry, decided and CLOSED: an
  automatic Retry in the guided mode lands back on `Hold C45 -> GND` and waits
  for the human "I'm holding - continue" press, so the loop parks at attempt 1
  and the feature cannot save the round trip there. Auto-pressing Continue was
  rejected outright: that press asserts a physical fact (the contact is being
  held) that no timer can know, which is the same line the project drew when it
  removed simulation. Adding a mode-B exclusion was considered and REJECTED by
  the maintainer: the Auto-retry setting already lets anyone turn it off, so the
  behavior stays as-is. Do not "fix" this by excluding mode B.
- Further auto-retry test results and open items (2026-07-28, Windows):
  - `flash_only` and `flash_slot0` confirmed working with auto-retry, as
    intended: they are Advanced actions but a failed connect writes nothing.
  - Power-race has NO reachable armable failure, so "auto-retry must not fire in
    mode D" cannot be tested by producing one. A failed connect there becomes
    attempt N+1 instead of a fail state, Cancel goes to idle, RDP in Power-race
    is `StageState.warn` ("Not supported") rather than fail, and a post-catch
    failure has already seen `target halted` so the sticky gate declines anyway.
    The observable check is the absence: hammering with a climbing attempt
    counter and no red screen. The mode exclusion is belt and braces over a
    state that does not occur.
  - RDP exclusion revisited. It was never a safety verdict, only "different
    mechanism, not yet thought through". On review `rdp_check` is a good
    candidate and arguably a better fit than the OpenOCD path: when the script
    is still waiting on stdin, `retry()` writes a newline to the live process
    instead of restarting anything, `sendContinue()` already returns false once
    the process has moved on, and the action is read-only. `rdp_rescue` should
    stay manual on one specific ground: it is the mass-erase tool, so an
    automatic press resumes an irreversible erase the moment contact returns
    with nobody at the laptop. Everywhere else regaining contact only repeats a
    read or a re-connect. Maintainer decision: LEAVE AS-IS for now, both still
    excluded. If this is revisited, first confirm whether `rdp.ps1` ever prints
    `target halted`, because that would set the sticky flag and block auto-retry
    on the RDP path regardless of the action gate.
  - Not yet exercised on hardware: the 10-attempt cap followed by a manual Retry
    restarting the budget, Dismiss during a countdown, Enter while armed (must
    do nothing), and setting Auto-retry to 0 while a countdown is running (must
    disarm immediately). The RDP actions have also not been checked for the
    plain-Retry-no-countdown behavior the exclusion promises.

## 2026-07-29

- Implemented the parked invalid-backup handling from 2026-07-28. A failed read
  can no longer occupy a real backup name.
  - Every dump now writes to `<name>.bin.part` and is renamed to `.bin` only
    after it passes inspection. Applied to all three read sites: Backup, the
    mandatory pre-flash backup, and the SHU-compat raw read. A `.part` file is
    invisible to a `.bin` file picker, which was the point: identity lives at
    0x1F000 in the last 4 KB, so a truncated dump can never hold it. A partial
    backup is not a degraded backup, it is not a backup.
  - Two verdicts, as agreed. `Firmware.inspectDump` replaces `Firmware.validate`
    on these paths and returns `ok` / `missing` / `incomplete` / `masked` /
    `blank` / `uniform`. Junk is incomplete, or a repeated byte that is not the
    protection signature. A full-size all-`0x00` read is the FAP signature and a
    full-size all-`0xFF` read is an erased chip: both are complete, correct
    reads, and the message points at Check protection rather than at the wiring.
  - Maintainer decision on the evidence file: it keeps the `.part` name. One
    rule — nothing that failed inspection ever gets a `.bin` name — beats a
    filename that asserts a diagnosis. The verdict lives in the message and the
    log.
  - REVERSES the 2026-07-28 rule that a masked read "must NOT inherit the
    invalid, bin it? flow". It now gets the same offer, decided after seeing the
    screen on a real FAP'd board. The reasoning that changed it: the evidence is
    the finding, and the finding is already on screen and in the log — 128 KB of
    zeros cannot be diffed, flashed, or sliced, so keeping the bytes proves
    nothing the log does not, and they accumulate one file per attempt. What
    survives from the original rule is the part that mattered: the dialog must
    never imply the read failed. `DumpCheck.isEvidence` now picks the WORDING
    instead of gating the offer — "This read is a finding, not a backup" versus
    "This file is not a backup". Do not re-derive the old behavior from the
    2026-07-28 entry.
  - The offer is a modal (maintainer's choice over an extra pill on the fail
    screen). The red failure screen is shown first, then the dialog explains the
    verdict, shows the path, and offers `Keep it` / `Move to Recycle Bin`.
  - `lib/engine/trash.dart` is new and has no hard-delete path at all.
    Windows shells to PowerShell `Microsoft.VisualBasic.FileIO.FileSystem`
    `SendToRecycleBin`; Linux writes the freedesktop `~/.local/share/Trash`
    `files/` + `info/*.trashinfo` pair; macOS moves into `~/.Trash` (the Finder
    `osascript` route is avoided because it trips the automation prompt).
    Cross-filesystem moves fall back to verified copy-then-remove — the copy's
    length is checked before the original goes. If anything fails, the file is
    left where it is and the screen says so.
  - Coverage the DEVLOG entry did not anticipate: OpenOCD can also fail *during*
    the dump, before validation is ever reached — that is the 0-byte and 32768-
    byte case from the auto-retry tests. Those paths now run the same cleanup
    offer, so the file is never silently abandoned. A cancelled run logs the
    leftover path rather than prompting.
  - The offer is suppressed while auto-retry is armed. A modal in front of an
    operator with both hands on the probe is the one thing the third hand exists
    to avoid. In practice this branch is unreachable: an armed retry means the
    run never connected, and a run that never connected wrote no file.
  - The `{}`/non-ASCII path guard that `Firmware.validate` applied to dump
    output would have been lost in the switch to `inspectDump`. It is now
    `Firmware.validateOpenOcdPath`, shared by both, and checked on the staging
    path BEFORE the run — a backup folder OpenOCD cannot write to now fails
    while nothing has happened yet, instead of after a wasted read.
  - Fixed the cosmetic `_openOcdExitFallback` ordering bug noted on 2026-07-28:
    dump/flash command lines also contain `flash probe`, so the probe branch has
    to be tested last or every failed dump reports "connection check failed".
  - `flutter analyze` clean, `dart format` applied, 160 tests pass (14 new in
    `test/backup_validation_test.dart`: the six verdicts, staging/promote, and
    controller-level runs proving a good read is promoted, a short read is
    offered and left alone when declined, a masked read is offered with the
    finding wording and the `Dismiss` label, a failed connect writes nothing,
    and an invalid pre-flash backup aborts the flash). The trash move itself is
    stubbed in tests — a unit test must not put files in the real Recycle Bin.
  - Verified outside the test suite on Windows: the exact PowerShell recycle
    one-liner, including apostrophe quoting, on a scratch file. Exit 0 and the
    file left its path. Linux and macOS trash moves are code-reviewed only and
    still need a real run.
  - Not covered and deliberately unchanged: `Firmware.validate` still guards
    firmware inputs on the flash side; only the dump-output paths moved to the
    new verdicts.
  - Settings: the `Backups` section header was removed. The section already sits
    between two dividers, so the header was redundant and everything moved up.
- Maintainer hardware result, Windows mode A, same day: the contact was pulled
  mid-dump after `target halted`, OpenOCD exited 1 with 28672 of 131072 bytes,
  the file stayed `.bin.part` with no `.bin` created, the modal named the
  shortfall, and `Move to Recycle Bin` cleared it. Recorded in `docs/testing.md`.
  - Two wording bugs the live run exposed, both fixed: the success log line read
    `moved to the recycle bin → <source path>`, which reads as a destination —
    Windows recycles through the shell and reports no destination path, so it
    now logs `<source> → moved to the Recycle Bin` and only prints a real
    destination on Linux/macOS, where there is one. The result note also said
    "recycle bin" in lower case (`Trash.label.toLowerCase()`) and called the
    file "incomplete" even for the repeated-byte verdict; it is now "The dump
    was moved to the Recycle Bin", matching the button's capitalisation.
- Maintainer hardware result, Windows mode A, on a deliberately FAP'd board
  (CLI `rdp.ps1 -Enable`): Backup read 131072 bytes of zeros, exit 0. The
  masked path behaved as designed — `.part` kept, no `.bin`, the message named
  the protection signature and pointed at Check protection, and the console
  logged `chip finding, file left at →`. The offer then appeared with the
  finding title and the move succeeded. This is the run that settled the
  reversal above. Recorded in `docs/testing.md`.
  - Failure-screen button: a chip verdict is not a rejected input, so
    "Back to setup" was wrong — there is nothing in setup to change. `_finishReal`
    gained a `finding` flag beside `reseat`, set from `DumpCheck.isEvidence` at
    all three validation sites, and `failurePrimaryLabel` returns `Dismiss` for
    it. This also fixes a case not yet seen on hardware: a masked chip during
    Backup + Flash would have said "Change firmware", blaming a file that was
    never the problem.
  - Still uncovered on hardware: `Keep it`, the pre-flash-backup abort, the
    all-`0xFF` blank verdict (free to test right after a rescue mass erase,
    before reflashing), and the Linux/macOS trash moves.
- Linux and macOS closed out the same day, after the commit: the maintainer
  reported no behavioral difference from the Windows runs — staged `.bin.part`,
  no `.bin`, the cleanup modal, and the trash move. That is the first real
  exercise of the freedesktop `info/*.trashinfo` path and of the `~/.Trash`
  move; both were code-reviewed only until then. No per-run figures were
  captured. Linux also restored the board from a `.bin` afterwards and passed.
  - Those two boards read back all zeros with FAP reported NOT enabled, i.e. an
    empty chip, not a masked one. Worth knowing because `inspectDump` keys on
    the byte pattern alone: an all-zero image gets the `masked` verdict and the
    "readout-protection signature" message regardless of the actual protection
    state. The message therefore names a cause the bytes cannot fully prove. It
    is left as-is for now — `Check protection` is exactly where it sends the
    operator, and that tool reads the FAP byte and settles it.
- Widened the auto-retry eligibility gate from `target halted` alone to ANY
  evidence that the run got past connect. `_sawTargetHalted` is now
  `_sawTargetProgress`.
  - Why: the old gate rested on one string from one cfg path. A cfg reword, or
    a flow that reaches flash without reprinting the halt line, would have made
    an erase or write failure eligible for an unattended repeat. That second
    case is not hypothetical — `runRace` already compensates for it, because on
    the 2-catch backup+flash and SHU flows the core is ALREADY halted from the
    first catch and the line is not printed again.
  - The gate now also trips on the guided `Ready to flash.` banner, the flash
    bank probe, and the operation markers `dumped` / `erased` / `wrote` /
    `written` / `verified`. These are objective: they mean the chip was reached
    and an operation may have started, whatever the connect log said.
  - One vocabulary, not three. `hasTargetProgressEvidence()` now lives in
    `lib/engine/openocd_runner.dart` beside the existing `OpenOcdEvidence`
    regexes, and both `_advanceOpenOcdStage` and the retry gate call it. There
    were three near-identical copies of this marker list before.
  - THE REASON THIS MATTERED, found while checking the widening against the
    other platforms: the old one-string gate was INERT ON macOS. The 2026-07-21
    macOS CLI issue in `docs/testing.md` is the proof — Linux OEM OpenOCD
    prints `target halted`, but the bundled xPack build at `-d0` does not, which
    is why mode-D grading had to move to flash-bank/FAP evidence. The GUI hits
    exactly that combination: `native/macos/oocd/bin/openocd` is a `cafebabe`
    universal binary whose two slices are byte-for-byte the sizes of the two
    `xpack-openocd-0.12.0-7-darwin-*` CLI builds, and `_base()` in
    `openocd_runner.dart` always passes `-d0`. So on macOS `_sawTargetHalted`
    would never have been set, and a run that connected and then failed
    mid-erase or mid-write would have been ELIGIBLE for an unattended repeat —
    the precise thing the gate exists to prevent.
  - Caught pre-release: auto-retry landed 2026-07-28 for v1.2.1, the tree is
    `1.2.1+7`, and the newest tag is `gui-v1.2.0`. No shipped build carried the
    inert gate. Nothing to warn users about.
  - Second half of the same hole: the probe marker was the literal
    `flash 'at32f415xx' found`, but macOS declares the bank with the `artery`
    driver (`native/macos/oocd/scripts/target/artery/*.cfg`), so that marker
    never matched there either — in the retry gate AND in the live progress
    surface. It is now driver-agnostic, `flash '<any>' found`. The macOS CLI
    mode-D entry from 2026-07-21 already recorded `flash 'artery' found` as the
    expected evidence; the GUI had not picked that up.
  - Generalise from this: a marker set validated on Windows is not validated.
    The three GUI platforms bundle different OpenOCD builds with different
    output, and `-d0` is quiet. Prefer several independent markers over one
    canonical line, and prefer the operation's own evidence over the
    connect banner.
  - The copies also used substring `contains` where the engine already had
    word-boundary regexes (`\bdumped\b` and friends). The shared predicate
    reuses those.
  - Regression the widening introduced and that is now fixed — worth reading
    before adding any marker: `run()` echoes its own command line
    (`> openocd <args>`) into the SAME stream the line handler parses, and
    those args carry the user's backup and firmware paths. A backup folder
    named `verified`, `dumped`, or `erased` therefore matched the new markers
    on line 1, before OpenOCD had started, and auto-retry would have been
    silently disarmed for that user on every run. Verified: all three paths
    return true from the predicate. `_onRealLine` now derives `fromTarget`
    (`!clean.startsWith('> ')`) and gates both the sticky flag and
    `_advanceOpenOcdStage` on it — the RDP runner echoes the same way
    (`> powershell rdp.ps1 …`, `> bash …`). It failed safe rather than
    dangerous, but it was invisible, which is worse to diagnose.
  - Same family as the `_openOcdExitFallback` ordering bug fixed above: the
    command line looks like output. Any future check on this stream must ask
    whether it is reading target output or the echo of our own arguments.
  - Answers the RDP open question left above: `rdp.ps1` output IS routed
    through `_onRealLine` (`driveOpenOcdProgress: false`, but the sticky flag
    still sets), and the script does print OpenOCD's text to stdout. So if the
    `rdp_check` / `rdp_rescue` exclusions are ever lifted, the sticky gate
    blocks auto-retry after contact on that path anyway. Code-read, not
    hardware-checked.
  - Tests: `test/auto_retry_test.dart` is 20 tests, up from 5. New coverage for
    every past-connect marker (both driver spellings), the three echoed-path
    regression cases above, the countdown actually firing a re-run, the
    10-attempt cap, a manual Retry restarting the budget, and setting
    Auto-retry to 0 mid-countdown disarming it. That is unit
    coverage for four of the items listed as "not yet exercised" on 2026-07-28
    — it does not replace the hardware pass, and Enter-while-armed is still
    uncovered.
  - Honest limit on the two new RDP tests: they pass vacuously. With an
    injected runner `_rdp` is null, so `_runRdp` fails at the availability
    check before anything could arm a timer, and the `actionId` guard in
    `_autoRetryEligible` is never reached. They pin "a protection failure
    leaves no countdown running" and assert the OpenOCD runner was never
    called; the guard itself stays untested by design, since no code path
    reaches `_finishReal` with an `rdp_*` action.
  - `flutter analyze` clean, 163 tests pass. No hardware run.
- Non-ASCII path guard: diagnosis and decisions. Nothing implemented — this
  entry exists so neither the diagnosis nor the reasoning is re-derived.
  - THE GUARD HAS A FOUNDING CASE, and it had never been written down, which is
    exactly why a re-check of the backup-validation commit read it as inherited
    superstition and came close to recommending it away. A shared dump in the
    private corpus, `MEMORY_G3_<serial>_1.5.4.bin`, carries U+0421 CYRILLIC
    CAPITAL LETTER ES inside what reads as a plain ASCII serial. It is a
    homoglyph of Latin C, invisible in every font, and OpenOCD could not open
    the file. Record founding cases here, not in anyone's head.
  - Mechanism, measured on the Windows box with the bundled
    `x3utils_win/oocd/bin/openocd.exe` and no hardware — `openocd -f <cfg> -c exit`
    against directories with different names. OpenOCD is a mingw build and its
    CRT converts `argv` from UTF-16 down to the system ANSI codepage before
    `main()` runs. The console `chcp` is irrelevant; the registry ACP applies,
    and that machine is ACP 1253 (Greek). `Pruefung` LOADED, `Δοκιμή` LOADED,
    `Prüfung` FAILED, the Cyrillic name FAILED, a name carrying U+200E FAILED.
  - So the real constraint is "representable in THIS PC's ANSI codepage", which
    differs per machine: Greek paths work on a Greek Windows and fail on a
    German one, umlauts the reverse. The blanket ASCII rule is therefore a
    deliberate locale-independent SAFE SUPERSET. Do not narrow it into a
    per-codepage test.
  - The umlaut row is the dangerous one. `ü` did not become `?` — it best-fit
    mapped to `u`, i.e. a VALID but different path. It failed only because no
    `Prufung` directory existed. Had one existed, OpenOCD would have opened the
    wrong file, and for a dump destination that means writing a backup where
    the app never looks. Loud in practice, silently wrong in principle.
  - Linux and macOS have no ANSI codepage: POSIX paths are opaque bytes, `argv`
    is unconverted, locales are UTF-8. Measured at that layer under WSL — six
    path shapes including `Jörg/Documents/x3utils/backup` all opened, and the
    bytes on disk are raw UTF-8 (`303 274` for `ü`). The bundled Linux OpenOCD
    imports no `iconv` or `wcstombs`; its only locale symbol is `mbstowcs`,
    which is jimtcl string handling, not path handling. The binary itself could
    not be run there (that WSL lacks `libhidapi-hidraw.so.0`), so this is the
    layer proven, not the binary. The maintainer also recalls testing non-ASCII
    paths OK on Linux/macOS; that cannot have gone through the GUI, since the
    guard refuses before OpenOCD launches, so it was the CLI or raw OpenOCD.
    Ten-second probe that would turn it into a `docs/testing.md` row:
    `openocd -f /tmp/Prüfung/probe.cfg -c exit`.
  - Neither Unix CLI has ever carried the check — `validate_bin.sh` rejects
    `{}` and nothing else — and the Windows CLI has no path-character check at
    all. The rule exists in exactly one of the four codebases, the GUI, ported
    from the old C# `FirmwareValidator.cs`. That is consistent with German
    users never complaining: on their own CP1252 machine `C:\Users\Jörg` is
    representable, so OpenOCD handles it, and the GUI blocked it as collateral.
  - Corpus pattern behind the founding case: the characters arrive from other
    people's keyboards. Alongside the Cyrillic dump the private corpus holds a
    German `für` package name and four community packages carrying `⚡`,
    mathematical-bold-italic letters, and a zero-width U+200E. By the time such
    a file reaches a German or Greek user's disk the character is unseeable, so
    "ask users to rename their files" cannot reach this failure.
  - AN EXTERNAL `openocd.exe.manifest` DECLARING `activeCodePage` UTF-8 DOES
    FIX IT — retested on a scratchpad copy of the bundled binary, and both
    `Prüfung` and the founding Cyrillic name loaded. RECORDED AS MECHANISM
    PROOF AND DELIBERATELY NOT ADOPTED. Do not resurrect it as the fix. It is a
    process-wide behaviour change rather than a path fix, covering every
    narrow-char API in OpenOCD/jimtcl under an ACP upstream never tested; an
    external manifest stops applying, silently, if a future OpenOCD build
    embeds its own; it needs Win10 1903+, silently; it is a loose file beside an
    exe that antivirus or a careless zip can remove, silently; and it is
    invisible to the next reader, who might drop the guard because it exists.
    Three silent failure modes is the wrong trade for a tool whose value is not
    bricking controllers.
  - DECISION: the non-ASCII half of `Firmware.validateOpenOcdPath` becomes
    Windows-only. The brace check stays unconditional on every platform — `{}`
    is Tcl quoting syntax and breaks everywhere. This is not a policy change:
    `AGENTS.md` already reads "On Windows, keep the non-ASCII path guard", and
    the function's own doc comment already scopes it to the bundled Windows
    build. The code was simply stricter than the rule it implements. No test
    asserts the rejection today, so nothing breaks.
  - One expectation moves with it: `tool/gen_test_bins.dart` emits a `Prüfung/`
    case whose manifest verdict is "reject non-ASCII path before OpenOCD
    starts". That becomes Windows-only, and per the standing rule about
    behaviour-pinning manifest rows it is updated in the same change.
  - Whatever Windows still refuses needs a message naming the offending
    character and its offset (`'С' U+0421 at position 15`). "Use English letters
    only" is unactionable when the name looks like English — precisely the
    founding case.
- x3utils ROOT FOLDER: replacing the "Backup folder" setting. DECIDED AND NOW
  BUILT — see the build note at the end of this entry. The driver is NOT the
  codepage issue, which only exposed it: "Backup folder choice was enough for
  the early GUI versions, now it's not."
  - What is actually wrong today. One run scatters across three trees — backup
    in the chosen folder, `compat/` and `logs/` hardcoded under
    `Documents/x3utils`, second copy in `%LOCALAPPDATA%` — so "send me your
    backup and the log" is two navigation paths. Only backups are settable at
    all. And `_dir()` joins `home + 'Documents'` literally instead of asking
    Windows where Documents is, so on a OneDrive-redirected machine the app
    writes to a different Documents than Explorer shows and the user finds
    nothing where they look. SHU compat is the sharpest case: it writes to the
    fixed `Documents/x3utils/compat`, so its "choose a different backup folder
    in Settings" message points at a setting it does not use.
  - One root, fixed subfolder names, no per-folder overrides. The subfolder set
    is unchanged: `backup/`, `compat/`, `unpacked_zip3/`, `packed_zip3/`,
    `logs/`.
  - Defaults: `C:\x3utils` on Windows, `~/x3utils` on Linux and macOS. The
    Windows root was ACL-checked — `C:\` grants Authenticated Users
    `CreateDirectories`, so a non-elevated user creates it with no UAC prompt.
    `~/x3utils` over `~/Documents/x3utils` for symmetry and visibility;
    `~/.local/share/x3utils` is the freedesktop-correct answer and the wrong one
    here, because users must be able to find these files and send them. Cloud
    sync agents (OneDrive, iCloud Desktop & Documents) are explicitly the user's
    problem, and both defaults sit outside Documents anyway.
  - This is the first real per-OS divergence in the main tree, which until now
    was uniformly `Documents/x3utils`. `_dir()` gains a branch, and `_homeLabel`
    stops fitting because it assumes a home-relative path and prefixes `~/`.
  - The second copy stays exactly as it is — `%LOCALAPPDATA%\x3utils_backup`,
    `~/.x3utils_backup`, `~/Library/Application Support/x3utils_backup`.
    Deliberately hidden, deliberately elsewhere, mirrors the CLI siblings, and
    written with Dart `copySync` rather than handed to OpenOCD. Do not fold it
    into the root.
  - New prefs key `x3utilsRoot`; `backupFolder` is never read again. That is
    ZERO migration code — an orphan key in the same store is inert. Rejected:
    a second prefs FILE beside the existing one, because the plugin offers no
    filename knob and macOS uses NSUserDefaults, so there is no json to sit
    beside; owning a settings file is a separate feature to judge on its own
    support merits, not a migration trick. Reusing the old value would also be
    WRONG rather than merely lazy: the same string means "where dumps go" as a
    backup folder and "the parent of backup/" as a root, so carrying it over
    would move a user's backups one directory level and scatter four new
    folders into a place picked for one purpose.
  - Never move files. On a root change or an upgrade, write to the new place
    and leave the old one alone; the user deals with it. Existing installs are
    not adopted. One release-note line is owed, since a user who deliberately
    pointed backups elsewhere goes quiet without warning.
  - Validate the root WHEN PICKED (writable, braces, ASCII on Windows).
    `setBackupFolder` currently stores whatever it is given with no check. Keep
    the pre-run destination check as the safety net; `AGENTS.md` pins it.
  - Settings label: "x3utils folder", not "root". The panel's voice is plain
    ("Backup folder", "Filename prefix", "Default location") and the audience is
    largely non-native English speakers, for whom "root" reads as the Linux root
    user. The precision belongs in the hint line under the path, naming what
    lands inside.
- Reversing the same-day "left as-is" call on the all-zero dump message. The
  `masked` verdict's wording will become neutral: all zeros may mean protection
  masking or an empty/unreadable target, with Check protection sent to
  distinguish them. Message only — refusing to promote, keeping it as evidence,
  `reseat: false` and the `Dismiss` button are all correct either way. Three
  places move together or the code still asserts what the message no longer
  does: the message, the `DumpVerdict.masked` doc comment, and the test's name
  (its assertion only checks for "Check protection" and still passes).
- Still open, unrelated to any of the above: `Firmware.promoteDump` swallows
  every rename failure and returns the unchanged `.part` path, and all three
  callers treat that as success. Backup then reports "Backed up and verified"
  with no `.bin`, and a guarded flash proceeds on a `.part` file. Low
  probability, but it is a wrong-success claim, which is the class the
  evidence-based verdicts exist to prevent. Fix is to return a result rather
  than a path and abort guarded writes when promotion failed.
- Agreed build order: scope the ASCII guard to Windows, then the root folder
  setting, then the all-zero message, then the promotion result.
- BUILT: the x3utils root folder, exactly as decided above. Taken out of order —
  the ASCII scoping is still open and unaffected, because the root check calls
  `validateOpenOcdPath` rather than restating the rule, so it inherits the
  Windows scoping whenever that lands.
  - `Firmware` gained the root: `defaultRoot` (`C:\x3utils` / `~/x3utils`),
    `root`, `setRoot`, `rootIsDefault`, `rootExists`, `validateRootFolder`.
    `_dir(sub)` now joins the root, and a non-creating `_path(sub)` sits under
    it so a UI label can never make a folder. `_homeLabel` is gone and the four
    `…DirLabel` getters return real absolute paths — with one root the panel can
    show and reveal the actual path instead of a hint standing in for one.
  - `newDumpPath` lost its `folder:` override; no caller passed one, and a
    per-call destination is exactly what the single root replaces. Both remaining
    dump destinations (`backup/`, and compat's explicit path) still go through
    `_stagedDumpPath`, so the pre-run check is unchanged and now — the point of
    the whole change — its "choose a different x3utils folder in Settings"
    message finally names a setting that governs compat too.
  - `AppController.backupFolder` → `x3utilsRoot`, prefs key `x3utilsRoot`,
    `setBackupFolder` → `setX3utilsRoot`, which also pushes the value into
    `Firmware`. `backupFolder` is not read anywhere; zero migration code, as
    decided. The root is process-wide static state in a class of statics; the
    controller owns pushing it, and the tests reset it in `tearDown`.
  - Settings panel: label "x3utils folder", the hint under the path names what
    lands inside (`backup · compat · unpacked_zip3 · packed_zip3 · logs`, plus
    "default location" while it is the default). A picked folder is validated on
    the spot — braces/non-ASCII plus a real write probe that is deleted again —
    and a refusal replaces the hint in red without changing the setting. Reveal
    is offered only once the root exists, since the subfolders are created by the
    first run that needs them, not by opening Settings.
  - Confirmed incidentally on this Windows box: `flutter test` created
    `C:\x3utils\unpacked_zip3` from a non-elevated process with no UAC prompt,
    which is the ACL claim above holding in practice rather than on paper.
  - 174 tests pass, `flutter analyze` clean. New `test/x3utils_root_test.dart`
    pins the parts a later change could quietly undo: all five outputs follow the
    root under fixed names, the 2nd copy stays outside it, blank restores the
    per-OS default, labels create nothing, and a stored `backupFolder` is NOT
    adopted as a root.
  - Version bumped to 1.2.2 (+8) with `dart run tool/version.dart 1.2.2`, so the
    root folder lands in GUI v1.2.2 and `backupFolder` is "v1.2.1 and earlier"
    as the code and AGENTS.md now say. All 7 places check in sync.
  - Owed at release: the one line warning that a user who deliberately pointed
    backups elsewhere is now writing to the new root. Not written yet — there is
    no changelog file, so it belongs in the v1.2.2 release notes.
  - Not covered by tests, so it needs eyes on the running app: the Browse/Reset
    row, the red refusal line, and Reveal.
  - HARDWARE PASS on the Windows testbed the same evening, and it found the one
    leak. Check connection, Backup, SHU compat (twice), Backup + Flash, guarded
    Flash slot 0 from a zip3 import, Check protection, and Make zip3 all wrote
    into `C:\x3utils` under the five expected subfolders, with the 2nd copy
    still in `%LOCALAPPDATA%`. The maintainer's prefs file also showed the
    migration decision working literally: an orphan `flutter.backupFolder`
    pointing at an old test dir sitting inert beside `flutter.x3utilsRoot`,
    which had been repointed to another drive (`I:\...`) through Browse.
  - THE LEAK, now fixed: the RDP toolkit wrote its own transcript outside the
    root — `Documents\x3utils\logs` on Windows (which is what kept re-creating
    that tree), the discarded temporary run tree on Linux/macOS. `RdpRunner` now
    passes `X3UTILS_RDP_LOG_DIR` through config.cmd / config.sh at
    `<root>/logs/rdp_check|rdp_rescue`. Only the bundled copies under
    `x3utils_flutter/native/` changed; the standalone CLIs log beside their own
    scripts, have no root setting, and must stay untouched.
  - The scripts now name their file `<prefix>_toolkit_<stamp>.log`, and that is
    NOT cosmetic. In the maintainer's run both logs were already
    `rdp_check_2026-07-29_17-10-25.log` — same basename, same second, saved only
    by being in different trees. Moving them into one folder without the suffix
    would have had one silently overwrite the other.
  - Which of the two to ask a user for: the CONSOLE log. Checked against real
    pairs afterwards — for a clean run the toolkit file is a strict subset of
    the console log, and on a 5-attempt retry run both hold all 5 attempts while
    the console log also has the header and the verdict. The toolkit file is
    also UTF-16LE. The one path where the script logs something the GUI does not
    show is Power-race (winning attempt only), and Power-race RDP is blocked
    before the script starts, so in the GUI it is unreachable. So the second
    file is redundant, not extra evidence — an earlier note here claimed the
    opposite. Kept anyway because it is what the script's own on-screen
    `Log file:` / `Full log:` lines name, and suppressing it would make those
    lines point at nothing useful. Rarely-used action, tiny files, not worth
    code churn.
  - Offline-verified only (details in `docs/testing.md`): `rdp.ps1` parses and
    its real config/log-path functions were run out of the shipped file, `bash -n`
    passes on both unix copies, but the unix RUNTIME path is uncovered because
    `rdp_runner_test.dart` no-ops on Windows — one Check protection run each is
    owed on Linux and macOS. Those tests now pin the root to their fixture, or
    they would write into the real x3utils folder.
  - NOTED FROM THE RUNNING APP, not fixed: the folder row wastes vertical space.
    `DesktopPathDisplay` is built for a long file path — leaf on the first line,
    parent dim underneath, plus the action button — so a root like `C:\x3utils`
    gets a tall two-line box ("x3utils" over "c:\") for eight characters, and it
    is now the largest block in Settings. The widget is right for run output
    where the filename is the point; the root is short by design and reads fine
    on one line. Left as is for now — a one-line variant for short directory
    paths is the obvious direction whenever the panel is next touched.
- HANDOFF — Linux and macOS, GUI v1.2.2. Windows is done (hardware sweep above
  plus the installer). What is untested off Windows: the x3utils root itself and
  the RDP toolkit log path. Both are per-OS by construction, so neither carries
  over from the Windows pass.
  - Build the real package, not a bare `flutter build`: Linux
    `tool/build_appimage.sh`, macOS `tool/package_macos.sh` (the plain build does
    not assemble a complete app). `package_macos.sh` refuses if VERSION,
    pubspec.yaml and theme.dart disagree — all three are 1.2.2.
  - Check the exec bits after the bundle is assembled. The standing gotcha is
    that the native bundle loses `+x`; `special/rdp/rdp_check.sh` in particular
    must be executable or Check protection dies before it can log anything.
  - ROOT: first launch shows `~/x3utils` with "default location" and NO
    `~/Documents/x3utils` is created. Run Backup → `~/x3utils/backup`, 2nd copy
    to `~/.x3utils_backup` (Linux) or `~/Library/Application Support/x3utils_backup`
    (macOS). Then Browse elsewhere, run again, and Reset. Nothing is ever moved.
  - RDP LOG (the actually-uncovered one): run Check protection in mode A (B or C
    is fine; Power-race RDP is blocked by design) and confirm BOTH files land in
    `~/x3utils/logs/rdp_check/` — the console log `rdp_check_<stamp>.log` and the
    toolkit's `rdp_check_toolkit_<stamp>.log`.
  - What failure looks like, so it is not misread as a pass: the `_toolkit` file
    MISSING while the console log is present means `X3UTILS_RDP_LOG_DIR` never
    reached the script and it logged into the temporary run tree, which is then
    deleted. That is the macOS risk specifically — config.sh is written at the
    temporary run root and the scripts load `../../config.sh`, so macOS is the
    one platform where the variable travels a different route than Linux's. A
    `Failed to create log directory` line means the root is not writable.
  - Worth capturing in the testing.md row: the paths from the console, and
    `ls ~/x3utils/logs/rdp_check`.
- LINUX v1.2.2 VALIDATED on the packaged AppImage, and the non-ASCII guard
  SCOPED TO WINDOWS. Rows in `docs/testing.md`.
  - The packaged sweep closed the Linux half of the handoff above: ten actions
    from `dist/x3utils-1.2.2-x86_64.AppImage`, all five subfolders under
    `~/x3utils`, 2nd copies outside it, no `~/Documents/x3utils` created, and
    both RDP logs in `~/x3utils/logs/rdp_check/`. The exec-bit gotcha did not
    bite: `rdp_check.sh` and `openocd` were `-rwxr-xr-x` inside the squashfs
    mount. `X3UTILS_RDP_LOG_DIR` reached the script even from that read-only
    mount, via the runner's temp-copy `config.sh`.
  - The `_toolkit` suffix has now been load-bearing three times out of three:
    every rdp_check pair recorded so far shares its second, on both platforms.
  - Correction to the entry above: the toolkit file is UTF-16LE on WINDOWS only.
    On Linux it is plain ASCII. The console log is still the one to ask a user
    for, for the other reason already given — it is the superset (1548 B vs
    592 B on the same run).
  - THE PROBE THE ENTRY ABOVE ASKED FOR, now run, so Linux is BINARY-proven
    rather than layer-proven. Bundled `native/linux/oocd/bin/openocd`, no
    hardware: `-f <dir>/probe.cfg` and a jimtcl `open`/`puts`/`close` write, both
    through four directory names — `Prüfung/` (German umlaut), `Δοκιμή/` (Greek),
    `MEMORY_G3_С45/` (the founding U+0421 Cyrillic homoglyph) and `zip⚡3/`
    (emoji). ALL EIGHT SUCCEEDED. Read and write, every shape the guard refused.
  - So the guard was refusing paths its own binary handles. DONE: the non-ASCII
    half of `Firmware.validateOpenOcdPath` is now `Platform.isWindows`-gated.
    Braces stay unconditional — Tcl quoting breaks everywhere. This is the step
    the "agreed build order" put first and the root-folder session took second;
    it is now closed.
  - HOW BAD IT WAS OFF WINDOWS, since this was under-rated as a cosmetic
    refusal. For a user whose home is `/home/Jörg`, the DEFAULT root
    `~/x3utils` carries the umlaut, so `_stagedDumpPath` refused Backup, SHU
    compat and Backup + Flash before OpenOCD started — and the message told them
    to pick another folder in Settings, where `validateRootFolder` refused every
    folder they own. A dead end out of the box. The guard also runs on the
    SOURCE file via `Firmware.validate`, so Flash Only, Flash slot 0 and the
    ZIP3 tools rejected anything under their home too.
  - Windows behaviour is byte-identical, message included, so the Windows
    hardware sweep and installer from earlier that day stay valid. The message
    wording is deliberately NOT changed here; it is Windows-only text and
    belongs with whichever Windows strategy lands (see OPEN below).
  - Noticed while tracing it: the v1.2.2 root change accidentally de-fanged this
    on Windows. The old default `Documents/x3utils` carried the username, so
    Jörg's dumps were blocked there too; `C:\x3utils` took the username out of
    the output path. On Linux/macOS `~/x3utils` still carries it, so the same
    commit left the guard lethal on exactly the two platforms where it has no
    technical basis.
  - `tool/gen_test_bins.dart` — the `Prüfung/` row's verdict is now scoped to
    Windows, per the standing rule that behaviour-pinning manifest rows move in
    the same change as the behaviour.
  - HARDWARE-CONFIRMED the same evening, which beats the offline probe: guarded
    Flash slot 0 took the `Prüfung/16a_slot_zt3_vcu_SYNTHETIC.bin` fixture and
    OpenOCD handled the umlaut path inside the brace-quoted `write_image erase`
    AND `verify_image` commands — wrote 59392 B (2 KB page rounding of 58436),
    verified 58436 B, exit 0. The probe only proved a jimtcl `open`; this is the
    real command path the app builds. Pre-flash backup, 2nd copy and the
    identity gate all behaved on the way through. Note the fixture is a
    synthetic unbootable payload, so the board needs a reflash afterwards — it
    exists to be SELECTED, and flashing it is not required to prove the gate.
  - 177 tests pass (was 174), `flutter analyze` clean. The three new ones sit
    beside the brace test in `x3utils_root_test.dart` and pin the two halves as
    SEPARATELY scoped, which is the thing a later cleanup would re-merge.
  - REJECTED, so it is not re-proposed: moving the Linux root to `/opt/x3utils`
    to dodge the username. `/opt` is `root:root` 755, so a normal user cannot
    create it, and the Linux artifact is an AppImage with no packaging step to
    do it for them. A run-once privileged setup script WOULD work — Linux
    already needs one by hand (udev rules, `libhidapi-hidraw0`, `plugdev`), so
    it is a net win on its own merits and is listed under OPEN below. But it
    cannot fix this bug: relocating the root fixes the destination half only,
    while firmware ARRIVES in the user's home directory, and the source-side
    check would still refuse it. macOS does have a real equivalent if it is ever
    wanted for its own sake — `/Users/Shared` is mode 1777 on every Mac and the
    app is unsandboxed by design — but the same limitation applies.
- macOS v1.2.2 VALIDATED, which closes the handoff above and makes v1.2.2 done
  on all three platforms. Rows in `docs/testing.md`. Two rounds on the Intel
  Mac: the dev tree first, then the packaged universal app run from
  `~/Desktop/x3utils.app`. Four actions — Check connection, Backup, guarded
  Flash slot 0, Check protection.
  - Both handoff items passed. The root behaved exactly as on Linux: `.bin.part`
    staged and promoted, two 131072-byte dumps under `~/x3utils/backup`, 2nd
    copies in `~/Library/Application Support/x3utils_backup`, logs under
    `~/x3utils/logs/`, and nothing new under `~/Documents/x3utils`.
  - The RDP log was the one flagged as a genuine macOS risk, because config.sh
    is written at the temporary run root and the scripts load `../../config.sh`,
    so `X3UTILS_RDP_LOG_DIR` travels a different route than on Linux. It did not
    bite: both files landed in `~/x3utils/logs/rdp_check/` from the PACKAGED
    bundle. The console log is 1603 B UTF-8, the toolkit file 622 B ASCII — so
    the UTF-16LE noted earlier is Windows-only, exactly as Linux found. Same
    stamp again; the `_toolkit` suffix has now been load-bearing four times out
    of four.
  - AUTO-RETRY's first hardware exercise on macOS, and it recovered: `open
    failed`, `auto-retry 1 of 10`, `open failed`, `auto-retry 2 of 10`, then a
    clean connect at the third attempt, no click. The dev round did the same
    once. It also correctly did not arm on any of the successful runs.
  - THE GATE-WIDENING REASONING IS NOW HARDWARE-PROVEN, not code-read. Every
    macOS log from this session prints `[at32f4x.cpu] halted due to
    debug-request` and never the literal `target halted`, and declares the bank
    as `flash 'artery' found` and never `at32f415xx`. Those are the two strings
    the pre-widening gate keyed on, so `_sawTargetHalted` really would have been
    inert here and a mid-erase failure really would have been eligible for an
    unattended repeat. The 2026-07-29 entry above inferred this from the binary
    slices and the 2026-07-21 CLI issue; this is the direct observation.
  - The Windows-scoped ASCII guard is hardware-confirmed on macOS too, the same
    way Linux confirmed it: guarded Flash slot 0 took the
    `Prüfung/16a_slot_zt3_vcu_SYNTHETIC.bin` fixture through the real
    brace-quoted `write_image erase` AND `verify_image` commands — wrote 58436 B
    in 21.6 s, verified 58436 B, exit 0, in both rounds. Note the figure differs
    from the Linux run, which reported `wrote 59392` (2 KB page rounding) for the
    same fixture while verifying the same 58436; only the wrote line differs, and
    both verified and exited 0. The identity gate passed on the way through.
    The fixture is a synthetic unbootable payload, so the board needs a reflash.
  - The offline four-path probe asked for in OPEN was also run, against both
    `native/macos/oocd/bin/openocd` and the packaged app's separate re-signed
    copy: `Prüfung/`, `Δοκιμή/`, `MEMORY_G3_С45/`, `zip⚡3/` plus an ASCII
    control, read and write, all ten checks passing each time. The hardware run
    above is the stronger evidence; the probe still earns its place because it
    covers the read path and the three shapes the fixture does not.
  - Exec bits survived packaging — the standing bundle gotcha did not bite on
    macOS either. `rdp_check.sh`, `rescue_unlock.sh`, `rdp_lib.sh` and
    `oocd/bin/openocd` are all `-rwxr-xr-x` inside the app, and the packaged
    `rdp_check.sh` is byte-identical to the source tree. `flutter analyze` clean
    and 177/177 tests pass on this Mac, matching the other two platforms.
  - EXTENDED THE SAME EVENING (20:30–20:36, packaged app), which closes the
    action gap the first pass left. Flash only restored the board from
    `zt3_vcu_rescue.bin` (erased, wrote and verified 131072 B, exit 0). SHU
    compat created `~/x3utils/compat/` for the first time on macOS — dump
    promoted, signature patched at `0x1420`, reflashed and verified — and its
    optional auto-zip3 correctly REFUSED for want of a trustworthy BLE
    firmware-length record, the same guard Linux hit, which is part of the pass.
    Full Backup + Flash matched identity and reflashed. macOS is now level with
    Linux on everything except the ZIP3 tools.
  - THE UMLAUT ROOT THROUGH SETTINGS, which is the half of the ASCII-guard bug
    that was still unproven anywhere. Linux confirmed the SOURCE side on
    hardware (firmware read out of a `Prüfung/` directory); this is the
    DESTINATION side, the one the entry above called "a dead end out of the box"
    because the default root carries the username and Settings then refused
    every folder the user owned. Browse accepted
    `…/gen_test_bins/Prüfung/x3utils` as the root, the Backup dumped and
    promoted into `Prüfung/x3utils/backup/`, and the log followed to
    `Prüfung/x3utils/logs/dump/`. The 2nd copy still went to
    `~/Library/Application Support/x3utils_backup`, outside the custom root,
    which is the invariant `x3utils_root_test.dart` pins.
  - macOS NORMALISATION, recorded so it is not re-derived: the stored pref is
    `flutter.x3utilsRoot = ".../Pru\U0308fung/x3utils"` — NFD, `u` + U+0308
    COMBINING DIAERESIS, not the NFC `ü` that was typed. The macOS file picker
    returns decomposed paths. Harmless here (OpenOCD took those bytes, and the
    `codeUnits > 127` guard catches either form), but any future code that
    COMPARES root paths as strings has to expect the two forms to be unequal
    while naming the same directory.
  - TESTBED STATE CHANGED, which affects later identity tests: the rescue image
    cleared the serial, so the board now reads `SCOOTER_VCU_xxU2 · serial:
    cleared` rather than its previous generic-replacement serial (model zt3),
    and guarded flashes now compare cleared against cleared.
  - FINISHED THE SWEEP at 20:43–20:44 with the ZIP3 tools, which created the
    last subfolder and put macOS at TEN ACTIONS, the same set Linux ran. Make
    zip3 from a full dump (source identity `SCOOTER_VCU_xxG3`, packed g3/VCU,
    60356 B), Make zip3 from a payload bin (`SCOOTER_MCU_0001`, slot bin, packed
    zt3/MCU, 59028 B), and Unpack zip3 (inspected then wrote zt3/VCU, 58460 B,
    matching the Linux figure). Three different model/component combinations
    with `enforceModel=true`, so the preselection logic was actually exercised
    rather than repeated. All three log into `logs/make_zip3/`, unpack included.
  - AND THE SETTINGS ROW IS FINALLY DONE, on macOS, after being carried past
    three sweeps on every platform. Browse was the umlaut root above; Reveal
    works; Reset REMOVES the `flutter.x3utilsRoot` key rather than writing the
    default path — worth knowing, because it means a future change to
    `defaultRoot` follows the user instead of being pinned by a stale stored
    string. That is the "blank restores the per-OS default" behaviour
    `x3utils_root_test.dart` pins, now seen in the real prefs file.
  - The brace half was confirmed live too, on the Flash Only screen: `Path
    contains an unsupported character: { or }.`, file rejected, field left at
    "No firmware chosen". Put beside the accepted `Prüfung` root, that is the
    running macOS app demonstrating what the three new tests assert — the two
    halves of `validateOpenOcdPath` are SEPARATELY scoped. Non-ASCII accepted
    off Windows, braces refused everywhere. This is the specific thing a later
    cleanup would re-merge, and it now has UI evidence, not just unit tests.
  - HONEST SCOPE after all three passes. No row on file for the `Keep it` branch
    of the cleanup modal, the pre-flash-backup abort, the all-`0xFF` blank
    verdict, or the red refusal line in Settings. READ THAT AS "NOT WRITTEN
    DOWN", NOT "NOT TESTED" — the maintainer reports having exercised `Keep it`
    and restored from a `.bin` before this session. This is a hobby project and
    its notes are a maintainer's log, not a QA matrix; earlier drafts of these
    rows kept converting a missing row into a claimed gap, which is an inference
    the evidence does not support and which puts invented work on someone's
    plate. Gatekeeper is the one item genuinely established as unobserved, and
    only because the testbed's own configuration proves it. No `.bin.part`
    orphan was left anywhere by any pass.
  - Existing-package collision, checked at 20:52 by re-running the zt3/MCU pack
    onto its own output: the dialog named the exact path and warned that Replace
    permanently overwrites, Cancel was taken, and the existing file was verified
    UNTOUCHED at the filesystem level — same 59484 B, same 20:44:22 mtime — with
    `make zip3 cancelled: existing package kept` in the log. The v1.2.0 rows
    covered this on the old layout; this is the first check of it inside the
    v1.2.2 root, where the destination is `<root>/packed_zip3` rather than a
    fixed Documents path.
  - STANDING RULE, worth stating once because a first draft of these rows got
    both halves wrong in opposite directions: full serials do NOT go into the
    public markdown under `docs/`. Describe them — "generic replacement",
    "non-generic", "cleared", or the prefix if the prefix is the point — and
    leave the digits in the logs. Separately, a serial being non-generic is NOT
    evidence that the device is real: corpus serials may be synthetic, and only
    the prefix is known to carry meaning at this point. The first draft
    published one serial and withheld another, each for a reason that does not
    survive this rule. Before committing docs, grep the diff for serial-shaped
    strings.
  - The rule is about serials that identify a DEVICE, and the existing DEVLOG
    text is consistent with it, which is worth spelling out so nobody scrubs the
    wrong thing. `1K1E0000000001` and `1CGC0000000001` already appear in this
    file at the v1.5.5 layout and identity-gate entries, deliberately: they are
    the published FACTORY serials of generic replacement boards and are hard-
    coded in the app as `kGenericSerials`. A constant that means "this board has
    no individual identity" is documentation, not disclosure. What must not land
    here is a serial read out of somebody's dump.
  - GATEKEEPER IS A HOLE, and the reason it went unnoticed is that the testbed
    hides it. The app is ad-hoc signed and not notarized (`Signature=adhoc`,
    `TeamIdentifier=not set`; `package_macos.sh` signs with `-` and never
    notarizes), the tested app carried no `com.apple.quarantine` because the zip
    was made and unzipped locally, and this Mac reports `spctl --status` =
    assessments disabled, so `spctl -a` returns `accepted (override=security
    disabled)`. No macOS row on this project says anything about first launch.
    The 2026-07-01 entry above judging unsigned distribution viable because
    "the only friction is the Gatekeeper open anyway step" was formed on this
    same machine and inherits the same blind spot — treat it as an assumption,
    not a measurement. Procedure and the macOS 15 caveat are in
    `docs/testing.md`.
  - Incidental, and the same as the Windows note: `flutter test` creates a real
    `~/x3utils/unpacked_zip3` in the user's actual root. Harmless and empty, but
    it is the suite writing outside its fixtures, and it is now confirmed on two
    platforms.

## 2026-07-30

- HANDOFF TO THE WINDOWS BOX. NOTHING IN THIS ENTRY WAS MEASURED. It is code
  reading and design discussion done on the Linux machine, so every claim about
  Windows behaviour below is inference from the source plus the probes already
  recorded on 2026-07-29 and 2026-07-30. Marked here so no later reader mistakes
  it for a validation result. Written as work items with the reasoning attached,
  NOT as a checklist — that framing is what left the ASCII scoping unstarted for
  two sessions.
- DECISION: ASCII STAGING, IN BOTH DIRECTIONS. This closes the four-way choice
  left open under `WINDOWS non-ASCII strategy`; that item now carries only its
  measured probe data and the work list.
  - What it is: OpenOCD is never handed a user-chosen path again. A flash input
    is copied to a fixed ASCII staging path, the copy's digest is compared
    against the source, and only the staging path goes into `argv`. A dump is
    written by OpenOCD to a staging path and MOVED to the user's destination by
    the app afterwards. Dart's file APIs use the wide Win32 calls, so the app
    can read and write any path the user can create; only OpenOCD's `argv`
    cannot survive the trip.
  - Why not (a), the ACP round-trip via `WideCharToMultiByte`. It is correct —
    it accepts exactly what this PC's codepage can represent, which is the real
    constraint — but its correctness is per-machine. `Jörg` on a German box is
    helped; `Jörg` on the Greek box is still refused, correctly, and still has
    no way to flash a file out of his own Downloads. It broadens acceptance
    where the machine happens to allow it instead of removing the dependency.
    Keep it on file as the fallback if staging turns out to be impossible, not
    as the plan.
  - (b), exempting characters that occur in `%USERPROFILE%`, is DROPPED, not
    deferred. It infers representability from "Windows created this path", which
    is not a guarantee: an account whose profile directory is unrepresentable in
    the machine ACP would have exactly the dangerous characters whitelisted, and
    that is the silent wrong-file write the guard exists to prevent. Five lines
    that make the guard unsound in its founding case.
  - BOTH DIRECTIONS ARE REQUIRED, because the root is user-settable in Settings.
    Input-only staging would leave a relocated root under a non-ASCII profile
    path still refused, and the refusal is not academic — the Settings row exists
    precisely so people can put backups where they want them.
  - The staging directory must be a FIXED ASCII location chosen by the app, NOT
    a subfolder of the configured root. If the user relocated the root under
    their profile, staging inside it inherits the problem. `C:\x3utils`
    regardless of the configured root is the obvious candidate.
  - It resolves the founding case rather than refusing it. The shared
    `MEMORY_G3_<serial>_1.5.4.bin` with U+0421 hiding in the serial gets staged
    under an ASCII name and flashes. The guard was never about file CONTENTS —
    the name is incidental — and staging is the only candidate that treats it
    that way.
  - PREREQUISITE, already on the OPEN list and now load-bearing:
    `Firmware.promoteDump` swallows every rename failure and returns the
    unchanged `.part` path, and all three callers read that as success. Once
    dumps route through a staging directory that may sit on a DIFFERENT DRIVE
    than the destination — where rename fails outright and needs copy-then-delete
    — that swallowed failure stops being latent and becomes the thing that loses
    a backup. Fix it before staging outputs, not after.
  - END STATE: `validateOpenOcdPath` stops applying to user-chosen paths on
    every platform, because the only paths reaching OpenOCD are ones the app
    constructed and are ASCII and brace-free by construction.
    `validateRootFolder` drops to the writable probe alone. The backup filename
    prefix is already ASCII by construction — `main.dart` `_clean` strips to
    `[A-Za-z0-9_-]`.
  - WHAT STAGING DOES NOT FIX: the app's own install path. See the `-s` item
    below; it needs its own answer.
- THE INTERIM IS ALREADY SHIPPED ON WINDOWS, with two gaps. No new refusal needs
  building while staging is written.
  - `_browse()` in `main.dart` runs the picked folder through
    `validateRootFolder`, which calls `validateOpenOcdPath`, so a non-ASCII root
    is refused on Windows, the red line shows, and `setX3utilsRoot` is never
    reached — the root does not move. There is no typed-path field; the native
    directory picker is the only way in. Every run then re-validates the
    destination before OpenOCD starts, so there is a second net.
  - GAP 1, the message. Still "Path has non-ASCII characters — use English
    letters only." For a folder the user can see this is merely blunt; for the
    founding case it fails completely, because the offending character is a
    Cyrillic homoglyph inside a name that READS as English and the user is being
    told to use English letters. Name the character and offset — `'С' U+0421 at
    position 15`. This is worth doing on its own, before staging, because it is
    the message a confused user reports from.
  - GAP 2, the load path is not validated. `AppController` reads the persisted
    root from prefs and calls `Firmware.setRoot` directly, and `setRoot` only
    trims. A root persisted before `validateRootFolder` existed, or a hand-edited
    prefs entry, comes back unchecked; Settings will display a root the app will
    then refuse to use, and the user meets the refusal mid-run instead of at the
    moment of the choice. Validate on load and fall back to `defaultRoot` with a
    note. This one survives staging: whatever the rule ends up being, a persisted
    root should be checked against it at startup.
- THE APP'S OWN INSTALL PATH IS UNGUARDED, and never has been. FOUND BY READING
  THE SOURCE ON LINUX, NOT OBSERVED — this is the first item to verify on the
  Windows box, because if it reproduces it affects users who did nothing unusual.
  - `OpenOcdRunner._base()` puts `-s <scriptsDir>` in EVERY invocation, and
    `scriptsDir` comes from `OpenOcdPaths.find()`, which walks up from
    `Platform.resolvedExecutable`. So the argument is an absolute path rooted at
    wherever the app was installed or unzipped.
  - `installer/x3utils.iss` is a PER-USER install,
    `DefaultDirName={localappdata}\Programs\x3utils`, so the DEFAULT install path
    contains the account name: `C:\Users\<name>\AppData\Local\Programs\x3utils`.
    No unusual user action is involved; that is simply where it installs.
  - CORRECTION TO AN EARLIER DRAFT OF THIS ENTRY, which described a portable
    build unzipped to the Desktop. There is no zip distribution — that scenario
    was invented and is struck. The installer default above is the real one.
  - It is also NARROWER than the default-path framing suggests. The failure needs
    the account name to be UNREPRESENTABLE IN THAT PC'S OWN ACP, and accounts are
    usually created under a matching locale — `Jörg` on a German CP1252 Windows
    works. It bites on mismatch: a name from a different script than the system
    locale, a locale changed after the account was created, a corporate image.
  - It reaches OpenOCD by TWO independent routes, which is why it survives fixing
    either one alone: `-s <scriptsDir>` from `OpenOcdRunner._base()`, and
    `$scripts` + `rescue.cfg` built from `$WinRoot` inside `rdp.ps1`.
  - It fails LOUDLY — no scripts, everything fails at once — rather than writing
    the wrong file, so this is "the app does not work for this user, with a
    confusing error", not a data-corruption bug.
  - CANDIDATE FIX, UNTESTED: pass `-s` RELATIVE. `Process.start` already sets
    `workingDirectory: paths.binDir`, and that travels through `CreateProcessW`,
    wide, immune to the conversion. If `-s` were `..\scripts`, OpenOCD would
    resolve it against a working directory that was set correctly and the
    absolute install path would never enter `argv` at all. One line, no FFI, and
    it removes the install-location dependency entirely. The exe path itself is
    already safe for the same reason — `Process.start` launches it wide.
  - PROBE, no hardware, same rig as the 2026-07-30 ACP probe: install a copy of
    the packaged app under a directory the ACP-1253 box cannot represent, and
    confirm an absolute `-s` fails to load the scripts where a relative `-s`
    succeeds. If OpenOCD or jimtcl canonicalises `-s` to absolute internally the
    trick will not hold, and that is exactly what the probe settles.
- FULL PATH SWEEP OF THE WINDOWS GUI, done so this is never re-derived one path
  at a time. Read from the source on Linux; nothing here was run.
  - TWO DIFFERENT MECHANISMS ARE IN PLAY, and conflating them produces the wrong
    fix. (A) argv → ANSI conversion, which affects ONLY `openocd.exe` because it
    is the mingw build; Dart's `Process.start`, `powershell.exe` and
    `explorer.exe` all take wide command lines and are immune. (B) FILE CONTENT
    encoding: `config.cmd` is written UTF-8 by `writeAsStringSync` and read by
    the GUI's `rdp.ps1` with `Get-Content` and NO `-Encoding`. The runner invokes
    `powershell`, i.e. Windows PowerShell 5.1, whose `Get-Content` defaults to
    the ANSI codepage. UTF-8 in, ANSI out. Dormant only because the root refusal
    keeps `logDir` ASCII today; it goes live the moment that refusal lifts.
  - INSTALL DIR — `%LOCALAPPDATA%\Programs\x3utils`, always carries the username,
    reaches OpenOCD by both routes above. THE ONLY GENUINELY BROKEN ONE.
  - FIRMWARE INPUT — user-picked, always able to be non-ASCII, reaches
    `write_image`/`verify_image`. Hard stop; only staging fixes it.
  - DATA ROOT and everything under it (`backup/`, `compat/`, `logs/`,
    `packed_zip3/`, `unpacked_zip3/`) — `C:\x3utils` by default, non-ASCII only
    if the user relocates it, which the Windows picker refuses today.
  - RDP TRANSCRIPT DIR — `<root>/logs/rdp_check/`, root-derived, and the one path
    that travels through mechanism (B).
  - SECOND COPY — `%LOCALAPPDATA%\x3utils_backup`, ALWAYS profile-derived and so
    always able to be non-ASCII, but written exclusively by Dart `copySync`.
    SAFE. LEAVE IT. Recorded because it looks like a hole and is not.
  - PREFS — `shared_preferences`, profile-derived, plugin-written through wide
    APIs. SAFE. LEAVE IT. Storing them in the root instead was considered and
    rejected as circular: the root is itself a stored preference.
  - RECYCLE BIN — `trash.dart` builds a `powershell -Command` string containing
    the path; PowerShell takes `GetCommandLineW`, so no conversion. SAFE.
  - `Directory.systemTemp` is Unix-only here (`_prepareUnixRunRoot`); the Windows
    path never uses it.
- DECIDED RELEASE SPLIT.
  - v1.2.3 IS A DIRECTORY RENAME AND NOTHING ELSE: `.iss` `DefaultDirName` to an
    ASCII, space-free, user-writable location (`C:\x3utils_app` — a SIBLING of
    the data root, not inside it, so app binaries never land in the folder
    Settings reveals to users), plus `UsePreviousAppDir=no` and cleanup of the
    old directory. Zero code change, keeps the no-UAC install, keeps `config.cmd`
    working exactly as it does now.
  - THE `UsePreviousAppDir` GOTCHA, which is what makes this non-obvious: `AppId`
    is fixed and `UsePreviousAppDir` defaults to YES, so `DefaultDirName` only
    applies to FRESH installs. Everyone already installed stays put on upgrade —
    and that is exactly the broken population, since the app installs and
    launches fine and it is only OpenOCD that fails. Without
    `UsePreviousAppDir=no` the hotfix reaches nobody who needs it.
  - v1.3.0 TAKES FOUR CHANGES THAT EACH UNLOCK THE NEXT: delete `config.cmd` →
    the bundle becomes read-only → the install can move to Program Files →
    plus ASCII staging. They ship together because they need one validation
    sweep, and because the RDP path is read-protection code that was just
    validated at v1.2.2.
- DELETE `config.cmd` FROM THE GUI (v1.3.0 entry point). The mechanism was
  inherited from the CLI, where `launcher.bat` writes it; the GUI has moved on
  and the CLI is bugfix-only, so the GUI's copy is ours to rewrite.
  - THE TWO COPIES HAVE ALREADY FORKED, which is the licence to do this: the CLI
    reads `$cfgCmd` from `$WinRoot`, the GUI's copy from `$ScriptDir`. This is
    not creating a fork, it is continuing one.
  - The change: `rdp.ps1` already has a `param()` block — add `[string]$Target`,
    `[int]$ConnectTimeout`, `[string]$LogDir`, `[switch]$Race`, delete the
    config-reading block, and have `RdpRunner` pass them as arguments.
    `-Launcher` becomes redundant, and the `.iss` loses its
    `Excludes: "special\rdp\config.cmd"`.
  - WHAT IT BUYS, and why it is the hinge for the rest: `rdp_runner.dart:152` is
    the ONLY runtime write into the bundle — verified, everything else touching
    the install dir is a read. Remove it and the install directory is read-only,
    which is exactly the precondition Program Files needs. It also DELETES
    mechanism (B) rather than mitigating it, since there is no longer a file to
    encode. The `-Config <path>` parameter considered earlier is unnecessary.
  - The `rdp.ps1` hand-run log fallback is `MyDocuments`, not the bundle, so it
    does not break under a read-only install either.
  - PROGRAM FILES CARRIES A NEW, NEVER-TESTED RISK: `C:\Program Files\x3utils`
    contains a SPACE, and that path reaches OpenOCD's argv twice — `-s` from the
    Dart runner and the `-f <rescue.cfg>` built inside `rdp.ps1`, which the
    script itself notes wants forward slashes. Nothing in this codebase has ever
    run with a space in those paths, because `%LOCALAPPDATA%\Programs\x3utils`
    has none. It should be fine — single argv elements, Dart quotes correctly —
    but that is what was said about the ASCII guard on Linux. Probe it on the
    same box, in the same session, as the `-s` probe.
  - Signing is NOT what kept the app out of Program Files. The `.iss` header says
    the reason was `config.cmd` needing to stay writable. Unsigned-app SmartScreen
    friction is accepted for this project and was never the constraint.
  - THE SAME KNOT EXISTS ON UNIX and is worth pulling while in here, UNVERIFIED:
    `_writeConfigSh` does the identical thing, and `_prepareUnixRunRoot()` exists
    ONLY because the signed bundle is read-only and `config.sh` has to be written
    somewhere. Passing those values via `Process.start`'s `environment:` looks
    close to drop-in, because the shell scripts already reference `TARGET`,
    `CONNECT_TIMEOUT` and `X3UTILS_RDP_LOG_DIR` as shell variables and would pick
    them up from the environment unchanged — which would retire the whole
    per-run temp-directory copy. READ THE SCRIPTS FIRST for defaults and `set -u`
    before promising this.
- OPEN ITEMS, carried forward explicitly. The previous handoff was written as a
  validation checklist and dropped these, which is why the ASCII scoping sat
  unstarted through two sessions. Keep this list at the tail.
  - WINDOWS non-ASCII strategy. The guard is still blanket ASCII on Windows,
    which refuses `C:\Users\Jörg\Desktop\fw.bin` before OpenOCD starts.
    Re-probed 2026-07-30 with the current bundled Windows
    `openocd.exe` (`0.11.0+dev-snapshot`, 2026-06-22), ACP 1253, and no
    hardware: a jimtcl `open` read an ASCII path; `Jörg` arrived inside OpenOCD
    as `Jorg` and failed `No such file or directory`; Greek `Άκης` opened
    successfully even though the captured console rendered it as `����`; and
    Cyrillic `Саша` arrived as `????` and failed `Invalid argument`. Each case
    was isolated so a best-fit ASCII sibling could not produce a false pass.
    This confirms the earlier diagnosis: success depends on exact
    representability in THIS PC's ACP, not whether the path is broadly called
    "non-ASCII", and garbled console rendering alone is not failure evidence.
    DECIDED 2026-07-30: ASCII staging in both directions, with the ACP
    round-trip kept only as the fallback if staging proves impossible and the
    `%USERPROFILE%` exemption dropped as unsound. Reasoning is in the
    2026-07-30 entry; do not re-open the four-way choice without reading it.
    Remaining work, in order: (1) the message names the character and offset
    (`'С' U+0421 at position 15`) — independent of staging and worth landing
    first, since "use English letters only" is unactionable when the name looks
    like English, which is the founding case exactly; (2) validate the persisted
    root on load, which `setRoot` does not do today; (3) fix `promoteDump` (its
    own item below) — it is a prerequisite for staging dumps, not a parallel
    task; (4) stage inputs; (5) stage outputs. The Windows refusal stays exactly
    as it ships until (4) and (5) land.
  - WINDOWS INSTALL PATH reaching OpenOCD by two routes (`-s <scriptsDir>` from
    the Dart runner, `$scripts`/`rescue.cfg` from `rdp.ps1`), absolute and
    unguarded, so an account name the machine ACP cannot represent stops the app
    finding its own scripts. Read from the source on Linux, NEVER OBSERVED —
    VERIFY THIS FIRST on the Windows box; it is cheap, needs no hardware, and it
    is the only genuinely broken path in the sweep. PLAN: v1.2.3 renames the
    install directory (`.iss`, zero code); v1.3.0 moves to Program Files after
    `config.cmd` is deleted. A relative `-s ..\scripts` against the
    already-correct `workingDirectory` remains a belt-and-braces candidate for
    dev builds and wizard-changed directories, still untested. Staging does not
    fix this one. Full reasoning, the sweep and the release split are in the
    2026-07-30 entry.
  - CLOSED 2026-07-29: macOS v1.2.2 validation — the four-path probe, the ten
    action sweep at parity with Linux, and the x3utils folder Settings row. See
    the macOS entry above. v1.2.2 is now validated on all three platforms.
  - macOS GATEKEEPER / notarization. Nothing on this project has ever tested the
    first-launch experience, because the testbed has Gatekeeper assessments
    disabled and the tested app never carried a quarantine attribute. Decide
    whether ad-hoc signing is the shipping answer only AFTER running the
    procedure in `docs/testing.md` on a machine with assessments enabled. This
    is a release-blocking unknown for the macOS artifact, not a polish item.
  - The red refusal line in Settings — a folder the app genuinely cannot write
    to. Browse, Reset and Reveal are all covered now (macOS, 2026-07-29), and
    the brace refusal was seen on the run side, but the unwritable-folder
    refusal has never been triggered on any platform.
  - The deliberate-failure paths have no rows on file: the `Keep it` branch of
    the cleanup modal, the pre-flash-backup abort, and the all-`0xFF` blank
    verdict (free right after a rescue mass erase, before reflashing). `Keep it`
    has been exercised at least once without being written up, so treat this as
    a documentation gap rather than a work item until someone says otherwise.
  - The all-zero dump message: make the `masked` verdict neutral (protection
    masking OR an empty/unreadable target). Three places move together — the
    message, the `DumpVerdict.masked` doc comment, and the test's name.
  - `Firmware.promoteDump` swallows every rename failure and returns the
    unchanged `.part` path; all three callers treat that as success. Return a
    result and abort guarded writes when promotion failed.
  - A Linux run-once setup script: deps, udev rules + reload + trigger, plugdev
    group, and a `--check` mode. Currently all manual in `x3utils_linux/README.md`.
  - v1.2.2 release note: users who deliberately pointed backups elsewhere now
    write to the new root. Still unwritten; there is no changelog file.
  - Cosmetic: `DesktopPathDisplay` gives a short root like `C:\x3utils` a tall
    two-line box. A one-line variant for short directory paths whenever the
    settings panel is next touched.

## 2026-07-30 — CLI v1.8.0: the rdp_check log omits its own verdict

- FROM A REAL USER on GitHub, then reproduced on the maintainer's own board, so
  this is a report AND a reproduction rather than either alone.
- WHAT HAPPENS: `rdp_check`'s log file contains ONLY the teed OpenOCD output —
  banner, guided-connect prompts, the two `mdw` reads, `shutdown command
  invoked`. The header, connect mode, Evidence block and Verdict are NOT in it.
  A healthy board's file ends identically, which is how it was confirmed: the
  file is not truncated and the run did not stop, the conclusion simply never
  reaches disk.
- CAUSE, one line: `Say`/`SayOk`/`SayInfo`/`SayWarn`/`SayFail` in
  `x3utils_win/special/rdp/rdp.ps1` are all bare `Write-Host`, and the single
  `Tee-Object -FilePath $LogFile` sits on the OpenOCD pipeline alone.
- WHY IT COSTS A ROUND TRIP: the script prints `Full log: <path>` DIRECTLY under
  the verdict, and names the same file again at the top. Asked for a log, the
  user sends the one file that cannot contain the answer, and it is labelled
  "Full". The user did nothing wrong.
- THE GUI IS NOT AFFECTED and that is why this was never noticed here: it
  captures `rdp.ps1`'s console output through the child process, so a GUI run's
  saved log DOES carry the verdict — that is where the `NOT PROTECTED` lines in
  `docs/testing.md` come from. The incomplete log belongs to the tool that is
  now bugfix-only.
- FIX (agreed, bugfix-only scope): route Evidence + Verdict through the tee that
  already exists. TWO GOTCHAS: `New-LogPath` runs AFTER the first `Say` calls,
  so early lines need buffering or reordering; and the teed OpenOCD text already
  lands with raw ANSI escapes in the file, so strip them on the way to disk in
  the same pass. Also drop the word "Full" from the label if it is not.
- THE REPORTED DEVICE IS READ PROTECTED, unambiguously: `0x1FFFF800` reads
  `00000000` (FAP not `0xA5`, complement inconsistent) and `0x08000000` reads
  all `0x00`. Two independent signals agreeing, so the contradiction guard does
  not apply. All-zero `xPSR`/`pc`/`msp` and "halted due to breakpoint" fit the
  same picture. LIKELY but NOT established from the log: a paid BLE unlock
  product engaging FAP, which is the common real cause of an all-zeros X3 dump.
  Ask whether they ran one and whether any pre-FAP dump of that board exists.
- INCIDENTAL FIELD FACT, worth more than the bug: that user runs from a path
  CONTAINING SPACES (a multi-word Dropbox folder), so `-s <scripts>` carried
  spaces into OpenOCD's argv — and the guided connect, both `mdw` reads and the
  shutdown all worked. The 2026-07-30 entry flagged spaces as a never-tested
  risk against moving the install to Program Files, on the grounds that nothing
  here had ever run with one. Something now has, on a stranger's machine.
  Their box is German Windows with an ASCII path, so no encoding is involved
  either way — and it is the first field data from a CP1252 machine.

## 2026-07-30 — WINDOWS BOX: the non-ASCII question, measured

- WHAT THIS IS: the probe the entry above asked for, run on the Windows box.
  Measurement only — no hardware, no code change, no release work. Windows 10
  Pro, ACP 1253, bundled `openocd.exe` 0.11.0+dev-snapshot (2026-06-22).
  Re-runnable as `x3utils_flutter/tool/acp_probe.ps1`, which prints `USER`,
  `ACP` and the OpenOCD version so any pasted result is self-describing.
- THE TWO GUARDS ARE NOT ONE GUARD, restated because conflating them is what
  produced the wrong work. The path-encoding problem is OpenOCD-on-WINDOWS,
  and the CLI has always guarded it Windows-only. The `{}` guard is ALL-OS
  because braces are the Tcl quoting characters the commands are built with.
  Different cause, different scope. They share a function; they are not one
  rule.
- THE AXIS IS ACP REPRESENTABILITY, NOT "NON-ASCII". Greek passed every
  position on this Greek box; German `ö` failed every position on the same box.
  Blanket ASCII is a locale-independent superset that happens to be safe, not a
  description of the mechanism.
- THE MATRIX, ACP 1253:

  | argv position | ASCII | Greek | `ö` | Cyrillic |
  | --- | --- | --- | --- | --- |
  | `-s <dir>` absolute | ok | ok | **wrong dir** | fail |
  | `-f <cfg>` absolute | ok | ok | **wrong file** | fail |
  | file read, jimtcl `open rb` | ok | ok | **wrong file** | fail |
  | file write, jimtcl `open wb` | n/t | ok | **wrong dir** | fail |
  | relative `-s ..\scripts`, exe + cwd in a bad tree | n/t | n/t | n/t | ok |

  `fail` is a loud refusal (`Can't find …`, `Invalid argument`, non-zero exit).
  **bold** is the silent case: OpenOCD used a DIFFERENT existing path without
  saying so. `n/t` = not run, not "passed".
- THE DISCRIMINATOR, which is the part worth keeping: best-fit does not invent a
  path, it lands on one that already exists. With a `Jorg\` directory present, a
  request for `Jörg\fw.bin` returned Jorg's file. With `Jorg\` moved out of the
  way, the same request failed loudly. So the silent-wrong class needs a
  colliding sibling to exist — which is exactly the shape of the founding case,
  where a Cyrillic homoglyph sits inside a name that reads as Latin.
- WHAT IS ACTUALLY NEW, against what was assumed before today:
  - `-s` and `-f` are affected too, so best-fit can silently load a DIFFERENT
    SCRIPTS TREE or cfg, not only a firmware file. Only the firmware-input case
    had been described.
  - The dump DESTINATION was measured rather than reasoned: a write addressed to
    `Jörg\out.bin` landed in `Jorg\out.bin`.
  - `-s ..\scripts` resolves correctly with the exe AND the working directory
    inside an unrepresentable tree, and a bogus cfg name still fails from there,
    so resolution really is coming from the relative path — OpenOCD does not
    canonicalise `-s`. argv is the only channel that converts; `CreateProcessW`
    paths do not. That makes relative `-s` a candidate for removing the
    install-path dependency with no FFI. NOT tried in the app.
- WHAT THESE NUMBERS DO NOT COVER. The file read/write cells are jimtcl `open`,
  which is the same CRT call `write_image` / `verify_image` / `dump_image` use
  but is NOT those commands — they need hardware and were not run here. The
  Linux hardware row of 2026-07-29 is still the only place a real
  `write_image` / `verify_image` went through an umlaut path, and that was on
  Linux.
- WHAT ONE BOX CANNOT ESTABLISH. Everything above is CP1253. That `ö` works on a
  German CP1252 machine follows from the mechanism (`WideCharToMultiByte`
  against the process ACP) and is NOT measured. The discriminating run is a
  GREEK-named account on German Windows; a German-named account is the control
  that should pass. Until that is run, no claim about German users is a
  measurement.
- FIELD EVIDENCE. No user has ever REPORTED a problem — but it was REPRODUCED
  the same day, which overtakes the "zero evidence" line this entry first
  carried. On the laptop, under a Greek-named Windows account, the PUBLISHED
  v1.2.0 failed on Backup: OpenOCD completed the read and the file was written
  to `C:\Users\<greek>\Documents\x3utils\backup\dump_<ts>.bin`, and the app then
  refused its OWN output — *"Dump saved but failed validation — do not trust it.
  Path has non-ASCII characters — use English letters only. (a read-protected or
  blank chip reads back like this — try Check protection)."* So v1.2.0's
  unconditional guard rejecting a profile-derived output path is OBSERVED, not
  inferred, and the wording sends a user holding a good dump toward FAP. Note
  the shape of it: nothing OpenOCD did failed. We refused ourselves.
- THE LINUX EQUIVALENT LARGELY CANNOT BE BUILT, which corrects a line in
  `docs/testing.md`. Attempting a Greek username on Linux Mint FAILED: `adduser`
  enforces `NAME_REGEX` from `/etc/adduser.conf` (`^[a-z][-a-z0-9_]*$`) and the
  GUI user manager offers nothing else. Root can force it, no ordinary user
  will. So `/home/<user>` is ASCII in practice, the v1.2.0 default root under it
  is ASCII, and the guard never fires on a Linux dump destination — the
  Windows `Σοφία` reproduction has no easy Linux counterpart, because Windows
  lets an account be named anything and Linux does not. The 2026-07-29 Linux row
  says a `/home/Jörg` user "was refused every dump"; that sentence was reasoning
  written alongside the fix, not an observed run, and it describes a user who
  mostly cannot exist. What IS real off Windows is the narrower case the probe
  and the hardware run actually covered: USER-CHOSEN paths — a firmware `.bin`
  under `Prüfung/`, or a root browsed to a non-ASCII directory. Annoying
  refusal, not a dead end. macOS DOES THE SAME, now checked rather than assumed:
  the New User sheet accepts `Σοφία` as Full Name but auto-derives the Account
  Name to `sophia` — transliterated, not stripped — and states that this is the
  name used for the home folder. So on all three OSes only WINDOWS lets a
  profile directory carry non-ASCII at all. That, not any difference in
  OpenOCD, is why the reproduction is Windows-only.
- NOT A v1.2.0 REGRESSION — IT IS ORIGINAL BEHAVIOUR. The maintainer reproduced
  the identical failure on v1.1.3, and `git log -S` puts the unconditional
  `codeUnits > 127` refusal in `057deb6`, the FIRST Flutter GUI commit (v0.9.0).
  `Firmware.validate(outPath)` on the dump is in v1.1.3 too. So every GUI
  release ever published — v0.9.0-beta, v1.0.0, v1.1.2, v1.1.3, v1.2.0 —
  refuses its own backup for any user whose profile path is not ASCII, on all
  three OSes. Nobody reported it across five releases and it took a deliberately
  created account to see it. Two readings stay open and the evidence does not
  choose between them: the affected population is very small, or it hits people
  who quietly give up. Do not write either one down as the answer.
- AND v1.2.2 PASSES ON THE SAME ACCOUNT — a clean A/B, same box, same Greek
  profile, 13 minutes apart. v1.2.0 at `18:27:42` refused its own dump; v1.2.2
  at `18:40:06` reported "Backup complete · Backed up and verified", TOOK 0:02,
  into `C:\x3utils\backup`. The mechanism is the ROOT MOVE, not the Windows
  scoping: the default root left the profile, so the destination stopped
  carrying the user's name and the guard has nothing to fire on. The scoping
  change is what frees Linux and macOS, where the root stays under `$HOME`.
  So the fix for the one observed failure is built, unpublished, and now
  verified on the affected account itself.
- THE INSTALL PATH WAS GREEK IN BOTH RUNS, AND OPENOCD DID NOT CARE. Both
  builds were installed to `%LOCALAPPDATA%\Programs\x3utils` under the Greek
  profile, so `-s <scriptsDir>` carried Greek into argv on every invocation —
  and OpenOCD resolved its cfg files and completed a full 128 KB dump both
  times. This QUALIFIES the entry above, which called the install path "the
  only genuinely broken one": it is a latent dependency, not an active fault,
  and it bites only when the account name is unrepresentable in the machine's
  own ACP (a Greek account on German/English Windows; `ö` on this Greek box).
  When it does bite it fails LOUDLY — `Can't find target/…cfg`, every action
  dead — because a silent best-fit hit would need a sibling install directory
  with the mangled name to already exist. Still uncovered on that account: only
  Backup was run, which is the Dart route; `rdp.ps1`'s `$scripts` +
  `rescue.cfg` route is exercised by Check protection alone.
- WHAT THAT A/B DOES NOT COVER: the guard is still live on Windows, so the same
  user picking a firmware `.bin` out of her own `Documents` is still refused —
  not exercised in this run. And Greek is representable in CP1253, so nothing
  here touches the best-fit / silent-wrong class; that still needs a character
  the machine ACP cannot represent.
- STILL OPEN ON THAT RUN, and cheap: the `.bin` size was not checked, and
  v1.2.0's `validate()` tests the path BEFORE size and content, so "the backup
  is intact" is not yet established — only that the guard fired first. The
  laptop's ACP was not recorded either, which is what decides whether OpenOCD
  wrote that Greek path natively (expected on 1253) or something else happened.
  `tool/acp_probe.ps1` under that account answers both in one run.
- DECIDED: THE GUI DROPS `config.cmd`. Maintainer's call — the file is CLI
  inheritance (`launcher.bat` writes it there) and the GUI no longer needs it;
  the CLI is bugfix-only and the two copies have already forked, the CLI reading
  `$cfgCmd` from `$WinRoot` and the GUI's from `$ScriptDir`. `RdpRunner` passes
  the values as arguments instead. Checked while recording this: `rdp.ps1`
  ALREADY has a `param()` block ending `[switch]$Launcher`, so `-Target`,
  `-ConnectTimeout`, `-LogDir` and `-Race` slot in and `-Launcher` becomes
  redundant; and `rdp_runner.dart:152` really is the ONLY runtime write into the
  bundle on Windows — every other write in that file is under the Unix temp run
  root. So this DELETES the file-content encoding mechanism rather than
  mitigating it (no file, nothing to mis-decode), makes the install directory
  read-only at runtime, and drops the `.iss` `Excludes:` line. The stray
  `config.cmd` left behind in an uninstalled `Programs\x3utils` tree — Inno
  never tracked it, so uninstall cannot remove it — stops being possible too.
- THE UNIX HALF IS THE SAME KNOT, and it has its own DEFECT — measured, not
  reasoned. `_writeConfigSh` wraps every value in DOUBLE quotes with no
  escaping, so `$`, backtick, `"` and `\` stay live when the script sources it.
  Tested in bash: a log dir of `…/x3$test/logs` came back as `…/x3/logs` — the
  unset `$test` expanded to nothing and the transcript would land in a
  DIFFERENT directory, silently. Same class as the Windows best-fit case,
  different cause; `validateOpenOcdPath` refuses only `{` and `}`, so nothing
  catches it. `OPENOCD_BIN` / `SCRIPTS_DIR` run through the same writer, where
  it would fail loudly instead. Scope is small — Unix only, RDP only, costs a
  transcript rather than a backup, and needs an unusual character in the root or
  bundle path.
  - UTF-8 is NOT part of this: the same test round-tripped `Prüfung` exactly and
    the directory resolved. `source` is byte-transparent, so the Windows
    ANSI-decode hazard has no Unix counterpart. Two different mechanisms; do not
    merge them.
  - So passing the values through `Process.start`'s `environment:` removes a
    real quoting bug, not just a piece of inheritance — environment values are
    never re-parsed by a shell. Still READ THE SCRIPTS FIRST: `rdp_check.sh`
    hard-exits with `[FAIL] Missing config.sh` if the file is absent, and
    `rdp_lib.sh` documents that it must be sourced after it for `INTERFACE`,
    `TARGET`, `CONNECT_TIMEOUT`, `CL_*` and `D`. Neither script uses `set -u`,
    so unset values expand empty rather than aborting. Retiring
    `_prepareUnixRunRoot()` is a SEPARATE, larger change — it also carries exec
    bits and the `backup/` fallback, and macOS places config.sh differently.
- CORRECTION TO THE ENTRY DIRECTLY ABOVE. "DECISION: ASCII STAGING, IN BOTH
  DIRECTIONS" and its ordered work list (1)–(5) were written on the Linux
  machine, with no Windows box and no field input. Read cold it looks like a
  commitment; it is not one, and nothing in it was ever weighed against user
  reports. This session inherited that urgency, built a v1.2.x hotfix case on
  top of code reading, and only then asked whether anyone had hit the bug.
  Treat the staging plan as an option with its reasoning attached. The
  OPEN ITEMS list above belongs to that entry, not to this one.

## 2026-07-31 — GUI: OpenOCD output can no longer fail a run (v1.2.3 BETA2)

- THE BUG, found by turning the beta path guard OFF on a Greek Windows account:
  OpenOCD echoes the source path in `wrote N bytes from file <path>`, in the
  platform's own encoding. On Windows that is ANSI bytes, the strict
  `utf8.decoder` threw `FormatException: Missing extension byte (at offset 38)`,
  and the error propagated out of `OpenOcdRunner.run`. The run died BETWEEN
  `flash erase_address` and `flash write_bank`, showing "Could not start
  OpenOCD" — for a run that had already erased the chip and, judging by where
  the exception landed, completed the write. Offset 38 is exactly the length of
  `wrote 131072 bytes from file C:/Users/`.
- THE REAL DEFECT was not the encoding, it was the coupling: a byte needed only
  to draw a console line could abort a flash. Reading the log must never decide
  the operation.
- FIX, five sites, no platform branches: `Utf8Decoder(allowMalformed: true)` in
  place of the strict decoder in `OpenOcdRunner.run`, both `runRace` streams and
  `RdpRunner._listenText`, plus a `_loggingOnly` guard so an exception in the
  console/evidence path is swallowed instead of thrown into the run.
- DELIBERATELY OS-AGNOSTIC. The trigger is Windows in practice — POSIX paths go
  out and come back as UTF-8, which is why the 2026-07-29 Linux and macOS runs
  pushed a `Prüfung/` path through the real `write_image`/`verify_image` without
  trouble. But POSIX filenames are arbitrary bytes, so a `.bin` carrying Latin-1
  in its name off an old archive reaches the same crash there. Framed as
  robustness, not encoding, so no `Platform.isWindows` appears in it.
- VERDICTS ARE UNAFFECTED, and that is tested rather than assumed: `wrote`,
  `verified`, `dumped` and the byte counts are ASCII and precede the path on
  every line. `test/openocd_output_decoding_test.dart` (4 tests) rebuilds the
  exact CP1253 byte sequence, asserts that strict UTF-8 still throws on it at
  offset 38 — a fixture guard, so the test cannot quietly stop reproducing the
  reported failure — then pins that lenient decoding returns normally and that
  write/verify evidence survives the mangling. 184 tests, analyze clean.
- THIS IS NOT THE PROPER FIX, and should not be recorded as one. It guarantees
  the stream cannot throw; it does NOT render the path correctly, which still
  comes out as U+FFFD. The proper fix decodes in the platform's actual encoding
  — `systemEncoding` is the ANSI codepage on Windows and would show `Σοφία` —
  but its behaviour on undecodable input is unverified, and whether Dart
  guarantees UTF-8 for it on POSIX under a non-UTF-8 locale is unchecked. Do
  that deliberately, not as a drive-by.
- Shipped as `1.2.3 BETA2` so bench transcripts say which build produced them:
  every log line starts `x3utils v1.2.3 BETA2 · …`, and the BETA1 runs that hit
  the crash remain distinguishable. Semver-style `1.2.3-1` was NOT used —
  `tool/version.dart` keeps five x.y.z strings byte-equal and `package_macos.sh`
  asserts that match, so the channel belongs in `kAppStage`, not the number.

## 2026-07-31 — BEST-FIT SUBSTITUTION, ON HARDWARE, IN THE REAL FLASH PATH

- THE RESULT THE WHOLE GUARD RESTS ON, finally observed rather than inferred.
  Windows box, ACP 1253, beta path check off, `Flash slot 0` against a live
  target. Sent
  `…/gen_test_bins/Prüfung/16a_slot_zt3_vcu_SYNTHETIC.bin`; OpenOCD answered
  `couldn't open …/gen_test_bins/Prufung/16a_slot_zt3_vcu_SYNTHETIC.bin`.
  `ü` → `u`. Not a jimtcl `open` this time — `flash write_image erase` on a
  halted chip.
- BOTH WAYS ON ONE MACHINE, MINUTES APART, which is what makes it conclusive.
  At 00:25 a Greek path worked end to end: dump INTO
  `…/Σοφία/Documents/x3utils/backup/` and flash FROM `…/Σοφία/Desktop/`,
  erased, wrote 131072, verified 131072, exit 0. At 00:30 the umlaut path
  mangled. Greek is in CP1253; `ü` is not. Codepage membership decides it —
  "non-ASCII" never did.
- THE NEAR-MISS IS THE POINT. It failed LOUDLY only because no `Prufung`
  directory exists. Had one been there — a stray copy, an ASCII-named sibling,
  the sort of thing that accumulates in a test folder — OpenOCD would have
  opened THAT file, written it to slot 0, and `verify_image` would have
  verified the same wrong file and returned success. Green screen over wrong
  firmware. That is the exact failure the Windows guard exists for, and it has
  now been demonstrated end to end.
- THREE-PLATFORM CONTRAST, same fixture: `Prüfung/16a_slot_zt3_vcu_SYNTHETIC.bin`
  is the file that PASSED on Linux and macOS hardware on 2026-07-29 through
  `write_image` and `verify_image`. Same bytes, same command — fine on POSIX,
  mangled on Windows. The `Platform.isWindows` scoping of the guard is now
  evidenced from both sides.
- No harm done: OpenOCD opens the image before erasing, so the failure aborted
  ahead of any write (no `wrote`, exit 1), and the run's own pre-flash backup
  was already on disk.
- DEFECT FOUND ALONGSIDE IT: the failure screen appended "Most failures are a
  lost SWD / C45 contact — re-seat it, keep it steady, then press Retry." For
  `couldn't open <path>` that is wrong and actively misleading — the SWD link
  demonstrably worked seconds earlier (the backup succeeded), retrying will fail
  identically forever, and the operator is sent to re-seat wiring that was never
  at fault. Suppress the re-seat hint when OpenOCD reports it could not open a
  file.
- MAINTAINER'S POSITION, recorded so it is not re-litigated: there will probably
  never be a FULL fix. The order is stay-out-of-trouble first — the Windows
  guard stays as it ships — and only then look at whether acceptance can be
  SAFELY widened for the CP1252 users who are the majority here, German and
  French alike (`ö ä ü ß`, `é è ç` are all in 1252 and all refused today for no
  reason those machines agree with). The ACP round-trip is the mechanism that
  could do it, and tonight strengthens the case for it specifically: it would
  have accepted `Prüfung` on a German box and refused it on this Greek one,
  which is exactly right in both directions. Not a promise, and not before the
  decoder work is finished properly.

## 2026-07-31 — Windows ACP-safe paths and the BETA3 comparison switch

- THE BLANKET ASCII GATE IS REPLACED ON WINDOWS by an exact round-trip through
  the active ANSI code page. The app gets the current ACP with `GetACP`, encodes
  the whole UTF-16 path with `WideCharToMultiByte`, decodes it again with
  `MultiByteToWideChar`, and accepts only when the result is byte-for-byte the
  original Dart string. `WC_NO_BEST_FIT_CHARS` plus the used-default-character
  result makes a best-fit such as CP1253 `ü` → `u` a hard rejection rather than
  a silently different filename.
- THIS IS LOCALE-SAFE, NOT GENERALLY UNICODE-SAFE. A CP1253 machine accepts
  `Σοφία` and rejects `Prüfung`; a CP1252 machine accepts `Prüfung`, `Jörg` and
  French accented names and rejects Greek or Cyrillic characters. ASCII still
  takes the fast path. CP65001 is handled with its valid flag/default-character
  combination and exact round-trip rule.
- `1.2.3 BETA3` HAS A WINDOWS-ONLY BENCH SWITCH. OFF is the new ACP-safe policy;
  ON is an explicitly labelled unrestricted non-ASCII bypass. Braces remain
  forbidden in either mode because they are Tcl syntax, not an encoding issue.
  The preference uses a BETA3-specific key and is honored only on Windows when
  `kAppStage` is exactly `BETA3`; the old BETA2 preference is ignored, so the
  experiment cannot silently survive into a stable or differently named build.
  Every real run logs either the active code page or `UNRESTRICTED BYPASS`.
- POSIX IS UNCHANGED: there is no ACP/non-ASCII gate on Linux or macOS. Braces
  are still rejected for paths that will be inserted into an OpenOCD Tcl
  command.
- OFFLINE ZIP3 SOURCES NO LONGER INHERIT OPENOCD PATH RULES. Slice and Pack use
  the same existence, extension, size/content and firmware-identity checks as
  before, but their selected local `.bin` may now live in a Unicode or
  brace-containing path. Unpack was already local. The shared x3utils output
  root keeps its OpenOCD-safe validation because backups under that root are
  passed to OpenOCD by hardware actions.
- THE OUTPUT DECODER CHANGE FROM BETA2 REMAINS SEPARATE and intentionally
  unchanged: malformed console bytes still cannot abort a run. This gate
  prevents Windows from handing OpenOCD a different filename in the first
  place; it does not try to render OpenOCD's ANSI output as Unicode.
- SOFTWARE VERIFICATION: deterministic CP1252, CP1253, CP65001, best-fit and
  homoglyph tests; controller preference-lifetime tests; ZIP3 call-site
  regression tests; all 195 Flutter tests pass; `flutter analyze` is clean; and
  `flutter build windows --release` produces the release executable. No
  additional hardware command was run for this implementation pass; the
  preceding real CP1253 flash results are the hardware evidence that motivated
  it.

## 2026-07-31 — BETA3 installed on the Greek Windows account

- INSTALLED-PACKAGE AND HARDWARE EVIDENCE, not a dev-tree extrapolation. The
  maintainer handoff contains ten saved logs plus two screenshots from Windows
  11 Greek, a Greek-script account name, ACP 1253, Default SWD, against the ZT3
  VCU test board. Every OpenOCD command uses the installed backend under
  `%LOCALAPPDATA%\Programs\x3utils\native\windows\oocd`, and every hardware
  transcript identifies `BETA3 Windows path mode: ACP-safe · code page 1253`.
- THE POSITIVE PATH PASSES END TO END. Backup produced and promoted a 131072 B
  dump under the default x3utils root; its second copy landed under
  `%LOCALAPPDATA%\x3utils_backup`. Backup + Flash and Flash Only both read the
  full rescue image from `%USERPROFILE%\Desktop`, erased, wrote and verified
  131072 B, exit 0. SHU compatible dumped, promoted, patched, reflashed and
  verified. ZIP3 import decrypted a 58460 B ZT3/VCU payload, then guarded slot
  0 backed up, matched identity and verified it; a second guarded slot-0 run
  read a 58220 B payload from deeper under `%USERPROFILE%\Desktop` and verified
  it too.
- THE NEGATIVE PATHS PASS TOO. A GT3 slot bin against the ZT3 target stopped
  after the mandatory backup and before write. CP1253 refused `ü` (`U+00FC`,
  character 51) in a `Prüfung` source path. Backup + Flash separately refused a
  58436 B slot bin because that action requires a full 131072 B image. Those
  last two are screenshot evidence; neither started a hardware write.
- CHECK PROTECTION'S HARDWARE VERDICT PASSED: complete USD/main-flash evidence,
  `ffff5aa5`, FAP `0xA5`/comp `0x5A`, readable firmware, `NOT PROTECTED`, exit
  0. THE RDP LOGGING BEHAVIOR DID NOT PASS ACCEPTANCE. The maintainer reports
  the GUI and CLI have the same logging problem on Windows, Linux and macOS.
  Keep that as a separate cross-platform RDP issue TBD; do not fold it into the
  ACP-path work or call it closed because the protection verdict was correct.

## 2026-07-31 — Windows installation-path conclusion after BETA3

- THE INSTALLER DID NOT CHANGE. Full history of
  `x3utils_flutter/installer/x3utils.iss` shows that every edit after its
  creation changed only `AppVer`; its per-user
  `%LOCALAPPDATA%\Programs\x3utils` destination, fixed `AppId`, payload rules,
  no-UAC policy and shortcuts are unchanged. BETA3 changed the application
  payload, not the installer behavior.
- THE GREEK INSTALLED RUN QUALIFIES THE OLD RISK. A profile name representable
  in the active ACP works, including the install path itself and firmware under
  that profile. The remaining install-path hole is the cross-locale case: an
  account name that the machine's own ACP cannot represent. Unlike a firmware
  best-fit collision, failure to find the app's own scripts should normally be
  loud and global.
- SECOND COPY AND PREFS STAY WHERE THEY ARE. The second copy now has direct
  installed-app evidence under the Greek profile and is written by Dart file
  APIs; preferences are plugin-written through Windows Unicode APIs. Neither is
  handed to OpenOCD, so moving them buys nothing.
- DO NOT CREATE TWO DIFFERENT BETA3 INSTALLERS. The ACP-safe BETA3 package has
  now been exercised as installed; freeze that installer behavior. Any install
  location experiment gets a new beta identity and its own fresh-install,
  upgrade, uninstall, normal OpenOCD and RDP checks.
- PROGRAM FILES IS THE PREFERRED LONG-TERM DESTINATION, AFTER THE BUNDLE IS
  READ-ONLY. Greek Explorer localizes its display name to `Αρχεία Εφαρμογών`,
  but the real filesystem path remains the ASCII `C:\Program Files`; locale is
  not a path risk. The current blocker is that Windows `RdpRunner` writes
  `config.cmd` beside the installed `rdp.ps1`. Remove that runtime bundle write
  first. A Program Files package then needs elevation plus explicit validation
  of the space-containing path in normal OpenOCD and RDP flows. Keep this
  packaging decision separate from the cross-platform RDP logging defect even
  if their cleanup stages happen to touch adjacent code.

## 2026-07-31 — Windows GUI RDP drops runtime config and the partial toolkit log

- VERSIONED AS `1.2.3+10 BETA4`. The semantic version stays 1.2.3; the visible
  stage advances from BETA3 and the Flutter build advances from +9 to +10. The
  BETA3-only Windows path bypass is deliberately unavailable in BETA4, so an old
  `beta3BypassWindowsPathSafety` preference is ignored and normal ACP-safe path
  handling remains. The first full run caught the old stage-gated expectation;
  its regression test now pins retirement outside BETA3. Focused root tests
  passed 20/20 and the final full suite passed 197/197.
- DONE, WINDOWS FLUTTER BUNDLE ONLY. `RdpRunner` no longer writes `config.cmd`
  beside the installed `rdp.ps1`. It passes `Target`, `ConnectTimeout`, `LogDir`,
  optional `Race`, and GUI `NoToolkitLog` as PowerShell arguments. `-Launcher`
  remains the switch that makes `Resolve-Connect` honor Target/Race rather than
  fall back to guided `rescue.cfg`; Rescue still passes `-Yes` because the GUI
  already owns the destructive confirmation and cannot satisfy the script's
  duplicate typed `UNLOCK` prompt.
- THE GUI NOW HAS ONE AUTHORITATIVE RDP LOG. The real Windows pair was measured
  before editing: the 43-line UTF-8 console log contained the complete command,
  mode, all 15 OpenOCD lines, evidence, verdict, and exit code; the UTF-16LE
  `_toolkit` file contained only those 15 OpenOCD lines. GUI calls therefore
  suppress the partial script file and its `Log file` / `Full log` claims. A
  direct hand-run without `-NoToolkitLog` keeps the old transcript behavior.
  Save log off now means no persistent Windows GUI RDP log, matching the toggle.
- STALE FILES FAIL HARMLESSLY. The bundled script never reads `config.cmd`; Inno
  deletes that exact legacy generated file on upgrade and uninstall, while the
  package exclusion stays as defense against an ignored developer artifact.
  The current per-user/no-UAC destination is unchanged; Program Files remains
  separate work.
- SCOPE HELD: no file under `x3utils_win`, Linux, or macOS changed. Unix GUI RDP
  still has the paired toolkit log and its temporary config.sh flow.
- NON-HARDWARE EVIDENCE: PowerShell parser clean; focused RDP tests 5/5 and the
  full Flutter suite 197/197; the
  runner fixture covers A/B/C/D, timeout, log dir, GUI suppression, Rescue
  `-Yes`, absent config, and an unchanged contradictory stale config. The real
  bundled script was also run against a copied non-hardware system executable:
  GUI mode made no toolkit log, while hand-run mode made one non-empty toolkit
  log. `flutter analyze` and `git diff --check` clean; Windows release build
  passed. Inno Setup 6.7.1 compiled `x3utils-setup-1.2.3.exe`, included the
  updated `rdp.ps1`, parsed the install/uninstall delete entries, and excluded
  the ignored source config. No hardware action ran during this implementation
  verification.
- PACKAGED WINDOWS AND HARDWARE EVIDENCE, W11GR: the maintainer installed BETA4
  over the previous per-user installation. The new install-delete rule removed
  the legacy runtime `config.cmd`, retained the packaged `rescue.cfg`, and GUI
  runs did not recreate `config.cmd`. Each new run produced exactly one complete
  GUI log; no new `_toolkit` companion appeared.
  - Check at 13:27 recorded `ffff5aa5`, consistent FAP `0xA5`/comp `0x5A`,
    readable main flash, `NOT PROTECTED`, and exit 0.
  - Destructive Rescue at 13:33 used launcher A / Default SWD and the passed
    target, timeout, log directory, `-NoToolkitLog`, and `-Yes`; it halted the
    target, erased/reprogrammed the option area, read back `ffff5aa5`, reported
    `Rewrite sent`, and exited 0.
  - After the required power-cycle, Check at 13:34 first hit `Error: open
    failed`; the retry then connected and produced the complete USD/main-flash
    evidence, `NOT PROTECTED`, and exit 0. That independent post-rescue Check is
    the recovery verdict; Rescue's exit status alone is not treated as proof.
  Evidence copies are under
  `I:\SCOOTER\__bins4tests\W11GR\logs\rdp_check|rdp_rescue`. This closes the
  Windows BETA4 installed-upgrade, read-only-bundle, single-log Check and Rescue
  acceptance. Program Files remains the next separate packaging discussion.

## 2026-07-31 — Unix GUI RDP also keeps one complete log

- VERSIONED AS `1.2.3+11 BETA5`. BETA4 remains the packaged Windows baseline;
  this follow-up changes only the Flutter GUI's Linux/macOS Check transcript
  behavior. It is a separate commit-sized change before the Program Files work.
- ROOT CAUSE AND SCOPE: bundled Linux/macOS `rdp_check.sh` tees every OpenOCD
  attempt into a temporary file for verdict parsing, then copied that same
  attempt into a persistent `_toolkit` file. The GUI already captures the live
  stream and adds the command, prompts, evidence, verdict and exit code, so its
  console log is the superset. Unix Rescue already had no toolkit transcript.
- MINIMAL FIX: Unix GUI Check passes `--no-toolkit-log`. Both bundled Check
  scripts still create and parse the temporary per-attempt file and still stream
  normal A/B/C output through `tee`; they only skip persistent directory/file
  creation, the append, and `Log file:` / `Full log:` lines. A direct or legacy
  script run without the flag keeps the old toolkit transcript. The temporary
  `config.sh` flow, RDP Tcl/connect behavior, rescue scripts and package assembly
  are unchanged. Standalone `x3utils_linux` and `x3utils_mac` are untouched.
- SAVE LOG now has one policy on every GUI platform: ON writes the complete GUI
  RDP log; OFF writes no persistent GUI RDP log. Power-race RDP remains blocked
  in `AppController`, so its Linux-only hidden-attempt transcript path is not a
  reachable GUI compatibility concern.
- WINDOWS-HOSTED NON-HARDWARE EVIDENCE: both edited shell scripts pass `bash -n`
  under Git for Windows. The focused RDP file reports 6/6, but only its two
  Windows cases execute on this host; the new GUI/direct/retry Unix cases are
  platform-gated and remain target-runtime evidence, not Windows evidence. The
  BETA5 stage/root test passes 20/20, the full suite passes 198/198, and
  `flutter analyze` is clean. At this checkpoint, before the target-runtime
  results below, both Unix packages, a retry, and a real direct-script run still
  required coverage.
- MACOS DEBUG/SOURCE-BUILD HANDOFF PASSED, commit `0fc483a`, on macOS 15.7.7 /
  Intel x86_64 with the ZT3 VCU test board, ST-LINK, and launcher A / Default
  SWD. The 14:16:48 GUI Check passed
  `bash rdp_check.sh --launcher --no-toolkit-log` and created exactly one new
  file, `~/x3utils/logs/rdp_check/rdp_check_2026-07-31_14-16-48.log` (1445 B).
  No same-run `_toolkit` companion appeared; the two old July 29 pairs remained
  visible in the directory, so this was not inferred from a cleaned folder.
  The GUI log is complete: USD `ffff5aa5`, consistent FAP `0xA5`/comp `0x5A`,
  readable main flash (MSP `0x20000550`, reset vector `0x08000121`), `NOT
  PROTECTED`, and exit 0. No retry occurred in this run. On the same macOS
  checkout, the focused RDP test passed 6/6 and `flutter analyze` was clean.
  This closes source-build macOS evidence; the packaged pass below closes the
  other macOS half. At that point a real direct-script compatibility run
  without the flag and Linux remained owed; the packaged Linux pass below
  closes the latter.
- MACOS PACKAGED-APP HANDOFF PASSED from
  `dist/x3utils-1.2.3-macos-universal/x3utils.app` on the same testbed. Check
  connection resolved the backend through the bundle's
  `Contents/MacOS/native/macos/oocd/scripts`, halted the target, found the
  `artery` flash bank, exited 0, and saved
  `check_2026-07-31_14-22-45.log` (745 B). The following Check protection passed
  `bash rdp_check.sh --launcher --no-toolkit-log` and saved exactly one new GUI
  log, `rdp_check_2026-07-31_14-22-52.log` (1445 B), with no new `_toolkit`
  companion. Its evidence matches the debug run: USD `ffff5aa5`, FAP
  `0xA5`/comp `0x5A`, readable main flash, `NOT PROTECTED`, and exit 0. No retry
  occurred. This closes packaged macOS coverage for the BETA5 single-log
  change. The packaged Linux pass below closes the other target package; a live
  BETA5 retry and a real direct-script compatibility run remain separate.
- LINUX PACKAGED-APPIMAGE HANDOFF PASSED from
  `dist/x3utils-1.2.3-x86_64.AppImage` on the Linux Mint home-primary x86_64
  workstation at clean commit `41d861d`. The AppImage was built at 14:33 and
  the 14:34 Check protection passed
  `bash rdp_check.sh --launcher --no-toolkit-log`. It saved exactly one new GUI
  log, `rdp_check_2026-07-31_14-34-11.log` (1392 B), and no same-run `_toolkit`
  companion; the three old July 29 toolkit logs remained visible in the
  directory. The complete log recorded USD `ffff5aa5`, consistent FAP
  `0xA5`/comp `0x5A`, readable main flash (MSP `0x20000550`, reset vector
  `0x08000121`), `NOT PROTECTED`, and exit 0. No retry occurred. This closes
  packaged Linux coverage for the BETA5 single-log change. A live BETA5 retry
  and a real direct-script compatibility run without `--no-toolkit-log` remain
  separate.

## 2026-07-31 — CLI v1.8.1 saves one complete RDP transcript

- SCOPE: standalone CLI only. This closes the v1.8.0 defect recorded above
  where the file labelled `Full log` contained only OpenOCD output and omitted
  the script header, connection mode, evidence and verdict. Flutter's separate
  single-log policy and bundled native scripts are unchanged.
- STORAGE: new standalone logs go under each platform's
  `special/rdp/logs/`; existing `backup/*.log` files are not moved. The tracked
  `.gitignore` placeholders keep runtime transcripts out of source control.
- WINDOWS: `rdp.ps1` creates the log before resolving configuration, writes
  UTF-8 without a BOM, strips ANSI, and routes both its `Say*` presentation and
  every OpenOCD attempt into the same file. Check, Clear, Rescue and Enable all
  use the new directory. A logging append failure warns once and cannot change
  the hardware action's verdict.
- LINUX/MACOS: `rdp_check.sh` re-execs once under a live `tee`, preserving stdin
  for guided C45 prompts and the existing per-attempt parser files. Quiet
  Power-race misses join the raw transcript without appearing on screen; after
  the child exits, ANSI is stripped into the one final log. If finalization
  fails, the raw temporary transcript is preserved and named instead of being
  deleted. Rescue remains console-only on these two platforms.
- NON-HARDWARE EVIDENCE: both Bash scripts pass `bash -n`; Windows PowerShell
  parses cleanly. An isolated Unix transcript probe kept a prompt live, captured
  a quiet attempt and verdict, preserved the child exit status and removed ANSI.
  The actual Windows logging functions were AST-extracted without dispatching
  the RDP script; they produced ANSI-free, no-BOM UTF-8 containing presentation,
  verdict and OpenOCD lines. `git diff --check` passed. ShellCheck is not
  installed on this workstation. No OpenOCD or hardware command was run.
