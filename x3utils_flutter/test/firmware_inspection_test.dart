import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:x3utils_flutter/engine/device_spec.dart';
import 'package:x3utils_flutter/engine/firmware.dart';
import 'package:x3utils_flutter/engine/firmware_inspection.dart';
import 'package:x3utils_flutter/engine/zp_extract.dart';

void main() {
  group('firmware inspection report', () {
    test('reports supported full-image evidence without certifying it', () {
      final image = _fullImage(
        banner: 'SCOOTER_VCU_xxU2',
        serial: '1K1EA2510P1673',
        zpPayloadLength: 51204,
      );

      final report = FirmwareInspector.inspect(image, slotBin: false);

      expect(report.identity.bannerSupported, isTrue);
      expect(report.bannerValue, contains('ZT3 · VCU'));
      expect(report.serialValue, contains('prefix suggests ZT3'));
      expect(report.zp.state, ZpRecordState.readable);
      expect(report.zp.payloadLength, 51204);
      expect(report.zpDetail, 'Record freshness cannot be determined.');
      expect(report.findings, isEmpty);
    });

    test('bannerless identity bytes are not classified as a serial', () {
      final report = FirmwareInspector.inspect(
        _fullImage(serial: '1K1E0000000001'),
        slotBin: false,
      );

      expect(
        report.findings.map((finding) => finding.code),
        containsAll(['banner_missing', 'zp_unavailable']),
      );
      expect(
        report.findings.map((finding) => finding.code),
        isNot(contains('serial_generic')),
      );
      expect(
        report.findings
            .singleWhere((finding) => finding.code == 'banner_missing')
            .message,
        'x3utils cannot identify this file as VCU or MCU firmware.',
      );
      expect(report.findings, hasLength(2));
      expect(report.zp.state, ZpRecordState.unavailable);
      expect(report.zpValue, contains('No trustworthy'));
    });

    test('unreadable serial on an identified VCU is a finding', () {
      final report = FirmwareInspector.inspect(
        _fullImage(banner: 'SCOOTER_VCU_xxU2'),
        slotBin: false,
      );

      expect(
        report.findings.map((finding) => finding.code),
        containsAll(['serial_unreadable', 'zp_unavailable']),
      );
      expect(
        report.findings.map((finding) => finding.code),
        isNot(contains('banner_missing')),
      );
      expect(report.findings, hasLength(2));
    });

    test('collects package allow-list and payload mismatch findings', () {
      final report = FirmwareInspector.inspect(
        _slotImage(banner: 'SCOOTER_VCU_xxU2'),
        slotBin: true,
        packageClaim: const PackageClaim(model: 'other', type: 'VCU'),
      );

      expect(
        report.findings.map((finding) => finding.code),
        containsAll([
          'package_identity_unsupported',
          'package_payload_mismatch',
        ]),
      );
      expect(
        report.findings
            .singleWhere(
              (finding) => finding.code == 'package_identity_unsupported',
            )
            .message,
        'This package is for OTHER. '
        'x3utils supports ZT3, G3, GT3, and F3 only.',
      );
      expect(
        report.findings
            .singleWhere(
              (finding) => finding.code == 'package_payload_mismatch',
            )
            .message,
        'The JSON says OTHER VCU, but the firmware banner says ZT3 VCU.',
      );
      expect(report.packageClaim!.label, 'OTHER · VCU');
      expect(report.serialValue, 'Not present in a slot image');
      expect(report.zp.state, ZpRecordState.notApplicable);
    });

    test('bannerless slot evidence stays observable and non-throwing', () {
      final report = FirmwareInspector.inspect(_slotImage(), slotBin: true);

      expect(report.bannerValue, 'Not found');
      expect(report.findings.single.code, 'banner_missing');
      expect(report.zpValue, 'Not present in a slot image');
    });

    test('conflicting ZP evidence uses simple wording', () {
      final image = _fullImage(
        banner: 'SCOOTER_VCU_xxU2',
        serial: '1K1EA2510P1673',
      );
      _writeZpRecord(image, 0x1F100, 51204);
      _writeZpRecord(image, 0x1F300, 52004);

      final report = FirmwareInspector.inspect(image, slotBin: false);

      expect(report.zpValue, 'Conflicting firmware-size records');
      expect(report.findings.single.code, 'zp_conflicting');
      expect(
        report.findings.single.message,
        'The file contains conflicting firmware-size records.',
      );
    });
  });

  group('non-throwing ZP inspection', () {
    test('preserves payloadFromDump hard-stop behavior', () {
      final image = _fullImage();

      expect(Zp.inspect(image).state, ZpRecordState.unavailable);
      expect(
        () => Zp.payloadFromDump(image),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('no trustworthy BLE firmware-length record'),
          ),
        ),
      );
    });
  });
}

Uint8List _slotImage({String? banner}) {
  final bytes = Uint8List.fromList(
    List<int>.generate(Firmware.slot0MinBytes, (index) => index & 0xff),
  );
  if (banner != null) {
    bytes.setRange(0x400, 0x410, ascii.encode(banner));
  }
  return bytes;
}

Uint8List _fullImage({String? banner, String? serial, int? zpPayloadLength}) {
  final bytes = Uint8List.fromList(
    List<int>.generate(Firmware.expectedSize, (index) => index & 0xff),
  );
  if (banner != null) {
    bytes.setRange(0x1400, 0x1410, ascii.encode(banner));
  }
  if (serial != null) {
    bytes
      ..setRange(
        kSerialOffset,
        kSerialOffset + kSerialLength,
        ascii.encode(serial),
      )
      ..setRange(
        kSerialBackupOffset,
        kSerialBackupOffset + kSerialLength,
        ascii.encode(serial),
      );
  }
  if (zpPayloadLength != null) {
    const offset = 0x1F800;
    final encryptedLength = zpPayloadLength + 4;
    bytes
      ..[offset] = 0x5A
      ..[offset + 1] = 0x50
      ..fillRange(offset + 2, offset + 8, 0)
      ..[offset + 8] = encryptedLength & 0xff
      ..[offset + 9] = (encryptedLength >> 8) & 0xff
      ..[offset + 10] = (encryptedLength >> 16) & 0xff
      ..[offset + 11] = (encryptedLength >> 24) & 0xff;
  }
  return bytes;
}

void _writeZpRecord(Uint8List bytes, int offset, int payloadLength) {
  final encryptedLength = payloadLength + 4;
  bytes
    ..[offset] = 0x5A
    ..[offset + 1] = 0x50
    ..fillRange(offset + 2, offset + 8, 0)
    ..[offset + 8] = encryptedLength & 0xff
    ..[offset + 9] = (encryptedLength >> 8) & 0xff
    ..[offset + 10] = (encryptedLength >> 16) & 0xff
    ..[offset + 11] = (encryptedLength >> 24) & 0xff;
}
