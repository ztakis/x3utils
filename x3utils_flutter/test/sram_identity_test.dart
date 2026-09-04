import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:x3utils_flutter/engine/sram_identity.dart';

/// Builds a record shaped like the real ones measured on hardware: marker byte
/// `0x5C` plus a model-dependent second byte, id at +0x20, an optional second
/// 16-char field at +0x40, and the version halfword at +0x2E for BOTH
/// components. `marker2` defaults to a value neither g3 (`0x50`) nor zt3
/// (`0x51`) uses, so every test that does not care about it is also asserting
/// that an unseen model still parses.
void _putTable(
  Uint8List bytes,
  int offset, {
  required int version,
  required String identity,
  int marker2 = 0x57,
  String? secondField,
}) {
  // The version halfword follows the id field: +0x2E after a 14-char serial,
  // +0x32 after a 16-char SN/MN (which itself runs to +0x2F).
  final versionOffset = offset + (identity.length == 16 ? 0x32 : 0x2e);
  bytes[offset] = 0x5c;
  bytes[offset + 1] = marker2;
  bytes.setRange(
    offset + 0x20,
    offset + 0x20 + identity.length,
    identity.codeUnits,
  );
  // Real records terminate a 14-char serial with a non-ASCII byte; without it
  // a VCU serial would read as the first 14 chars of a 16-char field.
  bytes[offset + 0x20 + identity.length] = 0x00;
  if (secondField != null) {
    bytes.setRange(
      offset + 0x40,
      offset + 0x40 + secondField.length,
      secondField.codeUnits,
    );
  }
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
        marker2: 0x50,
        version: 0x161,
        identity: '1CGC1234567890',
        secondField: 'Z03B000000000000',
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
    _putTable(bytes, 0x420, version: 0x152, identity: 'Z025000000000000');
    _putTable(bytes, 0x1d84, version: 0x152, identity: 'Z025B4G25BM30168');

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
    _putTable(bytes, 0x100, version: 0x161, identity: '1CGC1234567890');
    _putTable(bytes, 0x500, version: 0x162, identity: '1CGC1234567890');

    final result = SramIdentityParser.parse(bytes);

    expect(result.verdict, SramIdentityVerdict.conflicting);
    expect(result.reason, contains('disagree'));
  });

  // Regression: a zt3 VCU record carries marker `5C 51`, which the old parser
  // read as "MCU" and therefore demanded 16 ASCII chars at +0x20. The 14-char
  // serial ends before that, so a real, populated record was discarded and the
  // whole snapshot reported notFound. Measured on three boards.
  test('reads a VCU record whose marker byte is the one used by zt3', () {
    final bytes = Uint8List(kAt32f415SramLength);
    _putTable(
      bytes,
      0x19fc,
      marker2: 0x51,
      version: 0x155,
      identity: '1K1U1234567890',
      secondField: 'Z03X000000000000',
    );

    final result = SramIdentityParser.parse(bytes);

    expect(result.verdict, SramIdentityVerdict.identified);
    expect(result.identity!.type, 'VCU');
    expect(result.identity!.serial, '1K1U1234567890');
    expect(result.identity!.serialModel, 'zt3');
    expect(result.identity!.version.toString(), '1.5.5');
  });

  // Regression: an MCU's 16-char SN/MN at +0x20 runs to +0x2F, so the VCU
  // version offset (+0x2E) lands INSIDE it — on the real zt3 MCU 1.5.2 board
  // that halfword reads as ASCII from the middle of the SN/MN. Collapsing both
  // components onto +0x2E therefore cannot work; the offset follows the id
  // length. This record also carries the zt3 VCU's marker byte and an empty
  // +0x40, both as measured.
  test('reads an MCU record whose version clears the 16-char SN/MN', () {
    final bytes = Uint8List(kAt32f415SramLength);
    _putTable(
      bytes,
      0x420,
      marker2: 0x51,
      version: 0x152,
      identity: 'Z025B4G25BM30168',
    );

    final result = SramIdentityParser.parse(bytes);

    expect(result.verdict, SramIdentityVerdict.identified);
    expect(result.identity!.type, 'MCU');
    expect(result.identity!.version.toString(), '1.5.2');
    expect(result.identity!.serial, isNull);
    // The bytes at the VCU version offset are id text, not a version.
    expect(bytes[0x420 + 0x2e], greaterThanOrEqualTo(0x30));
  });

  test('reports identity when the version field does not decode', () {
    final bytes = Uint8List(kAt32f415SramLength);
    _putTable(bytes, 0x300, version: 0x000, identity: '1CGC1234567890');

    final result = SramIdentityParser.parse(bytes);

    expect(result.verdict, SramIdentityVerdict.identified);
    expect(result.identity!.serial, '1CGC1234567890');
    expect(result.identity!.version, isNull);
  });

  test('does not promote a sub-0x100 halfword into a major-1 version', () {
    final bytes = Uint8List(kAt32f415SramLength);
    _putTable(bytes, 0x300, version: 0x061, identity: '1CGC1234567890');

    final result = SramIdentityParser.parse(bytes);

    expect(result.identity!.version, isNull);
  });

  test('rejects a 14-char id whose prefix is not a known serial', () {
    final bytes = Uint8List(kAt32f415SramLength);
    _putTable(bytes, 0x300, version: 0x161, identity: 'ZZZZ1234567890');

    final result = SramIdentityParser.parse(bytes);

    expect(result.verdict, SramIdentityVerdict.notFound);
  });

  test('keeps G3 Plus separate and decodes its known region code', () {
    final bytes = Uint8List(kAt32f415SramLength);
    _putTable(bytes, 0x200, version: 0x318, identity: '4P2D1234567890');

    final result = SramIdentityParser.parse(bytes);

    expect(result.identity!.version.toString(), '3.1.8');
    expect(result.identity!.serialModel, 'g3 plus');
    expect(result.identity!.regionCode, 'D');
    expect(result.identity!.regionLabel, 'Germany');
  });
}
