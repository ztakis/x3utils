// Derived from swdart, MIT licensed. See third_party/swdart/LICENSE.
import 'dart:typed_data';

import 'debug_probe.dart';
import 'transport.dart';
import 'util.dart';

const _cmdGetVersion = 0xf1;
const _cmdDebug = 0xf2;
const _cmdDfu = 0xf3;
const _cmdGetCurrentMode = 0xf5;
const _cmdGetTargetVoltage = 0xf7;
const _cmdGetVersionV3 = 0xfb;
const _dfuExit = 0x07;

const _debugReadmem32 = 0x07;
const _debugWritemem32 = 0x08;
const _debugWritemem16 = 0x48;
const _debugExit = 0x21;
const _apiv2Enter = 0x30;
const _apiv2ReadIdcodes = 0x31;
const _apiv2Resetsys = 0x32;
const _apiv2Readreg = 0x33;
const _apiv2Writereg = 0x34;
const _apiv2Writedebugreg = 0x35;
const _apiv2Readdebugreg = 0x36;
const _apiv2GetLastRwStatus = 0x3b;
const _apiv2DriveNrst = 0x3c;
const _apiv2GetLastRwStatus2 = 0x3e;
const _debugEnterSwd = 0xa3;

const _statusOk = 0x80;
const _statusNames = <int, String>{
  0x09: 'JTAG_GET_IDCODE_ERROR',
  0x10: 'SWD_AP_WAIT',
  0x11: 'SWD_AP_FAULT',
  0x12: 'SWD_AP_ERROR',
  0x14: 'SWD_DP_WAIT',
  0x15: 'SWD_DP_FAULT',
  0x16: 'SWD_DP_ERROR',
  0x19: 'SWD_AP_STICKY_ERROR',
  0x1a: 'SWD_AP_STICKYORUN_ERROR',
};

const regR0 = 0;
const regR1 = 1;
const regR2 = 2;
const regR3 = 3;
const regSp = 13;
const regPc = 15;
const regXpsr = 16;

const _modeDfu = 0x00;
const _maxRw32 = 1024;
const _cooperativeYieldBytes = _maxRw32;

class Stlink implements DebugProbe {
  Stlink(this._usb);

  final UsbTransport _usb;

  @override
  ProbeVersion version = ProbeVersion(0, 0, 0, '?');

  @override
  String get probeName => _usb.productName;

  @override
  bool get hasMem16 => _usb.isV3 || version.jtag >= 26;

  @override
  Future<void> init() async {
    await _readVersion();
    if (!_usb.isV3 && version.jtag < 15) {
      throw SwdException(
        'ST-Link firmware too old (J${version.jtag}); APIv2 needs J15+.',
      );
    }
    if (await _getCurrentMode() == _modeDfu) {
      await _usb.xfer([_cmdDfu, _dfuExit]);
      await sleep(50);
    }
  }

  Future<void> _readVersion() async {
    if (_usb.isV3) {
      final rx = await _usb.xfer([_cmdGetVersionV3], rxLen: 12);
      version = ProbeVersion(rx[0], rx[2], rx[1], 'V${rx[0]}J${rx[2]}');
      return;
    }
    final rx = await _usb.xfer([_cmdGetVersion], rxLen: 6);
    final value = (rx[0] << 8) | rx[1];
    final stlink = value >> 12;
    final jtag = (value >> 6) & 0x3f;
    version = ProbeVersion(stlink, jtag, value & 0x3f, 'V${stlink}J$jtag');
  }

  Future<int> _getCurrentMode() async {
    final rx = await _usb.xfer([_cmdGetCurrentMode], rxLen: 2);
    return rx[0];
  }

  @override
  Future<double?> getTargetVoltage() async {
    final rx = await _usb.xfer([_cmdGetTargetVoltage], rxLen: 8);
    final adcRef = u32le(rx, 0);
    final adcVdd = u32le(rx, 4);
    if (adcRef == 0) return null;
    return 2 * adcVdd * (1.2 / adcRef);
  }

  void _checkStatus(Uint8List rx, String what) {
    if (rx.isEmpty || rx[0] == _statusOk) return;
    final name = _statusNames[rx[0]] ?? 'unknown';
    throw SwdException(
      '$what failed: ST-Link status 0x${rx[0].toRadixString(16)} ($name)',
    );
  }

  @override
  Future<void> enterSwd() async {
    final rx = await _usb.xfer([
      _cmdDebug,
      _apiv2Enter,
      _debugEnterSwd,
    ], rxLen: 2);
    _checkStatus(rx, 'enter SWD');
  }

