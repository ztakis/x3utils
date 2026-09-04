/// Evidence certificate for the opt-in standalone Backup BETA path.
///
/// The ordinary `.json` sidecar remains the canonical local identity record.
/// This adjacent `.extra.json` records how the backup was captured and the
/// anomaly checks applied to it. It is observational: only the controller may
/// decide whether a capture is accepted.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:universal_io/universal_io.dart';

import '../theme.dart';
import 'device_spec.dart';
import 'firmware.dart';
import 'fw_version.dart';
import 'hardware_backend.dart';
import 'sram_identity.dart';
import 'swdart_backend.dart';

class ExtraBackupMetadata {
  const ExtraBackupMetadata._();

  static const int schemaVersion = 2;

  static String sidecarPath(String dumpPath) {
    final extension = p.extension(dumpPath);
    final stem = extension.isEmpty
        ? dumpPath
        : dumpPath.substring(0, dumpPath.length - extension.length);
    return '$stem.extra.json';
  }

  /// Path of the raw SRAM snapshot beside a dump: `dump_<ts>_RAM.bin`.
  ///
  /// SRAM is live memory that cannot be re-read from the saved `.bin`, so it is
  /// persisted as its own raw artifact. It is 32 KiB, never the 131072 bytes a
  /// flash image must be, so the firmware validators refuse it as a flash
  /// source; the `_RAM` name is the human-facing signal on top of that gate.
  static String sramBinPath(String dumpPath) {
    final extension = p.extension(dumpPath);
    final stem = extension.isEmpty
        ? dumpPath
        : dumpPath.substring(0, dumpPath.length - extension.length);
    return '${stem}_RAM.bin';
  }

  /// Writes the raw SRAM snapshot to [sramBinPath] via a `.part` + rename so a
  /// truncated write never lands as a real `_RAM.bin`. Refuses to overwrite an
  /// existing snapshot, mirroring [write].
  static String writeSramBin(String dumpPath, List<int> bytes) {
    final path = sramBinPath(dumpPath);
    final target = File(path);
    if (target.existsSync()) {
      throw FileSystemException('Extra SRAM snapshot already exists', path);
    }
    final temporary = File('$path.part');
    try {
      temporary.createSync(exclusive: true);
      temporary.writeAsBytesSync(bytes, flush: true);
      if (target.existsSync()) {
        throw FileSystemException('Extra SRAM snapshot already exists', path);
      }
      temporary.renameSync(path);
      return path;
    } catch (_) {
      if (temporary.existsSync()) temporary.deleteSync();
      rethrow;
    }
  }

  static String digest(List<int> bytes) =>
      crypto.sha256.convert(bytes).toString();

