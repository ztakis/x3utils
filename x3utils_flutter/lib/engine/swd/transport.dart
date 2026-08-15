// Derived from swdart, MIT licensed. See third_party/swdart/LICENSE.
import 'dart:typed_data';

const int stlinkVid = 0x0483;

const Set<int> v3Pids = {
  0x374d,
  0x374e,
  0x374f,
  0x3753,
  0x3754,
  0x3755,
  0x3757,
};

abstract class UsbTransport {
  int get productId;
  String get productName;
  bool get isV3 => v3Pids.contains(productId);

  Future<Uint8List> xfer(List<int> command, {int rxLen = 0, Uint8List? data});

  Future<void> close();
}

/// Browser-visible lifecycle of the selected ST-Link. Native transports do not
/// need permission pairing and therefore report [ready].
enum UsbDeviceState {
  unsupported,
  selectionRequired,
  ready,
  disconnected,
  ambiguous,
}

class UsbDeviceStatus {
  const UsbDeviceStatus(this.state, {this.productName});

  final UsbDeviceState state;
  final String? productName;

  bool get ready => state == UsbDeviceState.ready;
}

enum UsbAcquireFailureKind {
  userCancelled,
  permissionRequired,
  unsupported,
  disconnected,
  ambiguous,
  unavailable,
  busy,
}

/// A USB acquisition failure whose recovery policy is known before target SWD
/// is attempted. These must not collapse into an ordinary contact failure.
class UsbAcquireException implements Exception {
  const UsbAcquireException(this.kind, this.message);

  final UsbAcquireFailureKind kind;
  final String message;

  @override
  String toString() => message;
}

typedef UsbDeviceStatusListener = void Function(UsbDeviceStatus status);
