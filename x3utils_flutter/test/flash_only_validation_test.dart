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
import 'package:x3utils_flutter/engine/openocd_paths.dart';
import 'package:x3utils_flutter/engine/openocd_runner.dart';
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

    test('guarded slot import rejects unsupported banner codes', () {
      for (final banner in ['SCOOTER_VCU_ZZZZ', 'SCOOTER_MCU_9999']) {
        final zip = _zip3(
          _payloadWithBanner(banner),
          model: 'zt3',
          type: banner.contains('_MCU_') ? 'MCU' : 'VCU',
        );
        expect(
          () => PackV3.unpackV3(zip),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('Unsupported firmware banner'),
            ),
          ),
          reason: banner,
        );
      }
    });

    test('Flash Only keeps unsupported banner codes informational', () {
      final zip = _zip3(
        _payloadWithBanner('SCOOTER_VCU_ZZZZ'),
        model: 'zt3',
        type: 'VCU',
      );

      final unpacked = PackV3.unpackV3(zip, enforceDeviceIdentity: false);
      expect(unpacked.type, 'VCU');
    });

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

  test('idle hero presents the selected firmware identity', () {
    SharedPreferences.setMockInitialValues({});
    final controller = AppController();
    addTearDown(controller.dispose);

    controller.selectAction('make_zip3');
    controller.setFirmware(
      'dump.bin',
      note: 'Firmware says: G3 · VCU',
      warn: true,
    );

    expect(controller.heroTitle, 'Complete package identity');
    expect(controller.heroMessage, 'Firmware says: G3 · VCU');
    expect(controller.heroMessageWarn, isTrue);

    controller.setZip3Type('VCU');
    controller.setZip3Model('g3');
    expect(controller.heroTitle, 'Ready to start');
    expect(controller.heroMessage, 'Firmware says: G3 · VCU');
  });

  test('input failure returns to setup instead of rerunning', () async {
    SharedPreferences.setMockInitialValues({});
    final temp = Directory.systemTemp.createTempSync('x3utils_retry_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final dump = File(p.join(temp.path, 'invalid_dump.bin'))
      ..writeAsBytesSync(
        Uint8List.fromList(
          List<int>.generate(Firmware.expectedSize, (i) => i & 0xff),
        ),
      );
    final controller = AppController();
    addTearDown(controller.dispose);

    controller.selectAction('make_zip3');
    controller.setFirmware(dump.path);
    controller.setZip3Type('VCU');
    controller.setZip3Model('g3');

    await controller.start();
    expect(controller.stage, StageState.fail);
    expect(controller.failureNeedsInput, isTrue);
    expect(controller.failurePrimaryLabel, 'Change input');

    await controller.retry();
    expect(controller.stage, StageState.idle);
    expect(controller.failureNeedsInput, isFalse);
  });

  test('guarded flash rejects a file changed after selection', () async {
    SharedPreferences.setMockInitialValues({});
    final temp = Directory.systemTemp.createTempSync('x3utils_changed_fw_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final bytes = Uint8List.fromList(
      List<int>.generate(Firmware.expectedSize, (i) => i & 0xff),
    );
    const banner = 'SCOOTER_VCU_xxG3';
    bytes.setRange(0x1400, 0x1400 + banner.length, banner.codeUnits);
    final firmware = File(p.join(temp.path, 'firmware.bin'))
      ..writeAsBytesSync(bytes);
    final inertRunner = OpenOcdRunner(
      OpenOcdPaths('/not-a-real-openocd', '/not-a-real-scripts'),
    );
    final controller = AppController(runner: inertRunner);
    addTearDown(controller.dispose);

    controller.selectAction('flash_backup');
    expect(controller.selectFirmwareBin(firmware.path).ok, isTrue);

    bytes[0x2000] ^= 0x01;
    firmware.writeAsBytesSync(bytes);
    await controller.start();

    expect(controller.stage, StageState.fail);
    expect(controller.failureNeedsInput, isTrue);
    expect(controller.failurePrimaryLabel, 'Change firmware');
    expect(controller.heroMessage, contains('changed on disk'));
    expect(
      controller.console.any((line) => line.contains('> openocd')),
      isFalse,
    );
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
