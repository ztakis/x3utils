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

## Dump Test

- Select the intended connection mode.
- Run full 128 KB dump.
- Confirm output file exists in the platform backup folder.
- Confirm secondary backup exists if that option is enabled.
- Confirm validator accepts the dumped file.
- Note whether read protection or connection timing affected the run.

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

## Regression Notes

Use this section for failures that should be remembered.

### YYYY-MM-DD

- Issue:
- Platform:
- Board:
- Reproduction:
- Fix or workaround:
