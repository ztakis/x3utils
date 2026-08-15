import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:x3utils_flutter/app_controller.dart';
import 'package:x3utils_flutter/engine/hardware_backend.dart';
import 'package:x3utils_flutter/engine/openocd_paths.dart';
import 'package:x3utils_flutter/engine/openocd_runner.dart';
import 'package:x3utils_flutter/models.dart';

/// Replays scripted OpenOCD output instead of launching a process, so the
/// auto-retry gate can be exercised without hardware. Both entry points are
/// overridden — an un-overridden runRace would start a real openocd.
class _ScriptedRunner extends OpenOcdRunner {
  _ScriptedRunner({required this.lines, required this.exitCode})
    : super(OpenOcdPaths('openocd', 'scripts'));

  final List<String> lines;
  final int exitCode;
  int runs = 0;

  OpenOcdResult _replay(void Function(String) onLine) {
    runs++;
    final evidence = OpenOcdEvidence();
    for (final line in lines) {
      evidence.record(line);
      onLine(line);
    }
    return OpenOcdResult(exitCode, evidence);
  }

  @override
  Future<OpenOcdResult> run(
    List<String> args,
    void Function(String line) onLine,
  ) async => _replay(onLine);

  @override
  Future<OpenOcdResult> runRace(
    List<String> args, {
    required void Function(String line) onLine,
    required void Function(int attempt, RaceTier tier) onAttempt,
    void Function()? onCaught,
  }) async => _replay(onLine);
}

class _WebFailureBackend implements HardwareBackend, HardwareDeviceBackend {
  _WebFailureBackend(this._status, {this.runFailure, this.selectFailure});

  HardwareDeviceStatus _status;
  final HardwareException? runFailure;
  final HardwareException? selectFailure;
  HardwareDeviceStatusListener? _listener;

  @override
  String get name => 'fake WebUSB';

  @override
  HardwareCapabilities get capabilities => const HardwareCapabilities(
    connectionModes: {ConnectionMode.defaultSwd},
    check: true,
    dump: true,
    flashFull: true,
    flashSlot0: true,
    protectionCheck: true,
    protectionRescue: false,
  );

  @override
  HardwareDeviceStatus get deviceStatus => _status;

  @override
  Future<HardwareDeviceStatus> refreshDevice() async => _status;

  @override
  Future<HardwareDeviceStatus> selectDevice() async {
    final failure = selectFailure;
    if (failure != null) throw failure;
    _status = const HardwareDeviceStatus(
      HardwareDeviceState.ready,
      productName: 'Fake ST-Link',
    );
    _listener?.call(_status);
    return _status;
  }

  @override
  void watchDevice(HardwareDeviceStatusListener listener) {
    _listener = listener;
  }

  @override
  Future<HardwareResult> run(
    HardwareRequest request,
    HardwareCallbacks callbacks,
  ) async {
    final failure = runFailure;
    if (failure != null) throw failure;
    return const HardwareResult(0, HardwareEvidence(caught: true));
  }

  @override
  Future<HardwareProtectionResult> runProtection(
    HardwareProtectionRequest request,
    HardwareProtectionCallbacks callbacks,
  ) => throw UnsupportedError('not used');

  @override
  bool sendContinue({required bool protection}) => false;

  @override
  void cancel() {}
}

Future<({AppController controller, _ScriptedRunner runner})> _harness({
  required List<String> lines,
  required int exitCode,
  int autoRetry = 3,
}) async {
  SharedPreferences.setMockInitialValues({'defaultAutoRetry': autoRetry});
  final runner = _ScriptedRunner(lines: lines, exitCode: exitCode);
  final controller = AppController(runner: runner);
  addTearDown(controller.dispose);
  await Future<void>.delayed(Duration.zero); // let _loadPrefs settle
  return (controller: controller, runner: runner);
}

Future<AppController> _controller({
  required List<String> lines,
  required int exitCode,
  int autoRetry = 3,
}) async {
  final harness = await _harness(
    lines: lines,
    exitCode: exitCode,
    autoRetry: autoRetry,
  );
  return harness.controller;
}

