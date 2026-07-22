import 'dart:typed_data';

import 'firmware.dart' show Firmware;

/// Recover the exact slot-0 firmware payload from a full 128 KB backup dump,
/// using the device's own "update config" record instead of guessing where the
/// firmware ends.
///
/// A BLE-OTA flash leaves non-deterministic junk fill past the live payload, so
/// scanning for the end (trailing-byte trim, tail signatures, periodic-run
/// detection) is unreliable — a stale tail from a longer prior flash can mimic a
/// real end. But near flash `0x1F800` the device stores an ASCII `ZP` magic; the
/// little-endian u32 at `ZP+8` is the ENCRYPTED length (8-aligned), and the exact
/// plaintext payload length is that minus 4. slot 0 begins at dump offset
/// `0x1000` (flash `0x08001000`).
///
/// A BLE flash updates this record, but an ST-Link slot-0 write does not. The
/// cut is deterministic only when the dump was taken after the current firmware
/// was installed through BLE, before any later ST-Link firmware write. A valid
/// but stale record cannot be identified from the dump alone. The guarded
/// extraction was validated byte-exact against the firmware mirror on real
/// fresh BLE-flash dumps across models (g3/zt3) and both types (VCU/MCU). See
/// DEVLOG 2026-07-20 and 2026-07-22.
class Zp {
  const Zp._();

  /// Where slot 0 starts inside a full dump (flash `0x08001000`).
  static const int slot0Offset = 0x1000;

  // The record lives in the top user/identity page (found at 0x1F800 on every
  // dump checked). Scan the whole page and accept the first candidate that
  // passes every guard, so a stray `ZP` in data cannot be mistaken for it.
  static const int _searchStart = 0x1F000;
  static const int _searchEnd = 0x20000;
  static const int _lenFieldFromMagic = 8; // LE u32 at ZP+8

  /// Extract the exact slot-0 payload from [dump], or throw a [FormatException]
  /// (fail-closed) when no trustworthy `ZP` length record is present.
  ///
  /// The guard, proven necessary by a real `len=0` case (a naive read gives a
  /// negative length), accepts a candidate only when the magic matches, the
  /// encoded length is non-zero, the derived payload length is `≡4 (mod 8)` (the
  /// decrypted-firmware invariant), it falls inside the slot-0 size window, and
  /// it fits within the dump. Anything else means Make zip3 must refuse this
  /// image rather than guess a trim. These structural checks cannot detect a
  /// valid record made stale by a later ST-Link slot-0 write.
  static Uint8List payloadFromDump(List<int> dump) {
    if (dump.length < _searchEnd) {
      throw FormatException(
        'Dump is ${dump.length} bytes — a full ${Firmware.expectedSize}-byte '
        'image is required to read the ZP length record.',
      );
    }
    for (var i = _searchStart; i + _lenFieldFromMagic + 4 <= _searchEnd; i++) {
      if (dump[i] != 0x5A || dump[i + 1] != 0x50) continue; // "ZP"
      final encLen = _u32le(dump, i + _lenFieldFromMagic);
      if (encLen == 0) continue;
      final payloadLen = encLen - 4;
      if (payloadLen % 8 != 4) continue; // decrypted fw is ≡4 (mod 8)
      if (payloadLen < Firmware.slot0MinBytes ||
          payloadLen > Firmware.slot0MaxBytes) {
        continue;
      }
      if (slot0Offset + payloadLen > dump.length) continue;
      return Uint8List.fromList(
        dump.sublist(slot0Offset, slot0Offset + payloadLen),
      );
    }
    throw const FormatException(
      'Make zip3 stopped: this dump has no trustworthy BLE firmware-length '
      'record, so x3utils cannot safely determine the exact payload. This '
      'optional tool requires a fresh full backup taken immediately after a '
      'BLE flash, before any ST-Link firmware write, and refuses rather than '
      'guessing.',
    );
  }

  static int _u32le(List<int> b, int o) =>
      b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
}
