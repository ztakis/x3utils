import 'fw_version.dart';

const int kSramBase = 0x20000000;
const int kAt32f415SramLength = 32 * 1024;

enum SramIdentityVerdict { identified, notFound, conflicting }

class SramIdentity {
  const SramIdentity({
    required this.type,
    required this.version,
    required this.tableOffsets,
    this.serial,
    this.serialModel,
    this.regionCode,
    this.regionLabel,
    this.controllerSnMnCandidates = const [],
  });

  final String type;

  /// Null when the record was found but its version field did not decode. The
  /// identity is still real and worth reporting — dropping the whole record
  /// over one unreadable field is what made populated snapshots read as
  /// `notFound`.
  final FwVersion? version;
  final List<int> tableOffsets;

  /// VCU-only scooter identity. MCU tables carry controller SN/MN candidates
  /// instead, which are useful for validating the table shape but are not the
  /// scooter serial and do not name the scooter model.
  final String? serial;
  final String? serialModel;
  final String? regionCode;
  final String? regionLabel;
  final List<String> controllerSnMnCandidates;

  String get displayModel => serialModel?.toUpperCase() ?? 'UNKNOWN MODEL';
}

class SramIdentityResult {
  const SramIdentityResult(this.verdict, {this.identity, this.reason = ''});

  final SramIdentityVerdict verdict;
  final SramIdentity? identity;
  final String reason;

  bool get identified => verdict == SramIdentityVerdict.identified;
}

class SramIdentityParser {
  const SramIdentityParser._();

  /// The record's first marker byte. The SECOND byte is deliberately not
  /// matched: it varies by scooter model (`0x50` on g3, `0x51` on zt3, measured
  /// on four boards across firmware 1.4.15 / 1.5.2 / 1.5.5 / 1.6.1, in RAM and
  /// in the flash identity page alike) and an unseen model would carry an
  /// unseen value. It is NOT a component tag — the same `0x51` carries a zt3
  /// VCU record and a zt3 MCU one — so component is decided by field SHAPE
  /// below, and a record from a model we have never met still parses.
  static const _markerByte = 0x5c;
  static const _idOffset = 0x20;
  static const _secondIdOffset = 0x40;
  static const _vcuSerialLength = 14;
  static const _mcuSnMnLength = 16;

  /// The version halfword sits immediately AFTER the id field, so its offset
  /// follows the id length rather than the component as such:
  ///
  /// - a 14-char serial ends at `+0x2D`, putting the version at `+0x2E`;
  /// - a 16-char SN/MN ends at `+0x2F` and would be overwritten by a halfword
  ///   at `+0x2E`, so that record carries it at `+0x32`.
  ///
  /// Both are confirmed against the ROM-derived version on readable boards:
  /// `+0x2E` on g3 1.6.1 and zt3 1.4.15 / 1.5.5, `+0x32` on a zt3 MCU 1.5.2
  /// whose `+0x2E` holds ASCII from the middle of its own SN/MN — which is the
  /// collision this split exists to avoid.
  static const _vcuVersionOffset = 0x2e;
  static const _mcuVersionOffset = 0x32;

  /// Serial prefixes identify the model family; the fourth character is the
  /// region code. G3 Plus is deliberately separate from G3 so detecting it
  /// cannot silently authorize ordinary G3 firmware policy.
  static const serialModels = <String, String>{
    '1K1': 'zt3',
    '1CG': 'g3',
    '1EF': 'f3',
    '03S': 'gt3',
    '1C2': 'g3 plus',
    '4P2': 'g3 plus',
  };

  /// Observed G3 Plus region codes as of VCU 3.1.8. Uncertain labels stay
  /// explicitly uncertain; the raw fourth character remains the evidence.
  static const regionLabels = <String, String>{
    '1C2U': 'US / China / Global (unconfirmed)',
    '1C2N': 'US / China / Global (unconfirmed)',
    '4P2E': 'Europe / EU (likely)',
    '4P2D': 'Germany',
    '4P2S': 'Europe / EU (likely)',
  };

