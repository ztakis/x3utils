import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:x3utils_flutter/engine/swd/stlink.dart';
import 'package:x3utils_flutter/engine/swd/transport.dart';
import 'package:x3utils_flutter/engine/swd/util.dart';

class _RecordingTransport implements UsbTransport {
  _RecordingTransport({this.v3 = false});

  final bool v3;
  Uint8List response = Uint8List.fromList([0x80, 0]);
  final commands = <List<int>>[];

  @override
  int get productId => 0x3748;

  @override
  String get productName => 'ST-Link/V2';

  @override
  bool get isV3 => v3;

  @override
  Future<Uint8List> xfer(
    List<int> command, {
    int rxLen = 0,
    Uint8List? data,
  }) async {
    commands.add(List<int>.from(command));
    return response;
  }

  @override
  Future<void> close() async {}
}

class _MemoryTransport implements UsbTransport {
  @override
  int get productId => 0x3748;

  @override
  String get productName => 'ST-Link/V2';

  @override
  bool get isV3 => false;

  @override
  Future<Uint8List> xfer(
    List<int> command, {
    int rxLen = 0,
    Uint8List? data,
  }) async {
    final response = Uint8List(rxLen);
    final isMemoryRead = command.length > 1 && command[1] == 0x07;
    if (!isMemoryRead && response.isNotEmpty) response[0] = 0x80;
    return response;
  }

  @override
  Future<void> close() async {}
}

void main() {
  test('ST-Link APIv2 drives genuine nRST low then high', () async {
    final transport = _RecordingTransport();
    final stlink = Stlink(transport);

    await stlink.driveNrst(0);
    await stlink.driveNrst(1);

    expect(transport.commands, [
      [0xf2, 0x3c, 0],
      [0xf2, 0x3c, 1],
    ]);
  });

  test('ST-Link nRST command failure is surfaced', () async {
    final transport = _RecordingTransport()
      ..response = Uint8List.fromList([0x16, 0]);
    final stlink = Stlink(transport);

    await expectLater(stlink.driveNrst(0), throwsA(isA<SwdException>()));
  });

  test('ST-Link APIv2 writes the FAP halfword with write-memory-16', () async {
    final transport = _RecordingTransport(v3: true);
    final stlink = Stlink(transport);

    await stlink.writeMem16(0x1ffff800, Uint8List.fromList(const [0xa5, 0x5a]));

    expect(transport.commands.first, [
      0xf2,
      0x48,
      0x00,
      0xf8,
      0xff,
      0x1f,
      0x02,
      0x00,
    ]);
    expect(transport.commands.last, [0xf2, 0x3e]);
  });

  test('long ST-Link memory reads yield to the event queue', () async {
    final stlink = Stlink(_MemoryTransport());
    var queuedEventRan = false;
    Timer.run(() => queuedEventRan = true);

    final bytes = await stlink.readMem32(0x08000000, 5 * 1024);

    expect(bytes, hasLength(5 * 1024));
    expect(queuedEventRan, isTrue);
  });
}
