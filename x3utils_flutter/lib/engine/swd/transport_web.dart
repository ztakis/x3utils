// Derived from swdart, MIT licensed. See third_party/swdart/LICENSE.
// package:web does not expose WebUSB, so bind navigator.usb directly.
import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'transport.dart';
import 'util.dart';

@JS('navigator.usb')
external _Usb get _usb;

@JS('navigator.usb')
external JSAny? get _usbRaw;

extension type _Usb._(JSObject _) implements JSObject {
  external JSPromise<JSArray<_UsbDevice>> getDevices();
  external JSPromise<_UsbDevice> requestDevice(JSObject options);
  external void addEventListener(String type, JSFunction listener);
}

extension type _UsbDevice._(JSObject _) implements JSObject {
  external int get vendorId;
  external int get productId;
  external String? get productName;
  external String? get serialNumber;
  external _UsbConfiguration? get configuration;
  external JSPromise<JSAny?> open();
  external JSPromise<JSAny?> close();
  external JSPromise<JSAny?> selectConfiguration(int configurationValue);
  external JSPromise<JSAny?> claimInterface(int interfaceNumber);
  external JSPromise<JSAny?> releaseInterface(int interfaceNumber);
  external JSPromise<_UsbInTransferResult> transferIn(
    int endpointNumber,
    int length,
  );
  external JSPromise<_UsbOutTransferResult> transferOut(
    int endpointNumber,
    JSObject data,
  );
}

extension type _UsbConfiguration._(JSObject _) implements JSObject {
  external JSArray<_UsbInterface> get interfaces;
}

extension type _UsbInterface._(JSObject _) implements JSObject {
  external int get interfaceNumber;
  external _UsbAlternateInterface get alternate;
}

extension type _UsbAlternateInterface._(JSObject _) implements JSObject {
  external int get interfaceClass;
  external JSArray<_UsbEndpoint> get endpoints;
}

extension type _UsbEndpoint._(JSObject _) implements JSObject {
  external int get endpointNumber;
  external String get direction;
  external String get type;
}

extension type _UsbInTransferResult._(JSObject _) implements JSObject {
  external _JsDataView? get data;
  external String get status;
}

extension type _UsbOutTransferResult._(JSObject _) implements JSObject {
  external String get status;
}

extension type _JsDataView._(JSObject _) implements JSObject {
  external JSArrayBuffer get buffer;
  external int get byteOffset;
  external int get byteLength;
}

bool get isUsbSupported => _usbRaw != null;

_UsbDevice? _selectedDevice;
String? _selectedSerial;
int? _selectedProductId;
UsbDeviceStatusListener? _statusListener;
JSFunction? _connectListener;
JSFunction? _disconnectListener;

UsbDeviceStatus get initialStlinkStatus => isUsbSupported
    ? const UsbDeviceStatus(UsbDeviceState.selectionRequired)
    : const UsbDeviceStatus(UsbDeviceState.unsupported);

String _deviceName(_UsbDevice device) {
  final name = device.productName;
  return name != null && name.isNotEmpty ? name : 'ST-Link';
}

bool _isSelectedDevice(_UsbDevice device) {
  if (_selectedDevice != null && device == _selectedDevice) return true;
  final serial = device.serialNumber;
  return _selectedSerial != null &&
      serial != null &&
      serial.isNotEmpty &&
      serial == _selectedSerial &&
      device.productId == _selectedProductId;
}

void _rememberDevice(_UsbDevice device) {
  _selectedDevice = device;
  _selectedProductId = device.productId;
  final serial = device.serialNumber;
  _selectedSerial = serial != null && serial.isNotEmpty ? serial : null;
}

void _publish(UsbDeviceStatus status) => _statusListener?.call(status);

