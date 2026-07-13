import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';
import 'theme.dart';
import 'engine/openocd_paths.dart';
import 'engine/openocd_runner.dart';
import 'engine/rdp_runner.dart';
import 'engine/firmware.dart';

/// Drives the whole UI via a single StageState the hero binds to.
///
/// PHASE 1: non-guided "Check connection" runs REAL OpenOCD (see _runReal).
/// Everything else still runs the SIMULATION (_simulate) until wired.
class AppController extends ChangeNotifier {
  AppController() {
    try {
      final paths = OpenOcdPaths.find();
      _runner = OpenOcdRunner(paths);
      _rdp = RdpRunner(paths);
      openOcdStatus = 'ready';
    } catch (e) {
      openOcdStatus = 'missing';
      console.add('OpenOCD not found: $e');
    }
    _loadPrefs();
  }

  // ── Backups settings (persisted) ──────────────────────────────────────────
  SharedPreferences? _prefs;
  String? backupFolder; // null = default Documents/x3utils/backup
  String backupPrefix = '';
  bool secondCopy = true; // redundant %LOCALAPPDATA%\x3utils_backup copy

  // Connection modes the user moved to the Advanced rail (persisted). Empty = all
  // in the standard "Connection" group; rendering order is always canonical.
  final Set<ConnectionMode> _advancedModes = <ConnectionMode>{};

  Future<void> _loadPrefs() async {
    _prefs = await SharedPreferences.getInstance();
    backupFolder = _prefs!.getString('backupFolder');
    backupPrefix = _prefs!.getString('backupPrefix') ?? '';
    secondCopy = _prefs!.getBool('secondCopy') ?? true;
    final adv = _prefs!.getStringList('advancedModes');
    _advancedModes.clear();
    if (adv == null) {
      // Ship default: Power-race (C) and genuine C45 (D) start in Advanced. The
      // user can right-click either back to Main; that choice then persists.
      _advancedModes
        ..add(ConnectionMode.powerRace)
        ..add(ConnectionMode.genuineC45);
    } else {
      _advancedModes.addAll(
        ConnectionMode.values.where((m) => adv.contains(m.name)),
      );
    }
    // Startup defaults (migrate the pre-v1.0 last-used keys as a fallback).
    final dm = _prefs!.getInt('defaultConnMode') ?? _prefs!.getInt('connMode');
    if (dm != null && dm >= 0 && dm < ConnectionMode.values.length) {
      defaultMode = ConnectionMode.values[dm];
    }
    defaultCountdown =
        (_prefs!.getInt('defaultCountdown') ??
                _prefs!.getInt('countdown') ??
                defaultCountdown)
            .clamp(0, 10);
    // Seed the live session from the defaults.
    mode = defaultMode;
    countdownSeconds = defaultCountdown;
    final ai = _prefs!.getInt('accent') ?? 1; // default: Silver
    accentNotifier.value = (ai >= 0 && ai < kAccents.length) ? ai : 0;
    logToFile = _prefs!.getBool('logToFile') ?? false;
    notifyListeners();
  }

  void toggleLogToFile() {
    logToFile = !logToFile;
    _prefs?.setBool('logToFile', logToFile);
    notifyListeners();
  }

  int get accentIndex => accentNotifier.value;

  void setAccent(int i) {
    final idx = (i >= 0 && i < kAccents.length) ? i : 0;
    accentNotifier.value = idx; // drives the app-wide recolor
    _prefs?.setInt('accent', idx);
  }

  void setBackupFolder(String? f) {
    backupFolder = f;
    if (f == null) {
      _prefs?.remove('backupFolder');
    } else {
      _prefs?.setString('backupFolder', f);
    }
    notifyListeners();
  }

  void setBackupPrefix(String v) {
    backupPrefix = v;
    _prefs?.setString('backupPrefix', v);
    notifyListeners();
  }

  void setSecondCopy(bool v) {
    secondCopy = v;
    _prefs?.setBool('secondCopy', v);
    notifyListeners();
  }

  void _maybeSecondCopy(String srcPath) {
    if (!secondCopy) return;
    final dest = Firmware.secondCopy(srcPath);
    if (dest != null) _log('== 2nd copy → $dest ==');
  }

