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
const _sResetSt = 1 << 25;
const _vcCorereset = 1 << 0;
const _aircrSysresetreq = 0x05fa0004;

class CortexM {
  CortexM(this._probe);

  final DebugProbe _probe;

  /// True when any [isHalted] poll saw `DHCSR.S_RESET_ST` since the last
  /// [resumeMasked].
  ///
  /// That bit means "the core was reset since this register was last read",
  /// and it CLEARS ON READ. The loader's own wait loop polls `DHCSR` every few
  /// milliseconds, so it destroys the evidence long before a timeout snapshot
  /// can look for it. Latching it here is the only way to tell a target that
  /// restarted mid-run from one that merely left the injected routine.
  ///
  /// Read it as "a reset was seen since the masked resume", not "this call saw
  /// one": every [isHalted] caller feeds the same flag.
  bool sawCoreResetSinceResume = false;

  Future<bool> isHalted() async {
    final status = await _probe.readDebugReg(dhcsr);
    if (status & _sResetSt != 0) sawCoreResetSinceResume = true;
    return status & _sHalt != 0;
  }

  Future<void> halt() =>
      _probe.writeDebugReg(dhcsr, _dbgkey | _cDebugen | _cHalt);

  Future<void> resumeMasked() async {
    if (!await isHalted()) {
      throw SwdException('core must be halted before masked resume');
    }
    // The check above already read DHCSR, which drains any sticky reset bit
    // left by an earlier reset. Clearing here means a latched flag afterwards
    // can only come from a restart during the injected run.
    sawCoreResetSinceResume = false;
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
