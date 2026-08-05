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

  /// Firmware is only being recovered to a local file: additionally accepts X3
  /// BMS/BLE packages and does not infer flashability from payload size.
  extract,
}

enum Zip3Format { rev2, legacy }

extension Zip3FormatLabel on Zip3Format {
  String get label => this == Zip3Format.rev2 ? 'zip 3.2' : 'zip 3';
}

/// Dart port of ScooterHacking's fw-zip-package-v3 `Python/pack.py`:
/// https://github.com/scooterhacking/fw-zip-package-v3
///
/// Builds both current plaintext zip3.2 packages and legacy NinebotTEA zip3
/// packages. The generic [makeZipV3] method remains the legacy upstream port;
/// production Slice/Pack calls default to [makeZipV32].
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
  static const int maxArchiveMembers = 16;
  static const int maxInfoBytes = 64 * 1024;
  static const int maxPayloadBytes = 16 * 1024 * 1024;
  static const int maxExpandedBytes = 32 * 1024 * 1024;
  static const Set<String> _reservedMembers = {
    'info.json',
    'FIRM.bin',
    'FIRM.bin.enc',
  };

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

  /// Create the rev2 (zip 3.2) package used by current upstream tooling.
  /// The payload is plaintext and its scalar MD5 covers `FIRM.bin` exactly.
  /// Metadata and archive member order intentionally match the standalone
  /// rev2 specification: `info.json` first, then `FIRM.bin`.
  static Uint8List makeZipV32({
    required List<int> data,
    required String name,
    required String typeFlag,
    required String model,
    required List<String> boards,
  }) {
    final type = typeFlag.trim().toUpperCase();
    validateModel(model);
    validateBoards(boards);
    validateTypeFlag(type);

    final infoJson = <String, dynamic>{
      'schemaVersion': 2,
      'firmware': <String, dynamic>{
        'displayName': name,
        'models': [model],
        'type': type.toLowerCase(),
        'compatible': boards,
        'md5': md5Hex(data),
      },
    };
    final archive = Archive()
      ..add(
        ArchiveFile.string(
          'info.json',
          const JsonEncoder.withIndent('  ').convert(infoJson),
        ),
      )
      ..add(ArchiveFile.bytes('FIRM.bin', data));
    return Uint8List.fromList(ZipEncoder().encode(archive));
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
  /// 2. package it as zip3.2 by default (`info.json` + plaintext `FIRM.bin`,
  ///    MD5-verified), or as explicitly selected legacy encrypted zip3. The BLE
  ///    app must still confirm acceptance.
  ///
  /// `compatible` is derived the way real packages do: a VCU is model-specific
  /// (`<model>_VCU_AT32`); an MCU is model-agnostic and always ships on the
  /// generic `x3_MCU_AT32` board (its `model` field is still a concrete label).
  /// [enforceModel] is used only by the legacy format. [displayName] fills the
  /// `info.json` displayName; when null/blank it defaults to `<model>_<TYPE>`.
  /// Throws a [FormatException] for an unsupported selection or an unreadable
  /// ZP length record.
  static Zip3BuildResult buildZip3FromDump(
    List<int> dumpBytes, {
    required String type,
    required String model,
    required bool enforceModel,
    String? displayName,
    Zip3Format format = Zip3Format.rev2,
  }) {
    final t = type.trim().toUpperCase();
    final m = model.trim().toLowerCase();

    // The operator-declared identity must be one we support (fails closed on an
    // empty/unknown model or a BLE/BMS type).
    final verdict = DeviceSpec.evaluateZip3(m, t);
    if (!verdict.ok) {
      throw FormatException(verdict.reason);
    }

    // The 16 bytes at 0x1420 are inside the payload. Their value is useful
    // diagnostic evidence for SHU/compat work, but it is not a ZIP3
    // acceptance rule: the BLE app does not reject a package merely because
    // this payload region contains non-default bytes.

    // Exact slot-0 payload from the device's own committed length.
    final payload = Zp.payloadFromDump(dumpBytes);

    return _finishBuild(
      payload: payload,
      type: t,
      model: m,
      enforceModel: enforceModel,
      displayName: displayName,
      format: format,
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
  /// The modulo check applies only to legacy NinebotTEA. That format cannot
  /// encode the original padding length, so an input other than `8n + 4` would
  /// unpack with extra zero bytes. Plaintext zip3.2 preserves every length.
  static void validatePayloadForPack(
    List<int> payload, {
    String? type,
    String? model,
    Zip3Format format = Zip3Format.rev2,
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

    if (format == Zip3Format.legacy && payload.length % 8 != 4) {
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
    Zip3Format format = Zip3Format.rev2,
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
    validatePayloadForPack(payload, type: t, model: m, format: format);

    return _finishBuild(
      payload: payload,
      type: t,
      model: m,
      enforceModel: enforceModel,
      displayName: displayName,
      format: format,
    );
  }

  /// Shared tail of the build paths: derive the board, resolve the
  /// display name, and pack the payload in the selected format.
  static Zip3BuildResult _finishBuild({
    required List<int> payload,
    required String type,
    required String model,
    required bool enforceModel,
    required Zip3Format format,
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

    final zip = format == Zip3Format.rev2
        ? makeZipV32(
            data: payload,
            name: name,
            typeFlag: type,
            model: model,
            boards: [board],
          )
        : makeZipV3(
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
      format: format,
    );
  }

  // ── Unpacking (dual reader for legacy zip3 and plaintext zip3.2) ───────────

  /// Inspect the central directory before any member is decompressed. This
  /// bounds standalone extraction while still allowing real multi-megabyte BLE
  /// packages, and rejects duplicate names at the trust boundary.
  static void _preflightArchive(List<int> zipBytes) {
    final ZipDirectory directory;
    try {
      directory = ZipDirectory()..read(InputMemoryStream(zipBytes));
    } catch (_) {
      throw const FormatException('Not a readable ZIP archive.');
    }
    final headers = directory.fileHeaders;
    if (directory.filePosition < 0 ||
        headers.length != directory.totalCentralDirectoryEntries) {
      throw const FormatException('Not a complete ZIP archive.');
    }
    if (headers.length > maxArchiveMembers) {
      throw FormatException(
        'ZIP archive has ${headers.length} members; the limit is '
        '$maxArchiveMembers.',
      );
    }

    var total = 0;
    final counts = <String, int>{};
    for (final header in headers) {
      final size = header.uncompressedSize;
      if (size < 0) {
        throw const FormatException('ZIP archive has an invalid member size.');
      }
      total += size;
      if (total > maxExpandedBytes) {
        throw FormatException(
          'ZIP archive expands beyond the $maxExpandedBytes-byte limit.',
        );
      }
      counts.update(header.filename, (value) => value + 1, ifAbsent: () => 1);
      if (header.filename == 'info.json' && size > maxInfoBytes) {
        throw FormatException(
          'info.json exceeds the $maxInfoBytes-byte limit.',
        );
      }
      if ((header.filename == 'FIRM.bin' ||
              header.filename == 'FIRM.bin.enc') &&
          size > maxPayloadBytes) {
        throw FormatException(
          '${header.filename} exceeds the $maxPayloadBytes-byte limit.',
        );
      }
    }
    for (final name in _reservedMembers) {
      if ((counts[name] ?? 0) > 1) {
        throw FormatException('ZIP archive contains duplicate $name members.');
      }
    }
  }

  /// Open either a legacy encrypted zip3 (`schemaVersion == 1`) or current
  /// plaintext zip3.2 (`schemaVersion == 2`). Both paths require an exact MD5,
  /// consistent model/type/board metadata, and matching VCU/MCU banner evidence.
  static UnpackedV3 unpackV3(
    List<int> zipBytes, {
    List<int>? key,
    Zip3UnpackPolicy policy = Zip3UnpackPolicy.flash,
  }) {
    _preflightArchive(zipBytes);
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zipBytes);
    } catch (_) {
      throw const FormatException('Not a readable ZIP archive.');
    }

    final infoFile = archive.findFile('info.json');
    if (infoFile == null) {
      throw const FormatException(
        'Missing info.json — not a zip3 or zip3.2 package.',
      );
    }
    Map<String, dynamic> info;
    try {
      info = jsonDecode(utf8.decode(infoFile.content)) as Map<String, dynamic>;
    } catch (_) {
      throw const FormatException('info.json is not valid JSON.');
    }
    final schemaVersion = info['schemaVersion'];
    if (schemaVersion != 1 && schemaVersion != 2) {
      throw FormatException(
        'Unsupported ZIP package schemaVersion: $schemaVersion.',
      );
    }

    final fw = info['firmware'];
    if (fw is! Map) {
      throw const FormatException('info.json has no firmware record.');
    }

    final String model;
    if (schemaVersion == 1) {
      final value = fw['model'];
      if (value is! String || value.trim().isEmpty) {
        throw const FormatException('info.json has no firmware.model.');
      }
      model = value.trim();
    } else {
      final modelsValue = fw['models'];
      final scalarValue = fw['model'];
      String? arrayModel;
      if (modelsValue != null) {
        if (modelsValue is! List ||
            modelsValue.length != 1 ||
            modelsValue.single is! String ||
            (modelsValue.single as String).trim().isEmpty) {
          throw const FormatException(
            'zip3.2 firmware.models must contain exactly one model.',
          );
        }
        arrayModel = (modelsValue.single as String).trim();
      }
      final scalarModel = scalarValue is String && scalarValue.trim().isNotEmpty
          ? scalarValue.trim()
          : null;
      if (arrayModel == null && scalarModel == null) {
        throw const FormatException('info.json has no firmware.models model.');
      }
      if (arrayModel != null &&
          scalarModel != null &&
          arrayModel.toLowerCase() != scalarModel.toLowerCase()) {
        throw const FormatException(
          'zip3.2 firmware.model and firmware.models disagree.',
        );
      }
      model = arrayModel ?? scalarModel!;
    }
    try {
      validateModel(model);
    } on ArgumentError catch (e) {
      throw FormatException(e.message?.toString() ?? 'Invalid model.');
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

    final Uint8List firmware;
    final String source;
    final Zip3Format format;
    if (schemaVersion == 2) {
      if (archive.findFile('FIRM.bin.enc') != null) {
        throw const FormatException(
          'zip3.2 must not contain encrypted FIRM.bin.enc.',
        );
      }
      if (fw['encryption'] != null) {
        throw const FormatException(
          'zip3.2 must not declare firmware.encryption.',
        );
      }
      final plainFile = archive.findFile('FIRM.bin');
      if (plainFile == null) {
        throw const FormatException('zip3.2 has no plaintext FIRM.bin.');
      }
      final declaredMd5 = fw['md5'];
      if (declaredMd5 is! String ||
          !RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(declaredMd5)) {
        throw const FormatException(
          'info.json has no valid scalar firmware.md5.',
        );
      }
      firmware = Uint8List.fromList(plainFile.content);
      if (md5Hex(firmware) != declaredMd5.toLowerCase()) {
        throw const FormatException(
          'zip3.2 FIRM.bin failed its MD5 check — package is corrupt.',
        );
      }
      source = 'FIRM.bin';
      format = Zip3Format.rev2;
    } else {
      if (fw['encryption'] != 'encrypted') {
        throw const FormatException(
          'Legacy zip3 must declare firmware.encryption as encrypted.',
        );
      }
      final encFile = archive.findFile('FIRM.bin.enc');
      if (encFile == null) {
        throw const FormatException(
          'Legacy zip 3 has no encrypted FIRM.bin.enc.',
        );
      }
      final md5map = fw['md5'];
      final md5enc = (md5map is Map && md5map['enc'] is String)
          ? md5map['enc'] as String
          : null;
      if (md5enc == null || !RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(md5enc)) {
        throw const FormatException(
          'Legacy zip 3 info.json has no valid md5.enc.',
        );
      }
      final encBytes = Uint8List.fromList(encFile.content);
      if (md5Hex(encBytes) != md5enc.toLowerCase()) {
        throw const FormatException(
          'Legacy zip 3 FIRM.bin.enc failed its MD5 check — package is corrupt.',
        );
      }
      try {
        firmware = NinebotTea(key: key).decrypt(encBytes);
      } on FormatException catch (e) {
        throw FormatException('Legacy zip 3 decryption failed: ${e.message}');
      }
      source = 'FIRM.bin.enc (decrypted)';
      format = Zip3Format.legacy;
    }

    // VCU/MCU carry the known X3 banner. BMS/BLE use different image formats,
    // so extraction relies on package metadata plus the selected format's
    // integrity checks instead.
    if (type == 'VCU' || type == 'MCU') {
      final banner = DeviceSpec.verifyBanner(firmware, model, type!);
      if (!banner.consistent) {
        throw FormatException(banner.message);
      }
    }

    return UnpackedV3(
      firmware: firmware,
      source: source,
      info: info,
      format: format,
      normalizedModel: model,
      normalizedType: type!,
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
    this.format = Zip3Format.rev2,
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

  final Zip3Format format;
}

/// Result of [PackV3.unpackV3]: plaintext firmware plus package metadata.
class UnpackedV3 {
  const UnpackedV3({
    required this.firmware,
    required this.source,
    required this.info,
    required this.format,
    required this.normalizedModel,
    required this.normalizedType,
  });

  /// Plaintext firmware bytes, ready for extraction or a guarded flash path.
  final Uint8List firmware;

  /// Which member produced [firmware] (for logging).
  final String source;

  /// Parsed `info.json`.
  final Map<String, dynamic> info;

  final Zip3Format format;
  final String normalizedModel;
  final String normalizedType;

  String get displayName {
    final fw = info['firmware'];
    final n = (fw is Map) ? fw['displayName'] : null;
    return (n is String && n.isNotEmpty) ? n : 'firmware';
  }

  /// Normalized scalar model accepted by [DeviceSpec] during unpack. Rev2's
  /// `models` array is deliberately required to contain exactly one entry.
  String get model => normalizedModel;

  /// `info.json` firmware.type (accepted by [DeviceSpec] during unpack).
  String get type => normalizedType;

  /// Informational legacy `firmware.enforceModel` value. It is deliberately not
  /// used as an extraction acceptance gate.
  bool? get enforceModel {
    final value = (info['firmware'] as Map?)?['enforceModel'];
    return value is bool ? value : null;
  }

  /// Declared `info.json` firmware.encryption mode.
  String? get encryption {
    final value = (info['firmware'] as Map?)?['encryption'];
    return value is String && value.trim().isNotEmpty ? value.trim() : null;
  }

  String get formatLabel => format.label;

  String get protectionLabel =>
      format == Zip3Format.rev2 ? 'plaintext + MD5' : 'NinebotTEA + MD5';
}