  OpenOcdRunner? _runner;
  RdpRunner? _rdp;
  String openOcdStatus = 'checking';
  bool _realRun = false;
  String? _diagnosis; // a specific cause parsed from OpenOCD output this run
  // Only the standard "Backup + Flash" remembers a bin. The advanced firmware
  // actions (Flash Only, Flash slot 0) never remember — cleared on every action
  // switch — so nothing stale or wrong-sized ever carries over.
  String? _firmwareStandard; // flash_backup
  String? _firmwareAdvanced; // flash_only / flash_slot0 (transient)

  bool get isSlotAction => actionId == 'flash_slot0';

  String? get firmwarePath =>
      actionId == 'flash_backup' ? _firmwareStandard : _firmwareAdvanced;

  void setFirmware(String? path) {
    if (actionId == 'flash_backup') {
      _firmwareStandard = path;
    } else {
      _firmwareAdvanced = path;
    }
    notifyListeners();
  }

  // STARTUP DEFAULTS (persisted, set only from Settings). Default to Mode A
  // (plain SWD). _loadPrefs seeds the live session values below from these; the
  // rail changes the session only.
  ConnectionMode defaultMode = ConnectionMode.defaultSwd;
  int defaultCountdown = 3;

  // Live session values (seeded from the defaults on launch; the rail overrides
  // these WITHOUT touching the persisted defaults).
  ConnectionMode mode = ConnectionMode.defaultSwd;
  String actionId = 'check';
  int countdownSeconds = 3;
  bool running = false;
  int raceAttempts =
      0; // power-race respawn: attempts so far (drives the indicator)
  RaceTier raceTier = RaceTier.searching;

  StageState stage = StageState.idle;
  String eyebrow = 'Ready';
  String title = 'Check connection';
  String sub = 'Pick a connection mode and an action, then hit start.';

  int countdownValue = 0;
  int activeStage = -1;
  List<bool> stageDone = const [];

  bool showContinue = false;
  String continueLabel = 'Continue';

  final List<String> console = <String>[];
  String lastConnect = '—';
  bool consoleOpen = false;
  bool consolePinned = false;
  double consoleHeight = 300;
  bool advancedOpen = false;
  bool logToFile = false; // opt-in: save each run's console to a log file
  final List<String> _runLog = <String>[];
  bool _capturing = false;

  int _token = 0;
  Completer<void>? _continue;

  FlashAction get action => kActions.firstWhere((a) => a.id == actionId);

  void selectMode(ConnectionMode m) {
    if (running) return;
    mode = m; // session-only; does NOT change the persisted default
    _goIdle();
  }

  // ── Connection-mode rail sections (persisted, user-movable) ────────────────
  Section sectionOf(ConnectionMode m) =>
      _advancedModes.contains(m) ? Section.advanced : Section.standard;

  /// Modes in a rail section, always in canonical A/B/C/D letter order (by tag,
  /// so display order is independent of the enum order).
  List<ConnectionMode> modesIn(Section s) =>
      ConnectionMode.values.where((m) => sectionOf(m) == s).toList()
        ..sort((a, b) => a.tag.compareTo(b.tag));

  /// Guardrail: never let the standard group be emptied.
  bool canMoveToAdvanced(ConnectionMode m) =>
      modesIn(Section.standard).length > 1;

  /// Move a mode between the standard and advanced rail groups (persisted).
  void moveMode(ConnectionMode m, Section to) {
    if (to == Section.advanced) {
      if (!canMoveToAdvanced(m)) return; // keep at least one in standard
      _advancedModes.add(m);
      advancedOpen = true; // so the moved button visibly lands
    } else {
      _advancedModes.remove(m);
    }
    _prefs?.setStringList(
      'advancedModes',
      _advancedModes.map((e) => e.name).toList(),
    );
    notifyListeners();
  }

  /// Settings: set the persisted STARTUP default mode AND apply it to the live
  /// session so the change shows immediately.
  void setDefaultMode(ConnectionMode m) {
    defaultMode = m;
    _prefs?.setInt('defaultConnMode', m.index);
    if (!running) mode = m;
    notifyListeners();
  }

  void selectAction(String id) {
    if (running) return;
    actionId = id;
    _firmwareAdvanced = null; // advanced actions don't remember loaded bins
    _goIdle();
  }

  void setCountdown(int v) {
    countdownSeconds = v.clamp(0, 10); // session-only
    notifyListeners();
  }

