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
  });

  final String type;
  final FwVersion version;
  final List<int> tableOffsets;

  /// VCU-only identity. MCU tables carry a controller part number instead,
  /// which is useful for validating the table shape but not for naming the
  /// scooter model.
  final String? serial;
  final String? serialModel;
  final String? regionCode;
  final String? regionLabel;

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

  static const _vcuMarker = <int>[0x5c, 0x50];
  static const _mcuMarker = <int>[0x5c, 0x51];
  static const _idOffset = 0x20;
  static const _vcuSerialLength = 14;
  static const _mcuPartNumberLength = 16;
  static const _vcuVersionOffset = 0x2e; // table index 0x17
  static const _mcuVersionOffset = 0x32; // table index 0x19

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
      offset + _mcuVersionOffset + 2 <= bytes.length;
      offset++
    ) {
      if (_markerAt(bytes, offset, _vcuMarker)) {
        final serial = _asciiAt(bytes, offset + _idOffset, _vcuSerialLength);
        final version = _versionAt(bytes, offset + _vcuVersionOffset);
        if (serial != null && version != null) {
          candidates.add(
            _SramCandidate(
              type: 'VCU',
              version: version,
              offset: offset,
              identityText: serial,
            ),
          );
        }
      } else if (_markerAt(bytes, offset, _mcuMarker)) {
        final partNumber = _asciiAt(
          bytes,
          offset + _idOffset,
          _mcuPartNumberLength,
        );
        final version = _versionAt(bytes, offset + _mcuVersionOffset);
        if (partNumber != null && version != null) {
          candidates.add(
            _SramCandidate(
              type: 'MCU',
              version: version,
              offset: offset,
              identityText: partNumber,
            ),
          );
        }
      }
    }

    if (candidates.isEmpty) {
      return const SramIdentityResult(
        SramIdentityVerdict.notFound,
        reason: 'No structurally valid VCU or MCU runtime table was found.',
      );
    }

    final types = candidates.map((c) => c.type).toSet();
    final versions = candidates.map((c) => c.version).toSet();
    if (types.length != 1 || versions.length != 1) {
      return SramIdentityResult(
        SramIdentityVerdict.conflicting,
        reason:
            'Runtime tables disagree (${types.join('/')} · '
            '${versions.join('/')}).',
      );
    }

    final type = types.single;
    String? serial;
    if (type == 'VCU') {
      final serials = candidates.map((c) => c.identityText).toSet();
      if (serials.length != 1) {
        return const SramIdentityResult(
          SramIdentityVerdict.conflicting,
          reason: 'VCU runtime tables contain different serial numbers.',
        );
      }
      serial = serials.single;
    }

    final prefix = serial?.substring(0, 3);
    final regionCode = serial?.substring(3, 4);
    final regionKey = serial?.substring(0, 4);
    return SramIdentityResult(
      SramIdentityVerdict.identified,
      identity: SramIdentity(
        type: type,
        version: versions.single,
        tableOffsets: candidates.map((c) => c.offset).toList(growable: false),
        serial: serial,
        serialModel: prefix == null ? null : serialModels[prefix],
        regionCode: regionCode,
        regionLabel: regionKey == null ? null : regionLabels[regionKey],
      ),
    );
  }

  static bool _markerAt(List<int> bytes, int offset, List<int> marker) =>
      bytes[offset] == marker[0] && bytes[offset + 1] == marker[1];

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

  static FwVersion? _versionAt(List<int> bytes, int offset) {
    final raw = bytes[offset] | (bytes[offset + 1] << 8);
    final encoded = raw < 0x100 ? 0x100 | raw : raw & 0x0fff;
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
  final FwVersion version;
  final int offset;
  final String identityText;
}
