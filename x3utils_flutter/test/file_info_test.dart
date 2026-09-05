import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:x3utils_flutter/engine/device_spec.dart';
import 'package:x3utils_flutter/engine/file_info.dart';
import 'package:x3utils_flutter/engine/firmware.dart';
import 'package:x3utils_flutter/engine/info_row.dart';
import 'package:x3utils_flutter/engine/pack_zip3.dart';

/// A varied 128 KB image so `inspectDump` cannot call it a single-repeated-byte
/// read, with a banner at the full-image offset.
List<int> _fullImage(String banner) {
  final bytes = List<int>.generate(131072, (i) => i % 251);
  bytes.setRange(
    kSlotBannerOffset,
    kSlotBannerOffset + kBannerLength,
    banner.codeUnits,
  );
  return bytes;
}

/// A slot payload: the banner sits at the slot offset, not the full-image one.
List<int> _slotPayload(String banner, {int length = 58460}) {
  final bytes = List<int>.generate(length, (i) => (i * 7) % 251);
  bytes.setRange(
    kBannerOffset,
    kBannerOffset + kBannerLength,
    banner.codeUnits,
  );
  return bytes;
}

/// MOVW Rd,#imm16 for an immediate that fits in 12 bits.
List<int> _movw(int imm, {int rd = 0}) {
  final i = (imm >> 11) & 1;
  final imm3 = (imm >> 8) & 7;
  final imm8 = imm & 0xFF;
  final hw1 = 0xF240 | (i << 10);
  final hw2 = (imm3 << 12) | (rd << 8) | imm8;
  return [hw1 & 0xFF, hw1 >> 8, hw2 & 0xFF, hw2 >> 8];
}

String _value(List<InfoRow> rows, String label) =>
    rows.firstWhere((row) => row.label == label).display(revealed: true);