  /// Settings: set the persisted STARTUP default countdown AND apply it live.
  void setDefaultCountdown(int v) {
    defaultCountdown = v.clamp(0, 10);
    _prefs?.setInt('defaultCountdown', defaultCountdown);
    countdownSeconds = defaultCountdown;
    notifyListeners();
  }

  void continueStep() {
    if (_realRun) {
      if (actionId.startsWith('rdp')) {
        _rdp?.sendContinue();
      } else {
        _runner?.sendContinue();
      }
      showContinue = false;
      notifyListeners();
      return;
    }
    _continue?.complete();
    _continue = null;
  }

  void toggleConsole() {
    consoleOpen = !consoleOpen;
    notifyListeners();
  }

  void clearConsole() {
    console.clear();
    notifyListeners();
  }

  void togglePin() {
    consolePinned = !consolePinned;
    notifyListeners();
  }

  void setConsoleHeight(double h) {
    consoleHeight = h;
    notifyListeners();
  }

  void toggleAdvanced() {
    advancedOpen = !advancedOpen;
    notifyListeners();
  }

  void cancel() {
    _token++;
    running = false;
    _realRun = false;
    _runner?.kill();
    _rdp?.kill();
    _log('-- cancelled --');
    lastConnect = '—';
    _goIdle();
  }

  /// Dismiss a completed (ok/fail) result back to idle — not a cancel.
  void dismiss() {
    if (running) return;
    _goIdle();
  }

  /// Re-run the current action after a failure (the 1.6.6 re-seat retry loop;
  /// skips the danger re-confirm — you already confirmed the first attempt).
  Future<void> retry() => start();

  void _goIdle() {
    running = false;
    stage = StageState.idle;
    eyebrow = 'Ready';
    title = action.name;
    sub = action.sub;
    showContinue = false;
    activeStage = -1;
    stageDone = const [];
    notifyListeners();
  }

  static final RegExp _ansi = RegExp(r'\x1B\[[0-9;]*[A-Za-z]');

  void _log(String s) {
    final clean = s.replaceAll(_ansi, ''); // strip ANSI colour escapes
    console.add(clean);
    if (_capturing) _runLog.add(clean);
    notifyListeners();
  }

  void _flushLog() {
    if (_runLog.isEmpty) return;
    try {
      final path = Firmware.writeLog(actionId, _runLog.join('\n'));
      _log('== log saved → $path ==');
    } catch (e) {
      _log('== could not save log: $e ==');
    }
  }

  void _set(
    StageState s,
    String eb,
    String t,
    String sb, {
    String? continueBtn,
  }) {
    stage = s;
    eyebrow = eb;
    title = t;
    sub = sb;
    showContinue = continueBtn != null;
    if (continueBtn != null) continueLabel = continueBtn;
    notifyListeners();
  }

  Future<void> _waitContinue() {
    // Guided hardware steps must wait for a real Continue click — never
    // auto-advance past holding/releasing the wire.
    _continue = Completer<void>();
    return _continue!.future;
  }

  /// One-line self-describing header for logs + clipboard (version/OS/mode/time).
  String contextHeader() {
    final os = switch (Platform.operatingSystem) {
      'windows' => 'Windows',
      'macos' => 'macOS',
      'linux' => 'Linux',
      _ => Platform.operatingSystem,
    };
    return 'x3utils v$kAppVersion · $os · ${mode.title} · '
        '${DateTime.now().toString().split('.').first}';
  }

  Future<void> start() async {
    _runLog.clear();
    _capturing = true;
    _log(contextHeader());
    try {
      await _dispatch();
    } finally {
      _capturing = false;
      if (logToFile) _flushLog();
    }
  }

  Future<void> _dispatch() async {
    final runner = _runner;
    if (runner == null) {
      await _simulate();
      return;
    }
    final g = mode.guided;
    switch (actionId) {
      case 'check':
        final r = await _runRealCore(
          runner.checkArgs(mode, countdownSeconds),
          guided: g,
        );
        if (r != null) {
          _finishReal(
            r.ok,
            action.okMsg,
            'OpenOCD exited with code ${r.exitCode}. Check the console.',
          );
        }
      case 'dump':
        await _runDump(runner, g);
      case 'flash_only':
        await _runFlash(runner, g, backup: false, slot0: false);
      case 'flash_backup':
        await _runFlash(runner, g, backup: true, slot0: false);
      case 'flash_slot0':
        await _runFlash(runner, g, backup: true, slot0: true);
      case 'flash_compat':
        await _runCompat(runner, g);
      case 'rdp_check':
        await _runRdp('Check', yes: false);
      case 'rdp_rescue':
        await _runRdp('Rescue', yes: true);
      default:
        await _simulate(); // anything not yet wired
    }
  }

