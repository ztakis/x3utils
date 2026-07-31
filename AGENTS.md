# AGENTS.md

Guidance for automated coding agents working in this repository.

## Project Overview

This repository contains cross-platform ST-LINK/OpenOCD utilities for
third-generation Ninebot scooter controllers.

The active GUI path is the Flutter app under `x3utils_flutter/`, currently
packaged for Windows, Linux, and macOS. The older script and launcher trees are
still important as proven behavior references and platform support.

The tools cover:

- dumping the full 128 KB VCU flash memory;
- flashing a selected 128 KB `.bin` file;
- dumping, patching, and flashing SHU-compatible firmware;
- recovery and read-protection checks where explicitly requested;
- connection modes for default SWD, C45 clone ST-LINK, genuine ST-LINK nRST,
  and Power-race.

The repository intentionally vendors OpenOCD binaries, support libraries,
target/interface configuration files, and firmware `.bin` payloads. Treat
these as release assets, not ordinary source code.

## Agent Workflow

Default to discussion/review mode for this repo.

- Read files and run non-writing inspection commands freely.
- Before editing, creating, deleting, moving, or formatting files, show the
  intended change and ask for confirmation unless the user has already clearly
  authorized that exact work.
- Do not commit unless the user explicitly asks.
- Do not run flash, dump, unlock, rescue, or other hardware-facing commands
  unless the user explicitly asks for that run.
- Keep changes small and aligned with the existing implementation style.

## Repository Layout

- `README.md` - top-level project documentation.
- `x3utils_flutter/` - active Flutter GUI path, including desktop runtime
  assets and OpenOCD orchestration.
- `x3utils_win/` - Windows `.bat`/`.cmd` implementation and bundled OpenOCD.
- `x3utils_linux/` - Linux shell implementation and bundled OpenOCD.
- `x3utils_mac/` - macOS shell implementation and bundled xPack OpenOCD.
- `docs/testing.md` - manual hardware test matrix, checklists, and regression
  notes.
- `docs/DEVLOG.md` - short chronological development memory for decisions,
  handoffs, and test notes.
- `*/special/` - special-purpose firmware files and flashing scripts.
- `*/backup/` and `*/compat/` - runtime output locations. These should
  generally stay ignored except for their existing `.gitignore` files.

Wiki pages are maintained directly in the GitHub wiki repository. Do not treat
old local `docs/wiki` drafts as the source of truth unless the user explicitly
says so.

## Safety Rules

- Do not introduce unlock, mass erase, read-protection bypass, or destructive
  recovery behavior unless the user explicitly requests it and understands the
  risk.
- Preserve evidence-based success verdicts. A green UI result must require the
  actual expected evidence, not only process exit status.
- Preserve the fixed firmware size expectation of `131072` bytes unless the
  hardware target changes.
- Keep rejection of unsafe paths in binary validation, especially braces `{}`
  used in OpenOCD Tcl command quoting. On Windows, keep the non-ASCII path
  guard unless command path handling is redesigned and tested.
- Be careful with files under `special/`; they include firmware images and
  scripts that may be intentionally target-specific.

## Flutter GUI Notes

The Flutter GUI is the active desktop path. For GUI work:

- Prefer the existing controller/runner structure over adding parallel logic.
- Keep OpenOCD output visible and do not hide important error lines behind
  generic UI messages.
- Success and failure handling should remain stricter than progress animation.
- Power-race is a connection strategy, not a separate truth model. Where
  possible, share evidence parsing with the other real OpenOCD modes.
- Preserve guided C45 hold/count/release prompts when changing real OpenOCD
  line parsing.

Progress presentation is settled. Do not reintroduce a per-step progress
checklist:

- `_advanceOpenOcdStage(line)` watches markers such as `target halted`,
  `dumped`, `erased`, `wrote`, and `verified`, but does not distinguish between
  them. Any marker flips the UI into the run state once and refreshes the race
  watchdog's liveness timestamp. It is a liveness detector, not a stage parser.
- The hero zones stay distinct: the header explains the selected action, the
  eyebrow carries stakes/state/telemetry, the large title carries the current
  instruction or outcome, and the message carries the supporting live fact.