UsbAcquireException _acquireError(Object error) {
  final message = '$error';
  final lower = message.toLowerCase();
  if (lower.contains('notfounderror') && lower.contains('no device selected')) {
    return UsbAcquireException(UsbAcquireFailureKind.userCancelled, message);
  }
  if (lower.contains('securityerror') ||
      lower.contains('notallowederror') ||
      lower.contains('user activation')) {
    return UsbAcquireException(
      UsbAcquireFailureKind.permissionRequired,
      message,
    );
  }
  if (lower.contains('networkerror') ||
      lower.contains('notfounderror') ||
      lower.contains('disconnected') ||
      lower.contains('device unavailable')) {
    return UsbAcquireException(UsbAcquireFailureKind.disconnected, message);
  }
  if (lower.contains('claim') || lower.contains('busy')) {
    return UsbAcquireException(UsbAcquireFailureKind.busy, message);
  }
  return UsbAcquireException(UsbAcquireFailureKind.unavailable, message);
}

Future<T> _usbCall<T>(Future<T> Function() call) async {
  try {
    return await call();
  } catch (error, stackTrace) {
    if (error is SwdException || error is UsbAcquireException) rethrow;
    Error.throwWithStackTrace(_acquireError(error), stackTrace);
  }
}

Future<List<_UsbDevice>> _grantedStlinks() async {
  if (!isUsbSupported) return const <_UsbDevice>[];
  return (await _usb.getDevices().toDart).toDart
      .where((device) => device.vendorId == stlinkVid)
      .toList(growable: false);
}

Future<UsbDeviceStatus> refreshStlinkSelection() async {
  if (!isUsbSupported) {
    const status = UsbDeviceStatus(UsbDeviceState.unsupported);
    _publish(status);
    return status;
  }

  try {
    final granted = await _grantedStlinks();
    for (final device in granted) {
      if (_isSelectedDevice(device)) {
        _rememberDevice(device);
        final status = UsbDeviceStatus(
          UsbDeviceState.ready,
          productName: _deviceName(device),
        );
        _publish(status);
        return status;
      }
    }

    if (granted.length == 1) {
      _rememberDevice(granted.single);
      final status = UsbDeviceStatus(
        UsbDeviceState.ready,
        productName: _deviceName(granted.single),
      );
      _publish(status);
      return status;
    }

    final status = granted.isEmpty
        ? UsbDeviceStatus(
            _selectedDevice == null
                ? UsbDeviceState.selectionRequired
                : UsbDeviceState.disconnected,
          )
        : const UsbDeviceStatus(UsbDeviceState.ambiguous);
    _publish(status);
    return status;
  } catch (error) {
    final failure = _acquireError(error);
    final status = UsbDeviceStatus(
      failure.kind == UsbAcquireFailureKind.permissionRequired
          ? UsbDeviceState.selectionRequired
          : UsbDeviceState.disconnected,
    );
    _publish(status);
    return status;
  }
}

Future<UsbDeviceStatus> selectStlink() async {
  if (!isUsbSupported) {
    throw const UsbAcquireException(
      UsbAcquireFailureKind.unsupported,
      'WebUSB is not supported by this browser.',
    );
  }
  final options =
      <String, dynamic>{
            'filters': <dynamic>[
              <String, dynamic>{'vendorId': stlinkVid},
            ],
          }.jsify()!
          as JSObject;

  // requestDevice must be invoked directly from the user gesture. Do not put
  // an await between the UI callback and this call.
  final request = _usb.requestDevice(options);
  try {
    final device = await request.toDart;
    _rememberDevice(device);
    final status = UsbDeviceStatus(
      UsbDeviceState.ready,
      productName: _deviceName(device),
    );
    _publish(status);
    return status;
  } catch (error) {
    throw _acquireError(error);
  }
}

void watchStlinkSelection(UsbDeviceStatusListener listener) {
  _statusListener = listener;
  if (!isUsbSupported || _connectListener != null) return;

  _connectListener = ((JSAny? _) {
    unawaited(refreshStlinkSelection());
  }).toJS;
  _disconnectListener = ((JSAny? _) {
    unawaited(refreshStlinkSelection());
  }).toJS;
  _usb.addEventListener('connect', _connectListener!);
  _usb.addEventListener('disconnect', _disconnectListener!);
}

class _WebUsbTransport implements UsbTransport {
  _WebUsbTransport(
    this._device,
    this._interface,
    this._endpointOut,
    this._endpointIn,
  );

  final _UsbDevice _device;
  final int _interface;
  final int _endpointOut;
  final int _endpointIn;

