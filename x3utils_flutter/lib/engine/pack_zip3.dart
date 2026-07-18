import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'device_spec.dart';
import 'ninebot_tea.dart';

/// Dart port of ScooterHacking's fw-zip-package-v3 `Python/pack.py`:
/// https://github.com/scooterhacking/fw-zip-package-v3
///
/// Builds a "v3" firmware ZIP: a plain `FIRM.bin` and/or a NinebotTEA-encrypted
/// `FIRM.bin.enc`, plus an `info.json` metadata file (MD5s included) and an
/// optional `params.txt`.
///
/// The ZIP bytes are NOT expected to be identical to Python's `zipfile` output
/// (headers, compression level, and timestamps differ). Equivalence is at the
/// archive level: same member names, same member bytes, same `info.json`
/// structure/key order, and matching MD5 hex digests.
class PackV3 {
  static const Set<String> allowedEncFlags = {'both', 'plain', 'encrypted'};
  static const Set<String> allowedTypeFlags = {'DRV', 'BMS', 'BLE'};
  static const (int, int) modelLengthRange = (1, 10);

  // ── Validation (mirrors the validate_* functions) ──────────────────────────

  /// 1–10 characters, alphanumeric. NOTE: Python's `str.isalnum()` also accepts
  /// non-ASCII letters/digits; this uses ASCII `[A-Za-z0-9]`, which matches the
  /// real firmware model names and rejects nothing the tool would have kept.
  static void validateModel(String model) {
    if (model.isEmpty) {
      throw ArgumentError('Model must be specified');
    }
    if (model.length < modelLengthRange.$1 || model.length > modelLengthRange.$2) {
      throw ArgumentError('Model must be between 1 and 10 characters long');
    }
    if (!RegExp(r'^[A-Za-z0-9]+$').hasMatch(model)) {
      throw ArgumentError('Model must be alphanumerical');
    }
  }

  static void validateBoards(List<String> boards) {
    if (boards.isEmpty) {
      throw ArgumentError('You must specify at least one compatible board, in a list!');
    }
  }

  static void validateEncryptionFlag(String enc) {
    if (!allowedEncFlags.contains(enc)) {
      throw ArgumentError('Invalid encryption flag! Allowed flags: $allowedEncFlags');
    }
  }

  static void validateTypeFlag(String typeFlag) {
    if (!allowedTypeFlags.contains(typeFlag)) {
      throw ArgumentError('Invalid type flag! Allowed flags: $allowedTypeFlags');
    }
  }

  // ── Packaging (mirrors make_zip_v3) ─────────────────────────────────────────

  /// Create a v3 firmware ZIP and return its bytes.
  ///
  /// [enc] selects which payloads are written: `plain` → `FIRM.bin`,
  /// `encrypted` → `FIRM.bin.enc`, `both` → both. [params], when non-empty,
  /// is written as `params.txt`.
  static Uint8List makeZipV3({
    required List<int> data,
    required String name,
    required String typeFlag,
    required String model,
    required List<String> boards,
    required bool enforceModel,
    required String enc,
    int schemaVersion = 1,
    String? params,
  }) {
    if (schemaVersion != 1) {
      throw ArgumentError('Unknown schema version');
    }

    validateModel(model);
    validateBoards(boards);
    validateEncryptionFlag(enc);
    validateTypeFlag(typeFlag);

    // Insertion order mirrors the Python dict so info.json reads identically.
    final md5 = <String, String>{};
    final infoJson = <String, dynamic>{
      'schemaVersion': schemaVersion,
      'firmware': <String, dynamic>{
        'displayName': name,
        'model': model,
        'enforceModel': enforceModel,
        'type': typeFlag,
        'compatible': boards,
        'encryption': enc,
        'md5': md5,
      },
    };

    final archive = Archive();

    if (enc == 'both' || enc == 'plain') {
      archive.add(ArchiveFile.bytes('FIRM.bin', data));
      md5['bin'] = md5Hex(data);
    }

    if (enc == 'both' || enc == 'encrypted') {
      final encryptedData = NinebotTea().encrypt(data);
      archive.add(ArchiveFile.bytes('FIRM.bin.enc', encryptedData));
      md5['enc'] = md5Hex(encryptedData);
    }

    // 4-space indent to match json.dumps(..., indent=4); cosmetic (no MD5 taken
    // over info.json), but kept faithful.
    archive.add(ArchiveFile.string(
      'info.json',
      const JsonEncoder.withIndent('    ').convert(infoJson),
    ));

    if (params != null && params.isNotEmpty) {
      archive.add(ArchiveFile.string('params.txt', params));
    }

    final bytes = ZipEncoder().encode(archive);
    return Uint8List.fromList(bytes);
  }

  /// Lowercase MD5 hex digest (matches `hashlib.md5(...).hexdigest()`).
  static String md5Hex(List<int> data) => md5.convert(data).toString();

  // ── Convenience: read a .bin, write the .zip ────────────────────────────────

