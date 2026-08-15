/// Local-only identity metadata for a validated full backup dump.
///
/// This is deliberately observation-only. It reads known full-image offsets to
/// create a sidecar next to a promoted backup; it never accepts, refuses,
/// patches, or otherwise changes a backup/flash verdict. The values may be
/// device identity material, so callers must keep the sidecar local.
library;

import 'dart:convert';
import 'package:universal_io/universal_io.dart';

import 'package:path/path.dart' as p;

import 'device_spec.dart';
import 'firmware.dart';
import 'fw_version.dart';
import 'info_row.dart';
import 'zp_extract.dart';

/// Reads a promoted 128 KB backup and writes its adjacent JSON sidecar.
class DumpMetadata {
  const DumpMetadata._();

  /// Schema 2 adds [modelSource], so an MCU model selected by an operator can
  /// never be presented as something the shared MCU banner detected.
  static const int schemaVersion = 2;
  static const String _operatorDeclared = 'operatorDeclared';
  static const String _firmwareBanner = 'firmwareBanner';

  /// Full-dump offsets for the two observed 96-bit UID copies.
  static const int uidPrimaryOffset = 0x1F1B4;
  static const int uidBackupOffset = 0x1F5B4;
  static const int uidLength = 12;

  /// Full-dump offset of the six-byte device random value after the key.
  static const int randOffset = 0x1430;
  static const int randLength = 6;

  /// The sidecar follows the primary dump exactly: `dump_<ts>.bin` → `.json`.
  static String sidecarPath(String dumpPath) =>
      p.setExtension(dumpPath, '.json');

  /// Inspect a complete, already-validated full [dump].
  ///
  /// Fields whose layout cannot establish a fact are null or carry an explicit
  /// state. In particular, an MCU banner identifies MCU firmware but does not
  /// encode the scooter model, so no picker/model selection is inferred here.
  static Map<String, Object?> inspect(
    List<int> dump, {
    required String backupPath,
  }) {
    if (dump.length != Firmware.expectedSize) {
      throw ArgumentError.value(
        dump.length,
        'dump.length',
        'A complete ${Firmware.expectedSize}-byte backup is required.',
      );
    }

    final identity = DeviceSpec.describeBin(dump, slotBin: false);
    final type = identity.bannerType;
    final model = type == 'VCU' ? identity.bannerModel : null;
    final version = _version(dump, type: type, model: model);
    final uid = _uid(dump);
    final keyBytes = dump.sublist(
      CompatPatch.offset,
      CompatPatch.offset + CompatPatch.signature.length,
    );
    final keyAscii = _isPrintableAscii(keyBytes);
    final keyState = CompatPatch.keyState(dump);
    final zp = Zp.inspect(dump);

    return <String, Object?>{
      'schema': schemaVersion,
      'ts': _timestampFromPath(backupPath),
      'backup': p.basename(backupPath),
      'type': type,
      'model': model,
      'modelSource': model == null ? null : _firmwareBanner,
      'version': version.version,
      'versionVerdict': version.verdict,
      'serial': identity.serial?.text,
      'serialState': identity.serial?.state.name,
      'uid': uid.value,
      'uidState': uid.state,
      'uidPrimary': uid.primary,
      'uidBackup': uid.backup,
      'key': keyAscii ? String.fromCharCodes(keyBytes) : _hex(keyBytes),
      'keyEncoding': keyAscii ? 'ascii' : 'hex',
      'keyState': switch (keyState) {
        FwKeyState.defaultKey => 'defaultKey',
        FwKeyState.blank => 'blank',
        FwKeyState.other when keyAscii => 'oem',
        FwKeyState.other => 'other',
      },
      'rand': _hex(dump.sublist(randOffset, randOffset + randLength)),
      'zpEncLen': zp.state == ZpRecordState.readable
          ? zp.payloadLength! + 4
          : null,
      'zpPayloadLen': zp.payloadLength,
      'zpState': zp.state.name,
      'dumpVerdict': 'ok',
    };
  }

