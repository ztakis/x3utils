import 'dart:typed_data';

import 'firmware.dart' show Firmware;

enum ZpRecordState {
  /// Slot payloads do not contain the full image's identity/ZP page.
  notApplicable,

  /// One trustworthy record named a payload length inside the slot window.
  readable,

  /// Multiple relocated records passed the guards but disagreed on length.
  conflicting,

  /// No guard-passing record was found.
  unavailable,

  /// The supplied bytes do not contain the full identity page.
  fullImageRequired,
}

/// Read-only evidence about the firmware-length record in a full image.
///
/// [readable] means the record is structurally trustworthy enough to name a
/// payload length. It does not prove that the record is fresh: an ST-Link
/// slot-0 write can leave a stale record behind.
class ZpInspection {
  const ZpInspection._(this.state, {this.payloadLength});

  const ZpInspection.notApplicable() : this._(ZpRecordState.notApplicable);

  const ZpInspection.readable(int payloadLength)
    : this._(ZpRecordState.readable, payloadLength: payloadLength);

  const ZpInspection.conflicting() : this._(ZpRecordState.conflicting);

  const ZpInspection.unavailable() : this._(ZpRecordState.unavailable);

  const ZpInspection.fullImageRequired()
    : this._(ZpRecordState.fullImageRequired);

  final ZpRecordState state;
  final int? payloadLength;
}

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

  // The record lives in the top user/identity page. Every real dump surveyed
  // holds it at exactly 0x1F800, so that offset is authoritative: a valid
  // record there wins outright. The full-page scan is only a fallback for a
  // relocated record, and it must be unanimous — when guard-passing candidates
  // disagree on the length, extraction refuses rather than letting whichever
  // stray `ZP` comes first silently win.
  static const int _knownOffset = 0x1F800;
  static const int _searchStart = 0x1F000;
  static const int _searchEnd = 0x20000;
  static const int _lenFieldFromMagic = 8; // LE u32 at ZP+8

  /// Extract the exact slot-0 payload from [dump], or throw a [FormatException]
  /// (fail-closed) when no trustworthy `ZP` length record is present.
  ///
  /// A valid record at the authoritative [_knownOffset] is used directly.
  /// Otherwise the page is scanned for a relocated record, which must be
  /// unanimous: conflicting guard-passing candidates refuse instead of picking
  /// the first one. The guards, proven necessary by a real `len=0` case (a
  /// naive read gives a negative length), accept a candidate only when the
  /// magic matches, the encoded length is non-zero, the derived payload length
  /// is `≡4 (mod 8)` (the decrypted-firmware invariant), it falls inside the
  /// slot-0 size window, and it fits within the dump. Anything else means Make
  /// zip3 must refuse this image rather than guess a trim. These structural
  /// checks cannot detect a valid record made stale by a later ST-Link slot-0
  /// write.
  static Uint8List payloadFromDump(List<int> dump) {
    final status = inspect(dump);
    return switch (status.state) {
      ZpRecordState.readable => _extract(dump, status.payloadLength!),
      ZpRecordState.fullImageRequired => throw FormatException(
        'Dump is ${dump.length} bytes — a full ${Firmware.expectedSize}-byte '
        'image is required to read the ZP length record.',
      ),
      ZpRecordState.conflicting => throw const FormatException(
        'Make zip3 stopped: this dump holds conflicting ZP length records, so '
        'x3utils cannot safely determine the exact payload and refuses rather '
        'than guessing.',
      ),
      ZpRecordState.unavailable => throw const FormatException(
        'Make zip3 stopped: this dump has no trustworthy BLE firmware-length '
        'record, so x3utils cannot safely determine the exact payload. This '
        'optional tool requires a fresh full backup taken immediately after a '
        'BLE flash, before any ST-Link firmware write, and refuses rather than '
        'guessing.',
      ),
      ZpRecordState.notApplicable => throw StateError(
        'A full-image ZP inspection cannot be notApplicable.',
      ),
    };
  }

  /// Inspect the ZP page without extracting or throwing.
  ///
  /// This exposes the same evidence [payloadFromDump] uses so other actions can
  /// report what is present without inheriting Make zip3's hard-stop policy.
  static ZpInspection inspect(List<int> dump) {
    if (dump.length < _searchEnd) {
      return const ZpInspection.fullImageRequired();
    }

    // Authoritative offset first: 0x1F800 on every real dump surveyed.
    final known = _payloadLenAt(dump, _knownOffset);
    if (known != null) return ZpInspection.readable(known);

    // Fallback: scan the page for a relocated record, requiring unanimity.
    final lengths = <int>{};
    for (var i = _searchStart; i + _lenFieldFromMagic + 4 <= _searchEnd; i++) {
      final len = _payloadLenAt(dump, i);
      if (len != null) lengths.add(len);
    }
    if (lengths.length == 1) return ZpInspection.readable(lengths.first);
    if (lengths.length > 1) {
      return const ZpInspection.conflicting();
    }
    return const ZpInspection.unavailable();
  }

  /// The payload length named by a guard-passing `ZP` record at [i], or null.
  static int? _payloadLenAt(List<int> dump, int i) {
    if (i + _lenFieldFromMagic + 4 > dump.length) return null;
    if (dump[i] != 0x5A || dump[i + 1] != 0x50) return null; // "ZP"
    final encLen = _u32le(dump, i + _lenFieldFromMagic);
    if (encLen == 0) return null;
    final payloadLen = encLen - 4;
    if (payloadLen % 8 != 4) return null; // decrypted fw is ≡4 (mod 8)
    if (payloadLen < Firmware.slot0MinBytes ||
        payloadLen > Firmware.slot0MaxBytes) {
      return null;
    }
    if (slot0Offset + payloadLen > dump.length) return null;
    return payloadLen;
  }

  static Uint8List _extract(List<int> dump, int payloadLen) =>
      Uint8List.fromList(dump.sublist(slot0Offset, slot0Offset + payloadLen));

  static int _u32le(List<int> b, int o) =>
      b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
}
