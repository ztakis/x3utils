import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'app_controller.dart';
import 'engine/firmware.dart';
import 'engine/firmware_inspection.dart';
import 'engine/trash.dart';
import 'models.dart';
import 'theme.dart';
import 'widgets/desktop_path_display.dart';

void main() => runApp(const X3UtilsApp());

class X3UtilsApp extends StatelessWidget {
  const X3UtilsApp({super.key});
  @override
  Widget build(BuildContext context) {
    // Rebuild the whole app (theme + tree) when the accent theme changes.
    return ValueListenableBuilder<int>(
      valueListenable: accentNotifier,
      builder: (context, idx, _) {
        AppColors.applyAccent(idx);
        return MaterialApp(
          title: 'x3utils',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(),
          home: HomeScreen(), // non-const so accent changes rebuild the tree
        );
      },
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final AppController c = AppController();

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  Future<void> _onStart() async {
    final a = c.action;
    if (a.id == 'flash_only') {
      final refreshed = c.refreshFlashOnlyInspection();
      if (!refreshed.ok) {
        // Let the normal Start path place a changed/invalid selection in the
        // hero failure state. Do not show compatibility evidence for stale
        // bytes.
        await c.start(
          confirmFileReplace: _showZip3ReplaceConfirm,
          confirmTrash: _showTrashConfirm,
        );
        return;
      }
      final ok = await _showFlashOnlyConfirm();
      if (ok != true) return;
    } else if (a.danger != DangerLevel.none) {
      final ok = await _showConfirm(a);
      if (ok != true) return;
    }
    await c.start(
      confirmFileReplace: _showZip3ReplaceConfirm,
      confirmTrash: _showTrashConfirm,
    );
  }

  /// Offered after a read that did not become a backup. The file is already
  /// named `.part`, so nothing can mistake it for a backup — this is about
  /// sweeping it out of the folder, and it goes to the OS trash so the choice
  /// stays reversible.
  Future<bool> _showTrashConfirm(
    String path,
    String title,
    String reason,
  ) async {
    final where = Trash.label;
    final move = await showDialog<bool>(
      context: context,
      barrierColor: const Color(0xB3040A0F),
      builder: (ctx) => Dialog(
        backgroundColor: AppColors.panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: AppColors.line2),
        ),
        child: Container(
          width: 460,
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: AppColors.hold.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.delete_outline_rounded,
                  color: AppColors.hold,
                  size: 24,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppColors.txt,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                reason,
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: AppColors.dim,
                ),
              ),
              const SizedBox(height: 8),
              DesktopPathDisplay(path: path, action: DesktopPathAction.none),
              const SizedBox(height: 12),
              Text(
                'Moving it to the $where keeps it recoverable — nothing is '
                'deleted. Keeping it is fine too; it can never be flashed.',
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: AppColors.dim,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _PillButton(
                    label: 'Keep it',
                    onTap: () => Navigator.pop(ctx, false),
                    bg: AppColors.line,
                    fg: AppColors.txt,
                    border: AppColors.line2,
                    small: true,
                  ),
                  const SizedBox(width: 10),
                  _PillButton(
                    label: 'Move to $where',
                    onTap: () => Navigator.pop(ctx, true),
                    gradient: [AppColors.brand, AppColors.brand2],
                    fg: const Color(0xFF04120F),
                    small: true,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    return move == true;
  }

  Future<bool> _showZip3ReplaceConfirm(String path) async {
    final replace = await showDialog<bool>(
      context: context,
      barrierColor: const Color(0xB3040A0F),
      builder: (ctx) => Dialog(
        backgroundColor: AppColors.panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: AppColors.line2),
        ),
        child: Container(
          width: 440,
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: AppColors.danger.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.warning_amber_rounded,
                  color: AppColors.danger,
                  size: 24,
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'Replace existing file?',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppColors.txt,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'A file already exists at this exact path:',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: AppColors.dim,
                ),
              ),
              const SizedBox(height: 8),
              DesktopPathDisplay(path: path, action: DesktopPathAction.none),
              const SizedBox(height: 12),
              const Text(
                'Replace will permanently overwrite the existing file.',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: AppColors.hold,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _PillButton(
                    label: 'Cancel',
                    onTap: () => Navigator.pop(ctx, false),
                    bg: AppColors.line,
                    fg: AppColors.txt,
                    border: AppColors.line2,
                    small: true,
                  ),
                  const SizedBox(width: 10),
                  _PillButton(
                    label: 'Replace',
                    onTap: () => Navigator.pop(ctx, true),
                    gradient: const [Color(0xFFFF6472), AppColors.danger],
                    fg: Colors.white,
                    small: true,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    return replace == true;
  }

  /// CLI muscle-memory: Enter fires the primary CTA for the current stage
  /// (Start / guided Continue / Done / Retry). Running stages ignore it, so
  /// Enter can never cancel a flash mid-write.
  void _onEnter() {
    switch (c.stage) {
      case StageState.idle:
        if (c.canStart) _onStart();
        break;
      case StageState.hold:
      case StageState.release:
      case StageState.connect:
      case StageState.run:
        if (c.showContinue) c.continueStep();
        break;
      case StageState.ok:
      case StageState.warn:
        c.dismiss();
        break;
      case StageState.fail:
        // Auto-retry makes the primary inert, so Enter must not fire it either.
        if (!c.autoRetryArmed) c.retry();
        break;
      case StageState.count:
        break;
    }
  }

  Future<void> _pickFirmware() async {
    const group = XTypeGroup(label: 'firmware', extensions: ['bin']);
    final file = await openFile(acceptedTypeGroups: [group]);
    if (file == null) return;
    // The controller validates for the current kind (plus the mainstream
    // banner gate) and remembers the bin + its identity note on success.
    final check = c.selectFirmwareBin(file.path);
    if (!check.ok) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              check.message,
              style: const TextStyle(color: Colors.white),
            ),
            backgroundColor: AppColors.danger,
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
  }

  /// Slot-0 only: load a v3 firmware .zip — the controller validates the
  /// package, decrypts the payload, and remembers the extracted slot bin.
  Future<void> _pickFirmwareZip() async {
    const group = XTypeGroup(label: 'v3 package', extensions: ['zip']);
    final file = await openFile(acceptedTypeGroups: [group]);
    if (file == null) return;
    final res = await c.loadSlotFirmwareFromZip(file.path);
    if (!mounted) return;
    // Two states: loaded → green, rejected (bad model/type/banner) → red.
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            res.ok ? res.message : 'Package rejected: ${res.message}',
            style: const TextStyle(color: Colors.white),
          ),
          backgroundColor: res.ok ? AppColors.ok : AppColors.danger,
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  /// Standalone offline unpack: inspect a ZIP3 and populate its package details.
  /// No output is written until the operator presses Unpack zip3.
  Future<void> _pickUnpackZip() async {
    const group = XTypeGroup(label: 'v3 package', extensions: ['zip']);
    final file = await openFile(acceptedTypeGroups: [group]);
    if (file == null) return;
    final res = await c.selectZip3ForUnpack(file.path);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            res.ok ? res.message : 'Package rejected: ${res.message}',
            style: const TextStyle(color: Colors.white),
          ),
          backgroundColor: res.ok ? AppColors.ok : AppColors.danger,
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Future<bool?> _showConfirm(FlashAction a) {
    final hard = a.danger == DangerLevel.hard;
    final accent = hard ? AppColors.danger : AppColors.brand;
    return showDialog<bool>(
      context: context,
      barrierColor: const Color(0xB3040A0F),
      builder: (ctx) => Dialog(
        backgroundColor: AppColors.panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: AppColors.line2),
        ),
        child: Container(
          width: 400,
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  hard ? Icons.warning_amber_rounded : Icons.bolt,
                  color: accent,
                  size: 24,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                hard ? 'Heads up — this is destructive' : 'Confirm ${a.name}',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppColors.txt,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _confirmBody(a),
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: AppColors.dim,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _PillButton(
                    label: 'Cancel',
                    onTap: () => Navigator.pop(ctx, false),
                    bg: AppColors.line,
                    fg: AppColors.txt,
                    border: AppColors.line2,
                    small: true,
                  ),
                  const SizedBox(width: 10),
                  _PillButton(
                    label: hard ? 'I understand — continue' : 'Continue',
                    onTap: () => Navigator.pop(ctx, true),
                    gradient: hard
                        ? const [Color(0xFFFF6472), AppColors.danger]
                        : [AppColors.brand, AppColors.brand2],
                    fg: hard ? Colors.white : const Color(0xFF04120F),
                    small: true,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<bool?> _showFlashOnlyConfirm() {
    final report = c.firmwareInspection;
    return showDialog<bool>(
      context: context,
      barrierColor: const Color(0xB3040A0F),
      builder: (ctx) {
        Widget sectionTitle(String text) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
              color: AppColors.hold,
            ),
          ),
        );

        Widget evidenceRow(String label, String value, {String? detail}) =>
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.dim,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    value,
                    style: const TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      color: AppColors.txt,
                    ),
                  ),
                  if (detail != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: AppColors.dim,
                      ),
                    ),
                  ],
                ],
              ),
            );

        Widget finding(CompatibilityFinding item) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 7),
                child: Icon(Icons.circle, size: 5, color: AppColors.hold),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  item.message,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.45,
                    color: AppColors.txt,
                  ),
                ),
              ),
            ],
          ),
        );

        Widget plainBullet(String text) =>
            finding(CompatibilityFinding('not_checked', text));

        return Dialog(
          backgroundColor: AppColors.panel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: AppColors.line2),
          ),
          child: Container(
            width: 600,
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.80,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          color: AppColors.hold.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                          Icons.warning_amber_rounded,
                          color: AppColors.hold,
                          size: 25,
                        ),
                      ),
                      const SizedBox(width: 14),
                      const Expanded(
                        child: Text(
                          'Compatibility warning',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: AppColors.txt,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Flexible(
                    child: Scrollbar(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.only(right: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            sectionTitle('OBSERVED IN THE SELECTED FILE'),
                            if (report?.packageClaim != null)
                              evidenceRow(
                                'Package claim',
                                report!.packageClaim!.label,
                              ),
                            evidenceRow(
                              'Banner',
                              report?.bannerValue ?? 'Unavailable',
                            ),
                            evidenceRow(
                              'Serial',
                              report?.serialValue ?? 'Unavailable',
                            ),
                            evidenceRow(
                              'ZP record',
                              report?.zpValue ?? 'Unavailable',
                              detail: report?.zpDetail,
                            ),
                            if (report != null &&
                                report.findings.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              sectionTitle(
                                'FINDINGS (${report.findings.length})',
                              ),
                              for (final item in report.findings) finding(item),
                            ],
                            const SizedBox(height: 6),
                            sectionTitle('NOT CHECKED'),
                            plainBullet(
                              'Compatibility with the connected controller.',
                            ),
                            plainBullet(
                              'Other firmware correctness or hardware suitability.',
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              'Flash Only will not create a backup.',
                              style: TextStyle(
                                fontSize: 13,
                                height: 1.45,
                                fontWeight: FontWeight.w700,
                                color: AppColors.hold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      _PillButton(
                        label: 'Cancel',
                        onTap: () => Navigator.pop(ctx, false),
                        bg: AppColors.line,
                        fg: AppColors.txt,
                        border: AppColors.line2,
                        small: true,
                      ),
                      const SizedBox(width: 10),
                      _PillButton(
                        label: 'Flash anyway',
                        onTap: () => Navigator.pop(ctx, true),
                        gradient: const [Color(0xFFFFC247), AppColors.hold],
                        fg: const Color(0xFF211600),
                        small: true,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _confirmBody(FlashAction a) => switch (a.id) {
    'flash_only' =>
      'No backup is taken and the target-match guard is skipped — nothing checks that this firmware belongs on this controller. If the write goes wrong there is nothing to restore from. Only continue if you already have a good dump and you are sure about the target.',
    'flash_slot0' =>
      'Only application slot 0 is erased and written. The bootloader and identity block stay untouched.',
    'flash_backup' =>
      'A full 128 KB backup runs first, then your firmware is written and verified. Keep the wires steady the whole time.',
    'flash_compat' =>
      'Backs up the chip, patches its own firmware for SHU compatibility, and flashes it back. The original is saved first. Keep the wires steady.',
    'rdp_rescue' =>
      'Clearing read protection triggers a full mass-erase — all firmware is wiped. Uses the deterministic option-byte rewrite. Continue only on a chip you accept erasing.',
    _ => a.sub,
  };

  void _showSettings() {
    showDialog(
      context: context,
      barrierColor: const Color(0xB3040A0F),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => Dialog(
          backgroundColor: AppColors.panel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: AppColors.line2),
          ),
          child: Container(
            width: 460,
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.85,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.settings_rounded,
                        color: AppColors.brand,
                        size: 22,
                      ),
                      SizedBox(width: 10),
                      Text(
                        'Settings',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: AppColors.txt,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Flexible(
                    child: Scrollbar(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.only(right: 10),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _SettingRow(
                              label: 'Default connection',
                              child: _ModeDropdown(
                                c: c,
                                onChanged: () => setLocal(() {}),
                              ),
                            ),
                            const SizedBox(height: 14),
                            _SettingRow(
                              label: 'Hold countdown',
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _StepBtn(
                                    icon: Icons.remove,
                                    onTap: () {
                                      c.setDefaultCountdown(
                                        c.defaultCountdown - 1,
                                      );
                                      setLocal(() {});
                                    },
                                  ),
                                  SizedBox(
                                    width: 30,
                                    child: Text(
                                      '${c.defaultCountdown}',
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        fontFamily: kMono,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.txt,
                                      ),
                                    ),
                                  ),
                                  _StepBtn(
                                    icon: Icons.add,
                                    onTap: () {
                                      c.setDefaultCountdown(
                                        c.defaultCountdown + 1,
                                      );
                                      setLocal(() {});
                                    },
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 14),
                            _SettingRow(
                              label: 'Auto-retry',
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _StepBtn(
                                    icon: Icons.remove,
                                    onTap: () {
                                      c.setDefaultAutoRetry(
                                        c.defaultAutoRetry - 1,
                                      );
                                      setLocal(() {});
                                    },
                                  ),
                                  SizedBox(
                                    width: 30,
                                    child: Text(
                                      c.defaultAutoRetry == 0
                                          ? 'off'
                                          : '${c.defaultAutoRetry}',
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        fontFamily: kMono,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.txt,
                                      ),
                                    ),
                                  ),
                                  _StepBtn(
                                    icon: Icons.add,
                                    onTap: () {
                                      c.setDefaultAutoRetry(
                                        c.defaultAutoRetry + 1,
                                      );
                                      setLocal(() {});
                                    },
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 14),
                            _SettingRow(
                              label: 'Theme accent',
                              child: _AccentPicker(
                                c: c,
                                onChanged: () => setLocal(() {}),
                              ),
                            ),
                            const Divider(color: AppColors.line, height: 28),
                            _BackupSettingsSection(c: c),
                            const Divider(color: AppColors.line, height: 28),
                            Text(
                              'x3utils  ·  v$kAppVersionLabel',
                              style: const TextStyle(
                                color: AppColors.dim,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'Engine: bundled OpenOCD (frozen) · AT32F415',
                              style: TextStyle(
                                color: AppColors.mut,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Align(
                    alignment: Alignment.centerRight,
                    child: _PillButton(
                      label: 'Done',
                      onTap: () => Navigator.pop(ctx),
                      gradient: [AppColors.brand, AppColors.brand2],
                      fg: const Color(0xFF04120F),
                      small: true,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Enter fires the current stage's primary CTA (see _onEnter) so the
      // guided C45 "Continue" answers OpenOCD's stdin like the CLI's Enter.
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.enter): _onEnter,
          const SingleActivator(LogicalKeyboardKey.numpadEnter): _onEnter,
        },
        child: Focus(
          autofocus: true,
          child: ListenableBuilder(
            listenable: c,
            builder: (context, _) => Column(
              children: [
                _TitleBar(c: c, onSettings: _showSettings),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final maxH = constraints.maxHeight;
                      final double h = c.consoleHeight
                          .clamp(140.0, math.max(140.0, maxH - 100))
                          .toDouble();
                      final mainRow = Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _Rail(c: c),
                          Expanded(
                            child: _MainArea(
                              c: c,
                              onStart: _onStart,
                              onPickFirmware: _pickFirmware,
                              onPickZip: _pickFirmwareZip,
                              onPickUnpackZip: _pickUnpackZip,
                            ),
                          ),
                        ],
                      );

                      // Pinned → dock alongside (pushes content up, stays put).
                      if (c.consoleOpen && c.consolePinned) {
                        return Column(
                          children: [
                            Expanded(child: mainRow),
                            _ConsolePanel(
                              c: c,
                              height: h,
                              maxHeight: maxH,
                              docked: true,
                            ),
                          ],
                        );
                      }

                      // Unpinned → float over, but reserve its height so the hero
                      // centers ABOVE it instead of being hidden behind it.
                      return Stack(
                        children: [
                          Padding(
                            padding: EdgeInsets.only(
                              bottom: c.consoleOpen && !c.consolePinned ? h : 0,
                            ),
                            child: mainRow,
                          ),
                          if (c.consoleOpen && !c.consolePinned)
                            Positioned(
                              left: 0,
                              right: 0,
                              top: 0,
                              bottom: h,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: c.toggleConsole,
                              ),
                            ),
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: AnimatedSlide(
                              offset: c.consoleOpen
                                  ? Offset.zero
                                  : const Offset(0, 1),
                              duration: const Duration(milliseconds: 300),
                              curve: Curves.easeOutCubic,
                              child: _ConsolePanel(
                                c: c,
                                height: h,
                                maxHeight: maxH,
                                docked: false,
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────── title bar

class _TitleBar extends StatelessWidget {
  const _TitleBar({required this.c, required this.onSettings});
  final AppController c;
  final VoidCallback onSettings;
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 54,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: const BoxDecoration(
        color: AppColors.bg2,
        border: Border(bottom: BorderSide(color: AppColors.line)),
      ),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              gradient: SweepGradient(
                colors: [
                  AppColors.brand,
                  AppColors.brand2,
                  AppColors.pop,
                  AppColors.brand,
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: AppColors.brand.withValues(alpha: 0.5),
                  blurRadius: 18,
                ),
              ],
            ),
            child: const Icon(Icons.bolt, size: 16, color: Color(0xFF04120F)),
          ),
          const SizedBox(width: 11),
          const Text(
            'x3utils',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AppColors.txt,
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: AppColors.brand.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: AppColors.brand.withValues(alpha: 0.35),
              ),
            ),
            child: Text(
              'v$kAppVersionLabel',
              style: TextStyle(
                fontFamily: kMono,
                fontSize: 11,
                color: AppColors.brand,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const Spacer(),
          const Text(
            'AT32F415 · X3 controller',
            style: TextStyle(fontSize: 12, color: AppColors.mut),
          ),
          const SizedBox(width: 8),
          _BarIconButton(
            icon: Icons.terminal_rounded,
            tooltip: c.consoleOpen ? 'Hide console' : 'Show console',
            active: c.consoleOpen,
            onTap: c.toggleConsole,
          ),
          _BarIconButton(
            icon: Icons.settings_rounded,
            tooltip: 'Settings',
            onTap: onSettings,
          ),
          _TitleMenu(c: c, onSettings: onSettings),
        ],
      ),
    );
  }
}

class _BarIconButton extends StatelessWidget {
  const _BarIconButton({
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.active = false,
  });
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final bool active;
  @override
  Widget build(BuildContext context) => IconButton(
    onPressed: onTap,
    icon: Icon(icon, size: 18),
    color: active ? AppColors.brand : AppColors.dim,
    tooltip: tooltip,
    visualDensity: VisualDensity.compact,
    padding: const EdgeInsets.all(6),
    constraints: const BoxConstraints(),
  );
}

class _TitleMenu extends StatelessWidget {
  const _TitleMenu({required this.c, required this.onSettings});
  final AppController c;
  final VoidCallback onSettings;
  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.menu_rounded, size: 18, color: AppColors.dim),
      tooltip: 'Menu',
      color: AppColors.panel2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.line2),
      ),
      onSelected: (v) {
        switch (v) {
          case 'console':
            c.toggleConsole();
          case 'settings':
            onSettings();
          case 'about':
            showAboutDialog(
              context: context,
              applicationName: 'x3utils',
              applicationVersion: 'v$kAppVersionLabel',
              applicationLegalese:
                  'ST-LINK utilities for X3 scooters · AT32F415 · bundled OpenOCD',
            );
        }
      },
      itemBuilder: (_) => [
        _mi(
          'console',
          Icons.terminal_rounded,
          c.consoleOpen ? 'Hide console' : 'Show console',
        ),
        _mi('settings', Icons.settings_rounded, 'Settings…'),
        const PopupMenuDivider(),
        _mi('about', Icons.info_outline_rounded, 'About'),
      ],
    );
  }

  PopupMenuItem<String> _mi(String v, IconData i, String t) => PopupMenuItem(
    value: v,
    height: 40,
    child: Row(
      children: [
        Icon(i, size: 16, color: AppColors.dim),
        const SizedBox(width: 10),
        Text(t, style: const TextStyle(color: AppColors.txt, fontSize: 13)),
      ],
    ),
  );
}

// ─────────────────────────────────────────── left rail

class _Rail extends StatelessWidget {
  const _Rail({required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 268,
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
      decoration: const BoxDecoration(
        border: Border(right: BorderSide(color: AppColors.line)),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _RailLabel('Connection'),
            for (final m in c.modesIn(Section.standard))
              _ModeTile(c: c, mode: m),
            if (c.mode.guided) ...[
              const SizedBox(height: 8),
              _CountdownStepper(c: c),
            ],
            const SizedBox(height: 20),
            const _RailLabel('Actions'),
            for (final a in kActions.where(
              (a) => a.section == Section.standard,
            ))
              _ActionTile(c: c, action: a),
            const SizedBox(height: 14),
            _AdvancedToggle(c: c),
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: c.advancedOpen
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 6),
                        for (final m in c.modesIn(Section.advanced))
                          _ModeTile(c: c, mode: m),
                        for (final a in kActions.where(
                          (a) => a.section == Section.advanced,
                        ))
                          _ActionTile(c: c, action: a),
                      ],
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }
}

class _RailLabel extends StatelessWidget {
  const _RailLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(2, 4, 2, 8),
    child: Text(
      text.toUpperCase(),
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.6,
        color: AppColors.mut,
      ),
    ),
  );
}

class _AdvancedToggle extends StatelessWidget {
  const _AdvancedToggle({required this.c});
  final AppController c;
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: c.toggleAdvanced,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(2, 4, 2, 6),
          child: Row(
            children: [
              const Text(
                'ADVANCED',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.6,
                  color: AppColors.mut,
                ),
              ),
              const SizedBox(width: 7),
              Icon(
                c.advancedOpen
                    ? Icons.lock_open_rounded
                    : Icons.lock_outline_rounded,
                size: 12,
                color: AppColors.mut,
              ),
              const Spacer(),
              AnimatedRotation(
                turns: c.advancedOpen ? 0.5 : 0,
                duration: const Duration(milliseconds: 200),
                child: const Icon(
                  Icons.expand_more_rounded,
                  size: 18,
                  color: AppColors.dim,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeTile extends StatelessWidget {
  const _ModeTile({required this.c, required this.mode});
  final AppController c;
  final ConnectionMode mode;

  Future<void> _showModeMenu(BuildContext context, Offset pos) async {
    if (c.running) return;
    final inAdvanced = c.sectionOf(mode) == Section.advanced;
    // The last mode in the standard group can't be moved out -> no menu (nothing).
    if (!inAdvanced && !c.canMoveToAdvanced(mode)) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final target = await showMenu<Section>(
      context: context,
      position: RelativeRect.fromRect(
        pos & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          value: inAdvanced ? Section.standard : Section.advanced,
          child: Text(inAdvanced ? 'Move to Main' : 'Move to Advanced'),
        ),
      ],
    );
    if (target != null) c.moveMode(mode, target);
  }

  @override
  Widget build(BuildContext context) {
    final selected = c.mode == mode;
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Material(
        color: selected
            ? AppColors.brand.withValues(alpha: 0.08)
            : AppColors.panel,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => c.selectMode(mode),
          onSecondaryTapDown: (d) => _showModeMenu(context, d.globalPosition),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected
                    ? AppColors.brand.withValues(alpha: 0.55)
                    : AppColors.line,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected ? AppColors.brand : const Color(0x0DFFFFFF),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: selected ? Colors.transparent : AppColors.line,
                    ),
                  ),
                  child: Text(
                    mode.tag,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                      color: selected ? const Color(0xFF04120F) : AppColors.dim,
                    ),
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        mode.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppColors.txt,
                        ),
                      ),
                      Text(
                        mode.sub,
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.dim,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CountdownStepper extends StatelessWidget {
  const _CountdownStepper({required this.c});
  final AppController c;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.line2),
      ),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'Hold countdown',
              style: TextStyle(fontSize: 12, color: AppColors.dim),
            ),
          ),
          _StepBtn(
            icon: Icons.remove,
            onTap: () => c.setCountdown(c.countdownSeconds - 1),
          ),
          SizedBox(
            width: 30,
            child: Text(
              '${c.countdownSeconds}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: kMono,
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: AppColors.txt,
              ),
            ),
          ),
          _StepBtn(
            icon: Icons.add,
            onTap: () => c.setCountdown(c.countdownSeconds + 1),
          ),
        ],
      ),
    );
  }
}

class _StepBtn extends StatelessWidget {
  const _StepBtn({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    shape: const CircleBorder(),
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(icon, size: 16, color: AppColors.txt),
      ),
    ),
  );
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({required this.c, required this.action});
  final AppController c;
  final FlashAction action;

  @override
  Widget build(BuildContext context) {
    final selected = c.actionId == action.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Stack(
        children: [
          Material(
            color: selected ? AppColors.panel2 : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () async {
                // Firmware-sensitive and destructive actions are gated every
                // time they are entered; re-clicking the selected tile is not
                // re-entry.
                if (action.id == 'flash_compat' && c.actionId != action.id) {
                  final ok = await _showShuCompatWarning(context);
                  if (ok != true) return;
                } else if (action.id == 'flash_only' &&
                    c.actionId != action.id) {
                  final ok = await _showFlashOnlyWarning(context);
                  if (ok != true) return;
                } else if (action.id == 'rdp_rescue' &&
                    c.actionId != action.id) {
                  final ok = await _showRescueWarning(context);
                  if (ok != true) return;
                }
                c.selectAction(action.id);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: selected ? AppColors.line2 : Colors.transparent,
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: action.danger.dot,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            action.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppColors.txt,
                            ),
                          ),
                          Text(
                            action.script,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: kMono,
                              fontSize: 11,
                              color: AppColors.dim,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (selected)
            Positioned(
              left: 0,
              top: 8,
              bottom: 8,
              child: Container(
                width: 3,
                decoration: BoxDecoration(
                  color: AppColors.brand,
                  borderRadius: BorderRadius.circular(3),
                  boxShadow: [
                    BoxShadow(color: AppColors.brand, blurRadius: 10),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────── main area

class _MainArea extends StatefulWidget {
  const _MainArea({
    required this.c,
    required this.onStart,
    required this.onPickFirmware,
    required this.onPickZip,
    required this.onPickUnpackZip,
  });
  final AppController c;
  final Future<void> Function() onStart;
  final Future<void> Function() onPickFirmware;
  final Future<void> Function() onPickZip;
  final Future<void> Function() onPickUnpackZip;

  @override
  State<_MainArea> createState() => _MainAreaState();
}

class _MainAreaState extends State<_MainArea> {
  final PageController _zip3Pages = PageController();
  late String _lastActionId = widget.c.actionId;
  late StageState _lastStage = widget.c.stage;

  @override
  void dispose() {
    _zip3Pages.dispose();
    super.dispose();
  }

  void _setZip3Page(Zip3WorkspacePage page) {
    widget.c.setZip3WorkspacePage(page);
    if (!_zip3Pages.hasClients) return;
    _zip3Pages.animateToPage(
      page.index,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeInOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final a = c.action;
    if (_lastActionId != c.actionId) {
      _lastActionId = c.actionId;
      if (c.actionId == 'make_zip3') {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _zip3Pages.hasClients) _zip3Pages.jumpToPage(0);
        });
      }
    }
    if (_lastStage != c.stage) {
      final returnedToIdle =
          _lastStage != StageState.idle &&
          c.stage == StageState.idle &&
          c.actionId == 'make_zip3';
      _lastStage = c.stage;
      if (returnedToIdle) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _zip3Pages.hasClients) {
            _zip3Pages.jumpToPage(c.zip3WorkspacePage.index);
          }
        });
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      a.name,
                      style: const TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w700,
                        color: AppColors.txt,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      a.sub,
                      style: const TextStyle(
                        fontSize: 13,
                        height: 1.45,
                        color: AppColors.dim,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 300),
                child: a.id == 'make_zip3'
                    ? _Zip3WorkspaceSwitch(c: c, onChanged: _setZip3Page)
                    : Wrap(
                        alignment: WrapAlignment.end,
                        spacing: 6,
                        runSpacing: 6,
                        children: [for (final ch in a.chips) _Chip(ch)],
                      ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _HeroStage(
            c: c,
            zip3Pages: _zip3Pages,
            onStart: widget.onStart,
            onPickFirmware: widget.onPickFirmware,
            onPickZip: widget.onPickZip,
            onPickUnpackZip: widget.onPickUnpackZip,
          ),
        ),
        _StatusBar(c: c),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.data);
  final InfoChipData data;
  @override
  Widget build(BuildContext context) {
    final col = data.kind.color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: col.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: col.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: col, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            data.label.toUpperCase(),
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: col,
            ),
          ),
        ],
      ),
    );
  }
}

class _Zip3WorkspaceSwitch extends StatelessWidget {
  const _Zip3WorkspaceSwitch({required this.c, required this.onChanged});
  final AppController c;
  final ValueChanged<Zip3WorkspacePage> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 49,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0x30000000),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _item('SLICE', Zip3WorkspacePage.slice),
          _item('PACK', Zip3WorkspacePage.pack),
          _item('UNPACK', Zip3WorkspacePage.unpack),
        ],
      ),
    );
  }

  Widget _item(String label, Zip3WorkspacePage page) {
    final selected = c.zip3WorkspacePage == page;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('zip3-${page.name}'),
        onTap: c.running ? null : () => onChanged(page),
        borderRadius: BorderRadius.circular(999),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.ok.withValues(alpha: 0.16)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected
                  ? AppColors.ok.withValues(alpha: 0.7)
                  : Colors.transparent,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.9,
              color: selected ? AppColors.ok : AppColors.dim,
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────── hero stage

class _HeroStage extends StatefulWidget {
  const _HeroStage({
    required this.c,
    required this.zip3Pages,
    required this.onStart,
    required this.onPickFirmware,
    required this.onPickZip,
    required this.onPickUnpackZip,
  });
  final AppController c;
  final PageController zip3Pages;
  final Future<void> Function() onStart;
  final Future<void> Function() onPickFirmware;
  final Future<void> Function() onPickZip;
  final Future<void> Function() onPickUnpackZip;
  @override
  State<_HeroStage> createState() => _HeroStageState();
}

class _HeroStageState extends State<_HeroStage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final accent = c.stage.accent;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.line),
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.panel, AppColors.bg2],
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 300,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(18),
                  ),
                  gradient: RadialGradient(
                    center: Alignment.topCenter,
                    radius: 1.1,
                    colors: [
                      accent.withValues(
                        alpha: c.stage == StageState.idle ? 0.05 : 0.16,
                      ),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: Column(
                children: [
                  Expanded(
                    child:
                        c.actionId == 'make_zip3' && c.stage == StageState.idle
                        ? PageView(
                            controller: widget.zip3Pages,
                            scrollDirection: Axis.vertical,
                            physics: const NeverScrollableScrollPhysics(),
                            allowImplicitScrolling: false,
                            children: [
                              KeyedSubtree(
                                key: const ValueKey('zip3-slice-page'),
                                child: _buildStagePage(c, accent),
                              ),
                              KeyedSubtree(
                                key: const ValueKey('zip3-pack-page'),
                                child: _buildStagePage(c, accent),
                              ),
                              _UnpackZip3Page(
                                c: c,
                                onPick: widget.onPickUnpackZip,
                                onStart: widget.onStart,
                              ),
                            ],
                          )
                        : _buildStagePage(c, accent),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStagePage(AppController c, Color accent) {
    // Optical center: nudge the stack up from true middle so it reads as
    // balanced. Tall pages still fill and scroll inside their own viewport.
    return Align(
      alignment: const Alignment(0, -0.08),
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 18, 28, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  c.heroEyebrow.toUpperCase(),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2.8,
                    color: c.stage == StageState.idle ? c.stakesColor : accent,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  c.heroTitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                    height: 1.08,
                    color: AppColors.txt,
                  ),
                ),
                const SizedBox(height: 12),
                _HeroMessage(
                  text: c.heroMessage,
                  color: c.heroMessageWarn
                      ? AppColors.hold
                      : c.stage == StageState.fail
                      ? AppColors.danger
                      : c.messageTone.color,
                  callout:
                      c.heroMessageWarn ||
                      c.heroMessage.length > 96 ||
                      c.heroMessage.contains('\n'),
                  icon: c.heroMessageWarn
                      ? Icons.warning_amber_rounded
                      : Icons.info_outline_rounded,
                ),
                if (c.resultNote != null) ...[
                  const SizedBox(height: 14),
                  _HeroMessage(
                    text: 'Note: ${c.resultNote!}',
                    color: AppColors.hold,
                    callout: true,
                    icon: Icons.info_outline_rounded,
                  ),
                ],
                if (c.resultPath != null) ...[
                  const SizedBox(height: 14),
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: kHeroBlockWidth,
                    ),
                    child: DesktopPathDisplay(
                      path: c.resultPath!,
                      action: DesktopPathAction.reveal,
                    ),
                  ),
                ],
                // Pack zip3's idle hero is the picker + identity form, so the
                // generic bolt is redundant there.
                if (!(c.actionId == 'make_zip3' &&
                    c.stage == StageState.idle)) ...[
                  const SizedBox(height: 22),
                  _Visual(c: c, accent: accent, pulse: _pulse),
                ],
                if (c.stage == StageState.idle && c.action.needsFirmware) ...[
                  const SizedBox(height: 14),
                  _FirmwareBar(
                    c: c,
                    onPick: widget.onPickFirmware,
                    onPickZip: widget.onPickZip,
                  ),
                ],
                if (c.stage == StageState.idle &&
                    c.actionId == 'make_zip3') ...[
                  const SizedBox(height: 12),
                  _MakeZip3Form(c: c),
                ],
                // The packer's idle page carries a file bar AND a form, so it
                // gets a tighter pre-CTA gap than the other actions.
                SizedBox(
                  height:
                      c.actionId == 'make_zip3' && c.stage == StageState.idle
                      ? 18
                      : 26,
                ),
                _StageButtons(c: c, onStart: widget.onStart),
                if (c.stage == StageState.idle &&
                    c.actionId == 'flash_compat') ...[
                  const SizedBox(height: 14),
                  _CompatZip3Toggle(c: c),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HeroMessage extends StatelessWidget {
  const _HeroMessage({
    required this.text,
    required this.color,
    required this.callout,
    required this.icon,
  });

  final String text;
  final Color color;
  final bool callout;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(fontSize: 14, height: 1.5, color: color);
    if (!callout) {
      return Text(text, textAlign: TextAlign.center, style: style);
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: kHeroBlockWidth),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.28)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(icon, size: 17, color: color),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(text, textAlign: TextAlign.start, style: style),
            ),
          ],
        ),
      ),
    );
  }
}

