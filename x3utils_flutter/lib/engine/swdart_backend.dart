import 'dart:async';
import 'dart:typed_data';

import '../models.dart';
import 'hardware_backend.dart';
import 'sram_identity.dart';
import 'swd/probe.dart' show GuidedConnectEvent, GuidedConnectStage;
import 'swd/swd.dart' as swd;
import 'swd/transport.dart';
import 'swd/transport_open.dart';

const int _flashBase = 0x08000000;
const int _slot0Base = 0x08001000;
const int _backupLength = 131072;

/// Option/USD word; FAP is its low byte. `0xA5` there means access protection
/// is disabled on Artery AT32.
const int _usdBase = 0x1ffff800;
const int _fapUnlocked = 0xa5;

/// The small swdart surface needed by the x3utils WebUSB backend.
///
/// Keeping this injectable lets controller/backend tests prove policy without
/// opening USB or touching hardware.
abstract interface class SwdartSession {
  void onLog(void Function(String line) sink);

  void onGuided(void Function(GuidedConnectEvent event) sink);

  void onRace(void Function(swd.RaceConnectEvent event) sink);

  Future<swd.TargetInfo> connect(swd.ConnectMode mode, {int countdown = 0});

  Future<Uint8List> readFlash({required int address, required int length});

  Future<Uint8List> readSram({required int address, required int length});

  Future<void> programFlash({
    required int address,
    required Uint8List bytes,
    required void Function(swd.FlashProgramStage stage) onStage,
  });

  Future<void> resetRun({
    required void Function(swd.FlashProgramStage stage) onStage,
  });

  Future<void> rescueProtection({
    required void Function(swd.ProtectionRescueStage stage) onStage,
  });

  bool continueConnect();

  void abort();

  Future<void> disconnect();
}

class SwdartProbeSession implements SwdartSession {
  SwdartProbeSession({
    swd.Probe? probe,
    bool useAt32Loader = true,
    bool loaderDiagnostics = false,
  }) : _probe =
           probe ??
           swd.Probe(
             useAt32Loader: useAt32Loader,
             loaderDiagnostics: loaderDiagnostics,
           );

  final swd.Probe _probe;

  /// The x3utils WebUSB path opts into the hardware-tested AT32 SRAM loader.
  bool get usesAt32Loader => _probe.useAt32Loader;

  /// Opt-in verbose SRAM-loader diagnostics (baseline + per-chunk logs).
  bool get usesLoaderDiagnostics => _probe.loaderDiagnostics;

  @override
  void onLog(void Function(String line) sink) => _probe.onLog(sink);

  @override
  void onGuided(void Function(GuidedConnectEvent event) sink) =>
      _probe.onGuided(sink);

  @override
  void onRace(void Function(swd.RaceConnectEvent event) sink) =>
      _probe.onRace(sink);

  @override
  Future<swd.TargetInfo> connect(swd.ConnectMode mode, {int countdown = 0}) =>
      _probe.connect(mode, countdown: countdown);

  @override
  Future<Uint8List> readFlash({required int address, required int length}) =>
      _probe.readFlash(address: address, length: length);

  @override
  Future<Uint8List> readSram({required int address, required int length}) =>
      _probe.readSram(address: address, length: length);

  @override
  Future<void> programFlash({
    required int address,
    required Uint8List bytes,
    required void Function(swd.FlashProgramStage stage) onStage,
  }) => _probe.program(address, bytes, onStage: onStage);

  @override
  Future<void> resetRun({
    required void Function(swd.FlashProgramStage stage) onStage,
  }) => _probe.resetRun(onStage: onStage);

  @override
  Future<void> rescueProtection({
    required void Function(swd.ProtectionRescueStage stage) onStage,
  }) => _probe.rescueProtection(onStage: onStage);

  @override
  bool continueConnect() => _probe.continueConnect();

  @override
  void abort() => _probe.abort();

  @override
  Future<void> disconnect() => _probe.disconnect();
}

