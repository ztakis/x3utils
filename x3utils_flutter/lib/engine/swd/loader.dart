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

// Reserve the architectural maximum of 256 Cortex-M vector entries. Keeping
// the complete table in SRAM means an NMI or fault can never fetch a handler
// from flash while that flash is erased or only partly programmed.
const loaderVectorTableBytes = 0x400;
const _loaderExceptionStackBytes = 0x40;

const _loaderExceptionTrap = <int>[
  0x22ff, // movs r2, #0xff — distinguish an exception from normal completion
  0xbe02, // bkpt #2
  0xe7fe, // b . — fail closed if BKPT does not halt the core
];

const _vtor = 0xe000ed08;
const _dfsr = 0xe000ed30;
const _cfsr = 0xe000ed28;
const _hfsr = 0xe000ed2c;
const _icsr = 0xe000ed04;
const _crmCtrlsts = 0x40021024;
const _dbgmcuCr = 0xe0042004;
const _wdtBase = 0x40003000;

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

String decodeAt32ResetFlags(int value) {
  final causes = <String>[
    if (value & (1 << 31) != 0) 'low-power',
    if (value & (1 << 30) != 0) 'window-watchdog',
    if (value & (1 << 29) != 0) 'watchdog',
    if (value & (1 << 28) != 0) 'software',
    if (value & (1 << 27) != 0) 'power-on/reset',
    if (value & (1 << 26) != 0) 'nRST',
  ];
  return causes.isEmpty ? 'none' : causes.join('|');
}

Uint8List _loaderToBytes(List<int> code) {
  final bytes = Uint8List(((code.length * 2 + 3) >> 2) << 2);
  for (var i = 0; i < code.length; i++) {
    bytes[i * 2] = code[i] & 0xff;
    bytes[i * 2 + 1] = code[i] >> 8;
  }
  return bytes;
}

Uint8List _loaderVectorTable(int stackTop, int trapAddr) {
  final bytes = Uint8List(loaderVectorTableBytes);
  final words = ByteData.sublistView(bytes);
  words.setUint32(0, stackTop, Endian.little);
  for (var offset = 4; offset < bytes.length; offset += 4) {
    words.setUint32(offset, trapAddr | 1, Endian.little);
  }
  return bytes;
}