  Future<void> _runRdp(String verb, {required bool yes}) async {
    final rdp = _rdp;
    if (rdp == null || !rdp.available) {
      _set(
        StageState.fail,
        'rdp unavailable',
        'rdp.ps1 not found',
        'The protection toolkit is missing from the bundle.',
      );
      return;
    }
    final my = ++_token;
    _diagnosis = null;
    running = true;
    _realRun = true;
    lastConnect = 'connecting…';
    final raceCheck = verb == 'Check' && mode == ConnectionMode.powerRace;
    if (raceCheck) {
      raceAttempts = 0;
      raceTier = RaceTier.searching;
      _set(
        StageState.connect,
        'Power-race',
        'Hammering the check…',
        'Cut & re-apply power now — the check starts when the window opens.',
      );
    } else {
      _set(
        StageState.connect,
        'Protection',
        '${action.name}…',
        'Running the protection toolkit — watch the console.',
      );
    }

    int code;
    try {
      code = await rdp.run(
        verb,
        mode,
        countdownSeconds,
        yes: yes,
        onLine: (line) {
          _onRealLine(line, mode.guided);
          if (raceCheck) _advanceRdpRaceLine(line);
        },
        onChunk: (chunk) {
          if (my != _token) return;
          _handleRdpChunk(chunk, raceCheck: raceCheck);
        },
      );
    } catch (e) {
      if (my != _token) return;
      _realRun = false;
      running = false;
      _set(
        StageState.fail,
        'Failed',
        '${action.name} failed',
        'Could not start rdp.ps1: $e',
      );
      return;
    }
    if (my != _token) return;
    _realRun = false;
    running = false;
    _log('== rdp exit $code ==');

    if (verb == 'Check') {
      // 0 = not protected, 2 = read-protected, 3 = inconclusive.
      switch (code) {
        case 0:
          _finishReal(true, 'NOT read-protected — the flash is readable.', '');
        case 2:
          // A locked chip is a valid verdict, not a success — amber, not green.
          lastConnect = 'PASS';
          _set(
            StageState.warn,
            'Verdict',
            'Read-protected',
            'The chip is locked. Unlock / rescue can clear it — but that erases the flash.',
          );
        default:
          _finishReal(
            false,
            '',
            'Inconclusive — could not determine the protection state. Check the console.',
          );
      }
    } else {
      _finishReal(
        code == 0,
        action.okMsg,
        'rescue exited with code $code. Check the console for what happened.',
      );
    }
  }

  void _handleRdpChunk(String chunk, {required bool raceCheck}) {
    final low = chunk.toLowerCase();
    if (low.contains('press enter to retry')) {
      _set(
        StageState.connect,
        mode == ConnectionMode.powerRace ? 'Power-race' : 'Protection',
        'Retry connection?',
        mode == ConnectionMode.powerRace
            ? 'The rescue attempt missed the window. Cut & re-apply power, then retry.'
            : 'The connect attempt missed. Re-seat the probe, then retry.',
        continueBtn: 'Retry connect',
      );
      return;
    }

    if (!raceCheck) return;
    final progress = chunk.replaceAll('\r', '').replaceAll('\n', '');
    if (!RegExp(r'^\.+$').hasMatch(progress)) return;
    final dots = progress.length;
    if (dots == 0) return;
    raceAttempts += dots;
    raceTier = RaceTier.searching;
    _set(
      StageState.connect,
      'Power-race',
      'Hammering — attempt $raceAttempts',
      _raceHint(raceTier),
    );
  }

  void _advanceRdpRaceLine(String line) {
    final low = line.toLowerCase();
    final caught = RegExp(
      r'caught the window on attempt\s+(\d+)',
    ).firstMatch(low);
    if (caught != null) {
      final n = int.tryParse(caught.group(1)!);
      if (n != null) raceAttempts = n;
      _set(
        StageState.run,
        'Power-race',
        'Caught — checking…',
        'Hold everything steady until the verdict is printed.',
      );
      _markStage('connect');
    } else if (low.contains('0x1ffff800:')) {
      _markStage('fap');
    } else if (low.contains('verdict')) {
      _markStage('verdict');
    }
  }

