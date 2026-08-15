// Derived from swdart, MIT licensed. See third_party/swdart/LICENSE.
// Native USB transport for a future desktop swdart backend. It is compiled but
// not selected by AppController while desktop continues to use OpenOCD.
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'transport.dart';
import 'util.dart';

const _stlinkPids = <int>[
  0x3748,
  0x374b,
  0x3752,
  0x374d,
  0x374e,
  0x374f,
  0x3753,
  0x3754,
  0x3755,
  0x3757,
];

const _outEp01Pids = <int>{
  0x374b,
  0x3752,
  0x374d,
  0x374e,
  0x374f,
  0x3753,
  0x3754,
  0x3755,
  0x3757,
};

const _epIn = 0x81;
const _interface = 0;
const _timeout = 2000;

int _outEndpoint(int pid) => _outEp01Pids.contains(pid) ? 0x01 : 0x02;

typedef _InitNative = Int32 Function(Pointer<Pointer<Void>>);
typedef _InitDart = int Function(Pointer<Pointer<Void>>);
typedef _ExitNative = Void Function(Pointer<Void>);
typedef _ExitDart = void Function(Pointer<Void>);
typedef _OpenVidPidNative =
    Pointer<Void> Function(Pointer<Void>, Uint16, Uint16);
typedef _OpenVidPidDart = Pointer<Void> Function(Pointer<Void>, int, int);
typedef _CloseNative = Void Function(Pointer<Void>);
typedef _CloseDart = void Function(Pointer<Void>);
typedef _ClaimNative = Int32 Function(Pointer<Void>, Int32);
typedef _ClaimDart = int Function(Pointer<Void>, int);
typedef _AutoDetachNative = Int32 Function(Pointer<Void>, Int32);
typedef _AutoDetachDart = int Function(Pointer<Void>, int);
typedef _BulkNative =
    Int32 Function(
      Pointer<Void>,
      Uint8,
      Pointer<Uint8>,
      Int32,
      Pointer<Int32>,
      Uint32,
    );
typedef _BulkDart =
    int Function(Pointer<Void>, int, Pointer<Uint8>, int, Pointer<Int32>, int);

class _Libusb {
  _Libusb(DynamicLibrary library)
    : init = library.lookupFunction<_InitNative, _InitDart>('libusb_init'),
      exit = library.lookupFunction<_ExitNative, _ExitDart>('libusb_exit'),
      openVidPid = library.lookupFunction<_OpenVidPidNative, _OpenVidPidDart>(
        'libusb_open_device_with_vid_pid',
      ),
      closeHandle = library.lookupFunction<_CloseNative, _CloseDart>(
        'libusb_close',
      ),
      claim = library.lookupFunction<_ClaimNative, _ClaimDart>(
        'libusb_claim_interface',
      ),
      release = library.lookupFunction<_ClaimNative, _ClaimDart>(
        'libusb_release_interface',
      ),
      autoDetach = library.lookupFunction<_AutoDetachNative, _AutoDetachDart>(
        'libusb_set_auto_detach_kernel_driver',
      ),
      bulk = library.lookupFunction<_BulkNative, _BulkDart>(
        'libusb_bulk_transfer',
      );

  final _InitDart init;
  final _ExitDart exit;
  final _OpenVidPidDart openVidPid;
  final _CloseDart closeHandle;
  final _ClaimDart claim;
  final _ClaimDart release;
  final _AutoDetachDart autoDetach;
  final _BulkDart bulk;

  static _Libusb open() {
    final executableDirectory = File(Platform.resolvedExecutable).parent.path;
    final candidates = <String>[];
    if (Platform.isWindows) {
      candidates.addAll([
        'libusb-1.0.dll',
        '$executableDirectory\\libusb-1.0.dll',
      ]);
    } else if (Platform.isMacOS) {
      candidates.addAll([
        '$executableDirectory/native/macos/oocd/libexec/'
            'libusb-1.0.0.dylib',
        'libusb-1.0.0.dylib',
        'libusb-1.0.dylib',
        '$executableDirectory/../Frameworks/libusb-1.0.0.dylib',
        '$executableDirectory/../Frameworks/libusb-1.0.dylib',
        '/opt/homebrew/lib/libusb-1.0.0.dylib',
        '/usr/local/lib/libusb-1.0.0.dylib',
      ]);
    } else {
      candidates.addAll([
        'libusb-1.0.so.0',
        'libusb-1.0.so',
        '$executableDirectory/lib/libusb-1.0.so.0',
        '$executableDirectory/lib/libusb-1.0.so',
        '/usr/lib/x86_64-linux-gnu/libusb-1.0.so.0',
        '/lib/x86_64-linux-gnu/libusb-1.0.so.0',
      ]);
    }
    for (final name in candidates) {
      try {
        return _Libusb(DynamicLibrary.open(name));
      } catch (_) {}
    }
    throw SwdException(
      'libusb-1.0 could not be loaded. Bundle it beside the application or '
      'install it system-wide.',
    );
  }
}