- Idle eyebrows show the action's stakes. A genuinely running OpenOCD/RDP core
  may show an `M:SS` elapsed clock and a timed result; guided C45 steps and
  Power-race phases keep their more useful phase labels. The clock is deliberate
  reassurance for slower macOS runs (Windows/Linux normally finish within about
  10 seconds), not a claim of precise per-step progress. Timing remains scoped
  to the current real process rather than the complete multi-process action;
  keep this behavior until real use motivates a clearer model.
- The UI is a single busy spinner plus that eyebrow. Per-step checklist rows
  were deliberately removed because they implied timing accuracy the tool does
  not have. Typed per-step progress events are not planned; adding them would be
  new work, not resumed work.
- Presentation delays gate only the busy/result transition and message
  readability: `_minBusyVisible` (1000 ms) and `_minAfterLastProgress`
  (2500 ms), combined with max rather than sum, plus a 900 ms pause after the
  SHU patch message. Never put a delay in front of an OpenOCD call.
- Pacing the display of an already-confirmed fact is presentation and is fine.
  Displaying a fact that has not been confirmed by real output is faking and is
  not.
- Keep raw OpenOCD output in the console as the debugging surface.
- Keep verdicts stricter than progress UI. Eyebrow text is presentation; a green
  result still requires the actual expected evidence.
- Never simulate hardware output. A missing or unresolvable OpenOCD backend,
  an unknown action id, or an unsupported platform must fail closed rather than
  fall back to a dry run.

### macOS Flutter Packaging

- From the repository root, use
  `cd x3utils_flutter && ./tool/package_macos.sh` for distributable macOS
  builds. A plain `flutter build macos --release` does not assemble the
  complete release package.
- The script builds a universal x86_64/arm64 app, embeds `native/macos` at
  `x3utils.app/Contents/MacOS/native/macos`, ad-hoc signs the backend and app,
  verifies signatures and architecture slices, parses the Power-race cfg
  without `init`, and creates a versioned ZIP under `x3utils_flutter/dist/`.
- `OpenOcdPaths.find()` expects that embedded `Contents/MacOS/native/macos`
  layout. Do not move the backend into Resources without redesigning path
  discovery.
- Preserve executable permissions for OpenOCD and the RDP shell scripts.
- The custom app icon is the normal `AppIcon` catalog. A stale Flutter icon in
  Dock/Launchpad was confirmed to be a macOS cache issue, not a bad package.
  Do not rename the icon identity or bump the build number solely to clear it.
- The startup window is 1024x768 (4:3) on all three platforms: Windows
  `windows/runner/main.cpp` (outer size), Linux `linux/runner/my_application.cc`
  (`gtk_window_set_default_size`), and macOS `MainMenu.xib` `contentRect`. Note
  the Windows number is the outer window while Linux/macOS are the content area,
  so those two get ~30px more usable height. Keep the three in sync and 4:3
  unless the UI layout is intentionally redesigned.

### Flutter RDP Platform Details

- Power-race protection actions are blocked in `AppController` before an RDP
  script starts. Keep this fail-safe warning.
- Windows RDP passes target, timeout, race, and log settings directly to the
  PowerShell toolkit. It never writes `config.cmd` inside the installed bundle.
- Linux copies the shell toolkit to a temporary tree and writes `config.sh`
  beside `special/rdp`.
- macOS also uses a temporary tree, but its CLI-derived scripts load
  `../../config.sh`; Flutter must therefore write config at the temporary run
  root.
- Flutter macOS Check protection passes `--launcher` and honors selected modes
  A Default SWD, B C45 Clone, and C C45 Genuine. This intentionally differs
  from the standalone macOS CLI read-only check, where `-l` is globally disabled
  because CLI mode D cannot be graded reliably.
- Preserve guided hold/count/release parsing for Flutter mode B RDP checks.
- Toolkit setup errors such as `Missing config.sh` are not contact failures and
  must not receive the generic SWD/C45 re-seat hint.

## Platform Parity

For script-tree behavior changes, inspect the matching files for relevant
platforms before finishing:

- Windows: `launcher.bat`, `config.cmd`, `dump.bat`, `flash.bat`,
  `flash_compat.bat`, validators, and special scripts.
- Linux: `launcher.sh`, `config.sh`, `dump.sh`, `flash.sh`,
  `flash_compat.sh`, validators, and special scripts.
- macOS: same shell script pattern as Linux, with architecture-aware OpenOCD
  paths in `config.sh` and installer considerations in `installer.sh`.