/// Standalone offline ZIP3 unpack. Selection inspects the package and fills the
/// details; Start re-validates it before writing the chosen local `.bin`.
class _UnpackZip3Page extends StatefulWidget {
  const _UnpackZip3Page({
    required this.c,
    required this.onPick,
    required this.onStart,
  });
  final AppController c;
  final Future<void> Function() onPick;
  final Future<void> Function() onStart;

  @override
  State<_UnpackZip3Page> createState() => _UnpackZip3PageState();
}

class _UnpackZip3PageState extends State<_UnpackZip3Page> {
  final TextEditingController _nameCtl = TextEditingController();

  @override
  void dispose() {
    _nameCtl.dispose();
    super.dispose();
  }

  /// A path as readable crumbs for a helper line. Empty segments are dropped,
  /// so a POSIX absolute path does not open with a stray separator.
  String _breadcrumb(String path) =>
      path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).join(' › ');

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final hasPackage = c.unpackZip3Path != null;
    if (_nameCtl.text != c.unpackOutputName) {
      _nameCtl.value = TextEditingValue(
        text: c.unpackOutputName,
        selection: TextSelection.collapsed(offset: c.unpackOutputName.length),
      );
    }
    final nameCheck = Firmware.validateUnpackedFilename(c.unpackOutputName);
    final unpackInfo = c.unpackPayloadLength == null
        ? null
        : '${c.unpackPayloadLength} bytes · '
              'enforceModel ${c.unpackEnforceModel == null
                  ? '—'
                  : c.unpackEnforceModel!
                  ? 'yes'
                  : 'no'} · '
              'encryption ${c.unpackEncryption?.toLowerCase() ?? '—'}';
    return Align(
      alignment: const Alignment(0, -0.08),
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 18, 28, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'OFFLINE · READS A FILE',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2.8,
                    color: AppColors.ok,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  hasPackage ? 'Ready to unpack' : 'Choose a zip3 package',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                    height: 1.08,
                    color: AppColors.txt,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Inspect the package, then decrypt its firmware to a local '
                  '.bin for editing or flashing.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.5,
                    color: AppColors.dim,
                  ),
                ),
                const SizedBox(height: 14),
                Container(
                  constraints: const BoxConstraints(maxWidth: kHeroBlockWidth),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.panel,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.line2),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.inventory_2_outlined,
                        size: 18,
                        color: AppColors.mut,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          c.unpackZip3FileName ?? 'No zip3 package chosen',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: hasPackage ? kMono : null,
                            fontSize: 13,
                            color: hasPackage ? AppColors.txt : AppColors.dim,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      _PillButton(
                        label: hasPackage ? 'Change' : 'Choose .zip',
                        onTap: widget.onPick,
                        bg: AppColors.line,
                        fg: AppColors.txt,
                        border: AppColors.line2,
                        small: true,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  constraints: const BoxConstraints(maxWidth: kHeroBlockWidth),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.panel,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.line2),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'PACKAGE DETAILS',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.6,
                          color: AppColors.mut,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            flex: 1,
                            child: _UnpackDetail(
                              label: 'Model',
                              value: c.unpackModel?.toUpperCase(),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 1,
                            child: _UnpackDetail(
                              label: 'Type',
                              value: c.unpackType?.toUpperCase(),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 2,
                            child: _UnpackDetail(
                              label: 'Name',
                              value: c.unpackDisplayName,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      _UnpackDetail(
                        label: 'Info',
                        value: unpackInfo,
                        valueFontSize: 12,
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _nameCtl,
                        enabled: hasPackage,
                        onChanged: c.setUnpackOutputName,
                        style: const TextStyle(
                          fontFamily: kMono,
                          fontSize: 13,
                          color: AppColors.txt,
                        ),
                        cursorColor: AppColors.brand,
                        decoration: InputDecoration(
                          isDense: true,
                          labelText: 'Output filename',
                          labelStyle: const TextStyle(
                            fontSize: 12,
                            color: AppColors.dim,
                          ),
                          hintText: 'firmware.bin',
                          hintStyle: const TextStyle(
                            fontFamily: kMono,
                            fontSize: 13,
                            color: AppColors.mut,
                          ),
                          errorText:
                              hasPackage &&
                                  c.unpackOutputName.trim().isNotEmpty &&
                                  !nameCheck.ok
                              ? nameCheck.message
                              : null,
                          helperText:
                              '.bin is added automatically. Output folder: '
                              '${_breadcrumb(Firmware.unpackedZip3DirLabel)}',
                          helperStyle: const TextStyle(
                            fontSize: 11,
                            color: AppColors.mut,
                          ),
                          helperMaxLines: 2,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 14,
                          ),
                          filled: true,
                          fillColor: AppColors.panel2,
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(
                              color: AppColors.line2,
                            ),
                          ),
                          disabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(
                              color: AppColors.line2,
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(color: AppColors.brand),
                          ),
                          errorBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(
                              color: AppColors.danger,
                            ),
                          ),
                          focusedErrorBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(
                              color: AppColors.danger,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 26),
                _PillButton(
                  label: 'Unpack zip3',
                  onTap: c.canStart ? widget.onStart : null,
                  gradient: [AppColors.brand, AppColors.brand2],
                  fg: const Color(0xFF04120F),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _UnpackDetail extends StatelessWidget {
  const _UnpackDetail({required this.label, this.value, this.valueFontSize});
  final String label;
  final String? value;
  final double? valueFontSize;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.panel2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.line2),
      ),
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: AppColors.dim),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value ?? '—',
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.start,
              style: TextStyle(
                fontFamily: kMono,
                fontSize: valueFontSize,
                color: value == null ? AppColors.mut : AppColors.txt,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Visual extends StatelessWidget {
  const _Visual({required this.c, required this.accent, required this.pulse});
  final AppController c;
  final Color accent;
  final AnimationController pulse;

  @override
  Widget build(BuildContext context) {
    switch (c.stage) {
      case StageState.idle:
        return const _IdleShimmerPlate();
      case StageState.hold:
        return _Pad(accent: accent, pulse: pulse, release: false);
      case StageState.release:
        return _Pad(accent: accent, pulse: pulse, release: true);
      case StageState.count:
        final frac = c.countdownSeconds == 0
            ? 0.0
            : c.countdownValue / c.countdownSeconds;
        return SizedBox(
          width: 168,
          height: 168,
          child: CustomPaint(
            painter: _RingPainter(frac, accent),
            child: Center(
              child: Text(
                '${c.countdownValue}',
                style: TextStyle(
                  fontFamily: kMono,
                  fontSize: 56,
                  fontWeight: FontWeight.w800,
                  color: accent,
                ),
              ),
            ),
          ),
        );
      case StageState.connect:
      case StageState.run:
        return _BusyProgress(accent: accent);
      case StageState.ok:
        return _ResultBadge(accent: accent, icon: Icons.check_rounded);
      case StageState.warn:
        return _ResultBadge(accent: accent, icon: Icons.lock_rounded);
      case StageState.fail:
        return _ResultBadge(accent: accent, icon: Icons.close_rounded);
    }
  }
}

/// Idle-state plate (84×84 bolt) with a periodic diagonal "armed shimmer":
/// a highlight crosses the plate, rests, then passes again. Variation C from
/// the hero-visual motion study. Its own slow controller (not the shared
/// 1400ms _pulse) so the sweep stays calm with a long rest between passes.
class _IdleShimmerPlate extends StatefulWidget {
  const _IdleShimmerPlate();

  @override
  State<_IdleShimmerPlate> createState() => _IdleShimmerPlateState();
}

class _IdleShimmerPlateState extends State<_IdleShimmerPlate>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shimmer = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 4600),
  )..repeat();

  @override
  void dispose() {
    _shimmer.dispose();
    super.dispose();
  }

  // Horizontal position of the sweep bar across the 84px plate: a long rest
  // off the left edge, one eased pass, then a hold off the right edge.
  double _sweepX(double t) {
    if (t < 0.55) return -80;
    if (t >= 0.85) return 120;
    final p = Curves.easeInOut.transform((t - 0.55) / 0.30);
    return -80 + p * 200;
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: AnimatedBuilder(
        animation: _shimmer,
        builder: (context, _) {
          return SizedBox(
            width: 84,
            height: 84,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppColors.brand.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.line2),
              ),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: _sweepX(_shimmer.value),
                    top: -20,
                    bottom: -20,
                    child: Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.skewX(-18 * math.pi / 180),
                      child: Container(
                        width: 68,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Colors.transparent,
                              AppColors.brand.withValues(alpha: 0.32),
                              Colors.transparent,
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Center(
                    child: Icon(Icons.bolt, color: AppColors.brand, size: 38),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The C45 contact visual: a wire with an arrow either pointing INTO the pad
/// (hold — press the wire on) or OUT of it (release — pull the wire off), with
/// a pulsing glowing contact dot.
class _Pad extends StatelessWidget {
  const _Pad({
    required this.accent,
    required this.pulse,
    required this.release,
  });
  final Color accent;
  final AnimationController pulse;
  final bool release;
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 232,
      height: 104,
      child: AnimatedBuilder(
        animation: pulse,
        builder: (context, _) => CustomPaint(
          painter: _PadPainter(
            accent: accent,
            t: pulse.value,
            release: release,
          ),
        ),
      ),
    );
  }
}

class _PadPainter extends CustomPainter {
  _PadPainter({required this.accent, required this.t, required this.release});
  final Color accent;
  final double t; // 0..1 repeating
  final bool release;

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    const padSize = 68.0;
    final padRect = Rect.fromLTWH(
      size.width - padSize,
      (size.height - padSize) / 2,
      padSize,
      padSize,
    );
    final rrect = RRect.fromRectAndRadius(padRect, const Radius.circular(18));
    final center = padRect.center;

    // pulse intensity (smooth)
    final g = 0.5 + 0.5 * math.sin(t * 2 * math.pi);

    // pad body
    canvas.drawRRect(rrect, Paint()..color = const Color(0xFF1B2331));
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = AppColors.line2,
    );

    // wire tip (arrow) + tail
    final padSide = Offset(padRect.left - 8, cy);
    final farSide = Offset(14, cy);
    final tip = release ? farSide : padSide; // arrow end
    final tail = release ? padSide : farSide;

    // wire: dim at the tail → accent at the arrow tip
    canvas.drawLine(
      tail,
      tip,
      Paint()
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round
        ..shader = ui.Gradient.linear(tail, tip, [AppColors.mut, accent]),
    );

    // arrowhead
    final dir = release ? -1.0 : 1.0; // pointing direction (x)
    const w = 10.0;
    final arrow = Paint()
      ..color = accent
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    canvas.drawLine(tip, Offset(tip.dx - dir * w, tip.dy - w), arrow);
    canvas.drawLine(tip, Offset(tip.dx - dir * w, tip.dy + w), arrow);

    // glowing contact dot
    canvas.drawCircle(
      center,
      24,
      Paint()
        ..color = accent.withValues(alpha: 0.10 + 0.12 * g)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 10 + 4 * g),
    );
    canvas.drawCircle(
      center,
      15,
      Paint()
        ..color = accent.withValues(alpha: 0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawCircle(center, 11, Paint()..color = accent);
    canvas.drawCircle(
      center.translate(-3, -3),
      3.5,
      Paint()..color = Colors.white.withValues(alpha: 0.55),
    );
  }

  @override
  bool shouldRepaint(_PadPainter old) =>
      old.t != t || old.accent != accent || old.release != release;
}

class _BusyProgress extends StatelessWidget {
  const _BusyProgress({required this.accent});
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: SizedBox(
        width: 72,
        height: 72,
        child: CircularProgressIndicator(
          strokeWidth: 6,
          color: accent,
          backgroundColor: AppColors.line2,
        ),
      ),
    );
  }
}