  @override
  int get productId => _device.productId;

  @override
  bool get isV3 => v3Pids.contains(productId);

  @override
  String get productName {
    final name = _device.productName;
    return name != null && name.isNotEmpty ? name : 'ST-Link';
  }

  @override
  Future<Uint8List> xfer(
    List<int> command, {
    int rxLen = 0,
    Uint8List? data,
  }) async {
    final packet = Uint8List(16)..setRange(0, command.length, command);
    final commandResult = await _usbCall(
      () => _device.transferOut(_endpointOut, packet.toJS).toDart,
    );
    if (commandResult.status != 'ok') {
      throw SwdException(
        'USB command transfer failed: ${commandResult.status}',
      );
    }

    if (data != null && data.isNotEmpty) {
      // A sublist view may lose its offset when crossing JS interop. Always
      // transfer a fresh, contiguous, offset-zero array.
      final clean = Uint8List.fromList(data);
      final dataResult = await _usbCall(
        () => _device.transferOut(_endpointOut, clean.toJS).toDart,
      );
      if (dataResult.status != 'ok') {
        throw SwdException('USB data transfer failed: ${dataResult.status}');
      }
    }

    if (rxLen == 0) return Uint8List(0);
    final readResult = await _usbCall(
      () => _device.transferIn(_endpointIn, rxLen).toDart,
    );
    final view = readResult.data;
    if (readResult.status != 'ok' || view == null) {
      throw SwdException('USB read failed: ${readResult.status}');
    }
    return Uint8List.fromList(
      view.buffer.toDart.asUint8List(view.byteOffset, view.byteLength),
    );
  }

  @override
  Future<void> close() async {
    try {
      await _device.releaseInterface(_interface).toDart;
    } catch (_) {}
    try {
      await _device.close().toDart;
    } catch (_) {}
  }
}

Future<UsbTransport> _openDevice(_UsbDevice device) async {
  await device.open().toDart;
  if (device.configuration == null) {
    await device.selectConfiguration(1).toDart;
  }
  final configuration = device.configuration;
  if (configuration == null) {
    throw SwdException('USB device has no active configuration');
  }

  for (final interface in configuration.interfaces.toDart) {
    final alternate = interface.alternate;
    if (alternate.interfaceClass != 0xff) continue;
    var endpointOut = -1;
    var endpointIn = -1;
    for (final endpoint in alternate.endpoints.toDart) {
      if (endpoint.type != 'bulk') continue;
      if (endpoint.direction == 'out' && endpointOut < 0) {
        endpointOut = endpoint.endpointNumber;
      }
      if (endpoint.direction == 'in' && endpointIn < 0) {
        endpointIn = endpoint.endpointNumber;
      }
    }
    if (endpointOut >= 0 && endpointIn >= 0) {
      await device.claimInterface(interface.interfaceNumber).toDart;
      return _WebUsbTransport(
        device,
        interface.interfaceNumber,
        endpointOut,
        endpointIn,
      );
    }
  }
  await device.close().toDart;
  throw SwdException(
    'No ST-Link debug interface found. On Windows, bind the ST-Link to WinUSB '
    '(official ST driver or Zadig).',
  );
}

Future<UsbTransport> openSelectedStlink() async {
  var selected = _selectedDevice;
  if (selected == null) {
    final status = await refreshStlinkSelection();
    selected = _selectedDevice;
    if (!status.ready || selected == null) {
      final kind = switch (status.state) {
        UsbDeviceState.unsupported => UsbAcquireFailureKind.unsupported,
        UsbDeviceState.ambiguous => UsbAcquireFailureKind.ambiguous,
        UsbDeviceState.disconnected => UsbAcquireFailureKind.disconnected,
        UsbDeviceState.selectionRequired =>
          UsbAcquireFailureKind.permissionRequired,
        UsbDeviceState.ready => UsbAcquireFailureKind.unavailable,
      };
      throw UsbAcquireException(kind, 'No selected ST-Link is ready.');
    }
  }

  try {
    return await _openDevice(selected);
  } catch (error) {
    if (error is UsbAcquireException) rethrow;
    throw _acquireError(error);
  }
}