  /// Creates a JSON sidecar without replacing any existing sidecar.
  ///
  /// The complete JSON is written to `.json.part` first, then renamed only
  /// after the write succeeds. A sidecar error is intentionally left to the
  /// caller: backup validity was settled before this optional metadata step.
  static String writeValidatedSidecar(String dumpPath) {
    final dump = File(dumpPath).readAsBytesSync();
    final sidecar = sidecarPath(dumpPath);
    final target = File(sidecar);
    if (target.existsSync()) {
      throw FileSystemException('Backup info sidecar already exists', sidecar);
    }

    final temporary = File('$sidecar.part');
    final encoded = const JsonEncoder.withIndent(
      '  ',
    ).convert(inspect(dump, backupPath: dumpPath));
    temporary.createSync(exclusive: true);
    temporary.writeAsStringSync(
      '$encoded\n',
      mode: FileMode.write,
      flush: true,
    );
    if (target.existsSync()) {
      throw FileSystemException('Backup info sidecar already exists', sidecar);
    }
    temporary.renameSync(sidecar);
    return sidecar;
  }

  /// Adds an operator-declared model to an existing MCU backup sidecar.
  ///
  /// The backup bytes are re-read first: only the exact supported MCU banner
  /// at full-dump offset 0x1400 can receive this annotation. The model itself
  /// remains an operator declaration; it selects the version matrix used to
  /// decode [version] and does not become a firmware-detected fact.
  ///
  /// All validation happens before the sidecar is rewritten. The replacement
  /// is flushed to `.part` and renamed over the old JSON, so Cancel or a
  /// validation/write failure leaves the original sidecar usable.
  static Map<String, Object?> declareMcuModel(
    String dumpPath,
    String sidecarPath,
    String declaredModel,
  ) {
    final metadata = readJson(sidecarPath);
    final model = _knownMcuModel(declaredModel);
    if (metadata['backup'] != p.basename(dumpPath)) {
      throw FormatException('Backup info does not belong to this backup file.');
    }
    if (metadata['type'] != 'MCU' || metadata['model'] != null) {
      throw const FormatException(
        'Only an MCU sidecar with no model can receive a model declaration.',
      );
    }

    final dump = File(dumpPath).readAsBytesSync();
    if (dump.length != Firmware.expectedSize) {
      throw FormatException(
        'The backup is not a complete ${Firmware.expectedSize}-byte image.',
      );
    }
    final identity = DeviceSpec.describeBin(dump, slotBin: false);
    if (!identity.bannerSupported || identity.bannerType != 'MCU') {
      throw const FormatException(
        'The backup no longer has the exact supported MCU firmware banner.',
      );
    }

    final version = FwVersionScanner.identify(
      dump.sublist(Zp.slot0Offset, 0x10000),
      model: model,
      type: 'MCU',
    );
    final updated = <String, Object?>{};
    for (final entry in metadata.entries) {
      switch (entry.key) {
        case 'schema':
          updated['schema'] = schemaVersion;
        case 'model':
          updated['model'] = model;
          updated['modelSource'] = _operatorDeclared;
        case 'modelSource':
          // Reinserted immediately after `model` above, whether this sidecar
          // was schema 1 (no source) or schema 2 (null source).
          break;
        case 'version':
          updated['version'] = version.version?.toString();
        case 'versionVerdict':
          updated['versionVerdict'] = version.verdict.name;
        default:
          updated[entry.key] = entry.value;
      }
    }
    _replaceSidecar(sidecarPath, updated);
    return updated;
  }

  /// An MCU sidecar needs a declaration only when its original byte-only
  /// analysis reached the expected model-required state.
  static bool needsMcuModelDeclaration(Map<String, Object?> metadata) =>
      metadata['type'] == 'MCU' &&
      metadata['model'] == null &&
      metadata['versionVerdict'] == 'modelRequired';

  static String _knownMcuModel(String value) {
    final model = value.trim().toLowerCase();
    if (FwVersionMatrix.known.containsKey(FwVersionMatrix.key(model, 'MCU'))) {
      return model;
    }
    throw FormatException('Unsupported MCU model "$value".');
  }

