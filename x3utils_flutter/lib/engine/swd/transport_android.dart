// Derived from swdart, MIT licensed. See third_party/swdart/LICENSE.
// Android USB-host transport. The Kotlin bridge owns UsbManager and performs
// blocking USB work away from Android's UI thread.
import 'dart:async';

import 'package:flutter/services.dart';

import 'transport.dart';
import 'util.dart';

const androidUsbHostChannelName = 'dev.x3utils/usb_host';

const MethodChannel _channel = MethodChannel(androidUsbHostChannelName);

bool get isUsbSupported => true;

UsbDeviceStatus get initialStlinkStatus =>
    const UsbDeviceStatus(UsbDeviceState.selectionRequired);

UsbDeviceStatusListener? _statusListener;
bool _watching = false;

UsbDeviceStatus _parseStatus(Object? raw) {
  if (raw is! Map) {
    throw const UsbAcquireException(
      UsbAcquireFailureKind.unavailable,
      'Android USB host returned an invalid device status.',
    );
  }
  final state = switch (raw['state']) {
    'unsupported' => UsbDeviceState.unsupported,
    'selectionRequired' => UsbDeviceState.selectionRequired,
    'ready' => UsbDeviceState.ready,
    'disconnected' => UsbDeviceState.disconnected,
    'ambiguous' => UsbDeviceState.ambiguous,
    _ => throw const UsbAcquireException(
      UsbAcquireFailureKind.unavailable,
      'Android USB host returned an unknown device state.',
    ),
  };
  return UsbDeviceStatus(state, productName: raw['productName'] as String?);
}

UsbAcquireException _acquireError(Object error) {
  if (error is UsbAcquireException) return error;
  if (error is PlatformException) {
    final kind = switch (error.code) {
      'user_cancelled' => UsbAcquireFailureKind.userCancelled,
      'permission_required' => UsbAcquireFailureKind.permissionRequired,
      'unsupported' => UsbAcquireFailureKind.unsupported,
      'disconnected' => UsbAcquireFailureKind.disconnected,
      'ambiguous' => UsbAcquireFailureKind.ambiguous,
      'busy' => UsbAcquireFailureKind.busy,
      _ => UsbAcquireFailureKind.unavailable,
    };
    return UsbAcquireException(
      kind,
      error.message ?? 'Android USB host failed (${error.code}).',
    );
  }
  return UsbAcquireException(UsbAcquireFailureKind.unavailable, '$error');
}

Future<T> _usbCall<T>(Future<T> Function() call) async {
  try {
    return await call();
  } catch (error) {
    throw _acquireError(error);
  }
}

Future<UsbDeviceStatus> refreshStlinkSelection() => _usbCall(() async {
  final raw = await _channel.invokeMethod<Object?>('getStatus');
  final status = _parseStatus(raw);
  _statusListener?.call(status);
  return status;
});

Future<UsbDeviceStatus> selectStlink() => _usbCall(() async {
  final raw = await _channel.invokeMethod<Object?>('requestPermission');
  final status = _parseStatus(raw);
  _statusListener?.call(status);
  return status;
});

void watchStlinkSelection(UsbDeviceStatusListener listener) {
  _statusListener = listener;
  if (_watching) return;
  _watching = true;
  _channel.setMethodCallHandler((call) async {
    if (call.method == 'deviceChanged') {
      try {
        await refreshStlinkSelection();
      } catch (_) {
        _statusListener?.call(
          const UsbDeviceStatus(UsbDeviceState.disconnected),
        );
      }
    }
  });
}

class _AndroidUsbTransport implements UsbTransport {
  _AndroidUsbTransport({required this.productId, required this.productName});

  @override
  final int productId;

  @override
  final String productName;

  @override
  bool get isV3 => v3Pids.contains(productId);

  bool _closed = false;

  @override
  Future<Uint8List> xfer(
    List<int> command, {
    int rxLen = 0,
    Uint8List? data,
  }) async {
    if (_closed) throw SwdException('Android USB transport is closed.');
    if (command.length > 16) {
      throw SwdException('ST-Link command exceeds the 16-byte USB packet.');
    }
    if (rxLen < 0) throw SwdException('USB receive length cannot be negative.');
    try {
      final response = await _channel.invokeMethod<Uint8List>('transfer', {
        'command': Uint8List.fromList(command),
        'rxLen': rxLen,
        if (data != null && data.isNotEmpty) 'data': data,
      });
      return response ?? Uint8List(0);
    } catch (error) {
      final failure = _acquireError(error);
      throw SwdException(failure.message);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _channel.invokeMethod<void>('close');
    } catch (error) {
      final failure = _acquireError(error);
      throw SwdException(failure.message);
    }
  }
}

Future<UsbTransport> openSelectedStlink() => _usbCall(() async {
  final raw = await _channel.invokeMethod<Object?>('open');
  if (raw is! Map || raw['productId'] is! int) {
    throw const UsbAcquireException(
      UsbAcquireFailureKind.unavailable,
      'Android USB host returned invalid ST-Link details.',
    );
  }
  return _AndroidUsbTransport(
    productId: raw['productId'] as int,
    productName: raw['productName'] as String? ?? 'ST-Link',
  );
});
