import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';
import 'theme.dart';
import 'engine/openocd_paths.dart';
import 'engine/openocd_runner.dart';
import 'engine/rdp_runner.dart';
import 'engine/device_spec.dart';
import 'engine/firmware.dart';
import 'engine/pack_zip3.dart';

/// Drives the whole UI via a single StageState the hero binds to.
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
      // Ship default: genuine C45 (C) and Power-race (D) start in Advanced. The
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
  // One-line identity/claim note shown under the loaded filename (zip3
  // "Package says …" or the bin's own "Firmware says …"); warn = amber.
  String? _firmwareNote;
  bool _firmwareNoteWarn = false;
  FlashOnlyScope flashOnlyScope = FlashOnlyScope.fullImage;

  // ── Make zip3 (offline packer) form state ──────────────────────────────────
  // Operator-declared identity, ninebottea-style. detect() PRESELECTS from the
  // loaded dump's banner (type always; VCU model from its code), but the
  // operator's dropdown choices are what buildZip3FromDump actually uses. MCU
  // has no model identity, so its model dropdown starts empty and the operator
  // picks it. All transient — reset on every action switch.
  static const List<String> zip3Types = ['VCU', 'MCU'];
  static const List<String> zip3Models = ['zt3', 'g3', 'gt3', 'f3'];
  String? zip3Type; // 'VCU' | 'MCU' (null = operator hasn't chosen)
  String?
  zip3Model; // 'zt3' | 'g3' | 'gt3' | 'f3' (null = operator hasn't chosen)
  bool zip3EnforceModel = true; // info.json enforceModel checkbox
  String zip3Name = ''; // editable displayName; blank → defaultZip3Name

  void setZip3Type(String? t) {
    if (running) return;
    zip3Type = t;
    notifyListeners();
  }

  void setZip3Model(String? m) {
    if (running) return;
    zip3Model = m;
    notifyListeners();
  }

  void setZip3EnforceModel(bool v) {
    if (running) return;
    zip3EnforceModel = v;
    notifyListeners();
  }

  // No notify: the name field is owned by the form's TextEditingController, so
  // rebuilding on each keystroke would fight the cursor. External resets (dump
  // reload / action switch) DO notify, and the form re-syncs from zip3Name then.
  void setZip3Name(String v) => zip3Name = v;

  void _resetZip3Form() {
    zip3Type = null;
    zip3Model = null;
    zip3EnforceModel = true;
    zip3Name = '';
  }

  bool get isFlashOnlySlot0 =>
      actionId == 'flash_only' && flashOnlyScope == FlashOnlyScope.slot0;

  bool get isSlotAction => actionId == 'flash_slot0' || isFlashOnlySlot0;

  String? get firmwarePath =>
      actionId == 'flash_backup' ? _firmwareStandard : _firmwareAdvanced;
  String? get firmwareNote => _firmwareNote;
  bool get firmwareNoteWarn => _firmwareNoteWarn;

  /// Whether the primary CTA is ready to fire for the current action. Firmware
  /// actions need a loaded file; Make zip3 additionally needs both dropdowns
  /// chosen (an MCU dump can't preselect its model).
  bool get canStart {
    if (action.needsFirmware && firmwarePath == null) return false;
    if (actionId == 'make_zip3' && (zip3Type == null || zip3Model == null)) {
      return false;
    }
    return true;
  }

  void setFirmware(String? path, {String? note, bool warn = false}) {
    if (actionId == 'flash_backup') {
      _firmwareStandard = path;
    } else {
      _firmwareAdvanced = path;
    }
    _firmwareNote = path == null ? null : note;
    _firmwareNoteWarn = path != null && warn;
    notifyListeners();
  }

  /// Validate + remember a picked `.bin` for the current action. Structural
  /// checks first (size/path/content), then the mainstream-only banner gate —
  /// Backup+Flash / Flash slot 0 refuse a bin with no readable SCOOTER banner
  /// (Flash Only stays permissive: crafted/unrecognized images are its job).
  /// On success the bin's readable identity (banner model/type + serial state)
  /// becomes the firmware-bar note; generic/cleared serials show amber.
  FirmwareCheck selectFirmwareBin(String path) {
    final makeZip3 = actionId == 'make_zip3';
    // Make zip3 takes a full 128 KB dump (like the mainstream full-image path),
    // never a slot bin.
    final check = isSlotAction
        ? Firmware.validateSlot(path)
        : Firmware.validate(path, requireSize: true);
    if (!check.ok) {
      // A rejected pick leaves no confirmed-good selection for this kind —
      // clear it so Start doesn't stay lit on a stale/invalid file.
      setFirmware(null);
      return check;
    }
    final bytes = File(path).readAsBytesSync();
    // Flash Only and Make zip3 stay permissive: Flash Only writes crafted
    // images, and Make zip3 lets the operator declare identity for a dump whose
    // banner may be blank (rescue / never-provisioned).
    final gate = DeviceSpec.checkIncomingBin(
      bytes,
      slotBin: isSlotAction,
      enforceBanner: actionId != 'flash_only' && !makeZip3,
    );
    if (!gate.ok) {
      setFirmware(null);
      return gate;
    }
    if (makeZip3) {
      // Preselect the dropdowns from the dump's banner (a suggestion only —
      // type reliably, VCU model from its code; MCU/unknown leaves the model
      // empty for the operator). A fresh dump gets a fresh default name.
      final d = PackV3.detect(bytes);
      zip3Type = d.type;
      zip3Model = d.model;
      zip3Name = '';
    }
    final id = DeviceSpec.describeBin(bytes, slotBin: isSlotAction);
    final summary = id.summary;
    setFirmware(
      path,
      note: summary == null ? null : 'Firmware says: $summary',
      warn: id.warn,
    );
    return FirmwareCheck.valid;
  }

  void setFlashOnlyScope(FlashOnlyScope scope) {
    if (running || actionId != 'flash_only' || flashOnlyScope == scope) return;
    flashOnlyScope = scope;
    _firmwareAdvanced = null;
    _firmwareNote = null;
    _firmwareNoteWarn = false;
    _goIdle();
  }

  /// Load a v3 firmware .zip for the current (slot-0) flash: validate the
  /// package, decrypt the encrypted payload, write the plaintext to a temp
  /// .bin, validate it as a slot bin, and remember it. Returns a
  /// [FirmwareCheck] (ok + message) for the UI to surface; on success the bin
  /// is set as the loaded firmware. Does NOT flash — the normal Start flow does.
  Future<FirmwareCheck> loadSlotFirmwareFromZip(String zipPath) async {
    // The pick runs outside a start() run, so it has its own capture that
    // flushes to logs/zip3_import/ (when Save log is on) — otherwise rejections
    // (bad model/type/banner) would only flash by in the console, never saved.
    final importLog = <String>[];
    void ilog(String s) {
      final clean = s.replaceAll(_ansi, '');
      console.add(clean);
      importLog.add(clean);
      notifyListeners();
    }

    // A rejected pick must never leave a stale previously-valid firmware armed.
    setFirmware(null);
    ilog(
      '== zip3 import: ${zipPath.split(RegExp(r'[\\/]')).last} · '
      '${DateTime.now().toString().split('.').first} ==',
    );
    try {
      if (!isSlotAction) {
        return FirmwareCheck.fail(
          'ZIP3 packages are available for slot 0 only.',
        );
      }
      final containerCheck = Firmware.validateZip3Container(zipPath);
      if (!containerCheck.ok) {
        ilog('== package rejected: ${containerCheck.message} ==');
        return containerCheck;
      }
      final bytes = await File(zipPath).readAsBytes();
      final guarded = actionId == 'flash_slot0';
      final pkg = PackV3.unpackV3(bytes, enforceDeviceIdentity: guarded);
      ilog(
        '== package says: ${pkg.displayName} · ${pkg.model}/${pkg.type} · '
        '${pkg.source} · ${pkg.firmware.length} bytes ==',
      );
      final outPath = Firmware.newUnpackedBinPath(
        prefix: backupPrefix,
        name: pkg.displayName,
      );
      await File(outPath).writeAsBytes(pkg.firmware);
      final v = Firmware.validateSlot(outPath);
      if (!v.ok) {
        ilog('== package firmware rejected: ${v.message} ==');
        return FirmwareCheck.fail(v.message);
      }
      final packageClaim =
          'Package says: ${pkg.model.toUpperCase()} · ${pkg.type.toUpperCase()}';
      setFirmware(outPath, note: packageClaim);
      ilog('== loaded slot-0 firmware from package → $outPath ==');
      return FirmwareCheck(
        true,
        'Decrypted ${pkg.firmware.length} bytes from ${pkg.displayName}. '
        '$packageClaim.',
      );
    } on FormatException catch (e) {
      ilog('== package error: ${e.message} ==');
      return FirmwareCheck.fail(e.message);
    } catch (e) {
      ilog('== package error: $e ==');
      return FirmwareCheck.fail('Could not read package: $e');
    } finally {
      if (logToFile) {
        try {
          final p = Firmware.writeLog('zip3_import', importLog.join('\n'));
          _log('== log saved → $p ==');
        } catch (err) {
          _log('== could not save import log: $err ==');
        }
      }
    }
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
  MessageTone messageTone = MessageTone.normal;

  int countdownValue = 0;
  DateTime? _progressShownAt;
  DateTime? _lastProgressAt;
  String? _activeRunEyebrow;
  String? _runIssue;
  int _runIssuePriority = 0;

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
  static const _minBusyVisible = Duration(milliseconds: 1000);
  static const _minAfterLastProgress = Duration(milliseconds: 2500);

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
    if (id == 'flash_only') flashOnlyScope = FlashOnlyScope.fullImage;
    _resetZip3Form(); // the packer form is transient, per action entry
    _firmwareAdvanced = null; // advanced actions don't remember loaded bins
    _firmwareNote = null;
    _firmwareNoteWarn = false;
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
    if (!_realRun) return;
    if (actionId.startsWith('rdp')) {
      _rdp?.sendContinue();
    } else {
      _runner?.sendContinue();
    }
    showContinue = false;
    notifyListeners();
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
    if (actionId == 'flash_only') {
      final slot0 = flashOnlyScope == FlashOnlyScope.slot0;
      title = slot0 ? 'Choose slot-0 firmware' : 'Choose a full image';
      sub = slot0
          ? 'Writes application slot 0 only. Bootloader and identity stay untouched.'
          : 'Writes the complete 128 KB image with no backup or target guard.';
    } else {
      title = action.name;
      sub = action.sub;
    }
    showContinue = false;
    _progressShownAt = null;
    _lastProgressAt = null;
    _activeRunEyebrow = null;
    messageTone = MessageTone.normal;
    _runIssue = null;
    _runIssuePriority = 0;
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
    messageTone = MessageTone.normal;
    showContinue = continueBtn != null;
    if (continueBtn != null) continueLabel = continueBtn;
    notifyListeners();
  }

  void _setInstruction(String value, {MessageTone tone = MessageTone.normal}) {
    if (sub == value && messageTone == tone) return;
    sub = value;
    messageTone = tone;
    notifyListeners();
  }

  /// One-line self-describing header for logs + clipboard (version/OS/mode/time).
  String contextHeader() {
    final os = switch (Platform.operatingSystem) {
      'windows' => 'Windows',
      'macos' => 'macOS',
      'linux' => 'Linux',
      _ => Platform.operatingSystem,
    };
    return 'x3utils v$kAppVersionLabel · $os · ${mode.title} · '
        '${DateTime.now().toString().split('.').first}';
  }

  Future<void> start() async {
    _runIssue = null;
    _runIssuePriority = 0;
    messageTone = MessageTone.normal;
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
    // Make zip3 is offline — a pure file→file repack that never talks to the
    // controller, so it runs before (and independent of) the OpenOCD runner.
    if (actionId == 'make_zip3') {
      await _runMakeZip3();
      return;
    }
    final runner = _runner;
    if (runner == null) {
      _failCannotRun(
        'OpenOCD missing',
        'Cannot run ${action.name}',
        'Bundled OpenOCD was not found. This build cannot talk to the controller.',
      );
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
          if (r.ok) {
            _setInstruction('Target answered. You can continue.');
          }
          await _finishRealAfterHold(
            r.ok,
            action.okMsg,
            'OpenOCD exited with code ${r.exitCode}. Check the console.',
          );
        }
      case 'dump':
        await _runDump(runner, g);
      case 'flash_only':
        await _runFlash(runner, g, backup: false, slot0: isFlashOnlySlot0);
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
        _failCannotRun(
          'Action unavailable',
          'Cannot run this action',
          'This action is not wired to a real OpenOCD command.',
        );
    }
  }

  void _failCannotRun(String eb, String t, String sb) {
    running = false;
    _realRun = false;
    lastConnect = 'FAIL';
    _log('== $t ==');
    _set(StageState.fail, eb, t, sb);
  }

  Future<void> _runRdp(String verb, {required bool yes}) async {
    if (mode == ConnectionMode.powerRace) {
      running = false;
      _realRun = false;
      lastConnect = '—';
      _set(
        StageState.warn,
        'Not supported',
        '${action.name} is not supported in Power-race',
        'RDP/protection work needs a stable OpenOCD session. Use Default SWD, C45 Clone, or C45 Genuine instead.',
      );
      return;
    }

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
    var setupFailure = false;
    try {
      code = await rdp.run(
        verb,
        mode,
        countdownSeconds,
        yes: yes,
        onLine: (line) {
          _onRealLine(line, mode.guided, driveOpenOcdProgress: false);
          if (line.toLowerCase().contains('missing config.sh')) {
            setupFailure = true;
            _setRunIssue('RDP toolkit: missing config.sh', priority: 4);
          }
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
            reseat: !setupFailure,
          );
      }
    } else {
      _finishReal(
        code == 0,
        action.okMsg,
        'rescue exited with code $code. Check the console for what happened.',
        reseat: !setupFailure,
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
    } else if (stage != StageState.run) {
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
          },
          onCaught: () {
            if (my != _token) return;
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
    if (result.exitCode != 0 && _runIssue == null) {
      _setRunIssue(_openOcdExitFallback(result.exitCode, args), priority: 2);
    }
    _realRun = false;
    running = false;
    _log('== openocd exit ${result.exitCode} ==');
    return result;
  }

  void _onRealLine(
    String line,
    bool guided, {
    bool driveOpenOcdProgress = true,
  }) {
    _log(line);
    final clean = line.replaceAll(_ansi, '').trim();
    final low = clean.toLowerCase();
    if (low.contains('target halted')) lastConnect = 'PASS';
    _diagnose(low);
    _surfaceOpenOcdIssue(clean, low);
    if (driveOpenOcdProgress) _advanceOpenOcdStage(low);
    if (guided) _parseGuided(line, low);
  }

  void _surfaceOpenOcdIssue(String clean, String low) {
    final issue = _openOcdIssueText(clean, low);
    if (issue != null) {
      _setRunIssue(issue, priority: low.contains('[fail]') ? 3 : 1);
    }
  }

  void _setRunIssue(String issue, {required int priority}) {
    if (priority < _runIssuePriority) return;
    _runIssue = issue;
    _runIssuePriority = priority;
    if (stage == StageState.fail) {
      _setInstruction(issue, tone: MessageTone.danger);
    }
  }

  String _openOcdExitFallback(int exitCode, List<String> args) {
    final joined = args.join(' ').toLowerCase();
    if (actionId == 'check' || joined.contains('flash probe')) {
      return 'OpenOCD: connection check failed';
    }
    if (joined.contains('dump_image')) return 'OpenOCD: dump did not complete';
    if (joined.contains('do_flash_and_verify') ||
        joined.contains('flash erase') ||
        joined.contains('flash write') ||
        joined.contains('write_image')) {
      return 'OpenOCD: flash did not complete';
    }
    return 'OpenOCD: failed with exit $exitCode';
  }

  String? _openOcdIssueText(String clean, String low) {
    if (clean.isEmpty) return null;
    if (low.contains('shutdown error')) return 'OpenOCD: shutdown error';
    if (low.contains('write protected') ||
        low.contains('read out protection')) {
      return 'OpenOCD: target is protected';
    }
    if (low.contains('timed out') || low.contains('timeout')) {
      return 'OpenOCD: timeout';
    }
    if (low.contains('open failed')) return 'OpenOCD: open failed';
    if (low.contains('unable to open')) return 'OpenOCD: unable to open';
    if (low.contains('adapter init failed')) {
      return 'OpenOCD: adapter init failed';
    }
    if (low.contains('init mode failed')) {
      return 'OpenOCD: init mode failed';
    }
    if (low.contains('unable to connect to the target')) {
      return 'OpenOCD: unable to connect to target';
    }
    if (low.contains('no device found')) return 'OpenOCD: no device found';
    if (low.contains('target not halted')) {
      return 'OpenOCD: target not halted';
    }
    if (low.contains('[fail]')) {
      final idx = low.indexOf('[fail]');
      return 'OpenOCD: ${clean.substring(idx + 6).trim()}';
    }
    if (low.contains('verify failed')) return 'OpenOCD: verify failed';
    if (low.contains('erase failed')) return 'OpenOCD: erase failed';
    if (low.contains('write failed')) return 'OpenOCD: write failed';
    if (low.startsWith('error:')) {
      return 'OpenOCD: ${clean.substring(6).trim()}';
    }
    if (low.contains(' error:')) {
      final idx = low.indexOf(' error:');
      return 'OpenOCD: ${clean.substring(idx + 7).trim()}';
    }
    return null;
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
      _progressShownAt ??= DateTime.now();
      _set(
        StageState.connect,
        _activeRunEyebrow ?? 'Linking',
        _activeRunEyebrow == null ? 'Connected' : action.name,
        'Keep the ST-LINK and SWD wires steady.',
      );
    } else if (low.contains('connecting in')) {
      final n = _trailingInt(line);
      if (n != null) countdownValue = n;
      showContinue = false;
      _set(
        StageState.count,
        'Step 2 of 3',
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
          'Step 2 of 3',
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
    } else if (_runIssue != null) {
      msg = reseat ? '$_runIssue\n$_reseatHint' : _runIssue!;
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

  Future<void> _finishRealAfterHold(
    bool ok,
    String okMsg,
    String failMsg, {
    bool reseat = true,
  }) async {
    final my = _token;
    final hadBusySurface = _busySurfaceIsVisible;
    await _holdBusySurfaceForReading();
    if (my != _token) return;
    if (hadBusySurface && !_busySurfaceIsVisible) return;
    _finishReal(ok, okMsg, failMsg, reseat: reseat);
  }

  Future<void> _holdBusySurfaceForReading() async {
    if (!_busySurfaceIsVisible) return;
    final shownAt = _progressShownAt;
    if (shownAt == null) return;

    final now = DateTime.now();
    var wait = Duration.zero;
    final shownElapsed = now.difference(shownAt);
    if (shownElapsed < _minBusyVisible) {
      wait = _minBusyVisible - shownElapsed;
    }

    final lastAt = _lastProgressAt;
    if (lastAt != null) {
      final lastElapsed = now.difference(lastAt);
      if (lastElapsed < _minAfterLastProgress) {
        final afterLastWait = _minAfterLastProgress - lastElapsed;
        if (afterLastWait > wait) wait = afterLastWait;
      }
    }

    if (wait > Duration.zero) {
      await Future.delayed(wait);
    }
  }

  bool get _busySurfaceIsVisible =>
      (stage == StageState.run || stage == StageState.connect) &&
      _progressShownAt != null;

  /// Live operator hint for a power-race miss, keyed to how far it got.
  String _raceHint(RaceTier tier) => switch (tier) {
    RaceTier.searching => 'No contact yet — cut & re-apply power.',
    RaceTier.noisy => 'On the pad but bouncing — hold it steadier.',
    RaceTier.nearCatch => 'Almost — reached the core, keep holding.',
    RaceTier.adapterGone => 'ST-LINK not seen — check the probe / USB.',
    RaceTier.timedOut =>
      'OpenOCD stalled — power-cycle and try the next catch.',
  };

  /// Any live OpenOCD marker shows the busy surface and keeps the race watchdog
  /// fed. Markers are not told apart; the eyebrow is per-action, not per-stage.
  void _advanceOpenOcdStage(String low) {
    if (low.contains('target halted') ||
        low.contains('caught; hold power') ||
        low.contains('x3_caught_hold_power') ||
        low.contains("flash 'at32f415xx' found") ||
        low.contains('dumped') ||
        low.contains('erased') ||
        low.contains('wrote') ||
        low.contains('written') ||
        low.contains('verified')) {
      _lastProgressAt = DateTime.now();
      _showOpenOcdProgress();
    }
  }

  void _showOpenOcdProgress({String? eyebrow}) {
    if (stage == StageState.hold ||
        stage == StageState.count ||
        stage == StageState.release) {
      return;
    }
    if (eyebrow != null) _activeRunEyebrow = eyebrow;
    if (eyebrow == null && stage == StageState.run) return;
    _progressShownAt ??= DateTime.now();
    _set(
      StageState.run,
      eyebrow ?? _activeRunEyebrow ?? _runEyebrow(),
      action.name,
      sub,
    );
  }

  String _runEyebrow() => switch (actionId) {
    'check' => 'Checking',
    'dump' => 'Backing up',
    'flash_backup' || 'flash_only' || 'flash_slot0' => 'Flashing',
    'flash_compat' => 'Working',
    'rdp_check' => 'Protection',
    'rdp_rescue' => 'Rescue',
    _ => 'Working',
  };

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
    _showOpenOcdProgress(eyebrow: 'Backing up');
    _setInstruction('Reading the full 128 KB flash into a backup file...');
    final r = await _runRealCore(
      runner.dumpArgs(mode, countdownSeconds, outPath),
      guided: guided,
    );
    if (r == null) return;
    if (!_dumpConfirmed(r)) {
      await _finishRealAfterHold(false, '', _dumpFailMessage(r));
      return;
    }
    _setInstruction('Backup saved to $outPath');
    _setInstruction('Validating backup file...');
    final v = Firmware.validate(outPath);
    if (!v.ok) {
      _log('== validation FAILED: ${v.message} ==');
      await _finishRealAfterHold(
        false,
        '',
        'Dump saved but failed validation — do not trust it. ${v.message} '
            '(a read-protected or blank chip reads back like this — try Check protection).',
        reseat: false,
      );
      return;
    }
    _log('== validated OK → $outPath ==');
    _setInstruction('Backup validated. Keep this file safe.');
    _maybeSecondCopy(outPath);
    await _finishRealAfterHold(true, 'Backed up & verified → $outPath', '');
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

    if (actionId == 'flash_only') {
      _log(
        '== flash_only scope=${slot0 ? 'slot0' : 'full'} '
        '— no backup, no target guard ==',
      );
    }

    String? backupPath;
    String?
    serialNote; // identity change fact for the log + result (never blocks)

    // Mandatory backup first (the scripts' safety floor) — abort flash if it fails.
    if (backup) {
      final outPath = Firmware.newDumpPath(
        folder: backupFolder,
        prefix: backupPrefix,
      );
      _showOpenOcdProgress(eyebrow: 'Backing up');
      _setInstruction('Backing up the chip before flashing...');
      final b = await _runRealCore(
        runner.dumpArgs(mode, countdownSeconds, outPath),
        guided: guided,
        title: 'Backing up first…',
      );
      if (b == null) return;
      if (!_dumpConfirmed(b)) {
        await _finishRealAfterHold(
          false,
          '',
          'Backup did not confirm a complete dump — flash aborted for safety. ${_dumpFailMessage(b)}',
        );
        return;
      }
      _setInstruction('Backup saved to $outPath');
      _setInstruction('Validating backup file before writing...');
      final backupCheck = Firmware.validate(outPath);
      if (!backupCheck.ok) {
        _log('== validation FAILED: ${backupCheck.message} ==');
        await _finishRealAfterHold(
          false,
          '',
          'Backup validation failed — flash aborted for safety. ${backupCheck.message} '
              '(read-protected or blank chip? try Check protection).',
          reseat: false,
        );
        return;
      }
      _log('== backup ok → $outPath ==');
      _setInstruction('Backup validated. Writing can continue.');
      _maybeSecondCopy(outPath);
      backupPath = outPath;

      // Device-side guard: does the target (from the backup we just took) match
      // the firmware we're about to write? Banner mismatch → abort, keep the
      // backup. Blank/unreadable target → allowed (first-flash / rescue).
      // Serials never decide — they are read, logged, and reported only.
      _setInstruction('Checking the target matches the firmware...');
      final dumpBytes = File(outPath).readAsBytesSync();
      final fwBytes = File(fw).readAsBytesSync();
      final targetId = DeviceSpec.describeBin(dumpBytes, slotBin: false);
      final fwId = DeviceSpec.describeBin(fwBytes, slotBin: slot0);
      _log('== target identity: ${targetId.logLine} ==');
      _log('== firmware identity: ${fwId.logLine} ==');
      serialNote = DeviceSpec.serialChangeNote(
        target: targetId.serial!,
        incoming: fwId.serial,
      );
      if (serialNote != null) _log('== note: $serialNote ==');
      final tm = DeviceSpec.checkTargetMatch(
        dump: dumpBytes,
        firmware: fwBytes,
        incomingIsSlotBin: slot0,
      );
      if (tm.blocked) {
        _log('== target mismatch: ${tm.message} ==');
        await _finishRealAfterHold(
          false,
          '',
          'Flash aborted — ${tm.message} Backup saved to $outPath.',
          reseat: false,
        );
        return;
      }
      if (tm.note != null) _log('== ${tm.note} ==');
    }

    final args = slot0
        ? runner.flashSlot0Args(mode, countdownSeconds, fw)
        : runner.flashArgs(mode, countdownSeconds, fw);
    _showOpenOcdProgress(eyebrow: 'Flashing');
    _setInstruction(
      slot0
          ? 'Writing slot 0 only. Bootloader and identity stay untouched.'
          : backup
          ? 'Writing the selected firmware...'
          : 'Writing without a backup. Keep the ST-LINK and SWD wires steady.',
    );
    final r = await _runRealCore(
      args,
      guided: guided,
      title: '${action.name}…',
    );
    if (r == null) return;
    final flashOk = _flashConfirmed(r);
    if (flashOk) {
      _setInstruction(
        slot0
            ? 'Slot 0 verified.'
            : backup
            ? 'Flash verified. Backup was saved first.'
            : 'Flash verified. No backup was taken.',
      );
    }
    var okMsg = backup && backupPath != null
        ? slot0
              ? 'Slot 0 flashed & verified. Backup saved to $backupPath'
              : 'Flashed & verified. Backup saved to $backupPath'
        : slot0
        ? 'Slot 0 flashed & verified. No backup was taken.'
        : action.okMsg;
    if (serialNote != null) okMsg = '$okMsg. Note: $serialNote.';
    await _finishRealAfterHold(flashOk, okMsg, _flashFailMessage(r));
  }

  /// SHU-compat: dump the chip → patch its own firmware → flash it back
  /// (mirrors flash_compat.bat; no user .bin — uses the chip's own image).
  Future<void> _runCompat(OpenOcdRunner runner, bool guided) async {
    final (raw, patched) = Firmware.newCompatPaths(prefix: backupPrefix);
    _showOpenOcdProgress(eyebrow: 'Backing up');
    _setInstruction('Reading the chip before patching...');

    // Step 1 — read the current firmware.
    final d = await _runRealCore(
      runner.dumpArgs(mode, countdownSeconds, raw),
      guided: guided,
      title: 'Reading current firmware…',
    );
    if (d == null) return;
    if (!_dumpConfirmed(d)) {
      await _finishRealAfterHold(
        false,
        '',
        'Could not confirm a complete chip read — nothing was changed. ${_dumpFailMessage(d)}',
      );
      return;
    }
    final rawCheck = Firmware.validate(raw);
    if (!rawCheck.ok) {
      _log('== validation FAILED: ${rawCheck.message} ==');
      await _finishRealAfterHold(
        false,
        '',
        'The chip read back as invalid — nothing was written. ${rawCheck.message} '
            '(a read-protected or blank chip reads back like this — try Check protection).',
        reseat: false,
      );
      return;
    }

    _setInstruction('Original backup saved to $raw');
    _maybeSecondCopy(raw);

    // Step 2 — patch (pure Dart, no hardware).
    _showOpenOcdProgress(eyebrow: 'Patching');
    _setInstruction('Patching the SHU compatibility signature...');
    _log('== patching SHU-compat signature @ 0x1420 ==');
    final patch = CompatPatch.apply(raw, patched);
    if (!patch.ok || !Firmware.validate(patched).ok) {
      _log('== patch FAILED: ${patch.message} ==');
      await _finishRealAfterHold(
        false,
        '',
        'Patch failed — the chip was NOT written. ${patch.message}',
        reseat: false,
      );
      return;
    }
    _log('== patched → $patched ==');
    _showOpenOcdProgress(eyebrow: 'Patching');
    _setInstruction('SHU patch applied. Ready to flash...');
    await Future.delayed(const Duration(milliseconds: 900));

    // Step 3 — flash the patched image back.
    _showOpenOcdProgress(eyebrow: 'Flashing');
    _setInstruction('Flashing it back to the chip...');
    final f = await _runRealCore(
      runner.flashArgs(mode, countdownSeconds, patched),
      guided: guided,
      title: 'Flashing SHU-compatible firmware…',
    );
    if (f == null) return;
    final flashOk = _flashConfirmed(f);
    if (flashOk) {
      _setInstruction('SHU-compatible firmware verified.');
    }
    await _finishRealAfterHold(
      flashOk,
      'SHU-compatible firmware flashed & verified. Original saved to $raw',
      _flashFailMessage(f),
    );
  }

  /// Offline "Make zip3": read a full 128 KB backup dump, recover the exact
  /// slot-0 payload via the device's own ZP length record, and repack it as a
  /// BLE-loadable v3 package with the operator-declared identity. No hardware —
  /// a file→file transform, so it just validates, packs, writes, and reports.
  Future<void> _runMakeZip3() async {
    final src = firmwarePath;
    if (src == null) {
      _set(
        StageState.fail,
        'No dump',
        'Choose a 128 KB dump first',
        'Pick a full backup .bin, then make the package.',
      );
      return;
    }
    final type = zip3Type;
    final model = zip3Model;
    if (type == null || model == null) {
      _set(
        StageState.fail,
        'Pick identity',
        'Choose the type and model',
        'Set the firmware Type and Model the package should declare.',
      );
      return;
    }
    // Re-validate the dump at run time (the picker already did, but the file
    // could have changed on disk).
    final v = Firmware.validate(src, requireSize: true);
    if (!v.ok) {
      _set(StageState.fail, 'Dump invalid', 'Dump invalid', v.message);
      return;
    }

    final name = zip3Name.trim().isEmpty
        ? Firmware.defaultZip3Name(model: model, type: type)
        : zip3Name.trim();
    _log(
      '== make zip3: $model/$type · enforceModel=$zip3EnforceModel · '
      'name="$name" ==',
    );
    try {
      final bytes = File(src).readAsBytesSync();
      final result = PackV3.buildZip3FromDump(
        bytes,
        type: type,
        model: model,
        enforceModel: zip3EnforceModel,
        displayName: name,
      );
      final outPath = Firmware.packedZip3Path(
        result.displayName,
        prefix: backupPrefix,
      );
      File(outPath).writeAsBytesSync(result.zipBytes);
      _log(
        '== packed ${result.model}/${result.type} · '
        '${result.payloadLength} B payload → $outPath ==',
      );
      _finishReal(
        true,
        'zip3 written → $outPath (${result.model.toUpperCase()} · '
            '${result.type} · ${result.payloadLength} bytes)',
        '',
        reseat: false,
      );
    } on FormatException catch (e) {
      // The ZP guard fails closed on a dump whose exact length can't be read.
      _log('== make zip3 failed: ${e.message} ==');
      _finishReal(false, '', e.message, reseat: false);
    } catch (e) {
      _log('== make zip3 error: $e ==');
      _finishReal(false, '', 'Could not write the package: $e', reseat: false);
    }
  }
}