For Flutter-only GUI changes, platform parity usually means preserving the
underlying OpenOCD command behavior and safety verdicts, not editing every
legacy script.

## Configuration Model

The script launchers persist connection-mode choices by rewriting `TARGET` in
`config.cmd` or `config.sh`.

- Default / blinker-buttons mode uses the default target config.
- C45 clone ST-LINK mode uses the C45 target config and may use
  `CONNECT_TIMEOUT`.
- C45 genuine ST-LINK mode uses the nRST target config.
- Power-race uses a respawn strategy to catch the target at power-on.

If target file names or paths change, update detection and rewrite logic at the
same time.

## Binary Validation Expectations

The shared validators are part of the safety boundary. They should continue to:

- require a file path;
- require the file to exist;
- require a `.bin` extension;
- require exactly `131072` bytes unless a documented `nosize` path is used;
- reject single-byte repeated content;
- expose normalized/resolved file variables consumed by flash scripts.

Avoid duplicating validation logic in callers. Prefer updating the shared
validator and then consuming its result.

### Staged Dumps and the Two Dump Verdicts

Dump output is validated before it is allowed to look like a backup:

- Every read writes `<name>.bin.part` and is renamed to `.bin` only after
  `Firmware.inspectDump` returns `ok`. This covers Backup, the mandatory
  pre-flash backup, and the SHU-compat raw read. Do not write a dump straight to
  its final `.bin` name: identity lives at 0x1F000 in the last 4 KB, so a
  truncated read can never contain it, and a `.bin` picker must never be able to
  offer one.
- `inspectDump` reports two different kinds of failure and they must stay
  distinct in WORDING, not in flow. Incomplete or single-repeated-byte junk is a
  failed read. A full-size all-`0x00` (readout protection) or all-`0xFF` (erased
  chip) read is a complete, correct read of a chip with nothing to save, and its
  message must point at Check protection and never imply the read failed.
  `DumpCheck.isEvidence` selects the dialog's title for this; both kinds get the
  same trash offer, and both keep the `.part` name whatever the operator
  decides. A filename must not assert a diagnosis.
- A verdict about the chip is not a rejected input. Pass `finding: true` to
  `_finishReal` for those, so the failure screen offers `Dismiss` instead of
  sending the operator back to setup or blaming the selected firmware.
- `lib/engine/trash.dart` moves files to the OS trash and has no hard-delete
  path. Keep it that way. If a platform move fails, leave the file and report
  where it is; never fall back to deleting it. macOS must not use the Finder
  `osascript` route (automation permission prompt).
- The cleanup offer is suppressed while auto-retry is armed. Do not put a modal
  in front of an operator whose hands are on the probe.
- `Firmware.validateOpenOcdPath` carries the brace/non-ASCII guard for both
  firmware inputs and dump destinations, and destinations are checked before the
  run. Keep that pre-run check when touching dump paths.

### The x3utils Folder

Everything a GUI run produces lands under ONE user-chosen root, so "send me your
backup and the log" is one place to look:

- `Firmware.root` is the single setting. Subfolder names are fixed and there are
  no per-folder overrides: `backup/`, `compat/`, `unpacked_zip3/`,
  `packed_zip3/`, `logs/`. Do not add a second path preference, and do not
  reintroduce a per-call destination override on the path helpers.
- The default is `C:\x3utils` on Windows and `~/x3utils` on Linux/macOS.
  Deliberately outside Documents, which OneDrive redirects, and deliberately not
  `~/.local/share`: the user has to be able to find these files and send them.
- The 2nd copy stays outside the root and hidden (`%LOCALAPPDATA%\x3utils_backup`,
  `~/.x3utils_backup`, `~/Library/Application Support/x3utils_backup`). A
  redundant copy must not share a parent the user can move or empty.
- The old `backupFolder` preference (GUI v1.2.1 and earlier) is never read
  again. Its string meant
  "where dumps go", not "the parent of `backup/`", so adopting it would move a
  user's backups a level down. There is no migration and none is wanted.
- Never move existing files on a root change. Write to the new place and leave
  the old tree alone.
- A picked root is validated in Settings (`Firmware.validateRootFolder`:
  OpenOCD path rules plus a real write probe). That is in addition to, not
  instead of, the pre-run destination check.
