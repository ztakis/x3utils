import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:x3utils_flutter/engine/swd/probe.dart'
    show GuidedConnectEvent, GuidedConnectStage;
import 'package:x3utils_flutter/engine/swd/swd.dart';

const _demcr = 0xe000edfc;

class _RecordingProbe implements DebugProbe {
  _RecordingProbe({this.remaining = 0, this.fpu = false});

  final int remaining;
  final bool fpu;
  final registers = <int, int>{0xe000edf0: 1 << 17, 0x40022010: 1 << 9};
  final debugWrites = <(int, int)>[];
  final memoryWrites = <(int, List<int>)>[];
  final regWrites = <(int, int)>[];
  final nrstStates = <int>[];
  var _count = 0;
  var _halted = true;
  bool closed = false;
  int initCalls = 0;
  int closeCalls = 0;

  @override
  ProbeVersion get version => ProbeVersion(2, 37, 0, 'V2J37');

  @override
  String get probeName => 'fake';

  @override
  bool get hasMem16 => true;

  @override
  Future<void> init() async => initCalls++;

  @override
  Future<void> enterSwd() async {}

  @override
  Future<int> readIdcode() async => 0x2ba01477;

  @override
  Future<double?> getTargetVoltage() async => 3.3;

  @override
  Future<void> resetSys() async {}

  @override
  Future<void> driveNrst(int state) async => nrstStates.add(state);

  @override
  Future<int> readReg(int index) async =>
      index == 2 ? (_count == 0 ? 0 : remaining) : 0;

  @override
  Future<void> writeReg(int index, int value) async {
    if (index == 2) _count = value;
    regWrites.add((index, value));
  }

  @override
  Future<int> readDebugReg(int address) async {
    if (address == dhcsr) return _halted ? 1 << 17 : 0;
    if (address == 0xe000ef34) return fpu ? 1 : 0;
    return registers[address] ?? 0;
  }

  @override
  Future<void> writeDebugReg(int address, int value) async {
    debugWrites.add((address, value));
    if (address == dhcsr) {
      // A healthy injected loader reaches BKPT immediately after resume.
      _halted = true;
    } else if (address == 0x4002200c) {
      registers[address] = 0;
    } else if (address == 0x40021000 && value & 1 != 0) {
      registers[address] = value | 2;
    } else {
      registers[address] = value;
    }
  }

  @override
  Future<void> writeMem16(int address, Uint8List data) async {
    memoryWrites.add((address, data.toList()));
  }

  @override
  Future<Uint8List> readMem32(int address, int length) async =>
      Uint8List(length);

  @override
  Future<void> writeMem32(int address, Uint8List data) async {
    memoryWrites.add((address, data.toList()));
  }

  @override
  Future<void> close() async {
    closed = true;
    closeCalls++;
  }
}

class _UnderResetProbe extends _RecordingProbe {
  final connectEvents = <String>[];

  @override
  Future<void> driveNrst(int state) async {
    connectEvents.add('nRST $state');
    await super.driveNrst(state);
  }

  @override
  Future<void> enterSwd() async => connectEvents.add('enter SWD');

  @override
  Future<int> readIdcode() async {
    connectEvents.add('read IDCODE');
    return super.readIdcode();
  }

  @override
  Future<void> writeDebugReg(int address, int value) async {
    if (address == dhcsr) connectEvents.add('halt core');
    if (address == 0xe000edfc && value == 1) {
      connectEvents.add('arm reset catch');
    }
    if (address == 0xe000edfc && value == 0) {
      connectEvents.add('clear reset catch');
    }
    await super.writeDebugReg(address, value);
  }
}

class _FailingUnderResetProbe extends _RecordingProbe {
  @override
  Future<void> enterSwd() => Future<void>.error(SwdException('attach failed'));
}

class _GuidedProbe extends _UnderResetProbe {
  _GuidedProbe({this.armReadback = true});

  final bool armReadback;
  int enterCalls = 0;
  int _guidedDemcr = 0;

  @override
  Future<void> enterSwd() async {
    enterCalls++;
    await super.enterSwd();
  }

  @override
  Future<Uint8List> readMem32(int address, int length) async {
    if (address == _demcr && length == 4) {
      connectEvents.add('confirm reset catch');
      final value = armReadback ? _guidedDemcr : 0;
      return Uint8List.fromList([
        value & 0xff,
        (value >> 8) & 0xff,
        (value >> 16) & 0xff,
        (value >> 24) & 0xff,
      ]);
    }
    return super.readMem32(address, length);
  }

