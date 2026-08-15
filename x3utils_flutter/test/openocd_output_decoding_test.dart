import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:x3utils_flutter/engine/openocd_runner.dart';

/// OpenOCD echoes the source path back in its write-success line, in the
/// PLATFORM's encoding rather than UTF-8. On a Greek Windows box (ACP 1253)
/// that produced bytes a strict `utf8.decoder` rejects, and the exception
/// propagated out of the run: measured 2026-07-30, a flash aborted between
/// `flash erase_address` and `flash write_bank` while reporting "Could not
/// start OpenOCD". The chip was erased; the failure was in reading the receipt.
///
/// These pin the two properties that keep that from recurring: decoding cannot
/// throw, and the write/verify evidence still survives the mangling.
void main() {
  // The exact line from the 2026-07-30 log, with the path in CP1253 rather
  // than UTF-8. `Σοφία` is 0xD3 0xEF 0xF6 0xDF 0xE1 there — 0xD3 is a valid
  // UTF-8 lead byte and 0xEF is not a valid continuation, which is what threw
  // `FormatException: Missing extension byte (at offset 38)`.
  final ansiPath = <int>[0xD3, 0xEF, 0xF6, 0xDF, 0xE1];
  final writeLine = <int>[
    ...ascii.encode('wrote 131072 bytes from file C:/Users/'),
    ...ansiPath,
    ...ascii.encode('/Desktop/zt3_vcu_rescue.bin to flash bank 0'),
  ];

  test('the offset the crash reported is where the ANSI bytes start', () {
    // Guards the fixture itself: if this is not 38, the bytes above no longer
    // reproduce the reported failure and the rest of this file proves nothing.
    expect(ascii.encode('wrote 131072 bytes from file C:/Users/').length, 38);
    expect(() => utf8.decode(writeLine), throwsFormatException);
  });

  test('lenient decoding does not throw on the line that aborted a flash', () {
    const decoder = Utf8Decoder(allowMalformed: true);
    late String out;
    expect(() => out = decoder.convert(writeLine), returnsNormally);
    expect(out, contains('wrote 131072 bytes from file'));
    expect(out, contains('to flash bank 0'));
    expect(out, contains('\uFFFD')); // the path is mangled, not the line
  });

  test('write evidence survives an undecodable path', () {
    // The verdict must not depend on the path rendering: `wrote` and the byte
    // count are ASCII and precede the path on every OpenOCD line.
    final ev = OpenOcdEvidence()
      ..record(const Utf8Decoder(allowMalformed: true).convert(writeLine));
    expect(ev.wrote, isTrue);
  });

  test('verify evidence survives it too', () {
    final line = <int>[
      ...ascii.encode('verified 131072 bytes in 3.3s from C:/'),
      ...ansiPath,
      ...ascii.encode('/fw.bin'),
    ];
    final ev = OpenOcdEvidence()
      ..record(const Utf8Decoder(allowMalformed: true).convert(line));
    expect(ev.verified, isTrue);
  });
}
