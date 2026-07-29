import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'device_spec.dart';
import 'firmware.dart';
import 'ninebot_tea.dart';
import 'zp_extract.dart';

enum Zip3UnpackPolicy {
  /// Firmware is being armed for a controller write: VCU/MCU only, with the
  /// existing X3 model, board, and payload-banner checks.
  flash,

  /// Firmware is only being decrypted to a local file: additionally accepts
  /// X3 BMS/BLE packages and does not infer flashability from payload size.
  extract,
}

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
  // Package creation/extraction supports every X3 component type represented
  // in the firmware corpus. The hardware-flash import policy remains a
  // separate, stricter VCU/MCU allow-list in unpackV3().
  static const Set<String> allowedTypeFlags = {'VCU', 'MCU', 'BMS', 'BLE'};
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
  /// what [buildZip3FromDump] actually uses. [slotBin] reads a hand-sliced
  /// slot-0 payload instead (banner at 0x400 rather than 0x1400).
  static Zip3Detect detect(List<int> dumpBytes, {bool slotBin = false}) {
    final id = DeviceSpec.describeBin(dumpBytes, slotBin: slotBin);
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
        'This dump has neither the default SHU key nor a blank key. '
        'It is usually OEM/stock firmware and may not be BLE-flashable, so Make '
        'zip3 was stopped. Some older repo firmware may also be rejected by '
        'this safety check.',
      );
    }

    // Exact slot-0 payload from the device's own committed length.
    final payload = Zp.payloadFromDump(dumpBytes);

    return _finishBuild(
      payload: payload,
      type: t,
      model: m,
      enforceModel: enforceModel,
      displayName: displayName,
    );
  }

  /// Fail-closed checks for a complete Pack payload.
  ///
  /// A full controller dump is recognized only at its exact 128 KB size and
  /// full-image banner offset. A VCU/MCU payload is recognized independently at
  /// its slot-relative banner offset, then checked against its physical ceiling
  /// and (when supplied) the operator-declared identity. BMS/BLE remain
  /// bannerless/manual: their observed size ranges are not identity evidence.
  ///
  /// The modulo check is required for byte-exact NinebotTEA round trips. The
  /// reference format cannot encode the original padding length, so any input
  /// other than `8n + 4` would unpack with extra zero bytes.
  static void validatePayloadForPack(
    List<int> payload, {
    String? type,
    String? model,
  }) {
    if (payload.length == Firmware.expectedSize) {
      final fullIdentity = DeviceSpec.describeBin(payload, slotBin: false);
      if (fullIdentity.bannerType != null) {
        throw const FormatException(
          'This is a full 128 KB VCU/MCU controller dump (firmware banner at '
          '0x1400). Use Slice instead of Pack.',
        );
      }
    }

    if (payload.length % 8 != 4) {
      throw FormatException(
        'Payload size must be 4 bytes more than a multiple of 8 for an exact '
        'NinebotTEA round trip. This file is ${payload.length} bytes '
        '(remainder ${payload.length % 8}); packing it would add zero padding.',
      );
    }

    final identity = DeviceSpec.describeBin(payload, slotBin: true);
    if (identity.banner != null && !identity.bannerSupported) {
      throw FormatException(
        'Unsupported VCU/MCU firmware banner "${identity.banner}" at 0x400.',
      );
    }

    if (identity.bannerSupported) {
      final maxBytes = identity.bannerType == 'MCU'
          ? Firmware.slot0MaxPayloadMcu
          : Firmware.slot0MaxPayloadVcu;
      if (payload.length > maxBytes) {
        throw FormatException(
          '${identity.bannerType} payload is ${payload.length} bytes, above '
          'its $maxBytes-byte physical slot-0 ceiling.',
        );
      }
    }

    final declaredType = type?.trim().toUpperCase();
    if (declaredType == null) return;
    if ((declaredType == 'VCU' || declaredType == 'MCU') &&
        !identity.bannerSupported) {
      throw FormatException(
        'The declared $declaredType type requires a supported firmware banner '
        'at 0x400.',
      );
    }
    if (identity.banner != null) {
      final verdict = DeviceSpec.verifyBanner(
        payload,
        model?.trim().toLowerCase() ?? '',
        declaredType,
      );
      if (!verdict.consistent) throw FormatException(verdict.message);
    }
  }

  /// Pack a complete firmware component payload as-is. Unlike the guarded
  /// full-dump Slice path, this generic Pack path does not infer a payload
  /// boundary or apply ZP or SHU-key checks.
  static Zip3BuildResult buildZip3FromPayload(
    List<int> payload, {
    required String type,
    required String model,
    required bool enforceModel,
    String? displayName,
  }) {
    final t = type.trim().toUpperCase();
    final m = model.trim().toLowerCase();
    validateTypeFlag(t);
    validateModel(m);
    if (!kSupportedDevices.any((device) => device.model == m)) {
      throw FormatException(
        'This package is for ${m.toUpperCase()}. '
        'x3utils supports ${DeviceSpec.modelList()} only.',
      );
    }
    validatePayloadForPack(payload, type: t, model: m);

    return _finishBuild(
      payload: payload,
      type: t,
      model: m,
      enforceModel: enforceModel,
      displayName: displayName,
    );
  }

  /// Shared tail of the build paths: derive the board, resolve the
  /// display name, and pack the payload as an encrypted, MD5'd package.
  static Zip3BuildResult _finishBuild({
    required List<int> payload,
    required String type,
    required String model,
    required bool enforceModel,
    String? displayName,
  }) {
    final board = switch (type) {
      'VCU' => '${model}_VCU_AT32',
      'MCU' => 'x3_MCU_AT32',
      'BMS' => 'x3_BMS',
      'BLE' => '${model}_BLE',
      _ => throw FormatException('Unsupported ZIP3 component type: $type.'),
    };
    final name = (displayName != null && displayName.trim().isNotEmpty)
        ? displayName.trim()
        : '${model}_$type';

    final zip = makeZipV3(
      data: payload,
      name: name,
      typeFlag: type,
      model: model,
      boards: [board],
      enforceModel: enforceModel,
      enc: 'encrypted',
    );

    return Zip3BuildResult(
      zipBytes: zip,
      model: model,
      type: type,
      displayName: name,
      payloadLength: payload.length,
    );
  }

  // ── Unpacking (the inverse: read a v3 ZIP, hand back flashable firmware) ────

  /// Open a zip3 firmware package and return the decrypted firmware, ready to
  /// flash. A zip3 is defined as **encrypted and MD5'd**, so this is strict:
  ///
  /// 1. readable ZIP with `info.json`, `schemaVersion == 1`;
  /// 2. metadata whose `compatible` board agrees with its model/type and the
  ///    selected [policy];
  /// 3. a `FIRM.bin.enc` member (a plain `FIRM.bin` alone is not a zip3 and is
  ///    rejected — the point of zip3 is the encryption);
  /// 4. a matching `md5.enc` in `info.json` — the payload is hashed and checked
  ///    before it is decrypted;
  /// 5. NinebotTEA decrypt, whose internal checksum guards the plaintext;
  /// 6. for VCU/MCU, a firmware banner that agrees with package metadata.
  ///
  /// The decrypted bytes are returned as-is (identical to `ninebottea decrypt`),
  /// including NinebotTEA's canonical trailing pad. Throws [FormatException] for
  /// anything that fails the above.
  static UnpackedV3 unpackV3(
    List<int> zipBytes, {
    List<int>? key,
    Zip3UnpackPolicy policy = Zip3UnpackPolicy.flash,
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
    final allowedTypes = policy == Zip3UnpackPolicy.flash
        ? const {'VCU', 'MCU'}
        : const {'VCU', 'MCU', 'BMS', 'BLE'};
    if (!allowedTypes.contains(type)) {
      throw FormatException(
        'This package contains ${type ?? 'unknown'} firmware. '
        '${policy == Zip3UnpackPolicy.flash ? 'x3utils flashes only VCU/MCU firmware.' : 'Standalone Unpack supports VCU, MCU, BMS, and BLE.'}',
      );
    }

    if (policy == Zip3UnpackPolicy.flash) {
      // A package armed for flashing stays on the strict VCU/MCU allow-list.
      final verdict = DeviceSpec.evaluateZip3(model, type);
      if (!verdict.ok) {
        throw FormatException(verdict.reason);
      }
    } else if (!kSupportedDevices.any(
      (device) => device.model == model.toLowerCase(),
    )) {
      throw FormatException(
        'This package is for ${model.toUpperCase()}. '
        'x3utils supports ${DeviceSpec.modelList()} only.',
      );
    }

    final compatibleValue = fw['compatible'];
    if (compatibleValue is! List ||
        compatibleValue.isEmpty ||
        compatibleValue.any(
          (value) => value is! String || value.trim().isEmpty,
        )) {
      throw const FormatException(
        'info.json has no valid firmware.compatible list.',
      );
    }
    final compatible = compatibleValue
        .cast<String>()
        .map((value) => value.trim())
        .toList(growable: false);
    final expectedBoard = switch (type) {
      'MCU' => 'x3_MCU_AT32',
      'BMS' => 'x3_BMS',
      'BLE' => '${model.toLowerCase()}_BLE',
      _ => '${model.toLowerCase()}_VCU_AT32',
    };
    if (compatible.length != 1 ||
        compatible.single.toLowerCase() != expectedBoard.toLowerCase()) {
      final boards = compatible.join(', ');
      throw FormatException(
        'Inconsistent JSON, "model" : ${model.toUpperCase()} $type, '
        '"compatible" : $boards.',
      );
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

    // VCU/MCU carry the known X3 banner. BMS/BLE use different image formats,
    // so extraction relies on package metadata + MD5 + TEA checksum instead.
    if (type == 'VCU' || type == 'MCU') {
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

/// Finished package plus its declared identity (for the UI/filename and logs).
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

  /// Declared scooter model and component type.
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

  /// Informational `info.json` firmware.enforceModel value. It is displayed but
  /// deliberately not used as an extraction acceptance gate.
  bool? get enforceModel {
    final value = (info['firmware'] as Map?)?['enforceModel'];
    return value is bool ? value : null;
  }

  /// Declared `info.json` firmware.encryption mode.
  String? get encryption {
    final value = (info['firmware'] as Map?)?['encryption'];
    return value is String && value.trim().isNotEmpty ? value.trim() : null;
  }
}