  @override
  Future<void> writeMem32(int address, Uint8List data) async {
    final value = data[0] | (data[1] << 8) | (data[2] << 16) | (data[3] << 24);
    if (address == dhcsr && value == 0xa05f0001) {
      connectEvents.add('enable debug');
    }
    if (address == _demcr) {
      _guidedDemcr = value;
      connectEvents.add(value == 1 ? 'arm reset catch' : 'clear reset catch');
    }
    await super.writeMem32(address, data);
  }

  @override
  Future<int> readDebugReg(int address) async {
    if (address == dhcsr) connectEvents.add('read halt status');
    return super.readDebugReg(address);
  }
}

class _RaceProbe extends _RecordingProbe {
  _RaceProbe({List<Object>? enterErrors, this.targetMisses = 0})
    : enterErrors = enterErrors ?? <Object>[];

  final List<Object> enterErrors;
  int targetMisses;
  int enterCalls = 0;

  @override
  Future<void> enterSwd() async {
    enterCalls++;
    if (enterErrors.isNotEmpty) throw enterErrors.removeAt(0);
  }

  @override
  Future<int> readDebugReg(int address) async {
    if (address == 0xe0042000 && targetMisses > 0) {
      targetMisses--;
      return 0;
    }
    return super.readDebugReg(address);
  }
}

class _EndlessRaceProbe extends _RecordingProbe {
  int enterCalls = 0;

  @override
  Future<void> enterSwd() async {
    enterCalls++;
    throw SwdException('enter SWD failed');
  }
}

class _DelayedInitRaceProbe extends _RecordingProbe {
  final initStarted = Completer<void>();
  final finishInit = Completer<void>();
  int enterCalls = 0;

  @override
  Future<void> init() async {
    initCalls++;
    initStarted.complete();
    await finishInit.future;
  }

  @override
  Future<void> enterSwd() async => enterCalls++;
}

class _ResetClearsWatchdogsProbe extends _RecordingProbe {
  final resetEvents = <String>[];

  @override
  Future<void> resetSys() async {
    resetEvents.add('system reset');
    registers[0xe0042004] = 0;
  }

  @override
  Future<void> writeDebugReg(int address, int value) async {
    await super.writeDebugReg(address, value);
    if (address == 0xe0042004) resetEvents.add('watchdog freeze');
  }
}

class _LoaderPreflightTimeoutProbe extends _RecordingProbe {
  _LoaderPreflightTimeoutProbe({this.forcedHaltSucceeds = true});

  final bool forcedHaltSucceeds;
  final flashEvents = <String>[];
  bool _loaderRunning = false;
  bool _sawFlashKey1 = false;
  bool _sawUsdKey1 = false;

  @override
  Future<int> readDebugReg(int address) async {
    if (address == dhcsr && _loaderRunning) return 0;
    return super.readDebugReg(address);
  }

  @override
  Future<void> writeDebugReg(int address, int value) async {
    if (address == dhcsr && value == 0xa05f0009) {
      _loaderRunning = true;
    } else if (address == dhcsr && value == 0xa05f0003) {
      if (forcedHaltSucceeds) _loaderRunning = false;
    }
    if (address == 0x40022010 && value == ((1 << 1) | (1 << 6))) {
      flashEvents.add('erase');
    }
    if (address == 0x40022004 && value == 0x45670123) {
      _sawFlashKey1 = true;
    } else if (address == 0x40022004 && value == 0xcdef89ab && _sawFlashKey1) {
      registers[0x40022010] = (registers[0x40022010] ?? 0) & ~(1 << 7);
      _sawFlashKey1 = false;
    }
    if (address == 0x40022008 && value == 0x45670123) {
      _sawUsdKey1 = true;
    } else if (address == 0x40022008 && value == 0xcdef89ab && _sawUsdKey1) {
      registers[0x40022010] = (registers[0x40022010] ?? 0) | (1 << 9);
      _sawUsdKey1 = false;
    }
    await super.writeDebugReg(address, value);
  }

