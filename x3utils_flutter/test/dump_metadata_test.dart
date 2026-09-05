import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:x3utils_flutter/engine/device_spec.dart';
import 'package:x3utils_flutter/engine/dump_metadata.dart';
import 'package:x3utils_flutter/engine/firmware.dart';
import 'package:x3utils_flutter/engine/info_row.dart';

List<int> _dump(String banner) {
  final bytes = List<int>.generate(131072, (i) => i % 251);
  bytes.setRange(
    kSlotBannerOffset,
    kSlotBannerOffset + kBannerLength,
    banner.codeUnits,
  );
  return bytes;
}

void _movw(List<int> bytes, int offset, int immediate) {
  final i = (immediate >> 11) & 1;
  final imm3 = (immediate >> 8) & 7;
  final imm8 = immediate & 0xFF;
  final hw1 = 0xF240 | (i << 10);
  final hw2 = (imm3 << 12) | imm8;
  bytes.setRange(offset, offset + 4, [
    hw1 & 0xFF,
    hw1 >> 8,
    hw2 & 0xFF,
    hw2 >> 8,
  ]);
}

void _writeZp(List<int> bytes, int payloadLength) {
  final encodedLength = payloadLength + 4;
  bytes.setRange(0x1F800, 0x1F810, [
    0x5A,
    0x50,
    0,
    0,
    0,
    0,
    0,
    0,
    encodedLength & 0xFF,
    (encodedLength >> 8) & 0xFF,
    (encodedLength >> 16) & 0xFF,
    (encodedLength >> 24) & 0xFF,
    0,
    0,
    0,
    0,
  ]);
}

