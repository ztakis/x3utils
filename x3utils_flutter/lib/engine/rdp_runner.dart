import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models.dart';
import 'cfg.dart';
import 'openocd_paths.dart';

/// Runs the bundled, vetted read-protection toolkit — `rdp.ps1` on Windows,
/// the `.sh` equivalents on macOS/Linux. Both encode the WRP-safe deterministic
/// option rewrite + their own re-seat retry, so we shell out rather than
/// reimplement. Only Check + Rescue are wired.
///
/// Exit codes (Check): 0 = not protected, 2 = read-protected, 3 = inconclusive.
class RdpRunner {
  RdpRunner(this.paths);
  final OpenOcdPaths paths;

  Process? _active;

  // native/<os>/oocd/bin → native/<os> (the OS root: has oocd/ + special/)
  String get _root => p.dirname(p.dirname(paths.binDir));
  String get _rdpDir => p.join(_root, 'special', 'rdp');

  String _scriptFor(String verb) {
    if (Platform.isWindows) return 'rdp.ps1';
    return verb == 'Rescue' ? 'rescue_unlock.sh' : 'rdp_check.sh';
  }

  bool get available => File(p.join(_rdpDir, _scriptFor('Check'))).existsSync();

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

  /// Runs a verb (`Check` | `Rescue`). Returns the process exit code.
  Future<int> run(String verb, ConnectionMode mode, int timeout,
      {bool yes = false, required void Function(String) onLine}) async {
    final String exe;
    final List<String> args;

    if (Platform.isWindows) {
      _writeConfigCmd(mode, timeout);
      exe = 'powershell';
      args = [
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', p.join(_rdpDir, 'rdp.ps1'),
        '-$verb', '-Launcher',
        if (yes) '-Yes',
      ];
      onLine('> powershell rdp.ps1 -$verb -Launcher${yes ? ' -Yes' : ''}');
    } else {
      _writeConfigSh(mode, timeout);
      final script = _scriptFor(verb);
      exe = 'bash';
      args = [
        p.join(_rdpDir, script),
        '--launcher',
        if (yes) '--yes',
      ];
      onLine('> bash $script --launcher${yes ? ' --yes' : ''}');
    }

    final proc = await Process.start(exe, args, workingDirectory: _root);
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

  // Windows: config.cmd beside rdp.ps1 (our rdp.ps1 reads from its ScriptDir).
  void _writeConfigCmd(ConnectionMode mode, int timeout) {
    final target = Cfg.target(mode).replaceAll('/', '\\');
    File(p.join(_rdpDir, 'config.cmd')).writeAsStringSync(
      'set "TARGET=$target"\r\n'
      'set "CONNECT_TIMEOUT=$timeout"\r\n',
    );
  }

  // macOS/Linux: config.sh beside the .sh scripts (they read $ScriptDir/config.sh),
  // mirroring the Windows config.cmd handoff in _rdpDir.
  void _writeConfigSh(ConnectionMode mode, int timeout) {
    final oocd = paths.openOcdExe;
    final scripts = paths.scriptsDir;
    File(p.join(_rdpDir, 'config.sh')).writeAsStringSync(
      'export CL_NC="\\033[0m"\n'
      'export CL_R="\\033[1;31m"\n'
      'export CL_G="\\033[1;32m"\n'
      'export CL_Y="\\033[1;33m"\n'
      'export CL_M="\\033[1;35m"\n'
      'export CL_C="\\033[1;36m"\n'
      'export D="============================================================"\n'
      'OPENOCD_BIN="$oocd"\n'
      'SCRIPTS_DIR="$scripts"\n'
      'INTERFACE="${Cfg.interface}"\n'
      'TARGET="${Cfg.target(mode)}"\n'
      'CONNECT_TIMEOUT=$timeout\n'
      'EXPECTED_SIZE=131072\n',
    );
  }
}
