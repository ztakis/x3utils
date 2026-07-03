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

- [01. ST-LINK pinouts](01.-ST-LINK-pinouts)
- [02. Windows quick start](02.-Windows-quick-start)
- [03. Linux quick start](03.-Linux-quick-start)
- [04. macOS quick start](04.-macOS-quick-start)
- [05. Connection modes](05.-Connection-modes)
- [06. Special mode / blinker buttons](06.-Special-mode-blinker-buttons)
- [07. Clone ST-Link C45 guide](07.-Clone-ST-Link-C45-guide)
- [08. Genuine ST-Link guide](08.-Genuine-ST-Link-guide)
- [09. Backups and flashing safely](09.-Backups-and-flashing-safely)
- [10. Troubleshooting](10.-Troubleshooting)

## Safety

This is not a normal phone app or scooter setting. ST-LINK talks directly to the MCU on the VCU. If flashing is interrupted, wiring is unstable, or the wrong file is written, the VCU may stop working until it is recovered.

The tools are tested heavily on testbed boards, including hundreds of dump and flash cycles, but end-user setups often fail because of fragile wiring or poor contact. Take your time with the physical connection.