- The Windows GUI suppresses the PowerShell toolkit's partial `_toolkit` file;
  when Save log is enabled, the GUI console log is the one complete persistent
  record (command, raw OpenOCD output, evidence, verdict, and exit code). A
  hand-run of the bundled script without `-NoToolkitLog` keeps its own transcript.
  Linux/macOS still use their existing config.sh and toolkit-log behavior. The
  standalone CLIs have no GUI root setting and must remain unchanged.

### Flutter Firmware Identity and Make zip3 Safety

The guarded Flutter flash paths are stricter than the shared structural
validator and must remain fail-closed:

- Backup + Flash and Flash slot 0 accept only the known VCU banner codes
  `xxU2` (ZT3), `xxG3` (G3), `xGT3` (GT3), and `xxF3` (F3), or the exact MCU
  banner `SCOOTER_MCU_0001`. A banner-shaped unknown code is not supported.
- After the mandatory backup, inspect the installed firmware banner in the dump
  and compare it with the selected firmware before any erase/write operation.
  A missing/unsupported banner, VCU/MCU mismatch, or cross-model VCU mismatch
  must abort while preserving and showing the backup path.
- The banner identifies installed firmware, not physical hardware. All supported
  MCU firmware uses `SCOOTER_MCU_0001`; ZT3/GT3/G3 share MCU hardware, but F3
  differs, so the banner cannot detect an F3 MCU mismatch. Do not claim stronger
  MCU compatibility than this evidence supports.
- Guarded selections keep a SHA-256 digest. Recheck the file at Start and after
  the backup so a changed-on-disk firmware cannot reach the write step.
- Flash Only remains the explicitly warned expert override. Do not silently
  apply its permissive policy to either guarded action.

ZIP3 tools is an offline local archive feature, not a compatibility or
BLE-acceptance guarantee:

- Slice is the guarded v1.2.0 full-dump path. It accepts exactly 131072 bytes,
  requires trustworthy ZP evidence to determine the payload boundary, and keeps
  the existing best-effort SHU-key filter. Its intended source is a fresh full
  ST-LINK backup taken immediately after the current firmware was installed
  through BLE, before any ST-LINK firmware write; a structurally valid ZP can
  still be stale and that cannot be detected from the dump alone.
- Pack treats the selected `.bin` as the complete payload and supports X3 VCU,
  MCU, BMS, and BLE package metadata. It must reject a detected full 128 KB
  controller dump, a payload whose length is not `8n + 4` (NinebotTEA would
  change it through zero padding), unsupported or contradictory VCU/MCU banner
  evidence, and VCU/MCU payloads beyond the 61436/59388-byte physical ceilings.
  Re-run these checks at Start so a changed file cannot bypass selection-time
  validation.
- VCU/MCU Pack inputs require a supported banner at payload offset `0x400`; the
  banner type and VCU model must agree with the declared Type/Model. BMS/BLE
  carry no equivalent known banner, so their Type and Model remain manual.
  Corpus size ranges are hints only and must not silently choose identity.
- Pack does not apply ZP or SHU-key checks. Unpack accepts internally consistent
  X3 VCU, MCU, BMS, and BLE packages for local extraction, while ZIP import for
  controller flashing remains separately restricted to VCU/MCU.
- A created package must still be tested through the BLE app's Load from file.
  Keep UI wording conservative and preserve operator responsibility for the
  declared Type and Model.

## OpenOCD Notes

- Windows and Linux use bundled `oocd/` directories.
- macOS uses bundled `xpack-openocd-0.12.0-7-darwin-*` directories selected by
  `uname -m` in the CLI. The Flutter bundle contains universal xPack OpenOCD
  and support dylibs.
- The C45 clone path uses guided OpenOCD Tcl helpers such as `guided_connect`,
  `guided_flash_connect`, and `do_flash_and_verify`.
- Non-C45 paths call OpenOCD with the ST-LINK interface config,
  initialize/reset halt, and then dump or erase/write/verify.

Distinguish the chip target name `at32f415xx` from the OpenOCD flash-driver
command family `at32f4xx`.

Do not casually replace vendored OpenOCD binaries or Tcl scripts. If they must
change, document the source/version and verify all platform launch paths.

## Tcl Is The Hardware Control Layer

