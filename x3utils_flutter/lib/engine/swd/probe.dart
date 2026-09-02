// Derived from swdart, MIT licensed. See third_party/swdart/LICENSE.
import 'dart:async';
import 'dart:typed_data';

import 'at32_flash.dart';
import 'cortexm.dart';
import 'debug_probe.dart';
import 'stlink.dart';
import 'targets.dart';
import 'transport.dart';
import 'transport_open.dart';
import 'util.dart';

enum ConnectMode { normal, underReset, guided, attachRace }

enum GuidedConnectStage { hold, count, release }

class GuidedConnectEvent {
  const GuidedConnectEvent(this.stage, {this.countdown});

  final GuidedConnectStage stage;
  final int? countdown;
}

enum RaceConnectTier { searching, noisy, nearCatch, adapterGone, timedOut }

class RaceConnectEvent {
  const RaceConnectEvent(this.attempt, this.tier, {this.caught = false});

  final int attempt;
  final RaceConnectTier tier;
  final bool caught;
}

enum FlashProgramStage { ready, erased, wrote, verified, resetRunning }

enum ProtectionRescueStage { usdErased, fapProgrammed }

const _flashBase = 0x08000000;
const _fallbackLength = 0x20000;
const _dbgmcuCr = 0xe0042004;

class Probe {
  Probe({this.useAt32Loader = false, this.loaderDiagnostics = false})
    : _providedProbe = null;

  Probe.withDebugProbe(
    DebugProbe debugProbe, {
    this.useAt32Loader = false,
    this.loaderDiagnostics = false,
  }) : _providedProbe = debugProbe;

  final DebugProbe? _providedProbe;
  final bool useAt32Loader;
  final bool loaderDiagnostics;

  UsbTransport? _usb;
  DebugProbe? _probe;
  CortexM? _core;
  TargetInfo? _target;
  FlashDriver? _driver;
  void Function(String line)? _log;
  void Function(GuidedConnectEvent event)? _guided;
  void Function(RaceConnectEvent event)? _race;
  Completer<void>? _continueGate;
  bool _stop = false;

  bool get isConnected => _probe != null;
  TargetInfo? get target => _target;
  String get probeName => _probe?.probeName ?? '?';
  bool get hasMem16 => _probe?.hasMem16 ?? false;

  void onLog(void Function(String line) sink) => _log = sink;
  void _emit(String line) => _log?.call(line);
  void onGuided(void Function(GuidedConnectEvent event) sink) => _guided = sink;
  void _emitGuided(GuidedConnectEvent event) => _guided?.call(event);
  void onRace(void Function(RaceConnectEvent event) sink) => _race = sink;
  void _emitRace(RaceConnectEvent event) => _race?.call(event);

