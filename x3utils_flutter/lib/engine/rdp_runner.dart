import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models.dart';
import 'openocd_paths.dart';

/// Runs the bundled, vetted `rdp.ps1` (the AT32F415 read-protection toolkit)
/// via PowerShell. rdp.ps1 already encodes the WRP-safe deterministic option
/// rewrite and its own re-seat retry — we shell out rather than reimplement.
///
/// Windows-only for now (PowerShell). The cross-platform build will call the
/// `special/rdp/*.sh` equivalents instead.
class RdpRunner {
  RdpRunner(this.paths);
  final OpenOcdPaths paths;

  Process? _active;

  // native/windows/oocd/bin  →  native/windows  (rdp.ps1's WinRoot: has oocd/ + special/)
  String get _winRoot => p.dirname(p.dirname(paths.binDir));
  String get _script => p.join(_winRoot, 'special', 'rdp', 'rdp.ps1');

  bool get available => Platform.isWindows && File(_script).existsSync();

  String _targetCfg(ConnectionMode mode) => switch (mode) {
        ConnectionMode.cloneC45 => r'target\at32f415xx_c45.cfg',
        ConnectionMode.genuineC45 => r'target\at32f415xx_nrst.cfg',
        _ => r'target\at32f415xx.cfg',
      };

  /// Mirror launcher.bat's config.cmd so rdp.ps1 -Launcher uses the app's mode.
  /// Written beside rdp.ps1 (its ScriptDir), where our bundled rdp.ps1 reads it.
  void _writeConfig(ConnectionMode mode, int timeout) {
    File(p.join(p.dirname(_script), 'config.cmd')).writeAsStringSync(
      'set "TARGET=${_targetCfg(mode)}"\r\n'
      'set "CONNECT_TIMEOUT=$timeout"\r\n',
    );
  }

  bool sendContinue() {
    final proc = _active;
    if (proc == null) return false;
    try {
      proc.stdin.writeln();
      return true;
    } catch (_) {
      return false;
    }
  }

  void kill() {
    _active?.kill();
    _active = null;
  }

  /// Runs a verb (`Check` | `Rescue` | `Clear` | `Enable`). Returns the exit
  /// code — for Check: 0 = not protected, 2 = read-protected, 3 = inconclusive.
  Future<int> run(String verb, ConnectionMode mode, int timeout,
      {bool yes = false, required void Function(String) onLine}) async {
    _writeConfig(mode, timeout);
    final args = <String>[
      '-NoProfile',
      '-ExecutionPolicy', 'Bypass',
      '-File', _script,
      '-$verb',
      '-Launcher',
      if (yes) '-Yes',
    ];
    onLine('> powershell rdp.ps1 -$verb -Launcher${yes ? ' -Yes' : ''}');
    final proc =
        await Process.start('powershell', args, workingDirectory: _winRoot);
    _active = proc;

    final out = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(onLine);
    final err = proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(onLine);

    final code = await proc.exitCode;
    await out.cancel();
    await err.cancel();
    if (identical(_active, proc)) _active = null;
    return code;
  }
}