bool _has(List<InfoRow> rows, String label) =>
    rows.any((row) => row.label == label);

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('x3utils_file_info_'));
  tearDown(() => dir.deleteSync(recursive: true));

  File write(String name, List<int> bytes) =>
      File(p.join(dir.path, name))..writeAsBytesSync(bytes);

  group('full image', () {
    test('is described with the same rows as a backup sidecar', () {
      final file = write('picked.bin', _fullImage('SCOOTER_VCU_xxG3'));
      final report = FileInfo.describe(file.path);

      expect(report.title, 'File info');
      expect(report.message, isNull);
      // The first row is labelled for a picked file, not for a backup.
      expect(_value(report.rows, 'File'), 'picked.bin');
      expect(_value(report.rows, 'Read'), 'Readable firmware image');
      expect(_value(report.rows, 'Firmware'), startsWith('G3 VCU'));
      // Identity rows are present and marked secret so the view masks them.
      for (final label in ['Serial', 'UID', 'Key hex', 'Rand']) {
        expect(_has(report.rows, label), isTrue, reason: label);
        expect(
          report.rows.firstWhere((row) => row.label == label).secret,
          isTrue,
          reason: label,
        );
      }
    });

    test('an all-zeros image is NOT reported as an ok dump', () {
      // The sidecar's hardcoded `ok` describes a dump that was already
      // validated. A picked file has not been, and a readout-protected image
      // must not be described as a good one.
      final file = write('masked.bin', List<int>.filled(131072, 0));
      expect(
        _value(FileInfo.describe(file.path).rows, 'Read'),
        contains('All zeros'),
      );
    });

    test(
      'an ASCII-alphanumeric key is shown as both text and 16 hex bytes',
      () {
        final bytes = _fullImage('SCOOTER_VCU_xxU2');
        bytes.setRange(0x1420, 0x1430, 'OmZhXbB2MgUo2t3E'.codeUnits);
        bytes.setRange(0x1430, 0x1436, [0x34, 0x71, 0x7A, 0x6A, 0x73, 0x6E]);
        final rows = FileInfo.describe(write('oemkey.bin', bytes).path).rows;

        expect(
          _value(rows, 'Key hex'),
          '4F 6D 5A 68 58 62 42 32 4D 67 55 6F 32 74 33 45',
        );
        expect(_value(rows, 'Key ASCII'), 'OmZhXbB2MgUo2t3E');
        expect(_value(rows, 'Rand'), '34 71 7A 6A 73 6E');
        // 16 bytes must read as 16 groups, whatever the bytes happen to be.
        expect(_value(rows, 'Key hex').split(' ').length, 16);
      },
    );

    test('an unrecognised serial and key claim nothing', () {
      // Failing to match a known value is not a finding. `real` would claim
      // the serial was checked against something, and `oem`/`other` would
      // dress up an unrecognised key as an identification. Both stay silent;
      // only the value is shown.
      final bytes = _fullImage('SCOOTER_VCU_xxU2');
      bytes.setRange(
        kSerialOffset,
        kSerialOffset + 14,
        '1K1UA000000000'.codeUnits,
      );
      bytes.setRange(0x1420, 0x1430, List<int>.generate(16, (i) => 0x40 + i));
      final rows = FileInfo.describe(write('unknown.bin', bytes).path).rows;

      expect(_value(rows, 'Serial'), '1K1UA000000000');
      expect(rows.firstWhere((row) => row.label == 'Serial').state, isNull);
      expect(_has(rows, 'Key ASCII'), isFalse);
      expect(rows.firstWhere((row) => row.label == 'Key hex').state, isNull);
      expect(_value(rows, 'Serial'), isNot(contains('real')));
    });

    test('an erased image reads as blank', () {
      final file = write('blank.bin', List<int>.filled(131072, 0xFF));
      expect(
        _value(FileInfo.describe(file.path).rows, 'Read'),
        contains('All 0xFF'),
      );
    });

    test('an MCU at 0x1400 requests and labels a model declaration', () {
      // Slot 0 begins at 0x1000 in a full dump, so its MCU banner is at
      // 0x1400. The version immediate is likewise written slot-relative.
      final bytes = List<int>.filled(Firmware.expectedSize, 0);
      bytes.setRange(
        kSlotBannerOffset,
        kSlotBannerOffset + kBannerLength,
        'SCOOTER_MCU_0001'.codeUnits,
      );
      bytes.setRange(0x1000 + 0x2000, 0x1000 + 0x2004, _movw(0x150));
      final file = write('mcu_full.bin', bytes);

      final initial = FileInfo.inspect(file.path);
      expect(initial.needsMcuModel, isTrue);
      expect(_value(initial.report.rows, 'Firmware'), startsWith('MCU'));
      expect(_has(initial.report.rows, 'Model'), isFalse);
      expect(_has(initial.report.rows, 'Serial'), isFalse);
      expect(_has(initial.report.rows, 'Part Number'), isFalse);
      // The fixture is all zeros at the identity page, so the row is present
      // and explicitly blank rather than silently missing.
      expect(
        initial.report.rows
            .firstWhere((row) => row.label == 'SN/MN')
            .display(revealed: true),
        '— (blank)',
      );

      final declared = FileInfo.inspect(file.path, declaredMcuModel: 'g3');
      expect(declared.needsMcuModel, isFalse);
      expect(_value(declared.report.rows, 'Firmware'), startsWith('MCU 1.5.0'));
      expect(_value(declared.report.rows, 'Model'), startsWith('G3'));
      expect(_has(declared.report.rows, 'Serial'), isFalse);
      expect(
        declared.report.rows.firstWhere((row) => row.label == 'Model').state,
        contains('operator-declared'),
      );
    });
  });

  group('slot payload', () {
    test('is named as a slot payload and identified from its banner', () {
      final file = write('slot.bin', _slotPayload('SCOOTER_VCU_xxU2'));
      final report = FileInfo.describe(file.path);

      expect(_value(report.rows, 'File'), 'slot.bin');
      expect(
        _value(report.rows, 'Size'),
        '58460 bytes (not a full 131072-byte image)',
      );
      expect(_value(report.rows, 'Firmware'), startsWith('ZT3 VCU'));
      expect(_value(report.rows, 'Banner'), contains('SCOOTER_VCU_xxU2'));
      // Serial, UID and ZP live outside slot 0 (0x1F020 / 0x1F1B4 / 0x1F800).
      // They are omitted rather than reported as absent, so nothing here can
      // be mistaken for a fact about the device. Key and rand are NOT in that
      // list — see the key-region test below.
      for (final label in ['Serial', 'UID', 'ZP']) {
        expect(_has(report.rows, label), isFalse, reason: label);
      }
    });

    test('the key region travels with the payload, VCU and MCU alike', () {
      // Slot 0 starts at 0x1000, so the full-image key at 0x1420 is at 0x420
      // of a payload — inside it, unlike serial/UID/ZP. A compat-patched
      // payload must therefore be recognisable from the file alone.
      for (final banner in ['SCOOTER_VCU_xxG3', 'SCOOTER_MCU_0001']) {
        final payload = _slotPayload(banner);
        payload.setRange(0x420, 0x420 + 16, CompatPatch.signature);
        payload.setRange(0x430, 0x436, [1, 2, 3, 4, 5, 6]);
        final rows = FileInfo.describe(
          write('compat_$banner.bin', payload).path,
        ).rows;

        expect(
          _value(rows, 'Key hex'),
          endsWith('(default key)'),
          reason: banner,
        );
        expect(_value(rows, 'Rand'), '01 02 03 04 05 06', reason: banner);
        // Identity material: masked until revealed, but the state that
        // answers "is this patched?" stays readable.
        final key = rows.firstWhere((row) => row.label == 'Key hex');
        expect(key.secret, isTrue);
        expect(key.display(revealed: false), endsWith('(default key)'));
        expect(key.display(revealed: false), isNot(contains('FE')));
      }
    });

    test('an unpatched payload is not called patched', () {
      final payload = _slotPayload('SCOOTER_VCU_xxG3');
      payload.setRange(0x420, 0x420 + 16, List<int>.filled(16, 0xFF));
      final rows = FileInfo.describe(write('blank_key.bin', payload).path).rows;
      expect(_value(rows, 'Key hex'), endsWith('(blank)'));
    });

    test('an unidentified file gets no key row at all', () {
      // Without a banner there is nothing to say 0x420 is the key region.
      final rows = FileInfo.describe(
        write('noise2.bin', List<int>.generate(4096, (i) => i % 251)).path,
      ).rows;
      expect(_has(rows, 'Key ASCII'), isFalse);
      expect(_has(rows, 'Key hex'), isFalse);
      expect(_has(rows, 'Rand'), isFalse);
    });

    test('XTEA uses the shifted payload offset and shows both forms', () {
      final payload = _slotPayload('SCOOTER_VCU_xxU2');
      payload.setRange(0x440, 0x450, 'Xtea1234Key56789'.codeUnits);
      final rows = FileInfo.describe(write('xtea.bin', payload).path).rows;

      expect(_value(rows, 'XTEA ASCII'), 'Xtea1234Key56789');
      expect(
        _value(rows, 'XTEA hex'),
        '58 74 65 61 31 32 33 34 4B 65 79 35 36 37 38 39',
      );
    });

    test('a bin with no readable banner still describes, and says so', () {
      final file = write('noise.bin', List<int>.generate(4096, (i) => i % 251));
      final report = FileInfo.describe(file.path);

      expect(report.message, isNull);
      expect(_value(report.rows, 'Firmware'), startsWith('—'));
      expect(_value(report.rows, 'Banner'), 'Not found');
      expect(_value(report.rows, 'Notes'), contains('cannot identify'));
    });

    test('an MCU payload at 0x400 requests a model declaration', () {
      final report = FileInfo.inspect(
        write('mcu_slot.bin', _slotPayload('SCOOTER_MCU_0001')).path,
      );
      expect(report.needsMcuModel, isTrue);
    });
  });

  group('zip3 package', () {
    test('a real rev2 package reports its metadata and payload', () {
      final built = PackV3.buildZip3FromPayload(
        _slotPayload('SCOOTER_VCU_xxG3'),
        type: 'VCU',
        model: 'g3',
        enforceModel: false,
        displayName: 'g3 VCU test',
      );
      final file = write('pkg.zip', built.zipBytes);
      final report = FileInfo.describe(file.path);

      expect(report.title, 'Package info');
      expect(_value(report.rows, 'Package'), startsWith('zip 3.2'));
      expect(_value(report.rows, 'Declared'), startsWith('G3 · VCU'));
      expect(_value(report.rows, 'Payload'), '58460 bytes');
      expect(_value(report.rows, 'Integrity'), 'MD5 matches the package');
      expect(_value(report.rows, 'Banner'), contains('SCOOTER_VCU_xxG3'));
    });

    test('an unreadable package reports why, and lists no rows', () {
      final file = write('broken.zip', List<int>.filled(512, 0x41));
      final report = FileInfo.describe(file.path);

      expect(report.rows, isEmpty);
      expect(report.message, contains('could not be opened'));
    });
  });

  group('refusals', () {
    test('a missing file', () {
      final report = FileInfo.describe(p.join(dir.path, 'gone.bin'));
      expect(report.message, contains('no longer exists'));
    });

    test('an unsupported extension', () {
      final file = write('notes.txt', 'hello'.codeUnits);
      expect(FileInfo.describe(file.path).message, contains('Only firmware'));
    });

    test('a file past the size limit', () {
      final file = write(
        'huge.bin',
        List<int>.filled(FileInfo.maxBinBytes + 1, 0),
      );
      expect(FileInfo.describe(file.path).message, contains('past the'));
    });
  });

  group('row formatting', () {
    test('a secret row masks its value but never its state', () {
      const row = InfoRow(
        'Serial',
        '1CGCXXXXXXXXXX',
        state: 'real',
        secret: true,
      );
      expect(row.display(revealed: false), '•••••••••••••• (real)');
      expect(row.display(revealed: true), '1CGCXXXXXXXXXX (real)');
    });

    test('an absent value is never masked', () {
      const row = InfoRow('Serial', '—', state: 'unavailable', secret: true);
      expect(row.hasSecret, isFalse);
      expect(row.display(revealed: false), '— (unavailable)');
    });

    test('grouping is uppercase and fixed width', () {
      expect(infoGrouped('fe801cb2', 2), 'FE 80 1C B2');
      expect(infoGrouped('C49B0DB9', 4), 'C49B 0DB9');
      expect(infoGrouped(null, 4), '—');
    });

    test('plainLine pads the label for Copy all', () {
      const row = InfoRow('ZP', '59028 payload', state: 'readable');
      expect(row.plainLine(10), 'ZP        59028 payload (readable)');
    });
  });
}
