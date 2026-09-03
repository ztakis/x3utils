import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:x3utils_flutter/engine/sram_identity.dart';

void _putTable(
  Uint8List bytes,
  int offset, {
  required String type,
  required int version,
  required String identity,
}) {
  final vcu = type == 'VCU';
  bytes[offset] = 0x5c;
  bytes[offset + 1] = vcu ? 0x50 : 0x51;
  bytes.setRange(
    offset + 0x20,
    offset + 0x20 + identity.length,
    identity.codeUnits,
  );
  final versionOffset = offset + (vcu ? 0x2e : 0x32);
  bytes[versionOffset] = version & 0xff;
  bytes[versionOffset + 1] = version >> 8;
}

void main() {
  test('identifies matching VCU tables, serial model, region and version', () {
    final bytes = Uint8List(kAt32f415SramLength);
    for (final offset in [0x120, 0x5100]) {
      _putTable(
        bytes,
        offset,
        type: 'VCU',
        version: 0x61,
        identity: '1CGC1234567890',
      );
    }

    final result = SramIdentityParser.parse(bytes);

    expect(result.verdict, SramIdentityVerdict.identified);
    expect(result.identity!.type, 'VCU');
    expect(result.identity!.version.toString(), '1.6.1');
    expect(result.identity!.serial, '1CGC1234567890');
    expect(result.identity!.serialModel, 'g3');
    expect(result.identity!.regionCode, 'C');
    expect(result.identity!.tableOffsets, [0x120, 0x5100]);
  });

  test('identifies MCU from agreeing tables with different SN/MN values', () {
    final bytes = Uint8List(kAt32f415SramLength);
    _putTable(
      bytes,
      0x420,
      type: 'MCU',
      version: 0x52,
      identity: 'Z025000000000000',
    );
    _putTable(
      bytes,
      0x1d84,
      type: 'MCU',
      version: 0x52,
      identity: 'Z025B4G25BM30168',
    );

    final result = SramIdentityParser.parse(bytes);

    expect(result.verdict, SramIdentityVerdict.identified);
    expect(result.identity!.type, 'MCU');
    expect(result.identity!.version.toString(), '1.5.2');
    expect(result.identity!.serial, isNull);
    expect(result.identity!.serialModel, isNull);
    expect(result.identity!.controllerSnMnCandidates, [
      'Z025000000000000',
      'Z025B4G25BM30168',
    ]);
  });

  test('rejects marker bytes without a valid identity table', () {
    final bytes = Uint8List(kAt32f415SramLength);
    bytes.setRange(0x80, 0x82, [0x5c, 0x50]);
    bytes[0x80 + 0x2e] = 0x61;

    final result = SramIdentityParser.parse(bytes);

    expect(result.verdict, SramIdentityVerdict.notFound);
  });

  test('rejects tables that disagree on firmware version', () {
    final bytes = Uint8List(kAt32f415SramLength);
    _putTable(
      bytes,
      0x100,
      type: 'VCU',
      version: 0x61,
      identity: '1CGC1234567890',
    );
    _putTable(
      bytes,
      0x500,
      type: 'VCU',
      version: 0x62,
      identity: '1CGC1234567890',
    );

    final result = SramIdentityParser.parse(bytes);

    expect(result.verdict, SramIdentityVerdict.conflicting);
    expect(result.reason, contains('disagree'));
  });

  test('keeps G3 Plus separate and decodes its known region code', () {
    final bytes = Uint8List(kAt32f415SramLength);
    _putTable(
      bytes,
      0x200,
      type: 'VCU',
      version: 0x318,
      identity: '4P2D1234567890',
    );

    final result = SramIdentityParser.parse(bytes);

    expect(result.identity!.version.toString(), '3.1.8');
    expect(result.identity!.serialModel, 'g3 plus');
    expect(result.identity!.regionCode, 'D');
    expect(result.identity!.regionLabel, 'Germany');
  });
}
