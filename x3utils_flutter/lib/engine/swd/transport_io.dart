// Derived from swdart, MIT licensed. See third_party/swdart/LICENSE.
// Routes Flutter IO platforms to their native USB implementation.
import 'dart:io';

import 'transport.dart';
import 'transport_android.dart' as android;
import 'transport_native.dart' as desktop;

bool get isUsbSupported => Platform.isAndroid ? android.isUsbSupported : true;

UsbDeviceStatus get initialStlinkStatus => Platform.isAndroid
    ? android.initialStlinkStatus
    : desktop.initialStlinkStatus;

Future<UsbDeviceStatus> refreshStlinkSelection() => Platform.isAndroid
    ? android.refreshStlinkSelection()
    : desktop.refreshStlinkSelection();

Future<UsbDeviceStatus> selectStlink() =>
    Platform.isAndroid ? android.selectStlink() : desktop.selectStlink();

void watchStlinkSelection(UsbDeviceStatusListener listener) {
  if (Platform.isAndroid) {
    android.watchStlinkSelection(listener);
  } else {
    desktop.watchStlinkSelection(listener);
  }
}

Future<UsbTransport> openSelectedStlink() => Platform.isAndroid
    ? android.openSelectedStlink()
    : desktop.openSelectedStlink();