typedef SwdartSessionFactory = SwdartSession Function();

/// AT32F415 backend powered by swdart.
///
/// Plain SWD supports Check, 128 KiB Backup, and full-image or slot-0
/// programming of any 128 KiB AT32F415 with 1024 B pages — the packages differ
/// only in pin count, which never reaches the programming path. Desktop may
/// additionally enable clone-C45 guided attach, genuine-probe nRST, and
/// Power-race. FAP Check is read-only; Unlock / rescue uses the deterministic
/// USD erase plus FAP-only rewrite behind the same geometry gate.
class SwdartBackend implements HardwareBackend, HardwareDeviceBackend {
  SwdartBackend({
    SwdartSessionFactory? sessionFactory,
    this.enableCloneC45 = false,
    this.enableGenuineNrst = false,
    this.enablePowerRace = false,
    this.capabilityOverride,
  }) : _deviceStatus = _toHardwareDeviceStatus(initialStlinkStatus) {
    _sessionFactory =
        sessionFactory ??
        () => SwdartProbeSession(
          useAt32Loader: useAt32Loader,
          loaderDiagnostics: loaderDiagnostics,
        );
    watchStlinkSelection((status) {
      _deviceStatus = _toHardwareDeviceStatus(status);
      _deviceDisconnected =
          _deviceStatus.state == HardwareDeviceState.disconnected;
      if (_deviceDisconnected) _activeSession?.abort();
      _deviceListener?.call(_deviceStatus);
    });
  }

  late final SwdartSessionFactory _sessionFactory;
  final bool enableCloneC45;
  final bool enableGenuineNrst;
  final bool enablePowerRace;
  final HardwareCapabilities? capabilityOverride;

  /// Opt-in verbose SRAM-loader diagnostics for sessions this backend creates.
  /// Read at session creation, so a settings change applies to the next run.
  bool loaderDiagnostics = false;

  /// Selects the programming implementation for sessions this backend creates.
  /// Desktop exposes this as an experimental A/B setting; Web and Android keep
  /// the default loader path unless their constructors explicitly opt out.
  bool useAt32Loader = true;
  SwdartSession? _activeSession;
  bool _cancelled = false;
  bool _deviceDisconnected = false;
  HardwareDeviceStatus _deviceStatus;
  HardwareDeviceStatusListener? _deviceListener;

  @override
  String get name => 'swdart';

  @override
  HardwareDeviceStatus get deviceStatus => _deviceStatus;

  @override
  Future<HardwareDeviceStatus> refreshDevice() async {
    _deviceStatus = _toHardwareDeviceStatus(await refreshStlinkSelection());
    return _deviceStatus;
  }

  @override
  Future<HardwareDeviceStatus> selectDevice() async {
    try {
      _deviceStatus = _toHardwareDeviceStatus(await selectStlink());
      return _deviceStatus;
    } on UsbAcquireException catch (error) {
      throw _toHardwareException(error);
    }
  }

  @override
  void watchDevice(HardwareDeviceStatusListener listener) {
    _deviceListener = listener;
  }

  @override
  HardwareCapabilities get capabilities =>
      capabilityOverride ??
      HardwareCapabilities(
        connectionModes: {
          ConnectionMode.defaultSwd,
          if (enableCloneC45) ConnectionMode.cloneC45,
          if (enableGenuineNrst) ConnectionMode.genuineC45,
          if (enablePowerRace) ConnectionMode.powerRace,
        },
        check: true,
        dump: true,
        flashFull: true,
        flashSlot0: true,
        protectionCheck: true,
        protectionRescue: true,
        extraBackup: true,
      );

  swd.ConnectMode _connectMode(ConnectionMode mode) => switch (mode) {
    ConnectionMode.defaultSwd => swd.ConnectMode.normal,
    ConnectionMode.cloneC45 => swd.ConnectMode.guided,
    ConnectionMode.genuineC45 => swd.ConnectMode.underReset,
    ConnectionMode.powerRace => swd.ConnectMode.attachRace,
  };

