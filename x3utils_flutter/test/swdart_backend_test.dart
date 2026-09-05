import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:x3utils_flutter/app_controller.dart';
import 'package:x3utils_flutter/engine/android_backup_store.dart';
import 'package:x3utils_flutter/engine/desktop_backend_router.dart';
import 'package:x3utils_flutter/engine/device_spec.dart';
import 'package:x3utils_flutter/engine/firmware.dart';
import 'package:x3utils_flutter/engine/extra_backup_metadata.dart';
import 'package:x3utils_flutter/engine/hardware_backend.dart';
import 'package:x3utils_flutter/engine/pack_zip3.dart';
import 'package:x3utils_flutter/engine/swd/probe.dart'
    show GuidedConnectEvent, GuidedConnectStage;
import 'package:x3utils_flutter/engine/swd/transport.dart';
import 'package:x3utils_flutter/engine/swdart_backend.dart';
import 'package:x3utils_flutter/engine/swd/swd.dart' as swd;
import 'package:x3utils_flutter/models.dart';

swd.TargetInfo _target({
  String name = 'AT32F415CBT7 (128 KB, 1024 B pages)',
  String family = 'AT32',
  int flashKB = 128,
  int pageSize = 1024,
  bool tested = true,
}) => swd.TargetInfo(
  name: name,
  family: family,
  idcode: 0x700301c5,
  flashKB: flashKB,
  pageSize: pageSize,
  sramBytes: 32 * 1024,
  flashBase: 0x08000000,
  programAlign: 4,
  protection: 'FAP',
  rdpDisableValue: 0xa5,
  tested: tested,
);

Uint8List _image([int length = Firmware.expectedSize]) =>
    Uint8List.fromList(List<int>.generate(length, (index) => index % 251));

Uint8List _identifiedImage({String banner = 'SCOOTER_VCU_xxG3'}) {
  final bytes = _image();
  bytes.setRange(
    kSlotBannerOffset,
    kSlotBannerOffset + kBannerLength,
    banner.codeUnits,
  );
  return bytes;
}

Uint8List _identifiedCompatImage({
  int versionValue = 0x155,
  String banner = 'SCOOTER_VCU_xxG3',
}) {
  final bytes = _identifiedImage(banner: banner);
  const at = 0x3000;
  final i = (versionValue >> 11) & 1;
  final imm3 = (versionValue >> 8) & 7;
  final imm8 = versionValue & 0xff;
  final hw1 = 0xf240 | (i << 10);
  final hw2 = (imm3 << 12) | imm8;
  bytes.setRange(at, at + 4, [hw1 & 0xff, hw1 >> 8, hw2 & 0xff, hw2 >> 8]);
  return bytes;
}

Uint8List _identifiedVcuSram({int versionValue = 0x155}) {
  final bytes = Uint8List(32 * 1024);
  const offset = 0x420;
  bytes[offset] = 0x5c;
  bytes[offset + 1] = 0x50;
  bytes.setRange(offset + 0x20, offset + 0x2e, '1CGC1234567890'.codeUnits);
  // Real firmware stores the whole nibble-packed `0xMmp`, major nibble
  // included; the parser no longer invents a major 1 for a sub-0x100 halfword.
  bytes[offset + 0x2e] = versionValue & 0xff;
  bytes[offset + 0x2f] = versionValue >> 8;
  return bytes;
}

Uint8List _identifiedMcuSram({required int versionValue}) {
  final bytes = Uint8List(32 * 1024);
  const offset = 0x420;
  bytes[offset] = 0x5c;
  bytes[offset + 1] = 0x51;
  bytes.setRange(offset + 0x20, offset + 0x30, 'Z025XXXXXXXXXXXX'.codeUnits);
  bytes[offset + 0x32] = versionValue & 0xff;
  bytes[offset + 0x33] = versionValue >> 8;
  return bytes;
}

Uint8List _identifiedSlotImage({String banner = 'SCOOTER_VCU_xxG3'}) {
  final bytes = _image(0xE000);
  bytes.setRange(
    kBannerOffset,
    kBannerOffset + kBannerLength,
    banner.codeUnits,
  );
  return bytes;
}

Uint8List _slotZip32(Uint8List payload, {required String model}) =>
    PackV3.makeZipV32(
      data: payload,
      name: '$model VCU test',
      typeFlag: 'VCU',
      model: model,
      boards: ['${model}_VCU_AT32'],
    );

class _FakeSession implements SwdartSession {
  _FakeSession({
    swd.TargetInfo? target,
    Uint8List? bytes,
    Uint8List? sramBytes,
    this.connectCompleter,
    this.connectError,
    this.events,
    this.resetError,
    this.rescueError,
    this.continueResult = false,
    this.onRead,
    this.rescueStages = const [
      swd.ProtectionRescueStage.usdErased,
      swd.ProtectionRescueStage.fapProgrammed,
    ],
    this.programStages = const [
      swd.FlashProgramStage.ready,
      swd.FlashProgramStage.erased,
      swd.FlashProgramStage.wrote,
      swd.FlashProgramStage.verified,
    ],
  }) : target = target ?? _target(),
       bytes = bytes ?? _image(),
       sramBytes = sramBytes ?? Uint8List(32 * 1024);

  final swd.TargetInfo target;
  final Uint8List bytes;
  final Uint8List sramBytes;
  final Completer<swd.TargetInfo>? connectCompleter;
  final Object? connectError;
  final List<String>? events;
  final Object? resetError;
  final Object? rescueError;
  final bool continueResult;

  /// Optional per-address read stub for the FAP-check reads; when null the
  /// whole [bytes] image is returned as before.
  final Uint8List Function(int address, int length)? onRead;

  final List<swd.ProtectionRescueStage> rescueStages;
  final List<swd.FlashProgramStage> programStages;
  void Function(String line)? log;
  void Function(GuidedConnectEvent event)? guided;
  void Function(swd.RaceConnectEvent event)? race;
  swd.ConnectMode? connectMode;
  int? connectCountdown;
  int? readAddress;
  int? readLength;
  int? sramAddress;
  int? sramLength;
  final List<int> readAddresses = [];
  int? programAddress;
  Uint8List? programBytes;
  int resetRuns = 0;
  int rescueRuns = 0;
  bool aborted = false;
  int disconnects = 0;
  int continues = 0;

  @override
  void onLog(void Function(String line) sink) => log = sink;

  @override
  void onGuided(void Function(GuidedConnectEvent event) sink) => guided = sink;

  @override
  void onRace(void Function(swd.RaceConnectEvent event) sink) => race = sink;

  @override
  Future<swd.TargetInfo> connect(
    swd.ConnectMode mode, {
    int countdown = 0,
  }) async {
    connectMode = mode;
    connectCountdown = countdown;
    log?.call('[probe] fake ST-Link');
    if (connectError != null) throw connectError!;
    return connectCompleter?.future ?? target;
  }

  @override
  Future<Uint8List> readFlash({
    required int address,
    required int length,
  }) async {
    // Mirror the real probe: a read after disconnect fails "not connected".
    // This pins the FAP-check read ordering so a disconnect that races the
    // reads is caught rather than silently returning data.
    if (disconnects > 0) throw StateError('not connected');
    readAddress = address;
    readLength = length;
    readAddresses.add(address);
    events?.add('read');
    log?.call('[flash] fake read');
    return onRead?.call(address, length) ?? bytes;
  }

  @override
  Future<Uint8List> readSram({
    required int address,
    required int length,
  }) async {
    if (disconnects > 0) throw StateError('not connected');
    sramAddress = address;
    sramLength = length;
    events?.add('sram');
    log?.call('[sram] fake read');
    return sramBytes;
  }

  @override
  Future<void> programFlash({
    required int address,
    required Uint8List bytes,
    required void Function(swd.FlashProgramStage stage) onStage,
  }) async {
    programAddress = address;
    programBytes = bytes;
    events?.add('program');
    for (final stage in programStages) {
      onStage(stage);
    }
  }

  @override
  Future<void> resetRun({
    required void Function(swd.FlashProgramStage stage) onStage,
  }) async {
    resetRuns++;
    events?.add('reset');
    if (resetError != null) throw resetError!;
    onStage(swd.FlashProgramStage.resetRunning);
  }

  @override
  Future<void> rescueProtection({
    required void Function(swd.ProtectionRescueStage stage) onStage,
  }) async {
    rescueRuns++;
    events?.add('rescue');
    for (final stage in rescueStages) {
      onStage(stage);
    }
    if (rescueError != null) throw rescueError!;
  }

  @override
  bool continueConnect() {
    continues++;
    return continueResult;
  }

  @override
  void abort() => aborted = true;

  @override
  Future<void> disconnect() async => disconnects++;
}

HardwareCallbacks _callbacks({void Function(String line)? onLine}) =>
    HardwareCallbacks(
      onLine: onLine ?? (_) {},
      onProgress: (_) {},
      onGuided: (_) {},
      onCaught: () {},
      onAttempt: (_, _) {},
    );