  static void _replaceSidecar(
    String sidecarPath,
    Map<String, Object?> metadata,
  ) {
    final target = File(sidecarPath);
    if (!target.existsSync()) {
      throw FileSystemException(
        'Backup info sidecar no longer exists',
        sidecarPath,
      );
    }
    final temporary = File('$sidecarPath.part');
    if (temporary.existsSync()) {
      throw FileSystemException(
        'Backup info has an unfinished sidecar update',
        temporary.path,
      );
    }
    final encoded = const JsonEncoder.withIndent('  ').convert(metadata);
    try {
      temporary.createSync(exclusive: true);
      temporary.writeAsStringSync(
        '$encoded\n',
        mode: FileMode.write,
        flush: true,
      );
      temporary.renameSync(sidecarPath);
    } catch (_) {
      if (temporary.existsSync()) temporary.deleteSync();
      rethrow;
    }
  }

  /// How a sidecar renders, and ONLY how a sidecar renders.
  ///
  /// The file inspector deliberately keeps its own rules rather than reusing
  /// these: it describes bytes on disk right now, this describes what a
  /// validated backup was when it was taken, and the two should be free to
  /// diverge without dragging each other along.
  static List<InfoRow> rows(Map<String, Object?> metadata) {
    final firmware = <String>[
      if (metadata['model'] != null) infoText(metadata['model']).toUpperCase(),
      infoText(metadata['type']),
      infoText(metadata['version']),
    ].where((part) => part != '—').join(' ');
    final uidConflict =
        metadata['uid'] == null && metadata['uidState'] == 'conflict';
    final zpKnown =
        metadata['zpPayloadLen'] != null && metadata['zpEncLen'] != null;

    return [
      InfoRow('Backup', infoText(metadata['backup'])),
      // No verdict row. A sidecar is only ever written after a dump has been
      // validated and promoted, so `dumpVerdict` can only say `ok` — a row
      // that cannot vary is not information. The field stays in the JSON for
      // machine use.
      InfoRow(
        'Firmware',
        firmware.isEmpty ? '—' : firmware,
        state: infoText(metadata['versionVerdict']),
      ),
      if (metadata['modelSource'] == _operatorDeclared)
        InfoRow(
          'Model',
          infoText(metadata['model']).toUpperCase(),
          state: 'operator-declared; MCU firmware does not encode it',
        ),
      // State only where something was PROVEN: a serial on the known-generic
      // list, an erased pair, an unreadable region. A shape-valid serial that
      // matched nothing has been recognised by nothing, and `real` would claim
      // it was checked against something.
      InfoRow(
        'Serial',
        infoText(metadata['serial']),
        state: switch (metadata['serialState']) {
          'generic' => 'generic replacement serial',
          'cleared' => 'cleared',
          'none' => 'unreadable',
          _ => null,
        },
        secret: true,
      ),
      InfoRow(
        'UID',
        uidConflict
            ? '${infoGrouped(metadata['uidPrimary'], 4)} / '
                  '${infoGrouped(metadata['uidBackup'], 4)}'
            : infoGrouped(metadata['uid'], 4),
        state: uidConflict ? 'copies conflict' : infoText(metadata['uidState']),
        secret: true,
      ),
      // ALWAYS HEX, even though the JSON stores the key as text when its bytes
      // happen to be printable. Pairing text reads as 8 bytes for a 16-byte
      // key, and uppercasing it changes the value — which is what Copy all
      // would then hand over, from the dialog attached to the only copy of the
      // original key. `oem`/`other` go the same way as `real` above.
      InfoRow(
        'Key',
        _keyHex(metadata),
        state: switch (metadata['keyState']) {
          'defaultKey' => 'default key',
          'blank' => 'blank',
          _ => null,
        },
        secret: true,
      ),
      InfoRow('Rand', infoGrouped(metadata['rand'], 2), secret: true),
      InfoRow(
        'ZP',
        zpKnown
            ? '${metadata['zpPayloadLen']} payload / '
                  '${metadata['zpEncLen']} encoded'
            : '—',
        state: infoText(metadata['zpState']),
      ),
    ];
  }