  @override
  Future<HardwareResult> run(
    HardwareRequest request,
    HardwareCallbacks callbacks,
  ) async {
    if (!capabilities.supports(request.operation, request.mode)) {
      throw UnsupportedError(
        '$name does not support ${request.operation.name} in ${request.mode.title}',
      );
    }
    if (request.extraBackup &&
        (request.operation != HardwareOperation.dump ||
            !capabilities.extraBackup)) {
      throw UnsupportedError(
        '$name does not support Extra backup for this request',
      );
    }
    final isFlash =
        request.operation == HardwareOperation.flashFull ||
        request.operation == HardwareOperation.flashSlot0;
    final programBytes = isFlash ? request.bytes : null;
    if (request.operation == HardwareOperation.flashFull &&
        programBytes?.length != _backupLength) {
      throw StateError(
        'swdart full-image flash requires exactly $_backupLength bytes',
      );
    }
    if (request.operation == HardwareOperation.flashSlot0 &&
        (programBytes == null ||
            programBytes.isEmpty ||
            programBytes.length > _backupLength - (_slot0Base - _flashBase))) {
      throw StateError(
        'swdart slot-0 flash requires 1 to '
        '${_backupLength - (_slot0Base - _flashBase)} bytes',
      );
    }

    final session = _sessionFactory();
    _activeSession = session;
    _cancelled = false;
    _deviceDisconnected =
        _deviceStatus.state == HardwareDeviceState.disconnected;
    session.onLog(callbacks.onLine);
    session.onGuided((event) {
      callbacks.onGuided(
        HardwareGuidedEvent(switch (event.stage) {
          GuidedConnectStage.hold => HardwareGuidedStage.hold,
          GuidedConnectStage.count => HardwareGuidedStage.count,
          GuidedConnectStage.release => HardwareGuidedStage.release,
        }, countdown: event.countdown),
      );
    });
    session.onRace((event) {
      if (event.caught) {
        callbacks.onCaught();
        return;
      }
      callbacks.onAttempt(event.attempt, switch (event.tier) {
        swd.RaceConnectTier.searching => HardwareRaceTier.searching,
        swd.RaceConnectTier.noisy => HardwareRaceTier.noisy,
        swd.RaceConnectTier.nearCatch => HardwareRaceTier.nearCatch,
        swd.RaceConnectTier.adapterGone => HardwareRaceTier.adapterGone,
        swd.RaceConnectTier.timedOut => HardwareRaceTier.timedOut,
      });
    });

    try {
      final swd.TargetInfo target;
      try {
        target = await session.connect(
          _connectMode(request.mode),
          countdown: request.countdown,
        );
      } catch (error) {
        throw _translateConnectError(error);
      }
      _throwIfCancelled();
      _requireKnownAt32f415(target);
      if (request.mode == ConnectionMode.cloneC45) {
        callbacks.onGuided(
          const HardwareGuidedEvent(HardwareGuidedStage.connected),
        );
      }
      callbacks.onProgress(const HardwareProgress(connected: true));

      if (request.operation == HardwareOperation.check) {
        return const HardwareResult(0, HardwareEvidence(caught: true));
      }

      if (isFlash) {
        _requireWritableTarget(target);
        var erased = false;
        var wrote = false;
        var verified = false;
        var resetRunning = false;
        try {
          await session.programFlash(
            address: request.operation == HardwareOperation.flashSlot0
                ? _slot0Base
                : _flashBase,
            bytes: programBytes!,
            onStage: (stage) {
              switch (stage) {
                case swd.FlashProgramStage.ready:
                  break;
                case swd.FlashProgramStage.erased:
                  erased = true;
                case swd.FlashProgramStage.wrote:
                  wrote = true;
                case swd.FlashProgramStage.verified:
                  verified = true;
                case swd.FlashProgramStage.resetRunning:
                  resetRunning = true;
              }
            },
          );
          _throwIfCancelled();
          if (!erased || !wrote || !verified) {
            throw StateError(
              'swdart programming ended without erase/write/verify evidence',
            );
          }
          await session.resetRun(
            onStage: (stage) {
              if (stage == swd.FlashProgramStage.resetRunning) {
                resetRunning = true;
              }
            },
          );
          if (!resetRunning) {
            throw StateError(
              'swdart reset ended without reset-running evidence',
            );
          }
          return HardwareResult(
            0,
            HardwareEvidence(
              caught: true,
              erased: erased,
              wrote: wrote,
              verified: verified,
              resetRunning: resetRunning,
            ),
          );
        } catch (error) {
          if (error is UsbAcquireException) rethrow;
          callbacks.onLine('[flash] failed: $error');
          return HardwareResult(
            1,
            HardwareEvidence(
              caught: true,
              erased: erased,
              wrote: wrote,
              verified: verified,
              resetRunning: resetRunning,
            ),
          );
        }
      }

      if (target.flashKB != 128) {
        throw StateError(
          'x3utils Backup requires a 128 KiB AT32F415; detected ${target.flashKB} KiB',
        );
      }
      // Extra backup only: classify readout protection BEFORE the expensive
      // reads. A protected AT32F415 masks flash to 0x00, so the two 128 KiB
      // reads would return a pair of zero images that compare equal — a
      // vacuous "match" costing 256 KiB to learn nothing. This probe is 20
      // bytes. It may only SKIP work: solely a `protected` verdict short-
      // circuits, while inconclusive falls through to the normal full read, so
      // a 4-byte option read can never deny anyone a backup.
      int? usdWord;
      var protectedNoRead = false;
      if (request.extraBackup) {
        try {
          final usd = await session.readFlash(address: _usdBase, length: 4);
          if (usd.length >= 4) usdWord = _u32le(usd, 0);
        } catch (error) {
          callbacks.onLine('[extra] warning: option area read failed: $error');
        }
        List<int>? probeWords;
        try {
          final head = await session.readFlash(address: _flashBase, length: 16);
          if (head.length >= 16) {
            probeWords = <int>[for (var i = 0; i < 16; i += 4) _u32le(head, i)];
          }
        } catch (error) {
          callbacks.onLine('[extra] warning: flash probe read failed: $error');
        }
        final early = classifySwdartProtection(
          usdWord: usdWord,
          flashWords: probeWords,
        );
        callbacks.onLine('[extra] protection probe: ${early.verdict.name}');
        protectedNoRead = early.verdict == HardwareProtectionVerdict.protected;
        if (protectedNoRead) {
          callbacks.onLine(
            '[extra] flash is read-protected — skipping the 128 KiB reads; '
            'capturing SRAM only',
          );
        }
        _throwIfCancelled();
      }
      Uint8List? sramBytes;
      final captureSram = request.captureSram || request.extraBackup;
      if (captureSram) {
        try {
          sramBytes = await session.readSram(
            address: kSramBase,
            length: target.sramBytes,
          );
          if (sramBytes.length != target.sramBytes) {
            callbacks.onLine(
              '[sram] warning: received ${sramBytes.length} of '
              '${target.sramBytes} bytes; ignoring snapshot',
            );
            sramBytes = null;
          }
        } catch (error) {
          callbacks.onLine('[sram] warning: snapshot failed: $error');
        }
      }
      if (protectedNoRead) {
        // Read-only diagnostic outcome: no backup bytes exist, but the SRAM
        // snapshot and protection evidence do. The controller decides what to
        // save; this stays evidence, never a green result.
        return HardwareResult(
          0,
          HardwareEvidence(
            caught: true,
            dumped: false,
            sramAttempted: captureSram,
          ),
          sramBytes: sramBytes,
          extraBackupEvidence: ExtraBackupHardwareEvidence(
            targetName: target.name,
            targetFamily: target.family,
            idcode: target.idcode,
            flashKB: target.flashKB,
            pageSize: target.pageSize,
            sramBytes: target.sramBytes,
            usdWord: usdWord,
            flashReadSkipped: true,
          ),
        );
      }
      final bytes = await session.readFlash(
        address: _flashBase,
        length: _backupLength,
      );
      _throwIfCancelled();
      if (bytes.length != _backupLength) {
        throw StateError(
          'swdart returned ${bytes.length} of $_backupLength backup bytes',
        );
      }
      Uint8List? comparisonBytes;
      if (request.extraBackup) {
        comparisonBytes = await session.readFlash(
          address: _flashBase,
          length: _backupLength,
        );
        _throwIfCancelled();
        if (comparisonBytes.length != _backupLength) {
          throw StateError(
            'swdart returned ${comparisonBytes.length} of $_backupLength '
            'comparison bytes',
          );
        }
      }
      return HardwareResult(
        0,
        HardwareEvidence(
          caught: true,
          dumped: true,
          sramAttempted: captureSram,
        ),
        bytes: bytes,
        sramBytes: sramBytes,
        comparisonBytes: comparisonBytes,
        extraBackupEvidence: request.extraBackup
            ? ExtraBackupHardwareEvidence(
                targetName: target.name,
                targetFamily: target.family,
                idcode: target.idcode,
                flashKB: target.flashKB,
                pageSize: target.pageSize,
                sramBytes: target.sramBytes,
                usdWord: usdWord,
              )
            : null,
      );
    } on UsbAcquireException catch (error) {
      throw _toHardwareException(error);
    } finally {
      if (identical(_activeSession, session)) _activeSession = null;
      await session.disconnect();
    }
  }

