import 'package:flutter_test/flutter_test.dart';
import 'package:x3utils_flutter/engine/hardware_backend.dart';
import 'package:x3utils_flutter/engine/openocd_backend.dart';
import 'package:x3utils_flutter/engine/openocd_paths.dart';
import 'package:x3utils_flutter/engine/openocd_runner.dart';
import 'package:x3utils_flutter/engine/rdp_runner.dart';
import 'package:x3utils_flutter/models.dart';

class _RecordingRunner extends OpenOcdRunner {
  _RecordingRunner({this.lines = const []})
    : super(OpenOcdPaths('openocd', 'scripts'));

  final List<String> lines;
  List<String>? lastArgs;
  bool continued = false;
  bool killed = false;
  bool usedRace = false;

  OpenOcdResult _replay(void Function(String line) onLine) {
    final evidence = OpenOcdEvidence();
    for (final line in lines) {
      evidence.record(line);
      onLine(line);
    }
    return OpenOcdResult(0, evidence);
  }

  @override
  Future<OpenOcdResult> run(
    List<String> args,
    void Function(String line) onLine,
  ) async {
    lastArgs = args;
    return _replay(onLine);
  }

  @override
  Future<OpenOcdResult> runRace(
    List<String> args, {
    required void Function(String line) onLine,
    required void Function(int attempt, RaceTier tier) onAttempt,
    void Function()? onCaught,
  }) async {
    lastArgs = args;
    usedRace = true;
    onAttempt(3, RaceTier.nearCatch);
    onCaught?.call();
    return _replay(onLine);
  }

  @override
  bool sendContinue() {
    continued = true;
    return true;
  }

  @override
  void kill() {
    killed = true;
  }
}

class _RecordingProtectionRunner extends RdpRunner {
  _RecordingProtectionRunner(this.code)
    : super(OpenOcdPaths('openocd', 'scripts'));

  final int code;
  String? verb;
  bool yes = false;

  @override
  bool get available => true;

  @override
  Future<int> run(
    String value,
    ConnectionMode mode,
    int timeout, {
    bool yes = false,
    required void Function(String line) onLine,
    void Function(String chunk)? onChunk,
  }) async {
    verb = value;
    this.yes = yes;
    onLine('protection result');
    onChunk?.call('protection result\n');
    return code;
  }
}

HardwareCallbacks _callbacks({
  void Function(HardwareProgress progress)? onProgress,
  void Function(HardwareGuidedEvent event)? onGuided,
  void Function()? onCaught,
  void Function(int attempt, HardwareRaceTier tier)? onAttempt,
}) => HardwareCallbacks(
  onLine: (_) {},
  onProgress: onProgress ?? (_) {},
  onGuided: onGuided ?? (_) {},
  onCaught: onCaught ?? () {},
  onAttempt: onAttempt ?? (_, _) {},
);

void main() {
  test('full flash maps to OpenOCD and returns generic evidence', () async {
    final runner = _RecordingRunner(
      lines: const [
        'target halted due to debug-request',
        'erased address 0x08000000 (131072 bytes)',
        'wrote 131072 bytes from file firmware.bin',
        'verified 131072 bytes in 2.0s',
      ],
    );
    final backend = OpenOcdBackend(runner: runner);
    final progress = <HardwareProgress>[];

    final result = await backend.run(
      const HardwareRequest(
        operation: HardwareOperation.flashFull,
        mode: ConnectionMode.defaultSwd,
        countdown: 5,
        filePath: 'firmware.bin',
      ),
      _callbacks(onProgress: progress.add),
    );

    expect(runner.lastArgs!.join(' '), contains('flash erase_address'));
    expect(runner.lastArgs!.join(' '), contains('flash write_bank'));
    expect(result.ok, isTrue);
    expect(result.evidence.erased, isTrue);
    expect(result.evidence.wrote, isTrue);
    expect(result.evidence.verified, isTrue);
    expect(progress.any((event) => event.connected), isTrue);
  });

  test('guided dump emits typed count and release events', () async {
    final runner = _RecordingRunner(
      lines: const [
        'Connecting in 3',
        '  2 .',
        'Remove the wire from GND',
        'dumped 131072 bytes',
      ],
    );
    final backend = OpenOcdBackend(runner: runner);
    final guided = <HardwareGuidedEvent>[];

    final result = await backend.run(
      const HardwareRequest(
        operation: HardwareOperation.dump,
        mode: ConnectionMode.cloneC45,
        countdown: 5,
        filePath: 'backup.part',
      ),
      _callbacks(onGuided: guided.add),
    );

    expect(result.evidence.dumped, isTrue);
    expect(guided.map((event) => event.stage), [
      HardwareGuidedStage.count,
      HardwareGuidedStage.count,
      HardwareGuidedStage.release,
    ]);
    expect(guided[0].countdown, 3);
    expect(guided[1].countdown, 2);
  });

  test('Power-race callbacks are backend-neutral', () async {
    final runner = _RecordingRunner(
      lines: const ['target halted due to debug-request'],
    );
    final backend = OpenOcdBackend(runner: runner);
    var caught = false;
    var attempt = 0;
    var tier = HardwareRaceTier.searching;

    await backend.run(
      const HardwareRequest(
        operation: HardwareOperation.check,
        mode: ConnectionMode.powerRace,
        countdown: 5,
      ),
      _callbacks(
        onCaught: () => caught = true,
        onAttempt: (value, valueTier) {
          attempt = value;
          tier = valueTier;
        },
      ),
    );

    expect(runner.usedRace, isTrue);
    expect(caught, isTrue);
    expect(attempt, 3);
    expect(tier, HardwareRaceTier.nearCatch);
  });

  test('continue and cancel delegate while protection stays unavailable', () {
    final runner = _RecordingRunner();
    final backend = OpenOcdBackend(runner: runner);

    expect(backend.capabilities.protectionCheck, isFalse);
    expect(backend.sendContinue(protection: false), isTrue);
    expect(runner.continued, isTrue);

    backend.cancel();
    expect(runner.killed, isTrue);
  });

  test('protection exit codes map to typed verdicts', () async {
    final lockedRunner = _RecordingProtectionRunner(2);
    final lockedBackend = OpenOcdBackend(
      runner: _RecordingRunner(),
      protectionRunner: lockedRunner,
    );
    final locked = await lockedBackend.runProtection(
      const HardwareProtectionRequest(
        operation: HardwareProtectionOperation.check,
        mode: ConnectionMode.defaultSwd,
        countdown: 5,
      ),
      HardwareProtectionCallbacks(
        onLine: (_) {},
        onChunk: (_) {},
        onGuided: (_) {},
      ),
    );
    expect(locked.verdict, HardwareProtectionVerdict.protected);
    expect(lockedRunner.verb, 'Check');
    expect(lockedRunner.yes, isFalse);

    final rescueRunner = _RecordingProtectionRunner(0);
    final rescueBackend = OpenOcdBackend(
      runner: _RecordingRunner(),
      protectionRunner: rescueRunner,
    );
    final rescue = await rescueBackend.runProtection(
      const HardwareProtectionRequest(
        operation: HardwareProtectionOperation.rescue,
        mode: ConnectionMode.genuineC45,
        countdown: 7,
      ),
      HardwareProtectionCallbacks(
        onLine: (_) {},
        onChunk: (_) {},
        onGuided: (_) {},
      ),
    );
    expect(rescue.verdict, HardwareProtectionVerdict.rescued);
    expect(rescueRunner.verb, 'Rescue');
    expect(rescueRunner.yes, isTrue);
  });
}