  /// The stored key as grouped hex, whichever form the sidecar recorded.
  ///
  /// `keyEncoding: ascii` means the 16 bytes were printable and [inspect]
  /// stored them as text; its code units ARE those bytes, so the conversion
  /// is lossless and the original case survives in the hex.
  static String _keyHex(Map<String, Object?> metadata) {
    final raw = infoText(metadata['key']);
    if (raw == '—') return raw;
    return infoGrouped(
      metadata['keyEncoding'] == 'ascii'
          ? raw.codeUnits
                .map((unit) => unit.toRadixString(16).padLeft(2, '0'))
                .join()
          : raw,
      2,
    );
  }

  /// Reads a sidecar produced by [writeValidatedSidecar].
  static Map<String, Object?> readJson(String sidecarPath) {
    final decoded = jsonDecode(File(sidecarPath).readAsStringSync());
    if (decoded is! Map) {
      throw const FormatException('Backup info is not a JSON object.');
    }
    return Map<String, Object?>.from(decoded);
  }

  /// Version scan over a slot-0 payload region.
  ///
  /// Public because the same read has to serve a picked slot bin or a zip3
  /// payload, which ARE that region rather than containing it. Pass slot 0
  /// only — see [FwVersionScanner.identify] for why slot 1 must not be
  /// included.
  static ({String? version, String verdict}) scanVersion(
    List<int> slot0, {
    required String? type,
    required String? model,
  }) {
    if (type == 'MCU') return (version: null, verdict: 'modelRequired');
    if (type != 'VCU' || model == null) {
      return (version: null, verdict: 'unavailable');
    }
    final found = FwVersionScanner.identify(slot0, model: model, type: type!);
    return (version: found.version?.toString(), verdict: found.verdict.name);
  }

  /// Slot 0 out of a full image. The slice is skipped when the type/model
  /// guards in [scanVersion] will short-circuit before reading it.
  static ({String? version, String verdict}) _version(
    List<int> dump, {
    required String? type,
    required String? model,
  }) => scanVersion(
    type == 'VCU' && model != null
        ? dump.sublist(Zp.slot0Offset, 0x10000)
        : const <int>[],
    type: type,
    model: model,
  );

  static _Uid _uid(List<int> dump) {
    final primary = _uidAt(dump, uidPrimaryOffset);
    final backup = _uidAt(dump, uidBackupOffset);
    if (primary == null && backup == null) return const _Uid('blank');
    if (primary != null && backup != null) {
      return primary == backup
          ? _Uid('matched', value: primary, primary: primary, backup: backup)
          : _Uid('conflict', primary: primary, backup: backup);
    }
    return primary != null
        ? _Uid('primaryOnly', value: primary, primary: primary)
        : _Uid('backupOnly', value: backup, backup: backup);
  }

  static String? _uidAt(List<int> dump, int offset) {
    final bytes = dump.sublist(offset, offset + uidLength);
    if (_isBlank(bytes)) return null;
    final groups = <String>[];
    for (var i = 0; i < bytes.length; i += 2) {
      groups.add(_hex(<int>[bytes[i + 1], bytes[i]]).toUpperCase());
    }
    return groups.join();
  }

  static bool _isBlank(List<int> bytes) =>
      bytes.every((byte) => byte == 0x00) ||
      bytes.every((byte) => byte == 0xFF);

  static bool _isPrintableAscii(List<int> bytes) =>
      bytes.every((byte) => byte >= 0x20 && byte <= 0x7E);

  static String _hex(List<int> bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  static String _timestampFromPath(String path) {
    final match = RegExp(
      r'(\d{4}-\d{2}-\d{2})_(\d{2})-(\d{2})-(\d{2})',
    ).firstMatch(p.basename(path));
    if (match == null) return DateTime.now().toIso8601String().split('.').first;
    return '${match.group(1)}T${match.group(2)}:${match.group(3)}:${match.group(4)}';
  }
}

class _Uid {
  const _Uid(this.state, {this.value, this.primary, this.backup});
  final String state;
  final String? value;
  final String? primary;
  final String? backup;
}