  /// Spawn OpenOCD, stream + parse its output, return the result (null if the
  /// run was cancelled/superseded). Does NOT set the final ok/fail stage — the
  /// caller decides (dump validates the file, flash chains a backup, etc.).
  Future<OpenOcdResult?> _runRealCore(
    List<String> args, {
    required bool guided,
    String? title,
  }) async {
    final runner = _runner;
    if (runner == null) return null;
    final my = ++_token;
    _diagnosis = null;
    running = true;
    _realRun = true;
    lastConnect = 'connecting…';
    final race = mode == ConnectionMode.powerRace;
    if (guided) {
      _set(
        StageState.hold,
        'Step 1 of 3',
        'Hold C45 → GND',
        'Hold the C45/nRST contact to GND and keep it steady, then hit continue.',
        continueBtn: "I'm holding — continue",
      );
    } else if (race) {
      raceAttempts = 0;
      _set(
        StageState.connect,
        'Power-race',
        'Hammering the connect…',
        'Cut & re-apply power now — it catches the instant the window opens.',
      );
    } else {
      _set(
        StageState.connect,
        'Linking',
        title ?? '${action.name}…',
        'Talking to the target over SWD — watch the console.',
      );
    }

    OpenOcdResult result;
    try {
      if (race) {
        result = await runner.runRace(
          args,
          onLine: (line) {
            _onRealLine(line, false);
            _advanceRaceStage(line);
          },
          onCaught: () {
            if (my != _token) return;
            if (stageDone.length != action.stages.length) {
              stageDone = List<bool>.filled(action.stages.length, false);
            }
            _set(
              StageState.run,
              'Power-race',
              'Caught — working…',
              'Hold everything steady, do NOT replug.',
            );
          },
          onAttempt: (n, tier) {
            if (my != _token) return;
            raceAttempts = n;
            raceTier = tier;
            _set(
              StageState.connect,
              'Power-race',
              'Hammering — attempt $n',
              _raceHint(tier),
            );
          },
        );
      } else {
        result = await runner.run(args, (line) => _onRealLine(line, guided));
      }
    } catch (e) {
      if (my != _token) return null;
      _realRun = false;
      running = false;
      _set(
        StageState.fail,
        'Failed',
        '${action.name} failed',
        'Could not start OpenOCD: $e',
      );
      return null;
    }
    if (my != _token) return null;
    // Final-hold: when the race just filled the last checkmark, freeze the
    // fully-checked stage list for a readable beat before the caller flips to
    // the 'complete' screen (chosen over per-stage dwell). Self-gated on every
    // stage being done, so it fires only on the action's true final step — never
    // after the backup catch in a 2-catch flow, whose list isn't full yet.
    if (race &&
        result.exitCode == 0 &&
        stageDone.isNotEmpty &&
        stageDone.every((d) => d)) {
      await Future.delayed(const Duration(milliseconds: 1500));
      if (my != _token) return null;
    }
    _realRun = false;
    running = false;
    _log('== openocd exit ${result.exitCode} ==');
    return result;
  }

  void _onRealLine(String line, bool guided) {
    _log(line);
    final low = line.toLowerCase();
    if (low.contains('target halted')) lastConnect = 'PASS';
    _diagnose(low);
    if (guided) _parseGuided(line, low);
  }

  /// Classify known OpenOCD error lines so the failure message names the real
  /// cause instead of the generic contact hint. (Expandable, like the WinForms
  /// ClassifyOpenOcdLine.) First-set wins for the run.
  void _diagnose(String low) {
    if (_diagnosis != null) return;
    if (low.contains('write protected') ||
        low.contains('read out protection')) {
      _diagnosis =
          'The chip is locked (read/write-protected) — nothing was written. '
          'Run Unlock / rescue to clear protection, then flash again.';
    }
  }

