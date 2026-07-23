# Flutter v1.2.0 Minimum macOS and Linux Validation

This is the minimum follow-up for the final Flutter v1.2.0 BETA checkout.
Windows already carries the exhaustive firmware-input and message-truth pass.
Do not replay that full matrix on macOS or Linux.

Run this checklist against the packaged application, not only a debug build.
Keep the complete private test corpus intact; the checklist names only the
fixtures needed for this minimum run.

## Status

- Linux x86_64: complete (2026-07-24).
- macOS: pending.

## Stop rule

When the dry/package checks, packaged-app smoke, and one matching guarded write
pass on an OS, record the evidence and stop. Do not repeat every malformed ZIP,
banner, serial, ZP, model, component, full-image, and slot-image combination.
If something fails, expand only that branch.

## 1. Dry and package checks

From `x3utils_flutter/`:

```bash
flutter test \
  test/confirmed_file_writer_test.dart \
  test/desktop_path_display_test.dart \
  test/flash_only_validation_test.dart \
  test/firmware_inspection_test.dart \
  test/pack_zip3_dump_test.dart \
  test/rdp_runner_test.dart \
  test/target_identity_test.dart
flutter analyze
```

Do not include `test/widget_test.dart` in this minimum gate. Its existing
1024x768 harness has a known 1 px status-bar overflow and off-screen Advanced
rail taps; those are test-harness limitations, not a platform verdict.

Package the current checkout:

- Linux: `./tool/build_appimage.sh`
- macOS: `./tool/package_macos.sh`

Linux must produce and launch the versioned AppImage with its real
`native/linux` payload. macOS must produce the versioned universal ZIP and pass
the package script's x86_64/arm64, deep-signature, embedded-backend, RDP-script,
and Power-race-cfg checks.

## 2. Packaged-app smoke

Use the final packaged artifact.

1. Confirm the app shows v1.2.0 BETA and opens at the normal 1024x768 layout
   without visible clipping.
2. Select
   `2nd_pass/make_zip3/target_agnostic/16c_truncated_full_SYNTHETIC.bin`
   in Make zip3. Expect the 131072-byte size Snackbar and no output.
3. Select
   `2nd_pass/make_zip3/target_agnostic/9a_make_zip3_source_zt3_vcu_v1.5.5_compat_full.bin`.
   Expect VCU/ZT3 preselection. Create `platform_make_zip3_test.zip`.
4. Repeat the same output name and choose Cancel in the Replace dialog. Confirm
   the existing file's bytes are unchanged.
5. Open Flash Only, select Slot 0 only, and import the created ZIP. Expect valid
   decryption plus matching ZT3/VCU JSON and firmware-banner evidence. Cancel
   the compatibility modal; this step must not flash the synthetic or generated
   validation input.
6. Use one result-path folder button. Finder or the Linux file manager should
   open promptly and the app should remain responsive.

This is enough packaged UI coverage. Do not repeat the Windows OEM-key,
missing/conflicting/relocated-ZP, MD5, JSON, BLE/BMS, or mismatch matrices.

## 3. Minimum hardware check

Use a normal test board, Default SWD, and genuine firmware known to match the
installed target. Never use a `SYNTHETIC_FULL` image for this section.

1. Run Check connection and require the real packaged OpenOCD backend to report
   evidence-backed PASS.
2. Run one matching Backup + Flash using a genuine full image, preferably the
   test board's own recent backup.
3. Require a new pre-flash backup path, real write evidence, real verify
   evidence, and the green completion screen.

That single guarded write is the platform hardware smoke. Flash Only full,
Flash Only slot 0, guarded mismatch, MCU/VCU mismatch, and ZIP3 slot-0 writes do
not need to be repeated on each OS unless this representative run exposes a
platform-specific problem.

## 4. Record and close

Record, separately:

- OS and CPU architecture;
- package artifact and package-script result;
- focused-test and analyzer results;
- packaged-app smoke evidence;
- board, ST-LINK, mode, selected genuine firmware, backup path, write evidence,
  and verify evidence for the single hardware run;
- anything skipped, timed out, or unavailable.

Add completed evidence to `docs/testing.md` and a short closeout to `DEVLOG.md`.

BLE app "Load from file" is a separate, one-time device acceptance test for a
created package. It is not repeated per desktop OS. Until that succeeds, call
the generated package structurally accepted by x3utils, not BLE-proven.