  /// Flash Access Protection (FAP) check or destructive rescue.
  @override
  Future<HardwareProtectionResult> runProtection(
    HardwareProtectionRequest request,
    HardwareProtectionCallbacks callbacks,
  ) async {
    if (request.mode == ConnectionMode.powerRace) {
      throw UnsupportedError(
        '$name does not support protection operations in Power-race',
      );
    }
    if (!capabilities.supportsProtection(request.operation, request.mode)) {
      throw UnsupportedError(
        '$name does not support ${request.operation.name} in '
        '${request.mode.title}',
      );
    }

    final session = _sessionFactory();
    _activeSession = session;
    _cancelled = false;
    _deviceDisconnected =
        _deviceStatus.state == HardwareDeviceState.disconnected;
    session.onLog(callbacks.onLine);
    session.onGuided((event) {
      callbacks.onGuided(
        HardwareGuidedEvent(switch (event.stage) {
          GuidedConnectStage.hold => HardwareGuidedStage.hold,
          GuidedConnectStage.count => HardwareGuidedStage.count,
          GuidedConnectStage.release => HardwareGuidedStage.release,
        }, countdown: event.countdown),
      );
    });

    try {
      try {
        final swd.TargetInfo target;
        try {
          target = await session.connect(
            _connectMode(request.mode),
            countdown: request.countdown,
          );
        } catch (error) {
          throw _translateConnectError(error);
        }
        _throwIfCancelled();
        if (request.operation == HardwareProtectionOperation.rescue) {
          _requireWritableTarget(target);
        } else {
          _requireKnownAt32f415(target);
        }
        if (request.mode == ConnectionMode.cloneC45) {
          callbacks.onGuided(
            const HardwareGuidedEvent(HardwareGuidedStage.connected),
          );
        }
      } catch (error) {
        if (request.operation == HardwareProtectionOperation.rescue) rethrow;
        callbacks.onLine(
          '[protection] could not reach/identify the target: '
          '$error',
        );
        return const HardwareProtectionResult(
          3,
          HardwareProtectionVerdict.inconclusive,
        );
      }
      // Await here: a bare `return _readProtection(...)` lets the finally's
      // disconnect race the reads and kill the probe mid-read, which would
      // report every chip as protected.
      if (request.operation == HardwareProtectionOperation.check) {
        return await _readProtection(session, callbacks);
      }

      var usdErased = false;
      var fapProgrammed = false;
      try {
        await session.rescueProtection(
          onStage: (stage) {
            switch (stage) {
              case swd.ProtectionRescueStage.usdErased:
                usdErased = true;
              case swd.ProtectionRescueStage.fapProgrammed:
                fapProgrammed = true;
            }
          },
        );
      } catch (error) {
        final stage = fapProgrammed
            ? 'after FAP programming'
            : usdErased
            ? 'after USD erase, during FAP programming'
            : 'before USD erase completed';
        callbacks.onLine('[protection] rescue failed $stage: $error');
        callbacks.onLine(
          '[protection] unplug/replug ST-LINK before retrying Rescue',
        );
        rethrow;
      }
      if (!usdErased || !fapProgrammed) {
        throw StateError(
          'swdart rescue ended without USD-erase/FAP-program evidence',
        );
      }
      callbacks.onLine(
        '[protection] FAP disabled — the chip erased its flash and reset. '
        'Power-cycle and reconnect, then run Check protection.',
      );
      return const HardwareProtectionResult(
        0,
        HardwareProtectionVerdict.rescued,
      );
    } on UsbAcquireException catch (error) {
      throw _toHardwareException(error);
    } finally {
      if (identical(_activeSession, session)) _activeSession = null;
      await session.disconnect();
    }
  }

