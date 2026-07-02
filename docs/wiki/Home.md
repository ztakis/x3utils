# x3utils Wiki

Welcome to the x3utils documentation.

x3utils is a set of ST-LINK/OpenOCD utilities for supported X3 / third-generation scooter VCUs. It is meant to make common VCU jobs easier:

- make a full 128 KB backup;
- flash a selected 128 KB `.bin` file;
- patch current firmware for SHU-compatible workflows;
- connect through normal SWD, service/blinker mode, clone ST-LINK connect-under-reset, or genuine ST-LINK connect-under-reset.

Supported model family:

- ZT3 Pro
- Max G3
- F3 / F3 Pro
- GT3

## Start Here

1. Read the safety notes.
2. Identify your ST-LINK type.
3. Check the pinout page before connecting wires.
4. Choose the correct connection mode.
5. Run a full memory dump before flashing.

## Pages

- [1. ST-LINK pinouts](1.-ST-LINK-pinouts)
- [2. Windows quick start](2.-Windows-quick-start)
- [3. Linux quick start](3.-Linux-quick-start)
- [4. macOS quick start](4.-macOS-quick-start)
- [5. Connection modes](5.-Connection-modes)
- [6. Special mode / blinker buttons](6.-Special-mode-blinker-buttons)
- [7. Clone ST-Link C45 guide](7.-Clone-ST-Link-C45-guide)
- [8. Genuine ST-Link guide](8.-Genuine-ST-Link-guide)
- [9. Backups and flashing safely](9.-Backups-and-flashing-safely)
- [10. Troubleshooting](10.-Troubleshooting)

## Safety

This is not a normal phone app or scooter setting. ST-LINK talks directly to the MCU on the VCU. If flashing is interrupted, wiring is unstable, or the wrong file is written, the VCU may stop working until it is recovered.

The tools are tested heavily on testbed boards, including hundreds of dump and flash cycles, but end-user setups often fail because of fragile wiring or poor contact. Take your time with the physical connection.
