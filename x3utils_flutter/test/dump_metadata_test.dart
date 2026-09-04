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
    const serial = '1CGCC9926C8115';
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
    expect(info.containsKey('controllerSnMn'), isFalse);
    expect(info.containsKey('serial'), isFalse);
    expect(info['uid'], 'C49B0DB900002193A70705E8');
    expect(info['uidState'], 'matched');
    // Hex even though these 16 bytes are printable ASCII ('7aoymhtysf886lb6').
    // keyState still reports 'oem', which is what printability was signalling.
    expect(info['key'], '37616f796d68747973663838366c6236');
    expect(info['keyEncoding'], 'hex');
    expect(info['keyState'], 'oem');
    expect(info['rand'], 'ffffffffffff');
    expect(info['zpEncLen'], 59032);
    expect(info['zpPayloadLen'], 59028);
    expect(info['zpState'], 'readable');
    expect(info['dumpVerdict'], 'ok');
  });

  test('does not infer an MCU model and records conflicting UID copies', () {
    final bytes = _dump('SCOOTER_MCU_0001');
    const controllerSnMn = 'Z025B4G25BM30168';
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
    // controllerSnMn is intentionally not emitted (dropped as low-value).
    expect(info.containsKey('controllerSnMn'), isFalse);
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
    File(dumpPath).writeAsBytesSync(_dump('SCOOTER_VCU_xxG3'));

    final sidecar = DumpMetadata.writeValidatedSidecar(dumpPath);
    final json =
        jsonDecode(File(sidecar).readAsStringSync()) as Map<String, dynamic>;

    expect(sidecar, p.join(dir.path, 'dump_2026-08-09_02-06-52.json'));
    expect(json['backup'], p.basename(dumpPath));
    expect(json['dumpVerdict'], 'ok');
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

    test('a legacy ascii key is rendered as hex, with its case recoverable', () {
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
        value(rows, 'Key'),
        '4F 6D 5A 68 58 62 42 32 4D 67 55 6F 32 74 33 45',
      );
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
        'keyState': 'oem', // not the default key, and that is all we know
      });

      expect(rows.any((row) => row.label == 'Verdict'), isFalse);
      expect(rows.firstWhere((row) => row.label == 'Serial').state, isNull);
      expect(rows.firstWhere((row) => row.label == 'Key').state, isNull);
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
      expect(value(rows, 'Key'), 'FE 80 1C B2 (default key)');
    });

    test('MCU rows hide both scooter serial and controller SN/MN', () {
      final rows = DumpMetadata.rows({
        'type': 'MCU',
        'backup': 'dump.bin',
        'scooterSerial': null,
        'controllerSnMn': 'Z025B4G25BM30168',
        'controllerSnMnState': 'matched',
      });

      expect(rows.any((row) => row.label == 'Serial'), isFalse);
      expect(rows.any((row) => row.label == 'SN/MN'), isFalse);
      expect(rows.any((row) => row.label == 'Part Number'), isFalse);
    });
  });
}