  /// Read the option/USD word and the flash vector table, then grade. A refused
  /// read is retained as unavailable evidence rather than treated as a masked
  /// bus: actual FAP masking returns all-zero bytes on the tested AT32F415,
  /// while a transport/contact fault throws. Each read is independent so
  /// decisive evidence from the other region can still produce a verdict.
  Future<HardwareProtectionResult> _readProtection(
    SwdartSession session,
    HardwareProtectionCallbacks callbacks,
  ) async {
    int? usdWord;
    try {
      final usd = await session.readFlash(address: _usdBase, length: 4);
      if (usd.length >= 4) usdWord = _u32le(usd, 0);
    } catch (error) {
      callbacks.onLine('[protection] option area read refused: $error');
    }
    List<int>? flashWords;
    try {
      final vt = await session.readFlash(address: _flashBase, length: 16);
      if (vt.length >= 16) {
        flashWords = [for (var i = 0; i < 16; i += 4) _u32le(vt, i)];
      }
    } catch (error) {
      callbacks.onLine('[protection] main flash read refused: $error');
    }
    _emitProtectionEvidence(usdWord, flashWords, callbacks.onLine);
    final result = classifySwdartProtection(
      usdWord: usdWord,
      flashWords: flashWords,
    );
    callbacks.onLine('[protection] verdict: ${result.verdict.name}');
    return result;
  }