  @override
  Future<int> readIdcode() async {
    final rx = await _usb.xfer([_cmdDebug, _apiv2ReadIdcodes], rxLen: 12);
    _checkStatus(rx, 'read IDCODE');
    return u32le(rx, 4);
  }

  @override
  Future<void> resetSys() async {
    final rx = await _usb.xfer([_cmdDebug, _apiv2Resetsys], rxLen: 2);
    _checkStatus(rx, 'reset');
  }

  @override
  Future<void> driveNrst(int state) async {
    final rx = await _usb.xfer([_cmdDebug, _apiv2DriveNrst, state], rxLen: 2);
    _checkStatus(rx, 'drive nRST');
  }

  @override
  Future<int> readReg(int index) async {
    final rx = await _usb.xfer([_cmdDebug, _apiv2Readreg, index], rxLen: 8);
    _checkStatus(rx, 'read core reg $index');
    return u32le(rx, 4);
  }

  @override
  Future<void> writeReg(int index, int value) async {
    final rx = await _usb.xfer([
      _cmdDebug,
      _apiv2Writereg,
      index,
      ...u32(value),
    ], rxLen: 2);
    _checkStatus(rx, 'write core reg $index');
  }

  @override
  Future<int> readDebugReg(int address) async {
    final rx = await _usb.xfer([
      _cmdDebug,
      _apiv2Readdebugreg,
      ...u32(address),
    ], rxLen: 8);
    _checkStatus(rx, 'read ${hex(address)}');
    return u32le(rx, 4);
  }

  @override
  Future<void> writeDebugReg(int address, int value) async {
    final rx = await _usb.xfer([
      _cmdDebug,
      _apiv2Writedebugreg,
      ...u32(address),
      ...u32(value),
    ], rxLen: 2);
    _checkStatus(rx, 'write ${hex(address)}');
  }

  Future<void> _checkLastRwStatus(String what) async {
    final command = _usb.isV3 || version.jtag >= 15
        ? _apiv2GetLastRwStatus2
        : _apiv2GetLastRwStatus;
    final rx = await _usb.xfer([
      _cmdDebug,
      command,
    ], rxLen: command == _apiv2GetLastRwStatus2 ? 12 : 2);
    _checkStatus(rx, what);
  }

  @override
  Future<Uint8List> readMem32(int address, int length) async {
    if (address % 4 != 0 || length % 4 != 0) {
      throw SwdException('readMem32 requires 4-byte alignment');
    }
    final result = Uint8List(length);
    var done = 0;
    while (done < length) {
      final chunk = length - done < _maxRw32 ? length - done : _maxRw32;
      final rx = await _usb.xfer([
        _cmdDebug,
        _debugReadmem32,
        ...u32(address + done),
        ...u16(chunk),
      ], rxLen: chunk);
      if (rx.length != chunk) {
        throw SwdException('short read: ${rx.length}/$chunk');
      }
      result.setRange(done, done + chunk, rx);
      await _checkLastRwStatus('read ${hex(address + done)}');
      done += chunk;
      // Native libusb futures complete synchronously on Flutter's UI isolate.
      // Long dumps must periodically let animation frames run, without
      // yielding inside an individual ST-Link command/status transaction.
      if (done < length && done % _cooperativeYieldBytes == 0) {
        await sleep(0);
      }
    }
    return result;
  }

  @override
  Future<void> writeMem16(int address, Uint8List data) async {
    if (!hasMem16) {
      throw SwdException(
        'this ST-Link firmware does not support 16-bit writes',
      );
    }
    if (address % 2 != 0 || data.length % 2 != 0) {
      throw SwdException('writeMem16 requires 2-byte alignment');
    }
    await _usb.xfer([
      _cmdDebug,
      _debugWritemem16,
      ...u32(address),
      ...u16(data.length),
    ], data: data);
    await _checkLastRwStatus('write16 ${hex(address)}');
  }

  @override
  Future<void> writeMem32(int address, Uint8List data) async {
    if (address % 4 != 0 || data.length % 4 != 0) {
      throw SwdException('writeMem32 requires 4-byte alignment');
    }
    var done = 0;
    while (done < data.length) {
      final chunk = data.length - done < _maxRw32
          ? data.length - done
          : _maxRw32;
      await _usb.xfer([
        _cmdDebug,
        _debugWritemem32,
        ...u32(address + done),
        ...u16(chunk),
      ], data: Uint8List.sublistView(data, done, done + chunk));
      await _checkLastRwStatus('write ${hex(address + done)}');
      done += chunk;
    }
  }

  @override
  Future<void> close() async {
    try {
      await _usb.xfer([_cmdDebug, _debugExit]);
    } catch (_) {}
    await _usb.close();
  }
}
