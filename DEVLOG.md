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
