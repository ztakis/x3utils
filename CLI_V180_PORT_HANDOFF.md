# CLI v1.8.0 Linux/macOS port handoff

Temporary cross-machine handoff. Delete this file after the Linux and macOS
ports are complete and their durable results are recorded in `DEVLOG.md` and
`docs/testing.md`.

## Settled direction

- Flutter is the primary feature path. The CLI selectively adopts useful GUI
  behavior without promising full feature parity.
- Keep the existing flat platform layouts. Do not move scripts into a new
  directory.
- Keep standalone entry points working:
  - Windows supports drag-and-drop/arguments for firmware scripts.
  - Bash scripts support direct execution, arguments where implemented, and
    their existing source-path prompts.
- Installers remain at platform root.
- CLI v1.8.0 is a useful cross-platform convergence release. Do not change
  `x3utils_flutter/VERSION` as part of it.

## Windows reference implementation

Reference files:

- `x3utils_win/connection_test.bat`
- `x3utils_win/launcher.bat`
- `x3utils_win/config.cmd`
- `x3utils_win/race_grade.cmd`
- `x3utils_win/special/flash_only.bat`
- `x3utils_win/special/flash_slot0.bat`
- `x3utils_win/special/rdp/rdp.ps1`

Main launcher order:

1. Check Connection
2. Backup Full Memory (128 KB)
3. Flash SHU Compatible
4. Backup + Flash Loaded File
5. Load / Change Target `.bin` File
6. Advanced
7. Exit

Connection keys A/B/C/D and the clone-C45 timeout key remain unchanged.

Advanced submenu:

1. Flash Only - No Backup
2. Flash Slot 0
3. Check Protection
4. Unlock / Rescue - Mass Erase
5. Back

Flash Only and Flash Slot 0 are launched without a firmware argument so they
retain their standalone prompts and separate validation behavior. Slot 0 does
not reuse the main launcher's full-128-KB loaded file.

Windows protection shortcuts call the consolidated PowerShell toolkit with the
launcher-selected mode:

```text
rdp.ps1 -Check -Launcher
rdp.ps1 -Rescue -Launcher
```

They intentionally do not block Mode D. The RDP toolkit remains directly
callable for users who need its other standalone verbs/options.

## Connection-check behavior to port

- It is read-only: connect/halt and `flash probe 0`; no dump or write.
- A: normal interface + `at32f415xx.cfg`, init/reset halt/probe.
- B: load `at32f415xx_c45.cfg` and run
  `guided_connect {CONNECT_TIMEOUT}`. Output must stay live because the Tcl
  procedure asks the operator to ground/release nRST and waits for input.
- C: normal interface + `at32f415xx_nrst.cfg`, init/reset halt/probe.
- D: fresh OpenOCD processes using the existing race cfg and grading helper;
  success must reach `flash probe 0`.
- A/B/C failures offer Enter to retry or Q to quit. Keep the implementation
  simple; do not add logging/tee infrastructure merely to classify their output.
- D retains its temporary per-attempt log because race grading requires it.

Windows hardware results:

- A: PASS, including missing-adapter retry then successful flash-bank probe.
- B: PASS, including live guided prompts, retry, target halt, and probe.
- C: PASS, including contact-failure retry then successful halt/probe.
- D: PASS; test catch succeeded on attempt 47 and confirmed the flash bank.
- Integrated Windows launcher: all testing completed, PASS.

## Linux port

- Add `x3utils_linux/connection_test.sh` using the Windows behavior and existing
  Bash/config/race conventions; do not transliterate batch structure blindly.
- Update `x3utils_linux/launcher.sh` to the settled main order and Advanced
  submenu.
- Advanced Flash Only and Slot 0 should call their Bash scripts with no file
  argument.
- Protection shortcuts should honor launcher selection using the existing Bash
  `-l`/`--launcher` interface:

```text
special/rdp/rdp_check.sh -l
special/rdp/rescue_unlock.sh -l
```

- Do not add a launcher-level Mode D block.
- Run `bash -n` across the normal, special, and RDP shell scripts, then test
  A/B/C/D on hardware before changing `x3utils_linux/VERSION` to `1.8.0`.

## macOS port cautions

- Port only after Linux behavior settles; use the Linux result as the immediate
  shell reference while preserving macOS OpenOCD/xPack path differences.
- The macOS standalone RDP check has platform-specific launcher-mode limits in
  the current implementation. Inspect `x3utils_mac/special/rdp/rdp_check.sh`
  and current documented/tested behavior before wiring Advanced Check; do not
  assume Linux `-l` parity.
- Rescue and other RDP actions must preserve macOS config path expectations.
- Preserve executable permissions and the root-level `installer.sh`.
- Run Bash syntax checks and real A/B/C/D hardware checks, then change
  `x3utils_mac/VERSION` to `1.8.0` only after the port passes.

## Current version and Git state at handoff

- `x3utils_win/VERSION`: 1.8.0, modified in the working tree.
- `x3utils_linux/VERSION`: 1.7.0.
- `x3utils_mac/VERSION`: 1.7.0.
- `x3utils_flutter/VERSION`: 1.2.0.
- `x3utils_win/connection_test.bat` was committed separately on 2026-07-18.
- At handoff creation, the Windows launcher/version work plus this documentation
  remained uncommitted. Recheck `git status` after pulling on each machine.