  @override
  Future<void> writeMem32(int address, Uint8List data) async {
    if (address == 0x20000000) flashEvents.add('preflight');
    if (address >= 0x08000000 && address < 0x08020000) {
      flashEvents.add('direct-write');
    }
    await super.writeMem32(address, data);
  }
}

/// Reports `S_RESET_ST` on one poll while the injected routine is running, then
/// goes back to a plain not-halted status. This is what a target that restarts
/// mid-chunk looks like: the bit clears on read, so exactly one poll sees it.
class _LoaderResetDuringRunProbe extends _LoaderPreflightTimeoutProbe {
  bool _reportedReset = false;

  @override
  Future<int> readDebugReg(int address) async {
    if (address == dhcsr && _loaderRunning && !_reportedReset) {
      _reportedReset = true;
      return 1 << 25;
    }
    return super.readDebugReg(address);
  }
}

class _ProtectionProbe extends _RecordingProbe {
  _ProtectionProbe({
    this.failOptionWrite = false,
    this.failUsdUnlock = false,
    this.failRelock = false,
  }) {
    registers[0x40022010] = 1 << 7;
  }

  final bool failOptionWrite;
  final bool failUsdUnlock;
  final bool failRelock;
  bool _sawFlashKey1 = false;
  bool _sawUsdKey1 = false;

  @override
  Future<void> writeDebugReg(int address, int value) async {
    if (failRelock && address == 0x40022010 && value == 0x80) {
      debugWrites.add((address, value));
      throw SwdException('relock failed');
    }
    if (address == 0x40022004 && value == 0x45670123) {
      _sawFlashKey1 = true;
    } else if (address == 0x40022004 && value == 0xcdef89ab && _sawFlashKey1) {
      registers[0x40022010] = (registers[0x40022010] ?? 0) & ~(1 << 7);
      _sawFlashKey1 = false;
    }
    if (address == 0x40022008 && value == 0x45670123) {
      _sawUsdKey1 = true;
    } else if (address == 0x40022008 && value == 0xcdef89ab && _sawUsdKey1) {
      if (!failUsdUnlock) {
        registers[0x40022010] = (registers[0x40022010] ?? 0) | (1 << 9);
      }
      _sawUsdKey1 = false;
    }
    await super.writeDebugReg(address, value);
  }

  @override
  Future<void> writeMem16(int address, Uint8List data) async {
    await super.writeMem16(address, data);
    if (failOptionWrite) throw SwdException('option write failed');
  }
}