  static Map<String, Object?> inspect({
    required String dumpPath,
    required List<int> firstRead,
    required List<int> secondRead,
    required List<int>? sramBytes,
    String? sramPath,
    required ExtraBackupHardwareEvidence hardware,
    required Map<String, Object?> backupMetadata,
    required bool secondaryCreated,
    required bool secondaryVerified,
    required String backendName,
    required String connectionMode,
    String? secondaryPath,
  }) {
    if (firstRead.length != Firmware.expectedSize ||
        secondRead.length != Firmware.expectedSize) {
      throw ArgumentError('Extra backup requires two complete 128 KiB reads.');
    }

    var differenceCount = 0;
    int? firstDifferenceOffset;
    for (var i = 0; i < firstRead.length; i++) {
      if (firstRead[i] == secondRead[i]) continue;
      differenceCount++;
      firstDifferenceOffset ??= i;
    }

    final rom = DeviceSpec.describeBin(firstRead, slotBin: false);
    final sram = SramIdentityParser.parse(sramBytes);
    final flashWords = <int>[
      for (var i = 0; i < 16; i += 4) _u32le(firstRead, i),
    ];
    final protection = classifySwdartProtection(
      usdWord: hardware.usdWord,
      flashWords: flashWords,
    ).verdict;
    final tea = CompatPatch.keyState(firstRead);
    final xtea = CompatXtea.keyState(firstRead);
    final model = backupMetadata['model'] as String?;
    final type = backupMetadata['type'] as String?;
    final versionVerdict = backupMetadata['versionVerdict'] as String?;
    final blacklistFrom = model == null || type == null
        ? null
        : FwVersionMatrix.refusedFrom(model, type)?.toString();
    final blacklisted = versionVerdict == FwVerdict.blacklisted.name;
    final romVersion = backupMetadata['version'] as String?;
    final scooterSerial = backupMetadata.containsKey('scooterSerial')
        ? backupMetadata['scooterSerial']
        : backupMetadata['serial'];
    final scooterSerialState = backupMetadata.containsKey('scooterSerialState')
        ? backupMetadata['scooterSerialState']
        : backupMetadata['serialState'];

    final findings = <String>[];
    if (differenceCount != 0) findings.add('flashReadsDiffer');
    if (sram.verdict == SramIdentityVerdict.notFound) {
      findings.add('sramIdentityNotFound');
    } else if (sram.verdict == SramIdentityVerdict.conflicting) {
      findings.add('sramIdentityConflicting');
    }
    if (hardware.usdWord == null ||
        protection == HardwareProtectionVerdict.inconclusive) {
      findings.add('protectionInconclusive');
    }
    if (blacklisted) findings.add('blacklistedVersion');
    if (versionVerdict == 'unknown' ||
        versionVerdict == 'ambiguous' ||
        versionVerdict == 'modelRequired') {
      findings.add('firmwareIdentityIncomplete');
    }
    if (rom.serialModelClash) {
      findings.add('romScooterSerialModelConflict');
    }
    if (backupMetadata['uidState'] == 'conflict') {
      findings.add('uidCopiesConflict');
    }
    if (tea == FwKeyState.defaultKey) findings.add('teaDefaultShuKey');
    if (tea == FwKeyState.blank) findings.add('teaFieldCleared');
    if (xtea == FwXteaState.present) findings.add('xteaFieldPresent');
    if (xtea == FwXteaState.cleared) findings.add('xteaFieldCleared');
    if (!secondaryVerified) findings.add('secondaryCopyNotVerified');

    final runtime = sram.identity;
    if (runtime != null && type != null && runtime.type != type) {
      findings.add('romSramComponentConflict');
    }
    if (runtime != null &&
        romVersion != null &&
        runtime.version.toString() != romVersion) {
      findings.add('romSramVersionConflict');
    }
    if (runtime?.serial != null &&
        scooterSerial != null &&
        runtime!.serial != scooterSerial) {
      findings.add('romSramScooterSerialConflict');
    }
    if (runtime?.serialModel != null &&
        model != null &&
        runtime!.serialModel != model) {
      findings.add('romSramModelConflict');
    }
    final initialSp = _u32le(firstRead, 0);
    final resetVector = _u32le(firstRead, 4);
    final vectorPlausible =
        initialSp >= 0x20000000 &&
        initialSp <= 0x20008000 &&
        resetVector >= 0x08000001 &&
        resetVector < 0x08020000 &&
        resetVector.isOdd;
    if (!vectorPlausible) findings.add('vectorTableNotPlausible');
    final shuCompatibility = switch ((model, type, versionVerdict, xtea)) {
      (final String m, _, _, _)
          when FwVersionMatrix.unsupportedModels.contains(m) =>
        'blockedModel',
      (_, _, 'blacklisted', _) => 'blockedVersion',
      (_, _, _, FwXteaState.present) => 'blockedXtea',
      (final String _, final String _, 'identified', _) =>
        'eligibleByCurrentPolicy',
      _ => 'unknown',
    };
    return <String, Object?>{
      'schema': schemaVersion,
      'kind': 'x3utilsExtraBackup',
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'tool': <String, Object?>{'version': kAppVersion, 'stage': kAppStage},
      'backup': <String, Object?>{
        'file': p.basename(dumpPath),
        'bytes': firstRead.length,
        'normalSidecar': p.basename(p.setExtension(dumpPath, '.json')),
        'role': 'factoryRestoreCandidate',
        'factoryConditionClaim': 'notProvenWithoutAnExternalReference',
      },
      'capture': <String, Object?>{
        'probeSessions': 1,
        'flashReads': 2,
        'match': differenceCount == 0,
        'differenceCount': differenceCount,
        'firstDifferenceOffset': firstDifferenceOffset,
        'sha256Read1': digest(firstRead),
        'sha256Read2': digest(secondRead),
        'sramAttempted': true,
        'sramBytesReturned': sramBytes?.length,
        'sramSha256': sramBytes == null ? null : digest(sramBytes),
        'sramFile': sramPath == null ? null : p.basename(sramPath),
        'backend': backendName,
        'connectionMode': connectionMode,
        'hostPlatform': Platform.operatingSystem,
      },
      'target': <String, Object?>{
        'name': hardware.targetName,
        'family': hardware.targetFamily,
        'idcode': _hex(hardware.idcode, 8),
        'flashKB': hardware.flashKB,
        'pageSize': hardware.pageSize,
        'sramBytes': hardware.sramBytes,
      },
      'protection': <String, Object?>{
        'usdAddress': '0x1FFFF800',
        'usdReadAttempted': true,
        'usdWord': hardware.usdWord == null ? null : _hex(hardware.usdWord!, 8),
        'fap': hardware.usdWord == null
            ? null
            : _hex(hardware.usdWord! & 0xff, 2),
        'fapComplement': hardware.usdWord == null
            ? null
            : _hex((hardware.usdWord! >> 8) & 0xff, 2),
        'complementConsistent': hardware.usdWord == null
            ? null
            : ((hardware.usdWord! & 0xff) ^
                      ((hardware.usdWord! >> 8) & 0xff)) ==
                  0xff,
        'verdict': protection.name,
        'rdpOn': protection == HardwareProtectionVerdict.protected,
        'fapUnlocked': hardware.usdWord == null
            ? null
            : (hardware.usdWord! & 0xff) == 0xa5,
      },
      'vectorTable': <String, Object?>{
        'initialSp': _hex(initialSp, 8),
        'resetVector': _hex(resetVector, 8),
        'plausible': vectorPlausible,
      },
      'firmware': <String, Object?>{
        'romBanner': rom.banner,
        'bannerSupported': rom.bannerSupported,
        'type': type,
        'model': model,
        'modelSource': backupMetadata['modelSource'],
        'mcuModelUserProvided':
            type == 'MCU' &&
            backupMetadata['modelSource'] == 'operatorDeclared',
        'version': backupMetadata['version'],
        'versionVerdict': versionVerdict,
        'blacklistFrom': blacklistFrom,
        'blacklisted': blacklisted,
        'blacklistedVersion': blacklisted ? romVersion : null,
        'shuCompatibilityAtCapture': shuCompatibility,
        'policyToolVersion': kAppVersion,
      },
      'compatibilityFields': <String, Object?>{
        'teaAt0x1420': tea.name,
        'xteaAt0x1440': xtea.name,
      },
      'runtime': <String, Object?>{
        'verdict': sram.verdict.name,
        'reason': sram.reason.isEmpty ? null : sram.reason,
        'component': runtime?.type,
        'version': runtime?.version.toString(),
        'tableOffsets': runtime?.tableOffsets.map(_hexOffset).toList(),
        'scooterSerial': runtime?.serial,
        'scooterModelFromSerial': runtime?.serialModel,
        'regionCode': runtime?.regionCode,
        'controllerSnMnCandidates': runtime?.controllerSnMnCandidates,
      },
      'identity': <String, Object?>{
        'scooterSerial': scooterSerial,
        'scooterSerialState': scooterSerialState,
        'controllerSnMn': backupMetadata['controllerSnMn'],
        'controllerSnMnState': backupMetadata['controllerSnMnState'],
        'controllerSnMnPrimary': backupMetadata['controllerSnMnPrimary'],
        'controllerSnMnBackup': backupMetadata['controllerSnMnBackup'],
        'uidState': backupMetadata['uidState'],
        'zpState': backupMetadata['zpState'],
      },
      'secondaryCopy': <String, Object?>{
        'required': true,
        'created': secondaryCreated,
        'verified': secondaryVerified,
        'file': secondaryPath == null ? null : p.basename(secondaryPath),
      },
      'findings': findings,
      'captureVerdict': differenceCount == 0 && findings.isEmpty
          ? 'complete'
          : 'completeWithFindings',
    };
  }

