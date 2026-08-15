// Derived from swdart, MIT licensed. See third_party/swdart/LICENSE.
import 'debug_probe.dart';
import 'util.dart';

const dhcsr = 0xe000edf0;
const demcr = 0xe000edfc;
const aircr = 0xe000ed0c;

const _dbgkey = 0xa05f0000;
const _cDebugen = 1 << 0;
const _cHalt = 1 << 1;
const _cMaskints = 1 << 3;
const _sHalt = 1 << 17;
const _vcCorereset = 1 << 0;
const _aircrSysresetreq = 0x05fa0004;

class CortexM {
  CortexM(this._probe);

  final DebugProbe _probe;

  Future<bool> isHalted() async =>
      (await _probe.readDebugReg(dhcsr) & _sHalt) != 0;

  Future<void> halt() =>
      _probe.writeDebugReg(dhcsr, _dbgkey | _cDebugen | _cHalt);

  Future<void> resumeMasked() async {
    if (!await isHalted()) {
      throw SwdException('core must be halted before masked resume');
    }
    await _probe.writeDebugReg(
      dhcsr,
      _dbgkey | _cDebugen | _cHalt | _cMaskints,
    );
    await _probe.writeDebugReg(dhcsr, _dbgkey | _cDebugen | _cMaskints);
  }

  Future<void> waitHalted([int timeoutMs = 3000]) async {
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    while (DateTime.now().isBefore(deadline)) {
      if (await isHalted()) return;
      await sleep(5);
    }
    throw SwdException('core did not halt within $timeoutMs ms');
  }

  Future<void> resetHalt() async {
    await halt();
    await _probe.writeDebugReg(demcr, _vcCorereset);
    await _probe.resetSys();
    await waitHalted();
    await _probe.writeDebugReg(demcr, 0);
  }

  Future<void> resetRun() async {
    await _probe.writeDebugReg(demcr, 0);
    await _probe.writeDebugReg(dhcsr, _dbgkey | _cDebugen);
    await _probe.writeDebugReg(aircr, _aircrSysresetreq);
  }

  Future<bool> hasFpu() async => (await _probe.readDebugReg(0xe000ef34)) != 0;
}