class _ResultBadge extends StatelessWidget {
  const _ResultBadge({required this.accent, required this.icon});
  final Color accent;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Container(
    width: 112,
    height: 112,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      border: Border.all(color: accent, width: 2),
      gradient: RadialGradient(
        colors: [accent.withValues(alpha: 0.18), Colors.transparent],
      ),
    ),
    child: Icon(icon, size: 52, color: accent),
  );
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.fraction, this.color);
  final double fraction;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - 8;
    final bg = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round
      ..color = const Color(0x12FFFFFF);
    canvas.drawCircle(center, radius, bg);
    final fg = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * fraction.clamp(0.0, 1.0),
      false,
      fg,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.fraction != fraction || old.color != color;
}

// ─────────────────────────────────────────── stage buttons

class _StageButtons extends StatelessWidget {
  const _StageButtons({required this.c, required this.onStart});
  final AppController c;
  final Future<void> Function() onStart;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    switch (c.stage) {
      case StageState.idle:
        children.add(
          _PillButton(
            label: c.action.cta,
            onTap: c.canStart ? onStart : null,
            gradient: c.action.danger == DangerLevel.hard
                ? const [Color(0xFFFF6472), AppColors.danger]
                : [AppColors.brand, AppColors.brand2],
            fg: c.action.danger == DangerLevel.hard
                ? Colors.white
                : const Color(0xFF04120F),
          ),
        );
        break;
      case StageState.hold:
      case StageState.release:
        final rel = c.stage == StageState.release;
        children.add(
          _PillButton(
            label: c.continueLabel,
            onTap: c.showContinue ? c.continueStep : null,
            gradient: rel
                ? const [Color(0xFFFF9A5C), AppColors.release]
                : const [Color(0xFFFFC44D), AppColors.hold],
            fg: const Color(0xFF160F00),
          ),
        );
        children.add(_cancel(c));
        break;
      case StageState.count:
      case StageState.connect:
      case StageState.run:
        if (c.showContinue) {
          children.add(
            _PillButton(
              label: c.continueLabel,
              onTap: c.continueStep,
              gradient: [AppColors.brand, AppColors.brand2],
              fg: const Color(0xFF04120F),
            ),
          );
        }
        children.add(_cancel(c));
        break;
      case StageState.ok:
      case StageState.warn:
        children.add(
          _PillButton(
            label: 'Done',
            onTap: c.dismiss,
            gradient: [AppColors.brand, AppColors.brand2],
            fg: const Color(0xFF04120F),
          ),
        );
        break;
      case StageState.fail:
        // While auto-retry is armed the primary is a readout, not a control:
        // the operator's hands are on the probe and Dismiss is the way out.
        children.add(
          _PillButton(
            label: c.autoRetryArmed ? c.autoRetryLabel : c.failurePrimaryLabel,
            onTap: c.autoRetryArmed ? null : () => c.retry(),
            gradient: [AppColors.brand, AppColors.brand2],
            fg: const Color(0xFF04120F),
          ),
        );
        if (!c.failureNeedsInput) {
          children.add(
            _PillButton(
              label: 'Dismiss',
              onTap: c.dismiss,
              bg: AppColors.line,
              fg: AppColors.txt,
              border: AppColors.line2,
            ),
          );
        }
        break;
    }
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 10,
      runSpacing: 10,
      children: children,
    );
  }

  Widget _cancel(AppController c) => _PillButton(
    label: 'Cancel',
    onTap: c.cancel,
    bg: AppColors.line,
    fg: AppColors.txt,
    border: AppColors.line2,
  );
}

