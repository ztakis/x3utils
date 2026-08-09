/// Local-only identity metadata for a validated full backup dump.
///
/// This is deliberately observation-only. It reads known full-image offsets to
/// create a sidecar next to a promoted backup; it never accepts, refuses,
/// patches, or otherwise changes a backup/flash verdict. The values may be
/// device identity material, so callers must keep the sidecar local.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'device_spec.dart';
import 'firmware.dart';
import 'fw_version.dart';
import 'zp_extract.dart';

/// Reads a promoted 128 KB backup and writes its adjacent JSON sidecar.
class DumpMetadata {
  const DumpMetadata._();

  static const int schemaVersion = 1;

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

  /// Reads a sidecar produced by [writeValidatedSidecar].
  static Map<String, Object?> readJson(String sidecarPath) {
    final decoded = jsonDecode(File(sidecarPath).readAsStringSync());
    if (decoded is! Map) {
      throw const FormatException('Backup info is not a JSON object.');
    }
    return Map<String, Object?>.from(decoded);
  }

  static _Version _version(
    List<int> dump, {
    required String? type,
    required String? model,
  }) {
    if (type == 'MCU') return const _Version(null, 'modelRequired');
    if (type != 'VCU' || model == null) {
      return const _Version(null, 'unavailable');
    }
    final slot0 = dump.sublist(Zp.slot0Offset, 0x10000);
    final found = FwVersionScanner.identify(slot0, model: model, type: type!);
    return _Version(found.version?.toString(), found.verdict.name);
  }

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

class _Version {
  const _Version(this.version, this.verdict);
  final String? version;
  final String verdict;
}

class _Uid {
  const _Uid(this.state, {this.value, this.primary, this.backup});
  final String state;
  final String? value;
  final String? primary;
  final String? backup;
}