  Future<TargetInfo> connect(ConnectMode mode, {int countdown = 0}) async {
    if (mode == ConnectMode.attachRace) return _connectRace();
    if (mode == ConnectMode.guided) {
      return _connectGuided(countdown.clamp(0, 10));
    }
    await _openProbe();
    final probe = _probe!;
    final underReset = mode == ConnectMode.underReset;
    var resetMayBeAsserted = false;
    var vectorCatchMayBeArmed = false;
    try {
      if (underReset) {
        _emit('[connect] genuine nRST: asserting reset');
        // A failed command response can still leave the physical output low.
        resetMayBeAsserted = true;
        await probe.driveNrst(0);
      }
      await probe.enterSwd();
      final idcode = await probe.readIdcode();
      _emit('[connect] SWD IDCODE ${hex(idcode)}');
      _core = CortexM(probe);
      if (underReset) {
        await _core!.halt();
        // Catch the first instruction after the continuously connected nRST
        // wire is released by software.
        vectorCatchMayBeArmed = true;
        await probe.writeDebugReg(demcr, 1);
        await probe.driveNrst(1);
        resetMayBeAsserted = false;
        await _core!.waitHalted();
        await probe.writeDebugReg(demcr, 0);
        vectorCatchMayBeArmed = false;
        _emit('[connect] core halted at reset vector');
      }
      return await _finishAttach();
    } catch (error, stackTrace) {
      if (resetMayBeAsserted) {
        try {
          await probe.driveNrst(1);
          _emit('[connect] nRST released after failed attach');
        } catch (_) {
          _emit(
            '[connect] warning: could not release nRST after failed attach',
          );
        }
      }
      if (vectorCatchMayBeArmed) {
        try {
          await probe.writeDebugReg(demcr, 0);
        } catch (_) {}
      }
      await disconnect();
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<TargetInfo> _connectRace() async {
    _stop = false;
    var attempt = 0;
    var probeAnnounced = false;
    for (;;) {
      _throwIfRaceStopped();
      attempt++;
      var tier = RaceConnectTier.searching;
      try {
        // Do not announce an asynchronously opened probe until cancellation
        // has been checked. Otherwise a cancelled race can log a new probe
        // session after its disconnect line.
        await _openProbe(announce: false);
        _throwIfRaceStopped();
        final probe = _probe!;
        if (!probeAnnounced) {
          _announceProbe(probe);
          _emit(
            '[race] warning: a catch confirms a halted SWD target, '
            'not independent target power',
          );
          probeAnnounced = true;
        }

        // This probe reports its own rail as Vtarget, so it cannot distinguish
        // main target power from SWD parasitic power. Race the proven x3utils
        // way and treat a catch only as evidence that the core was halted.
        _throwIfRaceStopped();
        await probe.enterSwd();
        tier = RaceConnectTier.noisy;
        final idcode = await probe.readIdcode();
        if (idcode == 0 || idcode == 0xffffffff) {
          throw SwdException('invalid SWD IDCODE ${hex(idcode)}');
        }

        tier = RaceConnectTier.nearCatch;
        _core = CortexM(probe);
        await _core!.halt();
        await _core!.waitHalted(1500);
        final target = await detectTarget(probe, _core!);
        if (target.family != 'AT32' ||
            !target.name.startsWith('AT32F415') ||
            target.flashKB == 0) {
          throw SwdException('race reached unsupported target: ${target.name}');
        }

        _emit('== caught on attempt $attempt; hold power ==');
        _emitRace(
          RaceConnectEvent(attempt, RaceConnectTier.nearCatch, caught: true),
        );
        return await _finishAttach(target);
      } catch (error) {
        _core = null;
        _target = null;
        _driver = null;
        if (_stop) {
          await disconnect();
          throw SwdException('attach-race aborted');
        }
        final classified = _classifyRaceError(error, tier);
        _emitRace(RaceConnectEvent(attempt, classified));
        if (attempt % 20 == 0) _emit('[race] $attempt attempts…');
        // Match x3utils Power-race: every miss gets a completely fresh
        // ST-Link/libusb session. Re-entering SWD in a stale session can spin
        // forever after the target firmware removes the debug port.
        await _closeRaceAttempt();
        // A fresh native USB open naturally yields; keep injected/WebUSB-fast
        // attempts cancellable too without adding an inter-attempt delay.
        await sleep(0);
      }
    }
  }

  void _throwIfRaceStopped() {
    if (_stop) throw SwdException('attach-race aborted');
  }

  Future<void> _closeRaceAttempt() async {
    final probe = _probe;
    final usb = _usb;
    _probe = null;
    _core = null;
    _target = null;
    _driver = null;
    _usb = null;
    try {
      if (probe != null) {
        await probe.close();
      } else {
        await usb?.close();
      }
    } catch (_) {}
  }

  RaceConnectTier _classifyRaceError(Object error, RaceConnectTier reached) {
    final message = '$error'.toLowerCase();
    if (message.contains('no st-link') ||
        message.contains('open failed') ||
        message.contains('no device') ||
        message.contains('failed: -4')) {
      return RaceConnectTier.adapterGone;
    }
    if (message.contains('timed out') ||
        message.contains('timeout') ||
        message.contains('failed: -7')) {
      return RaceConnectTier.timedOut;
    }
    return reached;
  }

  Future<TargetInfo> _connectGuided(int countdown) async {
    _stop = false;
    var vectorCatchMayBeArmed = false;
    try {
      _emit('[connect] clone C45: hold reset to GND');
      _emitGuided(const GuidedConnectEvent(GuidedConnectStage.hold));
      await _waitContinue();
      for (var remaining = countdown; remaining > 0; remaining--) {
        _throwIfStopped();
        _emitGuided(
          GuidedConnectEvent(GuidedConnectStage.count, countdown: remaining),
        );
        await sleep(1000);
      }
      _throwIfStopped();
      _emitGuided(
        const GuidedConnectEvent(GuidedConnectStage.count, countdown: 0),
      );

      // Match x3utils guided_connect: initialize SWD while the operator keeps
      // C45/nRST grounded, then arm vector catch without driving nRST through
      // the probe (clone probes do not provide a usable reset output).
      await _openProbe();
      final probe = _probe!;
      await probe.enterSwd();
      final idcode = await probe.readIdcode();
      _emit('[connect] SWD IDCODE ${hex(idcode)}');
      _core = CortexM(probe);

      // OpenOCD completes this setup while the operator still holds C45/nRST
      // low. Enabling C_DEBUGEN before release keeps the debug port attached
      // long enough for vector catch to halt the first instruction.
      await probe.writeMem32(dhcsr, Uint8List.fromList(u32(0xa05f0001)));
      vectorCatchMayBeArmed = true;
      await probe.writeMem32(demcr, Uint8List.fromList(u32(1)));
      final armedBytes = await probe.readMem32(demcr, 4);
      if (armedBytes.length != 4) {
        throw SwdException(
          'short DEMCR read while arming reset catch: '
          '${armedBytes.length}/4',
        );
      }
      final armed = u32le(armedBytes, 0);
      if (armed & 1 == 0) {
        throw SwdException('VC_CORERESET did not arm while C45 was grounded');
      }
      _emit('[connect] clone C45: reset catch armed');

      _emitGuided(const GuidedConnectEvent(GuidedConnectStage.release));
      await _waitContinue();
      _throwIfStopped();

      // The working OpenOCD path does not reconnect or re-examine here. Its
      // arp_examine command is a no-op because the target was already examined
      // under reset. Clear vector catch first, then observe the caught halt.
      await probe.writeMem32(demcr, Uint8List.fromList(u32(0)));
      vectorCatchMayBeArmed = false;
      await _core!.waitHalted();
      _emit('[connect] core halted at reset vector');
      return await _finishAttach();
    } catch (error, stackTrace) {
      _emit('[connect] clone C45 attach failed: $error');
      final probe = _probe;
      if (vectorCatchMayBeArmed && probe != null) {
        try {
          await probe.writeMem32(demcr, Uint8List.fromList(u32(0)));
        } catch (_) {}
      }
      await disconnect();
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _waitContinue() async {
    _throwIfStopped();
    final gate = Completer<void>();
    _continueGate = gate;
    try {
      await gate.future;
    } finally {
      if (identical(_continueGate, gate)) _continueGate = null;
    }
    _throwIfStopped();
  }

  void _throwIfStopped() {
    if (_stop) throw SwdException('guided C45 attach aborted');
  }

  bool continueConnect() {
    final gate = _continueGate;
    if (gate == null || gate.isCompleted) return false;
    gate.complete();
    return true;
  }

  void abort() {
    _stop = true;
    final gate = _continueGate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  Future<void> _openProbe({bool announce = true}) async {
    if (_probe != null) return;
    final provided = _providedProbe;
    if (provided != null) {
      await provided.init();
      _probe = provided;
      if (announce) _announceProbe(provided);
      return;
    }
    _usb = await openSelectedStlink();
    final stlink = Stlink(_usb!);
    await stlink.init();
    _probe = stlink;
    if (announce) _announceProbe(stlink);
  }

  void _announceProbe(DebugProbe probe) {
    _emit(
      '[probe] ${probe.probeName} (${probe.version.text})'
      '${probe.hasMem16 ? ", 16-bit" : ""}',
    );
  }

  Future<TargetInfo> _finishAttach([TargetInfo? detected]) async {
    final probe = _probe!;
    final target = detected ?? await detectTarget(probe, _core!);
    _target = target;
    if (target.family == 'AT32') {
      await _freezeWatchdogs(probe);
      _driver = At32Flash(
        probe,
        _core!,
        target.pageSize,
        target.sramBytes,
        useLoader: useAt32Loader,
        onLog: _emit,
        loaderDiagnostics: loaderDiagnostics,
      );
      _emit(
        '[flash] AT32 programming path: '
        '${useAt32Loader ? "SRAM loader (experimental)" : "direct word writes"}',
      );
    } else {
      _driver = null;
    }
    _emit('[target] ${target.name}');
    final voltage = await probe.getTargetVoltage().catchError((_) => null);
    if (voltage != null) {
      _emit('[target] Vtarget ${voltage.toStringAsFixed(2)} V');
    }
    return target;
  }

  Future<void> _freezeWatchdogs(DebugProbe probe) async {
    try {
      final current = await probe.readDebugReg(_dbgmcuCr);
      await probe.writeDebugReg(_dbgmcuCr, current | 0x307);
      _emit('[debug] watchdogs frozen while halted');
    } catch (_) {}
  }

  CortexM get _c {
    final core = _core;
    if (core == null) throw SwdException('not connected');
    return core;
  }

  DebugProbe get _p {
    final probe = _probe;
    if (probe == null) throw SwdException('not connected');
    return probe;
  }

  FlashDriver get _drv {
    if (!isConnected) throw SwdException('not connected');
    final driver = _driver;
    if (driver == null) {
      throw SwdException('no AT32 flash driver for ${_target?.name}');
    }
    return driver;
  }

  Future<void> resetHalt() async {
    await _c.resetHalt();
    await _freezeWatchdogs(_p);
    _emit('[target] reset halt');
  }

  Future<void> resetRun({
    void Function(FlashProgramStage stage)? onStage,
  }) async {
    await _c.resetRun();
    _emit('[target] reset, running');
    onStage?.call(FlashProgramStage.resetRunning);
  }

  Future<Uint8List> readMemory(int address, int length) async {
    if (length == 0) return Uint8List(0);
    final start = address & ~3;
    final end = (address + length + 3) & ~3;
    final raw = await _p.readMem32(start, end - start);
    return Uint8List.sublistView(
      raw,
      address - start,
      address - start + length,
    );
  }

  Future<Uint8List> readFlash({int? address, int? length}) async {
    await _c.halt();
    final base = address ?? _target?.flashBase ?? _flashBase;
    final kb = _target?.flashKB ?? 0;
    final readLength = length ?? (kb > 0 ? kb * 1024 : _fallbackLength);
    _emit('[flash] reading $readLength bytes from ${hex(base)}');
    return readMemory(base, readLength);
  }

  Future<Uint8List> readSram({int address = 0x20000000, int? length}) async {
    await _c.halt();
    final readLength = length ?? _target?.sramBytes ?? 0;
    if (readLength <= 0) throw SwdException('target SRAM size is unknown');
    _emit('[sram] reading $readLength bytes from ${hex(address)}');
    return readMemory(address, readLength);
  }

  Future<void> program(
    int address,
    Uint8List data, {
    bool eraseFirst = true,
    bool verify = true,
    ProgressFn? progress,
    void Function(FlashProgramStage stage)? onStage,
  }) async {
    await resetHalt();
    // Prove the selected programming mechanism while flash is still intact.
    // A recoverable SRAM-loader preflight failure can safely select direct
    // writes here; no fallback is attempted after erase/programming begins.
    await _drv.prepareProgram();
    _emit('[flash] programming path ready');
    onStage?.call(FlashProgramStage.ready);
    if (eraseFirst) {
      await _drv.erase(address, data.length, progress);
      _emit('[flash] erased');
      onStage?.call(FlashProgramStage.erased);
    }
    await _drv.program(address, data, progress);
    _emit('[flash] wrote ${data.length} bytes');
    onStage?.call(FlashProgramStage.wrote);
    if (verify) {
      await _drv.verify(address, data, progress);
      _emit('[flash] verified');
      onStage?.call(FlashProgramStage.verified);
    }
  }

  Future<void> rescueProtection({
    required void Function(ProtectionRescueStage stage) onStage,
  }) async {
    await _c.halt();
    final driver = _drv;
    if (driver is! At32Flash) {
      throw SwdException('no AT32 protection driver for ${_target?.name}');
    }
    await driver.rewriteFapUnlocked(
      onStage: (stage) {
        switch (stage) {
          case ProtectionRewriteStage.usdErased:
            _emit('[protection] user-system-data erased');
            onStage(ProtectionRescueStage.usdErased);
          case ProtectionRewriteStage.fapProgrammed:
            _emit('[protection] FAP halfword programmed: 0x5AA5');
            onStage(ProtectionRescueStage.fapProgrammed);
        }
      },
    );
  }

  Future<void> disconnect() async {
    final probe = _probe;
    if (probe == null && _usb == null) return;
    // Claim the session before awaiting close so concurrent cancel/finally
    // cleanup cannot close it twice or emit duplicate disconnect evidence.
    _probe = null;
    _core = null;
    _target = null;
    _driver = null;
    _usb = null;
    try {
      await probe?.close();
    } catch (_) {}
    _emit('[probe] disconnected');
  }
}
