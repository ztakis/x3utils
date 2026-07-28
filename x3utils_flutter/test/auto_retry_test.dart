import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:x3utils_flutter/app_controller.dart';
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

Future<AppController> _controller({
  required List<String> lines,
  required int exitCode,
  int autoRetry = 3,
}) async {
  SharedPreferences.setMockInitialValues({'defaultAutoRetry': autoRetry});
  final c = AppController(
    runner: _ScriptedRunner(lines: lines, exitCode: exitCode),
  );
  addTearDown(c.dispose);
  await Future<void>.delayed(Duration.zero); // let _loadPrefs settle
  return c;
}

void main() {
  // A connect that never reached the core is the whole point of the feature.
  const noContact = ['Error: init mode failed (unable to connect to the target)'];
  // 'target halted' is the marker that the run got past connect.
  const connected = ['target halted due to debug-request', 'Error: verify failed'];

  test('arms on a connect failure and counts down', () async {
    final c = await _controller(lines: noContact, exitCode: 1);
    await c.start();

    expect(c.stage, StageState.fail);
    expect(c.autoRetryArmed, isTrue);
    expect(c.autoRetryLabel, 'Retrying in 3…  (1 of 10)');
  });

  test('does not arm once the run reached the core', () async {
    final c = await _controller(lines: connected, exitCode: 1);
    await c.start();

    // Connected, then failed: the write may have gone out, so a third hand
    // must not repeat it unattended.
    expect(c.stage, StageState.fail);
    expect(c.autoRetryArmed, isFalse);
  });

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