  @override
  bool sendContinue({required bool protection}) =>
      _activeSession?.continueConnect() ?? false;

  @override
  void cancel() {
    _cancelled = true;
    final session = _activeSession;
    if (session == null) return;
    session.abort();
    unawaited(session.disconnect());
  }

  void _throwIfCancelled() {
    if (_cancelled) throw StateError('swdart operation cancelled');
  }

  void _requireKnownAt32f415(swd.TargetInfo target) {
    final assumed = target.name.toLowerCase().contains('assumed');
    if (target.family != 'AT32' ||
        !target.name.startsWith('AT32F415') ||
        assumed) {
      throw StateError(
        'Unsupported target: ${target.name}. '
        'Only explicitly identified AT32F415 targets are allowed.',
      );
    }
  }

  /// Writes are allowed on any 128 KiB AT32F415, not just the CBT7 that was
  /// hardware-tested first.
  ///
  /// The five 128 KiB parts — `RBT7`, `CBT7`, `KBU7-4`, `RBT7-7`, `CBU7` —
  /// differ only in package and pin count, which never reach the programming
  /// path: [At32Flash] is built from `pageSize` and `sramBytes` alone, and
  /// `sramBytes` is a constant 32 KiB for every row of the table. The GEOMETRY
  /// is therefore the real requirement and is checked directly. The 64 KiB
  /// parts cannot hold the image and the 256 KiB parts use 2048 B pages with a
  /// different layout, so both are still refused.
  ///
  /// `TargetInfo.tested` is deliberately NOT consulted any more. It stays in
  /// the table as a record of which part someone put an ST-Link on, and is
  /// reported rather than enforced.
  void _requireWritableTarget(swd.TargetInfo target) {
    // Repeated from the connect path so the write gate stands on its own
    // rather than relying on a caller having already checked the family.
    _requireKnownAt32f415(target);
    if (target.flashKB != 128 || target.pageSize != 1024) {
      throw StateError(
        'Writing requires a 128 KiB AT32F415 with 1024 B pages; '
        'detected ${target.name}',
      );
    }
  }