void main() {
  // A connect that never reached the core is the whole point of the feature.
  const noContact = [
    'Error: init mode failed (unable to connect to the target)',
  ];
  // Every marker that proves the run got past connect. The flash-bank driver
  // name is per-OS, so both spellings of the probe line are covered.
  const pastConnectEvidence = <String>[
    'target halted due to debug-request',
    'Connected.  Ready to flash.',
    "Info : flash 'at32f415xx' found at 0x08000000",
    "Info : flash 'artery' found at 0x08000000",
    'dumped 131072 bytes',
    'erased 128 KiB',
    'wrote 131072 bytes',
    'Write failed (chip half-written)',
    'verified 131072 bytes',
  ];

  test('WebUSB chooser cancellation stays idle and never arms retry', () async {
    SharedPreferences.setMockInitialValues({'defaultAutoRetry': 3});
    final backend = _WebFailureBackend(
      const HardwareDeviceStatus(HardwareDeviceState.selectionRequired),
      selectFailure: const HardwareException(
        HardwareFailureKind.userCancelled,
        'No device selected.',
      ),
    );
    final controller = AppController(backend: backend, browserMode: true);
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);

    expect(controller.canStart, isFalse);
    expect(controller.backendStatusLabel, 'Select ST-Link');
    await controller.selectDeviceProbe();

    expect(controller.stage, StageState.idle);
    expect(controller.autoRetryArmed, isFalse);
    expect(controller.console.last, contains('selection cancelled'));
  });

  test('explicit WebUSB selection enables hardware actions', () async {
    SharedPreferences.setMockInitialValues({'defaultAutoRetry': 3});
    final backend = _WebFailureBackend(
      const HardwareDeviceStatus(HardwareDeviceState.selectionRequired),
    );
    final controller = AppController(backend: backend, browserMode: true);
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);

    expect(controller.canStart, isFalse);
    await controller.selectDeviceProbe();

    expect(controller.deviceProbeReady, isTrue);
    expect(controller.backendStatusLabel, 'Fake ST-Link');
    expect(controller.canStart, isTrue);
  });

  test('WebUSB disconnect failure does not start timed retries', () async {
    SharedPreferences.setMockInitialValues({'defaultAutoRetry': 3});
    final backend = _WebFailureBackend(
      const HardwareDeviceStatus(
        HardwareDeviceState.ready,
        productName: 'Fake ST-Link',
      ),
      runFailure: const HardwareException(
        HardwareFailureKind.deviceDisconnected,
        'Device disconnected.',
      ),
    );
    final controller = AppController(backend: backend, browserMode: true);
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);

    await controller.start();

    expect(controller.stage, StageState.fail);
    expect(controller.autoRetryArmed, isFalse);
    expect(controller.sub, contains('Reconnect it'));
  });

  test('desktop unavailable ST-Link retains third-hand retry', () async {
    SharedPreferences.setMockInitialValues({'defaultAutoRetry': 3});
    final backend = _WebFailureBackend(
      const HardwareDeviceStatus(
        HardwareDeviceState.ready,
        productName: 'Fake ST-Link',
      ),
      runFailure: const HardwareException(
        HardwareFailureKind.deviceUnavailable,
        'No ST-Link found on USB.',
      ),
    );
    final controller = AppController(backend: backend, browserMode: false);
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);

    await controller.start();

    expect(controller.stage, StageState.fail);
    expect(controller.autoRetryArmed, isTrue);
    expect(controller.sub, contains('unavailable'));
  });

  test('WebUSB target contact failure retains third-hand retry', () async {
    SharedPreferences.setMockInitialValues({'defaultAutoRetry': 3});
    final backend = _WebFailureBackend(
      const HardwareDeviceStatus(
        HardwareDeviceState.ready,
        productName: 'Fake ST-Link',
      ),
      runFailure: const HardwareException(
        HardwareFailureKind.targetContact,
        'No SWD response.',
      ),
    );
    final controller = AppController(backend: backend, browserMode: true);
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);

    await controller.start();

    expect(controller.stage, StageState.fail);
    expect(controller.autoRetryArmed, isTrue);
    expect(controller.sub, contains('No SWD response'));
  });

  test('arms on a connect failure and counts down', () async {
    final c = await _controller(lines: noContact, exitCode: 1);
    await c.start();

    expect(c.stage, StageState.fail);
    expect(c.autoRetryArmed, isTrue);
    expect(c.autoRetryLabel, 'Retrying in 3…  (1 of 10)');
  });

  for (final marker in pastConnectEvidence) {
    test('does not arm after target progress: $marker', () async {
      final c = await _controller(
        lines: [marker, 'Error: operation failed'],
        exitCode: 1,
      );
      await c.start();

      // Connected, then failed: a flash operation may already have started, so
      // a third hand must not repeat it unattended.
      expect(c.stage, StageState.fail);
      expect(c.autoRetryArmed, isFalse);
    });
  }

  // The runner echoes '> openocd <args>' into the same stream, and the args
  // carry the user's backup/firmware path. A folder named after one of the
  // markers must not count as target evidence — that would silently disarm
  // auto-retry on every run for that user.
  for (final dir in ['verified', 'dumped', 'erased']) {
    test('a user path containing "$dir" still arms auto-retry', () async {
      final c = await _controller(
        lines: [
          r'> openocd -s scripts -d0 -c dump_image {d:\scooter\'
              '$dir'
              r'\fw.bin} 0x08000000 0x20000',
          ...noContact,
        ],
        exitCode: 1,
      );
      await c.start();

      expect(c.stage, StageState.fail);
      expect(c.autoRetryArmed, isTrue);
    });
  }

  test(
    'retries on the timer, stops at ten, and manual retry resets it',
    () async {
      final harness = await _harness(
        lines: noContact,
        exitCode: 1,
        autoRetry: 1,
      );
      final c = harness.controller;
      await c.start();

      expect(harness.runner.runs, 1);
      for (
        var attempt = 1;
        attempt <= AppController.kAutoRetryMaxAttempts;
        attempt++
      ) {
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (harness.runner.runs < attempt + 1 &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(harness.runner.runs, attempt + 1);
        expect(c.autoRetryAttempt, attempt);
      }

      expect(c.autoRetryArmed, isFalse);

      await c.retry();

      expect(harness.runner.runs, AppController.kAutoRetryMaxAttempts + 2);
      expect(c.autoRetryAttempt, 0);
      expect(c.autoRetryArmed, isTrue);
      expect(c.autoRetryLabel, 'Retrying in 1…  (1 of 10)');
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );

  test(
    'disabling auto-retry during a countdown cancels it',
    () async {
      final harness = await _harness(
        lines: noContact,
        exitCode: 1,
        autoRetry: 1,
      );
      final c = harness.controller;
      await c.start();
      expect(c.autoRetryArmed, isTrue);

      c.setDefaultAutoRetry(0);
      await Future<void>.delayed(const Duration(milliseconds: 1200));

      expect(c.autoRetryArmed, isFalse);
      expect(harness.runner.runs, 1);
      expect(c.stage, StageState.fail);
    },
    timeout: const Timeout(Duration(seconds: 5)),
  );

  test('0 disables it and restores the plain manual prompt', () async {
    final c = await _controller(lines: noContact, exitCode: 1, autoRetry: 0);
    await c.start();

    expect(c.stage, StageState.fail);
    expect(c.autoRetryArmed, isFalse);
    expect(c.failurePrimaryLabel, 'Retry');
  });

  test('does not arm in Power-race, which respawns on its own', () async {
    final c = await _controller(lines: noContact, exitCode: 1);
    c.selectMode(ConnectionMode.powerRace);
    await c.start();

    expect(c.stage, StageState.fail);
    expect(c.autoRetryArmed, isFalse);
  });

  // The protection actions drive rdp.ps1, not OpenOCD: with an injected runner
  // there is no RdpRunner, so they fail before anything could arm a timer. That
  // is exactly what must be asserted — a protection failure never leaves a
  // countdown running — while the actionId guard in _autoRetryEligible stays as
  // defence for the day one of them does reach the OpenOCD finish path.
  for (final actionId in ['rdp_check', 'rdp_rescue']) {
    test('does not arm for $actionId', () async {
      final harness = await _harness(lines: noContact, exitCode: 1);
      final c = harness.controller;
      c.selectAction(actionId);
      await c.start();

      expect(c.stage, StageState.fail);
      expect(c.autoRetryArmed, isFalse);
      expect(harness.runner.runs, 0); // never went through OpenOCD
    });
  }

  // NOTE: the "OpenOCD never launched" guard (_cannotRun) has no test here on
  // purpose. Reaching it needs an AppController built WITHOUT an injected
  // runner, and on a machine that has the bundled openocd — every dev box and
  // the packaged app — that constructor finds the real binary and start() then
  // drives whatever hardware is attached. A unit test must never do that.

  test('dismissing a failure disarms the timer', () async {
    final c = await _controller(lines: noContact, exitCode: 1);
    await c.start();
    expect(c.autoRetryArmed, isTrue);

    c.dismiss();

    expect(c.autoRetryArmed, isFalse);
    expect(c.stage, StageState.idle);
  });
}
