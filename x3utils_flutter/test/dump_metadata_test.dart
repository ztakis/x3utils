import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:x3utils_flutter/engine/device_spec.dart';
import 'package:x3utils_flutter/engine/dump_metadata.dart';
import 'package:x3utils_flutter/engine/firmware.dart';

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

    expect(info['schema'], 1);
    expect(info['ts'], '2026-08-09T02:06:52');
    expect(info['backup'], 'dump_2026-08-09_02-06-52.bin');
    expect(info['type'], 'VCU');
    expect(info['model'], 'g3');
    expect(info['version'], '1.6.1');
    expect(info['versionVerdict'], 'identified');
    expect(info['serial'], serial);
    expect(info['serialState'], 'real');
    expect(info['uid'], 'C49B0DB900002193A70705E8');
    expect(info['uidState'], 'matched');
    expect(info['key'], '7aoymhtysf886lb6');
    expect(info['keyEncoding'], 'ascii');
    expect(info['keyState'], 'oem');
    expect(info['rand'], 'ffffffffffff');
    expect(info['zpEncLen'], 59032);
    expect(info['zpPayloadLen'], 59028);
    expect(info['zpState'], 'readable');
    expect(info['dumpVerdict'], 'ok');
  });

  test('does not infer an MCU model and records conflicting UID copies', () {
    final bytes = _dump('SCOOTER_MCU_0001');
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
}
