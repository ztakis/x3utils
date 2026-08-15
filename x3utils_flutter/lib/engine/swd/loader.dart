// Derived from swdart, MIT licensed. See third_party/swdart/LICENSE.
import 'dart:typed_data';

import 'cortexm.dart';
import 'debug_probe.dart';
import 'stlink.dart';
import 'util.dart';

const wordLoader = <int>[
  0x2a00,
  0xd00c,
  0x6804,
  0x600c,
  0x68dd,
  0x2601,
  0x4235,
  0xd1fb,
  0x2614,
  0x4235,
  0xd104,
  0x3004,
  0x3104,
  0x3a01,
  0xe7f0,
  0xbe00,
  0xbe01,
];

const _dfsr = 0xe000ed30;
const _cfsr = 0xe000ed28;
const _hfsr = 0xe000ed2c;
const _icsr = 0xe000ed04;
const _crmCtrlsts = 0x40021024;

class LoaderHaltTimeout extends SwdException {
  LoaderHaltTimeout(super.message, {required this.forcedHalt});

  final bool forcedHalt;
}

Future<int?> _tryRead(Future<int> Function() read) async {
  try {
    return await read();
  } catch (_) {
    return null;
  }
}

String _diagnostic(String name, int? value) =>
    '$name=${value == null ? "unavailable" : hex(value)}';

Uint8List _loaderToBytes(List<int> code) {
  final bytes = Uint8List(((code.length * 2 + 3) >> 2) << 2);
  for (var i = 0; i < code.length; i++) {
    bytes[i * 2] = code[i] & 0xff;
    bytes[i * 2 + 1] = code[i] >> 8;
  }
  return bytes;
}

Future<void> runLoader(
  DebugProbe probe,
  CortexM core,
  List<int> code, {
  required int loaderAddr,
  required int srcAddr,
  required int dstAddr,
  required int count,
  required int flashRegBase,
  int timeoutMs = 10000,
}) async {
  await probe.writeMem32(loaderAddr, _loaderToBytes(code));
  await probe.writeReg(regR0, srcAddr);
  await probe.writeReg(regR1, dstAddr);
  await probe.writeReg(regR2, count);
  await probe.writeReg(regR3, flashRegBase);
  await probe.writeReg(regSp, srcAddr);
  await probe.writeReg(regPc, loaderAddr);
  await probe.writeReg(regXpsr, 0x01000000);

  await core.resumeMasked();
  try {
    await core.waitHalted(timeoutMs);
  } on SwdException catch (error) {
    // Transport/probe errors must remain fatal. Only a genuine wait timeout
    // gets the diagnostic forced-halt recovery used by preflight fallback.
    if (!error.message.startsWith('core did not halt within ')) rethrow;
    final runningDhcsr = await _tryRead(() => probe.readDebugReg(dhcsr));
    var forcedHalt = false;
    try {
      await core.halt();
      await core.waitHalted(500);
      forcedHalt = true;
    } catch (_) {}
    final pc = await _tryRead(() => probe.readReg(regPc));
    final xpsr = await _tryRead(() => probe.readReg(regXpsr));
    final remaining = await _tryRead(() => probe.readReg(regR2));
    final dfsr = await _tryRead(() => probe.readDebugReg(_dfsr));
    final cfsr = await _tryRead(() => probe.readDebugReg(_cfsr));
    final hfsr = await _tryRead(() => probe.readDebugReg(_hfsr));
    final icsr = await _tryRead(() => probe.readDebugReg(_icsr));
    final crmCtrlsts = await _tryRead(() => probe.readDebugReg(_crmCtrlsts));
    final flashSts = await _tryRead(
      () => probe.readDebugReg(flashRegBase + 0x0c),
    );
    throw LoaderHaltTimeout(
      'flash loader did not halt within $timeoutMs ms; '
      '${_diagnostic("DHCSR-before-halt", runningDhcsr)}, '
      'forced-halt=${forcedHalt ? "yes" : "no"}, '
      '${_diagnostic("PC", pc)}, ${_diagnostic("xPSR", xpsr)}, '
      '${_diagnostic("r2", remaining)}, ${_diagnostic("DFSR", dfsr)}, '
      '${_diagnostic("CFSR", cfsr)}, ${_diagnostic("HFSR", hfsr)}, '
      '${_diagnostic("ICSR", icsr)}, '
      '${_diagnostic("CRM_CTRLSTS", crmCtrlsts)}, '
      '${_diagnostic("FLASH_STS", flashSts)}',
      forcedHalt: forcedHalt,
    );
  }

  final remaining = await probe.readReg(regR2);
  if (remaining != 0) {
    throw SwdException(
      'flash loader stopped early at ${hex(dstAddr)} '
      '($remaining units left) — programming error',
    );
  }
}