  /// Read [binPath], build the package, and write it to [outputZipPath].
  static void packBinToZip({
    required String binPath,
    required String outputZipPath,
    required String name,
    required String typeFlag,
    required String model,
    required List<String> boards,
    required bool enforceModel,
    required String enc,
    int schemaVersion = 1,
    String? params,
  }) {
    final data = File(binPath).readAsBytesSync();
    final zip = makeZipV3(
      data: data,
      name: name,
      typeFlag: typeFlag,
      model: model,
      boards: boards,
      enforceModel: enforceModel,
      enc: enc,
      schemaVersion: schemaVersion,
      params: params,
    );
    File(outputZipPath).writeAsBytesSync(zip);
  }

  // ── Unpacking (the inverse: read a v3 ZIP, hand back flashable firmware) ────

  /// Open a zip3 firmware package and return the decrypted firmware, ready to
  /// flash. A zip3 is defined as **encrypted and MD5'd**, so this is strict:
  ///
  /// 1. readable ZIP with `info.json`, `schemaVersion == 1`;
  /// 2. a `FIRM.bin.enc` member (a plain `FIRM.bin` alone is not a zip3 and is
  ///    rejected — the point of zip3 is the encryption);
  /// 3. a matching `md5.enc` in `info.json` — the payload is hashed and checked
  ///    before it is decrypted;
  /// 4. NinebotTEA decrypt, whose internal checksum guards the plaintext.
  ///
  /// The decrypted bytes are returned as-is (identical to `ninebottea decrypt`),
  /// including NinebotTEA's canonical trailing pad. Throws [FormatException] for
  /// anything that fails the above.
  static UnpackedV3 unpackV3(List<int> zipBytes, {List<int>? key}) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zipBytes);
    } catch (_) {
      throw const FormatException('Not a readable ZIP archive.');
    }

    final infoFile = archive.findFile('info.json');
    if (infoFile == null) {
      throw const FormatException('Missing info.json — not a v3 package.');
    }
    Map<String, dynamic> info;
    try {
      info = jsonDecode(utf8.decode(infoFile.content)) as Map<String, dynamic>;
    } catch (_) {
      throw const FormatException('info.json is not valid JSON.');
    }
    if (info['schemaVersion'] != 1) {
      throw FormatException('Unsupported schemaVersion: ${info['schemaVersion']}.');
    }

    final fw = info['firmware'];

    // Model/type allow-list (device_spec.dart) — fail fast before any decrypt.
    final model = (fw is Map) ? fw['model']?.toString() : null;
    final type = (fw is Map) ? fw['type']?.toString() : null;
    final verdict = DeviceSpec.evaluateZip3(model, type);
    if (!verdict.ok) {
      throw FormatException(verdict.reason);
    }

    // zip3 must carry the encrypted payload.
    final encFile = archive.findFile('FIRM.bin.enc');
    if (encFile == null) {
      throw const FormatException('No FIRM.bin.enc — not an encrypted zip3 package.');
    }

    // zip3 must be MD5'd: require md5.enc and verify it before decrypting.
    final md5map = (fw is Map) ? fw['md5'] : null;
    final md5enc = (md5map is Map && md5map['enc'] is String) ? md5map['enc'] as String : null;
    if (md5enc == null) {
      throw const FormatException('info.json has no md5.enc — package is not MD5-verified.');
    }
    final encBytes = Uint8List.fromList(encFile.content);
    if (md5Hex(encBytes) != md5enc) {
      throw const FormatException('FIRM.bin.enc failed its MD5 check — package is corrupt.');
    }

    final firmware = NinebotTea(key: key).decrypt(encBytes); // TEA checksum inside

    // Soft payload-side cross-check: does the firmware's own banner agree with
    // the declared model/type? A mismatch is a warning, not a hard reject.
    final banner = DeviceSpec.verifyBanner(firmware, model ?? '', type ?? '');

    return UnpackedV3(
      firmware: firmware,
      source: 'FIRM.bin.enc (decrypted)',
      info: info,
      bannerWarning: banner.consistent ? null : banner.message,
    );
  }
}

/// Result of [PackV3.unpackV3]: the decrypted firmware plus package metadata.
class UnpackedV3 {
  const UnpackedV3({
    required this.firmware,
    required this.source,
    required this.info,
    this.bannerWarning,
  });

  /// Decrypted firmware bytes, ready to write to flash.
  final Uint8List firmware;

  /// Which member produced [firmware] (for logging).
  final String source;

  /// Parsed `info.json`.
  final Map<String, dynamic> info;

  /// Non-null when the firmware's own `SCOOTER_<TYPE>_<CODE>` banner disagrees
  /// with the declared model/type — a soft warning, not a load failure.
  final String? bannerWarning;

  String get displayName {
    final fw = info['firmware'];
    final n = (fw is Map) ? fw['displayName'] : null;
    return (n is String && n.isNotEmpty) ? n : 'firmware';
  }

  /// `info.json` firmware.model (accepted by [DeviceSpec] during unpack).
  String get model => (info['firmware'] as Map?)?['model']?.toString() ?? '';

  /// `info.json` firmware.type (accepted by [DeviceSpec] during unpack).
  String get type => (info['firmware'] as Map?)?['type']?.toString() ?? '';
}