  /// Certificate for an Extra run that found the target read-protected.
  ///
  /// No flash was read, so every flash-derived fact is absent rather than
  /// guessed: no ROM banner, no ROM version, no TEA/XTEA state, no vector
  /// table, no flash identity. What remains is real evidence — live SRAM
  /// runtime identity, the protection reading, and target geometry.
  ///
  /// `backup.file` is null and the role is explicitly not a restore candidate:
  /// this run produced no backup and the record must never imply otherwise.
  static Map<String, Object?> inspectProtected({
    required List<int>? sramBytes,
    required ExtraBackupHardwareEvidence hardware,
    required String backendName,
    required String connectionMode,
    String? sramPath,
  }) {
    final sram = SramIdentityParser.parse(sramBytes);
    final protection = classifySwdartProtection(
      usdWord: hardware.usdWord,
      flashWords: null,
    ).verdict;
    final runtime = sram.identity;

    final findings = <String>['flashReadProtected'];
    if (sram.verdict == SramIdentityVerdict.notFound) {
      findings.add('sramIdentityNotFound');
    } else if (sram.verdict == SramIdentityVerdict.conflicting) {
      findings.add('sramIdentityConflicting');
    }
    if (sramBytes == null) findings.add('sramSnapshotMissing');

    return <String, Object?>{
      'schema': schemaVersion,
      'kind': 'x3utilsExtraBackup',
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'tool': <String, Object?>{'version': kAppVersion, 'stage': kAppStage},
      'backup': <String, Object?>{
        'file': null,
        'bytes': null,
        'normalSidecar': null,
        'role': 'diagnosticNoRestorableBackup',
        'factoryConditionClaim': 'notApplicableNoBackupWasRead',
      },
      'capture': <String, Object?>{
        'probeSessions': 1,
        'flashReads': 0,
        'flashReadSkippedReason': 'targetReadProtected',
        'match': null,
        'differenceCount': null,
        'firstDifferenceOffset': null,
        'sha256Read1': null,
        'sha256Read2': null,
        'sramAttempted': true,
        'sramBytesReturned': sramBytes?.length,
        'sramSha256': sramBytes == null ? null : digest(sramBytes),
        'sramFile': sramPath == null ? null : p.basename(sramPath),
        'backend': backendName,
        'connectionMode': connectionMode,
        'hostPlatform': Platform.operatingSystem,
      },
      'target': <String, Object?>{
        'name': hardware.targetName,
        'family': hardware.targetFamily,
        'idcode': _hex(hardware.idcode, 8),
        'flashKB': hardware.flashKB,
        'pageSize': hardware.pageSize,
        'sramBytes': hardware.sramBytes,
      },
      'protection': <String, Object?>{
        'usdAddress': '0x1FFFF800',
        'usdReadAttempted': true,
        'usdWord': hardware.usdWord == null ? null : _hex(hardware.usdWord!, 8),
        'fap': hardware.usdWord == null
            ? null
            : _hex(hardware.usdWord! & 0xff, 2),
        'fapComplement': hardware.usdWord == null
            ? null
            : _hex((hardware.usdWord! >> 8) & 0xff, 2),
        'complementConsistent': hardware.usdWord == null
            ? null
            : ((hardware.usdWord! & 0xff) ^
                      ((hardware.usdWord! >> 8) & 0xff)) ==
                  0xff,
        'verdict': protection.name,
        'rdpOn': protection == HardwareProtectionVerdict.protected,
        'fapUnlocked': hardware.usdWord == null
            ? null
            : (hardware.usdWord! & 0xff) == 0xa5,
      },
      'runtime': <String, Object?>{
        'verdict': sram.verdict.name,
        'reason': sram.reason.isEmpty ? null : sram.reason,
        'component': runtime?.type,
        'version': runtime?.version.toString(),
        'tableOffsets': runtime?.tableOffsets.map(_hexOffset).toList(),
        'scooterSerial': runtime?.serial,
        'scooterModelFromSerial': runtime?.serialModel,
        'regionCode': runtime?.regionCode,
        'controllerSnMnCandidates': runtime?.controllerSnMnCandidates,
      },
      'findings': findings,
      'captureVerdict': 'protectedNoBackup',
    };
  }

  static String write(String dumpPath, Map<String, Object?> metadata) {
    final sidecar = sidecarPath(dumpPath);
    final target = File(sidecar);
    if (target.existsSync()) {
      throw FileSystemException('Extra backup sidecar already exists', sidecar);
    }
    final temporary = File('$sidecar.part');
    final encoded = const JsonEncoder.withIndent('  ').convert(metadata);
    try {
      temporary.createSync(exclusive: true);
      temporary.writeAsStringSync('$encoded\n', flush: true);
      if (target.existsSync()) {
        throw FileSystemException(
          'Extra backup sidecar already exists',
          sidecar,
        );
      }
      temporary.renameSync(sidecar);
      return sidecar;
    } catch (_) {
      if (temporary.existsSync()) temporary.deleteSync();
      rethrow;
    }
  }

  static int _u32le(List<int> bytes, int offset) =>
      bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);

  static String _hex(int value, int width) =>
      '0x${value.toUnsigned(width * 4).toRadixString(16).padLeft(width, '0').toUpperCase()}';

  static String _hexOffset(int offset) =>
      '0x${offset.toRadixString(16).padLeft(4, '0').toUpperCase()}';
}
