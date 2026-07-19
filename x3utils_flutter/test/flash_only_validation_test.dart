import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:x3utils_flutter/app_controller.dart';
import 'package:x3utils_flutter/engine/firmware.dart';
import 'package:x3utils_flutter/engine/ninebot_tea.dart';
import 'package:x3utils_flutter/engine/pack_zip3.dart';
import 'package:x3utils_flutter/models.dart';

void main() {
  group('firmware source size gates', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('x3utils_fw_'));
    tearDown(() => temp.deleteSync(recursive: true));

    File firmwareFile(String name, int length) => File(p.join(temp.path, name))
      ..writeAsBytesSync(
        Uint8List.fromList(List<int>.generate(length, (i) => i & 0xff)),
      );

    test('full image remains exactly 128 KB', () {
      expect(
        Firmware.validate(
          firmwareFile('full.bin', Firmware.expectedSize).path,
        ).ok,
        isTrue,
      );
      expect(
        Firmware.validate(
          firmwareFile('short.bin', Firmware.expectedSize - 1).path,
        ).ok,
        isFalse,
      );
    });

    test('slot image accepts only the configured inclusive window', () {
      expect(
        Firmware.validateSlot(
          firmwareFile('min.bin', Firmware.slot0MinBytes).path,
        ).ok,
        isTrue,
      );
      expect(
        Firmware.validateSlot(
          firmwareFile('max.bin', Firmware.slot0MaxBytes).path,
        ).ok,
        isTrue,
      );
      expect(
        Firmware.validateSlot(
          firmwareFile('too-small.bin', Firmware.slot0MinBytes - 1).path,
        ).ok,
        isFalse,
      );
      expect(
        Firmware.validateSlot(
          firmwareFile('too-big.bin', Firmware.slot0MaxBytes + 1).path,
        ).ok,
        isFalse,
      );
    });

    test('ZIP3 container is rejected before reading above 70 KiB', () {
      final atLimit = File(p.join(temp.path, 'limit.zip'))
        ..writeAsBytesSync(Uint8List(Firmware.maxZip3Bytes));
      final aboveLimit = File(p.join(temp.path, 'large.zip'))
        ..writeAsBytesSync(Uint8List(Firmware.maxZip3Bytes + 1));

      expect(Firmware.validateZip3Container(atLimit.path).ok, isTrue);
      final rejected = Firmware.validateZip3Container(aboveLimit.path);
      expect(rejected.ok, isFalse);
      expect(rejected.message, contains('too large'));
    });
  });

  group('ZIP3 identity policy', () {
    test('Flash Only accepts informational model and banner mismatch', () {
      final payload = _payloadWithBanner('SCOOTER_MCU_0001');
      final zip = _zip3(payload, model: 'other', type: 'VCU');

      final unpacked = PackV3.unpackV3(zip, enforceDeviceIdentity: false);

      expect(unpacked.model, 'other');
      expect(unpacked.type, 'VCU');
      expect(unpacked.firmware.sublist(0, payload.length), payload);
    });

    test('guarded slot import still rejects unsupported model', () {
      final zip = _zip3(
        _payloadWithBanner('SCOOTER_VCU_xxU2'),
        model: 'other',
        type: 'VCU',
      );

      expect(
        () => PackV3.unpackV3(zip),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Unsupported model'),
          ),
        ),
      );
    });

    test('BLE and BMS reject even when device identity is informational', () {
      for (final type in ['BLE', 'BMS']) {
        final zip = _zip3(
          _payloadWithBanner('SCOOTER_MCU_0001'),
          model: 'zt3',
          type: type,
        );
        expect(
          () => PackV3.unpackV3(zip, enforceDeviceIdentity: false),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('VCU/MCU'),
            ),
          ),
          reason: type,
        );
      }
    });

    test(
      'guarded slot import still accepts a consistent supported package',
      () {
        final zip = _zip3(
          _payloadWithBanner('SCOOTER_VCU_xxU2'),
          model: 'zt3',
          type: 'VCU',
        );

        final unpacked = PackV3.unpackV3(zip);
        expect(unpacked.model, 'zt3');
        expect(unpacked.type, 'VCU');
      },
    );

    test('MD5 integrity remains mandatory in Flash Only', () {
      final zip = _zip3(
        _payloadWithBanner('SCOOTER_VCU_xxU2'),
        model: 'zt3',
        type: 'VCU',
        md5Override: '00000000000000000000000000000000',
      );

      expect(
        () => PackV3.unpackV3(zip, enforceDeviceIdentity: false),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('MD5'),
          ),
        ),
      );
    });
  });

  test('Flash Only scope defaults to full and clears firmware on change', () {
    SharedPreferences.setMockInitialValues({});
    final controller = AppController();
    addTearDown(controller.dispose);

    controller.selectAction('flash_only');
    expect(controller.flashOnlyScope, FlashOnlyScope.fullImage);
    expect(controller.isSlotAction, isFalse);

    controller.setFirmware('selected.bin');
    controller.setFlashOnlyScope(FlashOnlyScope.slot0);
    expect(controller.isSlotAction, isTrue);
    expect(controller.firmwarePath, isNull);
  });
}

Uint8List _payloadWithBanner(String banner) {
  final bytes = Uint8List.fromList(
    List<int>.generate(Firmware.slot0MinBytes, (i) => i & 0xff),
  );
  bytes.setRange(0x400, 0x410, ascii.encode(banner));
  return bytes;
}

Uint8List _zip3(
  Uint8List payload, {
  required String model,
  required String type,
  String? md5Override,
}) {
  final encrypted = NinebotTea().encrypt(payload);
  final info = <String, dynamic>{
    'schemaVersion': 1,
    'firmware': <String, dynamic>{
      'displayName': 'test package',
      'model': model,
      'type': type,
      'md5': <String, String>{'enc': md5Override ?? PackV3.md5Hex(encrypted)},
    },
  };
  final archive = Archive()
    ..add(ArchiveFile.bytes('FIRM.bin.enc', encrypted))
    ..add(ArchiveFile.string('info.json', jsonEncode(info)));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