  static SramIdentityResult parse(List<int>? bytes) {
    if (bytes == null || bytes.isEmpty) {
      return const SramIdentityResult(
        SramIdentityVerdict.notFound,
        reason: 'No SRAM snapshot was returned.',
      );
    }

    final candidates = <_SramCandidate>[];
    for (
      var offset = 0;
      offset + _secondIdOffset + _mcuSnMnLength <= bytes.length;
      offset++
    ) {
      if (bytes[offset] != _markerByte) continue;

      // Component comes from the shape of the id field, never from the marker.
      // A VCU carries a 14-char scooter serial at +0x20 (a 16-char read there
      // runs into the binary byte that follows it, which is exactly how a real
      // VCU record used to be discarded as a malformed MCU one) and a second
      // 16-char field at +0x40. An MCU carries its own 16-char SN/MN at +0x20.
      final serial = _asciiAt(bytes, offset + _idOffset, _vcuSerialLength);
      if (serial != null && serialModels.containsKey(serial.substring(0, 3))) {
        candidates.add(
          _SramCandidate(
            type: 'VCU',
            version: _versionAt(bytes, offset + _vcuVersionOffset),
            offset: offset,
            identityText: serial,
          ),
        );
        continue;
      }
      final controllerSnMn = _asciiAt(
        bytes,
        offset + _idOffset,
        _mcuSnMnLength,
      );
      if (controllerSnMn != null) {
        candidates.add(
          _SramCandidate(
            type: 'MCU',
            version: _versionAt(bytes, offset + _mcuVersionOffset),
            offset: offset,
            identityText: controllerSnMn,
          ),
        );
      }
    }

    if (candidates.isEmpty) {
      return const SramIdentityResult(
        SramIdentityVerdict.notFound,
        reason: 'No structurally valid VCU or MCU runtime table was found.',
      );
    }

    final types = candidates.map((c) => c.type).toSet();
    // Only DECODED versions can disagree. A record whose version field did not
    // decode abstains rather than voting for "null", so one unreadable field no
    // longer turns an otherwise-agreeing set into a conflict.
    final versions = candidates
        .map((c) => c.version)
        .whereType<FwVersion>()
        .toSet();
    if (types.length != 1 || versions.length > 1) {
      return SramIdentityResult(
        SramIdentityVerdict.conflicting,
        reason:
            'Runtime tables disagree (${types.join('/')} · '
            '${versions.isEmpty ? 'no version' : versions.join('/')}).',
      );
    }

    final type = types.single;
    String? serial;
    var controllerSnMnCandidates = const <String>[];
    if (type == 'VCU') {
      final serials = candidates.map((c) => c.identityText).toSet();
      if (serials.length != 1) {
        return const SramIdentityResult(
          SramIdentityVerdict.conflicting,
          reason: 'VCU runtime tables contain different serial numbers.',
        );
      }
      serial = serials.single;
    } else {
      controllerSnMnCandidates = candidates
          .map((candidate) => candidate.identityText)
          .toSet()
          .toList(growable: false);
    }

    final prefix = serial?.substring(0, 3);
    final regionCode = serial?.substring(3, 4);
    final regionKey = serial?.substring(0, 4);
    return SramIdentityResult(
      SramIdentityVerdict.identified,
      identity: SramIdentity(
        type: type,
        version: versions.isEmpty ? null : versions.single,
        tableOffsets: candidates.map((c) => c.offset).toList(growable: false),
        serial: serial,
        serialModel: prefix == null ? null : serialModels[prefix],
        regionCode: regionCode,
        regionLabel: regionKey == null ? null : regionLabels[regionKey],
        controllerSnMnCandidates: controllerSnMnCandidates,
      ),
    );
  }

  static String? _asciiAt(List<int> bytes, int offset, int length) {
    if (offset < 0 || offset + length > bytes.length) return null;
    final values = bytes.sublist(offset, offset + length);
    final valid = values.every(
      (v) =>
          (v >= 0x30 && v <= 0x39) ||
          (v >= 0x41 && v <= 0x5a) ||
          (v >= 0x61 && v <= 0x7a),
    );
    return valid ? String.fromCharCodes(values) : null;
  }

  /// Decodes the nibble-packed `0xMmp` halfword. A raw value below `0x100` is
  /// REJECTED rather than promoted to major 1: real firmware stores the major
  /// nibble (0x0161, 0x014F, 0x0155 observed), so the old promotion only ever
  /// manufactured plausible-looking versions out of low-valued noise.
  static FwVersion? _versionAt(List<int> bytes, int offset) {
    if (offset + 2 > bytes.length) return null;
    final raw = bytes[offset] | (bytes[offset + 1] << 8);
    final encoded = raw & 0x0fff;
    final major = (encoded >> 8) & 0xf;
    final minor = (encoded >> 4) & 0xf;
    final patch = encoded & 0xf;
    if (major == 0) return null;
    return FwVersion(major, minor, patch);
  }
}

class _SramCandidate {
  const _SramCandidate({
    required this.type,
    required this.version,
    required this.offset,
    required this.identityText,
  });

  final String type;
  final FwVersion? version;
  final int offset;
  final String identityText;
}