void main() {
  test('reads known VCU metadata and UID words from a full dump', () {
    final bytes = _dump('SCOOTER_VCU_xxG3');
    const serial = '1CGCXXXXXXXXXX';
    const boardSnMn = 'Z03BXXXXXXXXXXXX';
    final uid = [
      0x9B,
      0xC4,
      0xB9,
      0x0D,
      0,
      0,
      0x93,
      0x21,
      0x07,
      0xA7,
      0xE8,
      0x05,
    ];
    bytes.setRange(
      kSerialOffset,
      kSerialOffset + kSerialLength,
      serial.codeUnits,
    );
    bytes.setRange(
      kSerialBackupOffset,
      kSerialBackupOffset + kSerialLength,
      serial.codeUnits,
    );
    // A VCU's own board SN/MN sits one record field past the scooter serial.
    bytes.setRange(
      kBoardSnMnOffset,
      kBoardSnMnOffset + kControllerSnMnLength,
      boardSnMn.codeUnits,
    );
    bytes.setRange(
      kBoardSnMnBackupOffset,
      kBoardSnMnBackupOffset + kControllerSnMnLength,
      boardSnMn.codeUnits,
    );
    bytes.setRange(
      DumpMetadata.uidPrimaryOffset,
      DumpMetadata.uidPrimaryOffset + 12,
      uid,
    );
    bytes.setRange(
      DumpMetadata.uidBackupOffset,
      DumpMetadata.uidBackupOffset + 12,
      uid,
    );
    bytes.setRange(
      CompatPatch.offset,
      CompatPatch.offset + 16,
      '7aoymhtysf886lb6'.codeUnits,
    );
    bytes.setRange(
      DumpMetadata.randOffset,
      DumpMetadata.randOffset + 6,
      List.filled(6, 0xFF),
    );
    _writeZp(bytes, 59028);
    _movw(bytes, 0x3000, 0x161); // G3 VCU 1.6.1

    final info = DumpMetadata.inspect(
      bytes,
      backupPath: r'C:\x3utils\backup\dump_2026-08-09_02-06-52.bin',
    );

    expect(info['schema'], DumpMetadata.schemaVersion);
    expect(info['ts'], '2026-08-09T02:06:52');
    expect(info['backup'], 'dump_2026-08-09_02-06-52.bin');
    expect(info['type'], 'VCU');
    expect(info['model'], 'g3');
    expect(info['modelSource'], 'firmwareBanner');
    expect(info['version'], '1.6.1');
    expect(info['versionVerdict'], 'identified');
    expect(info['scooterSerial'], serial);
    // 'real' is the boring default and is intentionally not emitted.
    expect(info.containsKey('scooterSerialState'), isFalse);
    // A VCU carries its own board SN/MN at 0x1F040, behind the scooter serial.
    expect(info['controllerSnMn'], boardSnMn);
    expect(info.containsKey('controllerSnMnState'), isFalse);
    expect(info.containsKey('serial'), isFalse);
    expect(info['uid'], 'C49B0DB900002193A70705E8');
    expect(info['uidState'], 'matched');
    // Raw bytes stay canonical hex; the state records the narrower OEM shape.
    expect(info['key'], '37616f796d68747973663838366c6236');
    expect(info['keyEncoding'], 'hex');
    expect(info['keyState'], 'asciiAlphanumeric');
    expect(info['rand'], 'ffffffffffff');
    expect(info['xtea'], isNull);
    expect(info['xteaEncoding'], 'hex');
    expect(info['xteaState'], 'notDetected');
    expect(info['zpEncLen'], 59032);
    expect(info['zpPayloadLen'], 59028);
    expect(info['zpState'], 'readable');
    expect(info['dumpVerdict'], 'ok');
  });

  test('records only ASCII-alphanumeric key shapes as such', () {
    final bytes = _dump('SCOOTER_VCU_xxU2');
    bytes.setRange(
      CompatPatch.offset,
      CompatPatch.offset + CompatPatch.signature.length,
      'Abcd1234-Efgh!56'.codeUnits,
    );

    final info = DumpMetadata.inspect(bytes, backupPath: 'dump.bin');
    expect(info['keyState'], 'other');
  });

  test('records XTEA as hex only for the ASCII-alphanumeric field shape', () {
    final present = _dump('SCOOTER_VCU_xxU2');
    present.setRange(
      CompatXtea.offset,
      CompatXtea.offset + CompatXtea.length,
      'Xtea1234Key56789'.codeUnits,
    );
    final presentInfo = DumpMetadata.inspect(present, backupPath: 'dump.bin');
    expect(presentInfo['xtea'], '58746561313233344b65793536373839');
    expect(presentInfo['xteaEncoding'], 'hex');
    expect(presentInfo['xteaState'], 'asciiAlphanumeric');

    final cleared = _dump('SCOOTER_VCU_xxU2');
    cleared.setRange(
      CompatXtea.offset,
      CompatXtea.offset + CompatXtea.length,
      List<int>.filled(CompatXtea.length, 0xFF),
    );
    final clearedInfo = DumpMetadata.inspect(cleared, backupPath: 'dump.bin');
    expect(clearedInfo['xtea'], isNull);
    expect(clearedInfo['xteaEncoding'], 'hex');
    expect(clearedInfo['xteaState'], 'cleared');
  });

  test('does not infer an MCU model and records conflicting UID copies', () {
    final bytes = _dump('SCOOTER_MCU_0001');
    const controllerSnMn = 'Z025XXXXXXXXXXXX';
    bytes.setRange(
      kControllerSnMnOffset,
      kControllerSnMnOffset + kControllerSnMnLength,
      controllerSnMn.codeUnits,
    );
    bytes.setRange(
      kControllerSnMnBackupOffset,
      kControllerSnMnBackupOffset + kControllerSnMnLength,
      controllerSnMn.codeUnits,
    );
    bytes.setRange(
      DumpMetadata.uidPrimaryOffset,
      DumpMetadata.uidPrimaryOffset + 12,
      List<int>.filled(12, 0x11),
    );
    bytes.setRange(
      DumpMetadata.uidBackupOffset,
      DumpMetadata.uidBackupOffset + 12,
      List<int>.filled(12, 0x22),
    );

    final info = DumpMetadata.inspect(
      bytes,
      backupPath: 'dump_2026-08-09_14-36-53.bin',
    );

    expect(info['type'], 'MCU');
    expect(info['model'], isNull);
    expect(info['version'], isNull);
    expect(info['versionVerdict'], 'modelRequired');
    expect(info['scooterSerial'], isNull);
    expect(info['scooterSerialState'], isNull);
    // Both identity copies agree, so `matched` stays the unstated default.
    expect(info['controllerSnMn'], controllerSnMn);
    expect(info.containsKey('controllerSnMnState'), isFalse);
    expect(info.containsKey('serial'), isFalse);
    expect(info['uid'], isNull);
    expect(info['uidState'], 'conflict');
    expect(info['uidPrimary'], '111111111111111111111111');
    expect(info['uidBackup'], '222222222222222222222222');
  });

  test('writes an adjacent JSON sidecar without replacing one', () {
    final dir = Directory.systemTemp.createTempSync('x3utils_dump_metadata_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final dumpPath = p.join(dir.path, 'dump_2026-08-09_02-06-52.bin');
    final bytes = _dump('SCOOTER_VCU_xxG3');
    bytes.setRange(
      CompatXtea.offset,
      CompatXtea.offset + CompatXtea.length,
      'Xtea1234Key56789'.codeUnits,
    );
    File(dumpPath).writeAsBytesSync(bytes);

    final sidecar = DumpMetadata.writeValidatedSidecar(dumpPath);
    final json =
        jsonDecode(File(sidecar).readAsStringSync()) as Map<String, dynamic>;

    expect(sidecar, p.join(dir.path, 'dump_2026-08-09_02-06-52.json'));
    expect(json['backup'], p.basename(dumpPath));
    expect(json['dumpVerdict'], 'ok');
    expect(json['xtea'], '58746561313233344b65793536373839');
    expect(json['xteaEncoding'], 'hex');
    expect(json['xteaState'], 'asciiAlphanumeric');
    expect(File('$sidecar.part').existsSync(), isFalse);
    expect(
      () => DumpMetadata.writeValidatedSidecar(dumpPath),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('persists an operator-declared MCU model and decoded version', () {
    final dir = Directory.systemTemp.createTempSync('x3utils_mcu_metadata_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final dumpPath = p.join(dir.path, 'dump_2026-08-10_23-18-58.bin');
    final bytes = List<int>.filled(Firmware.expectedSize, 0);
    bytes.setRange(
      kSlotBannerOffset,
      kSlotBannerOffset + kBannerLength,
      'SCOOTER_MCU_0001'.codeUnits,
    );
    _movw(bytes, 0x1000 + 0x2000, 0x150); // G3 MCU 1.5.0
    File(dumpPath).writeAsBytesSync(bytes);
    final sidecar = DumpMetadata.writeValidatedSidecar(dumpPath);

    final updated = DumpMetadata.declareMcuModel(dumpPath, sidecar, 'G3');
    expect(updated['schema'], DumpMetadata.schemaVersion);
    expect(updated['model'], 'g3');
    expect(updated['modelSource'], 'operatorDeclared');
    expect(updated['version'], '1.5.0');
    expect(updated['versionVerdict'], 'identified');

    final persisted = DumpMetadata.readJson(sidecar);
    expect(persisted, updated);
    final rows = DumpMetadata.rows(persisted);
    String value(String label) =>
        rows.firstWhere((row) => row.label == label).display(revealed: true);
    expect(value('Firmware'), 'G3 MCU 1.5.0 (identified)');
    expect(
      value('Model'),
      'G3 (operator-declared; MCU firmware does not encode it)',
    );
  });

  group('dialog rows', () {
    String value(List<InfoRow> rows, String label) =>
        rows.firstWhere((row) => row.label == label).display(revealed: true);

    test('a legacy ascii key keeps its text and renders canonical hex', () {
      // Sidecars written before the hex switch stored printable key bytes as
      // TEXT. Grouping that text read as 8 bytes for a 16-byte key and
      // uppercased it, so the value shown — and copied — was not the key on the
      // chip. New sidecars are always `keyEncoding: hex`; this is the read-back
      // path for the old ones, which must keep working.
      final rows = DumpMetadata.rows({
        'type': 'VCU',
        'backup': 'dump.bin',
        'key': 'OmZhXbB2MgUo2t3E',
        'keyEncoding': 'ascii',
        'keyState': 'other',
      });
      expect(
        value(rows, 'Key hex'),
        '4F 6D 5A 68 58 62 42 32 4D 67 55 6F 32 74 33 45',
      );
      expect(value(rows, 'Key ASCII'), 'OmZhXbB2MgUo2t3E');
    });

    test('states appear only where something was proven', () {
      final rows = DumpMetadata.rows({
        'type': 'VCU',
        'backup': 'dump.bin',
        'dumpVerdict': 'ok',
        'scooterSerial': '1K1UA2510P9900',
        'scooterSerialState':
            'real', // shape-valid only — recognised by nothing
        'key': 'aabb',
        'keyState': 'oem', // legacy sidecars remain readable
      });

      expect(rows.any((row) => row.label == 'Verdict'), isFalse);
      expect(rows.firstWhere((row) => row.label == 'Serial').state, isNull);
      expect(rows.firstWhere((row) => row.label == 'Key hex').state, isNull);
    });

    test('a matched value and an observation keep their state', () {
      final rows = DumpMetadata.rows({
        'type': 'VCU',
        'backup': 'dump.bin',
        'serialState': 'cleared',
        'key': 'fe801cb2',
        'keyState': 'defaultKey',
      });
      expect(value(rows, 'Serial'), '— (cleared)');
      expect(value(rows, 'Key hex'), 'FE 80 1C B2 (default key)');
    });

    test('XTEA renders as ASCII and hex, or as an explicit absent state', () {
      final present = DumpMetadata.rows({
        'type': 'VCU',
        'backup': 'dump.bin',
        'xtea': '58746561313233344b65793536373839',
        'xteaEncoding': 'hex',
        'xteaState': 'asciiAlphanumeric',
      });
      expect(value(present, 'XTEA ASCII'), 'Xtea1234Key56789');
      expect(
        value(present, 'XTEA hex'),
        '58 74 65 61 31 32 33 34 4B 65 79 35 36 37 38 39',
      );

      final absent = DumpMetadata.rows({
        'type': 'VCU',
        'backup': 'dump.bin',
        'xtea': null,
        'xteaEncoding': 'hex',
        'xteaState': 'notDetected',
      });
      expect(value(absent, 'XTEA'), '— (not detected)');
    });

    test('MCU rows keep SN/MN out of the Serial label but do show it', () {
      final rows = DumpMetadata.rows({
        'type': 'MCU',
        'backup': 'dump.bin',
        'scooterSerial': null,
        'controllerSnMn': 'Z025XXXXXXXXXXXX',
        'controllerSnMnState': 'matched',
      });

      expect(rows.any((row) => row.label == 'Serial'), isFalse);
      expect(rows.any((row) => row.label == 'Part Number'), isFalse);
      final snMn = rows.firstWhere((row) => row.label == 'SN/MN');
      expect(snMn.display(revealed: true), 'Z025XXXXXXXXXXXX (matched)');
      expect(snMn.secret, isTrue);
    });

    test(
      'a matched SN/MN is stated in the modal even though the JSON omits it',
      () {
        final rows = DumpMetadata.rows({
          'type': 'MCU',
          'backup': 'dump.bin',
          'controllerSnMn': 'Z025XXXXXXXXXXXX',
        });

        expect(rows.firstWhere((row) => row.label == 'SN/MN').state, 'matched');
      },
    );

    test('a sidecar written before SN/MN was recorded says so', () {
      final rows = DumpMetadata.rows({'type': 'MCU', 'backup': 'dump.bin'});

      final snMn = rows.firstWhere((row) => row.label == 'SN/MN');
      expect(snMn.display(revealed: true), '— (not recorded)');
    });

    test('a VCU gets its own board SN/MN row alongside the scooter serial', () {
      final rows = DumpMetadata.rows({
        'type': 'VCU',
        'backup': 'dump.bin',
        'scooterSerial': '1EFE0000000001',
        'controllerSnMn': 'Z03BXXXXXXXXXXXX',
      });

      expect(rows.any((row) => row.label == 'Serial'), isTrue);
      expect(
        rows.firstWhere((row) => row.label == 'SN/MN').display(revealed: true),
        'Z03BXXXXXXXXXXXX (matched)',
      );
    });

    test('a genericized SN/MN is shown but never read as the sticker', () {
      final rows = DumpMetadata.rows({
        'type': 'VCU',
        'backup': 'dump.bin',
        'controllerSnMn': 'Z03B000000000001',
        'controllerSnMnState': 'generic',
      });

      expect(
        rows.firstWhere((row) => row.label == 'SN/MN').display(revealed: true),
        'Z03B000000000001 (factory-generic)',
      );
    });
  });
}