/// Selection gate for SHU compat: recent VCU firmware versions are not
/// supported, so entering the action requires acknowledging the known version
/// ceilings after a short countdown. Anything except acceptance keeps the
/// previous action selected.
Future<bool?> _showShuCompatWarning(BuildContext context) {
  return showDialog<bool>(
    context: context,
    barrierColor: const Color(0xB3040A0F),
    builder: (ctx) => Dialog(
      backgroundColor: AppColors.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: AppColors.line2),
      ),
      child: Container(
        width: 520,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: AppColors.danger.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.warning_amber_rounded,
                color: AppColors.danger,
                size: 24,
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'ATTENTION',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.txt,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'SHU compat cannot be used with recent VCU firmware.\n\n'
              'Only continue if your installed firmware is older than:\n\n'
              'F3 VCU — 1.6.3\n'
              'G3 VCU — 1.6.3\n'
              'ZT3 VCU — 1.5.9\n'
              'GT3 VCU — 1.7.2 — for reference only:\n'
              'x3utils does not support SHU compatible on GT3 at any version',
              style: TextStyle(fontSize: 13, height: 1.5, color: AppColors.dim),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _PillButton(
                  label: 'Cancel',
                  onTap: () => Navigator.pop(ctx, false),
                  bg: AppColors.line,
                  fg: AppColors.txt,
                  border: AppColors.line2,
                  small: true,
                ),
                const SizedBox(width: 10),
                _CountdownPillButton(
                  label: 'I understand — continue',
                  seconds: 5,
                  onTap: () => Navigator.pop(ctx, true),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

/// Selection gate for Flash Only: shown every time the action is entered from
/// the left pane. Flash Only is the deliberate override — no backup and no
/// target-match guard — so entry requires sitting through a short countdown.
/// Returns true when the operator accepts; anything else keeps the previous
/// selection.
Future<bool?> _showFlashOnlyWarning(BuildContext context) {
  return showDialog<bool>(
    context: context,
    barrierColor: const Color(0xB3040A0F),
    builder: (ctx) => Dialog(
      backgroundColor: AppColors.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: AppColors.line2),
      ),
      child: Container(
        width: 520,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: AppColors.danger.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.warning_amber_rounded,
                color: AppColors.danger,
                size: 24,
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'Flash Only — no safety nets',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.txt,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'This is the deliberate override. No backup is taken and the '
              'target-match guard is skipped — nothing checks that your '
              'firmware belongs on the connected controller. If a write goes '
              'wrong there is nothing to restore from. Only continue if you '
              'already have a good dump and you are sure about the target.',
              style: TextStyle(fontSize: 13, height: 1.5, color: AppColors.dim),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _PillButton(
                  label: 'Cancel',
                  onTap: () => Navigator.pop(ctx, false),
                  bg: AppColors.line,
                  fg: AppColors.txt,
                  border: AppColors.line2,
                  small: true,
                ),
                const SizedBox(width: 10),
                _CountdownPillButton(
                  label: 'I understand — continue',
                  seconds: 5,
                  onTap: () => Navigator.pop(ctx, true),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

/// Selection gate for Unlock / rescue: shown every time the action is entered
/// from the left pane. Rescue rewrites the option bytes to clear read
/// protection, which mass-erases the flash — an irreversible wipe of whatever
/// is on the controller — so entry requires sitting through a short countdown.
/// Returns true when the operator accepts; anything else keeps the previous
/// selection.
Future<bool?> _showRescueWarning(BuildContext context) {
  return showDialog<bool>(
    context: context,
    barrierColor: const Color(0xB3040A0F),
    builder: (ctx) => Dialog(
      backgroundColor: AppColors.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: AppColors.line2),
      ),
      child: Container(
        width: 520,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: AppColors.danger.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.warning_amber_rounded,
                color: AppColors.danger,
                size: 24,
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'Unlock / rescue — this erases the flash',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.txt,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Rescue rewrites the option bytes to clear read protection, and '
              'that mass-erases the flash. Everything on the connected '
              'controller — firmware and identity — is wiped, and there is '
              'nothing to restore from unless you already have a good dump. '
              'Only continue on a board you are prepared to re-flash from '
              'scratch. After it runs, power-cycle and use Check protection to '
              'confirm.',
              style: TextStyle(fontSize: 13, height: 1.5, color: AppColors.dim),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _PillButton(
                  label: 'Cancel',
                  onTap: () => Navigator.pop(ctx, false),
                  bg: AppColors.line,
                  fg: AppColors.txt,
                  border: AppColors.line2,
                  small: true,
                ),
                const SizedBox(width: 10),
                _CountdownPillButton(
                  label: 'I understand — continue',
                  seconds: 5,
                  onTap: () => Navigator.pop(ctx, true),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

/// Hard-styled confirm button that stays disabled for [seconds], showing the
/// remaining time in its label, then becomes tappable. Used by the Flash Only
/// override dialog.
class _CountdownPillButton extends StatefulWidget {
  const _CountdownPillButton({
    required this.label,
    required this.seconds,
    required this.onTap,
  });
  final String label;
  final int seconds;
  final VoidCallback onTap;

  @override
  State<_CountdownPillButton> createState() => _CountdownPillButtonState();
}

class _CountdownPillButtonState extends State<_CountdownPillButton> {
  late int _left = widget.seconds;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      setState(() => _left--);
      if (_left <= 0) t.cancel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _left <= 0;
    return _PillButton(
      label: ready ? widget.label : '${widget.label} (${_left}s)',
      onTap: ready ? widget.onTap : null,
      gradient: const [Color(0xFFFF6472), AppColors.danger],
      fg: Colors.white,
      small: true,
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({
    required this.label,
    required this.onTap,
    this.gradient,
    this.bg,
    this.fg = AppColors.txt,
    this.border,
    this.small = false,
  });
  final String label;
  final VoidCallback? onTap;
  final List<Color>? gradient;
  final Color? bg;
  final Color fg;
  final Color? border;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: small ? 16 : 22,
              vertical: small ? 10 : 12,
            ),
            decoration: BoxDecoration(
              color: gradient == null ? (bg ?? Colors.transparent) : null,
              gradient: gradient == null
                  ? null
                  : LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: gradient!,
                    ),
              borderRadius: BorderRadius.circular(999),
              border: border == null ? null : Border.all(color: border!),
              boxShadow: gradient == null
                  ? null
                  : [
                      BoxShadow(
                        color: gradient!.last.withValues(alpha: 0.35),
                        blurRadius: 18,
                        offset: const Offset(0, 8),
                      ),
                    ],
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: small ? 13 : 14,
                fontWeight: FontWeight.w700,
                color: fg,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────── status bar

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.c});
  final AppController c;
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: const BoxDecoration(
        color: Color(0x40000000),
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      child: Row(
        children: [
          _stat(
            'OpenOCD',
            c.openOcdStatus,
            led: c.openOcdStatus == 'ready'
                ? AppColors.ok
                : c.openOcdStatus == 'missing'
                ? AppColors.danger
                : AppColors.hold,
          ),
          _sep(),
          _stat('Mode', c.mode.title),
          _sep(),
          _stat('Last connect', c.lastConnect),
          const Spacer(),
          InkWell(
            onTap: c.toggleConsole,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Text(
                c.consoleOpen ? '▾ Console' : '▤ Console',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.brand,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stat(String k, String v, {Color? led}) => Row(
    children: [
      if (led != null) ...[
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: led,
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: led, blurRadius: 8)],
          ),
        ),
        const SizedBox(width: 7),
      ],
      Text('$k ', style: const TextStyle(fontSize: 12, color: AppColors.mut)),
      Text(v, style: const TextStyle(fontSize: 12, color: AppColors.dim)),
    ],
  );

  Widget _sep() => Container(
    width: 1,
    height: 18,
    margin: const EdgeInsets.symmetric(horizontal: 13),
    color: AppColors.line,
  );
}

// ─────────────────────────────────────────── console drawer

class _ConsolePanel extends StatefulWidget {
  const _ConsolePanel({
    required this.c,
    required this.height,
    required this.maxHeight,
    required this.docked,
  });
  final AppController c;
  final double height;
  final double maxHeight;
  final bool docked;
  @override
  State<_ConsolePanel> createState() => _ConsolePanelState();
}

class _ConsolePanelState extends State<_ConsolePanel> {
  final ScrollController _sc = ScrollController();

  @override
  void dispose() {
    _sc.dispose();
    super.dispose();
  }

  void _copy(BuildContext context) {
    final body = widget.c.console.join('\n');
    final text = body.isEmpty ? '' : '${widget.c.contextHeader()}\n\n$body';
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            text.isEmpty ? 'Console is empty' : 'Console copied',
            style: const TextStyle(
              color: AppColors.txt,
              fontWeight: FontWeight.w600,
            ),
          ),
          duration: const Duration(milliseconds: 1200),
          behavior: SnackBarBehavior.floating,
          width: 200,
          backgroundColor: AppColors.elev,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: AppColors.line2),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.c.console;
    // keep pinned to the newest line
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_sc.hasClients) _sc.jumpTo(_sc.position.maxScrollExtent);
    });
    return Container(
      height: widget.height,
      decoration: const BoxDecoration(
        color: Color(0xFF080B10),
        border: Border(top: BorderSide(color: AppColors.line2)),
        boxShadow: [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 30,
            offset: Offset(0, -12),
          ),
        ],
      ),
      child: Column(
        children: [
          _ResizeHandle(c: widget.c, maxHeight: widget.maxHeight),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.line)),
            ),
            child: Row(
              children: [
                Icon(Icons.terminal_rounded, size: 16, color: AppColors.brand),
                const SizedBox(width: 8),
                const Text(
                  'OpenOCD console',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: AppColors.txt,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(width: 10),
                const Text(
                  'stdout · stderr',
                  style: TextStyle(color: AppColors.mut, fontSize: 12),
                ),
                const SizedBox(width: 14),
                _LogToggle(c: widget.c),
                const Spacer(),
                _PinButton(c: widget.c),
                const SizedBox(width: 14),
                _ConsoleAction(label: 'Copy', onTap: () => _copy(context)),
                const SizedBox(width: 16),
                _ConsoleAction(label: 'Clear', onTap: widget.c.clearConsole),
                const SizedBox(width: 16),
                _ConsoleAction(label: 'Close ▾', onTap: widget.c.toggleConsole),
              ],
            ),
          ),
          Expanded(
            child: lines.isEmpty
                ? const Center(
                    child: Text(
                      '// waiting for first action…',
                      style: TextStyle(
                        fontFamily: kMono,
                        color: AppColors.mut,
                        fontSize: 12,
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _sc,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    itemCount: lines.length,
                    itemBuilder: (_, i) => Text(
                      lines[i],
                      style: TextStyle(
                        fontFamily: kMono,
                        fontSize: 12,
                        height: 1.55,
                        color: _lineColor(lines[i]),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Color _lineColor(String l) {
    final low = l.toLowerCase();
    if (l.startsWith('>')) return AppColors.brand;
    if (low.contains('error') || low.contains('fail')) return AppColors.danger;
    if (l.contains('✔') ||
        low.contains(' ok') ||
        low.contains('halted') ||
        low.contains('pass')) {
      return AppColors.ok;
    }
    if (low.contains('cancel') ||
        low.contains('warn') ||
        low.contains('release') ||
        low.contains('hold')) {
      return AppColors.hold;
    }
    return const Color(0xFFC4D0DF);
  }
}

class _ConsoleAction extends StatelessWidget {
  const _ConsoleAction({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(6),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Text(
        label,
        style: TextStyle(
          color: AppColors.brand,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}

class _FirmwareBar extends StatelessWidget {
  const _FirmwareBar({
    required this.c,
    required this.onPick,
    required this.onPickZip,
  });
  final AppController c;
  final Future<void> Function() onPick;
  final Future<void> Function() onPickZip;
  @override
  Widget build(BuildContext context) {
    final path = c.firmwarePath;
    final name = path?.split(RegExp(r'[\\/]')).last;
    final has = name != null;
    final flashOnly = c.actionId == 'flash_only';
    final slot0 = c.isSlotAction;
    final twoLine = flashOnly || c.actionId == 'flash_slot0';

    if (!twoLine) {
      return Container(
        constraints: const BoxConstraints(maxWidth: kHeroBlockWidth),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.panel,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: has
                ? AppColors.brand.withValues(alpha: 0.4)
                : AppColors.line2,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  has ? Icons.memory_rounded : Icons.folder_open_rounded,
                  size: 18,
                  color: has ? AppColors.brand : AppColors.mut,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    name ?? 'No firmware chosen',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: has ? kMono : null,
                      fontSize: 13,
                      color: has ? AppColors.txt : AppColors.dim,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                _PillButton(
                  label: has ? 'Change' : 'Choose .bin',
                  onTap: () => onPick(),
                  bg: AppColors.line,
                  fg: AppColors.txt,
                  border: AppColors.line2,
                  small: true,
                ),
              ],
            ),
          ],
        ),
      );
    }

    final hint = !has && flashOnly
        ? (slot0
              ? 'Choose a slot-sized .bin or import a VCU/MCU ZIP3 package.'
              : 'ZIP3 packages contain slot firmware — select Slot 0 only.')
        : null;
    return Container(
      constraints: const BoxConstraints(maxWidth: kHeroBlockWidth),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 11),
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: has ? AppColors.brand.withValues(alpha: 0.4) : AppColors.line2,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                has ? Icons.memory_rounded : Icons.folder_open_rounded,
                size: 18,
                color: has ? AppColors.brand : AppColors.mut,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  name ?? 'No firmware chosen',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: has ? kMono : null,
                    fontSize: 13,
                    color: has ? AppColors.txt : AppColors.dim,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Divider(height: 1, color: AppColors.line),
          const SizedBox(height: 10),
          Row(
            children: [
              if (flashOnly)
                Expanded(child: _FlashOnlyScopeControl(c: c))
              else
                const Spacer(),
              const SizedBox(width: 12),
              _PillButton(
                label: 'Choose .bin',
                onTap: () => onPick(),
                bg: AppColors.line,
                fg: AppColors.txt,
                border: AppColors.line2,
                small: true,
              ),
              const SizedBox(width: 8),
              _PillButton(
                label: 'Choose .zip',
                onTap: slot0 ? () => onPickZip() : null,
                bg: AppColors.line,
                fg: AppColors.txt,
                border: AppColors.line2,
                small: true,
              ),
            ],
          ),
          if (hint != null) ...[
            const SizedBox(height: 8),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: AppColors.dim),
            ),
          ],
        ],
      ),
    );
  }
}

class _FlashOnlyScopeControl extends StatelessWidget {
  const _FlashOnlyScopeControl({required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 42,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0x30000000),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.line2),
      ),
      child: Row(
        children: [
          _item('Full image', FlashOnlyScope.fullImage),
          _item('Slot 0 only', FlashOnlyScope.slot0),
        ],
      ),
    );
  }

  Widget _item(String label, FlashOnlyScope scope) {
    final selected = c.flashOnlyScope == scope;
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: selected ? null : () => c.setFlashOnlyScope(scope),
            borderRadius: BorderRadius.circular(999),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected ? AppColors.elev : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: selected ? AppColors.line2 : Colors.transparent,
                ),
              ),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.fade,
                softWrap: false,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: selected ? AppColors.txt : AppColors.dim,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shared Slice/Pack identity form: operator-declared Type/Model (optionally
/// preselected from a readable VCU/MCU banner), an enforce-model checkbox, and
/// an editable package name.
class _MakeZip3Form extends StatefulWidget {
  const _MakeZip3Form({required this.c});
  final AppController c;
  @override
  State<_MakeZip3Form> createState() => _MakeZip3FormState();
}

class _MakeZip3FormState extends State<_MakeZip3Form> {
  final TextEditingController _nameCtl = TextEditingController();
  final FocusNode _nameFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    // The name box paints its own focus border (it is a plain container, not
    // an InputDecorator), so rebuild on focus change.
    _nameFocus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    // Re-sync the local field when the controller reset the name externally
    // (a fresh dump / action switch). Typing doesn't notify, so this never
    // fights the cursor while the operator edits.
    if (c.zip3Name != _nameCtl.text) {
      _nameCtl.text = c.zip3Name;
      _nameCtl.selection = TextSelection.collapsed(
        offset: _nameCtl.text.length,
      );
    }
    final hasDump = c.firmwarePath != null;
    final canName = c.zip3Type != null && c.zip3Model != null;
    final defaultName = c.zip3DefaultName ?? 'model_TYPE_name';

    return Opacity(
      opacity: hasDump ? 1 : 0.5,
      child: IgnorePointer(
        ignoring: !hasDump,
        child: Container(
          constraints: const BoxConstraints(maxWidth: kHeroBlockWidth),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 13),
          decoration: BoxDecoration(
            color: AppColors.panel,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.line2),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'PACKAGE IDENTITY',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.6,
                  color: AppColors.mut,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  // Model before Type: reads like the banner ("G3 VCU").
                  Expanded(
                    child: _dropdown(
                      hint: 'Model',
                      value: c.zip3Model,
                      items: AppController.zip3Models,
                      onChanged: c.setZip3Model,
                      labelOf: (m) => m.toUpperCase(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _dropdown(
                      hint: 'Type',
                      value: c.zip3Type,
                      items: c.zip3TypeOptions,
                      onChanged: c.setZip3Type,
                    ),
                  ),
                ],
              ),
              if (hasDump && !canName) ...[
                const SizedBox(height: 8),
                Text(
                  c.zip3Type == 'MCU'
                      ? 'MCU firmware has no model identity — pick the model.'
                      : 'Pick the firmware type and model to build.',
                  style: const TextStyle(fontSize: 12, color: AppColors.hold),
                ),
              ],
              const SizedBox(height: 10),
              _EnforceModelToggle(c: c),
              const SizedBox(height: 12),
              // The name box clones the dropdowns' fixed 44 px container
              // rather than using an InputDecorator: an outline TextField's
              // height follows font metrics, which differ between the test
              // font and real platform fonts, so padding math cannot keep the
              // boxes matched. A fixed-height box matches by construction.
              AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: AppColors.panel2,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: _nameFocus.hasFocus
                        ? AppColors.brand
                        : AppColors.line2,
                  ),
                ),
                child: Center(
                  child: TextField(
                    controller: _nameCtl,
                    focusNode: _nameFocus,
                    onChanged: c.setZip3Name,
                    style: const TextStyle(
                      fontFamily: kMono,
                      fontSize: 13,
                      color: AppColors.txt,
                    ),
                    cursorColor: AppColors.brand,
                    decoration: InputDecoration.collapsed(
                      hintText: defaultName,
                      hintStyle: const TextStyle(
                        fontFamily: kMono,
                        fontSize: 13,
                        color: AppColors.mut,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              // One line on purpose: this page is the tallest idle layout in
              // the app, and a wrapped caption costs a line the MCU case
              // (which adds a "pick the model" hint) needs. The output folder
              // is still shown with a reveal button on the result screen.
              const Text(
                'Package name — blank uses the suggestion.',
                style: TextStyle(fontSize: 11, color: AppColors.mut),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dropdown({
    required String hint,
    required String? value,
    required List<String> items,
    required ValueChanged<String?> onChanged,
    String Function(String)? labelOf,
  }) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.panel2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.line2),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          hint: Text(
            hint,
            style: const TextStyle(color: AppColors.mut, fontSize: 13),
          ),
          dropdownColor: AppColors.panel2,
          style: const TextStyle(color: AppColors.txt, fontSize: 13),
          icon: const Icon(Icons.expand_more_rounded, color: AppColors.dim),
          items: [
            for (final it in items)
              DropdownMenuItem(value: it, child: Text(labelOf?.call(it) ?? it)),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}

/// Faint opt-in under the "Make SHU compatible" pill: after the patched image
/// flashes, also repackage it as a BLE-loadable zip3. Off by default; VCU only
/// (an MCU compat run silently skips — see AppController.compatMakeZip3).
class _CompatZip3Toggle extends StatelessWidget {
  const _CompatZip3Toggle({required this.c});
  final AppController c;
  @override
  Widget build(BuildContext context) {
    final on = c.compatMakeZip3;
    return InkWell(
      onTap: () => c.setCompatMakeZip3(!on),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              on
                  ? Icons.check_box_rounded
                  : Icons.check_box_outline_blank_rounded,
              size: 16,
              color: on ? AppColors.brand : AppColors.mut,
            ),
            const SizedBox(width: 7),
            Text(
              'Attempt to also make zip3',
              style: TextStyle(
                fontSize: 12,
                color: on ? AppColors.txt : AppColors.dim,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The "Enforce model" checkbox for Make zip3 — mirrors info.json's
/// `enforceModel`; default on so a package only loads on its declared model.
class _EnforceModelToggle extends StatelessWidget {
  const _EnforceModelToggle({required this.c});
  final AppController c;
  @override
  Widget build(BuildContext context) {
    final on = c.zip3EnforceModel;
    return InkWell(
      onTap: () => c.setZip3EnforceModel(!on),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Icon(
              on
                  ? Icons.check_box_rounded
                  : Icons.check_box_outline_blank_rounded,
              size: 18,
              color: on ? AppColors.brand : AppColors.mut,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Enforce model — the package only loads on its declared model',
                style: TextStyle(
                  fontSize: 12,
                  color: on ? AppColors.txt : AppColors.dim,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LogToggle extends StatelessWidget {
  const _LogToggle({required this.c});
  final AppController c;
  @override
  Widget build(BuildContext context) {
    final on = c.logToFile;
    return Tooltip(
      message: on
          ? 'Saving each run → ${Firmware.logsDirLabel}'
          : 'Save each run to a log file',
      child: InkWell(
        onTap: c.toggleLogToFile,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                on
                    ? Icons.check_box_rounded
                    : Icons.check_box_outline_blank_rounded,
                size: 15,
                color: on ? AppColors.brand : AppColors.mut,
              ),
              const SizedBox(width: 5),
              Text(
                'Save log',
                style: TextStyle(
                  fontSize: 12,
                  color: on ? AppColors.brand : AppColors.mut,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PinButton extends StatelessWidget {
  const _PinButton({required this.c});
  final AppController c;
  @override
  Widget build(BuildContext context) {
    final pinned = c.consolePinned;
    return Tooltip(
      message: pinned ? 'Unpin — float over' : 'Pin — dock alongside',
      child: InkWell(
        onTap: c.togglePin,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Icon(
            pinned ? Icons.push_pin : Icons.push_pin_outlined,
            size: 16,
            color: pinned ? AppColors.brand : AppColors.dim,
          ),
        ),
      ),
    );
  }
}

/// Draggable grip at the top of the console to resize its height.
class _ResizeHandle extends StatelessWidget {
  const _ResizeHandle({required this.c, required this.maxHeight});
  final AppController c;
  final double maxHeight;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (d) {
          final double nh = (c.consoleHeight - d.delta.dy)
              .clamp(140.0, math.max(140.0, maxHeight - 100))
              .toDouble();
          c.setConsoleHeight(nh);
        },
        child: Container(
          height: 14,
          alignment: Alignment.center,
          color: Colors.transparent,
          child: Container(
            width: 44,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.line2,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────── settings helpers

class _SettingRow extends StatelessWidget {
  const _SettingRow({required this.label, required this.child});
  final String label;
  final Widget child;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          label,
          style: const TextStyle(
            color: AppColors.txt,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      child,
    ],
  );
}

class _AccentPicker extends StatelessWidget {
  const _AccentPicker({required this.c, required this.onChanged});
  final AppController c;
  final VoidCallback onChanged;
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < kAccents.length; i++) ...[
          if (i > 0) const SizedBox(width: 10),
          Tooltip(
            message: kAccents[i].name,
            child: GestureDetector(
              onTap: () {
                c.setAccent(i);
                onChanged();
              },
              child: Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [kAccents[i].brand, kAccents[i].pop],
                  ),
                  border: Border.all(
                    color: c.accentIndex == i
                        ? AppColors.txt
                        : Colors.transparent,
                    width: 2,
                  ),
                  boxShadow: c.accentIndex == i
                      ? [
                          BoxShadow(
                            color: kAccents[i].brand.withValues(alpha: 0.5),
                            blurRadius: 8,
                          ),
                        ]
                      : null,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _BackupSettingsSection extends StatefulWidget {
  const _BackupSettingsSection({required this.c});
  final AppController c;
  @override
  State<_BackupSettingsSection> createState() => _BackupSettingsSectionState();
}

class _BackupSettingsSectionState extends State<_BackupSettingsSection> {
  late final TextEditingController _prefix = TextEditingController(
    text: widget.c.backupPrefix,
  );

  // Set when a picked folder is refused, cleared by the next pick.
  String? _rootError;

  @override
  void dispose() {
    _prefix.dispose();
    super.dispose();
  }

  Future<void> _browse() async {
    final dir = await getDirectoryPath();
    if (dir == null) return;
    final check = Firmware.validateRootFolder(dir);
    setState(() => _rootError = check.ok ? null : check.message);
    if (check.ok) widget.c.setX3utilsRoot(dir);
  }

  String _clean(String s) =>
      s.trim().replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '');

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final root = Firmware.root;
    final pre = _clean(_prefix.text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'x3utils folder',
                style: TextStyle(
                  color: AppColors.txt,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            _ConsoleAction(label: 'Browse…', onTap: () => _browse()),
            if (c.x3utilsRoot != null) ...[
              const SizedBox(width: 14),
              _ConsoleAction(
                label: 'Reset',
                onTap: () {
                  c.setX3utilsRoot(null);
                  setState(() => _rootError = null);
                },
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        DesktopPathDisplay(
          path: root,
          // Reveal only once it is really there — the subfolders are created on
          // the first run that needs them, not by opening Settings.
          action: Firmware.rootExists
              ? DesktopPathAction.reveal
              : DesktopPathAction.copy,
        ),
        const SizedBox(height: 5),
        Text(
          _rootError ??
              'Holds backup · compat · unpacked_zip3 · packed_zip3 · logs'
                  '${Firmware.rootIsDefault ? ' · default location' : ''}',
          style: TextStyle(
            fontSize: 11,
            color: _rootError == null ? AppColors.mut : AppColors.danger,
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            const Expanded(
              child: Text(
                'Filename prefix',
                style: TextStyle(
                  color: AppColors.txt,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            SizedBox(
              width: 150,
              child: TextField(
                controller: _prefix,
                onChanged: (v) {
                  c.setBackupPrefix(v);
                  setState(() {});
                },
                style: const TextStyle(
                  color: AppColors.txt,
                  fontSize: 13,
                  fontFamily: kMono,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'none',
                  hintStyle: const TextStyle(color: AppColors.mut),
                  filled: true,
                  fillColor: AppColors.panel2,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppColors.line2),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: AppColors.brand),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '${pre.isEmpty ? '' : '${pre}_'}dump_<time>.bin',
          style: const TextStyle(
            color: AppColors.mut,
            fontSize: 12,
            fontFamily: kMono,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            const Expanded(
              child: Text(
                'Keep a 2nd copy',
                style: TextStyle(
                  color: AppColors.txt,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Transform.scale(
              scale: 0.8,
              alignment: Alignment.centerRight,
              child: Switch(
                value: c.secondCopy,
                activeThumbColor: AppColors.brand,
                onChanged: (v) {
                  c.setSecondCopy(v);
                  setState(() {});
                },
              ),
            ),
          ],
        ),
        Text(
          Firmware.secondCopyLabel,
          style: const TextStyle(
            color: AppColors.mut,
            fontSize: 12,
            fontFamily: kMono,
          ),
        ),
        // BETA3 Windows-only bench instrument. Safe ACP validation is the
        // default; this restores unrestricted BETA2 behavior for comparison.
        if (c.windowsPathBenchAvailable) ...[
          const SizedBox(height: 14),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Bypass Windows path safety',
                  style: TextStyle(
                    color: AppColors.txt,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Transform.scale(
                scale: 0.8,
                alignment: Alignment.centerRight,
                child: Switch(
                  value: c.bypassWindowsPathSafety,
                  activeThumbColor: AppColors.brand,
                  onChanged: (v) {
                    c.setBypassWindowsPathSafety(v);
                    setState(() {});
                  },
                ),
              ),
            ],
          ),
          const Text(
            'BETA3 bench switch. OFF allows only paths this PC’s Windows '
            'code page passes to OpenOCD unchanged. ON hands non-ASCII paths '
            'straight through and can silently resolve a DIFFERENT file. '
            'Braces stay refused. Every run logs the selected mode.',
            style: TextStyle(color: AppColors.mut, fontSize: 12),
          ),
        ],
      ],
    );
  }
}

class _ModeDropdown extends StatelessWidget {
  const _ModeDropdown({required this.c, required this.onChanged});
  final AppController c;
  final VoidCallback onChanged;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    decoration: BoxDecoration(
      color: AppColors.panel2,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: AppColors.line2),
    ),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<ConnectionMode>(
        value: c.defaultMode,
        dropdownColor: AppColors.panel2,
        style: const TextStyle(color: AppColors.txt, fontSize: 13),
        items: [
          for (final m in [
            ...ConnectionMode.values,
          ]..sort((a, b) => a.tag.compareTo(b.tag)))
            DropdownMenuItem(value: m, child: Text('${m.tag} · ${m.title}')),
        ],
        onChanged: (m) {
          if (m != null) {
            c.setDefaultMode(m);
            onChanged();
          }
        },
      ),
    ),
  );
}