The C45 target configs are the key hardware-specific logic in the repo. They
implement the manual connect-under-reset workflow for clone ST-LINK adapters
and should be treated as the stable OpenOCD API.

Preserve these Tcl procedures and their semantics:

- `guided_connect {timeout}` - guided connect-under-reset flow for dumping.
- `guided_flash_connect {timeout}` - guided connect-under-reset flow for
  flashing.
- `do_flash_and_verify {path}` - erase, write, verify, and fail hard on errors.
- `do_flash_and_verify_slot0 {path}` - slot-0 write/verify helper.

Flutter is the active GUI/orchestration path. If shared orchestration is
expanded, keep Tcl responsible for OpenOCD target setup, reset/halt behavior,
DEMCR/VC_CORERESET handling, flash driver selection, and hardware-facing failure
handling. Use Flutter/Dart code for orchestration: UI flow, platform detection,
file validation, backup paths, patching bytes, and command construction.

## Testing and Verification

There is no automated test suite that replaces hardware validation. For
non-hardware changes, prefer dry checks:

- Flutter: `dart format`, `flutter analyze`, and the relevant `flutter build`
  target when available.
- macOS Flutter packaging: run `tool/package_macos.sh`; confirm universal app
  and OpenOCD slices, valid deep signature, embedded race cfg/RDP scripts, and
  normal `AppIcon` metadata.
- macOS Flutter RDP: run `flutter test test/rdp_runner_test.dart`; it uses fake
  OpenOCD to verify temporary config placement and A/B/C mode selection without
  touching hardware.
- Bash syntax: `bash -n x3utils_linux/*.sh` and, where possible,
  `bash -n x3utils_mac/*.sh`.
- Windows batch review: inspect with `cmd /c` only for non-hardware code paths,
  and avoid launching flash/dump commands without explicit user approval.
- Validate file-list and path changes with `rg --files`.

### Validation Test Bins (tool/gen_test_bins.dart)

`x3utils_flutter/tool/gen_test_bins.dart` generates the deterministic
validation test-bin set (synthetic full images, slot bins, and mutated zip3
packages). The output lives in the maintainer's private test-bin corpus, which
is local and untracked; the output folder is passed as the first argument.

- Its layout constants are corpus-derived from real hardware dumps on purpose.
  Do not "fix" the tool to import constants from `lib/engine`: it is an
  independent statement of the bin layout, so an engine constant that drifts
  from hardware makes a test fail instead of silently agreeing with the code
  under test.
- Each synthetic differs from its accept baseline by exactly one knob, and the
  emitted `gen_manifest.csv` is the oracle: file, knob turned, expected
  verdict, SHA-256.
- Synthetic images are unflashable by construction (random payload plus an
  ASCII do-not-flash marker); unmodified real corpus files are copied in to
  pin constants and formats. Real device serials, OEM firmware keys, and the
  6-byte device rand that follows the key are identity material and must not
  be quoted in tracked files.
- One manifest row intentionally pins current behavior rather than desired
  behavior: the exact-64-KiB slot-size window edge. Update its expectation in
  the same change that tightens the window. (The ZP scan-order pin was retired
  when extraction was hardened: the authoritative `0x1F800` record now wins
  outright, and a relocated record is honored only when the page's candidates
  are unanimous — conflicts refuse rather than guess.)

For hardware-facing behavior, explain what was reviewed and what still requires
a real device to verify.

## Developer Workflow Context

This is primarily a single-maintainer project, but work happens across multiple
Windows, Linux, and macOS workstations and laptops. Chat context may be lost
between sessions. Prefer writing durable decisions and test results into repo
files instead of relying on conversation history.

- Use `docs/testing.md` for real hardware testbed boards, workstation coverage,
  manual checklists, and regression notes.
- Use `docs/DEVLOG.md` for short chronological notes about decisions, test
  results, and why a change was made.

The maintainer has real testbed boards that have been reflashed many times. Do
not assume that lack of CI means lack of testing; hardware validation is manual
and should be recorded clearly when it is done.

## Style

- Keep shell scripts portable within their platform.
- Preserve CRLF-sensitive Windows batch readability and ASCII output unless a
  file already requires otherwise.
- Keep user prompts clear and conservative; this utility is used around firmware
  writes.
- Prefer small, direct changes over broad refactors.
- Do not modify generated backup or compatibility output files.
