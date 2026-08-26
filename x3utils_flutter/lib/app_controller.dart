import 'dart:async';
import 'dart:ui' show Color;
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_io/universal_io.dart';
import 'models.dart';
import 'theme.dart';
import 'engine/android_backup_store.dart';
import 'engine/backup_download.dart';
import 'engine/desktop_backend_router.dart';
import 'engine/hardware_backend.dart';
import 'engine/openocd_backend.dart';
import 'engine/openocd_paths.dart';
import 'engine/openocd_runner.dart';
import 'engine/rdp_runner.dart';
import 'engine/swdart_backend.dart';
import 'engine/device_spec.dart';
import 'engine/firmware.dart';
import 'engine/firmware_inspection.dart';
import 'engine/pack_zip3.dart';
import 'engine/confirmed_file_writer.dart';
import 'engine/dump_metadata.dart';
import 'engine/fw_version.dart';
import 'engine/trash.dart';
import 'engine/zp_extract.dart';

/// Asks the operator which model an MCU dump belongs to.
///
/// MCU firmware carries no model identity — every build banners as
/// `SCOOTER_MCU_0001` — and the binaries genuinely differ between models, so
/// this is a DECLARATION we cannot verify, not a check. Returning null cancels.
typedef AskMcuModel = Future<String?> Function(List<String> models);

/// Asks whether to continue when the installed firmware could not be
/// identified — the one outcome that is the operator's call rather than the
/// tool's. Blacklisted builds never reach it, and a missing callback fails
/// closed.
///
/// [ceiling] arrives separately from [finding] so the view can weight it: it
/// carries the number that would have decided this, and it is the sentence the
/// operator most needs to read before choosing.
typedef ConfirmUnidentified =
    Future<bool> Function(String finding, String ceiling);

typedef BackupDownloader =
    Future<void> Function(Uint8List bytes, String fileName);

/// Testing-only Android connection mode. Set false for a shipping build unless
/// genuine ST-Link nRST has been deliberately retained.
const bool kAndroidEnableGenuineC45ForTesting = false;

/// What identification established about the firmware on the chip, carried
/// forward so the packaging step names its output from evidence gathered
/// before the write rather than re-deriving it from the image afterwards.
///
/// [version] is null only when the operator chose to continue past a build
/// x3utils could not place — the one case where a package cannot claim a
/// version and must not look as though it does.
///
/// [modelDeclared] records that the model was picked by the operator (MCU
/// firmware carries no model identity) rather than read from the banner. It is
/// not verifiable, so anything named from it inherits that uncertainty.
class CompatIdentity {
  const CompatIdentity({
    required this.model,
    required this.type,
    required this.version,
    required this.modelDeclared,
  });

  final String model;
  final String type;
  final String? version;
  final bool modelDeclared;

  /// The identity stem both packages of a run share: `zt3_vcu_v1.5.5`, or
  /// `zt3_vcu_unknownfw` when the operator waved an unplaceable build through.
  /// Only the trailing `_stock` / `_compat` tells the two apart.
  String get nameStem {
    final v = version == null ? 'unknownfw' : 'v$version';
    return '${model.toLowerCase()}_${type.toLowerCase()}_$v';
  }
}

/// Drives the whole UI via a single StageState the hero binds to.
class AppController extends ChangeNotifier {
  AppController({
    HardwareBackend? backend,
    bool? phoneMode,
    @visibleForTesting OpenOcdRunner? runner,
    @visibleForTesting bool? browserMode,
    @visibleForTesting bool? androidMode,
    @visibleForTesting BackupDownloader? backupDownloader,
    @visibleForTesting AndroidBackupPublisher? androidBackupPublisher,
  }) : assert(
         backend == null || runner == null,
         'Provide either backend or runner, not both.',
       ),
       _browserMode = browserMode ?? kIsWeb,
       _androidMode = androidMode ?? (!kIsWeb && Platform.isAndroid),
       // Defaults to androidMode, so the APK and both desktop builds are
       // unaffected by the existence of this flag. Only lib/main_mobile.dart
       // passes it explicitly.
       _phoneMode = phoneMode ?? androidMode ?? (!kIsWeb && Platform.isAndroid),
       _backupDownloader = backupDownloader ?? downloadBackupBytes,
       _androidBackupPublisher =
           androidBackupPublisher ?? publishAndroidBackup {
    if (backend != null) {
      _backend = backend;
      if (!_browserMode && backend is DesktopBackendRouter) {
        _desktopBackendRouter = backend;
      }
      _syncBackendStatus();
      _configureDeviceBackend();
      _loadPrefs();
      return;
    }
    if (runner != null) {
      _backend = OpenOcdBackend(runner: runner);
      backendStatus = 'ready';
      _loadPrefs();
      return;
    }
    if (_browserMode) {
      _backend = SwdartBackend(
        enableCloneC45: true,
        enableGenuineNrst: true,
        enablePowerRace: true,
      );
      _configureDeviceBackend();
      _loadPrefs();
      return;
    }
    if (_androidMode) {
      _backend = SwdartBackend(
        enableCloneC45: true,
        enableGenuineNrst: kAndroidEnableGenuineC45ForTesting,
        enablePowerRace: true,
        capabilityOverride: const HardwareCapabilities(
          connectionModes: {
            ConnectionMode.defaultSwd,
            ConnectionMode.powerRace,
            ConnectionMode.cloneC45,
            if (kAndroidEnableGenuineC45ForTesting) ConnectionMode.genuineC45,
          },
          check: true,
          dump: true,
          flashFull: true,
          flashSlot0: true,
          protectionCheck: true,
          protectionRescue: false,
        ),
      );
      _configureDeviceBackend();
      _loadPrefs();
      return;
    }
    HardwareBackend? openOcd;
    String? openOcdUnavailableReason;
    try {
      final paths = OpenOcdPaths.find();
      openOcd = OpenOcdBackend(
        runner: OpenOcdRunner(paths),
        protectionRunner: RdpRunner(paths),
      );
    } catch (e) {
      openOcdUnavailableReason = '$e';
      console.add('OpenOCD not found: $e');
    }
    final router = DesktopBackendRouter(
      openOcd: openOcd,
      swdart: SwdartBackend(
        enableCloneC45: true,
        enableGenuineNrst: true,
        enablePowerRace: true,
      ),
      openOcdUnavailableReason: openOcdUnavailableReason,
    );
    _desktopBackendRouter = router;
    _backend = router;
    _syncBackendStatus();
    _loadPrefs();
  }

  // ── Backups settings (persisted) ──────────────────────────────────────────
  SharedPreferences? _prefs;
  final bool _browserMode;
  final bool _androidMode;
  final bool _phoneMode;
  final BackupDownloader _backupDownloader;
  final AndroidBackupPublisher _androidBackupPublisher;
  DesktopBackendRouter? _desktopBackendRouter;

  bool get browserMode => _browserMode;

  /// The Android PLATFORM: USB-host transport, scoped storage, the permission
  /// wording. False in a browser even when the phone layout is in use.
  bool get androidMode => _androidMode;

  /// The phone TIER: the compact layout and the reduced action set, shared by
  /// the Android APK and the mobile web build at /m/. Deliberately separate
  /// from [androidMode] — the two coincide in the APK and diverge in Chrome.
  bool get phoneMode => _phoneMode;

  /// Transport shown beside the ST-Link in the phone connection rows.
  String get probeTransportLabel =>
      _browserMode ? 'ST-LINK · WebUSB' : 'ST-LINK · USB OTG';

  /// Where a backup lands, for the phone action rows. Android publishes through
  /// scoped storage to a known folder; a browser hands the file to Chrome and
  /// cannot know where it ends up.
  String get backupDestinationLabel =>
      _browserMode ? 'Browser download' : androidBackupDirectoryLabel;
  String get backendName =>
      _backend?.name ??
      (_browserMode
          ? 'swdart'
          : _androidMode
          ? 'Android USB-host'
          : 'OpenOCD');

  String? x3utilsRoot; // null = the per-OS default (Firmware.defaultRoot)
  String backupPrefix = '';
  bool secondCopy = true; // redundant %LOCALAPPDATA%\x3utils_backup copy

  /// BETA3 bench switch — safe ACP validation is the default; this deliberately
  /// restores the unrestricted BETA2 behavior for comparison runs only.
  bool bypassWindowsPathSafety = false;

  bool get desktopBackendSelectorAvailable =>
      !_browserMode && _desktopBackendRouter != null;

  bool get useSwdartDesktop =>
      _desktopBackendRouter?.selection == DesktopBackendSelection.swdart;

  SwdartBackend? get _desktopSwdartBackend {
    final swdart = _desktopBackendRouter?.swdart;
    return swdart is SwdartBackend ? swdart : null;
  }

  bool get desktopSwdartLoaderSelectorAvailable =>
      desktopBackendSelectorAvailable &&
      useSwdartDesktop &&
      _desktopSwdartBackend != null;

  bool get useSwdartLoaderDesktop =>
      _desktopSwdartBackend?.useAt32Loader ?? true;

  String get engineDescription {
    if (_browserMode) return 'Engine: swdart · WebUSB · AT32F415';
    if (_androidMode) {
      return 'Engine: swdart · Android USB-host · AT32F415';
    }
    if (useSwdartDesktop) {
      final programming = useSwdartLoaderDesktop
          ? 'SRAM loader'
          : 'direct word writes';
      return 'Engine: swdart experimental · native libusb · AT32F415 · '
          '$programming';
    }
    return 'Engine: bundled OpenOCD (frozen) · AT32F415';
  }

  bool get windowsPathBenchAvailable =>
      Platform.isWindows && kAppStage == 'BETA3';

  // Connection modes the user moved to the Advanced rail (persisted). Empty = all
  // in the standard "Connection" group; rendering order is always canonical.
  final Set<ConnectionMode> _advancedModes = <ConnectionMode>{};