  HardwareException _translateConnectError(Object error) {
    if (error is HardwareException) return error;
    if (error is UsbAcquireException) return _toHardwareException(error);
    if (_deviceDisconnected) {
      return const HardwareException(
        HardwareFailureKind.deviceDisconnected,
        'The selected ST-Link disconnected.',
      );
    }
    if (_cancelled) {
      return const HardwareException(
        HardwareFailureKind.userCancelled,
        'Hardware operation cancelled.',
      );
    }
    return HardwareException(HardwareFailureKind.targetContact, '$error');
  }
}

HardwareDeviceStatus _toHardwareDeviceStatus(UsbDeviceStatus status) =>
    HardwareDeviceStatus(switch (status.state) {
      UsbDeviceState.unsupported => HardwareDeviceState.unsupported,
      UsbDeviceState.selectionRequired => HardwareDeviceState.selectionRequired,
      UsbDeviceState.ready => HardwareDeviceState.ready,
      UsbDeviceState.disconnected => HardwareDeviceState.disconnected,
      UsbDeviceState.ambiguous => HardwareDeviceState.ambiguous,
    }, productName: status.productName);

HardwareException _toHardwareException(
  UsbAcquireException error,
) => HardwareException(switch (error.kind) {
  UsbAcquireFailureKind.userCancelled => HardwareFailureKind.userCancelled,
  UsbAcquireFailureKind.permissionRequired =>
    HardwareFailureKind.permissionRequired,
  UsbAcquireFailureKind.unsupported => HardwareFailureKind.unsupported,
  UsbAcquireFailureKind.disconnected => HardwareFailureKind.deviceDisconnected,
  UsbAcquireFailureKind.ambiguous => HardwareFailureKind.deviceAmbiguous,
  UsbAcquireFailureKind.unavailable => HardwareFailureKind.deviceUnavailable,
  UsbAcquireFailureKind.busy => HardwareFailureKind.deviceBusy,
}, error.message);

