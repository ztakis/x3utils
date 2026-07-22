import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'device_spec.dart';
import 'firmware.dart';
import 'ninebot_tea.dart';
import 'zp_extract.dart';

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
  // x3 controllers are VCU/MCU only. (The upstream tool's DRV/BMS/BLE list does
  // not apply here — a package must declare VCU or MCU, same as the unpack gate.)
  static const Set<String> allowedTypeFlags = {'VCU', 'MCU'};
  static const (int, int) modelLengthRange = (1, 10);

  // ── Validation (mirrors the validate_* functions) ──────────────────────────

  /// 1–10 characters, alphanumeric. NOTE: Python's `str.isalnum()` also accepts
  /// non-ASCII letters/digits; this uses ASCII `[A-Za-z0-9]`, which matches the
  /// real firmware model names and rejects nothing the tool would have kept.
  static void validateModel(String model) {
    if (model.isEmpty) {
      throw ArgumentError('Model must be specified');
    }
    if (model.length < modelLengthRange.$1 ||
        model.length > modelLengthRange.$2) {
      throw ArgumentError('Model must be between 1 and 10 characters long');
    }
    if (!RegExp(r'^[A-Za-z0-9]+$').hasMatch(model)) {
      throw ArgumentError('Model must be alphanumerical');
    }
  }

  static void validateBoards(List<String> boards) {
    if (boards.isEmpty) {
      throw ArgumentError(
        'You must specify at least one compatible board, in a list!',
      );
    }
  }

  static void validateEncryptionFlag(String enc) {
    if (!allowedEncFlags.contains(enc)) {
      throw ArgumentError(
        'Invalid encryption flag! Allowed flags: $allowedEncFlags',
      );
    }
  }

  static void validateTypeFlag(String typeFlag) {
    if (!allowedTypeFlags.contains(typeFlag)) {
      throw ArgumentError(
        'Invalid type flag! Allowed flags: $allowedTypeFlags',
      );
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
    archive.add(
      ArchiveFile.string(
        'info.json',
        const JsonEncoder.withIndent('    ').convert(infoJson),
      ),
    );

    if (params != null && params.isNotEmpty) {
      archive.add(ArchiveFile.string('params.txt', params));
    }

    final bytes = ZipEncoder().encode(archive);
    return Uint8List.fromList(bytes);
  }

  /// Lowercase MD5 hex digest (matches `hashlib.md5(...).hexdigest()`).
  static String md5Hex(List<int> data) => md5.convert(data).toString();

  // ── Dump → zip3 (the offline "Make zip3" tool) ──────────────────────────────

  /// Inspect a full 128 KB [dumpBytes] to PRESELECT the Make-zip3 dropdowns.
  ///
  /// The banner (`0x1400`) gives the type reliably, and a VCU banner code
  /// decodes to the model. An MCU carries no model identity at all — its banner
  /// is `0001` and its dump holds only a generic MCU part serial (`Z025A4…`),
  /// never a `1K1/1CG/1EF/03S` model serial — so its model cannot be
  /// preselected: [Zip3Detect.model] is left null and the operator picks it.
  /// Identity here is a suggestion only; the operator's dropdown choices are
  /// what [buildZip3FromDump] actually uses.
  static Zip3Detect detect(List<int> dumpBytes) {
    final id = DeviceSpec.describeBin(dumpBytes, slotBin: false);
    return Zip3Detect(
      type: id.bannerType,
      // Only VCU can be preselected; MCU (and unknown VCU codes) stay empty.
      model: id.bannerType == 'VCU' ? id.bannerModel : null,
    );
  }

  /// Build a BLE-loadable zip3 package from a full 128 KB backup [dumpBytes],
  /// labelled with the OPERATOR-declared [type]/[model] (the Make-zip3
  /// dropdowns), same as `ninebottea` takes its packaging inputs.
  ///
  /// Offline, no hardware:
  /// 1. recover the slot-0 payload length from the device's `ZP` record
  ///    ([Zp.payloadFromDump], fail-closed for a missing/invalid record — no
  ///    guessed trim; a structurally valid but stale record is not detectable);
  /// 2. pack it with [makeZipV3] as an encrypted, MD5'd package
  ///    (`FIRM.bin.enc` + `info.json`) in the format intended for the BLE app's
  ///    "Load from file". The BLE app must still confirm acceptance.
  ///
  /// `compatible` is derived the way real packages do: a VCU is model-specific
  /// (`<model>_VCU_AT32`); an MCU is model-agnostic and always ships on the
  /// generic `x3_MCU_AT32` board (its `model` field is still a concrete label).
  /// [enforceModel] is the operator's checkbox. [displayName] fills the
  /// `info.json` displayName; when null/blank it defaults to `<model>_<TYPE>`.
  /// Throws a [FormatException] for an unsupported selection or an unreadable
  /// ZP length record.
  static Zip3BuildResult buildZip3FromDump(
    List<int> dumpBytes, {
    required String type,
    required String model,
    required bool enforceModel,
    String? displayName,
  }) {
    final t = type.trim().toUpperCase();
    final m = model.trim().toLowerCase();

    // The operator-declared identity must be one we support (fails closed on an
    // empty/unknown model or a BLE/BMS type).
    final verdict = DeviceSpec.evaluateZip3(m, t);
    if (!verdict.ok) {
      throw FormatException(verdict.reason);
    }

    // The 16 bytes at 0x1420: newer repo firmware leaves them blank (0xFF), and
    // flash_compat writes the default SHU key there. Anything else is USUALLY
    // OEM/stock (a different production key) and would fail a BLE flash — so
    // refuse it. Two caveats, both UNCONFIRMED maintainer guesses:
    //  * 0x1420 is INSIDE the payload (0x20 past the banner), so some OLDER repo
    //    builds hold unrelated firmware bytes there (observed: an ASCII token on
    //    a real g3 VCU 1.4.8) yet still BLE-flash fine. Working theory: that fw
    //    was patched to not look for a key at all, and newer fw later adopted
    //    the simpler blank convention. Those older builds trip this gate as a
    //    known EXCEPTION, not a bug.
    //  * Passing is NECESSARY, NOT SUFFICIENT: a blank/key here does not
    //    guarantee SHU BLE will accept the package.
    // So this is a best-effort filter for the obvious OEM case, not a proof.
    if (!CompatPatch.keyState(dumpBytes).bleFlashable) {
      throw const FormatException(
        'This dump has neither the default SHU key nor a blank key at 0x1420. '
        'It is usually OEM/stock firmware and may not be BLE-flashable, so Make '
        'zip3 was stopped. Some older repo firmware may also be rejected by '
        'this safety check.',
      );
    }

    // Exact slot-0 payload from the device's own committed length.
    final payload = Zp.payloadFromDump(dumpBytes);

    final board = t == 'MCU' ? 'x3_MCU_AT32' : '${m}_VCU_AT32';
    final name = (displayName != null && displayName.trim().isNotEmpty)
        ? displayName.trim()
        : '${m}_$t';

    final zip = makeZipV3(
      data: payload,
      name: name,
      typeFlag: t,
      model: m,
      boards: [board],
      enforceModel: enforceModel,
      enc: 'encrypted',
    );

    return Zip3BuildResult(
      zipBytes: zip,
      model: m,
      type: t,
      displayName: name,
      payloadLength: payload.length,
    );
  }

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
  static UnpackedV3 unpackV3(
    List<int> zipBytes, {
    List<int>? key,
    bool enforceDeviceIdentity = true,
  }) {
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
      throw FormatException(
        'Unsupported schemaVersion: ${info['schemaVersion']}.',
      );
    }

    final fw = info['firmware'];
    if (fw is! Map) {
      throw const FormatException('info.json has no firmware record.');
    }

    final model = fw['model']?.toString().trim();
    if (model == null || model.isEmpty) {
      throw const FormatException('info.json has no firmware.model.');
    }
    final type = fw['type']?.toString().trim().toUpperCase();
    if (type != 'VCU' && type != 'MCU') {
      throw FormatException(
        'Unsupported firmware type "${type ?? 'missing'}" — '
        'x3utils flashes VCU/MCU packages only (not BLE/BMS).',
      );
    }

    // Guarded slot flashing retains the supported-model allow-list. Flash Only
    // deliberately treats model metadata as information, while still rejecting
    // BLE/BMS above and retaining all package-integrity checks below.
    if (enforceDeviceIdentity) {
      final verdict = DeviceSpec.evaluateZip3(model, type);
      if (!verdict.ok) {
        throw FormatException(verdict.reason);
      }
    }

    // zip3 must carry the encrypted payload.
    final encFile = archive.findFile('FIRM.bin.enc');
    if (encFile == null) {
      throw const FormatException(
        'No FIRM.bin.enc — not an encrypted zip3 package.',
      );
    }

    // zip3 must be MD5'd: require md5.enc and verify it before decrypting.
    final md5map = fw['md5'];
    final md5enc = (md5map is Map && md5map['enc'] is String)
        ? md5map['enc'] as String
        : null;
    if (md5enc == null) {
      throw const FormatException(
        'info.json has no md5.enc — package is not MD5-verified.',
      );
    }
    final encBytes = Uint8List.fromList(encFile.content);
    if (md5Hex(encBytes) != md5enc) {
      throw const FormatException(
        'FIRM.bin.enc failed its MD5 check — package is corrupt.',
      );
    }

    final firmware = NinebotTea(
      key: key,
    ).decrypt(encBytes); // TEA checksum inside

    // Payload-side gate: the firmware's own banner must match the declared
    // model/type. A mismatch means a mislabeled package — hard-rejected, same as
    // the model gate. Proven safe across the full jsb.by firmware set (every
    // VCU/MCU image's banner matches its model; 0 mismatches over 99 files).
    if (enforceDeviceIdentity) {
      final banner = DeviceSpec.verifyBanner(firmware, model, type!);
      if (!banner.consistent) {
        throw FormatException(banner.message);
      }
    }

    return UnpackedV3(
      firmware: firmware,
      source: 'FIRM.bin.enc (decrypted)',
      info: info,
    );
  }
}

