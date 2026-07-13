# AGENTS.md

Guidance for automated coding agents working in this repository.

## Project Overview

This repository contains cross-platform ST-LINK/OpenOCD utilities for
third-generation Ninebot scooter controllers.

The current active Windows user path is the Flutter GUI under
`x3utils_flutter/`. The older script and launcher trees are still important
as proven behavior references and platform support.

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
- `x3utils_flutter/` - active Flutter GUI path, including Windows runtime
  assets and OpenOCD orchestration.
- `x3utils_win/` - Windows `.bat`/`.cmd` implementation and bundled OpenOCD.
- `x3utils_linux/` - Linux shell implementation and bundled OpenOCD.
- `x3utils_mac/` - macOS shell implementation and bundled xPack OpenOCD.
- `docs/testing.md` - manual hardware test matrix, checklists, and regression
  notes.
- `DEVLOG.md` - short chronological development memory for decisions, handoffs,
  and test notes.
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

The Flutter GUI is now the active Windows path. For GUI work:

- Prefer the existing controller/runner structure over adding parallel logic.
- Keep OpenOCD output visible and do not hide important error lines behind
  generic UI messages.
- Success and failure handling should remain stricter than progress animation.
- Power-race is a connection strategy, not a separate truth model. Where
  possible, share evidence parsing with the other real OpenOCD modes.
- Preserve guided C45 hold/count/release prompts when changing real OpenOCD
  line parsing.

For current progress checklist work, the intended direction is:

- generalize `_advanceRaceStage(line)` to an OpenOCD-stage parser used by all
  real modes;
- drive progress from markers such as `target halted`, `flash 'at32f415xx'
  found`, `dumped`, `erased`, `wrote`, and `verified`;
- manually mark app-side stages such as dump validation, compat patching, and
  forced backup validation where useful.

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

## OpenOCD Notes

- Windows and Linux use bundled `oocd/` directories.
- macOS uses bundled `xpack-openocd-0.12.0-7-darwin-*` directories selected by
  `uname -m`.
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
- Bash syntax: `bash -n x3utils_linux/*.sh` and, where possible,
  `bash -n x3utils_mac/*.sh`.
- Windows batch review: inspect with `cmd /c` only for non-hardware code paths,
  and avoid launching flash/dump commands without explicit user approval.
- Validate file-list and path changes with `rg --files`.

For hardware-facing behavior, explain what was reviewed and what still requires
a real device to verify.

## Developer Workflow Context

This is primarily a single-maintainer project, but work happens across multiple
Windows, Linux, and macOS workstations and laptops. Chat context may be lost
between sessions. Prefer writing durable decisions and test results into repo
files instead of relying on conversation history.

- Use `docs/testing.md` for real hardware testbed boards, workstation coverage,
  manual checklists, and regression notes.
- Use `DEVLOG.md` for short chronological notes about decisions, test results,
  and why a change was made.

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