int _u32le(Uint8List b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

String _hex32(int v) => '0x${v.toRadixString(16).padLeft(8, '0')}';
String _hex8(int v) => '0x${v.toRadixString(16).padLeft(2, '0').toUpperCase()}';

/// Classify the flash vector table once, shared by the verdict ladder and the
/// evidence line so they cannot disagree. [words] is null when the read was
/// refused/faulted (a blocked bus).
({bool accessible, bool blocked, String label}) _classifyFlash(
  List<int>? words,
) {
  if (words == null) {
    return (accessible: false, blocked: false, label: 'unreadable');
  }
  if ((words[0] & 0xff000000) == 0x20000000) {
    return (
      accessible: true,
      blocked: false,
      label: 'firmware present (MSP in SRAM)',
    );
  }
  if (words.every((w) => w == 0xffffffff)) {
    return (accessible: true, blocked: false, label: 'blank/erased, readable');
  }
  if (words.every((w) => w == 0x00000000)) {
    return (accessible: false, blocked: true, label: 'masked (all 0x00)');
  }
  return (accessible: false, blocked: false, label: 'unclassified');
}

/// Print the raw reads behind the verdict, mirroring the OpenOCD rdp tool's
/// Evidence section so a swdart verdict can be cross-checked from the log.
void _emitProtectionEvidence(
  int? usdWord,
  List<int>? flashWords,
  void Function(String line) onLine,
) {
  if (usdWord != null) {
    final fap = usdWord & 0xff;
    final fapComp = (usdWord >> 8) & 0xff;
    final ssb = (usdWord >> 16) & 0xff;
    final ssbComp = (usdWord >> 24) & 0xff;
    final comp = (fap ^ fapComp) == 0xff
        ? 'complement consistent'
        : 'complement inconsistent';
    onLine(
      '[protection] USD @ 0x1FFFF800 = ${_hex32(usdWord)}  '
      'FAP=${_hex8(fap)} FAP_COMP=${_hex8(fapComp)} '
      'SSB=${_hex8(ssb)} SSB_COMP=${_hex8(ssbComp)} [$comp]',
    );
  } else {
    onLine('[protection] USD @ 0x1FFFF800 unreadable');
  }
  if (flashWords != null) {
    onLine(
      '[protection] flash @ 0x08000000 = ${flashWords.map(_hex32).join(' ')} '
      '[${_classifyFlash(flashWords).label}]',
    );
  } else {
    onLine('[protection] flash @ 0x08000000 unreadable');
  }
}

/// Grade a FAP check from two reads. Pure so every branch is unit-testable
/// without hardware. Mirrors the field-proven `special/rdp/rdp_check.sh`
/// ladder; the connection-failure and unidentified-target cases are handled by
/// the caller (both become inconclusive before this runs).
///
/// [usdWord] is the option/USD word at 0x1FFFF800, or null when the option
/// area could not be read. [flashWords] are the four words of the flash vector
/// table at 0x08000000, or null when the read was refused/faulted. A null read
/// is unknown rather than blocked; the hardware-observed blocked signature is
/// four returned all-zero words.
///
/// Exit codes match the OpenOCD path: 0 not protected, 2 read protected,
/// 3 inconclusive.
HardwareProtectionResult classifySwdartProtection({
  required int? usdWord,
  required List<int>? flashWords,
}) {
  const notProtected = HardwareProtectionResult(
    0,
    HardwareProtectionVerdict.notProtected,
  );
  const protected = HardwareProtectionResult(
    2,
    HardwareProtectionVerdict.protected,
  );
  const inconclusive = HardwareProtectionResult(
    3,
    HardwareProtectionVerdict.inconclusive,
  );

  final fapRead = usdWord != null;
  final fap = fapRead ? usdWord & 0xff : 0;
  final fapComp = fapRead ? (usdWord >> 8) & 0xff : 0;
  final fapUnlocked = fapRead && fap == _fapUnlocked;
  final fapCompOk = fapRead && (fap ^ fapComp) == 0xff;

  // firmware (MSP in SRAM) or blank 0xFF => the bus returned real, readable
  // data; returned masked 0x00 => the bus is blocked. An errored read is
  // unavailable evidence and cannot by itself prove protection. A protected
  // AT32F415 masks flash to returned 0x00 bytes on the tested hardware and can
  // never return readable flash.
  final flash = _classifyFlash(flashWords);

  // Contradiction guard: a non-0xA5 FAP byte alongside readable flash is a
  // glitched option read, not protection — readable flash is decisive.
  if (flash.accessible && fapRead && !fapUnlocked) return notProtected;
  if (fapRead && !fapUnlocked) return protected;
  if (fapRead && fapUnlocked && fapCompOk) return notProtected;
  if (fapRead && fapUnlocked) {
    // 0xA5 low byte but an invalid complement: a masked/garbled option read.
    return flash.blocked ? protected : inconclusive;
  }
  // Option word unreadable but the adapter was reachable.
  if (flash.accessible) return notProtected;
  if (flash.blocked) return protected;
  return inconclusive;
}