/// Preselect suggestion from [PackV3.detect] for the Make-zip3 dropdowns.
/// Either field is null when it cannot be inferred: [type] when there is no
/// readable banner, [model] for MCU (no model identity) or an unknown VCU code.
class Zip3Detect {
  const Zip3Detect({this.type, this.model});

  /// `VCU` / `MCU`, or null when no banner is readable.
  final String? type;

  /// `zt3`/`g3`/`gt3`/`f3`, or null when it cannot be preselected.
  final String? model;
}

/// Result of [PackV3.buildZip3FromDump]: the finished package plus the identity
/// derived from the dump (for the UI/filename and logs).
class Zip3BuildResult {
  const Zip3BuildResult({
    required this.zipBytes,
    required this.model,
    required this.type,
    required this.displayName,
    required this.payloadLength,
  });

  /// The complete zip3 archive, ready to write to disk.
  final Uint8List zipBytes;

  /// Derived scooter model (e.g. `g3`) and type (`VCU`/`MCU`).
  final String model;
  final String type;

  /// `info.json` displayName used (operator-supplied or `"<model> <TYPE>"`).
  final String displayName;

  /// Length of the exact slot-0 payload that was packed.
  final int payloadLength;
}

/// Result of [PackV3.unpackV3]: the decrypted firmware plus package metadata.
class UnpackedV3 {
  const UnpackedV3({
    required this.firmware,
    required this.source,
    required this.info,
  });

  /// Decrypted firmware bytes, ready to write to flash.
  final Uint8List firmware;

  /// Which member produced [firmware] (for logging).
  final String source;

  /// Parsed `info.json`.
  final Map<String, dynamic> info;

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
