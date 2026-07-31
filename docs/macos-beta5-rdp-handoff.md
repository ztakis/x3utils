# macOS BETA5 RDP single-log handoff

This handoff validates the Flutter GUI's Unix RDP logging change in
`1.2.3+11 BETA5` on macOS. The first pass uses a debug build from the source
tree. That is source-build and hardware evidence, not packaged-app evidence.

## Commit before changing OS

Suggested commit message:

```text
flutter: keep one RDP log for Unix GUI checks

- pass --no-toolkit-log for Linux/macOS GUI Check
- preserve temporary attempt capture, retries and verdict parsing
- retain toolkit logs for direct script runs
- leave Unix Rescue and standalone CLIs unchanged
- add Unix suppression and compatibility tests
- bump the GUI to 1.2.3+11 BETA5
- document target-platform verification still pending
```

Record the resulting commit hash for the test report:

```bash
git rev-parse --short HEAD
```

## Build and preflight on macOS

From `x3utils_flutter`:

```bash
flutter test test/rdp_runner_test.dart
flutter analyze
flutter build macos --debug
open build/macos/Build/Products/Debug/x3utils.app
```

The focused test uses fake OpenOCD. On macOS it exercises the Unix GUI
suppression path, direct-script compatibility, macOS A/B/C target selection,
and redirected retry prompts without touching hardware.

`OpenOcdPaths.find()` supports this debug layout: it walks upward from the
debug executable until it finds the source tree's `native/macos` backend.

## Hardware Check procedure

1. Enable **Save log** in the GUI.
2. Select Check protection.
3. Use A / Default SWD, B / C45 Clone, or C / C45 Genuine. Power-race RDP is
   blocked by design.
4. Run Check protection against the normal testbed.
5. If contact fails, use the normal GUI retry and confirm that both the failed
   and successful attempts remain visible in the one GUI log.

The console command must contain:

```text
> bash rdp_check.sh --launcher --no-toolkit-log
```

Mode-specific text may follow `--launcher`, but `--no-toolkit-log` must be
present for GUI Check.

## Acceptance criteria

- Exactly one new file appears under `~/x3utils/logs/rdp_check/`:
  `rdp_check_<stamp>.log`.
- No new `rdp_check_toolkit_<stamp>.log` appears.
- The GUI log contains the command, raw OpenOCD output, Evidence, Verdict, and
  `== rdp exit <code> ==`.
- For the normal unlocked testbed, the expected result is complete USD and
  main-flash evidence, `NOT PROTECTED`, and exit 0.
- A contact failure followed by a successful retry must leave both attempts in
  the GUI log and still finish with the evidence-based verdict.
- `Missing config.sh`, `Failed to create log directory`, a missing verdict, or
  a new `_toolkit` file is a regression in this change.

Do not delete older `_toolkit` files before the test. Distinguish the new run by
its timestamp. A simple before/after listing is sufficient:

```bash
ls -lt ~/x3utils/logs/rdp_check
```

## Evidence classification

- `flutter test`: fake-runner/unit evidence.
- `flutter analyze`: static analysis.
- Debug GUI Check: source-build hardware evidence.
- `tool/package_macos.sh` plus a Check from that app: packaged-app hardware
  evidence, still separate and still required before claiming packaged macOS
  coverage.

A green process exit alone is not enough. The hardware pass requires the
action-specific option-byte and main-flash evidence plus the final verdict.

## If Check fails

First preserve the GUI console and any log that was written. Then collect:

```bash
ls -la ~/x3utils/logs/rdp_check
ls -td "${TMPDIR%/}"/x3utils_rdp_* 2>/dev/null | head -1
```

Use the path returned by the second command:

```bash
runroot="/path/returned/above"
ls -la "$runroot"
ls -la "$runroot/special/rdp"
grep -n 'no-toolkit-log' "$runroot/special/rdp/rdp_check.sh"
grep -E '^(OPENOCD_BIN|SCRIPTS_DIR|TARGET|CONNECT_TIMEOUT|X3UTILS_RDP_LOG_DIR|RACE)' \
  "$runroot/config.sh"
```

Also capture the exact output of:

```bash
flutter test test/rdp_runner_test.dart
flutter analyze
```

Do not treat a silent or timed-out test as a pass.

## Failure interpretation

- `Error: open failed` with no option-byte/main-flash evidence is normally a
  contact or setup failure, not automatically a logging regression.
- A successful retry that produces the complete verdict in the single GUI log
  is a pass.
- `Missing config.sh` means the macOS temporary-root layout failed.
- `Failed to create log directory` during GUI Check suggests the suppression
  flag was absent or a stale script ran; the suppressed path does not create the
  toolkit directory.
- A command line containing `--no-toolkit-log` that still creates `_toolkit`
  points to a stale or mismatched copied script. Check the latest temp tree.
- No GUI log after a successful Check may simply mean Save log was off. Confirm
  the setting and look for the GUI's `log saved` line before calling it a code
  failure.
- A log that stops before Evidence/Verdict or lacks the RDP exit line is
  incomplete and must not be accepted.

## Failure handoff template

```text
macOS BETA5 RDP Check failed

Commit:
macOS version/architecture:
Board/testbed:
ST-LINK type:
Connection mode:
Save log: ON/OFF

flutter test result:
flutter analyze result:

GUI command line:
GUI final message:
RDP exit code:

New files under ~/x3utils/logs/rdp_check:
Was an _toolkit file created:

Latest x3utils_rdp_* temp path:
Did config.sh exist at its root:
Did copied rdp_check.sh contain --no-toolkit-log:

Observed USD/FAP evidence:
Observed main-flash evidence:
Observed verdict:

Attached:
- complete GUI RDP log, if created
- console output from the first command line through exit
- directory and temporary-tree listings above
```

## Pass handoff

If the debug check passes, report:

```text
macOS BETA5 debug RDP Check passed

Commit:
macOS version/architecture:
Board/testbed:
ST-LINK type:
Connection mode:

Focused tests: pass
flutter analyze: pass
New GUI logs: 1
New toolkit logs: 0
Retry exercised: yes/no
USD/FAP evidence:
Main-flash evidence:
Verdict and exit code:
```

After that result is recorded, build with `./tool/package_macos.sh` for the
separate packaged-app verification.