void main() {
  test('default x3utils probe session enables the AT32 SRAM loader', () {
    expect(SwdartProbeSession().usesAt32Loader, isTrue);
    expect(SwdartProbeSession(useAt32Loader: false).usesAt32Loader, isFalse);
    expect(
      SwdartProbeSession(probe: swd.Probe()).usesAt32Loader,
      isFalse,
      reason: 'an explicitly supplied probe keeps its own configuration',
    );
  });

  test('loader diagnostics stay off unless the session opts in', () {
    expect(SwdartProbeSession().usesLoaderDiagnostics, isFalse);
    expect(
      SwdartProbeSession(loaderDiagnostics: true).usesLoaderDiagnostics,
      isTrue,
    );
  });

  test(
    'Check accepts a known AT32F415 and forwards only session logs',
    () async {
      final session = _FakeSession();
      final backend = SwdartBackend(sessionFactory: () => session);
      final lines = <String>[];

      final result = await backend.run(
        const HardwareRequest(
          operation: HardwareOperation.check,
          mode: ConnectionMode.defaultSwd,
          countdown: 3,
        ),
        _callbacks(onLine: lines.add),
      );

      expect(result.ok, isTrue);
      expect(result.evidence.caught, isTrue);
      expect(result.evidence.dumped, isFalse);
      expect(session.connectMode, swd.ConnectMode.normal);
      expect(lines, ['[probe] fake ST-Link']);
      expect(session.disconnects, 1);
    },
  );

  test('USB acquisition failures stay typed through swdart backend', () async {
    final session = _FakeSession(
      connectError: const UsbAcquireException(
        UsbAcquireFailureKind.disconnected,
        'ST-Link disconnected.',
      ),
    );
    final backend = SwdartBackend(sessionFactory: () => session);

    await expectLater(
      backend.run(
        const HardwareRequest(
          operation: HardwareOperation.check,
          mode: ConnectionMode.defaultSwd,
          countdown: 3,
        ),
        _callbacks(),
      ),
      throwsA(
        isA<HardwareException>().having(
          (error) => error.kind,
          'kind',
          HardwareFailureKind.deviceDisconnected,
        ),
      ),
    );
  });

  test('ordinary pre-target SWD failure is typed as target contact', () async {
    final session = _FakeSession(
      connectError: swd.SwdException('No SWD response.'),
    );
    final backend = SwdartBackend(sessionFactory: () => session);

    await expectLater(
      backend.run(
        const HardwareRequest(
          operation: HardwareOperation.check,
          mode: ConnectionMode.defaultSwd,
          countdown: 3,
        ),
        _callbacks(),
      ),
      throwsA(
        isA<HardwareException>().having(
          (error) => error.kind,
          'kind',
          HardwareFailureKind.targetContact,
        ),
      ),
    );
  });

  test('Backup reads and returns exactly 128 KiB from flash base', () async {
    final bytes = _image();
    final session = _FakeSession(bytes: bytes);
    final backend = SwdartBackend(sessionFactory: () => session);

    final result = await backend.run(
      const HardwareRequest(
        operation: HardwareOperation.dump,
        mode: ConnectionMode.defaultSwd,
        countdown: 3,
        captureSram: true,
      ),
      _callbacks(),
    );

    expect(result.evidence.dumped, isTrue);
    expect(result.bytes, same(bytes));
    expect(result.bytes, hasLength(Firmware.expectedSize));
    expect(session.readAddress, 0x08000000);
    expect(session.readLength, Firmware.expectedSize);
    expect(session.sramAddress, 0x20000000);
    expect(session.sramLength, 32 * 1024);
    expect(result.evidence.sramAttempted, isTrue);
    expect(result.sramBytes, same(session.sramBytes));
    expect(result.comparisonBytes, isNull);
    expect(session.readAddresses, [0x08000000]);
  });

  test(
    'Extra Backup captures SRAM, USD, and two flash reads in one session',
    () async {
      final bytes = _identifiedCompatImage();
      final events = <String>[];
      final session = _FakeSession(
        bytes: bytes,
        sramBytes: _identifiedVcuSram(),
        events: events,
        onRead: (address, length) => address == 0x1ffff800
            ? Uint8List.fromList([0xa5, 0x5a, 0xff, 0x00])
            : bytes,
      );
      final backend = SwdartBackend(sessionFactory: () => session);

      final result = await backend.run(
        const HardwareRequest(
          operation: HardwareOperation.dump,
          mode: ConnectionMode.defaultSwd,
          countdown: 3,
          extraBackup: true,
        ),
        _callbacks(),
      );

      expect(result.ok, isTrue);
      expect(result.bytes, same(bytes));
      expect(result.comparisonBytes, same(bytes));
      expect(result.sramBytes, same(session.sramBytes));
      expect(result.extraBackupEvidence?.usdWord, 0x00ff5aa5);
      expect(result.extraBackupEvidence?.idcode, 0x700301c5);
      expect(result.extraBackupEvidence?.flashReadSkipped, isFalse);
      // Protection is probed FIRST (option word, then a short flash read), so
      // a protected target never pays for two 128 KiB reads. An accessible
      // target falls through to the normal SRAM + double-read capture.
      expect(session.readAddresses, [
        0x1ffff800,
        0x08000000,
        0x08000000,
        0x08000000,
      ]);
      expect(events, ['read', 'read', 'sram', 'read', 'read']);
      expect(session.disconnects, 1);
    },
  );

  test(
    'Extra Backup skips both 128 KiB reads when the target is protected',
    () async {
      final events = <String>[];
      final session = _FakeSession(
        sramBytes: _identifiedVcuSram(),
        events: events,
        // FAP locked and flash masked to 0x00 — the readout-protection shape.
        onRead: (address, length) => address == 0x1ffff800
            ? Uint8List.fromList([0x00, 0xff, 0xff, 0xff])
            : Uint8List(length),
      );
      final backend = SwdartBackend(sessionFactory: () => session);

      final result = await backend.run(
        const HardwareRequest(
          operation: HardwareOperation.dump,
          mode: ConnectionMode.defaultSwd,
          countdown: 3,
          extraBackup: true,
        ),
        _callbacks(),
      );

      expect(result.extraBackupEvidence?.flashReadSkipped, isTrue);
      expect(result.bytes, isNull);
      expect(result.comparisonBytes, isNull);
      // SRAM is still captured: on a protected controller it is the only
      // identity evidence obtainable, and a rescue would destroy it.
      expect(result.sramBytes, same(session.sramBytes));
      expect(session.readAddresses, [0x1ffff800, 0x08000000]);
      expect(events, ['read', 'read', 'sram']);
      expect(session.disconnects, 1);
    },
  );

  test('C45 Genuine maps to software-driven nRST under-reset attach', () async {
    final session = _FakeSession();
    final backend = SwdartBackend(
      sessionFactory: () => session,
      enableGenuineNrst: true,
    );

    final result = await backend.run(
      const HardwareRequest(
        operation: HardwareOperation.check,
        mode: ConnectionMode.genuineC45,
        countdown: 3,
      ),
      _callbacks(),
    );

    expect(result.ok, isTrue);
    expect(session.connectMode, swd.ConnectMode.underReset);
    expect(
      backend.capabilities.connectionModes,
      containsAll([ConnectionMode.defaultSwd, ConnectionMode.genuineC45]),
    );
    expect(
      backend.capabilities.connectionModes,
      isNot(contains(ConnectionMode.cloneC45)),
    );
    expect(
      backend.capabilities.connectionModes,
      isNot(contains(ConnectionMode.powerRace)),
    );
  });

  test('C45 Clone maps guided stages and Continue without fallback', () async {
    final connect = Completer<swd.TargetInfo>();
    final session = _FakeSession(
      connectCompleter: connect,
      continueResult: true,
    );
    final backend = SwdartBackend(
      sessionFactory: () => session,
      enableCloneC45: true,
    );
    final guided = <HardwareGuidedEvent>[];

    final running = backend.run(
      const HardwareRequest(
        operation: HardwareOperation.check,
        mode: ConnectionMode.cloneC45,
        countdown: 4,
      ),
      HardwareCallbacks(
        onLine: (_) {},
        onProgress: (_) {},
        onGuided: guided.add,
        onCaught: () {},
        onAttempt: (_, _) {},
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(session.connectMode, swd.ConnectMode.guided);
    expect(session.connectCountdown, 4);
    expect(
      backend.capabilities.connectionModes,
      contains(ConnectionMode.cloneC45),
    );
    session.guided?.call(const GuidedConnectEvent(GuidedConnectStage.hold));
    session.guided?.call(
      const GuidedConnectEvent(GuidedConnectStage.count, countdown: 2),
    );
    session.guided?.call(const GuidedConnectEvent(GuidedConnectStage.release));
    expect(backend.sendContinue(protection: false), isTrue);
    expect(session.continues, 1);

    connect.complete(session.target);
    final result = await running;

    expect(result.ok, isTrue);
    expect(guided.map((event) => event.stage), [
      HardwareGuidedStage.hold,
      HardwareGuidedStage.count,
      HardwareGuidedStage.release,
      HardwareGuidedStage.connected,
    ]);
    expect(guided[1].countdown, 2);
  });

  test('Power-race maps typed attempts and catch without fallback', () async {
    final connect = Completer<swd.TargetInfo>();
    final session = _FakeSession(connectCompleter: connect);
    final backend = SwdartBackend(
      sessionFactory: () => session,
      enablePowerRace: true,
    );
    final attempts = <(int, HardwareRaceTier)>[];
    var caught = false;

    final running = backend.run(
      const HardwareRequest(
        operation: HardwareOperation.check,
        mode: ConnectionMode.powerRace,
        countdown: 3,
      ),
      HardwareCallbacks(
        onLine: (_) {},
        onProgress: (_) {},
        onGuided: (_) {},
        onCaught: () => caught = true,
        onAttempt: (attempt, tier) => attempts.add((attempt, tier)),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(session.connectMode, swd.ConnectMode.attachRace);
    expect(
      backend.capabilities.connectionModes,
      contains(ConnectionMode.powerRace),
    );
    session.race?.call(
      const swd.RaceConnectEvent(1, swd.RaceConnectTier.searching),
    );
    session.race?.call(
      const swd.RaceConnectEvent(2, swd.RaceConnectTier.noisy),
    );
    session.race?.call(
      const swd.RaceConnectEvent(
        3,
        swd.RaceConnectTier.nearCatch,
        caught: true,
      ),
    );

    expect(attempts, [
      (1, HardwareRaceTier.searching),
      (2, HardwareRaceTier.noisy),
    ]);
    expect(caught, isTrue);
    connect.complete(session.target);
    final result = await running;
    expect(result.ok, isTrue);
    expect(session.disconnects, 1);
  });

  test('unknown assumed AT32 and non-AT32 targets fail closed', () async {
    for (final target in [
      _target(name: 'Artery AT32 device 0x1234 (untested — F415-like assumed)'),
      _target(name: 'STM32F103', family: 'STM32'),
    ]) {
      final backend = SwdartBackend(
        sessionFactory: () => _FakeSession(target: target),
      );
      await expectLater(
        backend.run(
          const HardwareRequest(
            operation: HardwareOperation.check,
            mode: ConnectionMode.defaultSwd,
            countdown: 3,
          ),
          _callbacks(),
        ),
        throwsA(isA<StateError>()),
      );
    }
  });

  test('wrong backup size fails closed', () async {
    final backend = SwdartBackend(
      sessionFactory: () => _FakeSession(bytes: _image(32768)),
    );

    await expectLater(
      backend.run(
        const HardwareRequest(
          operation: HardwareOperation.dump,
          mode: ConnectionMode.defaultSwd,
          countdown: 3,
        ),
        _callbacks(),
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('writes and FAP check/rescue are available, but other write modes are '
      'not', () async {
    final backend = SwdartBackend(sessionFactory: _FakeSession.new);

    expect(
      backend.capabilities.supports(
        HardwareOperation.dump,
        ConnectionMode.defaultSwd,
      ),
      isTrue,
    );
    expect(
      backend.capabilities.supports(
        HardwareOperation.dump,
        ConnectionMode.cloneC45,
      ),
      isFalse,
    );
    expect(
      backend.capabilities.supports(
        HardwareOperation.flashFull,
        ConnectionMode.defaultSwd,
      ),
      isTrue,
    );
    expect(backend.capabilities.flashSlot0, isTrue);
    expect(backend.capabilities.protectionCheck, isTrue);
    expect(backend.capabilities.protectionRescue, isTrue);
    expect(backend.sendContinue(protection: false), isFalse);
  });

  test(
    'capability override rejects Android work before opening a session',
    () async {
      final session = _FakeSession();
      final backend = SwdartBackend(
        sessionFactory: () => session,
        capabilityOverride: const HardwareCapabilities(
          connectionModes: {ConnectionMode.defaultSwd},
          check: true,
          dump: false,
          flashFull: false,
          flashSlot0: false,
          protectionCheck: false,
          protectionRescue: false,
        ),
      );

      await expectLater(
        backend.run(
          const HardwareRequest(
            operation: HardwareOperation.dump,
            mode: ConnectionMode.defaultSwd,
            countdown: 0,
          ),
          _callbacks(),
        ),
        throwsA(isA<UnsupportedError>()),
      );
      expect(session.connectMode, isNull);
    },
  );

  test(
    'protection Rescue requires both rewrite stages before success',
    () async {
      final session = _FakeSession();
      final lines = <String>[];
      final backend = SwdartBackend(sessionFactory: () => session);

      final result = await backend.runProtection(
        const HardwareProtectionRequest(
          operation: HardwareProtectionOperation.rescue,
          mode: ConnectionMode.defaultSwd,
          countdown: 3,
        ),
        HardwareProtectionCallbacks(
          onLine: lines.add,
          onChunk: (_) {},
          onGuided: (_) {},
        ),
      );

      expect(result.exitCode, 0);
      expect(result.verdict, HardwareProtectionVerdict.rescued);
      expect(session.rescueRuns, 1);
      expect(session.disconnects, 1);
      expect(
        lines,
        contains(
          '[protection] FAP disabled — the chip erased its flash and reset. '
          'Power-cycle and reconnect, then run Check protection.',
        ),
      );
    },
  );

  test(
    'protection Rescue rejects a wrong-geometry target before rewriting',
    () async {
      // 256 KiB / 2048 B part: in family, but the layout the rescue path
      // assumes does not apply. `tested` is irrelevant to the gate now.
      final session = _FakeSession(
        target: _target(
          name: 'AT32F415RCT7 (256 KB, 2048 B pages)',
          flashKB: 256,
          pageSize: 2048,
          tested: false,
        ),
      );
      final backend = SwdartBackend(sessionFactory: () => session);

      await expectLater(
        backend.runProtection(
          const HardwareProtectionRequest(
            operation: HardwareProtectionOperation.rescue,
            mode: ConnectionMode.defaultSwd,
            countdown: 3,
          ),
          HardwareProtectionCallbacks(
            onLine: (_) {},
            onChunk: (_) {},
            onGuided: (_) {},
          ),
        ),
        throwsA(isA<StateError>()),
      );
      expect(session.rescueRuns, 0);
      expect(session.disconnects, 1);
    },
  );

  test(
    'protection Rescue cannot succeed without both destructive stages',
    () async {
      final session = _FakeSession(
        rescueStages: const [swd.ProtectionRescueStage.usdErased],
      );
      final backend = SwdartBackend(sessionFactory: () => session);

      await expectLater(
        backend.runProtection(
          const HardwareProtectionRequest(
            operation: HardwareProtectionOperation.rescue,
            mode: ConnectionMode.defaultSwd,
            countdown: 3,
          ),
          HardwareProtectionCallbacks(
            onLine: (_) {},
            onChunk: (_) {},
            onGuided: (_) {},
          ),
        ),
        throwsA(isA<StateError>()),
      );
      expect(session.rescueRuns, 1);
      expect(session.disconnects, 1);
    },
  );

  test(
    'protection Rescue logs its completed stage and ST-Link recovery hint',
    () async {
      final session = _FakeSession(
        rescueError: StateError('ST-Link status 0x16'),
        rescueStages: const [swd.ProtectionRescueStage.usdErased],
      );
      final lines = <String>[];
      final backend = SwdartBackend(sessionFactory: () => session);

      await expectLater(
        backend.runProtection(
          const HardwareProtectionRequest(
            operation: HardwareProtectionOperation.rescue,
            mode: ConnectionMode.defaultSwd,
            countdown: 3,
          ),
          HardwareProtectionCallbacks(
            onLine: lines.add,
            onChunk: (_) {},
            onGuided: (_) {},
          ),
        ),
        throwsA(isA<StateError>()),
      );

      expect(
        lines,
        contains(
          '[protection] rescue failed after USD erase, during FAP programming: '
          'Bad state: ST-Link status 0x16',
        ),
      );
      expect(
        lines,
        contains('[protection] unplug/replug ST-LINK before retrying Rescue'),
      );
    },
  );

  test('all swdart protection operations reject Power-race', () async {
    final session = _FakeSession();
    final backend = SwdartBackend(
      sessionFactory: () => session,
      enablePowerRace: true,
    );

    await expectLater(
      backend.runProtection(
        const HardwareProtectionRequest(
          operation: HardwareProtectionOperation.rescue,
          mode: ConnectionMode.powerRace,
          countdown: 3,
        ),
        HardwareProtectionCallbacks(
          onLine: (_) {},
          onChunk: (_) {},
          onGuided: (_) {},
        ),
      ),
      throwsA(isA<UnsupportedError>()),
    );
    expect(session.connectMode, isNull);
  });

  group('classifySwdartProtection ladder', () {
    int usd(int fap, int fapComp, [int ssb = 0, int ssbComp = 0]) =>
        fap | (fapComp << 8) | (ssb << 16) | (ssbComp << 24);
    List<int> flash(int word) => [word, word, word, word];

    test('FAP masked and flash masked -> read protected (2)', () {
      final r = classifySwdartProtection(
        usdWord: usd(0x00, 0x00),
        flashWords: flash(0x00000000),
      );
      expect(r.verdict, HardwareProtectionVerdict.protected);
      expect(r.exitCode, 2);
    });

    test('FAP 0xA5 with valid complement -> not protected (0)', () {
      final r = classifySwdartProtection(
        usdWord: usd(0xa5, 0x5a),
        flashWords: [0x20001000, 1, 2, 3],
      );
      expect(r.verdict, HardwareProtectionVerdict.notProtected);
      expect(r.exitCode, 0);
    });

    test('blank readable flash with FAP 0xA5 -> not protected', () {
      final r = classifySwdartProtection(
        usdWord: usd(0xa5, 0x5a),
        flashWords: flash(0xffffffff),
      );
      expect(r.verdict, HardwareProtectionVerdict.notProtected);
    });

    test('contradiction guard: non-0xA5 FAP but readable flash wins', () {
      final r = classifySwdartProtection(
        usdWord: usd(0x11, 0x22),
        flashWords: [0x20000400, 1, 2, 3],
      );
      expect(r.verdict, HardwareProtectionVerdict.notProtected);
      expect(r.exitCode, 0);
    });

    test('option word unreadable but flash masked -> read protected', () {
      final r = classifySwdartProtection(usdWord: null, flashWords: flash(0));
      expect(r.verdict, HardwareProtectionVerdict.protected);
    });

    test('both reads unavailable -> inconclusive (3)', () {
      final r = classifySwdartProtection(usdWord: null, flashWords: null);
      expect(r.verdict, HardwareProtectionVerdict.inconclusive);
      expect(r.exitCode, 3);
    });

    test(
      'option word unreadable and flash unclassified -> inconclusive (3)',
      () {
        final r = classifySwdartProtection(
          usdWord: null,
          flashWords: [0x08001234, 1, 2, 3],
        );
        expect(r.verdict, HardwareProtectionVerdict.inconclusive);
        expect(r.exitCode, 3);
      },
    );

    test('FAP 0xA5, bad complement, masked flash -> read protected', () {
      final r = classifySwdartProtection(
        usdWord: usd(0xa5, 0x00),
        flashWords: flash(0x00000000),
      );
      expect(r.verdict, HardwareProtectionVerdict.protected);
    });

    test('FAP 0xA5, bad complement, unclassified flash -> inconclusive', () {
      final r = classifySwdartProtection(
        usdWord: usd(0xa5, 0x00),
        flashWords: [0x08001234, 1, 2, 3],
      );
      expect(r.verdict, HardwareProtectionVerdict.inconclusive);
    });
  });

  test(
    'protection Check reads FAP + flash and grades a locked board',
    () async {
      final session = _FakeSession(
        onRead: (address, length) => Uint8List(length),
      );
      final backend = SwdartBackend(sessionFactory: () => session);
      final lines = <String>[];

      final result = await backend.runProtection(
        const HardwareProtectionRequest(
          operation: HardwareProtectionOperation.check,
          mode: ConnectionMode.defaultSwd,
          countdown: 3,
        ),
        HardwareProtectionCallbacks(
          onLine: lines.add,
          onChunk: (_) {},
          onGuided: (_) {},
        ),
      );

      expect(result.verdict, HardwareProtectionVerdict.protected);
      expect(result.exitCode, 2);
      expect(session.connectMode, swd.ConnectMode.normal);
      expect(session.readAddresses, [0x1ffff800, 0x08000000]);
      expect(session.disconnects, 1);
      // Evidence line mirrors the OpenOCD Evidence section for cross-checking.
      expect(
        lines,
        contains(
          '[protection] USD @ 0x1FFFF800 = 0x00000000  '
          'FAP=0x00 FAP_COMP=0x00 SSB=0x00 SSB_COMP=0x00 '
          '[complement inconsistent]',
        ),
      );
      expect(
        lines,
        contains(
          '[protection] flash @ 0x08000000 = '
          '0x00000000 0x00000000 0x00000000 0x00000000 [masked (all 0x00)]',
        ),
      );
    },
  );

  test(
    'protection Check on an unidentified target is inconclusive, not thrown',
    () async {
      final session = _FakeSession(
        target: _target(name: 'STM32F103', family: 'STM32'),
      );
      final backend = SwdartBackend(sessionFactory: () => session);

      final result = await backend.runProtection(
        const HardwareProtectionRequest(
          operation: HardwareProtectionOperation.check,
          mode: ConnectionMode.defaultSwd,
          countdown: 3,
        ),
        HardwareProtectionCallbacks(
          onLine: (_) {},
          onChunk: (_) {},
          onGuided: (_) {},
        ),
      );

      expect(result.verdict, HardwareProtectionVerdict.inconclusive);
      expect(result.exitCode, 3);
      expect(session.readAddresses, isEmpty);
      expect(session.disconnects, 1);
    },
  );

  test(
    'protection Check with both reads faulting is inconclusive, not protected',
    () async {
      final session = _FakeSession(
        onRead: (address, length) => throw StateError('contact lost'),
      );
      final backend = SwdartBackend(sessionFactory: () => session);
      final lines = <String>[];

      final result = await backend.runProtection(
        const HardwareProtectionRequest(
          operation: HardwareProtectionOperation.check,
          mode: ConnectionMode.defaultSwd,
          countdown: 3,
        ),
        HardwareProtectionCallbacks(
          onLine: lines.add,
          onChunk: (_) {},
          onGuided: (_) {},
        ),
      );

      expect(result.verdict, HardwareProtectionVerdict.inconclusive);
      expect(result.exitCode, 3);
      expect(session.readAddresses, [0x1ffff800, 0x08000000]);
      expect(session.disconnects, 1);
      expect(
        lines.where((line) => line.contains('read refused')),
        hasLength(2),
      );
      expect(lines, contains('[protection] verdict: inconclusive'));
    },
  );

  test(
    'full write requires exact bytes and all typed completion stages',
    () async {
      final bytes = _image();
      final session = _FakeSession();
      final backend = SwdartBackend(sessionFactory: () => session);

      final result = await backend.run(
        HardwareRequest(
          operation: HardwareOperation.flashFull,
          mode: ConnectionMode.defaultSwd,
          countdown: 3,
          bytes: bytes,
        ),
        _callbacks(),
      );

      expect(result.ok, isTrue);
      expect(result.evidence.erased, isTrue);
      expect(result.evidence.wrote, isTrue);
      expect(result.evidence.verified, isTrue);
      expect(result.evidence.resetRunning, isTrue);
      expect(session.programAddress, 0x08000000);
      expect(session.programBytes, same(bytes));
      expect(session.resetRuns, 1);
    },
  );

  test('full write rejects missing bytes before opening a session', () async {
    var sessions = 0;
    final backend = SwdartBackend(
      sessionFactory: () {
        sessions++;
        return _FakeSession();
      },
    );

    await expectLater(
      backend.run(
        const HardwareRequest(
          operation: HardwareOperation.flashFull,
          mode: ConnectionMode.defaultSwd,
          countdown: 3,
        ),
        _callbacks(),
      ),
      throwsA(isA<StateError>()),
    );
    expect(sessions, 0);
  });

  test('slot-0 write programs the exact bytes at 0x08001000', () async {
    final bytes = _image(0xE000);
    final session = _FakeSession();
    final backend = SwdartBackend(sessionFactory: () => session);

    final result = await backend.run(
      HardwareRequest(
        operation: HardwareOperation.flashSlot0,
        mode: ConnectionMode.defaultSwd,
        countdown: 3,
        bytes: bytes,
      ),
      _callbacks(),
    );

    expect(result.ok, isTrue);
    expect(result.evidence.erased, isTrue);
    expect(result.evidence.wrote, isTrue);
    expect(result.evidence.verified, isTrue);
    expect(result.evidence.resetRunning, isTrue);
    expect(session.programAddress, 0x08001000);
    expect(session.programBytes, same(bytes));
    expect(session.resetRuns, 1);
  });

  test(
    'slot-0 write rejects missing or out-of-flash bytes before connect',
    () async {
      var sessions = 0;
      final backend = SwdartBackend(
        sessionFactory: () {
          sessions++;
          return _FakeSession();
        },
      );

      for (final bytes in <Uint8List?>[
        null,
        Uint8List(0),
        Uint8List(Firmware.expectedSize - 0x1000 + 1),
      ]) {
        await expectLater(
          backend.run(
            HardwareRequest(
              operation: HardwareOperation.flashSlot0,
              mode: ConnectionMode.defaultSwd,
              countdown: 3,
              bytes: bytes,
            ),
            _callbacks(),
          ),
          throwsA(isA<StateError>()),
        );
      }
      expect(sessions, 0);
    },
  );

  test('full write refuses a 256 KiB AT32F415 before programming', () async {
    final session = _FakeSession(
      target: _target(
        name: 'AT32F415RCT7 (256 KB, 2048 B pages)',
        flashKB: 256,
        pageSize: 2048,
        tested: false,
      ),
    );
    final backend = SwdartBackend(sessionFactory: () => session);

    await expectLater(
      backend.run(
        HardwareRequest(
          operation: HardwareOperation.flashFull,
          mode: ConnectionMode.defaultSwd,
          countdown: 3,
          bytes: _image(),
        ),
        _callbacks(),
      ),
      throwsA(isA<StateError>()),
    );
    expect(session.programBytes, isNull);
  });

  test('full write accepts any 128 KiB AT32F415 package', () async {
    // A non-CBT7 package with `tested: false`. It must program: the gate is
    // geometry, and `tested` is not consulted.
    final session = _FakeSession(
      target: _target(
        name: 'AT32F415RBT7 (128 KB, 1024 B pages)',
        tested: false,
      ),
    );
    final backend = SwdartBackend(sessionFactory: () => session);

    final result = await backend.run(
      HardwareRequest(
        operation: HardwareOperation.flashFull,
        mode: ConnectionMode.defaultSwd,
        countdown: 3,
        bytes: _image(),
      ),
      _callbacks(),
    );

    expect(result.ok, isTrue);
    expect(session.programBytes, isNotNull);
  });

  test(
    'full write fails closed when typed verify evidence is missing',
    () async {
      final session = _FakeSession(
        programStages: const [
          swd.FlashProgramStage.ready,
          swd.FlashProgramStage.erased,
          swd.FlashProgramStage.wrote,
        ],
      );
      final backend = SwdartBackend(sessionFactory: () => session);

      final result = await backend.run(
        HardwareRequest(
          operation: HardwareOperation.flashFull,
          mode: ConnectionMode.defaultSwd,
          countdown: 3,
          bytes: _image(),
        ),
        _callbacks(),
      );

      expect(result.ok, isFalse);
      expect(result.evidence.wrote, isTrue);
      expect(result.evidence.verified, isFalse);
      expect(result.evidence.resetRunning, isFalse);
      expect(session.resetRuns, 0);
    },
  );

  test('full write fails closed when reset-to-running fails', () async {
    final session = _FakeSession(resetError: StateError('reset failed'));
    final backend = SwdartBackend(sessionFactory: () => session);

    final result = await backend.run(
      HardwareRequest(
        operation: HardwareOperation.flashFull,
        mode: ConnectionMode.defaultSwd,
        countdown: 3,
        bytes: _image(),
      ),
      _callbacks(),
    );

    expect(result.ok, isFalse);
    expect(result.evidence.verified, isTrue);
    expect(result.evidence.resetRunning, isFalse);
  });

  test('cancel aborts and disconnects an active session', () async {
    final connect = Completer<swd.TargetInfo>();
    final session = _FakeSession(connectCompleter: connect);
    final backend = SwdartBackend(sessionFactory: () => session);
    final running = backend.run(
      const HardwareRequest(
        operation: HardwareOperation.check,
        mode: ConnectionMode.defaultSwd,
        countdown: 3,
      ),
      _callbacks(),
    );

    await Future<void>.delayed(Duration.zero);
    backend.cancel();
    connect.complete(session.target);

    await expectLater(running, throwsA(isA<StateError>()));
    expect(session.aborted, isTrue);
    expect(session.disconnects, greaterThanOrEqualTo(1));
  });

  test(
    'controller stages, validates, and promotes returned backup bytes',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'defaultAutoRetry': 0,
      });
      final root = Directory.systemTemp.createTempSync('x3utils_swdart_test');
      addTearDown(() {
        Firmware.setRoot(null);
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final backend = SwdartBackend(sessionFactory: _FakeSession.new);
      final controller = AppController(backend: backend);
      addTearDown(controller.dispose);
      await Future<void>.delayed(Duration.zero);
      controller.setX3utilsRoot(root.path);
      controller.setSecondCopy(false);
      controller.selectAction('dump');

      expect(controller.canStart, isTrue);
      await controller.start();

      expect(controller.stage, StageState.ok);
      expect(controller.resultPath, endsWith('.bin'));
      expect(File(controller.resultPath!).readAsBytesSync(), _image());
      expect(
        Directory(p.join(root.path, 'backup'))
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.part')),
        isEmpty,
      );

      controller.selectMode(ConnectionMode.cloneC45);
      expect(controller.canStart, isFalse);
      controller.selectMode(ConnectionMode.defaultSwd);
      controller.selectAction('flash_compat');
      expect(controller.canStart, isTrue);
    },
  );

  test(
    'controller Extra Backup writes verified primary, secondary, and certificate',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'defaultAutoRetry': 0,
      });
      final root = Directory.systemTemp.createTempSync('x3utils_extra_test');
      final secondary = Directory(p.join(root.path, 'secondary'))..createSync();
      addTearDown(() {
        Firmware.setRoot(null);
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final bytes = _identifiedCompatImage();
      final session = _FakeSession(
        bytes: bytes,
        sramBytes: _identifiedVcuSram(),
        onRead: (address, length) => address == 0x1ffff800
            ? Uint8List.fromList([0xa5, 0x5a, 0xff, 0x00])
            : bytes,
      );
      final controller = AppController(
        backend: SwdartBackend(sessionFactory: () => session),
        backupSecondCopy: (source) => File(
          source,
        ).copySync(p.join(secondary.path, p.basename(source))).path,
      );
      addTearDown(controller.dispose);
      await Future<void>.delayed(Duration.zero);
      controller.setX3utilsRoot(root.path);
      controller.setSecondCopy(false);
      controller.selectAction('dump');
      controller.setExtraBackup(true);

      await controller.start();

      expect(controller.stage, StageState.ok);
      expect(controller.resultPath, endsWith('.bin'));
      final primary = File(controller.resultPath!);
      expect(primary.readAsBytesSync(), bytes);
      final normalSidecar = File(controller.resultMetadataPath!);
      final extraSidecar = File(
        ExtraBackupMetadata.sidecarPath(controller.resultPath!),
      );
      expect(normalSidecar.existsSync(), isTrue);
      expect(extraSidecar.existsSync(), isTrue);
      expect(
        File(p.join(secondary.path, p.basename(primary.path))).existsSync(),
        isTrue,
      );
      expect(
        File(
          p.join(secondary.path, p.basename(normalSidecar.path)),
        ).existsSync(),
        isTrue,
      );
      expect(
        File(
          p.join(secondary.path, p.basename(extraSidecar.path)),
        ).existsSync(),
        isTrue,
      );
      final extra = jsonDecode(extraSidecar.readAsStringSync()) as Map;
      expect((extra['capture'] as Map)['match'], isTrue);
      expect((extra['capture'] as Map)['flashReads'], 2);
      expect((extra['secondaryCopy'] as Map)['verified'], isTrue);
      final rom = (extra['rom'] as Map)['firmware'] as Map;
      expect(rom['version'], '1.5.5');
      expect(rom['blacklisted'], isFalse);
      expect(rom['blacklistFrom'], '1.6.3');
      expect(rom['shuCompatibilityAtCapture'], 'eligibleByCurrentPolicy');
      expect((extra['ram'] as Map)['version'], '1.5.5');
      expect((extra['protection'] as Map)['verdict'], 'notProtected');
      expect((extra['protection'] as Map)['rdpOn'], isFalse);
      expect((extra['protection'] as Map)['fapUnlocked'], isTrue);
      // Schema 4: the certificate must describe the key fields with the SAME
      // words as the ordinary sidecar. Before this, one capture's two files
      // called the same bytes `other`/`present` and `asciiAlphanumeric`.
      final keyFields = (extra['rom'] as Map)['keyFields'] as Map;
      final normal = jsonDecode(normalSidecar.readAsStringSync()) as Map;
      expect(keyFields['teaAt0x1420'], isNotNull);
      expect(keyFields['xteaAt0x1440'], isNotNull);
      expect(keyFields['teaAt0x1420'], normal['keyState']);
      expect(keyFields['xteaAt0x1440'], normal['xteaState']);
      expect(extra['schema'], 4);
      expect(
        (extra['backup'] as Map)['factoryConditionClaim'],
        'notProvenWithoutAnExternalReference',
      );
      // JSON observations are for later analysis. They must not overload the
      // completion screen when every required Extra artifact was saved.
      expect((extra['findings'] as List), isNotEmpty);
      expect(controller.resultNote, isNull);
      expect(
        controller.heroMessage,
        'Backup verified. Extra data saved. No need to repeat.',
      );
      expect(controller.console.join('\n'), contains('Extra comparison OK'));
    },
  );

  test(
    'controller Extra Backup keeps the backup green but marks missing Extra artifacts',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'defaultAutoRetry': 0,
      });
      final root = Directory.systemTemp.createTempSync(
        'x3utils_extra_incomplete',
      );
      addTearDown(() {
        Firmware.setRoot(null);
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final bytes = _identifiedCompatImage();
      final session = _FakeSession(
        bytes: bytes,
        sramBytes: _identifiedVcuSram(),
        onRead: (address, length) => address == 0x1ffff800
            ? Uint8List.fromList([0xa5, 0x5a, 0xff, 0x00])
            : bytes,
      );
      final controller = AppController(
        backend: SwdartBackend(sessionFactory: () => session),
        backupSecondCopy: (_) => null,
      );
      addTearDown(controller.dispose);
      await Future<void>.delayed(Duration.zero);
      controller.setX3utilsRoot(root.path);
      controller.selectAction('dump');
      controller.setExtraBackup(true);

      await controller.start();

      expect(controller.stage, StageState.ok);
      expect(controller.heroMessage, 'Backup verified.');
      expect(
        controller.resultNote,
        'The Extra record is incomplete. Repeat Extra Backup if you need it.',
      );
      expect(File(controller.resultPath!).existsSync(), isTrue);
    },
  );

  test(
    'controller Extra Backup refuses mismatched reads without saving',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'defaultAutoRetry': 0,
      });
      final root = Directory.systemTemp.createTempSync(
        'x3utils_extra_mismatch',
      );
      addTearDown(() {
        Firmware.setRoot(null);
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final first = _identifiedCompatImage();
      final second = Uint8List.fromList(first)..[0x6000] ^= 0x01;
      var flashRead = 0;
      final session = _FakeSession(
        sramBytes: _identifiedVcuSram(),
        onRead: (address, length) {
          if (address == 0x1ffff800) {
            return Uint8List.fromList([0xa5, 0x5a, 0xff, 0x00]);
          }
          // The short pre-read protection probe must not consume one of the
          // two full reads this test is comparing.
          if (length < first.length) return first;
          return flashRead++ == 0 ? first : second;
        },
      );
      final controller = AppController(
        backend: SwdartBackend(sessionFactory: () => session),
        backupSecondCopy: (_) => fail('mismatched capture must not be copied'),
      );
      addTearDown(controller.dispose);
      await Future<void>.delayed(Duration.zero);
      controller.setX3utilsRoot(root.path);
      controller.selectAction('dump');
      controller.setExtraBackup(true);

      await controller.start();

      expect(controller.stage, StageState.fail);
      expect(controller.resultPath, isNull);
      expect(
        Directory(p.join(root.path, 'backup')).listSync().whereType<File>(),
        isEmpty,
      );
      expect(controller.console.join('\n'), contains('1 differing bytes'));
    },
  );

  test(
    'controller Extra Backup on a protected target saves RAM evidence only',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'defaultAutoRetry': 0,
      });
      final root = Directory.systemTemp.createTempSync(
        'x3utils_extra_protected',
      );
      final secondary = Directory(p.join(root.path, 'secondary'))..createSync();
      addTearDown(() {
        Firmware.setRoot(null);
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final session = _FakeSession(
        sramBytes: _identifiedVcuSram(),
        onRead: (address, length) => address == 0x1ffff800
            ? Uint8List.fromList([0x00, 0xff, 0xff, 0xff])
            : Uint8List(length),
      );
      final controller = AppController(
        backend: SwdartBackend(sessionFactory: () => session),
        backupSecondCopy: (src) {
          final dest = p.join(secondary.path, p.basename(src));
          File(src).copySync(dest);
          return dest;
        },
      );
      addTearDown(controller.dispose);
      await Future<void>.delayed(Duration.zero);
      controller.setX3utilsRoot(root.path);
      controller.selectAction('dump');
      controller.setExtraBackup(true);

      await controller.start();

      // No backup exists, so the run must not read as success.
      expect(controller.stage, StageState.fail);

      final produced = Directory(
        p.join(root.path, 'backup'),
      ).listSync().whereType<File>().map((f) => p.basename(f.path)).toList();
      // The RAM snapshot and the diagnostic record, and nothing that could be
      // mistaken for a restorable backup — no .bin, and no orphan .bin.part.
      expect(produced.where((n) => n.endsWith('_RAM.bin')), hasLength(1));
      expect(produced.where((n) => n.endsWith('_EXTRA.json')), hasLength(1));
      expect(produced.any((n) => n.endsWith('.bin.part')), isFalse);
      expect(
        produced.any((n) => n.endsWith('.bin') && !n.endsWith('_RAM.bin')),
        isFalse,
      );

      final certificate =
          jsonDecode(
                File(
                  p.join(
                    root.path,
                    'backup',
                    produced.firstWhere((n) => n.endsWith('_EXTRA.json')),
                  ),
                ).readAsStringSync(),
              )
              as Map<String, Object?>;
      expect(certificate['captureVerdict'], 'protectedNoBackup');
      expect(
        (certificate['findings']! as List).contains('flashReadProtected'),
        isTrue,
      );
      final backupSection = certificate['backup']! as Map<String, Object?>;
      expect(backupSection['file'], isNull);
      expect(backupSection['role'], 'diagnosticNoRestorableBackup');
      final capture = certificate['capture']! as Map<String, Object?>;
      expect(capture['flashReads'], 0);
      expect(capture['sramFile'], endsWith('_RAM.bin'));
      // No flash was read, so there is no ROM evidence.
      expect(certificate['rom'], isNull);
      // The SRAM identity is the payload this record exists to preserve.
      final ram = certificate['ram']! as Map<String, Object?>;
      expect(ram['component'], 'VCU');
    },
  );

  test(
    'controller Extra Backup on a blank chip keeps RAM evidence, not a backup',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'defaultAutoRetry': 0,
      });
      final root = Directory.systemTemp.createTempSync('x3utils_extra_blank');
      final secondary = Directory(p.join(root.path, 'secondary'))..createSync();
      addTearDown(() {
        Firmware.setRoot(null);
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final blank = Uint8List(0x20000)..fillRange(0, 0x20000, 0xff);
      final session = _FakeSession(
        sramBytes: _identifiedVcuSram(),
        // FAP unlocked and flash readable-but-blank: probe says notProtected,
        // so the full double-read runs and validation finds an erased chip.
        onRead: (address, length) => address == 0x1ffff800
            ? Uint8List.fromList([0xa5, 0x5a, 0xff, 0xff])
            : Uint8List.sublistView(blank, 0, length),
      );
      final controller = AppController(
        backend: SwdartBackend(sessionFactory: () => session),
        backupSecondCopy: (src) {
          final dest = p.join(secondary.path, p.basename(src));
          File(src).copySync(dest);
          return dest;
        },
      );
      addTearDown(controller.dispose);
      await Future<void>.delayed(Duration.zero);
      controller.setX3utilsRoot(root.path);
      controller.selectAction('dump');
      controller.setExtraBackup(true);

      await controller.start();

      expect(controller.stage, StageState.fail);
      final produced = Directory(
        p.join(root.path, 'backup'),
      ).listSync().whereType<File>().map((f) => p.basename(f.path)).toList();
      // The RAM snapshot and the diagnostic record survive the blank verdict;
      // no promoted .bin is produced.
      expect(produced.where((n) => n.endsWith('_RAM.bin')), hasLength(1));
      expect(produced.where((n) => n.endsWith('_EXTRA.json')), hasLength(1));
      expect(
        produced.any((n) => n.endsWith('.bin') && !n.endsWith('_RAM.bin')),
        isFalse,
      );

      final certificate =
          jsonDecode(
                File(
                  p.join(
                    root.path,
                    'backup',
                    produced.firstWhere((n) => n.endsWith('_EXTRA.json')),
                  ),
                ).readAsStringSync(),
              )
              as Map<String, Object?>;
      expect(certificate['captureVerdict'], 'chipFindingNoBackup');
      expect((certificate['backup']! as Map)['file'], isNull);
      final capture = certificate['capture']! as Map<String, Object?>;
      expect(capture['flashReads'], 2);
      expect(capture['noBackupReason'], 'chip_blank');
      expect(capture['sramFile'], endsWith('_RAM.bin'));
      expect((certificate['protection']! as Map)['verdict'], 'notProtected');
    },
  );

  test(
    'controller Extra Backup records an operator-declared MCU model',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'defaultAutoRetry': 0,
      });
      final root = Directory.systemTemp.createTempSync('x3utils_extra_mcu');
      final secondary = Directory(p.join(root.path, 'secondary'))..createSync();
      addTearDown(() {
        Firmware.setRoot(null);
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final bytes = _identifiedCompatImage(
        versionValue: 0x157,
        banner: 'SCOOTER_MCU_0001',
      );
      const controllerSnMn = 'Z025XXXXXXXXXXXX';
      bytes.setRange(
        kControllerSnMnOffset,
        kControllerSnMnOffset + kControllerSnMnLength,
        controllerSnMn.codeUnits,
      );
      bytes.setRange(
        kControllerSnMnBackupOffset,
        kControllerSnMnBackupOffset + kControllerSnMnLength,
        controllerSnMn.codeUnits,
      );
      final session = _FakeSession(
        bytes: bytes,
        sramBytes: _identifiedMcuSram(versionValue: 0x157),
        onRead: (address, length) => address == 0x1ffff800
            ? Uint8List.fromList([0xa5, 0x5a, 0xff, 0x00])
            : bytes,
      );
      final controller = AppController(
        backend: SwdartBackend(sessionFactory: () => session),
        backupSecondCopy: (source) => File(
          source,
        ).copySync(p.join(secondary.path, p.basename(source))).path,
      );
      addTearDown(controller.dispose);
      await Future<void>.delayed(Duration.zero);
      controller.setX3utilsRoot(root.path);
      controller.selectAction('dump');
      controller.setExtraBackup(true);

      await controller.start(askMcuModel: (_) async => 'g3');

      expect(controller.stage, StageState.ok);
      final extra =
          jsonDecode(
                File(
                  ExtraBackupMetadata.sidecarPath(controller.resultPath!),
                ).readAsStringSync(),
              )
              as Map;
      final firmware = (extra['rom'] as Map)['firmware'] as Map;
      expect(firmware['model'], 'g3');
      expect(firmware['modelSource'], 'operatorDeclared');
      expect(firmware['mcuModelUserProvided'], isTrue);
      expect(firmware['version'], '1.5.7');
      // Flash-derived SN/MN belongs in rom.identity; the RAM section still
      // emits no SN/MN, pending a cross-check against fresh RAM dumps.
      final ram = extra['ram'] as Map;
      expect(ram.containsKey('controllerSnMnCandidates'), isFalse);
      final identity = (extra['rom'] as Map)['identity'] as Map;
      expect(identity['scooterSerial'], isNull);
      expect(identity.containsKey('controllerSnMn'), isTrue);
    },
  );

  test(
    'desktop Backup + Flash validates a full backup before slot-0 programming',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'defaultAutoRetry': 0,
      });
      final root = Directory.systemTemp.createTempSync(
        'x3utils_swdart_slot0_test',
      );
      addTearDown(() {
        Firmware.setRoot(null);
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final events = <String>[];
      final backup = _identifiedImage();
      final incoming = _identifiedSlotImage();
      final firmware = File(p.join(root.path, 'slot0.bin'))
        ..writeAsBytesSync(incoming);
      final session = _FakeSession(bytes: backup, events: events);
      final controller = AppController(
        backend: SwdartBackend(sessionFactory: () => session),
      );
      addTearDown(controller.dispose);
      await Future<void>.delayed(Duration.zero);
      controller.setX3utilsRoot(root.path);
      controller.setSecondCopy(false);
      controller.selectAction('flash_backup');
      controller.setFlashScope(FlashScope.slot0);
      expect(controller.selectFirmwareBin(firmware.path).ok, isTrue);

      await controller.start();

      expect(controller.stage, StageState.ok);
      expect(events, ['read', 'program', 'reset']);
      expect(session.programAddress, 0x08001000);
      expect(session.programBytes, incoming);
      expect(controller.resultPath, endsWith('.bin'));
      expect(File(controller.resultPath!).existsSync(), isTrue);
    },
  );

  test(
    'desktop swdart SHU compat snapshots and programs the patched full image',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'desktopHardwareBackend': DesktopBackendSelection.swdart.name,
        'defaultAutoRetry': 0,
      });
      final root = Directory.systemTemp.createTempSync(
        'x3utils_swdart_compat_test',
      );
      addTearDown(() {
        Firmware.setRoot(null);
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final events = <String>[];
      final backup = _identifiedCompatImage();
      final session = _FakeSession(
        bytes: backup,
        sramBytes: _identifiedVcuSram(),
        events: events,
      );
      final swdart = SwdartBackend(sessionFactory: () => session);
      final router = DesktopBackendRouter(openOcd: null, swdart: swdart)
        ..select(DesktopBackendSelection.swdart);
      final controller = AppController(backend: router);
      addTearDown(controller.dispose);
      await Future<void>.delayed(Duration.zero);
      controller.setX3utilsRoot(root.path);
      controller.setSecondCopy(false);
      controller.selectAction('flash_compat');

      expect(controller.canStart, isTrue);
      await controller.start();

      expect(controller.stage, StageState.ok);
      expect(events, ['read', 'program', 'reset']);
      expect(session.sramAddress, isNull);
      expect(session.programAddress, 0x08000000);
      final programmed = session.programBytes!;
      expect(programmed, hasLength(Firmware.expectedSize));
      final expected = Uint8List.fromList(backup);
      expected.setRange(
        CompatPatch.offset,
        CompatPatch.offset + CompatPatch.signature.length,
        CompatPatch.signature,
      );
      expect(programmed, expected);
      expect(CompatPatch.keyState(programmed), FwKeyState.defaultKey);
      expect(controller.resultPath, endsWith('.bin'));
      expect(File(controller.resultPath!).readAsBytesSync(), backup);
    },
  );

  test(
    'browser controller validates then downloads returned bytes only',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'defaultConnMode': ConnectionMode.cloneC45.index,
        'defaultAutoRetry': 0,
        'logToFile': true,
        'secondCopy': true,
      });
      Uint8List? downloaded;
      String? downloadName;
      final controller = AppController(
        backend: SwdartBackend(
          sessionFactory: _FakeSession.new,
          enableCloneC45: true,
          enableGenuineNrst: true,
          enablePowerRace: true,
        ),
        browserMode: true,
        backupDownloader: (bytes, fileName) async {
          downloaded = bytes;
          downloadName = fileName;
        },
      );
      addTearDown(controller.dispose);
      await Future<void>.delayed(Duration.zero);

      expect(controller.backendName, 'swdart');
      expect(controller.availableModes, ConnectionMode.values);
      expect(controller.defaultMode, ConnectionMode.cloneC45);
      expect(controller.logToFile, isFalse);
      expect(controller.secondCopy, isFalse);
      expect(controller.hasAdvancedOptions, isTrue);
      expect(controller.isActionAvailable('check'), isTrue);
      expect(controller.isActionAvailable('dump'), isTrue);
      expect(controller.isActionAvailable('flash_backup'), isTrue);
      expect(controller.isActionAvailable('flash_compat'), isTrue);
      expect(controller.isActionAvailable('flash_only'), isTrue);
      expect(controller.isActionAvailable('rdp_check'), isTrue);
      expect(controller.isActionAvailable('make_zip3'), isFalse);
      expect(controller.isActionAvailable('file_info'), isTrue);
      expect(controller.hasFlashScope, isFalse);

      controller.selectAction('dump');
      expect(controller.canStart, isTrue);
      await controller.start();

      expect(controller.stage, StageState.ok);
      expect(downloaded, _image());
      expect(downloadName, endsWith('.bin'));
      expect(controller.resultPath, downloadName);
      expect(controller.resultMetadataPath, isNull);
      expect(controller.resultNote, contains('no metadata sidecar'));
    },
  );

  test('Android controller validates then publishes one backup bin', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'defaultAutoRetry': 0,
      'logToFile': true,
      'secondCopy': true,
    });
    final backup = _identifiedImage();
    Uint8List? published;
    String? publishedName;
    final controller = AppController(
      backend: SwdartBackend(
        sessionFactory: () => _FakeSession(bytes: backup),
        capabilityOverride: const HardwareCapabilities(
          connectionModes: {ConnectionMode.defaultSwd},
          check: true,
          dump: true,
          flashFull: false,
          flashSlot0: false,
          protectionCheck: false,
          protectionRescue: false,
        ),
      ),
      androidMode: true,
      androidBackupPublisher: (bytes, fileName) async {
        published = Uint8List.fromList(bytes);
        publishedName = fileName;
        return '$androidBackupDirectoryLabel/$fileName';
      },
    );
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);

    expect(controller.logToFile, isFalse);
    expect(controller.secondCopy, isFalse);
    expect(controller.isActionAvailable('dump'), isTrue);
    expect(controller.isActionAvailable('flash_backup'), isFalse);

    controller.selectAction('dump');
    expect(controller.canStart, isTrue);
    await controller.start();

    expect(controller.stage, StageState.ok);
    expect(published, backup);
    expect(publishedName, endsWith('.bin'));
    expect(
      controller.resultPath,
      '$androidBackupDirectoryLabel/$publishedName',
    );
    expect(controller.resultMetadataPath, isNull);
    expect(controller.resultNote, contains('no metadata sidecar'));
  });

  test('Android full Backup + Flash publishes before programming', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'defaultAutoRetry': 0,
    });
    final events = <String>[];
    final backup = _identifiedImage();
    final incoming = _identifiedImage()..[0x2000] ^= 0x55;
    final session = _FakeSession(bytes: backup, events: events);
    Uint8List? published;
    final controller = AppController(
      backend: SwdartBackend(sessionFactory: () => session),
      androidMode: true,
      androidBackupPublisher: (bytes, fileName) async {
        events.add('publish');
        published = Uint8List.fromList(bytes);
        return '$androidBackupDirectoryLabel/$fileName';
      },
    );
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);

    expect(controller.isActionAvailable('flash_backup'), isTrue);
    expect(controller.isActionAvailable('flash_only'), isTrue);
    expect(controller.isActionAvailable('flash_compat'), isTrue);
    controller.selectAction('flash_backup');
    expect(controller.selectFirmwareBytes('incoming.bin', incoming).ok, isTrue);
    await controller.start();

    expect(controller.stage, StageState.ok);
    expect(events, ['read', 'publish', 'program', 'reset']);
    expect(published, backup);
    expect(session.programAddress, 0x08000000);
    expect(session.programBytes, incoming);
    expect(controller.resultPath, startsWith(androidBackupDirectoryLabel));
    expect(controller.resultNote, contains('Android backup only'));
  });

  test('Android SHU saves the original before patching and flashing', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'defaultAutoRetry': 0,
    });
    final events = <String>[];
    final backup = _identifiedCompatImage();
    final session = _FakeSession(
      bytes: backup,
      sramBytes: _identifiedVcuSram(),
      events: events,
    );
    Uint8List? published;
    final controller = AppController(
      backend: SwdartBackend(sessionFactory: () => session),
      androidMode: true,
      androidBackupPublisher: (bytes, fileName) async {
        events.add('publish');
        published = Uint8List.fromList(bytes);
        return '$androidBackupDirectoryLabel/$fileName';
      },
    );
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);

    expect(controller.isActionAvailable('flash_compat'), isTrue);
    controller.selectAction('flash_compat');
    expect(controller.canStart, isTrue);
    await controller.start();

    expect(controller.stage, StageState.ok);
    expect(events, ['read', 'publish', 'program', 'reset']);
    expect(session.sramAddress, isNull);
    expect(published, backup);
    expect(session.programAddress, 0x08000000);
    final expected = Uint8List.fromList(backup)
      ..setRange(
        CompatPatch.offset,
        CompatPatch.offset + CompatPatch.signature.length,
        CompatPatch.signature,
      );
    expect(session.programBytes, expected);
    expect(CompatPatch.keyState(session.programBytes!), FwKeyState.defaultKey);
    expect(controller.resultPath, startsWith(androidBackupDirectoryLabel));
    expect(controller.resultNote, contains('Android backup only'));
  });

  test('Android SHU blocks XTEA before ROM identity or model checks', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'defaultAutoRetry': 0,
    });
    final events = <String>[];
    final backup =
        _identifiedCompatImage(
          versionValue: 0x160,
          banner: 'UNRECOGNISED_FIRMWARE',
        )..setRange(
          CompatXtea.offset,
          CompatXtea.offset + CompatXtea.length,
          'xtea1234key56789'.codeUnits,
        );
    final session = _FakeSession(
      bytes: backup,
      sramBytes: _identifiedMcuSram(versionValue: 0x160),
      events: events,
    );
    var modelPrompts = 0;
    final controller = AppController(
      backend: SwdartBackend(sessionFactory: () => session),
      androidMode: true,
      androidBackupPublisher: (_, fileName) async {
        events.add('publish');
        return '$androidBackupDirectoryLabel/$fileName';
      },
    );
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);

    controller.selectAction('flash_compat');
    await controller.start(
      askMcuModel: (_) async {
        modelPrompts++;
        return 'zt3';
      },
    );

    expect(modelPrompts, 0);
    expect(controller.stage, StageState.fail);
    expect(events, ['read', 'publish']);
    expect(session.sramAddress, isNull);
    expect(session.programBytes, isNull);
    expect(controller.sub, contains('XTEA key is present'));
    expect(
      controller.console.any(
        (line) => line.contains('ROM XTEA field: present'),
      ),
      isTrue,
    );
  });

  test(
    'Android SHU old MCU layout continues to model and version checks',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'defaultAutoRetry': 0,
      });
      final events = <String>[];
      final backup = _identifiedCompatImage(
        versionValue: 0x152,
        banner: 'SCOOTER_MCU_0001',
      );
      final session = _FakeSession(
        bytes: backup,
        sramBytes: _identifiedMcuSram(versionValue: 0x152),
        events: events,
      );
      var modelPrompts = 0;
      final controller = AppController(
        backend: SwdartBackend(sessionFactory: () => session),
        androidMode: true,
        androidBackupPublisher: (_, fileName) async {
          events.add('publish');
          return '$androidBackupDirectoryLabel/$fileName';
        },
      );
      addTearDown(controller.dispose);
      await Future<void>.delayed(Duration.zero);

      controller.selectAction('flash_compat');
      await controller.start(
        askMcuModel: (_) async {
          modelPrompts++;
          return 'zt3';
        },
      );

      expect(modelPrompts, 1);
      expect(controller.stage, StageState.ok);
      expect(events, ['read', 'publish', 'program', 'reset']);
      expect(session.sramAddress, isNull);
    },
  );

  test(
    'Android SHU lets ROM version policy handle non-present XTEA layouts',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'defaultAutoRetry': 0,
      });
      for (final entry in <(String, int, List<int>)>[
        ('default TEA', CompatPatch.offset, CompatPatch.signature),
        (
          'cleared TEA',
          CompatPatch.offset,
          List<int>.filled(CompatPatch.signature.length, 0xFF),
        ),
        (
          'cleared XTEA',
          CompatXtea.offset,
          List<int>.filled(CompatXtea.length, 0xFF),
        ),
      ]) {
        final backup = _identifiedCompatImage()
          ..setRange(entry.$2, entry.$2 + entry.$3.length, entry.$3);
        final session = _FakeSession(
          bytes: backup,
          sramBytes: _identifiedVcuSram(),
        );
        final controller = AppController(
          backend: SwdartBackend(sessionFactory: () => session),
          androidMode: true,
          androidBackupPublisher: (_, fileName) async =>
              '$androidBackupDirectoryLabel/$fileName',
        );
        addTearDown(controller.dispose);
        await Future<void>.delayed(Duration.zero);

        controller.selectAction('flash_compat');
        await controller.start();

        expect(controller.stage, StageState.ok, reason: entry.$1);
        expect(session.programBytes, isNotNull, reason: entry.$1);
        expect(session.sramAddress, isNull, reason: entry.$1);
      }
    },
  );

  test('Android SHU aborts before patching when backup save fails', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'defaultAutoRetry': 0,
    });
    final events = <String>[];
    final session = _FakeSession(
      bytes: _identifiedCompatImage(),
      events: events,
    );
    final controller = AppController(
      backend: SwdartBackend(sessionFactory: () => session),
      androidMode: true,
      androidBackupPublisher: (_, _) async {
        events.add('publish');
        throw StateError('blocked');
      },
    );
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);

    controller.selectAction('flash_compat');
    await controller.start();

    expect(controller.stage, StageState.fail);
    expect(events, ['read', 'publish']);
    expect(session.sramAddress, isNull);
    expect(session.programBytes, isNull);
    expect(controller.sub, contains('Nothing was written'));
  });

  test('Android SHU saves but refuses a blocked firmware version', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'defaultAutoRetry': 0,
    });
    final events = <String>[];
    final session = _FakeSession(
      bytes: _identifiedCompatImage(versionValue: 0x163),
      sramBytes: _identifiedVcuSram(versionValue: 0x163),
      events: events,
    );
    final controller = AppController(
      backend: SwdartBackend(sessionFactory: () => session),
      androidMode: true,
      androidBackupPublisher: (_, fileName) async {
        events.add('publish');
        return '$androidBackupDirectoryLabel/$fileName';
      },
    );
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);

    controller.selectAction('flash_compat');
    await controller.start();

    expect(controller.stage, StageState.fail);
    expect(events, ['read', 'publish']);
    expect(session.sramAddress, isNull);
    expect(session.programBytes, isNull);
    expect(controller.resultPath, startsWith(androidBackupDirectoryLabel));
    expect(controller.sub, contains('does not work on that firmware'));
  });

  test(
    'Android SHU ignores SRAM and uses the identified ROM version',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'defaultAutoRetry': 0,
      });
      final events = <String>[];
      final session = _FakeSession(
        bytes: _identifiedCompatImage(),
        sramBytes: _identifiedVcuSram(versionValue: 0x158),
        events: events,
      );
      final controller = AppController(
        backend: SwdartBackend(sessionFactory: () => session),
        androidMode: true,
        androidBackupPublisher: (_, fileName) async {
          events.add('publish');
          return '$androidBackupDirectoryLabel/$fileName';
        },
      );
      addTearDown(controller.dispose);
      await Future<void>.delayed(Duration.zero);

      controller.selectAction('flash_compat');
      await controller.start();

      expect(controller.stage, StageState.ok);
      expect(events, ['read', 'publish', 'program', 'reset']);
      expect(session.sramAddress, isNull);
      expect(session.programBytes, isNotNull);
    },
  );

  test('ZT3 MCU 1.6.0 is blocked after operator model selection', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'defaultAutoRetry': 0,
    });
    final events = <String>[];
    final session = _FakeSession(
      bytes: _identifiedCompatImage(
        versionValue: 0x160,
        banner: 'SCOOTER_MCU_0001',
      ),
      sramBytes: _identifiedMcuSram(versionValue: 0x160),
      events: events,
    );
    final controller = AppController(
      backend: SwdartBackend(sessionFactory: () => session),
      androidMode: true,
      androidBackupPublisher: (_, fileName) async {
        events.add('publish');
        return '$androidBackupDirectoryLabel/$fileName';
      },
    );
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);

    controller.selectAction('flash_compat');
    await controller.start(askMcuModel: (_) async => 'zt3');

    expect(controller.stage, StageState.fail);
    expect(events, ['read', 'publish']);
    expect(session.sramAddress, isNull);
    expect(session.programBytes, isNull);
    expect(controller.sub, contains('does not work on that firmware'));
  });

  test('Android slot-0 Backup + Flash accepts a matching ZIP3.2', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'defaultAutoRetry': 0,
    });
    final events = <String>[];
    final backup = _identifiedImage();
    final incoming = _identifiedSlotImage();
    final session = _FakeSession(bytes: backup, events: events);
    final controller = AppController(
      backend: SwdartBackend(sessionFactory: () => session),
      androidMode: true,
      androidBackupPublisher: (_, fileName) async {
        events.add('publish');
        return '$androidBackupDirectoryLabel/$fileName';
      },
    );
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);

    controller.selectAction('flash_backup');
    controller.setFlashScope(FlashScope.slot0);
    expect(
      controller
          .loadSlotFirmwareFromZipBytes(
            'incoming.zip',
            _slotZip32(incoming, model: 'g3'),
          )
          .ok,
      isTrue,
    );
    await controller.start();

    expect(controller.stage, StageState.ok);
    expect(events, ['read', 'publish', 'program', 'reset']);
    expect(session.programAddress, 0x08001000);
    expect(session.programBytes, incoming);
  });

  test(
    'Android Backup + Flash rejects an invalid backup before saving',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'defaultAutoRetry': 0,
      });
      var publishes = 0;
      final session = _FakeSession(bytes: Uint8List(Firmware.expectedSize));
      final controller = AppController(
        backend: SwdartBackend(sessionFactory: () => session),
        androidMode: true,
        androidBackupPublisher: (_, _) async {
          publishes++;
          return 'unused';
        },
      );
      addTearDown(controller.dispose);
      await Future<void>.delayed(Duration.zero);

      controller.selectAction('flash_backup');
      expect(
        controller.selectFirmwareBytes('incoming.bin', _identifiedImage()).ok,
        isTrue,
      );
      await controller.start();

      expect(controller.stage, StageState.fail);
      expect(publishes, 0);
      expect(session.programBytes, isNull);
    },
  );

  test('Android Backup + Flash aborts when MediaStore save fails', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'defaultAutoRetry': 0,
    });
    final session = _FakeSession(bytes: _identifiedImage());
    final controller = AppController(
      backend: SwdartBackend(sessionFactory: () => session),
      androidMode: true,
      androidBackupPublisher: (_, _) async => throw StateError('blocked'),
    );
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);

    controller.selectAction('flash_backup');
    expect(
      controller.selectFirmwareBytes('incoming.bin', _identifiedImage()).ok,
      isTrue,
    );
    await controller.start();

    expect(controller.stage, StageState.fail);
    expect(session.programBytes, isNull);
    expect(controller.sub, contains('Nothing was written'));
  });

  test(
    'Android Backup + Flash saves but does not program a target mismatch',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'defaultAutoRetry': 0,
      });
      var publishes = 0;
      final session = _FakeSession(
        bytes: _identifiedImage(banner: 'SCOOTER_VCU_xxG3'),
      );
      final controller = AppController(
        backend: SwdartBackend(sessionFactory: () => session),
        androidMode: true,
        androidBackupPublisher: (_, fileName) async {
          publishes++;
          return '$androidBackupDirectoryLabel/$fileName';
        },
      );
      addTearDown(controller.dispose);
      await Future<void>.delayed(Duration.zero);

      controller.selectAction('flash_backup');
      expect(
        controller
            .selectFirmwareBytes(
              'incoming.bin',
              _identifiedImage(banner: 'SCOOTER_VCU_xxU2'),
            )
            .ok,
        isTrue,
      );
      await controller.start();

      expect(controller.stage, StageState.fail);
      expect(publishes, 1);
      expect(session.programBytes, isNull);
      expect(controller.resultPath, startsWith(androidBackupDirectoryLabel));
      expect(controller.sub, contains('Nothing was written'));
    },
  );

  test(
    'Android full Flash Only writes without reading or saving a backup',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'defaultAutoRetry': 0,
      });
      final events = <String>[];
      final incoming = _identifiedImage();
      final session = _FakeSession(events: events);
      var publishes = 0;
      final controller = AppController(
        backend: SwdartBackend(sessionFactory: () => session),
        androidMode: true,
        androidBackupPublisher: (_, _) async {
          publishes++;
          return 'unused';
        },
      );
      addTearDown(controller.dispose);
      await Future<void>.delayed(Duration.zero);

      controller.selectAction('flash_only');
      expect(
        controller.selectFirmwareBytes('incoming.bin', incoming).ok,
        isTrue,
      );
      await controller.start();

      expect(controller.stage, StageState.ok);
      expect(events, ['program', 'reset']);
      expect(publishes, 0);
      expect(session.readAddresses, isEmpty);
      expect(session.programAddress, 0x08000000);
      expect(session.programBytes, incoming);
    },
  );

  test('Android slot-0 Flash Only accepts ZIP3.2 without a backup', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'defaultAutoRetry': 0,
    });
    final events = <String>[];
    final incoming = _identifiedSlotImage();
    final session = _FakeSession(events: events);
    var publishes = 0;
    final controller = AppController(
      backend: SwdartBackend(sessionFactory: () => session),
      androidMode: true,
      androidBackupPublisher: (_, _) async {
        publishes++;
        return 'unused';
      },
    );
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);

    controller.selectAction('flash_only');
    controller.setFlashScope(FlashScope.slot0);
    expect(
      controller
          .loadSlotFirmwareFromZipBytes(
            'incoming.zip',
            _slotZip32(incoming, model: 'g3'),
          )
          .ok,
      isTrue,
    );
    await controller.start();

    expect(controller.stage, StageState.ok);
    expect(events, ['program', 'reset']);
    expect(publishes, 0);
    expect(session.readAddresses, isEmpty);
    expect(session.programAddress, 0x08001000);
    expect(session.programBytes, incoming);
  });

  test('Android Check protection reports readable flash as unlocked', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'defaultAutoRetry': 0,
    });
    final session = _FakeSession(
      onRead: (address, length) {
        final bytes = Uint8List(length);
        final data = ByteData.sublistView(bytes);
        if (address == 0x1ffff800) {
          data.setUint32(0, 0xffff5aa5, Endian.little);
        } else {
          data.setUint32(0, 0x20000550, Endian.little);
          data.setUint32(4, 0x08000121, Endian.little);
        }
        return bytes;
      },
    );
    final controller = AppController(
      backend: SwdartBackend(sessionFactory: () => session),
      androidMode: true,
    );
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);

    controller.selectAction('rdp_check');
    expect(controller.canStart, isTrue);
    await controller.start();

    expect(controller.stage, StageState.ok);
    expect(controller.sub, contains('NOT read-protected'));
    expect(session.readAddresses, [0x1ffff800, 0x08000000]);
    expect(session.programBytes, isNull);
  });

  test('Android C45 Clone routes Check through guided attach', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'defaultAutoRetry': 0,
    });
    final session = _FakeSession();
    final controller = AppController(
      backend: SwdartBackend(
        sessionFactory: () => session,
        enableCloneC45: true,
        enableGenuineNrst: true,
      ),
      androidMode: true,
    );
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);

    expect(controller.availableModes, const [
      ConnectionMode.defaultSwd,
      ConnectionMode.cloneC45,
    ]);
    controller.selectMode(ConnectionMode.cloneC45);
    controller.selectAction('check');
    await controller.start();

    expect(controller.stage, StageState.ok);
    expect(session.connectMode, swd.ConnectMode.guided);
  });

  test('Android Power-race routes Check through attach race', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'defaultAutoRetry': 0,
    });
    final session = _FakeSession();
    final controller = AppController(
      backend: SwdartBackend(
        sessionFactory: () => session,
        enablePowerRace: true,
      ),
      androidMode: true,
    );
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);

    expect(controller.availableModes, const [
      ConnectionMode.defaultSwd,
      ConnectionMode.powerRace,
    ]);
    controller.selectMode(ConnectionMode.powerRace);
    controller.selectAction('check');
    await controller.start();

    expect(controller.stage, StageState.ok);
    expect(session.connectMode, swd.ConnectMode.attachRace);
  });

  test(
    'browser Backup + Flash downloads a valid backup before programming',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'defaultAutoRetry': 0,
      });
      final events = <String>[];
      final backup = _identifiedImage();
      final incoming = _identifiedImage();
      incoming[0x2000] ^= 0x55;
      final session = _FakeSession(bytes: backup, events: events);
      Uint8List? downloaded;
      final controller = AppController(
        backend: SwdartBackend(sessionFactory: () => session),
        browserMode: true,
        backupDownloader: (bytes, _) async {
          events.add('download');
          downloaded = Uint8List.fromList(bytes);
        },
      );
      addTearDown(controller.dispose);
      await Future<void>.delayed(Duration.zero);

      controller.selectAction('flash_backup');
      expect(
        controller.selectFirmwareBytes('incoming.bin', incoming).ok,
        isTrue,
      );
      expect(controller.canStart, isTrue);
      await controller.start();

      expect(controller.stage, StageState.ok);
      expect(events, ['read', 'download', 'program', 'reset']);
      expect(downloaded, backup);
      expect(session.programBytes, incoming);
      expect(controller.resultPath, endsWith('.bin'));
      expect(controller.resultMetadataPath, isNull);
      expect(controller.resultNote, contains('no metadata sidecar'));
    },
  );

  test('browser guarded slot-0 flash accepts matching slot identity', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'defaultAutoRetry': 0,
    });
    final events = <String>[];
    final backup = _identifiedImage();
    final incoming = _identifiedSlotImage();
    final session = _FakeSession(bytes: backup, events: events);
    Uint8List? downloaded;
    final controller = AppController(
      backend: SwdartBackend(sessionFactory: () => session),
      browserMode: true,
      backupDownloader: (bytes, _) async {
        events.add('download');
        downloaded = Uint8List.fromList(bytes);
      },
    );
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);

    controller.selectAction('flash_backup');
    controller.setFlashScope(FlashScope.slot0);
    expect(
      controller
          .loadSlotFirmwareFromZipBytes(
            'incoming.zip',
            _slotZip32(incoming, model: 'g3'),
          )
          .ok,
      isTrue,
    );
    expect(controller.canStart, isTrue);
    await controller.start();

    expect(controller.stage, StageState.ok);
    expect(events, ['read', 'download', 'program', 'reset']);
    expect(downloaded, backup);
    expect(session.programAddress, 0x08001000);
    expect(session.programBytes, incoming);
  });

  test(
    'browser guarded slot-0 flash rejects a target mismatch before writing',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'defaultAutoRetry': 0,
      });
      var downloads = 0;
      final session = _FakeSession(
        bytes: _identifiedImage(banner: 'SCOOTER_VCU_xxG3'),
      );
      final controller = AppController(
        backend: SwdartBackend(sessionFactory: () => session),
        browserMode: true,
        backupDownloader: (_, _) async => downloads++,
      );
      addTearDown(controller.dispose);
      await Future<void>.delayed(Duration.zero);

      controller.selectAction('flash_backup');
      controller.setFlashScope(FlashScope.slot0);
      final incoming = _identifiedSlotImage(banner: 'SCOOTER_VCU_xxU2');
      expect(
        controller
            .loadSlotFirmwareFromZipBytes(
              'incoming.zip',
              _slotZip32(incoming, model: 'zt3'),
            )
            .ok,
        isTrue,
      );
      await controller.start();

      expect(controller.stage, StageState.fail);
      expect(downloads, 1);
      expect(session.programBytes, isNull);
      expect(controller.sub, contains('Incompatible firmware can brick'));
    },
  );

  test(
    'browser slot-0 selection and Flash Only refresh use slot rules',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final controller = AppController(
        backend: SwdartBackend(sessionFactory: _FakeSession.new),
        browserMode: true,
        backupDownloader: (_, _) async {},
      );
      addTearDown(controller.dispose);
      await Future<void>.delayed(Duration.zero);

      controller.selectAction('flash_only');
      controller.setFlashScope(FlashScope.slot0);
      expect(
        controller
            .selectFirmwareBytes('incoming.bin', _identifiedSlotImage())
            .ok,
        isTrue,
      );
      expect(controller.refreshFlashOnlyInspection().ok, isTrue);
      expect(controller.firmwareInspection?.slotBin, isTrue);
    },
  );

  test('browser Backup + Flash does not program an invalid backup', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'defaultAutoRetry': 0,
    });
    var downloads = 0;
    final session = _FakeSession(bytes: Uint8List(Firmware.expectedSize));
    final controller = AppController(
      backend: SwdartBackend(sessionFactory: () => session),
      browserMode: true,
      backupDownloader: (_, _) async => downloads++,
    );
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);

    controller.selectAction('flash_backup');
    expect(
      controller.selectFirmwareBytes('incoming.bin', _identifiedImage()).ok,
      isTrue,
    );
    await controller.start();

    expect(controller.stage, StageState.fail);
    expect(downloads, 0);
    expect(session.programBytes, isNull);
  });

  test('browser Backup + Flash aborts when download dispatch fails', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'defaultAutoRetry': 0,
    });
    final session = _FakeSession(bytes: _identifiedImage());
    final controller = AppController(
      backend: SwdartBackend(sessionFactory: () => session),
      browserMode: true,
      backupDownloader: (_, _) async => throw StateError('blocked'),
    );
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);

    controller.selectAction('flash_backup');
    expect(
      controller.selectFirmwareBytes('incoming.bin', _identifiedImage()).ok,
      isTrue,
    );
    await controller.start();

    expect(controller.stage, StageState.fail);
    expect(session.programBytes, isNull);
    expect(controller.sub, contains('Nothing was written'));
  });

  test(
    'browser Backup + Flash downloads but does not program a mismatch',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'defaultAutoRetry': 0,
      });
      var downloads = 0;
      final session = _FakeSession(
        bytes: _identifiedImage(banner: 'SCOOTER_VCU_xxG3'),
      );
      final controller = AppController(
        backend: SwdartBackend(sessionFactory: () => session),
        browserMode: true,
        backupDownloader: (_, _) async => downloads++,
      );
      addTearDown(controller.dispose);
      await Future<void>.delayed(Duration.zero);

      controller.selectAction('flash_backup');
      expect(
        controller
            .selectFirmwareBytes(
              'incoming.bin',
              _identifiedImage(banner: 'SCOOTER_VCU_xxU2'),
            )
            .ok,
        isTrue,
      );
      await controller.start();

      expect(controller.stage, StageState.fail);
      expect(downloads, 1);
      expect(session.programBytes, isNull);
      expect(controller.sub, contains('Nothing was written'));
    },
  );

  test('browser firmware selection rejects invalid full images', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final controller = AppController(
      backend: SwdartBackend(sessionFactory: _FakeSession.new),
      browserMode: true,
      backupDownloader: (_, _) async {},
    );
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);
    controller.selectAction('flash_backup');

    expect(
      controller.selectFirmwareBytes('incoming.txt', _identifiedImage()).ok,
      isFalse,
    );
    expect(
      controller.selectFirmwareBytes('incoming.bin', Uint8List(12)).ok,
      isFalse,
    );
    expect(
      controller
          .selectFirmwareBytes('incoming.bin', Uint8List(Firmware.expectedSize))
          .ok,
      isFalse,
    );
    expect(controller.firmwarePath, isNull);
    expect(controller.canStart, isFalse);
  });
}