  /// Drive the C45 hold/countdown/release stages from OpenOCD's guided prompts
  /// (ported from the WinForms HandleCloneC45Prompt string matches).
  void _parseGuided(String line, String low) {
    if (low.contains('hold a wire between') ||
        low.contains('keep it grounded')) {
      _set(
        StageState.hold,
        'Step 1 of 3',
        'Hold C45 → GND',
        'Hold the C45/nRST contact to GND and keep it steady, then hit continue.',
        continueBtn: "I'm holding — continue",
      );
    } else if (low.contains('remove the wire from gnd') ||
        low.contains('release nrst')) {
      _set(
        StageState.release,
        'Step 3 of 3',
        'Release now',
        'Lift the wire off the pad — right now — then hit continue.',
        continueBtn: 'Released — continue',
      );
    } else if (low.contains('connected') && low.contains('ready')) {
      showContinue = false;
      _set(
        StageState.connect,
        'Linking',
        'Connected',
        'Keep the ST-LINK and SWD wires steady.',
      );
    } else if (low.contains('connecting in')) {
      final n = _trailingInt(line);
      if (n != null) countdownValue = n;
      showContinue = false;
      _set(
        StageState.count,
        'Under reset',
        'Connecting under reset',
        'Keep holding the wire — do not lift it yet.',
      );
    } else {
      // Per-second countdown ticks: "  3 .", "  2 .", "  1 .", "  0".
      final tick = _countdownTick(line);
      if (tick != null) {
        countdownValue = tick;
        showContinue = false;
        _set(
          StageState.count,
          'Under reset',
          'Connecting under reset',
          'Keep holding the wire — do not lift it yet.',
        );
      }
    }
  }

  int? _trailingInt(String s) {
    final ms = RegExp(r'(\d+)').allMatches(s);
    return ms.isEmpty ? null : int.tryParse(ms.last.group(1)!);
  }