  Future<void> _loadPrefs() async {
    _prefs = await SharedPreferences.getInstance();
    final router = _desktopBackendRouter;
    if (router != null) {
      // swdart is the shipping default from 2.1.0. The test is written against
      // openOcd, not swdart, so an operator who explicitly chose OpenOCD keeps
      // it: only that choice writes the openOcd key. An unset key is a fresh
      // install and gets swdart. OpenOCD stays bundled and selectable.
      final saved = _prefs!.getString('desktopHardwareBackend');
      router.select(
        saved == DesktopBackendSelection.openOcd.name
            ? DesktopBackendSelection.openOcd
            : DesktopBackendSelection.swdart,
      );
      final swdart = _desktopSwdartBackend;
      if (swdart != null) {
        swdart.useAt32Loader = _prefs!.getBool('desktopSwdartLoader') ?? true;
      }
      _syncBackendStatus();
    }
    // The old `backupFolder` key (v1.2.1 and earlier) is never read again. The
    // same string meant "where dumps go", not "the parent of backup/", so
    // carrying it over would move a user's backups a level down and scatter
    // four more folders into a place picked for one purpose. The orphan key is
    // inert; there is no migration.
    x3utilsRoot = _browserMode || _androidMode
        ? null
        : _prefs!.getString('x3utilsRoot');
    Firmware.setRoot(x3utilsRoot);
    backupPrefix = _prefs!.getString('backupPrefix') ?? '';
    secondCopy =
        !_browserMode &&
        !_androidMode &&
        (_prefs!.getBool('secondCopy') ?? true);
    // NB `compatAskWhenUnidentified` (GUI v1.2.8 only) is never read again: an
    // unrecognised build now always asks the operator, so there is nothing left
    // for a stored preference to switch. The orphan key is inert.
    // Deliberately a new BETA3 key. A BETA2 "allow everything" preference must
    // not carry forward silently, and no stored bench setting may activate in
    // a later beta or stable build whose stage does not explicitly opt in.
    bypassWindowsPathSafety =
        windowsPathBenchAvailable &&
        (_prefs!.getBool('beta3BypassWindowsPathSafety') ?? false);
    Firmware.bypassWindowsPathSafety = bypassWindowsPathSafety;
    // Rail layout re-seed. Bumping this stamp forces EVERY install back to the
    // ship default once, discarding arrangements the user chose deliberately;
    // only bump it for an intended relayout, never as a side effect.
    const railLayoutSeed = 2;
    final seeded = _prefs!.getInt('railLayoutSeed') ?? 0;
    final adv = seeded == railLayoutSeed
        ? _prefs!.getStringList('advancedModes')
        : null;
    _advancedModes.clear();
    if (adv == null) {
      // Ship default: only genuine C45 starts in Advanced. The user can
      // right-click it back to Main; that choice then persists.
      _advancedModes.add(ConnectionMode.genuineC45);
      _prefs!
        ..setStringList(
          'advancedModes',
          _advancedModes.map((e) => e.name).toList(),
        )
        ..setInt('railLayoutSeed', railLayoutSeed);
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
    if (!availableModes.contains(defaultMode)) {
      defaultMode = ConnectionMode.defaultSwd;
    }
    defaultCountdown =
        (_prefs!.getInt('defaultCountdown') ??
                _prefs!.getInt('countdown') ??
                defaultCountdown)
            .clamp(0, 10);
    defaultAutoRetry = (_prefs!.getInt('defaultAutoRetry') ?? defaultAutoRetry)
        .clamp(0, 10);
    // Seed the live session from the defaults.
    mode = defaultMode;
    countdownSeconds = defaultCountdown;
    autoRetrySeconds = defaultAutoRetry;
    final ai = _prefs!.getInt('accent') ?? 1; // default: Silver
    final accentCount = _phoneMode ? 4 : kAccents.length;
    final validAccent = ai >= 0 && ai < accentCount;
    accentNotifier.value = validAccent ? ai : (_phoneMode ? 1 : 0);
    if (_phoneMode && !validAccent) {
      await _prefs!.setInt('accent', accentNotifier.value);
    }
    // ON by default from 2.1.0 on desktop: a run the operator wants help with
    // should already have its transcript on disk. Turning it off writes false
    // and keeps it off. Web/Android have nowhere to write and stay off.
    logToFile =
        !_browserMode &&
        !_androidMode &&
        (_prefs!.getBool('logToFile') ?? true);
    // ON by default from 2.1.0 on DESKTOP. The loader failure that took weeks
    // to find was intermittent, so a field recurrence must arrive with its
    // register baseline and per-chunk log already in the transcript — which
    // works because desktop also writes that transcript to a file. Web/Android
    // default OFF: the console is their only transcript, so a per-chunk
    // baseline buries the run instead of documenting it. The switch stays
    // available on all three, and turning it off writes false and keeps it off.
    loaderDiagnostics =
        _prefs!.getBool('loaderDiagnostics') ?? (!_browserMode && !_androidMode);
    _applyLoaderDiagnostics();
    notifyListeners();
  }

  void toggleLogToFile() {
    logToFile = !logToFile;
    _prefs?.setBool('logToFile', logToFile);
    notifyListeners();
  }

  // ── Advanced logging (persisted) ──────────────────────────────────────────
  // Opt-in swdart SRAM-loader diagnostics: register baseline before flashing
  // plus per-chunk programming logs. Exists to make the intermittent loader
  // failure self-documenting on the first real recurrence.
  bool loaderDiagnostics = false;

  /// The toggle only means something where a swdart engine is actually
  /// SELECTED: always on Web/Android, and on desktop only while the swdart
  /// backend is on.
  ///
  /// The desktop half deliberately reuses [desktopSwdartLoaderSelectorAvailable]
  /// so this row and `SRAM loader` appear and disappear together — they
  /// describe the same engine, and the diagnostics are SRAM-loader-only. The
  /// previous form asked whether the router HELD a swdart backend, which is
  /// true even when OpenOCD is selected, so the row stayed visible and ON while
  /// it could not affect anything.
  ///
  /// Hiding does not clear the setting: [loaderDiagnostics] and its stored key
  /// are untouched, so switching swdart back on restores the operator's choice.
  /// Writing `false` here would be wrong — under the persisted-default rules an
  /// explicit `false` is preserved, so it would silently destroy an ON choice.
  bool get loaderDiagnosticsAvailable =>
      _backend is SwdartBackend || desktopSwdartLoaderSelectorAvailable;

  void setLoaderDiagnostics(bool value) {
    loaderDiagnostics = value;
    _prefs?.setBool('loaderDiagnostics', value);
    _applyLoaderDiagnostics();
    notifyListeners();
  }

  void _applyLoaderDiagnostics() {
    final backend = _backend;
    final swdart = backend is SwdartBackend
        ? backend
        : _desktopBackendRouter?.swdart;
    if (swdart is SwdartBackend) swdart.loaderDiagnostics = loaderDiagnostics;
  }

  // ── Desktop swdart programming path (persisted) ─────────────────────────
  // This A/B control is intentionally desktop-only. Web and Android retain
  // their existing SRAM-loader behavior while the direct path is evaluated.
  void setUseSwdartLoaderDesktop(bool value) {
    if (running) return;
    final swdart = _desktopSwdartBackend;
    if (swdart == null) return;
    swdart.useAt32Loader = value;
    _prefs?.setBool('desktopSwdartLoader', value);
    notifyListeners();
  }

  int get accentIndex => accentNotifier.value;

  void setAccent(int i) {
    final accentCount = _phoneMode ? 4 : kAccents.length;
    final idx = (i >= 0 && i < accentCount) ? i : (_phoneMode ? 1 : 0);
    accentNotifier.value = idx; // drives the app-wide recolor
    _prefs?.setInt('accent', idx);
  }

  /// Point the whole x3utils folder somewhere else; null restores the default.
  /// Nothing is moved — an existing tree is left exactly where it is and the
  /// app simply starts writing to the new one.
  void setX3utilsRoot(String? folder) {
    x3utilsRoot = folder;
    Firmware.setRoot(folder);
    if (folder == null) {
      _prefs?.remove('x3utilsRoot');
    } else {
      _prefs?.setString('x3utilsRoot', folder);
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

  void setUseSwdartDesktop(bool value) {
    final router = _desktopBackendRouter;
    if (router == null || running) return;
    router.select(
      value ? DesktopBackendSelection.swdart : DesktopBackendSelection.openOcd,
    );
    _prefs?.setString('desktopHardwareBackend', router.selection.name);
    _syncBackendStatus();
    _log('== desktop backend selected: ${router.name} ==');
    _goIdle();
  }

  void _syncBackendStatus() {
    final router = _desktopBackendRouter;
    backendStatus = router == null || router.selectedAvailable
        ? 'ready'
        : 'missing';
  }

  void _configureDeviceBackend() {
    final backend = _backend;
    if (!_browserMode && !_androidMode) return;
    if (backend is! HardwareDeviceBackend) return;
    final deviceBackend = backend as HardwareDeviceBackend;
    _applyDeviceStatus(deviceBackend.deviceStatus, notify: false);
    deviceBackend.watchDevice(_applyDeviceStatus);
    unawaited(_refreshDeviceBackend(deviceBackend));
  }

  Future<void> _refreshDeviceBackend(HardwareDeviceBackend backend) async {
    try {
      _applyDeviceStatus(await backend.refreshDevice());
    } catch (error) {
      _log('== could not refresh USB probe state: $error ==');
    } finally {
      _deviceProbeRefreshComplete = true;
      notifyListeners();
    }
  }

  void _applyDeviceStatus(HardwareDeviceStatus status, {bool notify = true}) {
    _deviceStatus = status;
    backendStatus = switch (status.state) {
      HardwareDeviceState.ready => 'ready',
      HardwareDeviceState.selectionRequired => 'select',
      HardwareDeviceState.disconnected => 'disconnected',
      HardwareDeviceState.ambiguous => 'multiple',
      HardwareDeviceState.unsupported => 'unsupported',
    };
    if (notify) notifyListeners();
  }

  /// BETA3 bench switch — see [Firmware.bypassWindowsPathSafety]. Pushed into
  /// the engine immediately so the next run uses it without a restart.
  void setBypassWindowsPathSafety(bool v) {
    final enabled = windowsPathBenchAvailable && v;
    bypassWindowsPathSafety = enabled;
    Firmware.bypassWindowsPathSafety = enabled;
    _prefs?.setBool('beta3BypassWindowsPathSafety', enabled);
    notifyListeners();
  }

  /// The redundant copy carries the sidecar too when there is one: a backup
  /// that outlives its root is a 128 KB blob without the file that says what
  /// it is. The sidecar only follows a backup that copied successfully, so the
  /// 2nd-copy dir can never hold metadata for an image that is not beside it.
  void _maybeSecondCopy(String srcPath, {String? sidecarPath}) {
    if (!secondCopy) return;
    final dest = Firmware.secondCopy(srcPath);
    if (dest == null) return;
    _log('== 2nd copy → $dest ==');
    if (sidecarPath == null) return;
    final info = Firmware.secondCopy(sidecarPath);
    if (info != null) _log('== 2nd copy → $info ==');
  }

  HardwareBackend? _backend;
  HardwareDeviceStatus? _deviceStatus;
  bool _deviceProbeRefreshComplete = false;
  String backendStatus = 'checking';

  bool get deviceProbeControlAvailable =>
      (_browserMode || _androidMode) && _backend is HardwareDeviceBackend;

  bool get deviceProbeReady =>
      !deviceProbeControlAvailable || (_deviceStatus?.ready ?? false);

  bool get deviceProbeRefreshComplete =>
      !deviceProbeControlAvailable || _deviceProbeRefreshComplete;

  bool get deviceProbeNeedsSelection =>
      deviceProbeControlAvailable &&
      (_deviceStatus?.state == HardwareDeviceState.selectionRequired ||
          _deviceStatus?.state == HardwareDeviceState.ambiguous);

  bool get deviceProbeBlocksCurrentAction =>
      deviceProbeControlAvailable &&
      !deviceProbeReady &&
      actionId != 'make_zip3' &&
      actionId != 'file_info';

  String get deviceProbeActionLabel => switch (_deviceStatus?.state) {
    HardwareDeviceState.disconnected => 'Connect ST-Link',
    HardwareDeviceState.ambiguous when _androidMode => 'Use one ST-Link',
    HardwareDeviceState.unsupported =>
      _androidMode ? 'USB host unavailable' : 'WebUSB unavailable',
    HardwareDeviceState.ready => 'Continue',
    _ => 'Connect ST-Link',
  };

  bool get deviceProbeSelectable =>
      deviceProbeControlAvailable &&
      !running &&
      _deviceStatus?.state != HardwareDeviceState.unsupported;

  String get backendStatusLabel {
    if (!deviceProbeControlAvailable) return backendStatus;
    final status = _deviceStatus;
    return switch (status?.state) {
      HardwareDeviceState.ready => status?.productName ?? 'ST-Link ready',
      HardwareDeviceState.selectionRequired =>
        _androidMode ? 'USB permission required' : 'Select ST-Link',
      HardwareDeviceState.disconnected => 'Disconnected — reconnect',
      HardwareDeviceState.ambiguous =>
        _androidMode ? 'Disconnect extra ST-Links' : 'Choose ST-Link',
      HardwareDeviceState.unsupported =>
        _androidMode ? 'USB host unsupported' : 'WebUSB unsupported',
      null => 'Checking…',
    };
  }

  Future<bool> selectDeviceProbe() async {
    final backend = _backend;
    if (!deviceProbeSelectable) return false;
    if (backend is! HardwareDeviceBackend) return false;
    final deviceBackend = backend as HardwareDeviceBackend;
    try {
      final status = await deviceBackend.selectDevice();
      _applyDeviceStatus(status);
      _log(
        '== USB probe selected: '
        '${status.productName ?? 'ST-Link'} ==',
      );
      return status.ready;
    } on HardwareException catch (error) {
      if (error.kind == HardwareFailureKind.userCancelled) {
        _log('== USB probe selection cancelled ==');
        return false;
      }
      _log('== USB probe selection failed: ${error.message} ==');
      notifyListeners();
      return false;
    } catch (error) {
      _log('== USB probe selection failed: $error ==');
      return false;
    }
  }

  bool _realRun = false;
  String? _diagnosis; // a specific cause parsed from OpenOCD output this run
  // No firmware action remembers a bin. The selection is cleared on every
  // action switch AND on every scope change, so a full image can never stay
  // armed under slot-0 rules (or the reverse) after the operator moved on.
  String? _firmwareSelected;
  String? _firmwareSelectedDigest;
  Uint8List? _firmwareSelectedBytes;
  // One-line identity/claim note shown under the loaded filename (zip3
  // "Package says …" or the bin's own "Firmware says …"); warn = amber.
  String? _firmwareNote;
  bool _firmwareNoteWarn = false;
  FirmwareInspection? _firmwareInspection;
  FlashScope flashScope = FlashScope.fullImage;

  // ── ZIP3 tools (offline slice / pack / unpack) form state ──────────────────
  // Slice keeps the guarded X3 VCU/MCU full-dump workflow. Pack is the generic
  // payload-to-package path and also supports the BMS/BLE component types found
  // in the firmware corpus. Flash ZIP import remains independently restricted
  // to VCU/MCU.
  static const List<String> zip3SliceTypes = ['VCU', 'MCU'];
  static const List<String> zip3PackTypes = ['VCU', 'MCU', 'BMS', 'BLE'];
  static const List<String> zip3Models = ['zt3', 'g3', 'gt3', 'f3'];
  String? zip3Type; // null = operator has not chosen
  String?
  zip3Model; // 'zt3' | 'g3' | 'gt3' | 'f3' (null = operator hasn't chosen)
  // Legacy zip3 is the default because it is what the BLE app in the field
  // reads: SHU 4.1 rejects zip3.2 outright ("Unsupported schema version: 2"),
  // and 3.x never knew it. Revisit when a release that accepts it is out.
  Zip3Format zip3Format = Zip3Format.legacy;
  bool zip3EnforceModel = true; // legacy info.json enforceModel checkbox
  String zip3Name = ''; // editable displayName; blank → defaultZip3Name

  List<String> get zip3TypeOptions =>
      zip3WorkspacePage == Zip3WorkspacePage.pack
      ? zip3PackTypes
      : zip3SliceTypes;

  // Standalone ZIP3 unpack state. Selection validates and recovers in memory
  // for the details preview; Start re-reads and re-validates the source before
  // writing the requested local .bin.
  String? _unpackZip3Path;
  String? _unpackZip3Digest;
  UnpackedV3? _unpackZip3Package;
  String unpackOutputName = '';

  String? get unpackZip3Path => _unpackZip3Path;
  String? get unpackZip3FileName =>
      _unpackZip3Path?.split(RegExp(r'[\\/]')).last;
  String? get unpackDisplayName => _unpackZip3Package?.displayName;
  String? get unpackModel => _unpackZip3Package?.model;
  String? get unpackType => _unpackZip3Package?.type;
  int? get unpackPayloadLength => _unpackZip3Package?.firmware.length;
  bool? get unpackEnforceModel => _unpackZip3Package?.enforceModel;
  String? get unpackEncryption => _unpackZip3Package?.encryption;
  String? get unpackFormatLabel => _unpackZip3Package?.formatLabel;
  String? get unpackProtectionLabel => _unpackZip3Package?.protectionLabel;

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

  void setZip3Format(Zip3Format format) {
    if (running || zip3Format == format) return;
    zip3Format = format;
    final path = firmwarePath;
    if (path != null && zip3WorkspacePage == Zip3WorkspacePage.pack) {
      try {
        PackV3.validatePayloadForPack(
          File(path).readAsBytesSync(),
          format: format,
        );
      } on FormatException catch (e) {
        setFirmware(null);
        _log('== source cleared for ${format.label}: ${e.message} ==');
        return;
      }
    }
    notifyListeners();
  }

  // No notify: the name field is owned by the form's TextEditingController, so
  // rebuilding on each keystroke would fight the cursor. External resets (dump
  // reload / action switch) DO notify, and the form re-syncs from zip3Name then.
  void setZip3Name(String v) => zip3Name = v;

  /// The package name Start uses when the name field is blank — also the hint
  /// the form shows, so the two can never disagree. A raw Pack source inherits
  /// its filename (same shape as the Unpack suggestion, keeping round-trip
  /// lineage readable); a Slice dump gets the timestamp default. Null until
  /// both dropdowns are chosen.
  String? get zip3DefaultName {
    final type = zip3Type;
    final model = zip3Model;
    if (type == null || model == null) return null;
    final src = firmwarePath;
    if (zip3WorkspacePage == Zip3WorkspacePage.pack && src != null) {
      return Firmware.defaultZip3NameForPayload(
        model: model,
        type: type,
        sourceFilename: src.split(RegExp(r'[\\/]')).last,
      );
    }
    return Firmware.defaultZip3Name(model: model, type: type);
  }

  void setUnpackOutputName(String v) {
    unpackOutputName = v;
    notifyListeners();
  }

  void _resetZip3Form() {
    zip3Type = null;
    zip3Model = null;
    zip3EnforceModel = true;
    zip3Format = Zip3Format.legacy;
    zip3Name = '';
    _unpackZip3Path = null;
    _unpackZip3Digest = null;
    _unpackZip3Package = null;
    unpackOutputName = '';
  }

  // ── SHU-compat: also pack a BLE zip3 of the patched image ───────────────────
  // Opt-in checkbox under the "Make SHU compatible" action. When on and the
  // compat flash succeeds, the patched image is repackaged as a BLE-loadable
  // zip3. A VCU model is read from its banner; an MCU carries no model of its
  // own, so it packs with the model the operator declared during identification.
  // Best-effort: a packaging hiccup never demotes the compat flash success.
  // Off by default and transient (reset on every action switch).
  //
  // Two formats, independently selectable, because two generations of the BLE
  // app are in the field: 3.x reads only legacy zip3 (schemaVersion 1), and
  // 4.x is expected to read both. Emitting both is a checkbox and two files;
  // handing someone the one format their app refuses is a dead end at the
  // moment they need it.
  bool compatMakeZip3 = false; // legacy zip3, NinebotTEA
  bool compatMakeZip32 = false; // zip3.2, plaintext + MD5
  Zip3WorkspacePage zip3WorkspacePage = Zip3WorkspacePage.slice;

  void setCompatMakeZip3(bool v) {
    if (running) return;
    compatMakeZip3 = v;
    notifyListeners();
  }

  void setCompatMakeZip32(bool v) {
    if (running) return;
    compatMakeZip32 = v;
    notifyListeners();
  }

  void setZip3WorkspacePage(Zip3WorkspacePage page) {
    if (running || zip3WorkspacePage == page) return;
    zip3WorkspacePage = page;
    // Slice and Pack interpret a .bin differently and have different component
    // choices. Their shared form is transient across every page change, while
    // the independent Unpack selection/details remain untouched.
    zip3Type = null;
    zip3Model = null;
    zip3Name = '';
    setFirmware(null);
  }

  /// The two firmware flash actions carry the Full image / Slot 0 scope
  /// control. They differ in their guards — Backup + Flash backs up and
  /// enforces identity, Flash Only does neither — not in what they can write.
  bool get hasFlashScope {
    if (actionId != 'flash_backup' && actionId != 'flash_only') return false;
    final capabilities = _backend?.capabilities;
    return capabilities == null ||
        (capabilities.flashFull && capabilities.flashSlot0);
  }

  /// Retired `flash_slot0` is slot-scoped by definition; it has no control of
  /// its own, so it answers here rather than through [flashScope].
  bool get isSlotAction =>
      actionId == 'flash_slot0' ||
      (hasFlashScope && flashScope == FlashScope.slot0);

  String? get firmwarePath => _firmwareSelected;
  Uint8List? get firmwareBytes => _firmwareSelectedBytes;
  String? get _firmwareDigest => _firmwareSelectedDigest;
  String? get firmwareNote => _firmwareNote;
  bool get firmwareNoteWarn => _firmwareNoteWarn;
  FirmwareInspection? get firmwareInspection => _firmwareInspection;

  /// Whether the primary CTA is ready to fire for the current action. Firmware
  /// actions need a loaded file; Make zip3 additionally needs both dropdowns
  /// chosen (an MCU dump can't preselect its model).
  bool get canStart {
    if (actionId == 'make_zip3' &&
        zip3WorkspacePage == Zip3WorkspacePage.unpack) {
      return _unpackZip3Path != null &&
          _unpackZip3Package != null &&
          Firmware.validateUnpackedFilename(unpackOutputName).ok;
    }
    if (!_backendSupportsCurrentAction) return false;
    if (deviceProbeControlAvailable &&
        actionId != 'make_zip3' &&
        !deviceProbeReady) {
      return false;
    }
    if (action.needsFirmware && firmwarePath == null) return false;
    if (actionId == 'make_zip3' && (zip3Type == null || zip3Model == null)) {
      return false;
    }
    return true;
  }

  bool get _backendSupportsCurrentAction => isActionAvailable(actionId);

  bool isActionAvailable(String id) {
    // The phone tier deliberately exposes only the workflows selected for a
    // direct ST-Link transport. Keep every other desktop/advanced action
    // fail-closed even when the backend has lower-level capability for it.
    // Tier, not platform: the mobile web build gets the same reduced set.
    if (_phoneMode &&
        !const {
          'check',
          'dump',
          'flash_backup',
          'flash_compat',
          'flash_only',
          'rdp_check',
        }.contains(id)) {
      return false;
    }
    if (id == 'make_zip3') return !_browserMode;
    if (id == 'file_info') return true;
    if (id == 'rdp_rescue' && _browserMode) return false;
    if (id == 'rdp_rescue' && _backend == null) return !_androidMode;
    final capabilities = _backend?.capabilities;
    // Preserve the existing missing-OpenOCD CTA: dispatch owns that explicit
    // diagnostic. Capability gating applies once a backend is present.
    if (capabilities == null) return true;
    bool supports(HardwareOperation operation) =>
        capabilities.supports(operation, mode);
    return switch (id) {
      'check' => supports(HardwareOperation.check),
      'dump' => supports(HardwareOperation.dump),
      'flash_only' => supports(
        isSlotAction
            ? HardwareOperation.flashSlot0
            : HardwareOperation.flashFull,
      ),
      'flash_backup' =>
        supports(HardwareOperation.dump) &&
            supports(
              isSlotAction
                  ? HardwareOperation.flashSlot0
                  : HardwareOperation.flashFull,
            ),
      'flash_slot0' =>
        supports(HardwareOperation.dump) &&
            supports(HardwareOperation.flashSlot0),
      'flash_compat' =>
        supports(HardwareOperation.dump) &&
            supports(HardwareOperation.flashFull),
      'rdp_check' => capabilities.supportsProtection(
        HardwareProtectionOperation.check,
        mode,
      ),
      'rdp_rescue' => capabilities.supportsProtection(
        HardwareProtectionOperation.rescue,
        mode,
      ),
      _ => false,
    };
  }

  List<ConnectionMode> get availableModes {
    if (_phoneMode) {
      final modes = _backend?.capabilities.connectionModes;
      return [
        ConnectionMode.defaultSwd,
        if (modes?.contains(ConnectionMode.powerRace) ?? false)
          ConnectionMode.powerRace,
        if (modes?.contains(ConnectionMode.cloneC45) ?? false)
          ConnectionMode.cloneC45,
        if (kAndroidEnableGenuineC45ForTesting &&
            (modes?.contains(ConnectionMode.genuineC45) ?? false))
          ConnectionMode.genuineC45,
      ];
    }
    final modes = _backend?.capabilities.connectionModes;
    return ConnectionMode.values
        .where((mode) => modes == null || modes.contains(mode))
        .toList(growable: false);
  }

  bool get hasAdvancedOptions =>
      modesIn(Section.advanced).isNotEmpty ||
      kActions.any(
        (action) =>
            action.section == Section.advanced &&
            !action.hidden &&
            isActionAvailable(action.id),
      );

  /// Inspect a ZIP3 for standalone unpack. No output is written here: the
  /// package details and default filename are only armed after container,
  /// cryptographic, metadata, banner, and slot-size validation all pass.
  Future<FirmwareCheck> selectZip3ForUnpack(String path) async {
    if (running ||
        actionId != 'make_zip3' ||
        zip3WorkspacePage != Zip3WorkspacePage.unpack) {
      return FirmwareCheck.fail('Standalone ZIP3 unpack is not active.');
    }
    _unpackZip3Path = null;
    _unpackZip3Digest = null;
    _unpackZip3Package = null;
    unpackOutputName = '';
    notifyListeners();

    final containerCheck = Firmware.validateZip3Container(
      path,
      enforceFlashSizeLimit: false,
    );
    if (!containerCheck.ok) return containerCheck;
    try {
      final bytes = await File(path).readAsBytes();
      final pkg = PackV3.unpackV3(bytes, policy: Zip3UnpackPolicy.extract);
      _unpackZip3Path = path;
      _unpackZip3Digest = crypto.sha256.convert(bytes).toString();
      _unpackZip3Package = pkg;
      unpackOutputName = Firmware.defaultUnpackedFilename(
        model: pkg.model,
        type: pkg.type,
        sourceFilename: path.split(RegExp(r'[\\/]')).last,
      );
      _log(
        '== zip3 inspected: ${pkg.displayName} · ${pkg.model}/${pkg.type} · '
        '${pkg.firmware.length} bytes ==',
      );
      notifyListeners();
      return FirmwareCheck(
        true,
        'Ready to unpack ${pkg.formatLabel} package ${pkg.displayName} '
        '(${pkg.model.toUpperCase()} ${pkg.type.toUpperCase()}).',
      );
    } on FormatException catch (e) {
      return FirmwareCheck.fail(e.message);
    } catch (e) {
      return FirmwareCheck.fail('Could not read package: $e');
    }
  }

  /// The header owns the stable action explanation. While idle, the hero shows
  /// only the next live state; running/result stages keep their orchestration
  /// title and message unchanged.
  // Invariant: non-idle stages fall back to the mutable title/sub, seeded with action.name/action.sub in _goIdle — every non-idle transition must go through _set() so the hero never re-echoes the header description.
  String get heroTitle {
    if (stage != StageState.idle) return title;
    if (deviceProbeBlocksCurrentAction) return deviceProbeActionLabel;
    if (action.needsFirmware && firmwarePath == null) {
      if (actionId == 'make_zip3') {
        return zip3WorkspacePage == Zip3WorkspacePage.slice
            ? 'Choose a backup dump'
            : 'Choose a firmware payload';
      }
      if (actionId == 'file_info') return 'Choose a file';
      return 'Choose firmware';
    }
    if (actionId == 'make_zip3' && (zip3Type == null || zip3Model == null)) {
      return 'Complete package identity';
    }
    return 'Ready to start';
  }

  String get heroMessage {
    if (stage != StageState.idle) return sub;
    if (deviceProbeBlocksCurrentAction) {
      return switch (_deviceStatus?.state) {
        HardwareDeviceState.disconnected =>
          'Reconnect the selected ST-Link, or choose it again to continue.',
        HardwareDeviceState.ambiguous when _androidMode =>
          'Multiple supported ST-Links are connected. Leave one attached and try again.',
        HardwareDeviceState.unsupported =>
          _androidMode
              ? 'This phone does not provide the USB-host access x3utils requires.'
              : 'This browser does not provide the WebUSB access x3utils requires.',
        _ =>
          _androidMode
              ? 'Android USB permission is required before Check can start.'
              : 'Browser permission is required before hardware actions can start.',
      };
    }
    if (action.needsFirmware && firmwarePath == null) {
      if (actionId == 'make_zip3') {
        if (zip3WorkspacePage == Zip3WorkspacePage.slice) {
          return 'Choose a full 128 KB backup .bin below.';
        }
        return 'Choose the complete firmware .bin to package below.';
      }
      if (actionId == 'file_info') {
        return 'Choose any firmware .bin or zip3 package below — nothing is '
            'written and nothing is checked for flashing.';
      }
      if (isSlotAction) {
        return 'Choose a slot-sized .bin or zip3 package below.';
      }
      return 'Choose a full 128 KB firmware .bin below.';
    }
    if (actionId == 'make_zip3' && (zip3Type == null || zip3Model == null)) {
      return _firmwareNote ?? 'Choose both Type and Model below.';
    }
    if (actionId == 'file_info') {
      return 'File selected. Show its report when ready.';
    }
    if (action.needsFirmware) {
      return _firmwareNote ?? 'Firmware selected. Start when ready.';
    }
    return '${mode.title} selected. Start when ready.';
  }

  bool get heroMessageWarn =>
      stage == StageState.idle && _firmwareNote != null && _firmwareNoteWarn;

  /// Idle eyebrow (Lens 1 — stakes): what the action does to the device, so the
  /// consequence sits right above the button. Label + colour travel together.
  ({String label, Color color}) get _stakes {
    switch (actionId) {
      case 'flash_only':
        if (firmwarePath != null) {
          return (label: 'Compatibility warning', color: AppColors.hold);
        }
        return (label: 'Writes flash', color: AppColors.hold);
      case 'flash_backup':
        return (label: 'Writes flash', color: AppColors.hold);
      case 'flash_slot0': // retired, hidden
        return (label: 'Slot 0 only', color: AppColors.ok);
      case 'flash_compat':
        return (label: 'Writes flash', color: AppColors.hold);
      case 'rdp_rescue':
        return (label: 'Erases flash', color: AppColors.danger);
      case 'make_zip3':
        return (label: 'Offline', color: AppColors.ok);
      default: // check, dump, rdp_check
        return (label: 'Read-only', color: AppColors.ok);
    }
  }

  /// Idle-eyebrow tint (view uses this only while idle; other stages keep the
  /// stage accent).
  Color get stakesColor =>
      deviceProbeBlocksCurrentAction ? AppColors.hold : _stakes.color;

  /// The eyebrow to display. Idle → stakes; a live run → an elapsed clock; a
  /// finished run → the outcome fact. Anything that wasn't actually timed
  /// (offline pack, RDP, input failures, guided steps, race attempts, verdicts)
  /// falls back to the stored [eyebrow], so we never invent a duration/exit.
  String get heroEyebrow {
    switch (stage) {
      case StageState.idle:
        if (deviceProbeBlocksCurrentAction) return 'ST-Link required';
        return _stakes.label;
      case StageState.run:
        return _runStartedAt != null
            ? _fmtDuration(DateTime.now().difference(_runStartedAt!))
            : eyebrow;
      case StageState.ok:
        return _lastRunDuration != null
            ? 'Took ${_fmtDuration(_lastRunDuration!)}'
            : eyebrow;
      case StageState.fail:
        // Only surface a non-zero exit — "Exit 0" on a judged failure misleads.
        return (_lastExitCode != null &&
                _lastExitCode != 0 &&
                _lastRunDuration != null)
            ? 'Exit $_lastExitCode · ${_fmtDuration(_lastRunDuration!)}'
            : eyebrow;
      default: // hold / count / release / connect / warn keep their step/phase
        return eyebrow;
    }
  }

  static String _fmtDuration(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  /// Start the run clock + live elapsed ticker. Called when a real process run
  /// begins; resets any prior outcome so a stale duration can't leak.
  void _startRunClock() {
    _runStartedAt = DateTime.now();
    _lastRunDuration = null;
    _lastExitCode = null;
    _elapsedTicker?.cancel();
    _elapsedTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (running) {
        notifyListeners();
      } else {
        _elapsedTicker?.cancel();
        _elapsedTicker = null;
      }
    });
  }

  /// Freeze the elapsed clock and record the outcome for the result eyebrow.
  void _stopRunClock(int? exitCode) {
    if (_runStartedAt != null) {
      _lastRunDuration = DateTime.now().difference(_runStartedAt!);
    }
    _lastExitCode = exitCode;
    _runStartedAt = null;
    _elapsedTicker?.cancel();
    _elapsedTicker = null;
  }

  @override
  void dispose() {
    _elapsedTicker?.cancel();
    _elapsedTicker = null;
    _cancelAutoRetry();
    super.dispose();
  }

  void setFirmware(
    String? path, {
    String? note,
    bool warn = false,
    FirmwareInspection? inspection,
  }) {
    final digest = path == null ? null : _digestFile(path);
    _firmwareSelected = path;
    _firmwareSelectedDigest = digest;
    _firmwareSelectedBytes = null;
    _firmwareNote = path == null ? null : note;
    _firmwareNoteWarn = path != null && warn;
    _firmwareInspection = path == null ? null : inspection;
    notifyListeners();
  }

  void setFirmwareRawBytes(String fileName, Uint8List bytes) {
    _firmwareSelected = fileName;
    _firmwareSelectedBytes = Uint8List.fromList(bytes);
    _firmwareSelectedDigest = crypto.sha256.convert(bytes).toString();
    _firmwareNote = null;
    _firmwareNoteWarn = false;
    _firmwareInspection = null;
    notifyListeners();
  }

  /// Validate and retain firmware selected by a memory-backed platform without
  /// relying on a native filesystem path.
  FirmwareCheck selectFirmwareBytes(String fileName, Uint8List bytes) {
    if (!_browserMode && !_androidMode) {
      return FirmwareCheck.fail(
        'In-memory firmware selection is not available on desktop.',
      );
    }
    final slot0 = isSlotAction;
    final enforceBanner = actionId != 'flash_only';
    if (!fileName.toLowerCase().endsWith('.bin')) {
      _clearFirmwareSelection();
      notifyListeners();
      return FirmwareCheck.fail('Invalid file type. Only .bin is allowed.');
    }
    final structural = slot0
        ? Firmware.validateSlotBytes(bytes)
        : Firmware.validateFullImageBytes(bytes);
    if (!structural.ok) {
      _clearFirmwareSelection();
      notifyListeners();
      return structural;
    }
    final identity = DeviceSpec.checkIncomingBin(
      bytes,
      slotBin: slot0,
      enforceBanner: enforceBanner,
    );
    if (!identity.ok) {
      _clearFirmwareSelection();
      notifyListeners();
      return identity;
    }
    final retained = Uint8List.fromList(bytes);
    final inspection = FirmwareInspector.inspect(retained, slotBin: slot0);
    final summary = inspection.identity.summary;
    _firmwareSelected = fileName;
    _firmwareSelectedBytes = retained;
    _firmwareSelectedDigest = crypto.sha256.convert(retained).toString();
    _firmwareNote = summary == null ? null : 'Firmware says: $summary';
    _firmwareNoteWarn = enforceBanner ? inspection.identity.warn : false;
    _firmwareInspection = inspection;
    notifyListeners();
    return FirmwareCheck.valid;
  }

  void _clearFirmwareSelection() {
    _firmwareSelected = null;
    _firmwareSelectedDigest = null;
    _firmwareSelectedBytes = null;
    _firmwareNote = null;
    _firmwareNoteWarn = false;
    _firmwareInspection = null;
  }

  String? _digestFile(String path) {
    try {
      return crypto.sha256.convert(File(path).readAsBytesSync()).toString();
    } catch (_) {
      return null;
    }
  }

  FirmwareCheck _validateFirmwareFile(
    String path, {
    required bool slot0,
    required bool enforceBanner,
  }) {
    final structural = slot0
        ? Firmware.validateSlot(path)
        : Firmware.validate(path, requireSize: true);
    if (!structural.ok || !enforceBanner) return structural;
    try {
      return DeviceSpec.checkIncomingBin(
        File(path).readAsBytesSync(),
        slotBin: slot0,
        enforceBanner: true,
      );
    } catch (e) {
      return FirmwareCheck.fail('Could not read the firmware file: $e');
    }
  }

  /// Validate + remember a picked `.bin` for the current action. Structural
  /// checks first (size/path/content), then the mainstream-only banner gate —
  /// Backup + Flash refuses a bin with no readable SCOOTER banner in either
  /// scope (Flash Only stays permissive: crafted/unrecognized images are its
  /// job).
  /// On success the bin's readable identity (banner model/type + serial state)
  /// becomes the firmware-bar note; generic/cleared serials show amber.
  FirmwareCheck selectFirmwareBin(String path) {
    final makeZip3 = actionId == 'make_zip3';
    final sliceZip3 = makeZip3 && zip3WorkspacePage == Zip3WorkspacePage.slice;
    if (makeZip3 && zip3WorkspacePage == Zip3WorkspacePage.unpack) {
      return FirmwareCheck.fail(
        'Choose Slice or Pack before selecting a .bin.',
      );
    }
    final FirmwareCheck check;
    if (sliceZip3) {
      check = Firmware.validateLocalBin(path, requireSize: true);
    } else if (makeZip3) {
      // Pack treats the selected .bin as the complete component payload.
      // Component formats and sizes differ (especially BMS/BLE), so it applies
      // only the common local-bin structural checks here. Neither ZIP3 source
      // path reaches OpenOCD, so Tcl/Windows argv restrictions do not apply.
      check = Firmware.validateLocalBin(path, requireSize: false);
    } else {
      check = _validateFirmwareFile(
        path,
        slot0: isSlotAction,
        enforceBanner: actionId != 'flash_only' && !makeZip3,
      );
    }
    if (!check.ok) {
      // A rejected pick leaves no confirmed-good selection for this kind —
      // clear it so Start doesn't stay lit on a stale/invalid file.
      setFirmware(null);
      return check;
    }
    final bytes = File(path).readAsBytesSync();
    if (makeZip3 && !sliceZip3) {
      try {
        PackV3.validatePayloadForPack(bytes, format: zip3Format);
      } on FormatException catch (e) {
        setFirmware(null);
        return FirmwareCheck.fail(e.message);
      }
    }
    if (makeZip3) {
      // Preselect the dropdowns from the banner (a suggestion only — type
      // reliably, VCU model from its code; MCU/unknown leaves the model empty
      // for the operator). A fresh pick gets a fresh default name.
      final d = PackV3.detect(
        bytes,
        slotBin: zip3WorkspacePage == Zip3WorkspacePage.pack,
      );
      zip3Type = d.type;
      zip3Model = d.model;
      zip3Name = '';
    }
    final inspection = FirmwareInspector.inspect(
      bytes,
      slotBin: makeZip3 && zip3WorkspacePage == Zip3WorkspacePage.pack
          ? true
          : isSlotAction,
    );
    final id = inspection.identity;
    // ZIP3 tools use any readable banner only as an optional preselection hint.
    final summary = makeZip3 ? id.bannerSummary : id.summary;
    if (makeZip3) _log('== source identity: ${id.logLine} ==');
    setFirmware(
      path,
      note: summary == null ? null : 'Firmware says: $summary',
      // Flash Only uses the persistent eyebrow + confirmation modal for its
      // findings. Guarded identity notes keep their existing amber
      // presentation; the packer has nothing amber left to show.
      warn: actionId == 'flash_only' || makeZip3 ? false : id.warn,
      inspection: inspection,
    );
    return FirmwareCheck.valid;
  }

  /// Re-read a selected Flash Only source immediately before its confirmation
  /// modal. Flash Only deliberately does not enforce the stored digest, but
  /// the evidence shown to the operator must describe the bytes about to be
  /// written rather than a stale selection-time snapshot.
  FirmwareCheck refreshFlashOnlyInspection() {
    if (actionId != 'flash_only') return FirmwareCheck.valid;
    final path = firmwarePath;
    if (path == null) {
      return FirmwareCheck.fail('No firmware file selected.');
    }
    final List<int> raw;
    if (_browserMode || _androidMode) {
      final retained = _firmwareSelectedBytes;
      if (retained == null) {
        return FirmwareCheck.fail('No firmware bytes available.');
      }
      final snapshot = Uint8List.fromList(retained);
      final structural = isSlotAction
          ? Firmware.validateSlotBytes(snapshot)
          : Firmware.validateFullImageBytes(snapshot);
      if (!structural.ok) return structural;
      raw = retained;
    } else {
      final check = _validateFirmwareFile(
        path,
        slot0: isSlotAction,
        enforceBanner: false,
      );
      if (!check.ok) return check;
      try {
        raw = File(path).readAsBytesSync();
      } catch (e) {
        return FirmwareCheck.fail('Could not read the firmware file: $e');
      }
    }
    try {
      final packageClaim = _firmwareInspection?.packageClaim;
      final inspection = FirmwareInspector.inspect(
        raw,
        slotBin: isSlotAction,
        packageClaim: packageClaim,
      );
      _firmwareInspection = inspection;
      final summary = inspection.identity.summary;
      _firmwareNote = packageClaim == null
          ? (summary == null ? null : 'Firmware says: $summary')
          : 'Package says: ${packageClaim.label}';
      _firmwareNoteWarn = false;
      notifyListeners();
      return FirmwareCheck.valid;
    } catch (e) {
      return FirmwareCheck.fail('Could not inspect the firmware file: $e');
    }
  }

  /// Switch the write scope. The selected bin is dropped with it: a full image
  /// and a slot payload are different files, so carrying one across the change
  /// could only leave a wrong-sized selection armed.
  void setFlashScope(FlashScope scope) {
    if (running || !hasFlashScope || flashScope == scope) return;
    flashScope = scope;
    _firmwareSelected = null;
    _firmwareSelectedDigest = null;
    _firmwareSelectedBytes = null;
    _firmwareNote = null;
    _firmwareNoteWarn = false;
    _firmwareInspection = null;
    _goIdle();
  }

  /// Load a v3 firmware .zip for the current (slot-0) flash: validate the
  /// package, recover its plaintext payload, validate it in memory, write it to
  /// a temp .bin, and remember it. Returns a
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
          'zip3 and zip3.2 packages are available for Slot 0 only.',
        );
      }
      final containerCheck = Firmware.validateZip3Container(zipPath);
      if (!containerCheck.ok) {
        ilog('== package rejected: ${containerCheck.message} ==');
        return containerCheck;
      }
      final bytes = await File(zipPath).readAsBytes();
      final pkg = PackV3.unpackV3(bytes);
      ilog(
        '== package says: ${pkg.displayName} · ${pkg.model}/${pkg.type} · '
        '${pkg.source} · ${pkg.firmware.length} bytes ==',
      );
      final v = Firmware.validateSlotBytes(pkg.firmware);
      if (!v.ok) {
        ilog('== package firmware rejected: ${v.message} ==');
        return FirmwareCheck.fail(v.message);
      }
      final outPath = Firmware.newUnpackedBinPath(
        prefix: backupPrefix,
        name: pkg.displayName,
      );
      await File(outPath).writeAsBytes(pkg.firmware);
      final claim = PackageClaim(
        model: pkg.model,
        type: pkg.type,
        displayName: pkg.displayName,
      );
      final inspection = FirmwareInspector.inspect(
        pkg.firmware,
        slotBin: true,
        packageClaim: claim,
      );
      final packageClaim =
          'Package says: ${pkg.model.toUpperCase()} · ${pkg.type.toUpperCase()}';
      setFirmware(outPath, note: packageClaim, inspection: inspection);
      ilog('== loaded slot-0 firmware from package → $outPath ==');
      return FirmwareCheck(
        true,
        'Loaded ${pkg.formatLabel} package ${pkg.displayName}: '
        '${pkg.firmware.length} bytes. '
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

  FirmwareCheck loadSlotFirmwareFromZipBytes(String fileName, Uint8List bytes) {
    setFirmware(null);
    _log(
      '== zip3 import: $fileName · '
      '${DateTime.now().toString().split('.').first} ==',
    );
    try {
      if (!isSlotAction) {
        return FirmwareCheck.fail(
          'zip3 and zip3.2 packages are available for Slot 0 only.',
        );
      }
      if (!fileName.toLowerCase().endsWith('.zip')) {
        return FirmwareCheck.fail('Invalid file type. Only .zip is allowed.');
      }
      if (Firmware.enforceSlotSizeHeuristics &&
          bytes.length > Firmware.maxZip3Bytes) {
        return FirmwareCheck.fail(
          'ZIP is too large (${bytes.length} bytes). Slot-0 zip3/zip3.2 '
          'packages must be ${Firmware.maxZip3Bytes} bytes or smaller.',
        );
      }
      final pkg = PackV3.unpackV3(bytes);
      _log(
        '== package says: ${pkg.displayName} · ${pkg.model}/${pkg.type} · '
        '${pkg.source} · ${pkg.firmware.length} bytes ==',
      );
      final v = Firmware.validateSlotBytes(pkg.firmware);
      if (!v.ok) {
        _log('== package firmware rejected: ${v.message} ==');
        return FirmwareCheck.fail(v.message);
      }
      final claim = PackageClaim(
        model: pkg.model,
        type: pkg.type,
        displayName: pkg.displayName,
      );
      final inspection = FirmwareInspector.inspect(
        pkg.firmware,
        slotBin: true,
        packageClaim: claim,
      );
      final packageClaim =
          'Package says: ${pkg.model.toUpperCase()} · ${pkg.type.toUpperCase()}';
      setFirmwareRawBytes(fileName, Uint8List.fromList(pkg.firmware));
      _firmwareNote = packageClaim;
      _firmwareInspection = inspection;
      notifyListeners();
      _log('== loaded slot-0 firmware from package (in-memory) ==');
      return FirmwareCheck(
        true,
        'Loaded ${pkg.formatLabel} package ${pkg.displayName}: '
        '${pkg.firmware.length} bytes. '
        '$packageClaim.',
      );
    } on FormatException catch (e) {
      _log('== package error: ${e.message} ==');
      return FirmwareCheck.fail(e.message);
    } catch (e) {
      _log('== package error: $e ==');
      return FirmwareCheck.fail('Could not read package: $e');
    }
  }

  // STARTUP DEFAULTS (persisted, set only from Settings). Default to Mode A
  // (plain SWD). _loadPrefs seeds the live session values below from these; the
  // rail changes the session only.
  ConnectionMode defaultMode = ConnectionMode.defaultSwd;
  int defaultCountdown = 3;
  int defaultAutoRetry = 3; // seconds between automatic retries; 0 = off

  // Live session values (seeded from the defaults on launch; the rail overrides
  // these WITHOUT touching the persisted defaults).
  ConnectionMode mode = ConnectionMode.defaultSwd;
  String actionId = 'check';
  int countdownSeconds = 3;
  int autoRetrySeconds = 3;
  bool running = false;
  int raceAttempts =
      0; // power-race respawn: attempts so far (drives the indicator)
  HardwareRaceTier raceTier = HardwareRaceTier.searching;

  StageState stage = StageState.idle;
  String eyebrow = 'Ready';
  // Eyebrow telemetry (Lens 3): only set when a real process was timed, so the
  // outcome eyebrow never fabricates a duration/exit for an untimed stage.
  DateTime? _runStartedAt;
  Duration? _lastRunDuration;
  int? _lastExitCode;
  Timer? _elapsedTicker;
  String title = 'Check connection';
  String sub = 'Pick a connection mode and an action, then hit start.';
  MessageTone messageTone = MessageTone.normal;
  String? resultPath;
  String? resultNote;
  String? resultMetadataPath;
  bool _failureNeedsInput = false;
  bool _failureIsFinding = false; // a chip verdict, not a rejected input
  bool _rdpRetryPending = false;
  HardwareFailureKind? _hardwareFailureKind;

  /// A validation or policy failure must return to setup instead of repeating
  /// the same run. Connection failures retain the existing re-seat retry loop.
  bool get failureNeedsInput => stage == StageState.fail && _failureNeedsInput;

  // ── Auto-retry: the third hand ────────────────────────────────────────────
  // The top real-world failure is a lost SWD / C45 contact, and the operator
  // who has to fix it has both hands on the probe. Rather than making them let
  // go to click Retry, press it for them. Nothing else is special-cased: the
  // automatic press runs the same retry() the button runs.
  static const int kAutoRetryMaxAttempts = 10;
  Timer? _autoRetryTimer;
  int autoRetryCountdown = 0; // seconds left before the next automatic press
  int autoRetryAttempt = 0; // automatic presses used since the last fresh run
  bool _sawTargetProgress = false; // this run reached target/operation progress
  bool _cannotRun = false; // never launched (missing OpenOCD / unwired action)

  /// Set when the backend identified a chip package nobody has run on hardware.
  ///
  /// Advisory only. Writes are gated on GEOMETRY — any 128 KiB AT32F415 with
  /// 1024 B pages programs — so an unmeasured package is a thing the operator
  /// is told about, not stopped by. Null when the part is the tested one, or
  /// when the backend cannot name a part at all (OpenOCD).
  String? untestedTargetWarning;

  bool get autoRetryArmed => _autoRetryTimer != null;

  String get autoRetryLabel =>
      'Retrying in $autoRetryCountdown…  '
      '(${autoRetryAttempt + 1} of $kAutoRetryMaxAttempts)';

  /// Only a failure that never got past connect may repeat itself. A run that
  /// reached the core and failed later may have written flash, and re-running
  /// that unattended is not what a third hand would do.
  bool get _autoRetryEligible =>
      autoRetrySeconds > 0 &&
      stage == StageState.fail &&
      !_failureNeedsInput && // policy failure: needs the user, not a retry
      !_cannotRun && // a broken bundle is not a loose wire
      !_sawTargetProgress && // connected/progressed → never auto-repeat
      (_hardwareFailureKind == null ||
          _hardwareFailureKind == HardwareFailureKind.targetContact ||
          (!_browserMode &&
              _hardwareFailureKind == HardwareFailureKind.deviceUnavailable)) &&
      mode != ConnectionMode.powerRace && // has its own respawn loop
      actionId != 'rdp_check' && // stdin prompt, not a re-run (own pass)
      actionId != 'rdp_rescue' &&
      autoRetryAttempt < kAutoRetryMaxAttempts;

  void _armAutoRetry() {
    _autoRetryTimer?.cancel();
    autoRetryCountdown = autoRetrySeconds;
    _autoRetryTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      autoRetryCountdown--;
      if (autoRetryCountdown > 0) {
        notifyListeners();
        return;
      }
      _cancelAutoRetry();
      autoRetryAttempt++;
      _log('== auto-retry $autoRetryAttempt of $kAutoRetryMaxAttempts ==');
      retry(auto: true);
    });
  }

  void _cancelAutoRetry() {
    _autoRetryTimer?.cancel();
    _autoRetryTimer = null;
    autoRetryCountdown = 0;
  }

  String get failurePrimaryLabel {
    if (!failureNeedsInput) return 'Retry';
    if (failureNeedsDeviceProbe) return deviceProbeActionLabel;
    // A chip verdict is not a rejected input: there is nothing in setup to
    // change, and on a firmware action the selected .bin is not the problem
    // either. The button only clears the screen, so it says so.
    if (_failureIsFinding) return 'Dismiss';
    if (actionId == 'make_zip3') return 'Change input';
    if (action.needsFirmware) return 'Change firmware';
    return 'Back to setup';
  }

  bool get failureNeedsDeviceProbe {
    if (stage != StageState.fail || !deviceProbeControlAvailable) return false;
    return switch (_hardwareFailureKind) {
      HardwareFailureKind.permissionRequired ||
      HardwareFailureKind.deviceDisconnected ||
      HardwareFailureKind.deviceAmbiguous ||
      HardwareFailureKind.deviceUnavailable ||
      HardwareFailureKind.deviceBusy => true,
      _ => false,
    };
  }

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
  bool logToFile = false; // save each run's console to a log file; see _load
  final List<String> _runLog = <String>[];
  bool _capturing = false;

  int _token = 0;
  static const _minBusyVisible = Duration(milliseconds: 1000);
  static const _minAfterLastProgress = Duration(milliseconds: 1500);

  FlashAction get action => kActions.firstWhere((a) => a.id == actionId);

  void selectMode(ConnectionMode m) {
    if (running) return;
    mode = m; // session-only; does NOT change the persisted default
    _goIdle();
  }

  // ── Connection-mode rail sections (persisted, user-movable) ────────────────
  Section sectionOf(ConnectionMode m) =>
      _advancedModes.contains(m) ? Section.advanced : Section.standard;

  /// Modes in a rail section, always in canonical `kModeOrder`, so display
  /// order is independent of the persisted enum order.
  List<ConnectionMode> modesIn(Section s) =>
      availableModes.where((m) => sectionOf(m) == s).toList()..sort(
        (a, b) => kModeOrder.indexOf(a).compareTo(kModeOrder.indexOf(b)),
      );

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
    zip3WorkspacePage = Zip3WorkspacePage.slice;
    flashScope =
        FlashScope.fullImage; // scope is per action entry, never sticky
    _resetZip3Form(); // the packer form is transient, per action entry
    compatMakeZip3 = false; // the compat zip3 opt-ins are transient too
    compatMakeZip32 = false;
    _firmwareSelected = null; // no action remembers a loaded bin
    _firmwareSelectedDigest = null;
    _firmwareSelectedBytes = null;
    _firmwareNote = null;
    _firmwareNoteWarn = false;
    _firmwareInspection = null;
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

  /// Settings: seconds the failure screen waits before pressing Retry itself.
  /// 0 disables auto-retry entirely and restores the plain manual prompt.
  void setDefaultAutoRetry(int v) {
    defaultAutoRetry = v.clamp(0, 10);
    _prefs?.setInt('defaultAutoRetry', defaultAutoRetry);
    autoRetrySeconds = defaultAutoRetry;
    if (autoRetrySeconds == 0) _cancelAutoRetry();
    notifyListeners();
  }

  void continueStep() {
    if (!_realRun) return;
    _backend?.sendContinue(protection: actionId.startsWith('rdp'));
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
    _backend?.cancel();
    _log('-- cancelled --');
    lastConnect = '—';
    _goIdle();
  }

  /// Dismiss a completed (ok/fail) result back to idle — not a cancel.
  void dismiss() {
    if (_rdpRetryPending) {
      cancel();
      return;
    }
    if (running) return;
    _goIdle();
  }

  /// Re-run a connection failure, or return an input/policy failure to setup.
  /// The latter must never repeat a flash with the same rejected firmware.
  ///
  /// [auto] marks the press as coming from the auto-retry timer rather than the
  /// user. A real press is a fresh intent, so it restarts the attempt budget.
  Future<void> retry({bool auto = false}) async {
    _cancelAutoRetry();
    if (!auto) autoRetryAttempt = 0;
    if (_rdpRetryPending) {
      _rdpRetryPending = false;
      lastConnect = 'connecting…';
      _set(
        StageState.connect,
        'Protection',
        '${action.name}…',
        'Retrying the connection — watch the console.',
      );
      if (_backend?.sendContinue(protection: true) ?? false) return;

      _token++;
      _backend?.cancel();
      _realRun = false;
      running = false;
      _stopRunClock(null);
      lastConnect = 'FAIL';
      _set(
        StageState.fail,
        'Failed',
        '${action.name} failed',
        'The waiting protection process is no longer available. Press Retry to start again.',
      );
      return;
    }
    if (failureNeedsDeviceProbe) {
      if (deviceProbeReady || await selectDeviceProbe()) _goIdle();
      return;
    }
    if (failureNeedsInput) {
      _goIdle();
      return;
    }
    await start();
  }

  void _goIdle() {
    running = false;
    _elapsedTicker?.cancel();
    _elapsedTicker = null;
    _cancelAutoRetry();
    autoRetryAttempt = 0;
    _runStartedAt = null;
    resultPath = null;
    resultNote = null;
    resultMetadataPath = null;
    _failureNeedsInput = false;
    _failureIsFinding = false;
    _rdpRetryPending = false;
    _hardwareFailureKind = null;
    stage = StageState.idle;
    eyebrow = 'Ready';
    if (hasFlashScope) {
      final slot0 = flashScope == FlashScope.slot0;
      final backup = actionId == 'flash_backup';
      title = slot0 ? 'Choose slot-0 firmware' : 'Choose a full image';
      sub = switch ((slot0, backup)) {
        (true, true) =>
          'Backs up the chip first, then writes application slot 0 only. '
              'Bootloader and identity stay untouched.',
        (true, false) =>
          'Writes application slot 0 only. Bootloader and identity stay untouched.',
        (false, true) =>
          'Backs up the chip first, then writes and verifies the complete 128 KB image.',
        (false, false) =>
          'Writes the complete 128 KB image with no backup or target guard.',
      };
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
    // The red screen is the one place auto-retry arms from, so every failure
    // path gets it without any action knowing this feature exists.
    if (s == StageState.fail && _autoRetryEligible) {
      _armAutoRetry();
    } else {
      _cancelAutoRetry();
    }
    notifyListeners();
  }

  void _setInputFailure(String eb, String t, String sb) {
    _failureNeedsInput = true;
    _set(StageState.fail, eb, t, sb);
  }

  void _setInstruction(String value, {MessageTone tone = MessageTone.normal}) {
    if (sub == value && messageTone == tone) return;
    sub = value;
    messageTone = tone;
    notifyListeners();
  }

  /// One-line self-describing header for logs + clipboard (version/OS/mode/time).
  String contextHeader() {
    final os = _browserMode
        ? 'Web'
        : switch (Platform.operatingSystem) {
            'windows' => 'Windows',
            'macos' => 'macOS',
            'linux' => 'Linux',
            _ => Platform.operatingSystem,
          };
    return 'x3utils v$kAppVersionLabel · $os · ${mode.title} · '
        '${DateTime.now().toString().split('.').first}';
  }

  /// Kept on the controller rather than threaded through each call: [retry]
  /// re-enters [start] with no arguments, and a retried dump that fails again
  /// must still be able to offer its cleanup.
  ConfirmTrash? _confirmTrash;
  AskMcuModel? _askMcuModel;
  ConfirmUnidentified? _confirmUnidentified;

  Future<void> start({
    ConfirmFileReplace? confirmFileReplace,
    ConfirmTrash? confirmTrash,
    AskMcuModel? askMcuModel,
    ConfirmUnidentified? confirmUnidentified,
  }) async {
    if (confirmTrash != null) _confirmTrash = confirmTrash;
    if (askMcuModel != null) _askMcuModel = askMcuModel;
    if (confirmUnidentified != null) _confirmUnidentified = confirmUnidentified;
    _runIssue = null;
    _runIssuePriority = 0;
    messageTone = MessageTone.normal;
    resultPath = null;
    resultNote = null;
    resultMetadataPath = null;
    _failureNeedsInput = false;
    _failureIsFinding = false;
    _rdpRetryPending = false;
    _hardwareFailureKind = null;
    untestedTargetWarning = null;
    _sawTargetProgress = false;
    _cannotRun = false;
    _lastRunDuration = null;
    _lastExitCode = null;
    _runLog.clear();
    _capturing = true;
    _log(contextHeader());
    // Every BETA3 Windows transcript identifies the comparison mode. A bypass
    // run is not evidence about the default/shipping policy.
    if (windowsPathBenchAvailable && actionId != 'make_zip3') {
      if (Firmware.bypassWindowsPathSafety) {
        _log('== BETA3 Windows path mode: UNRESTRICTED BYPASS ==');
      } else {
        final codePage = Firmware.windowsAnsiCodePage;
        _log(
          '== BETA3 Windows path mode: ACP-safe'
          '${codePage == null ? '' : ' · code page $codePage'} ==',
        );
      }
    }
    try {
      await _dispatch(confirmFileReplace: confirmFileReplace);
    } finally {
      _capturing = false;
      if (logToFile) _flushLog();
    }
  }

  Future<void> _dispatch({ConfirmFileReplace? confirmFileReplace}) async {
    // Pack / Unpack zip3 is offline — pure file→file work that never talks to
    // the controller, so it runs before (and independent of) OpenOCD.
    if (actionId == 'make_zip3') {
      if (zip3WorkspacePage == Zip3WorkspacePage.unpack) {
        await _runUnpackZip3(confirmFileReplace: confirmFileReplace);
      } else {
        await _runMakeZip3(confirmFileReplace: confirmFileReplace);
      }
      return;
    }
    final backend = _backend;
    if (_androidMode && backend == null) {
      _failCannotRun(
        'Android OTG unavailable',
        'Check connection unavailable',
        'The Android USB-host backend is unavailable in this build. '
            'Nothing was sent to hardware.',
      );
      return;
    }
    if (backend == null) {
      _failCannotRun(
        'OpenOCD missing',
        'Cannot run ${action.name}',
        'Bundled OpenOCD was not found. This build cannot talk to the controller.',
      );
      return;
    }
    if (deviceProbeControlAvailable &&
        backend is HardwareDeviceBackend &&
        !deviceProbeReady) {
      _hardwareFailureKind = switch (_deviceStatus?.state) {
        HardwareDeviceState.unsupported => HardwareFailureKind.unsupported,
        HardwareDeviceState.disconnected =>
          HardwareFailureKind.deviceDisconnected,
        HardwareDeviceState.ambiguous => HardwareFailureKind.deviceAmbiguous,
        HardwareDeviceState.selectionRequired ||
        null => HardwareFailureKind.permissionRequired,
        HardwareDeviceState.ready => HardwareFailureKind.deviceUnavailable,
      };
      _setInputFailure(
        'ST-Link required',
        _androidMode ? 'Connect the ST-Link first' : 'Select a probe first',
        _androidMode
            ? 'Grant USB access from the Check screen, then start again.'
            : 'Use the ST-Link control in the status bar, then start again.',
      );
      return;
    }
    final router = _desktopBackendRouter;
    if (router != null && !router.selectedAvailable) {
      _failCannotRun(
        '${router.name} missing',
        'Cannot run ${action.name}',
        router.selectedUnavailableReason ?? '${router.name} is unavailable.',
      );
      return;
    }
    if (!_selectedBackendSupportsCurrentAction) {
      _failCannotRun(
        '${backend.name} experimental',
        '${action.name} is not implemented',
        '${backend.name} does not yet support ${action.name} in ${mode.title}. '
            'Nothing was sent to hardware.',
      );
      return;
    }
    if (!_backendSupportsCurrentAction) {
      _failCannotRun(
        '${backend.name} unavailable',
        'Cannot run ${action.name}',
        '${backend.name} does not support ${action.name} in ${mode.title}.',
      );
      return;
    }
    final g = mode.guided;
    switch (actionId) {
      case 'check':
        final r = await _runRealCore(
          HardwareRequest(
            operation: HardwareOperation.check,
            mode: mode,
            countdown: countdownSeconds,
          ),
          guided: g,
        );
        if (r != null) {
          if (r.ok) {
            _setInstruction('Target answered. You can continue.');
          }
          await _finishRealAfterHold(
            r.ok,
            action.okMsg,
            '$backendName exited with code ${r.exitCode}. Check the console.',
          );
        }
      case 'dump':
        await _runDump(g);
      case 'flash_only':
        await _runFlash(g, backup: false, slot0: isSlotAction);
      case 'flash_backup':
        await _runFlash(g, backup: true, slot0: isSlotAction);
      case 'flash_slot0': // retired, hidden — same guarded slot-0 write
        await _runFlash(g, backup: true, slot0: true);
      case 'flash_compat':
        await _runCompat(g);
      case 'rdp_check':
        await _runRdp('Check');
      case 'rdp_rescue':
        await _runRdp('Rescue');
      default:
        _failCannotRun(
          'Action unavailable',
          'Cannot run this action',
          'This action is not wired to a real OpenOCD command.',
        );
    }
  }

  bool get _selectedBackendSupportsCurrentAction {
    final router = _desktopBackendRouter;
    if (router == null) return true;
    return _capabilitiesSupportAction(actionId, router.selectedCapabilities);
  }

  bool _capabilitiesSupportAction(
    String id,
    HardwareCapabilities capabilities,
  ) {
    bool supports(HardwareOperation operation) =>
        capabilities.supports(operation, mode);
    return switch (id) {
      'check' => supports(HardwareOperation.check),
      'dump' => supports(HardwareOperation.dump),
      'flash_only' => supports(
        isSlotAction
            ? HardwareOperation.flashSlot0
            : HardwareOperation.flashFull,
      ),
      'flash_backup' =>
        supports(HardwareOperation.dump) &&
            supports(
              isSlotAction
                  ? HardwareOperation.flashSlot0
                  : HardwareOperation.flashFull,
            ),
      'flash_slot0' =>
        supports(HardwareOperation.dump) &&
            supports(HardwareOperation.flashSlot0),
      'flash_compat' =>
        supports(HardwareOperation.dump) &&
            supports(HardwareOperation.flashFull),
      'rdp_check' => capabilities.supportsProtection(
        HardwareProtectionOperation.check,
        mode,
      ),
      'rdp_rescue' => capabilities.supportsProtection(
        HardwareProtectionOperation.rescue,
        mode,
      ),
      _ => true,
    };
  }

  void _failCannotRun(String eb, String t, String sb) {
    running = false;
    _realRun = false;
    _cannotRun =
        true; // nothing launched: a retry cannot help, so don't arm one
    lastConnect = 'FAIL';
    _log('== $t ==');
    _set(StageState.fail, eb, t, sb);
  }

  Future<void> _runRdp(String verb) async {
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

    final backend = _backend;
    final capabilities = backend?.capabilities;
    final supported = verb == 'Check'
        ? capabilities?.protectionCheck ?? false
        : capabilities?.protectionRescue ?? false;
    if (backend == null || !supported) {
      _set(
        StageState.fail,
        _androidMode ? 'Unavailable' : 'rdp unavailable',
        _androidMode ? 'Protection check unavailable' : 'rdp.ps1 not found',
        _androidMode
            ? 'This Android build cannot read the protection state.'
            : 'The protection toolkit is missing from the bundle.',
      );
      return;
    }
    final my = ++_token;
    _diagnosis = null;
    _rdpRetryPending = false;
    running = true;
    _realRun = true;
    _startRunClock();
    lastConnect = 'connecting…';
    final raceCheck = verb == 'Check' && mode == ConnectionMode.powerRace;
    if (raceCheck) {
      raceAttempts = 0;
      raceTier = HardwareRaceTier.searching;
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
        _androidMode
            ? 'Reading the option bytes and flash evidence…'
            : 'Running the protection toolkit — watch the console.',
      );
    }

    late HardwareProtectionResult protectionResult;
    int code;
    var setupFailure = false;
    try {
      protectionResult = await backend.runProtection(
        HardwareProtectionRequest(
          operation: verb == 'Check'
              ? HardwareProtectionOperation.check
              : HardwareProtectionOperation.rescue,
          mode: mode,
          countdown: countdownSeconds,
        ),
        HardwareProtectionCallbacks(
          onLine: (line) {
            _onRealLine(line, driveOpenOcdProgress: false);
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
          onGuided: _handleGuidedEvent,
        ),
      );
      code = protectionResult.exitCode;
    } catch (e) {
      if (my != _token) return;
      _realRun = false;
      running = false;
      _stopRunClock(null);
      _set(
        StageState.fail,
        'Failed',
        '${action.name} failed',
        _androidMode
            ? 'The protection check could not run: $e'
            : 'Could not start rdp.ps1: $e',
      );
      return;
    }
    if (my != _token) return;
    _rdpRetryPending = false;
    _realRun = false;
    running = false;
    _stopRunClock(code);
    _log('== rdp exit $code ==');

    if (verb == 'Check') {
      // 0 = not protected, 2 = read-protected, 3 = inconclusive.
      switch (protectionResult.verdict) {
        case HardwareProtectionVerdict.notProtected:
          _finishReal(true, 'NOT read-protected — the flash is readable.', '');
        case HardwareProtectionVerdict.protected:
          // A locked chip is a valid verdict, not a success — amber, not green.
          lastConnect = 'PASS';
          _set(
            StageState.warn,
            'Verdict',
            'Read-protected',
            _androidMode
                ? 'The chip is locked. Unlock / rescue is not available in the Android app.'
                : 'The chip is locked. Unlock / rescue can clear it — but that erases the flash.',
          );
        case HardwareProtectionVerdict.inconclusive ||
            HardwareProtectionVerdict.failed ||
            HardwareProtectionVerdict.rescued:
          _finishReal(
            false,
            '',
            _androidMode
                ? 'Inconclusive — could not determine the protection state. Reconnect the ST-Link and try again.'
                : 'Inconclusive — could not determine the protection state. Check the console.',
            reseat: !setupFailure,
          );
      }
    } else if (protectionResult.verdict == HardwareProtectionVerdict.rescued) {
      // A successful rescue (green), but not a walk-away finish: the FAP write
      // only takes effect once a power-cycle reloads the option bytes, so the
      // title carries the required next step.
      lastConnect = 'PASS';
      _set(
        StageState.ok,
        'Rescued',
        'Power-cycle the board',
        'FAP cleared and the flash erased. Power-cycle the board and reconnect, '
            'then run Check protection to confirm — a check before power-cycling may '
            'still read protected until the option bytes reload.',
      );
    } else {
      _finishReal(
        false,
        action.okMsg,
        'rescue exited with code $code. Check the console for what happened.',
        reseat: !setupFailure,
      );
    }
  }

  void _handleRdpChunk(String chunk, {required bool raceCheck}) {
    final low = chunk.toLowerCase();
    if (low.contains('press enter to retry')) {
      _rdpRetryPending = true;
      lastConnect = 'FAIL';
      final issue = _runIssue ?? 'OpenOCD: connection failed';
      _set(
        StageState.fail,
        'Failed',
        '${action.name} failed',
        '$issue\n$_reseatHint',
      );
      return;
    }

    if (!raceCheck) return;
    final progress = chunk.replaceAll('\r', '').replaceAll('\n', '');
    if (!RegExp(r'^\.+$').hasMatch(progress)) return;
    final dots = progress.length;
    if (dots == 0) return;
    raceAttempts += dots;
    raceTier = HardwareRaceTier.searching;
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

  /// Run the selected hardware backend and return its structured evidence
  /// (null if the run was cancelled/superseded). The caller still owns product
  /// policy such as backup validation and target-versus-firmware matching.
  Future<HardwareResult?> _runRealCore(
    HardwareRequest request, {
    required bool guided,
    String? title,
  }) async {
    final backend = _backend;
    if (backend == null) return null;
    final my = ++_token;
    _diagnosis = null;
    running = true;
    _realRun = true;
    _startRunClock();
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

    HardwareResult result;
    try {
      // Native swdart completes many libusb futures synchronously on Flutter's
      // UI isolate. Give the busy state one event-loop turn to paint before
      // the first native transfer; OpenOCD already yields through Process I/O.
      if (useSwdartDesktop) {
        await Future<void>.delayed(Duration.zero);
        if (my != _token) return null;
      }
      result = await backend.run(
        request,
        HardwareCallbacks(
          onLine: (line) {
            _onRealLine(line, driveOpenOcdProgress: false);
          },
          onProgress: (progress) {
            if (my != _token) return;
            _sawTargetProgress = true;
            if (progress.connected) lastConnect = 'PASS';
            _lastProgressAt = DateTime.now();
            _showOpenOcdProgress();
          },
          onGuided: (event) {
            if (my != _token) return;
            _handleGuidedEvent(event);
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
        ),
      );
    } catch (e) {
      if (my != _token) return null;
      if (e is HardwareException) _hardwareFailureKind = e.kind;
      _realRun = false;
      running = false;
      _stopRunClock(null);
      _set(
        StageState.fail,
        'Failed',
        '${action.name} failed',
        _hardwareFailureMessage(backend, e),
      );
      return null;
    }
    if (my != _token) return null;
    _noteUntestedTarget(result.evidence);
    if (result.exitCode != 0 && _runIssue == null) {
      _setRunIssue(_backendExitFallback(request.operation), priority: 2);
    }
    _realRun = false;
    running = false;
    _stopRunClock(result.exitCode);
    _log('== ${backend.name.toLowerCase()} exit ${result.exitCode} ==');
    return result;
  }

  String _hardwareFailureMessage(HardwareBackend backend, Object error) {
    if (error is! HardwareException) {
      return 'Could not start ${backend.name}: $error';
    }
    return switch (error.kind) {
      HardwareFailureKind.userCancelled => 'The operation was cancelled.',
      HardwareFailureKind.permissionRequired =>
        'Select an ST-Link in the status bar before trying again.',
      HardwareFailureKind.unsupported =>
        'This browser does not provide WebUSB.',
      HardwareFailureKind.deviceDisconnected =>
        'The selected ST-Link disconnected. Reconnect it, then press Retry.',
      HardwareFailureKind.deviceAmbiguous =>
        'More than one ST-Link is available. Select the one to use.',
      HardwareFailureKind.deviceUnavailable =>
        'The selected ST-Link is unavailable. Reconnect or select it again.',
      HardwareFailureKind.deviceBusy =>
        'The selected ST-Link is busy. Close other tools using it, then retry.',
      HardwareFailureKind.targetContact =>
        'Could not reach the target over SWD: ${error.message}',
      HardwareFailureKind.unsupportedTarget => error.message,
      HardwareFailureKind.operation => error.message,
    };
  }

  void _onRealLine(String line, {bool driveOpenOcdProgress = true}) {
    _log(line);
    final clean = line.replaceAll(_ansi, '').trim();
    final low = clean.toLowerCase();
    if (low.contains('target halted')) {
      lastConnect = 'PASS';
    }
    // The runners echo their own command line ('> openocd …', '> bash …') into
    // this same stream, and those args carry user-chosen paths. A backup folder
    // named 'verified' or 'dumped' must never read as target evidence: it would
    // disarm the third hand before OpenOCD had even started, invisibly and for
    // every run. Only real target output counts.
    final fromTarget = !clean.startsWith('> ');
    // Sticky for the whole run: _finishReal overwrites lastConnect with FAIL
    // on ANY failure, so it cannot tell "never connected" from "connected,
    // then failed" — and only the former may auto-retry. Treat later objective
    // progress as proof too, so a missing/changed halt line can never make an
    // erase or write failure eligible for unattended repetition.
    if (fromTarget) _sawTargetProgress |= hasTargetProgressEvidence(low);
    _diagnose(low);
    _surfaceOpenOcdIssue(clean, low);
    if (driveOpenOcdProgress && fromTarget) _advanceOpenOcdStage(low);
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
      _setInstruction(
        _rdpRetryPending ? '$issue\n$_reseatHint' : issue,
        tone: MessageTone.danger,
      );
    }
  }

  String _backendExitFallback(HardwareOperation operation) {
    final name = _backend?.name ?? 'Hardware backend';
    return switch (operation) {
      HardwareOperation.check => '$name: connection check failed',
      HardwareOperation.dump => '$name: dump did not complete',
      HardwareOperation.flashFull ||
      HardwareOperation.flashSlot0 => '$name: flash did not complete',
    };
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

  /// Drive the shared UI from a backend-neutral guided connection event.
  void _handleGuidedEvent(HardwareGuidedEvent event) {
    switch (event.stage) {
      case HardwareGuidedStage.hold:
        _set(
          StageState.hold,
          'Step 1 of 3',
          'Hold C45 → GND',
          'Hold the C45/nRST contact to GND and keep it steady, then hit continue.',
          continueBtn: "I'm holding — continue",
        );
      case HardwareGuidedStage.release:
        _set(
          StageState.release,
          'Step 3 of 3',
          'Release now',
          'Lift the wire off the pad — right now — then hit continue.',
          continueBtn: 'Released — continue',
        );
      case HardwareGuidedStage.connected:
        showContinue = false;
        _progressShownAt ??= DateTime.now();
        _set(
          StageState.connect,
          _activeRunEyebrow ?? 'Linking',
          _activeRunEyebrow == null ? 'Connected' : action.name,
          'Keep the ST-LINK and SWD wires steady.',
        );
      case HardwareGuidedStage.count:
        if (event.countdown != null) countdownValue = event.countdown!;
        showContinue = false;
        _set(
          StageState.count,
          'Step 2 of 3',
          'Connecting under reset',
          'Keep holding the wire — do not lift it yet.',
        );
    }
  }

  static const _reseatHint =
      'Most failures are a lost SWD / C45 contact — re-seat it, keep it steady, then press Retry.';

  /// [reseat] appends the contact-retry hint — only right for CONNECTION
  /// failures, not validation/patch failures (a re-seat won't fix those).
  /// [finding] marks a verdict about the CHIP rather than a rejected input, so
  /// the button offers to clear the screen instead of sending the operator back
  /// to setup for something they cannot change.
  void _finishReal(
    bool ok,
    String okMsg,
    String failMsg, {
    bool reseat = true,
    bool finding = false,
    String? outputPath,
    String? outputNote,
    String? outputMetadataPath,
  }) {
    lastConnect = ok ? 'PASS' : 'FAIL';
    resultPath = outputPath;
    resultNote = outputNote;
    resultMetadataPath = outputMetadataPath;
    _failureNeedsInput = !ok && !reseat;
    _failureIsFinding = !ok && finding;
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
    bool finding = false,
    String? outputPath,
    String? outputNote,
    String? outputMetadataPath,
  }) async {
    final my = _token;
    final hadBusySurface = _busySurfaceIsVisible;
    await _holdBusySurfaceForReading();
    if (my != _token) return;
    if (hadBusySurface && !_busySurfaceIsVisible) return;
    _finishReal(
      ok,
      okMsg,
      failMsg,
      reseat: reseat,
      finding: finding,
      outputPath: outputPath,
      outputNote: outputNote,
      outputMetadataPath: outputMetadataPath,
    );
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
  String _raceHint(HardwareRaceTier tier) => switch (tier) {
    HardwareRaceTier.searching => 'No contact yet — cut & re-apply power.',
    HardwareRaceTier.noisy => 'On the pad but bouncing — hold it steadier.',
    HardwareRaceTier.nearCatch => 'Almost — reached the core, keep holding.',
    HardwareRaceTier.adapterGone => 'ST-LINK not seen — check the probe / USB.',
    HardwareRaceTier.timedOut =>
      'OpenOCD stalled — power-cycle and try the next catch.',
  };

  /// Any live OpenOCD marker shows the busy surface and keeps the race watchdog
  /// fed. Markers are not told apart; the eyebrow is per-action, not per-stage.
  void _advanceOpenOcdStage(String low) {
    if (hasTargetProgressEvidence(low)) {
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

  /// Record an identified-but-unmeasured chip package, once per run.
  ///
  /// `targetTested == null` means the backend cannot name a part (OpenOCD), and
  /// must stay silent — treating it as untested would warn about every OpenOCD
  /// run. Only an explicit `false` warns.
  void _noteUntestedTarget(HardwareEvidence evidence) {
    if (evidence.targetTested != false) return;
    if (untestedTargetWarning != null) return;
    final part = evidence.targetName ?? 'this chip';
    untestedTargetWarning =
        '$part is not the package x3utils has been tested on. '
        'It has the same flash layout as the tested part, but no one has '
        'verified a write on it — flash at your own risk.';
    _log('== target not hardware-tested: $part ==');
  }

  bool _dumpConfirmed(HardwareResult r) => r.ok && r.evidence.dumped;

  bool _flashConfirmed(HardwareResult r) =>
      r.ok && r.evidence.wrote && r.evidence.verified;

  String _dumpFailMessage(HardwareResult r) {
    if (r.ok && !r.evidence.dumped) {
      return '$backendName completed, but a complete dump was not confirmed. Retry required.';
    }
    return 'Dump failed (exit ${r.exitCode}). Check the console.';
  }

  String _flashFailMessage(HardwareResult r) {
    if (r.ok && r.evidence.wrote && !r.evidence.verified) {
      return 'Flash wrote data, but verification was not confirmed. Retry required.';
    }
    if (r.ok && !r.evidence.wrote) {
      return 'OpenOCD exited successfully, but no flash write was confirmed. Retry required.';
    }
    return 'Flash failed (exit ${r.exitCode}). Nothing verified — check the console.';
  }

  Future<void> _runDump(bool guided) async {
    final memoryBacked = _browserMode || _androidMode;
    final staged = memoryBacked ? null : _stagedDumpPath();
    if (!memoryBacked && staged == null) return;
    _showOpenOcdProgress(eyebrow: 'Backing up');
    _setInstruction('Reading the full 128 KB flash...');
    final r = await _runRealCore(
      HardwareRequest(
        operation: HardwareOperation.dump,
        mode: mode,
        countdown: countdownSeconds,
        filePath: staged,
      ),
      guided: guided,
    );
    if (r == null) {
      if (staged != null) {
        _noteStagedFile(staged); // cancelled mid-read: say what was left behind
      }
      return;
    }
    _showOpenOcdProgress(eyebrow: 'Validating');
    if (!_dumpConfirmed(r)) {
      await _finishRealAfterHold(
        false,
        '',
        _dumpFailMessage(r),
        outputPath: staged == null ? null : _existingOrNull(staged),
      );
      if (staged != null) await _offerDumpCleanup(staged);
      return;
    }
    if (_browserMode) {
      await _finishBrowserDump(r);
      return;
    }
    if (_androidMode) {
      await _finishAndroidDump(r);
      return;
    }
    final nativeStaged = staged!;
    final stageError = await _stageReturnedDumpBytes(r, nativeStaged);
    if (stageError != null) {
      _log('== backup staging FAILED: $stageError ==');
      await _finishRealAfterHold(
        false,
        '',
        '$stageError It was not saved as a backup.',
        outputPath: _existingOrNull(nativeStaged),
      );
      await _offerDumpCleanup(nativeStaged);
      return;
    }
    _setInstruction('Validating backup file...');
    final v = Firmware.inspectDump(nativeStaged);
    if (!v.ok) {
      _log('== validation FAILED: ${v.message} ==');
      await _finishRealAfterHold(
        false,
        '',
        '${v.message} It was not saved as a backup.',
        // An incomplete read is still a contact problem, so it keeps the
        // re-seat/Retry loop. A masked or blank chip is a finding, not a
        // wiring fault — re-seating it changes nothing.
        reseat: v.verdict == DumpVerdict.incomplete,
        finding: v.isEvidence,
        outputPath: _existingOrNull(nativeStaged),
      );
      await _offerDumpCleanup(nativeStaged);
      return;
    }
    final outPath = Firmware.promoteDump(nativeStaged);
    _log('== validated OK → $outPath ==');
    _setInstruction('Backup validated. Keep this file safe.');
    final metadataPath = _writeDumpMetadata(outPath);
    _maybeSecondCopy(outPath, sidecarPath: metadataPath);
    await _finishRealAfterHold(
      true,
      'Backed up and verified.',
      '',
      outputPath: outPath,
      outputMetadataPath: metadataPath,
    );
  }

  Future<void> _finishBrowserDump(HardwareResult result) async {
    final bytes = result.bytes;
    if (bytes == null || bytes.length != Firmware.expectedSize) {
      final length = bytes?.length ?? 0;
      await _finishRealAfterHold(
        false,
        '',
        'The browser backend returned $length of ${Firmware.expectedSize} '
            'backup bytes. Nothing was downloaded.',
      );
      return;
    }
    final check = Firmware.inspectDumpBytes(bytes);
    if (!check.ok) {
      _log('== validation FAILED: ${check.message} ==');
      await _finishRealAfterHold(
        false,
        '',
        '${check.message} Nothing was downloaded.',
        reseat: check.verdict == DumpVerdict.incomplete,
        finding: check.isEvidence,
      );
      return;
    }

    final fileName = Firmware.dumpFileName(prefix: backupPrefix);
    _setInstruction('Backup validated. Starting the browser download...');
    try {
      await _backupDownloader(bytes, fileName);
    } catch (e) {
      _log('== browser download FAILED: $e ==');
      await _finishRealAfterHold(
        false,
        '',
        'The backup validated, but the browser download failed: $e',
        reseat: false,
      );
      return;
    }
    _log('== validated OK → browser download $fileName ==');
    _setInstruction('Backup validated and sent to your browser downloads.');
    await _finishRealAfterHold(
      true,
      'Backed up and verified.',
      '',
      outputPath: fileName,
      outputNote:
          'Browser download only — no metadata sidecar or second copy was created.',
    );
  }

  Future<void> _finishAndroidDump(HardwareResult result) async {
    final bytes = result.bytes;
    if (bytes == null || bytes.length != Firmware.expectedSize) {
      final length = bytes?.length ?? 0;
      await _finishRealAfterHold(
        false,
        '',
        'The Android backend returned $length of ${Firmware.expectedSize} '
            'backup bytes. Nothing was saved.',
      );
      return;
    }
    final check = Firmware.inspectDumpBytes(bytes);
    if (!check.ok) {
      _log('== validation FAILED: ${check.message} ==');
      await _finishRealAfterHold(
        false,
        '',
        '${check.message} Nothing was saved.',
        reseat: check.verdict == DumpVerdict.incomplete,
        finding: check.isEvidence,
      );
      return;
    }

    final fileName = Firmware.dumpFileName(prefix: backupPrefix);
    _setInstruction('Backup validated. Saving to Downloads...');
    late final String savedPath;
    try {
      savedPath = await _androidBackupPublisher(bytes, fileName);
    } catch (e) {
      _log('== Android backup save FAILED: $e ==');
      await _finishRealAfterHold(
        false,
        '',
        'The backup validated, but Android could not save it: $e',
        reseat: false,
      );
      return;
    }
    _log('== validated OK → $savedPath ==');
    _setInstruction('Backup validated and saved to Downloads.');
    await _finishRealAfterHold(
      true,
      'Backed up and verified.',
      '',
      outputPath: savedPath,
      outputNote:
          'Android backup only — no metadata sidecar or second copy was created.',
    );
  }

  // ── Staged dumps ──────────────────────────────────────────────────────────
  // Every read writes to `<name>.bin.part` and is renamed to `.bin` only after
  // it passes inspection, so a failed read can never occupy a real backup name
  // or be offered by a `.bin` file picker. A partial dump is not a degraded
  // backup: identity lives in the last 4 KB, so a short file can never hold it.

  /// The staging path for this run, or null when the destination itself is
  /// unusable — checked BEFORE the run, while nothing has happened yet.
  String? _stagedDumpPath({String? explicitPath}) {
    final finalPath =
        explicitPath ?? Firmware.newDumpPath(prefix: backupPrefix);
    final staged = Firmware.stagedDumpPath(finalPath);
    final safe = Firmware.validateOpenOcdPath(staged);
    if (!safe.ok) {
      _setInputFailure(
        'x3utils folder',
        'Cannot write the backup',
        '${safe.message} Choose a different x3utils folder in Settings, then '
            'start again.',
      );
      return null;
    }
    return staged;
  }

  String? _existingOrNull(String path) => File(path).existsSync() ? path : null;

  /// Materialize an in-memory backend dump into the same staged-file policy
  /// used by OpenOCD. The file is still promoted only after inspection passes.
  Future<String?> _stageReturnedDumpBytes(
    HardwareResult result,
    String staged,
  ) async {
    final bytes = result.bytes;
    if (bytes == null) return null;
    if (bytes.length != Firmware.expectedSize) {
      return 'The hardware backend returned ${bytes.length} of '
          '${Firmware.expectedSize} backup bytes.';
    }
    try {
      await File(staged).writeAsBytes(bytes, flush: true);
      _log('== staged ${bytes.length} backend bytes → $staged ==');
      return null;
    } catch (e) {
      return 'Could not write the staged backup: $e';
    }
  }

  /// Adds optional local identity metadata after a dump is already a backup.
  /// Failure here is logged but intentionally never alters the run's verdict.
  String? _writeDumpMetadata(String dumpPath) {
    if (Firmware.isStagedDump(dumpPath)) {
      _log('== backup info was not written: backup promotion failed ==');
      return null;
    }
    try {
      final sidecar = DumpMetadata.writeValidatedSidecar(dumpPath);
      _log('== backup info → $sidecar ==');
      return sidecar;
    } catch (e) {
      _log('== backup info was not written: $e ==');
      return null;
    }
  }

  void _noteStagedFile(String staged) {
    if (!File(staged).existsSync()) return;
    final finding = Firmware.inspectDump(staged).isEvidence;
    _log(
      finding
          ? '== chip finding, file left at → $staged =='
          : '== incomplete read left at → $staged ==',
    );
  }

  /// Warn about a dump that is not a backup and offer to bin it.
  ///
  /// Two verdicts, not one — but the difference is carried by the WORDING, not
  /// by whether the offer appears. Junk (a short read, or one repeated byte
  /// that is not the protection signature) is a failed read. A full-size
  /// all-zeros or all-0xFF read is a complete, correct read that says something
  /// true about the chip, and its dialog must never imply the read failed.
  /// Neither one is a backup, neither can be flashed, and both keep the `.part`
  /// name whatever the operator decides.
  Future<void> _offerDumpCleanup(String staged) async {
    final file = File(staged);
    if (!file.existsSync()) return;
    final check = Firmware.inspectDump(staged);
    _noteStagedFile(staged);
    // Auto-retry means the operator has both hands on the probe. A modal is
    // exactly the wrong thing to put in front of them mid-loop.
    if (autoRetryArmed) return;
    final confirm = _confirmTrash;
    if (confirm == null) return;
    final title = check.isEvidence
        ? 'This read is a finding, not a backup'
        : 'This file is not a backup';
    if (!await confirm(staged, title, check.message)) {
      _log('== kept → $staged ==');
      return;
    }
    final result = await Trash.move(staged);
    final where = Trash.label;
    if (result.ok) {
      // Source → destination. Windows recycles through the shell and reports no
      // destination path, so say where it went by name instead of repeating the
      // source path after an arrow that would read like a destination.
      final dest = result.destination;
      _log(
        dest == null
            ? '== $staged → moved to the $where =='
            : '== $staged → moved to $dest ==',
      );
      resultPath = null;
      resultNote = 'The dump was moved to the $where.';
    } else {
      // Fail closed: never a hard delete, and never a silent one either.
      _log('== could not move to the $where: ${result.message} ==');
      resultPath = staged;
      resultNote =
          'It could not be moved to the $where (${result.message}) — it is '
          'still at the path above.';
    }
    notifyListeners();
  }

  Future<void> _runFlash(
    bool guided, {
    required bool backup,
    required bool slot0,
  }) async {
    if (_browserMode || _androidMode) {
      await _runMemoryBackedFlash(guided, backup: backup, slot0: slot0);
      return;
    }
    final fw = firmwarePath;
    if (fw == null) {
      _setInputFailure(
        'No firmware',
        'Choose a firmware .bin first',
        'Pick a .bin file, then start the flash.',
      );
      return;
    }
    final guarded = actionId != 'flash_only';
    final v = _validateFirmwareFile(fw, slot0: slot0, enforceBanner: guarded);
    if (!v.ok) {
      _setInputFailure('Firmware invalid', 'Firmware invalid', v.message);
      return;
    }
    final selectedDigest = _firmwareDigest;
    if (guarded &&
        (selectedDigest == null || _digestFile(fw) != selectedDigest)) {
      _setInputFailure(
        'Firmware changed',
        'Choose the firmware again',
        'The selected firmware changed on disk after it was checked. Choose it '
            'again before flashing.',
      );
      return;
    }

    if (actionId == 'flash_only') {
      _log(
        '== flash_only scope=${slot0 ? 'slot0' : 'full'} '
        '— no backup, no target guard ==',
      );
    }

    String? backupPath;
    String? backupMetadataPath;
    Uint8List? programBytes;
    String?
    serialNote; // identity change fact for the log + result (never blocks)

    // Mandatory backup first (the scripts' safety floor) — abort flash if it fails.
    if (backup) {
      final staged = _stagedDumpPath();
      if (staged == null) return;
      _showOpenOcdProgress(eyebrow: 'Backing up');
      _setInstruction('Backing up the chip before flashing...');
      final b = await _runRealCore(
        HardwareRequest(
          operation: HardwareOperation.dump,
          mode: mode,
          countdown: countdownSeconds,
          filePath: staged,
        ),
        guided: guided,
        title: 'Backing up first…',
      );
      if (b == null) {
        _noteStagedFile(staged);
        return;
      }
      if (!_dumpConfirmed(b)) {
        await _finishRealAfterHold(
          false,
          '',
          'Backup did not confirm a complete dump — flash aborted for safety. ${_dumpFailMessage(b)}',
          outputPath: _existingOrNull(staged),
        );
        await _offerDumpCleanup(staged);
        return;
      }
      final stageError = await _stageReturnedDumpBytes(b, staged);
      if (stageError != null) {
        _log('== backup staging FAILED: $stageError ==');
        await _finishRealAfterHold(
          false,
          '',
          'Flash aborted for safety — $stageError Nothing was written.',
          outputPath: _existingOrNull(staged),
        );
        await _offerDumpCleanup(staged);
        return;
      }
      _setInstruction('Validating backup file before writing...');
      final backupCheck = Firmware.inspectDump(staged);
      if (!backupCheck.ok) {
        _log('== validation FAILED: ${backupCheck.message} ==');
        await _finishRealAfterHold(
          false,
          '',
          'Flash aborted for safety — nothing was written. '
              '${backupCheck.message}',
          reseat: backupCheck.verdict == DumpVerdict.incomplete,
          finding: backupCheck.isEvidence,
          outputPath: _existingOrNull(staged),
        );
        await _offerDumpCleanup(staged);
        return;
      }
      final outPath = Firmware.promoteDump(staged);
      _log('== backup ok → $outPath ==');
      _setInstruction('Backup validated. Writing can continue.');
      backupMetadataPath = _writeDumpMetadata(outPath);
      _maybeSecondCopy(outPath, sidecarPath: backupMetadataPath);
      backupPath = outPath;

      // Device-side guard: does the target (from the backup we just took) match
      // the firmware we're about to write? Unsupported/missing identity or a
      // banner mismatch → abort and keep the backup. Serials never decide —
      // they are read, logged, and reported only.
      _setInstruction('Checking the target matches the firmware...');
      final dumpBytes = File(outPath).readAsBytesSync();
      late final Uint8List fwBytes;
      try {
        fwBytes = File(fw).readAsBytesSync();
      } catch (e) {
        await _finishRealAfterHold(
          false,
          '',
          'Flash aborted — the selected firmware could not be read after the '
              'backup: $e. The pre-flash backup was saved.',
          reseat: false,
          outputPath: outPath,
          outputMetadataPath: backupMetadataPath,
        );
        return;
      }
      final currentDigest = crypto.sha256.convert(fwBytes).toString();
      if (selectedDigest == null || currentDigest != selectedDigest) {
        await _finishRealAfterHold(
          false,
          '',
          'Flash aborted — the selected firmware changed on disk after it was '
              'checked. Choose it again. The pre-flash backup was saved.',
          reseat: false,
          outputPath: outPath,
          outputMetadataPath: backupMetadataPath,
        );
        return;
      }
      // swdart consumes this exact post-backup, digest-checked snapshot. The
      // OpenOCD adapter still consumes [fw] and ignores the in-memory copy.
      programBytes = Uint8List.fromList(fwBytes);
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
          'Flash aborted — ${tm.message} The pre-flash backup was saved.',
          reseat: false,
          outputPath: outPath,
          outputMetadataPath: backupMetadataPath,
        );
        return;
      }
      if (tm.note != null) _log('== ${tm.note} ==');
    }

    // Flash Only deliberately has no stored-digest or target-identity gate,
    // but native-library backends still need a stable snapshot of the bytes
    // selected for this individual write.
    try {
      programBytes ??= File(fw).readAsBytesSync();
    } catch (e) {
      _setInputFailure(
        'Firmware unavailable',
        'Could not read the firmware',
        'The selected firmware could not be read immediately before writing: '
            '$e',
      );
      return;
    }

    _showOpenOcdProgress(eyebrow: 'Flashing');
    _setInstruction(
      slot0
          ? 'Writing slot 0 only. Bootloader and identity stay untouched.'
          : backup
          ? 'Writing the selected firmware...'
          : 'Writing without a backup. Keep the ST-LINK and SWD wires steady.',
    );
    final r = await _runRealCore(
      HardwareRequest(
        operation: slot0
            ? HardwareOperation.flashSlot0
            : HardwareOperation.flashFull,
        mode: mode,
        countdown: countdownSeconds,
        filePath: fw,
        bytes: programBytes,
      ),
      guided: guided,
      title: '${action.name}…',
    );
    if (r == null) return;
    // OpenOCD has stopped, so the live timer is frozen. Keep the busy surface
    // truthful while the evidence verdict and final result are being settled
    // instead of falling back to the stale "Flashing" phase label.
    _showOpenOcdProgress(eyebrow: 'Validating');
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
    final okMsg = backup && backupPath != null
        ? slot0
              ? 'Slot 0 flashed and verified. The pre-flash backup was saved.'
              : 'Flashed and verified. The pre-flash backup was saved.'
        : slot0
        ? 'Slot 0 flashed & verified. No backup was taken.'
        : action.okMsg;
    var failMsg = _flashFailMessage(r);
    if (backupPath != null) {
      failMsg = '$failMsg The pre-flash backup was saved.';
    }
    await _finishRealAfterHold(
      flashOk,
      okMsg,
      failMsg,
      outputPath: backupPath,
      outputNote: flashOk ? serialNote : null,
      outputMetadataPath: backupMetadataPath,
    );
  }

  Future<void> _runMemoryBackedFlash(
    bool guided, {
    required bool backup,
    required bool slot0,
  }) async {
    final firmwareName = firmwarePath;
    final retained = _firmwareSelectedBytes;
    final selectedDigest = _firmwareDigest;
    if (firmwareName == null || retained == null || selectedDigest == null) {
      _setInputFailure(
        'No firmware',
        'Choose a firmware .bin first',
        slot0
            ? 'Pick a slot-0 payload .bin or load a zip3 package, then start.'
            : 'Pick a full 128 KB .bin file, then start.',
      );
      return;
    }
    final guarded = backup;
    final firmwareBytes = Uint8List.fromList(retained);
    final structural = slot0
        ? Firmware.validateSlotBytes(firmwareBytes)
        : Firmware.validateFullImageBytes(firmwareBytes);
    if (!structural.ok) {
      _setInputFailure(
        'Firmware invalid',
        'Firmware invalid',
        structural.message,
      );
      return;
    }
    if (guarded) {
      final identity = DeviceSpec.checkIncomingBin(
        firmwareBytes,
        slotBin: slot0,
        enforceBanner: true,
      );
      if (!identity.ok) {
        _setInputFailure(
          'Firmware invalid',
          'Firmware invalid',
          identity.message,
        );
        return;
      }
    }
    if (crypto.sha256.convert(firmwareBytes).toString() != selectedDigest) {
      _setInputFailure(
        'Firmware changed',
        'Choose the firmware again',
        'The selected in-memory firmware changed after validation.',
      );
      return;
    }

    Uint8List? dumpBytes;
    String? backupName;
    String? serialNote;

    if (backup) {
      _showOpenOcdProgress(eyebrow: 'Backing up');
      _setInstruction('Backing up the chip before flashing...');
      final backupResult = await _runRealCore(
        HardwareRequest(
          operation: HardwareOperation.dump,
          mode: mode,
          countdown: countdownSeconds,
        ),
        guided: guided,
        title: 'Backing up first…',
      );
      if (backupResult == null) return;
      if (!_dumpConfirmed(backupResult)) {
        await _finishRealAfterHold(
          false,
          '',
          'Backup did not confirm a complete dump — flash aborted for safety. '
              '${_dumpFailMessage(backupResult)}',
        );
        return;
      }
      dumpBytes = backupResult.bytes;
      final backupCheck = dumpBytes == null
          ? const DumpCheck(
              DumpVerdict.missing,
              'The hardware backend returned no backup bytes.',
              0,
            )
          : Firmware.inspectDumpBytes(dumpBytes);
      if (!backupCheck.ok) {
        _log('== validation FAILED: ${backupCheck.message} ==');
        await _finishRealAfterHold(
          false,
          '',
          'Flash aborted for safety — nothing was written. '
              '${backupCheck.message}',
          reseat: backupCheck.verdict == DumpVerdict.incomplete,
          finding: backupCheck.isEvidence,
        );
        return;
      }

      backupName = Firmware.dumpFileName(prefix: backupPrefix);
      final backupNote = _androidMode
          ? 'Android backup only — no metadata sidecar or second copy was created.'
          : 'Browser download only — no metadata sidecar or second copy was created.';
      String backupPath;
      try {
        if (_androidMode) {
          _setInstruction('Backup validated. Saving to Downloads...');
          backupPath = await _androidBackupPublisher(
            Uint8List.fromList(dumpBytes!),
            backupName,
          );
        } else {
          _setInstruction('Backup validated. Starting the browser download...');
          await _backupDownloader(Uint8List.fromList(dumpBytes!), backupName);
          backupPath = backupName;
        }
      } catch (e) {
        final saveKind = _androidMode
            ? 'Android backup save'
            : 'browser download';
        _log('== $saveKind FAILED: $e ==');
        await _finishRealAfterHold(
          false,
          '',
          'Flash aborted for safety — the backup validated, but it could not '
              'be saved: $e. Nothing was written.',
          reseat: false,
        );
        return;
      }
      backupName = backupPath;
      _log('== backup ok → $backupPath ==');

      _setInstruction('Checking the target matches the firmware...');
      final targetId = DeviceSpec.describeBin(dumpBytes, slotBin: false);
      final firmwareId = DeviceSpec.describeBin(firmwareBytes, slotBin: slot0);
      _log('== target identity: ${targetId.logLine} ==');
      _log('== firmware identity: ${firmwareId.logLine} ==');
      serialNote = DeviceSpec.serialChangeNote(
        target: targetId.serial!,
        incoming: firmwareId.serial,
      );
      if (serialNote != null) _log('== note: $serialNote ==');
      final targetMatch = DeviceSpec.checkTargetMatch(
        dump: dumpBytes,
        firmware: firmwareBytes,
        incomingIsSlotBin: slot0,
      );
      if (targetMatch.blocked) {
        _log('== target mismatch: ${targetMatch.message} ==');
        final backupResultText = _androidMode
            ? 'The pre-flash backup was saved.'
            : 'The pre-flash backup download was started.';
        await _finishRealAfterHold(
          false,
          '',
          'Flash aborted — ${targetMatch.message} $backupResultText '
              'Nothing was written.',
          reseat: false,
          outputPath: backupPath,
          outputNote: backupNote,
        );
        return;
      }
      if (targetMatch.note != null) _log('== ${targetMatch.note} ==');

      if (crypto.sha256.convert(firmwareBytes).toString() !=
          _firmwareSelectedDigest) {
        await _finishRealAfterHold(
          false,
          '',
          'Flash aborted — the selected in-memory firmware changed after the '
              'backup. Nothing was written.',
          reseat: false,
          outputPath: backupName,
        );
        return;
      }
    } else {
      _log(
        '== ${slot0 ? 'flash scope=slot0' : 'flash_only scope=full'}'
        ' — no backup, no target guard ==',
      );
    }

    _showOpenOcdProgress(eyebrow: 'Flashing');
    _setInstruction('Writing the selected firmware...');
    final flashResult = await _runRealCore(
      HardwareRequest(
        operation: slot0
            ? HardwareOperation.flashSlot0
            : HardwareOperation.flashFull,
        mode: mode,
        countdown: countdownSeconds,
        bytes: firmwareBytes,
      ),
      guided: guided,
      title: '${action.name}…',
    );
    if (flashResult == null) return;
    _showOpenOcdProgress(eyebrow: 'Validating');
    final flashOk =
        _flashConfirmed(flashResult) && flashResult.evidence.resetRunning;
    if (flashOk) {
      _setInstruction('Flash verified and target reset to running.');
    }
    final failure =
        flashResult.ok &&
            flashResult.evidence.wrote &&
            flashResult.evidence.verified &&
            !flashResult.evidence.resetRunning
        ? 'Flash verified, but reset-to-running was not confirmed.'
        : _flashFailMessage(flashResult);
    if (backup) {
      final backupNote = _androidMode
          ? 'Android backup only — no metadata sidecar or second copy was created.'
          : 'Browser download only — no metadata sidecar or second copy was created.';
      final backupResultText = _androidMode
          ? 'The pre-flash backup was saved.'
          : 'The pre-flash backup download was started.';
      await _finishRealAfterHold(
        flashOk,
        'Flashed and verified. $backupResultText',
        '$failure $backupResultText',
        outputPath: backupName,
        outputNote: flashOk && serialNote != null
            ? '$serialNote $backupNote'
            : backupNote,
      );
    } else {
      await _finishRealAfterHold(flashOk, action.okMsg, failure);
    }
  }

  /// Memory-backed SHU-compat: dump → save the original backup → patch in
  /// memory → flash back. Browser downloads the backup; Android publishes it
  /// through MediaStore before anything is patched or written.
  Future<void> _runMemoryCompat(bool guided) async {
    _showOpenOcdProgress(eyebrow: 'Backing up');
    _setInstruction('Reading the chip before patching...');

    final dumpResult = await _runRealCore(
      HardwareRequest(
        operation: HardwareOperation.dump,
        mode: mode,
        countdown: countdownSeconds,
      ),
      guided: guided,
      title: 'Reading current firmware…',
    );
    if (dumpResult == null) return;
    if (!_dumpConfirmed(dumpResult)) {
      await _finishRealAfterHold(
        false,
        '',
        'Could not confirm a complete chip read — nothing was changed. '
            '${_dumpFailMessage(dumpResult)}',
      );
      return;
    }
    final dumpBytes = dumpResult.bytes;
    final dumpCheck = dumpBytes == null
        ? const DumpCheck(
            DumpVerdict.missing,
            'The hardware backend returned no backup bytes.',
            0,
          )
        : Firmware.inspectDumpBytes(dumpBytes);
    if (!dumpCheck.ok) {
      _log('== validation FAILED: ${dumpCheck.message} ==');
      await _finishRealAfterHold(
        false,
        '',
        'Nothing was written — the chip did not read back as firmware. '
            '${dumpCheck.message}',
        reseat: dumpCheck.verdict == DumpVerdict.incomplete,
        finding: dumpCheck.isEvidence,
      );
      return;
    }

    final backupName = Firmware.dumpFileName(prefix: backupPrefix);
    final backupNote = _androidMode
        ? 'Android backup only — no metadata sidecar or second copy was created.'
        : 'Browser download only — no metadata sidecar or second copy was created.';
    final backupResultText = _androidMode
        ? 'The original backup was saved.'
        : 'The original backup download was started.';
    _setInstruction(
      _androidMode
          ? 'Backup validated. Saving to $androidBackupDirectoryLabel...'
          : 'Backup validated. Starting the browser download...',
    );
    var backupPath = backupName;
    try {
      final backup = Uint8List.fromList(dumpBytes!);
      if (_androidMode) {
        backupPath = await _androidBackupPublisher(backup, backupName);
      } else {
        await _backupDownloader(backup, backupName);
      }
    } catch (e) {
      final destination = _androidMode
          ? 'Android backup save'
          : 'browser download';
      _log('== $destination FAILED: $e ==');
      await _finishRealAfterHold(
        false,
        '',
        'Compat aborted — the backup validated, but the $destination failed: '
            '$e. Nothing was written.',
        reseat: false,
      );
      return;
    }
    _log('== backup ok → $backupPath ==');

    final identity = await _compatIdentityGateBytes(
      dumpBytes,
      backupResultText: backupResultText,
      backupPath: backupPath,
      backupNote: backupNote,
    );
    if (identity == null) return;

    _showOpenOcdProgress(eyebrow: 'Patching');
    _setInstruction('Patching the SHU compatibility signature...');
    _log('== patching SHU-compat signature @ 0x1420 ==');
    final (patchCheck, patchedBytes) = CompatPatch.applyBytes(
      Uint8List.fromList(dumpBytes),
    );
    if (!patchCheck.ok || patchedBytes == null) {
      _log('== patch FAILED: ${patchCheck.message} ==');
      await _finishRealAfterHold(
        false,
        '',
        'Patch failed — the chip was NOT written. ${patchCheck.message}',
        reseat: false,
        outputPath: backupPath,
        outputNote: backupNote,
      );
      return;
    }
    final programCheck = Firmware.validateFullImageBytes(patchedBytes);
    final signatureOk =
        CompatPatch.keyState(patchedBytes) == FwKeyState.defaultKey;
    if (!programCheck.ok || !signatureOk) {
      final reason = !programCheck.ok
          ? programCheck.message
          : 'The SHU compatibility signature is missing at 0x1420.';
      _log('== patch validation FAILED: $reason ==');
      await _finishRealAfterHold(
        false,
        '',
        'Patch validation failed — the chip was NOT written. $reason',
        reseat: false,
        outputPath: backupPath,
        outputNote: backupNote,
      );
      return;
    }
    _showOpenOcdProgress(eyebrow: 'Patching');
    _setInstruction('SHU patch applied. Ready to flash...');
    await Future.delayed(const Duration(milliseconds: 900));

    _showOpenOcdProgress(eyebrow: 'Flashing');
    _setInstruction('Flashing it back to the chip...');
    final f = await _runRealCore(
      HardwareRequest(
        operation: HardwareOperation.flashFull,
        mode: mode,
        countdown: countdownSeconds,
        bytes: patchedBytes,
      ),
      guided: guided,
      title: 'Flashing SHU-compatible firmware…',
    );
    if (f == null) return;
    _showOpenOcdProgress(eyebrow: 'Validating');
    final flashOk = _flashConfirmed(f) && f.evidence.resetRunning;
    if (flashOk) {
      _setInstruction('SHU-compatible firmware verified and target reset.');
    }
    final failure =
        f.ok &&
            f.evidence.wrote &&
            f.evidence.verified &&
            !f.evidence.resetRunning
        ? 'Flash verified, but reset-to-running was not confirmed.'
        : _flashFailMessage(f);
    await _finishRealAfterHold(
      flashOk,
      'SHU-compatible firmware flashed and verified. $backupResultText',
      '$failure $backupResultText',
      outputPath: backupPath,
      outputNote: backupNote,
    );
  }

  /// Bytes-based variant of [_compatIdentityGate] for memory-backed platforms.
  Future<CompatIdentity?> _compatIdentityGateBytes(
    List<int> bytes, {
    required String backupResultText,
    required String backupPath,
    required String backupNote,
  }) async {
    _setInstruction('Identifying the installed firmware...');
    final id = DeviceSpec.describeBin(bytes, slotBin: false);
    _log('== installed firmware: ${id.logLine} ==');

    final type = id.bannerType;
    if (type == null || !id.bannerSupported) {
      await _finishRealAfterHold(
        false,
        '',
        'Nothing was written — this chip is not running firmware x3utils '
            'recognises (${id.bannerLabel}). SHU compat only applies to '
            'supported ZT3, G3 and F3 firmware. $backupResultText',
        reseat: false,
        finding: true,
        outputPath: backupPath,
        outputNote: backupNote,
      );
      return null;
    }

    var model = id.bannerModel;
    var modelDeclared = false;
    if (type == 'MCU') {
      final models =
          FwVersionMatrix.known.keys
              .where((k) => k.endsWith('/MCU'))
              .map((k) => k.split('/').first)
              .toList()
            ..sort();
      final ask = _askMcuModel;
      final picked = ask == null ? null : await ask(models);
      if (picked == null) {
        await _finishRealAfterHold(
          false,
          '',
          'Nothing was written — this is MCU firmware, which does not say which '
              'model it belongs to, and no model was selected. '
              '$backupResultText',
          reseat: false,
          finding: true,
          outputPath: backupPath,
          outputNote: backupNote,
        );
        return null;
      }
      model = picked;
      modelDeclared = true;
      _log('== operator declared MCU model: $model (not verifiable) ==');
    }

    if (FwVersionMatrix.unsupportedModels.contains(model)) {
      await _finishRealAfterHold(
        false,
        '',
        'Nothing was written — SHU compat is not supported on '
            '${model!.toUpperCase()} at any firmware version. '
            '$backupResultText',
        reseat: false,
        finding: true,
        outputPath: backupPath,
        outputNote: backupNote,
      );
      return null;
    }

    final fw = FwVersionScanner.identify(
      bytes.sublist(Zp.slot0Offset, _slot0RegionEnd),
      model: model!,
      type: type,
    );
    _log('== ${fw.logLine} ==');

    if (fw.blocked) {
      await _finishRealAfterHold(
        false,
        '',
        'Nothing was written — this chip runs '
            '${model.toUpperCase()} $type ${fw.version}, and SHU compat does '
            'not work on that firmware. $backupResultText',
        reseat: false,
        finding: true,
        outputPath: backupPath,
        outputNote: backupNote,
      );
      return null;
    }

    if (fw.uncertain) {
      final finding = fw.verdict == FwVerdict.ambiguous
          ? 'The installed firmware gave contradictory version evidence '
                '(${fw.matches.join(', ')}).'
          : 'x3utils does not recognise the installed firmware version'
                '${modelDeclared ? ' for the $model MCU you selected' : ''}.';
      final floor = FwVersionMatrix.refusedFrom(model, type);
      final ceiling = floor == null
          ? ' x3utils has no $type version ceiling recorded at all, so it '
                'cannot tell you whether this build is affected.'
          : ' On ${model.toUpperCase()} $type, $floor and newer are known not '
                'to work.';
      final ask = _confirmUnidentified;
      final proceed = ask != null && await ask(finding, ceiling.trim());
      if (!proceed) {
        await _finishRealAfterHold(
          false,
          '',
          'Nothing was written — $finding$ceiling It stopped rather than patch '
              'a build it cannot place. $backupResultText',
          reseat: false,
          finding: true,
          outputPath: backupPath,
          outputNote: backupNote,
        );
        return null;
      }
      _log('== operator continued past an unidentified firmware version ==');
      return CompatIdentity(
        model: model,
        type: type,
        version: null,
        modelDeclared: modelDeclared,
      );
    }

    _setInstruction(
      'Installed firmware: ${model.toUpperCase()} $type ${fw.version}.',
    );
    return CompatIdentity(
      model: model,
      type: type,
      version: fw.version?.toString(),
      modelDeclared: modelDeclared,
    );
  }

  /// SHU-compat: dump the chip → patch its own firmware → flash it back
  /// (mirrors flash_compat.bat; no user .bin — uses the chip's own image).
  Future<void> _runCompat(bool guided) async {
    if (_browserMode || _androidMode) {
      await _runMemoryCompat(guided);
      return;
    }
    final (rawFinal, patched) = Firmware.newCompatPaths(prefix: backupPrefix);
    final staged = _stagedDumpPath(explicitPath: rawFinal);
    if (staged == null) return;
    _showOpenOcdProgress(eyebrow: 'Backing up');
    _setInstruction('Reading the chip before patching...');

    // Step 1 — read the current firmware.
    final d = await _runRealCore(
      HardwareRequest(
        operation: HardwareOperation.dump,
        mode: mode,
        countdown: countdownSeconds,
        filePath: staged,
      ),
      guided: guided,
      title: 'Reading current firmware…',
    );
    if (d == null) {
      _noteStagedFile(staged);
      return;
    }
    if (!_dumpConfirmed(d)) {
      await _finishRealAfterHold(
        false,
        '',
        'Could not confirm a complete chip read — nothing was changed. ${_dumpFailMessage(d)}',
        outputPath: _existingOrNull(staged),
      );
      await _offerDumpCleanup(staged);
      return;
    }
    final stageError = await _stageReturnedDumpBytes(d, staged);
    if (stageError != null) {
      _log('== backup staging FAILED: $stageError ==');
      await _finishRealAfterHold(
        false,
        '',
        'Nothing was written — $stageError',
        outputPath: _existingOrNull(staged),
      );
      await _offerDumpCleanup(staged);
      return;
    }
    final rawCheck = Firmware.inspectDump(staged);
    if (!rawCheck.ok) {
      _log('== validation FAILED: ${rawCheck.message} ==');
      await _finishRealAfterHold(
        false,
        '',
        'Nothing was written — the chip did not read back as firmware. '
            '${rawCheck.message}',
        reseat: rawCheck.verdict == DumpVerdict.incomplete,
        finding: rawCheck.isEvidence,
        outputPath: _existingOrNull(staged),
      );
      await _offerDumpCleanup(staged);
      return;
    }
    final raw = Firmware.promoteDump(staged);

    _setInstruction('Original backup saved. Preparing the patch...');
    final rawMetadataPath = _writeDumpMetadata(raw);
    _maybeSecondCopy(raw, sidecarPath: rawMetadataPath);

    // Step 1b — identify what is actually installed, BEFORE touching it.
    // Until now compat patched whatever it dumped: its only test was that the
    // file reached 0x1430. The backup is already on disk, so every refusal here
    // costs the operator nothing they wanted to keep.
    final identity = await _compatIdentityGate(
      raw,
      metadataPath: rawMetadataPath,
    );
    if (identity == null) return;

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
        outputPath: raw,
        outputMetadataPath: rawMetadataPath,
      );
      return;
    }
    _log('== patched → $patched ==');
    _showOpenOcdProgress(eyebrow: 'Patching');
    _setInstruction('SHU patch applied. Ready to flash...');
    await Future.delayed(const Duration(milliseconds: 900));

    // Snapshot and revalidate the generated image immediately before the
    // write. OpenOCD consumes [patched] while native-library backends consume
    // these exact bytes; both routes therefore use the same guarded artifact.
    late final Uint8List programBytes;
    try {
      programBytes = Uint8List.fromList(File(patched).readAsBytesSync());
    } catch (e) {
      _log('== patched snapshot FAILED: $e ==');
      await _finishRealAfterHold(
        false,
        '',
        'Patch validation failed — the chip was NOT written. '
            'The patched image could not be read: $e',
        reseat: false,
        outputPath: raw,
        outputMetadataPath: rawMetadataPath,
      );
      return;
    }
    final programCheck = Firmware.validateFullImageBytes(programBytes);
    final signatureOk =
        CompatPatch.keyState(programBytes) == FwKeyState.defaultKey;
    if (!programCheck.ok || !signatureOk) {
      final reason = !programCheck.ok
          ? programCheck.message
          : 'The SHU compatibility signature is missing at 0x1420.';
      _log('== patched snapshot validation FAILED: $reason ==');
      await _finishRealAfterHold(
        false,
        '',
        'Patch validation failed — the chip was NOT written. $reason',
        reseat: false,
        outputPath: raw,
        outputMetadataPath: rawMetadataPath,
      );
      return;
    }

    // Step 3 — flash the patched image back.
    _showOpenOcdProgress(eyebrow: 'Flashing');
    _setInstruction('Flashing it back to the chip...');
    final f = await _runRealCore(
      HardwareRequest(
        operation: HardwareOperation.flashFull,
        mode: mode,
        countdown: countdownSeconds,
        filePath: patched,
        bytes: programBytes,
      ),
      guided: guided,
      title: 'Flashing SHU-compatible firmware…',
    );
    if (f == null) return;
    _showOpenOcdProgress(eyebrow: 'Validating');
    final flashOk = _flashConfirmed(f);
    const okMsg =
        'SHU-compatible firmware flashed and verified. The original backup was saved.';
    String? zipNote;
    if (flashOk) {
      _setInstruction('SHU-compatible firmware verified.');
      // Optional, best-effort: repack the just-flashed patched image as a
      // BLE-loadable zip3. Never lets a packaging problem demote the success.
      if (compatMakeZip3 || compatMakeZip32) {
        zipNote = _maybeCompatZip3(raw, patched, identity);
      }
    }
    await _finishRealAfterHold(
      flashOk,
      okMsg,
      '${_flashFailMessage(f)} The original backup was saved.',
      outputPath: raw,
      outputNote: zipNote,
      outputMetadataPath: rawMetadataPath,
    );
  }

  /// Slot 0 occupies `0x1000`-`0xFFFF` of a full dump. Identification reads
  /// THIS REGION ONLY: slot 1 holds the OTA copy, which can be the previous
  /// firmware, and scanning both would surface two versions and refuse a
  /// perfectly normal device. Deliberately a fixed region rather than the ZP
  /// payload length — a stale ZP record must not turn identification into a
  /// failure.
  static const _slot0RegionEnd = 0x10000;

  /// Decide whether SHU compat may proceed against the firmware in [rawPath]
  /// (the backup just taken). Returns null when the run has already been
  /// finished with a failure screen.
  ///
  /// Order matters: the banner establishes model/type, GT3 is refused outright,
  /// and the version blacklist is consulted BEFORE identification, so a
  /// known-bad build refuses without depending on the known-version list being
  /// complete.
  Future<CompatIdentity?> _compatIdentityGate(
    String rawPath, {
    String? metadataPath,
  }) async {
    _setInstruction('Identifying the installed firmware...');
    final List<int> bytes;
    try {
      bytes = File(rawPath).readAsBytesSync();
    } catch (e) {
      await _finishRealAfterHold(
        false,
        '',
        'Nothing was written — the backup could not be re-read to identify the '
            'installed firmware: $e',
        reseat: false,
        outputPath: rawPath,
        outputMetadataPath: metadataPath,
      );
      return null;
    }

    final id = DeviceSpec.describeBin(bytes, slotBin: false);
    _log('== installed firmware: ${id.logLine} ==');

    final type = id.bannerType;
    if (type == null || !id.bannerSupported) {
      await _finishRealAfterHold(
        false,
        '',
        'Nothing was written — this chip is not running firmware x3utils '
            'recognises (${id.bannerLabel}). SHU compat only applies to '
            'supported ZT3, G3 and F3 firmware. The backup was saved.',
        reseat: false,
        finding: true,
        outputPath: rawPath,
        outputMetadataPath: metadataPath,
      );
      return null;
    }

    // MCU carries no model identity and the binaries differ between models, so
    // the operator declares it. We cannot check that declaration; it only
    // selects which version list to consult.
    var model = id.bannerModel;
    var modelDeclared = false;
    if (type == 'MCU') {
      // Offered models come from the matrix itself, so the picker cannot drift
      // out of sync with the lists it selects.
      final models =
          FwVersionMatrix.known.keys
              .where((k) => k.endsWith('/MCU'))
              .map((k) => k.split('/').first)
              .toList()
            ..sort();
      final ask = _askMcuModel;
      final picked = ask == null ? null : await ask(models);
      if (picked == null) {
        await _finishRealAfterHold(
          false,
          '',
          'Nothing was written — this is MCU firmware, which does not say which '
              'model it belongs to, and no model was selected. The backup was '
              'saved.',
          reseat: false,
          finding: true,
          outputPath: rawPath,
          outputMetadataPath: metadataPath,
        );
        return null;
      }
      model = picked;
      modelDeclared = true;
      _log('== operator declared MCU model: $model (not verifiable) ==');
    }

    // Applied to the declared model as well as the banner-derived one, so the
    // refusal cannot be dodged by picking it from the MCU list.
    if (FwVersionMatrix.unsupportedModels.contains(model)) {
      await _finishRealAfterHold(
        false,
        '',
        'Nothing was written — SHU compat is not supported on '
            '${model!.toUpperCase()} at any firmware version. The backup was '
            'saved.',
        reseat: false,
        finding: true,
        outputPath: rawPath,
        outputMetadataPath: metadataPath,
      );
      return null;
    }

    final fw = FwVersionScanner.identify(
      bytes.sublist(Zp.slot0Offset, _slot0RegionEnd),
      model: model!,
      type: type,
    );
    _log('== ${fw.logLine} ==');

    if (fw.blocked) {
      await _finishRealAfterHold(
        false,
        '',
        'Nothing was written — this chip runs '
            '${model.toUpperCase()} $type ${fw.version}, and SHU compat does '
            'not work on that firmware. Patching it would overwrite the key '
            'without making the scooter SHU-compatible. The backup was saved.',
        reseat: false,
        finding: true,
        outputPath: rawPath,
        outputMetadataPath: metadataPath,
      );
      return null;
    }

    if (fw.uncertain) {
      final finding = fw.verdict == FwVerdict.ambiguous
          ? 'The installed firmware gave contradictory version evidence '
                '(${fw.matches.join(', ')}).'
          : 'x3utils does not recognise the installed firmware version'
                '${modelDeclared ? ' for the $model MCU you selected' : ''}.';
      // Name the ceiling for THIS model rather than talking about ceilings in
      // the abstract: the operator is being asked to judge a version we could
      // not read, so the one number that would have decided it is the useful
      // thing to hand them.
      //
      // When no ceiling is recorded — MCU today — say THAT, rather than
      // leaving a gap where the VCU gets a number. Silence there reads as
      // reassurance; the truth is an absence of data, which is a different
      // thing and the operator should weigh it themselves.
      final floor = FwVersionMatrix.refusedFrom(model, type);
      final ceiling = floor == null
          ? ' x3utils has no $type version ceiling recorded at all, so it '
                'cannot tell you whether this build is affected.'
          : ' On ${model.toUpperCase()} $type, $floor and newer are known not '
                'to work.';
      // An unrecognised build is always the OPERATOR's call, never a silent
      // refusal and never a silent pass. A missing callback fails closed: no
      // way to ask means no way to consent.
      final ask = _confirmUnidentified;
      final proceed = ask != null && await ask(finding, ceiling.trim());
      if (!proceed) {
        await _finishRealAfterHold(
          false,
          '',
          'Nothing was written — $finding$ceiling It stopped rather than patch '
              'a build it cannot place. The backup was saved.',
          reseat: false,
          finding: true,
          outputPath: rawPath,
          outputMetadataPath: metadataPath,
        );
        return null;
      }
      _log('== operator continued past an unidentified firmware version ==');
      // No version to carry: anything named from this run says so rather than
      // inheriting a number nobody established.
      return CompatIdentity(
        model: model,
        type: type,
        version: null,
        modelDeclared: modelDeclared,
      );
    }

    _setInstruction(
      'Installed firmware: ${model.toUpperCase()} $type ${fw.version}.',
    );
    return CompatIdentity(
      model: model,
      type: type,
      version: fw.version?.toString(),
      modelDeclared: modelDeclared,
    );
  }

  /// Repack BOTH images of a compat run into BLE-loadable zip3 packages: the
  /// SHU-patched image just flashed, and the original firmware exactly as it
  /// was found. Returns a location note for the success screen, or null when
  /// neither could be built.
  ///
  /// The original is packaged because it is the only route back that does not
  /// need an ST-Link: the raw backup is a full 128 KB dump the BLE app cannot
  /// load, so without this the undo path requires the cable that compat exists
  /// to avoid needing twice.
  ///
  /// Identity comes from [identity], settled by the gate before the write: a
  /// VCU model is banner-derived, and an MCU (banner `SCOOTER_MCU_0001`, no
  /// model of its own) uses the model the operator declared at the prompt. That
  /// declaration is what now lets an MCU run pack — the packer no longer has to
  /// read a model the image does not carry. Every failure is swallowed: the
  /// compat flash already succeeded, and this extra is strictly best-effort —
  /// but a package that failed to build is NAMED rather than passed over in
  /// silence, so the operator never assumes an undo they do not have.
  String? _maybeCompatZip3(
    String rawPath,
    String patchedPath,
    CompatIdentity identity,
  ) {
    // Both packages of a run share one folder named for the run, so the two
    // clean identity filenames can repeat across runs without a later compat
    // on the same model and version overwriting an earlier scooter's stock
    // package — the one artifact that is unit-specific, since it carries that
    // board's own key.
    final Directory folder;
    try {
      folder = Directory(
        patchedPath.replaceFirst(RegExp(r'_patched\.bin$'), '_zips'),
      )..createSync(recursive: true);
    } catch (e) {
      _log('== compat zip3 skipped: could not create the zip folder: $e ==');
      return null;
    }

    final stem = identity.nameStem;
    final formats = <Zip3Format>[
      if (compatMakeZip3) Zip3Format.legacy,
      if (compatMakeZip32) Zip3Format.rev2,
    ];

    // The format token is always present, even when only one is selected: a
    // package the operator's app version cannot read is worse than a long name,
    // and 3.x/4.x users share these files with each other.
    // A package that fails to build is named in the log by _packCompatZip3.
    // Only the stock case reaches the success screen, because it is the only
    // one whose absence changes what the operator can still do.
    final built = <String>[];
    var stockBuilt = false;
    for (final format in formats) {
      final token = format == Zip3Format.legacy ? 'zip3' : 'zip32';
      for (final (suffix, src) in [
        ('compat', patchedPath),
        ('stock', rawPath),
      ]) {
        final file = _packCompatZip3(
          src,
          folder,
          '${stem}_${suffix}_$token',
          format,
          identity.type,
          identity.model,
        );
        if (file == null) continue;
        built.add(file);
        if (suffix == 'stock') stockBuilt = true;
      }
    }

    if (built.isEmpty) {
      if (folder.listSync().isEmpty) folder.deleteSync();
      return null;
    }

    // Two sentences, hard limit. Filenames, formats and per-file failures are
    // in the folder and in the log; nobody reads a paragraph on a success
    // screen. What loading a stock package does cannot be recovered from
    // either, so that is the sentence that earns its place.
    final where = folder.path.split(RegExp(r'[\\/]')).last;
    final count =
        '${built.length} package${built.length == 1 ? '' : 's'} saved in $where.';
    return stockBuilt
        ? '$count Loading a stock package restores the original key.'
        : '$count No stock package — going back needs the ST-Link.';
  }

  /// Build one zip3 from [binPath] into [folder] as `<name>.zip`, returning its
  /// filename or null.
  ///
  /// [name] is used for BOTH the filename and the package's internal
  /// displayName, so what the BLE app lists is what sits on disk — the packages
  /// are told apart in the app, not only in the file picker.
  String? _packCompatZip3(
    String binPath,
    Directory folder,
    String name,
    Zip3Format format,
    String type,
    String model,
  ) {
    try {
      final bytes = File(binPath).readAsBytesSync();
      // [type]/[model] come from the identity gate, not re-detected from the
      // image: an MCU image carries no model, so re-detection returned null and
      // an MCU run skipped. The operator declared the MCU model at the prompt;
      // a VCU model is banner-derived. buildZip3FromDump still fails closed if
      // the declared identity is unsupported or the ZP slice is missing.
      // enforceModel applies to legacy only; rev2 uses `models` and ignores it.
      final result = PackV3.buildZip3FromDump(
        bytes,
        type: type,
        model: model,
        enforceModel: true,
        displayName: name,
        format: format,
      );
      final outPath = '${folder.path}${Platform.pathSeparator}$name.zip';
      File(outPath).writeAsBytesSync(result.zipBytes);
      _log(
        '== compat zip3 ($name): ${result.model}/${result.type} · '
        '${result.payloadLength} B payload → $outPath ==',
      );
      return '$name.zip';
    } catch (e) {
      // Best-effort only — the compat flash succeeded regardless.
      _log('== compat zip3 ($name) skipped: $e ==');
      return null;
    }
  }

  /// Offline ZIP3 Slice/Pack. Slice extracts the exact slot-0 payload from a
  /// strict 128 KB backup via its ZP record. Pack treats the chosen .bin as the
  /// complete component payload, with no dump/slot/banner assumptions.
  Future<void> _runMakeZip3({ConfirmFileReplace? confirmFileReplace}) async {
    final sliceMode = zip3WorkspacePage == Zip3WorkspacePage.slice;
    final src = firmwarePath;
    if (src == null) {
      _setInputFailure(
        'No input',
        sliceMode
            ? 'Choose a 128 KB backup dump first'
            : 'Choose a firmware payload first',
        sliceMode
            ? 'Pick a full 128 KB backup .bin, then make the package.'
            : 'Pick the complete firmware .bin, then make the package.',
      );
      return;
    }
    final type = zip3Type;
    final model = zip3Model;
    if (type == null || model == null) {
      _setInputFailure(
        'Pick identity',
        'Choose the type and model',
        'Set the firmware Type and Model the package should declare.',
      );
      return;
    }
    // Re-validate at run time (the picker already did, but the file could
    // have changed on disk). Slice always requires the exact full dump; Pack
    // accepts the differing payload sizes used by VCU, MCU, BMS, and BLE.
    final v = Firmware.validateLocalBin(src, requireSize: sliceMode);
    if (!v.ok) {
      _setInputFailure('Input invalid', 'Input invalid', v.message);
      return;
    }

    final name = zip3Name.trim().isEmpty
        ? (zip3DefaultName ??
              Firmware.defaultZip3Name(model: model, type: type))
        : zip3Name.trim();
    try {
      final bytes = File(src).readAsBytesSync();
      _log(
        '== make ${zip3Format.label}: $model/$type · '
        '${sliceMode ? 'full dump' : 'payload bin'} '
        '${zip3Format == Zip3Format.legacy ? '· enforceModel=$zip3EnforceModel ' : ''}'
        '· name="$name" ==',
      );
      final Zip3BuildResult result;
      if (sliceMode) {
        result = PackV3.buildZip3FromDump(
          bytes,
          type: type,
          model: model,
          enforceModel: zip3EnforceModel,
          displayName: name,
          format: zip3Format,
        );
      } else {
        result = PackV3.buildZip3FromPayload(
          bytes,
          type: type,
          model: model,
          enforceModel: zip3EnforceModel,
          displayName: name,
          format: zip3Format,
        );
      }
      final outPath = Firmware.packedZip3Path(
        result.displayName,
        prefix: backupPrefix,
      );
      final writeResult = await writeBytesWithConfirmation(
        File(outPath),
        result.zipBytes,
        confirmReplace: confirmFileReplace,
      );
      if (writeResult == ConfirmedWriteResult.cancelled) {
        _log('== make zip3 cancelled: existing package kept → $outPath ==');
        return;
      }
      _log(
        '== packed ${result.format.label} ${result.model}/${result.type} · '
        '${result.payloadLength} B payload → $outPath ==',
      );
      _finishReal(
        true,
        '${result.format.label} created · ${result.model.toUpperCase()} · '
            '${result.type} · ${result.payloadLength} bytes',
        '',
        reseat: false,
        outputPath: outPath,
      );
    } on FormatException catch (e) {
      // Slice's ZP guard and Pack's metadata validation fail closed through
      // here.
      _log('== make zip3 failed: ${e.message} ==');
      _finishReal(false, '', e.message, reseat: false);
    } catch (e) {
      _log('== make zip3 error: $e ==');
      _finishReal(false, '', 'Could not create the package: $e', reseat: false);
    }
  }

  /// Offline standalone ZIP3 unpack: re-read the selected package, prove it is
  /// unchanged and still valid, then write its plaintext firmware under
  /// the operator's filename. Existing files are never silently overwritten.
  Future<void> _runUnpackZip3({ConfirmFileReplace? confirmFileReplace}) async {
    final src = _unpackZip3Path;
    if (src == null || _unpackZip3Package == null) {
      _setInputFailure(
        'No package',
        'Choose a zip3 package first',
        'Pick a zip3 or zip3.2 package, then choose its output filename.',
      );
      return;
    }
    final nameCheck = Firmware.validateUnpackedFilename(unpackOutputName);
    if (!nameCheck.ok) {
      _setInputFailure(
        'Filename invalid',
        'Choose a valid output filename',
        nameCheck.message,
      );
      return;
    }
    final containerCheck = Firmware.validateZip3Container(
      src,
      enforceFlashSizeLimit: false,
    );
    if (!containerCheck.ok) {
      _setInputFailure(
        'Package invalid',
        'Package invalid',
        containerCheck.message,
      );
      return;
    }

    try {
      final bytes = await File(src).readAsBytes();
      final digest = crypto.sha256.convert(bytes).toString();
      if (_unpackZip3Digest == null || digest != _unpackZip3Digest) {
        _setInputFailure(
          'Package changed',
          'Choose the package again',
          'The selected ZIP3 changed after it was inspected.',
        );
        return;
      }
      final pkg = PackV3.unpackV3(bytes, policy: Zip3UnpackPolicy.extract);
      final outPath = Firmware.unpackedBinPath(unpackOutputName);
      _log(
        '== unpack zip3: ${pkg.model}/${pkg.type} · '
        '${pkg.firmware.length} bytes → $outPath ==',
      );
      final writeResult = await writeBytesWithConfirmation(
        File(outPath),
        pkg.firmware,
        confirmReplace: confirmFileReplace,
      );
      if (writeResult == ConfirmedWriteResult.cancelled) {
        _log('== unpack zip3 cancelled: existing file kept → $outPath ==');
        return;
      }
      _log('== unpacked ${pkg.displayName} → $outPath ==');
      _finishReal(
        true,
        'Firmware unpacked · ${pkg.model.toUpperCase()} · '
            '${pkg.type.toUpperCase()} · ${pkg.firmware.length} bytes',
        '',
        reseat: false,
        outputPath: outPath,
      );
    } on FormatException catch (e) {
      _log('== unpack zip3 failed: ${e.message} ==');
      _finishReal(false, '', e.message, reseat: false);
    } catch (e) {
      _log('== unpack zip3 error: $e ==');
      _finishReal(false, '', 'Could not unpack the package: $e', reseat: false);
    }
  }
}