void main() {
  test(
    'protection rescue performs the exact USD erase and FAP-only rewrite',
    () async {
      final probe = _ProtectionProbe();
      final stages = <ProtectionRewriteStage>[];
      final driver = At32Flash(probe, CortexM(probe), 1024, 32 * 1024);

      await driver.rewriteFapUnlocked(onStage: stages.add);

      expect(
        probe.debugWrites,
        containsAllInOrder([
          (0x40022004, 0x45670123),
          (0x40022004, 0xcdef89ab),
          (0x40022008, 0x45670123),
          (0x40022008, 0xcdef89ab),
          (0x4002200c, 0x14),
          (0x40022010, 0x220),
          (0x40022010, 0x260),
          (0x40022010, 0x210),
          (0x40022010, 0x80),
        ]),
      );
      expect(probe.memoryWrites.single.$1, 0x1ffff800);
      expect(probe.memoryWrites.single.$2, [0xa5, 0x5a]);
      expect(stages, [
        ProtectionRewriteStage.usdErased,
        ProtectionRewriteStage.fapProgrammed,
      ]);
    },
  );

  test(
    'protection rescue tolerates the option-write reset as success',
    () async {
      final probe = _ProtectionProbe(failOptionWrite: true);
      final stages = <ProtectionRewriteStage>[];
      final driver = At32Flash(probe, CortexM(probe), 1024, 32 * 1024);

      // On a protected part the FAP write triggers the mass-erase and reset,
      // which faults the transfer. That fault is the success signature, not a
      // failure, so the rewrite completes both stages.
      await driver.rewriteFapUnlocked(onStage: stages.add);

      expect(stages, [
        ProtectionRewriteStage.usdErased,
        ProtectionRewriteStage.fapProgrammed,
      ]);
      expect(probe.memoryWrites.single.$1, 0x1ffff800);
      expect(probe.memoryWrites.single.$2, [0xa5, 0x5a]);
      // The reset makes the relock impossible; it is not attempted after the
      // fault, so no OPLK write follows.
      expect(probe.debugWrites, isNot(contains((0x40022010, 0x80))));
    },
  );

  test('protection rescue reset path emits no relock warning', () async {
    final lines = <String>[];
    final stages = <ProtectionRewriteStage>[];
    final probe = _ProtectionProbe(failOptionWrite: true, failRelock: true);
    final driver = At32Flash(
      probe,
      CortexM(probe),
      1024,
      32 * 1024,
      onLog: lines.add,
    );

    await driver.rewriteFapUnlocked(onStage: stages.add);

    expect(stages, contains(ProtectionRewriteStage.fapProgrammed));
    expect(lines.where((line) => line.contains('relock')), isEmpty);
  });

  test(
    'protection rescue relocks after a partial controller-unlock failure',
    () async {
      final probe = _ProtectionProbe(failUsdUnlock: true);
      final driver = At32Flash(probe, CortexM(probe), 1024, 32 * 1024);

      await expectLater(
        driver.rewriteFapUnlocked(onStage: (_) {}),
        throwsA(isA<SwdException>()),
      );

      expect(probe.memoryWrites, isEmpty);
      expect(probe.debugWrites.last, (0x40022010, 0x80));
    },
  );

  test('SRAM loader sets its register contract and masks interrupts', () async {
    final probe = _RecordingProbe();

    await runLoader(
      probe,
      CortexM(probe),
      wordLoader,
      loaderAddr: 0x20000000,
      srcAddr: 0x20000100,
      dstAddr: 0x08001000,
      count: 64,
      flashRegBase: 0x40022000,
    );

    expect(probe.memoryWrites.single.$1, 0x20000000);
    expect(probe.memoryWrites.single.$2, hasLength(36));
    expect(
      probe.regWrites,
      containsAllInOrder([
        (0, 0x20000100),
        (1, 0x08001000),
        (2, 64),
        (3, 0x40022000),
      ]),
    );
    expect(
      probe.debugWrites
          .where((write) => write.$1 == dhcsr)
          .map((write) => write.$2),
      containsAllInOrder([0xa05f000b, 0xa05f0009]),
    );
  });

  test('AT32 reset flags are decoded for loader diagnostics', () {
    expect(decodeAt32ResetFlags(0), 'none');
    expect(
      decodeAt32ResetFlags((1 << 29) | (1 << 28) | (1 << 26)),
      'watchdog|software|nRST',
    );
  });

  test(
    'loader timeout captures the halted core and peripheral state',
    () async {
      final probe = _LoaderPreflightTimeoutProbe()
        ..registers[0x40021024] = 1 << 29
        ..registers[0xe0042004] = 0x307
        ..registers[0x40003004] = 6
        ..registers[0x40003008] = 0x4e1
        ..registers[0x4000300c] = 0
        ..registers[0x40003010] = 0xfff
        ..registers[0x4002200c] = 0x20
        ..registers[0x40022014] = 0x08001000;

      await expectLater(
        runLoader(
          probe,
          CortexM(probe),
          wordLoader,
          loaderAddr: 0x20000000,
          srcAddr: 0x20000100,
          dstAddr: 0x08001000,
          count: 64,
          flashRegBase: 0x40022000,
          timeoutMs: 1,
          context: 'chunk 2/16',
          baselineResetFlags: 0,
        ),
        throwsA(
          isA<LoaderHaltTimeout>().having(
            (error) => error.message,
            'message',
            allOf([
              contains('chunk 2/16'),
              contains('dst=0x08001000, count=64'),
              contains('forced-halt=yes'),
              contains('r0='),
              contains('SP='),
              contains('LR='),
              contains('PC='),
              contains('reset=watchdog'),
              contains('new-since-baseline=watchdog'),
              contains('core-reset-seen=no'),
              contains('DBGMCU_CR=0x00000307'),
              contains('WDT_RLD=0x000004E1'),
              contains('FLASH_ADDR=0x08001000'),
            ]),
          ),
        ),
      );
    },
  );

  test(
    'a reset during the loader run is latched, not lost to the poll',
    () async {
      final probe = _LoaderResetDuringRunProbe();
      final core = CortexM(probe);

      await expectLater(
        runLoader(
          probe,
          core,
          wordLoader,
          loaderAddr: 0x20000000,
          srcAddr: 0x20000100,
          dstAddr: 0x08001000,
          count: 64,
          flashRegBase: 0x40022000,
          timeoutMs: 1,
          context: 'chunk 9/16',
        ),
        throwsA(
          isA<LoaderHaltTimeout>().having(
            (error) => error.message,
            'message',
            contains('core-reset-seen=yes'),
          ),
        ),
      );
      expect(
        core.sawCoreResetSinceResume,
        isTrue,
        reason: 'S_RESET_ST clears on read, so only the latch preserves it',
      );
    },
  );

  test('the reset latch clears at each masked resume', () async {
    final probe = _RecordingProbe();
    final core = CortexM(probe)..sawCoreResetSinceResume = true;

    await core.resumeMasked();

    expect(
      core.sawCoreResetSinceResume,
      isFalse,
      reason:
          'a stale bit from an earlier reset must not read as a restart '
          'during this run',
    );
  });

  test('non-zero loader remainder is a programming failure', () async {
    final probe = _RecordingProbe(remaining: 7);

    await expectLater(
      runLoader(
        probe,
        CortexM(probe),
        wordLoader,
        loaderAddr: 0x20000000,
        srcAddr: 0x20000100,
        dstAddr: 0x08001000,
        count: 64,
        flashRegBase: 0x40022000,
      ),
      throwsA(
        isA<SwdException>().having(
          (error) => error.message,
          'message',
          allOf(contains('stopped early'), contains('7 units left')),
        ),
      ),
    );
  });

  test('loader programming preflights then stages through SRAM', () async {
    final probe = _RecordingProbe();
    final driver = At32Flash(
      probe,
      CortexM(probe),
      1024,
      32 * 1024,
      useLoader: true,
    );

    await driver.program(0x08001000, Uint8List(0x400));

    expect(
      probe.memoryWrites.where((write) => write.$1 == 0x20000100).single.$2,
      hasLength(0x400),
    );
    expect(
      probe.regWrites.where((write) => write.$1 == 2).map((write) => write.$2),
      [0, 0x100],
      reason: 'count-zero preflight must precede the real loader run',
    );
    final ctrlWrites = probe.debugWrites
        .where((write) => write.$1 == 0x40022010)
        .map((write) => write.$2)
        .toList();
    expect(ctrlWrites, contains(1));
    expect(ctrlWrites.last & (1 << 7), 1 << 7);
  });

  test('opt-in loader diagnostics log baseline and every chunk', () async {
    final probe = _RecordingProbe()
      ..registers[0x40021024] = (1 << 29) | (1 << 27)
      ..registers[0xe0042004] = 0x307
      ..registers[0x40003004] = 6
      ..registers[0x40003008] = 0x4e1;
    final lines = <String>[];
    final driver = At32Flash(
      probe,
      CortexM(probe),
      1024,
      32 * 1024,
      useLoader: true,
      loaderDiagnostics: true,
      onLog: lines.add,
    );

    await driver.program(0x08000000, Uint8List(0x3000));

    expect(
      lines.first,
      allOf(
        startsWith('[flash:loader] baseline'),
        contains('reset=watchdog|power-on/reset'),
        contains('WDT_RLD=0x000004E1'),
      ),
    );
    expect(
      lines,
      containsAllInOrder([
        contains('chunk 1/2 start dst=0x08000000, bytes=8192'),
        contains('chunk 1/2 complete dst=0x08000000, bytes=8192'),
        contains('chunk 2/2 start dst=0x08002000, bytes=4096'),
        contains('chunk 2/2 complete dst=0x08002000, bytes=4096'),
      ]),
    );
  });

  test(
    'recoverable loader preflight timeout selects direct writes before erase',
    () async {
      final probe = _LoaderPreflightTimeoutProbe();
      final lines = <String>[];
      final driver = At32Flash(
        probe,
        CortexM(probe),
        1024,
        32 * 1024,
        useLoader: true,
        onLog: lines.add,
        loaderTimeoutMs: 1,
      );

      await driver.prepareProgram();
      await driver.erase(0x08000000, 4);
      await driver.program(0x08000000, Uint8List.fromList([1, 2, 3, 4]));

      expect(
        probe.flashEvents,
        containsAllInOrder(['preflight', 'erase', 'direct-write']),
      );
      expect(
        probe.regWrites
            .where((write) => write.$1 == 2)
            .map((write) => write.$2),
        [0],
        reason: 'the loader must not be launched again after erase',
      );
      expect(lines.single, contains('using direct word writes'));
    },
  );

  test(
    'unrecoverable loader preflight timeout remains fatal before erase',
    () async {
      final probe = _LoaderPreflightTimeoutProbe(forcedHaltSucceeds: false);
      final driver = At32Flash(
        probe,
        CortexM(probe),
        1024,
        32 * 1024,
        useLoader: true,
        loaderTimeoutMs: 1,
      );

      await expectLater(
        driver.prepareProgram(),
        throwsA(isA<LoaderHaltTimeout>()),
      );

      expect(probe.flashEvents, ['preflight']);
      expect(
        probe.debugWrites.where(
          (write) =>
              write.$1 == 0x40022010 && write.$2 == ((1 << 1) | (1 << 6)),
        ),
        isEmpty,
      );
    },
  );

  test('direct programming does not stage or resume target code', () async {
    final probe = _RecordingProbe();
    final driver = At32Flash(probe, CortexM(probe), 1024, 32 * 1024);

    await driver.program(0x08000000, Uint8List.fromList([1, 2, 3, 4]));

    expect(probe.memoryWrites.single.$1, 0x08000000);
    expect(probe.regWrites, isEmpty);
  });

  test('exact AT32F415CBT7 ID remains the only tested write target', () async {
    final probe = _RecordingProbe()..registers[0xe0042000] = 0x700301c5;

    final target = await detectTarget(probe, CortexM(probe));

    expect(target.family, 'AT32');
    expect(target.name, startsWith('AT32F415CBT7'));
    expect(target.flashKB, 128);
    expect(target.tested, isTrue);
  });

  test('shared F413/F415 ID with an FPU fails closed', () async {
    final probe = _RecordingProbe(fpu: true)
      ..registers[0xe0042000] = 0x700301c5;

    final target = await detectTarget(probe, CortexM(probe));

    expect(target.family, 'unknown');
    expect(target.tested, isFalse);
  });

  test('unknown AT32 ID is not treated as an F415-like device', () async {
    final probe = _RecordingProbe()..registers[0xe0042000] = 0x7003ffff;

    final target = await detectTarget(probe, CortexM(probe));

    expect(target.family, 'unknown');
    expect(target.flashKB, 0);
    expect(target.name, isNot(contains('assumed')));
  });

  test('reset-halt restores AT32 watchdog freeze before programming', () async {
    final debugProbe = _ResetClearsWatchdogsProbe()
      ..registers[0xe0042000] = 0x700301c5;
    final probe = Probe.withDebugProbe(debugProbe, useAt32Loader: true);
    await probe.connect(ConnectMode.normal);
    debugProbe.resetEvents.clear();

    await probe.resetHalt();

    expect(debugProbe.resetEvents, ['system reset', 'watchdog freeze']);
    expect(debugProbe.registers[0xe0042004], 0x307);
    await probe.disconnect();
  });

  test('genuine nRST attach catches the core at the reset vector', () async {
    final debugProbe = _UnderResetProbe()..registers[0xe0042000] = 0x700301c5;
    final lines = <String>[];
    final probe = Probe.withDebugProbe(debugProbe)..onLog(lines.add);

    await probe.connect(ConnectMode.underReset);

    expect(
      debugProbe.connectEvents,
      containsAllInOrder([
        'nRST 0',
        'enter SWD',
        'read IDCODE',
        'halt core',
        'arm reset catch',
        'nRST 1',
        'clear reset catch',
      ]),
    );
    expect(debugProbe.nrstStates, [0, 1]);
    expect(lines, contains('[connect] core halted at reset vector'));
    await probe.disconnect();
  });

  test('failed genuine nRST attach releases reset and disconnects', () async {
    final debugProbe = _FailingUnderResetProbe();
    final lines = <String>[];
    final probe = Probe.withDebugProbe(debugProbe)..onLog(lines.add);

    await expectLater(
      probe.connect(ConnectMode.underReset),
      throwsA(isA<SwdException>()),
    );

    expect(debugProbe.nrstStates, [0, 1]);
    expect(debugProbe.closed, isTrue);
    expect(lines, contains('[connect] nRST released after failed attach'));
  });

  test(
    'clone C45 enables debug under reset and observes the caught halt',
    () async {
      final debugProbe = _GuidedProbe()..registers[0xe0042000] = 0x700301c5;
      final guided = <GuidedConnectEvent>[];
      final probe = Probe.withDebugProbe(debugProbe)..onGuided(guided.add);

      final connecting = probe.connect(ConnectMode.guided, countdown: 0);
      await _waitFor(
        () => guided.any((e) => e.stage == GuidedConnectStage.hold),
      );

      expect(debugProbe.enterCalls, 0);
      expect(probe.continueConnect(), isTrue);
      await _waitFor(
        () => guided.any((e) => e.stage == GuidedConnectStage.release),
      );

      expect(debugProbe.nrstStates, isEmpty);
      expect(
        debugProbe.connectEvents,
        containsAllInOrder([
          'enter SWD',
          'read IDCODE',
          'enable debug',
          'arm reset catch',
          'confirm reset catch',
        ]),
      );
      expect(probe.continueConnect(), isTrue);

      await connecting;

      expect(debugProbe.enterCalls, 1);
      expect(
        debugProbe.connectEvents,
        containsAllInOrder([
          'enable debug',
          'arm reset catch',
          'confirm reset catch',
          'clear reset catch',
          'read halt status',
        ]),
      );
      expect(debugProbe.connectEvents, isNot(contains('read CPUID')));
      expect(debugProbe.memoryWrites.map((write) => write.$1), [
        dhcsr,
        _demcr,
        _demcr,
      ]);
      expect(debugProbe.memoryWrites.map((write) => write.$2), [
        [0x01, 0x00, 0x5f, 0xa0],
        [0x01, 0x00, 0x00, 0x00],
        [0x00, 0x00, 0x00, 0x00],
      ]);
      expect(
        guided
            .where((e) => e.stage == GuidedConnectStage.count)
            .single
            .countdown,
        0,
      );
      await probe.disconnect();
    },
  );

  test('clone C45 fails closed when reset catch does not arm', () async {
    final debugProbe = _GuidedProbe(armReadback: false)
      ..registers[0xe0042000] = 0x700301c5;
    final guided = <GuidedConnectEvent>[];
    final lines = <String>[];
    final probe = Probe.withDebugProbe(debugProbe)
      ..onGuided(guided.add)
      ..onLog(lines.add);

    final connecting = probe.connect(ConnectMode.guided, countdown: 0);
    await _waitFor(
      () => guided.any((event) => event.stage == GuidedConnectStage.hold),
    );
    expect(probe.continueConnect(), isTrue);

    await expectLater(connecting, throwsA(isA<SwdException>()));

    expect(debugProbe.enterCalls, 1);
    expect(
      debugProbe.connectEvents,
      containsAllInOrder([
        'enable debug',
        'arm reset catch',
        'confirm reset catch',
        'clear reset catch',
      ]),
    );
    expect(
      lines,
      contains(
        '[connect] clone C45 attach failed: '
        'VC_CORERESET did not arm while C45 was grounded',
      ),
    );
    expect(debugProbe.closed, isTrue);
  });

  test('clone C45 cancellation unblocks either operator gate', () async {
    final holdProbe = _GuidedProbe()..registers[0xe0042000] = 0x700301c5;
    final holdEvents = <GuidedConnectEvent>[];
    final holdSession = Probe.withDebugProbe(holdProbe)
      ..onGuided(holdEvents.add);
    final waitingForHold = holdSession.connect(
      ConnectMode.guided,
      countdown: 0,
    );
    await _waitFor(
      () => holdEvents.any((e) => e.stage == GuidedConnectStage.hold),
    );
    holdSession.abort();
    await expectLater(waitingForHold, throwsA(isA<SwdException>()));
    expect(holdProbe.enterCalls, 0);
    expect(holdProbe.nrstStates, isEmpty);

    final releaseProbe = _GuidedProbe()..registers[0xe0042000] = 0x700301c5;
    final releaseEvents = <GuidedConnectEvent>[];
    final releaseLines = <String>[];
    final releaseSession = Probe.withDebugProbe(releaseProbe)
      ..onGuided(releaseEvents.add)
      ..onLog(releaseLines.add);
    final waitingForRelease = releaseSession.connect(
      ConnectMode.guided,
      countdown: 0,
    );
    await _waitFor(
      () => releaseEvents.any((e) => e.stage == GuidedConnectStage.hold),
    );
    expect(releaseSession.continueConnect(), isTrue);
    await _waitFor(
      () => releaseEvents.any((e) => e.stage == GuidedConnectStage.release),
    );
    releaseSession.abort();
    final disconnecting = releaseSession.disconnect();
    await expectLater(waitingForRelease, throwsA(isA<SwdException>()));
    await disconnecting;
    await releaseSession.disconnect();
    expect(releaseProbe.closed, isTrue);
    expect(
      releaseLines.where((line) => line == '[probe] disconnected'),
      hasLength(1),
    );
  });

  test(
    'attach-race continues through misses until exact target catch',
    () async {
      final debugProbe = _RaceProbe(
        enterErrors: [SwdException('enter SWD failed')],
        targetMisses: 1,
      )..registers[0xe0042000] = 0x700301c5;
      final events = <RaceConnectEvent>[];
      final lines = <String>[];
      final probe = Probe.withDebugProbe(debugProbe)
        ..onRace(events.add)
        ..onLog(lines.add);

      final target = await probe.connect(ConnectMode.attachRace);

      expect(target.name, startsWith('AT32F415CBT7'));
      expect(debugProbe.enterCalls, 3);
      expect(debugProbe.initCalls, 3);
      expect(debugProbe.closeCalls, 2);
      expect(events.map((event) => event.caught), [false, false, true]);
      expect(events.map((event) => event.tier), [
        RaceConnectTier.searching,
        RaceConnectTier.nearCatch,
        RaceConnectTier.nearCatch,
      ]);
      expect(lines, contains('== caught on attempt 3; hold power =='));
      expect(
        lines,
        contains(
          '[race] warning: a catch confirms a halted SWD target, '
          'not independent target power',
        ),
      );
      expect(lines.where((line) => line.startsWith('[probe]')), hasLength(1));
      await probe.disconnect();
      expect(debugProbe.closeCalls, 3);
    },
  );

  test('attach-race classifies USB loss and timeout before catch', () async {
    final debugProbe = _RaceProbe(
      enterErrors: [
        SwdException('libusb bulk OUT failed: -4'),
        SwdException('libusb bulk OUT failed: -7'),
      ],
    )..registers[0xe0042000] = 0x700301c5;
    final events = <RaceConnectEvent>[];
    final probe = Probe.withDebugProbe(debugProbe)..onRace(events.add);

    await probe.connect(ConnectMode.attachRace);

    expect(events.map((event) => event.tier), [
      RaceConnectTier.adapterGone,
      RaceConnectTier.timedOut,
      RaceConnectTier.nearCatch,
    ]);
    expect(events.last.caught, isTrue);
    expect(debugProbe.initCalls, 3);
    expect(debugProbe.closeCalls, 2);
    await probe.disconnect();
  });

  test('attach-race cancellation stops attempts and disconnects', () async {
    final debugProbe = _EndlessRaceProbe();
    final events = <RaceConnectEvent>[];
    final probe = Probe.withDebugProbe(debugProbe)..onRace(events.add);

    final connecting = probe.connect(ConnectMode.attachRace);
    await _waitFor(() => events.isNotEmpty);
    probe.abort();

    await expectLater(connecting, throwsA(isA<SwdException>()));
    expect(debugProbe.closed, isTrue);
    expect(debugProbe.closeCalls, debugProbe.initCalls);
    final attemptsAfterStop = debugProbe.enterCalls;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(debugProbe.enterCalls, attemptsAfterStop);
  });

  test(
    'attach-race cancellation during open does not announce a probe',
    () async {
      final debugProbe = _DelayedInitRaceProbe();
      final lines = <String>[];
      final probe = Probe.withDebugProbe(debugProbe)..onLog(lines.add);

      final connecting = probe.connect(ConnectMode.attachRace);
      await debugProbe.initStarted.future;
      probe.abort();
      debugProbe.finishInit.complete();

      await expectLater(connecting, throwsA(isA<SwdException>()));
      expect(debugProbe.enterCalls, 0);
      expect(debugProbe.closeCalls, 1);
      expect(lines.where((line) => line.startsWith('[probe] fake')), isEmpty);
      expect(
        lines.where((line) => line == '[probe] disconnected'),
        hasLength(1),
      );
    },
  );
}

Future<void> _waitFor(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('condition was not reached');
}
