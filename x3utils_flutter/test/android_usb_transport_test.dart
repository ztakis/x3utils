import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:x3utils_flutter/engine/swd/transport.dart';
import 'package:x3utils_flutter/engine/swd/transport_android.dart';
import 'package:x3utils_flutter/engine/swd/util.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(androidUsbHostChannelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('refresh maps Android USB-host device status', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getStatus');
      return <String, Object>{'state': 'ready', 'productName': 'ST-Link/V2'};
    });

    final status = await refreshStlinkSelection();

    expect(status.state, UsbDeviceState.ready);
    expect(status.productName, 'ST-Link/V2');
  });

  test('permission denial remains a typed acquisition failure', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'requestPermission');
      throw PlatformException(
        code: 'permission_required',
        message: 'USB permission was denied.',
      );
    });

    await expectLater(
      selectStlink(),
      throwsA(
        isA<UsbAcquireException>()
            .having(
              (error) => error.kind,
              'kind',
              UsbAcquireFailureKind.permissionRequired,
            )
            .having((error) => error.message, 'message', contains('denied')),
      ),
    );
  });

  test('open, transfer and close preserve one ST-Link transaction', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'open':
          return <String, Object>{
            'productId': 0x3748,
            'productName': 'ST-Link/V2',
          };
        case 'transfer':
          final arguments = call.arguments as Map<Object?, Object?>;
          expect(arguments['command'], Uint8List.fromList([0xf2, 0x21]));
          expect(arguments['data'], Uint8List.fromList([1, 2, 3, 4]));
          expect(arguments['rxLen'], 2);
          return Uint8List.fromList([0x80, 0x00]);
        case 'close':
          return null;
      }
      fail('Unexpected Android USB-host method ${call.method}');
    });

    final transport = await openSelectedStlink();
    final response = await transport.xfer(
      [0xf2, 0x21],
      rxLen: 2,
      data: Uint8List.fromList([1, 2, 3, 4]),
    );
    await transport.close();

    expect(transport.productId, 0x3748);
    expect(transport.productName, 'ST-Link/V2');
    expect(response, Uint8List.fromList([0x80, 0x00]));
    expect(calls.map((call) => call.method), ['open', 'transfer', 'close']);
    await expectLater(
      transport.xfer([0xf2]),
      throwsA(
        isA<SwdException>().having(
          (error) => '$error',
          'message',
          contains('closed'),
        ),
      ),
    );
  });

  test('oversized ST-Link commands fail before crossing the channel', () async {
    var channelCalls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      channelCalls++;
      if (call.method == 'open') {
        return <String, Object>{
          'productId': 0x3748,
          'productName': 'ST-Link/V2',
        };
      }
      return null;
    });
    final transport = await openSelectedStlink();

    await expectLater(
      transport.xfer(List<int>.filled(17, 0)),
      throwsA(isA<SwdException>()),
    );
    expect(channelCalls, 1);
  });

  test(
    'native attach or detach events refresh the watched device state',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'getStatus');
        return <String, Object>{'state': 'disconnected'};
      });
      final changed = Completer<UsbDeviceStatus>();
      watchStlinkSelection(changed.complete);
      final response = Completer<void>();

      await messenger.handlePlatformMessage(
        androidUsbHostChannelName,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('deviceChanged'),
        ),
        (_) => response.complete(),
      );
      await response.future;
      final status = await changed.future;

      expect(status.state, UsbDeviceState.disconnected);
    },
  );
}
