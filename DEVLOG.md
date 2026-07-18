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
    cross-checks info.json - type always, model for VCU - verified 28/28 against
    8 example bins. SOFT by design: a mismatch is an amber "loaded anyway -
    verify before flashing" warning, not a block. Decision: start soft (a
    firmware revision could move/change the banner); may tighten to a hard block
    once proven across the full firmware set.
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