class _NativeUsbTransport implements UsbTransport {
  _NativeUsbTransport(this._library, this._context, this._handle, this._pid);

  final _Libusb _library;
  final Pointer<Void> _context;
  final Pointer<Void> _handle;
  final int _pid;

  @override
  int get productId => _pid;

  @override
  String get productName =>
      isV3 ? 'STLINK-V3' : (_pid == 0x3748 ? 'ST-Link/V2' : 'ST-Link/V2-1');

  @override
  bool get isV3 => v3Pids.contains(_pid);

  Future<void> _bulkOut(int endpoint, Uint8List data) async {
    final buffer = malloc<Uint8>(data.length);
    final transferred = malloc<Int32>();
    try {
      buffer.asTypedList(data.length).setAll(0, data);
      final result = _library.bulk(
        _handle,
        endpoint,
        buffer,
        data.length,
        transferred,
        _timeout,
      );
      if (result != 0) {
        throw SwdException('libusb bulk OUT failed: $result');
      }
    } finally {
      malloc.free(buffer);
      malloc.free(transferred);
    }
  }

  Future<Uint8List> _bulkIn(int endpoint, int length) async {
    final buffer = malloc<Uint8>(length);
    final transferred = malloc<Int32>();
    try {
      final result = _library.bulk(
        _handle,
        endpoint,
        buffer,
        length,
        transferred,
        _timeout,
      );
      if (result != 0) {
        throw SwdException('libusb bulk IN failed: $result');
      }
      return Uint8List.fromList(buffer.asTypedList(transferred.value));
    } finally {
      malloc.free(buffer);
      malloc.free(transferred);
    }
  }

  int get _endpointOut => _outEndpoint(_pid);

  @override
  Future<Uint8List> xfer(
    List<int> command, {
    int rxLen = 0,
    Uint8List? data,
  }) async {
    final packet = Uint8List(16)..setRange(0, command.length, command);
    await _bulkOut(_endpointOut, packet);
    if (data != null && data.isNotEmpty) {
      await _bulkOut(_endpointOut, data);
    }
    if (rxLen > 0) return _bulkIn(_epIn, rxLen);
    return Uint8List(0);
  }

  @override
  Future<void> close() async {
    try {
      _library.release(_handle, _interface);
    } catch (_) {}
    _library.closeHandle(_handle);
    _library.exit(_context);
  }
}

Future<UsbTransport?> _open() async {
  final library = _Libusb.open();
  final contextPointer = malloc<Pointer<Void>>();
  try {
    if (library.init(contextPointer) != 0) {
      throw SwdException('libusb_init failed');
    }
    final context = contextPointer.value;
    for (final pid in _stlinkPids) {
      final handle = library.openVidPid(context, stlinkVid, pid);
      if (handle == nullptr) continue;
      try {
        library.autoDetach(handle, 1);
      } catch (_) {}
      final result = library.claim(handle, _interface);
      if (result != 0) {
        library.closeHandle(handle);
        library.exit(context);
        throw SwdException(
          'libusb_claim_interface failed: $result (WinUSB driver bound?)',
        );
      }
      return _NativeUsbTransport(library, context, handle, pid);
    }
    library.exit(context);
    return null;
  } finally {
    malloc.free(contextPointer);
  }
}

UsbDeviceStatus get initialStlinkStatus =>
    const UsbDeviceStatus(UsbDeviceState.ready);

Future<UsbDeviceStatus> refreshStlinkSelection() async => initialStlinkStatus;

Future<UsbDeviceStatus> selectStlink() async => initialStlinkStatus;

void watchStlinkSelection(UsbDeviceStatusListener listener) {}

Future<UsbTransport> openSelectedStlink() async {
  final transport = await _open();
  if (transport == null) {
    throw const UsbAcquireException(
      UsbAcquireFailureKind.unavailable,
      'No ST-Link found on USB',
    );
  }
  return transport;
}
