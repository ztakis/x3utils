# x3utils GUI v1.2.0

> **Draft** — subject to edit before release. Open item: Apple-Silicon validation
> pass on macOS still pending (all macOS testing to date is Intel; the universal
> build's arm64 slice is verified to exist but not yet run on Apple Silicon).

**The BLE-loop release.** v1.2.0 adds the *Make zip3* firmware packer, hardens every
firmware-write path with model/banner validation, and graduates the GUI out of BETA.
Validated on Windows and Linux; macOS pending final Apple-Silicon sign-off.

## New

- **Make zip3 packer** — a new offline Advanced action that packs a slot-0 `.bin`
  into a ready-to-flash VCU/MCU `zip3` for the BLE update loop. No device, no risk.
  A SHU-key gate accepts repo firmware (default/blank key) and refuses OEM dumps,
  with an optional **Enforce model** switch that binds the package to its declared
  model so it won't load on the wrong hardware.
- **zip3 firmware import** — load a `.zip3` package directly; it's validated by
  model and firmware banner before anything is written.
- **Four additional theme accents** in the picker.
- **Idle "armed shimmer"** — the idle hero plate now has a slow diagonal highlight
  pass so the app reads as alive and waiting rather than hung.

## Safety & validation

- **Serials inform, banners enforce** — retired serial-based blocking; the firmware
  banner is now the authority for accept/reject, and serials are shown as context.
- **Flash Only hardening** — validated slot-0 scope, an entry-gate warning, a hard
  banner-reject on incompatible firmware, a slot-0 size window, and a target-ID guard.
- **Clearer errors** for unsupported VCU/MCU firmware, and hardened ZP-length extraction.
- **Fail-closed** everywhere: a missing OpenOCD backend refuses to run rather than
  degrading.

## Polish

- **Validating state** shown after flash completes and during the final OpenOCD hold,
  so a successful write is unambiguous.
- Reworked hero: stakes/telemetry eyebrow, locked-zone treatment, optically-centred
  content, and a **4:3 1024×768** startup window across all three OSes.
- Smaller settings toggle and assorted layout cleanups; fixed a timer-cleanup leak.

## Platform

- First stable (non-BETA) build for **Windows, Linux, and macOS**.
- Minimum hardware/build validation closed on Linux (AppImage) and macOS Intel
  (universal build) as documented in
  `docs/flutter-v1.2.0-minimum-macos-linux-validation.md`.
- **Pending:** Apple-Silicon (arm64) validation pass before macOS is signed off.

## Notes

- Builds are unsigned — Windows SmartScreen and macOS Gatekeeper will prompt on
  first launch.
