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
