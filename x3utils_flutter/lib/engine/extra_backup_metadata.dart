/// Evidence certificate for the opt-in standalone Backup BETA path.
///
/// The ordinary `.json` sidecar remains the canonical local identity record.
/// This adjacent `_EXTRA.json` records how the backup was captured and the
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

  // Schema 3 groups evidence by SOURCE: `rom` (flash-derived, solid),
  // `ram` (SRAM-derived, decoder is work-in-progress and anchored rather than
  // fixed-offset), and `findings` (cross-checks and oddities — grain of salt).
  // The envelope (backup/capture/target/protection/secondaryCopy) holds the
  // hard session facts that are neither interpretation nor grain of salt.
  //
  // Schema 4 changes what `rom.keyFields` VALUES mean: they now use the same
  // words as the ordinary sidecar's `keyState`/`xteaState` instead of raw enum
  // names. A reader that matched on `present` or a bare `other` must be
  // updated — hence a major bump rather than an additive field.
  static const int schemaVersion = 4;

  /// Path of the evidence certificate beside a dump: `dump_<ts>_EXTRA.json`.
  ///
  /// The qualifier is an underscore inside the stem, matching [sramBinPath]'s
  /// `_RAM.bin`, so every artifact this capture adds beyond the ordinary
  /// sidecar is marked the same way. Captures written before 2026-09-04 used
  /// `.extra.json`; nothing reads either name back, so those files keep theirs.
  static String sidecarPath(String dumpPath) {
    final extension = p.extension(dumpPath);
    final stem = extension.isEmpty
        ? dumpPath
        : dumpPath.substring(0, dumpPath.length - extension.length);
    return '${stem}_EXTRA.json';
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
    // Plain key-field STATE is not an oddity — it lives in rom.keyFields. Only
    // the notable/unexpected states are worth a grain-of-salt finding.
    if (xtea == FwXteaState.present) findings.add('xteaFieldPresent');
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
      'secondaryCopy': <String, Object?>{
        'required': true,
        'created': secondaryCreated,
        'verified': secondaryVerified,
        'file': secondaryPath == null ? null : p.basename(secondaryPath),
      },
      // Flash-derived facts. Solid, like the ordinary sidecar.
      'rom': <String, Object?>{
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
        'vectorTable': <String, Object?>{
          'initialSp': _hex(initialSp, 8),
          'resetVector': _hex(resetVector, 8),
          'plausible': vectorPlausible,
        },
        // Schema 4: the shared labels. These previously wrote the raw enum
        // names, so one capture's two sidecars described the same bytes
        // differently — `other`/`present` here against
        // `asciiAlphanumeric` in the ordinary `.json`.
        'keyFields': <String, Object?>{
          'teaAt0x1420': CompatPatch.keyStateLabel(firstRead),
          'xteaAt0x1440': CompatXtea.keyStateLabel(firstRead),
        },
        'identity': <String, Object?>{
          'scooterSerial': scooterSerial,
          if (scooterSerialState != null && scooterSerialState != 'real')
            'scooterSerialState': scooterSerialState,
          'uidState': backupMetadata['uidState'],
          'zpState': backupMetadata['zpState'],
        },
      },
      // SRAM-derived facts. Anchored by runtime-table markers, not fixed
      // offsets; the decoder is work in progress, so treat as softer than rom.
      'ram': _runtimeMap(sram),
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
      'target': _targetMap(hardware),
      'protection': _protectionMap(hardware, null),
      // No flash was read, so there is no ROM evidence at all.
      'rom': null,
      'ram': _runtimeMap(sram),
      'findings': findings,
      'captureVerdict': 'protectedNoBackup',
    };
  }

  /// Certificate for an Extra run where the flash WAS read but held nothing to
  /// back up — a blank/erased chip, or a masked read the pre-probe did not
  /// catch. Unlike [inspectProtected] the flash was accessible, so protection
  /// is classified from the real read; unlike [inspect] there is no restorable
  /// backup. The point of keeping this at all is the SRAM snapshot: it was
  /// captured in the same session and is evidence (and RAM-mapping material)
  /// that would otherwise be discarded with the empty flash read.
  static Map<String, Object?> inspectChipFinding({
    required String dumpVerdict,
    required List<int> firstRead,
    required List<int>? sramBytes,
    required ExtraBackupHardwareEvidence hardware,
    required String backendName,
    required String connectionMode,
    String? sramPath,
  }) {
    final sram = SramIdentityParser.parse(sramBytes);
    final flashWords = <int>[
      for (var i = 0; i < 16; i += 4) _u32le(firstRead, i),
    ];
    final findings = <String>['chipFinding_$dumpVerdict'];
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
        'flashReads': 2,
        'noBackupReason': 'chip_$dumpVerdict',
        'match': null,
        'differenceCount': null,
        'firstDifferenceOffset': null,
        'sha256Read1': digest(firstRead),
        'sha256Read2': null,
        'sramAttempted': true,
        'sramBytesReturned': sramBytes?.length,
        'sramSha256': sramBytes == null ? null : digest(sramBytes),
        'sramFile': sramPath == null ? null : p.basename(sramPath),
        'backend': backendName,
        'connectionMode': connectionMode,
        'hostPlatform': Platform.operatingSystem,
      },
      'target': _targetMap(hardware),
      'protection': _protectionMap(hardware, flashWords),
      // The flash read back empty (blank/masked), so no ROM firmware facts.
      'rom': null,
      'ram': _runtimeMap(sram),
      'findings': findings,
      'captureVerdict': 'chipFindingNoBackup',
    };
  }

  // Shared blocks for the no-backup certificate variants. [inspectProtected]
  // predates these and keeps its own inline copy; the two should merge when the
  // metadata architecture is unified.
  static Map<String, Object?> _targetMap(ExtraBackupHardwareEvidence h) =>
      <String, Object?>{
        'name': h.targetName,
        'family': h.targetFamily,
        'idcode': _hex(h.idcode, 8),
        'flashKB': h.flashKB,
        'pageSize': h.pageSize,
        'sramBytes': h.sramBytes,
      };

  static Map<String, Object?> _protectionMap(
    ExtraBackupHardwareEvidence hardware,
    List<int>? flashWords,
  ) {
    final verdict = classifySwdartProtection(
      usdWord: hardware.usdWord,
      flashWords: flashWords,
    ).verdict;
    final usd = hardware.usdWord;
    return <String, Object?>{
      'usdAddress': '0x1FFFF800',
      'usdReadAttempted': true,
      'usdWord': usd == null ? null : _hex(usd, 8),
      'fap': usd == null ? null : _hex(usd & 0xff, 2),
      'fapComplement': usd == null ? null : _hex((usd >> 8) & 0xff, 2),
      'complementConsistent': usd == null
          ? null
          : ((usd & 0xff) ^ ((usd >> 8) & 0xff)) == 0xff,
      'verdict': verdict.name,
      'rdpOn': verdict == HardwareProtectionVerdict.protected,
      'fapUnlocked': usd == null ? null : (usd & 0xff) == 0xa5,
    };
  }

  static Map<String, Object?> _runtimeMap(SramIdentityResult sram) {
    final runtime = sram.identity;
    // Deliberately lean: model-from-serial (redundant with the ROM banner),
    // region (not a designed/validated feature), and SN/MN candidates
    // (low-value) are NOT emitted. The SramIdentity class still carries them
    // for internal use; they just do not belong in this record.
    return <String, Object?>{
      'verdict': sram.verdict.name,
      'reason': sram.reason.isEmpty ? null : sram.reason,
      'component': runtime?.type,
      'version': runtime?.version.toString(),
      'tableOffsets': runtime?.tableOffsets.map(_hexOffset).toList(),
      'scooterSerial': runtime?.serial,
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