  /// A bare countdown line like "  3 ." or "  0" (whole line = digits + opt " .").
  int? _countdownTick(String line) {
    final m = RegExp(r'^(\d+)\s*\.?$').firstMatch(line.trim());
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  static const _reseatHint =
      'Most failures are a lost SWD / C45 contact — re-seat it, keep it steady, then press Retry.';

  /// [reseat] appends the contact-retry hint — only right for CONNECTION
  /// failures, not validation/patch failures (a re-seat won't fix those).
  void _finishReal(
    bool ok,
    String okMsg,
    String failMsg, {
    bool reseat = true,
  }) {
    lastConnect = ok ? 'PASS' : 'FAIL';
    final String msg;
    if (ok) {
      msg = okMsg;
    } else if (_diagnosis != null) {
      msg = _diagnosis!; // a specific diagnosed cause — no contact hint
    } else {
      msg = reseat ? '$failMsg\n$_reseatHint' : failMsg;
    }
    _set(
      ok ? StageState.ok : StageState.fail,
      ok ? 'Done' : 'Failed',
      ok ? '${action.name} complete' : '${action.name} failed',
      msg,
    );
  }

  /// Live operator hint for a power-race miss, keyed to how far it got.
  String _raceHint(RaceTier tier) => switch (tier) {
    RaceTier.searching => 'No contact yet — cut & re-apply power.',
    RaceTier.noisy => 'On the pad but bouncing — hold it steadier.',
    RaceTier.nearCatch => 'Almost — reached the core, keep holding.',
    RaceTier.adapterGone => 'ST-LINK not seen — check the probe / USB.',
    RaceTier.timedOut =>
      'OpenOCD stalled — power-cycle and try the next catch.',
  };

  /// Once the race catches, drive the stage-list checkmarks from the winning
  /// attempt's live output — the same visual the guided A/B/C paths would show,
  /// but fed by real OpenOCD progress markers instead of the simulate timer.
  void _advanceRaceStage(String line) {
    final low = line.toLowerCase();
    if (low.contains('target halted') || low.contains('caught; hold power')) {
      _markStage('connect');
    } else if (low.contains('dumped')) {
      _markStage('read');
    } else if (low.contains('erased')) {
      _markStage('eras');
    } else if (low.contains('wrote')) {
      _markStage('writ');
    } else if (low.contains('verified')) {
      _markStage('verif');
    }
  }

  /// Mark the stage whose label contains [part] (and every stage before it) done,
  /// then arm the next one. Prior stages cascade, so a marker for a later step
  /// also ticks the earlier ones we have no explicit marker for.
  void _markStage(String part) {
    final stages = action.stages;
    if (stageDone.length != stages.length) {
      stageDone = List<bool>.filled(stages.length, false);
    }
    final idx = stages.indexWhere((s) => s.toLowerCase().contains(part));
    if (idx < 0) return;
    for (var i = 0; i <= idx; i++) {
      stageDone[i] = true;
    }
    activeStage = idx + 1 < stages.length ? idx + 1 : idx;
    notifyListeners();
  }

  bool _dumpConfirmed(OpenOcdResult r) => r.ok && r.evidence.dumped;

  bool _flashConfirmed(OpenOcdResult r) =>
      r.ok && r.evidence.wrote && r.evidence.verified;

  String _dumpFailMessage(OpenOcdResult r) {
    if (r.ok && !r.evidence.dumped) {
      return 'OpenOCD exited successfully, but a complete dump was not confirmed. Retry required.';
    }
    return 'Dump failed (exit ${r.exitCode}). Check the console.';
  }

  String _flashFailMessage(OpenOcdResult r) {
    if (r.ok && r.evidence.wrote && !r.evidence.verified) {
      return 'Flash wrote data, but verification was not confirmed. Retry required.';
    }
    if (r.ok && !r.evidence.wrote) {
      return 'OpenOCD exited successfully, but no flash write was confirmed. Retry required.';
    }
    return 'Flash failed (exit ${r.exitCode}). Nothing verified — check the console.';
  }

  Future<void> _runDump(OpenOcdRunner runner, bool guided) async {
    final outPath = Firmware.newDumpPath(
      folder: backupFolder,
      prefix: backupPrefix,
    );
    final r = await _runRealCore(
      runner.dumpArgs(mode, countdownSeconds, outPath),
      guided: guided,
    );
    if (r == null) return;
    if (!_dumpConfirmed(r)) {
      _finishReal(false, '', _dumpFailMessage(r));
      return;
    }
    final v = Firmware.validate(outPath);
    if (!v.ok) {
      _log('== validation FAILED: ${v.message} ==');
      _finishReal(
        false,
        '',
        'Dump saved but failed validation — do not trust it. ${v.message} '
            '(a read-protected or blank chip reads back like this — try Check protection).',
        reseat: false,
      );
      return;
    }
    _log('== validated OK → $outPath ==');
    _maybeSecondCopy(outPath);
    _finishReal(true, 'Backed up & verified → $outPath', '');
  }

  Future<void> _runFlash(
    OpenOcdRunner runner,
    bool guided, {
    required bool backup,
    required bool slot0,
  }) async {
    final fw = firmwarePath;
    if (fw == null) {
      _set(
        StageState.fail,
        'No firmware',
        'Choose a firmware .bin first',
        'Pick a .bin file, then start the flash.',
      );
      return;
    }
    final v = slot0
        ? Firmware.validateSlot(fw)
        : Firmware.validate(fw, requireSize: true);
    if (!v.ok) {
      _set(StageState.fail, 'Firmware invalid', 'Firmware invalid', v.message);
      return;
    }

    // Mandatory backup first (the scripts' safety floor) — abort flash if it fails.
    if (backup) {
      final outPath = Firmware.newDumpPath(
        folder: backupFolder,
        prefix: backupPrefix,
      );
      final b = await _runRealCore(
        runner.dumpArgs(mode, countdownSeconds, outPath),
        guided: guided,
        title: 'Backing up first…',
      );
      if (b == null) return;
      if (!_dumpConfirmed(b)) {
        _finishReal(
          false,
          '',
          'Backup did not confirm a complete dump — flash aborted for safety. ${_dumpFailMessage(b)}',
        );
        return;
      }
      final backupCheck = Firmware.validate(outPath);
      if (!backupCheck.ok) {
        _log('== validation FAILED: ${backupCheck.message} ==');
        _finishReal(
          false,
          '',
          'Backup validation failed — flash aborted for safety. ${backupCheck.message} '
              '(read-protected or blank chip? try Check protection).',
          reseat: false,
        );
        return;
      }
      _log('== backup ok → $outPath ==');
      _maybeSecondCopy(outPath);
    }

    final args = slot0
        ? runner.flashSlot0Args(mode, countdownSeconds, fw)
        : runner.flashArgs(mode, countdownSeconds, fw);
    final r = await _runRealCore(
      args,
      guided: guided,
      title: '${action.name}…',
    );
    if (r == null) return;
    _finishReal(_flashConfirmed(r), action.okMsg, _flashFailMessage(r));
  }

  /// SHU-compat: dump the chip → patch its own firmware → flash it back
  /// (mirrors flash_compat.bat; no user .bin — uses the chip's own image).
  Future<void> _runCompat(OpenOcdRunner runner, bool guided) async {
    final (raw, patched) = Firmware.newCompatPaths(prefix: backupPrefix);

    // Step 1 — read the current firmware.
    final d = await _runRealCore(
      runner.dumpArgs(mode, countdownSeconds, raw),
      guided: guided,
      title: 'Reading current firmware…',
    );
    if (d == null) return;
    if (!_dumpConfirmed(d)) {
      _finishReal(
        false,
        '',
        'Could not confirm a complete chip read — nothing was changed. ${_dumpFailMessage(d)}',
      );
      return;
    }
    final rawCheck = Firmware.validate(raw);
    if (!rawCheck.ok) {
      _log('== validation FAILED: ${rawCheck.message} ==');
      _finishReal(
        false,
        '',
        'The chip read back as invalid — nothing was written. ${rawCheck.message} '
            '(a read-protected or blank chip reads back like this — try Check protection).',
        reseat: false,
      );
      return;
    }

    _maybeSecondCopy(raw);

    // Step 2 — patch (pure Dart, no hardware).
    _log('== patching SHU-compat signature @ 0x1420 ==');
    final patch = CompatPatch.apply(raw, patched);
    if (!patch.ok || !Firmware.validate(patched).ok) {
      _log('== patch FAILED: ${patch.message} ==');
      _finishReal(
        false,
        '',
        'Patch failed — the chip was NOT written. ${patch.message}',
        reseat: false,
      );
      return;
    }
    _log('== patched → $patched ==');

    // Step 3 — flash the patched image back.
    final f = await _runRealCore(
      runner.flashArgs(mode, countdownSeconds, patched),
      guided: guided,
      title: 'Flashing SHU-compatible firmware…',
    );
    if (f == null) return;
    _finishReal(
      _flashConfirmed(f),
      'SHU-compatible firmware flashed & verified. Original saved to $raw',
      _flashFailMessage(f),
    );
  }

  Future<void> _simulate() async {
    final my = ++_token;
    running = true;
    final a = action;
    _log('> ${a.name}  [${mode.title}]  (simulated)');
    lastConnect = 'connecting…';
    notifyListeners();

    if (mode.guided) {
      _set(
        StageState.hold,
        'Step 1 of 3',
        'Hold C45 → GND',
        'Touch the wire to the C45 pad and keep it steady. Then hit continue.',
        continueBtn: 'I’m holding — continue',
      );
      _log('hold a wire between C45 and GND…');
      await _waitContinue();
      if (my != _token) return;

      _set(
        StageState.count,
        'Under reset',
        'Connecting under reset',
        'Keep holding. Do not lift the wire yet.',
      );
      for (var n = countdownSeconds; n > 0; n--) {
        countdownValue = n;
        _log('connecting in $n…');
        notifyListeners();
        await Future.delayed(const Duration(milliseconds: 720));
        if (my != _token) return;
      }
      countdownValue = 0;
      notifyListeners();

      _set(
        StageState.release,
        'Step 3 of 3',
        'Release now',
        'Lift the wire off the pad — right now.',
        continueBtn: 'Released — continue',
      );
      _log('>>> remove the wire from GND');
      await _waitContinue();
      if (my != _token) return;
    }

    _set(
      StageState.connect,
      'Linking',
      'Connecting…',
      'Re-examining the target over SWD.',
    );
    _log('init');
    await Future.delayed(const Duration(milliseconds: 700));
    if (my != _token) return;
    _log('target halted');
    lastConnect = 'PASS';
    notifyListeners();

    stageDone = List<bool>.filled(a.stages.length, false);
    activeStage = -1;
    _set(
      StageState.run,
      a.name,
      '${a.name}…',
      'Keep the ST-LINK and SWD wires steady until it finishes.',
    );
    for (var i = 0; i < a.stages.length; i++) {
      activeStage = i;
      notifyListeners();
      await Future.delayed(Duration(milliseconds: 720 + i * 90));
      if (my != _token) return;
      stageDone[i] = true;
      notifyListeners();
    }

    _log('== ${a.name} OK ==');
    _set(StageState.ok, 'Done', '${a.name} complete', a.okMsg);
    running = false;
    notifyListeners();
  }
}