Future<void> runLoader(
  DebugProbe probe,
  CortexM core,
  List<int> code, {
  required int vectorTableAddr,
  required int loaderAddr,
  required int stackTop,
  required int srcAddr,
  required int dstAddr,
  required int count,
  required int flashRegBase,
  int timeoutMs = 10000,
  String? context,
  int? baselineResetFlags,
}) async {
  if (vectorTableAddr % loaderVectorTableBytes != 0) {
    throw SwdException('flash loader vector table must be 1 KiB-aligned');
  }
  if (stackTop % 8 != 0) {
    throw SwdException('flash loader stack must be 8-byte aligned');
  }

  final loaderBytes = _loaderToBytes(code);
  final trapBytes = _loaderToBytes(_loaderExceptionTrap);
  final trapAddr = loaderAddr + loaderBytes.length;
  final vectorTableEnd = vectorTableAddr + loaderVectorTableBytes;
  final trapEnd = trapAddr + trapBytes.length;
  if (loaderAddr % 4 != 0 || loaderAddr < vectorTableEnd) {
    throw SwdException('flash loader code overlaps its SRAM vector table');
  }
  if (trapEnd > stackTop - _loaderExceptionStackBytes) {
    throw SwdException('flash loader code overlaps its exception stack');
  }
  if (srcAddr % 4 != 0 || srcAddr < stackTop) {
    throw SwdException('flash loader source overlaps its protected SRAM area');
  }
  final loaderAndTrap = Uint8List(loaderBytes.length + trapBytes.length)
    ..setRange(0, loaderBytes.length, loaderBytes)
    ..setRange(
      loaderBytes.length,
      loaderBytes.length + trapBytes.length,
      trapBytes,
    );
  final originalVtor = await probe.readDebugReg(_vtor);
  var restoreVtorWhileHalted = false;

  await probe.writeMem32(
    vectorTableAddr,
    _loaderVectorTable(stackTop, trapAddr),
  );
  await probe.writeMem32(loaderAddr, loaderAndTrap);
  await probe.writeReg(regR0, srcAddr);
  await probe.writeReg(regR1, dstAddr);
  await probe.writeReg(regR2, count);
  await probe.writeReg(regR3, flashRegBase);
  await probe.writeReg(regSp, stackTop);
  await probe.writeReg(regPc, loaderAddr);
  await probe.writeReg(regXpsr, 0x01000000);

  await probe.writeDebugReg(_vtor, vectorTableAddr);
  restoreVtorWhileHalted = true;
  final installedVtor = await probe.readDebugReg(_vtor);
  if (installedVtor != vectorTableAddr) {
    try {
      await probe.writeDebugReg(_vtor, originalVtor);
    } finally {
      restoreVtorWhileHalted = false;
    }
    throw SwdException(
      'flash loader VTOR did not latch: wrote ${hex(vectorTableAddr)}, '
      'read ${hex(installedVtor)}',
    );
  }

  try {
    // From this point until a halt is observed, an AHB write to VTOR would be
    // unsafe because transport failure can leave the core running.
    restoreVtorWhileHalted = false;
    try {
      await core.resumeMasked();
    } catch (_) {
      try {
        restoreVtorWhileHalted = await core.isHalted();
      } catch (_) {}
      rethrow;
    }
    try {
      await core.waitHalted(timeoutMs);
      restoreVtorWhileHalted = true;
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
        restoreVtorWhileHalted = true;
      } catch (_) {}
      // Once the core has been stopped, collect a broad snapshot. Do not add
      // diagnostic traffic while the loader may still be running: on a marginal
      // target that traffic could itself change timing or obscure the failure.
      final r0 = forcedHalt ? await _tryRead(() => probe.readReg(regR0)) : null;
      final r1 = forcedHalt ? await _tryRead(() => probe.readReg(regR1)) : null;
      final r2 = forcedHalt ? await _tryRead(() => probe.readReg(regR2)) : null;
      final r3 = forcedHalt ? await _tryRead(() => probe.readReg(regR3)) : null;
      final sp = forcedHalt ? await _tryRead(() => probe.readReg(regSp)) : null;
      final lr = forcedHalt ? await _tryRead(() => probe.readReg(regLr)) : null;
      final pc = forcedHalt ? await _tryRead(() => probe.readReg(regPc)) : null;
      final xpsr = forcedHalt
          ? await _tryRead(() => probe.readReg(regXpsr))
          : null;
      final dfsr = forcedHalt
          ? await _tryRead(() => probe.readDebugReg(_dfsr))
          : null;
      final cfsr = forcedHalt
          ? await _tryRead(() => probe.readDebugReg(_cfsr))
          : null;
      final hfsr = forcedHalt
          ? await _tryRead(() => probe.readDebugReg(_hfsr))
          : null;
      final icsr = forcedHalt
          ? await _tryRead(() => probe.readDebugReg(_icsr))
          : null;
      final vtor = forcedHalt
          ? await _tryRead(() => probe.readDebugReg(_vtor))
          : null;
      final crmCtrlsts = forcedHalt
          ? await _tryRead(() => probe.readDebugReg(_crmCtrlsts))
          : null;
      final dbgmcuCr = forcedHalt
          ? await _tryRead(() => probe.readDebugReg(_dbgmcuCr))
          : null;
      final wdtDiv = forcedHalt
          ? await _tryRead(() => probe.readDebugReg(_wdtBase + 0x04))
          : null;
      final wdtRld = forcedHalt
          ? await _tryRead(() => probe.readDebugReg(_wdtBase + 0x08))
          : null;
      final wdtSts = forcedHalt
          ? await _tryRead(() => probe.readDebugReg(_wdtBase + 0x0c))
          : null;
      final wdtWin = forcedHalt
          ? await _tryRead(() => probe.readDebugReg(_wdtBase + 0x10))
          : null;
      final flashSts = forcedHalt
          ? await _tryRead(() => probe.readDebugReg(flashRegBase + 0x0c))
          : null;
      final flashCtrl = forcedHalt
          ? await _tryRead(() => probe.readDebugReg(flashRegBase + 0x10))
          : null;
      final flashAddr = forcedHalt
          ? await _tryRead(() => probe.readDebugReg(flashRegBase + 0x14))
          : null;
      final resetCause = crmCtrlsts == null
          ? 'unavailable'
          : decodeAt32ResetFlags(crmCtrlsts);
      final newResetCause = crmCtrlsts == null || baselineResetFlags == null
          ? 'unavailable'
          : decodeAt32ResetFlags(crmCtrlsts & ~baselineResetFlags);
      throw LoaderHaltTimeout(
        'flash loader${context == null ? "" : " ($context)"} did not halt '
        'within $timeoutMs ms; dst=${hex(dstAddr)}, count=$count, '
        '${_diagnostic("DHCSR-before-halt", runningDhcsr)}, '
        'forced-halt=${forcedHalt ? "yes" : "no"}, '
        // Latched across the whole run: DHCSR.S_RESET_ST clears on read, so the
        // poll loop above would otherwise have discarded it.
        'core-reset-seen=${core.sawCoreResetSinceResume ? "yes" : "no"}, '
        '${_diagnostic("r0", r0)}, ${_diagnostic("r1", r1)}, '
        '${_diagnostic("r2", r2)}, ${_diagnostic("r3", r3)}, '
        '${_diagnostic("SP", sp)}, ${_diagnostic("LR", lr)}, '
        '${_diagnostic("PC", pc)}, ${_diagnostic("xPSR", xpsr)}, '
        '${_diagnostic("DFSR", dfsr)}, '
        '${_diagnostic("CFSR", cfsr)}, ${_diagnostic("HFSR", hfsr)}, '
        '${_diagnostic("ICSR", icsr)}, '
        '${_diagnostic("VTOR-before", originalVtor)}, '
        '${_diagnostic("VTOR-at-timeout", vtor)}, '
        '${_diagnostic("CRM_CTRLSTS", crmCtrlsts)} '
        '(reset=$resetCause, new-since-baseline=$newResetCause), '
        '${_diagnostic("DBGMCU_CR", dbgmcuCr)}, '
        '${_diagnostic("WDT_DIV", wdtDiv)}, '
        '${_diagnostic("WDT_RLD", wdtRld)}, '
        '${_diagnostic("WDT_STS", wdtSts)}, '
        '${_diagnostic("WDT_WIN", wdtWin)}, '
        '${_diagnostic("FLASH_STS", flashSts)}, '
        '${_diagnostic("FLASH_CTRL", flashCtrl)}, '
        '${_diagnostic("FLASH_ADDR", flashAddr)}',
        forcedHalt: forcedHalt,
      );
    }

    final remaining = await probe.readReg(regR2);
    if (remaining != 0) {
      final xpsr = await probe.readReg(regXpsr);
      final exception = xpsr & 0x1ff;
      if (exception != 0) {
        throw SwdException(
          'flash loader trapped exception $exception at ${hex(dstAddr)} '
          '($remaining units left) — programming aborted',
        );
      }
      throw SwdException(
        'flash loader stopped early at ${hex(dstAddr)} '
        '($remaining units left) — programming error',
      );
    }
  } finally {
    if (restoreVtorWhileHalted) {
      await probe.writeDebugReg(_vtor, originalVtor);
      final restoredVtor = await probe.readDebugReg(_vtor);
      if (restoredVtor != originalVtor) {
        throw SwdException(
          'flash loader VTOR restore failed: wrote ${hex(originalVtor)}, '
          'read ${hex(restoredVtor)}',
        );
      }
    }
  }
}
