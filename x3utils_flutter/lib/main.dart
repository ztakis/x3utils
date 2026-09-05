import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'android_console.dart'; // swipe-to-console (Android)
import 'app_controller.dart';
import 'engine/dump_metadata.dart';
import 'engine/file_info.dart';
import 'engine/info_row.dart';
import 'engine/firmware.dart';
import 'engine/firmware_inspection.dart';
import 'engine/pack_zip3.dart';
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
  const HomeScreen({super.key, this.controller});

  final AppController? controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final AppController c = widget.controller ?? AppController();
  late final bool _ownsController = widget.controller == null;

  @override
  void dispose() {
    if (_ownsController) c.dispose();
    super.dispose();
  }

  Future<void> _onStart() async {
    final a = c.action;
    if (a.id == 'flash_compat' && c.compatRecoveryPending) {
      await c.start(); // Return to recovery without offering another patch run.
      return;
    }
    // Get file info reads a local file and shows a dialog. It deliberately
    // never reaches `c.start()`: that path owns the busy surface, the stage
    // machine and `lastConnect`, and nothing here touches a target — a PASS
    // connect verdict for a run that never connected would be a lie.
    if (a.id == 'file_info') {
      if (c.browserMode) {
        final name = c.firmwarePath;
        final bytes = c.firmwareBytes;
        if (name != null && bytes != null) {
          var inspection = FileInfo.inspectBytes(name, bytes);
          if (inspection.needsMcuModel) {
            final model = await _showMcuModelPicker(
              context,
              FileInfo.mcuModels,
            );
            if (!mounted || model == null) return;
            inspection = FileInfo.inspectBytes(
              name,
              bytes,
              declaredMcuModel: model,
            );
          }
          if (mounted) await _showInfoReport(context, inspection.report);
        }
      } else {
        final path = c.firmwarePath;
        if (path != null) {
          var inspection = FileInfo.inspect(path);
          if (inspection.needsMcuModel) {
            final model = await _showMcuModelPicker(
              context,
              FileInfo.mcuModels,
            );
            if (!mounted || model == null) return;
            inspection = FileInfo.inspect(path, declaredMcuModel: model);
          }
          if (mounted) await _showInfoReport(context, inspection.report);
        }
      }
      return;
    }
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
      askMcuModel: (models) => _showMcuModelPicker(context, models),
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
                    phone: c.phoneMode,
                  ),
                  const SizedBox(width: 10),
                  _PillButton(
                    label: 'Move to $where',
                    onTap: () => Navigator.pop(ctx, true),
                    gradient: [AppColors.brand, AppColors.brand2],
                    fg: const Color(0xFF04120F),
                    small: true,
                    phone: c.phoneMode,
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
                    phone: c.phoneMode,
                  ),
                  const SizedBox(width: 10),
                  _PillButton(
                    label: 'Replace',
                    onTap: () => Navigator.pop(ctx, true),
                    gradient: const [Color(0xFFFF6472), AppColors.danger],
                    fg: Colors.white,
                    small: true,
                    phone: c.phoneMode,
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
    // Get file info describes a file rather than writing it, so its picker is
    // deliberately PERMISSIVE: it takes .bin or .zip and applies none of the
    // flash validators. A truncated dump, an unknown banner or an unreadable
    // package is exactly what an operator reaches for this tool to understand,
    // and a picker that refuses those refuses the tool's whole purpose. The
    // bad news belongs in the report, not in a rejection.
    if (c.actionId == 'file_info') {
      const group = XTypeGroup(
        label: 'firmware or package',
        extensions: ['bin', 'zip'],
      );
      final picked = await openFile(acceptedTypeGroups: [group]);
      if (picked != null) {
        if (c.browserMode) {
          c.setFirmwareRawBytes(picked.name, await picked.readAsBytes());
        } else {
          c.setFirmware(picked.path);
        }
      }
      return;
    }
    const group = XTypeGroup(label: 'firmware', extensions: ['bin']);
    final file = await openFile(acceptedTypeGroups: [group]);
    if (file == null) return;
    // The controller validates for the current kind (plus the mainstream
    // banner gate) and remembers the bin + its identity note on success.
    final check = c.browserMode || c.androidMode
        ? c.selectFirmwareBytes(file.name, await file.readAsBytes())
        : c.selectFirmwareBin(file.path);
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

  /// Slot-0 only: load a zip3/zip3.2 firmware .zip — the controller validates
  /// the package, recovers its plaintext, and remembers the slot bin.
  Future<void> _pickFirmwareZip() async {
    const group = XTypeGroup(label: 'zip3 package', extensions: ['zip']);
    final file = await openFile(acceptedTypeGroups: [group]);
    if (file == null) return;
    final res = c.browserMode || c.androidMode
        ? c.loadSlotFirmwareFromZipBytes(file.name, await file.readAsBytes())
        : await c.loadSlotFirmwareFromZip(file.path);
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
    const group = XTypeGroup(label: 'zip3 package', extensions: ['zip']);
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
                    phone: c.phoneMode,
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
                    phone: c.phoneMode,
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
                    child: _DialogScrollView(
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
                          if (report != null && report.findings.isNotEmpty) ...[
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
                        phone: c.phoneMode,
                      ),
                      const SizedBox(width: 10),
                      _PillButton(
                        label: 'Flash anyway',
                        onTap: () => Navigator.pop(ctx, true),
                        gradient: const [Color(0xFFFFC247), AppColors.hold],
                        fg: const Color(0xFF211600),
                        small: true,
                        phone: c.phoneMode,
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
    'flash_backup' =>
      c.isSlotAction
          ? 'A full 128 KB backup runs first, then only application slot 0 is erased and written — the bootloader and identity block stay untouched. Keep the wires steady the whole time.'
          : 'A full 128 KB backup runs first, then your firmware is written and verified. Keep the wires steady the whole time.',
    'flash_slot0' => // retired, hidden
    'Only application slot 0 is erased and written. The bootloader and identity block stay untouched.',
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
                    child: _DialogScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (!c.phoneMode) ...[
                            _SettingRow(
                              label: 'Default connection',
                              child: _ModeDropdown(
                                c: c,
                                onChanged: () => setLocal(() {}),
                              ),
                            ),
                            const SizedBox(height: 14),
                          ],
                          _SettingRow(
                            label: 'Hold countdown',
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _StepBtn(
                                  icon: Icons.remove,
                                  large: c.phoneMode,
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
                                  large: c.phoneMode,
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
                                  large: c.phoneMode,
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
                                  large: c.phoneMode,
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
                          if (c.browserMode)
                            const Text(
                              'Browser backups are validated in memory and '
                              'downloaded directly. No sidecar, second copy, '
                              'or local log file is written.',
                              style: TextStyle(
                                color: AppColors.mut,
                                fontSize: 12,
                              ),
                            )
                          else if (c.androidMode)
                            const Text(
                              'Backups are saved to '
                              'Downloads/x3utils/backup. Android creates one '
                              'validated .bin with no sidecar or second copy.',
                              style: TextStyle(
                                color: AppColors.mut,
                                fontSize: 12,
                              ),
                            )
                          else
                            _BackupSettingsSection(c: c),
                          ..._advancedSettings(setLocal),
                        ],
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
                      phone: c.phoneMode,
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

  /// The experimental extras, at the end of Settings. They used to sit above
  /// the everyday settings, and the version/engine lines used to close the
  /// dialog; the version and the live engine line now live in About instead.
  ///
  /// Desktop carries the backend and loader switches as well, so it collapses
  /// them behind a caret. Web and Android can only ever reach the one logging
  /// switch, and a caret around a single row hides it for nothing.
  List<Widget> _advancedSettings(StateSetter setLocal) {
    final rows = <Widget>[
      if (c.desktopBackendSelectorAvailable)
        _advancedSwitch(
          label: 'swdart backend',
          switchKey: const ValueKey('desktop-swdart-backend-switch'),
          value: c.useSwdartDesktop,
          onChanged: (value) {
            c.setUseSwdartDesktop(value);
            setLocal(() {});
          },
          description:
              'Experimental global backend. When ON, every hardware action '
              'is sent only to swdart; there is no automatic OpenOCD '
              'fallback.',
        ),
      if (c.desktopSwdartLoaderSelectorAvailable)
        _advancedSwitch(
          label: 'SRAM loader',
          switchKey: const ValueKey('desktop-swdart-loader-switch'),
          value: c.useSwdartLoaderDesktop,
          onChanged: (value) {
            c.setUseSwdartLoaderDesktop(value);
            setLocal(() {});
          },
          description:
              'Experimental swdart accelerator. Turn OFF to use slower direct '
              '32-bit word writes. The choice applies to the next hardware '
              'session.',
        ),
      if (c.loaderDiagnosticsAvailable)
        _advancedSwitch(
          label: 'Advanced logging',
          switchKey: const ValueKey('loader-diagnostics-switch'),
          value: c.loaderDiagnostics,
          onChanged: (value) {
            c.setLoaderDiagnostics(value);
            setLocal(() {});
          },
          description:
              'swdart SRAM-loader only. Logs a register baseline before '
              'flashing and every programming chunk, so an intermittent '
              'failure leaves full evidence.',
        ),
    ];
    if (rows.isEmpty) return const <Widget>[];
    // Desktop ALWAYS keeps the caret, even when the swdart switch is the only
    // row left. Its membership changes as the backend is toggled — turning
    // swdart off takes the loader and diagnostics rows with it — and dropping
    // to a bare row there would destroy the group, so switching back on would
    // rebuild it collapsed and hide the very switches being used. Web/Android
    // have no selector and can only ever reach the one logging row, so they
    // keep the bare form: a caret around a permanently single row hides it for
    // nothing.
    final grouped = c.desktopBackendSelectorAvailable || rows.length > 1;
    return [
      const Divider(color: AppColors.line, height: 28),
      if (grouped) _AdvancedGroup(children: rows) else rows.single,
    ];
  }

  Widget _advancedSwitch({
    required String label,
    required Key switchKey,
    required bool value,
    required ValueChanged<bool> onChanged,
    required String description,
  }) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _SettingRow(
        label: label,
        child: Transform.scale(
          scale: 0.8,
          alignment: Alignment.centerRight,
          child: Switch(
            key: switchKey,
            value: value,
            activeThumbColor: AppColors.brand,
            onChanged: onChanged,
          ),
        ),
      ),
      const SizedBox(height: 4),
      Text(
        description,
        style: const TextStyle(color: AppColors.mut, fontSize: 12),
      ),
    ],
  );

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
            builder: (context, _) {
              if (c.phoneMode) {
                return AndroidConsolePager(
                  c: c,
                  checkPage: SafeArea(
                    child: _AndroidCheckPage(
                      c: c,
                      onStart: _onStart,
                      onSettings: _showSettings,
                      onPickFirmware: _pickFirmware,
                      onPickZip: _pickFirmwareZip,
                    ),
                  ),
                );
              }
              return Column(
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
                                bottom: c.consoleOpen && !c.consolePinned
                                    ? h
                                    : 0,
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
              );
            },
          ),
        ),
      ),
    );
  }
}

class _AndroidCheckPage extends StatefulWidget {
  const _AndroidCheckPage({
    required this.c,
    required this.onStart,
    required this.onSettings,
    required this.onPickFirmware,
    required this.onPickZip,
  });

  final AppController c;
  final Future<void> Function() onStart;
  final VoidCallback onSettings;
  final Future<void> Function() onPickFirmware;
  final Future<void> Function() onPickZip;

  @override
  State<_AndroidCheckPage> createState() => _AndroidCheckPageState();
}

class _AndroidCheckPageState extends State<_AndroidCheckPage>
    with SingleTickerProviderStateMixin {
  bool _connectionOpen = false;
  bool _actionsOpen = false;
  bool _advancedActionsOpen = false;

  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  void _toggleConnection() {
    if (widget.c.running) return;
    setState(() {
      _connectionOpen = !_connectionOpen;
      _actionsOpen = false;
    });
  }

  void _toggleActions() {
    if (widget.c.running) return;
    setState(() {
      _actionsOpen = !_actionsOpen;
      _connectionOpen = false;
    });
  }

  Future<void> _selectAction(String id) async {
    if (widget.c.actionId != id) {
      final warning = switch (id) {
        'flash_compat' => _showShuCompatWarning(context),
        'flash_only' => _showFlashOnlyWarning(context),
        _ => null,
      };
      if (warning != null && await warning != true) return;
      if (!mounted) return;
    }
    widget.c.selectAction(id);
    setState(() => _actionsOpen = false);
  }

  Widget _panel({required Key key, required Widget child}) => Container(
    key: key,
    margin: const EdgeInsets.only(top: 8),
    padding: const EdgeInsets.all(6),
    decoration: BoxDecoration(
      color: AppColors.panel,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: AppColors.line2),
    ),
    child: child,
  );

  Widget _connectionPanel(AppController c) => _panel(
    key: const ValueKey('android-connection-menu'),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 250),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _AndroidChoiceRow(
              key: const ValueKey('android-mode-default'),
              icon: ConnectionMode.defaultSwd.icon,
              iconColor: ConnectionMode.defaultSwd.color,
              badgeIcon: true,
              title: ConnectionMode.defaultSwd.title,
              subtitle: c.probeTransportLabel,
              selected: c.mode == ConnectionMode.defaultSwd,
              enabled: true,
              onTap: () {
                c.selectMode(ConnectionMode.defaultSwd);
                setState(() => _connectionOpen = false);
              },
            ),
            const Divider(color: AppColors.line, height: 1),
            _AndroidChoiceRow(
              key: const ValueKey('android-mode-power-race'),
              icon: ConnectionMode.powerRace.icon,
              iconColor: ConnectionMode.powerRace.color,
              badgeIcon: true,
              title: ConnectionMode.powerRace.title,
              subtitle: ConnectionMode.powerRace.sub,
              selected: c.mode == ConnectionMode.powerRace,
              enabled: c.availableModes.contains(ConnectionMode.powerRace),
              onTap: c.availableModes.contains(ConnectionMode.powerRace)
                  ? () {
                      c.selectMode(ConnectionMode.powerRace);
                      setState(() => _connectionOpen = false);
                    }
                  : null,
            ),
            const Divider(color: AppColors.line, height: 1),
            _AndroidChoiceRow(
              key: const ValueKey('android-mode-clone-c45'),
              icon: ConnectionMode.cloneC45.icon,
              iconColor: ConnectionMode.cloneC45.color,
              badgeIcon: true,
              title: ConnectionMode.cloneC45.title,
              subtitle: ConnectionMode.cloneC45.sub,
              selected: c.mode == ConnectionMode.cloneC45,
              enabled: c.availableModes.contains(ConnectionMode.cloneC45),
              onTap: c.availableModes.contains(ConnectionMode.cloneC45)
                  ? () {
                      c.selectMode(ConnectionMode.cloneC45);
                      setState(() => _connectionOpen = false);
                    }
                  : null,
            ),
            const SizedBox(height: 6),
            KeyedSubtree(
              key: const ValueKey('android-hold-countdown'),
              child: _CountdownStepper(c: c),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _actionChoice(AppController c, String id, {bool enabled = false}) {
    final action = kActions.firstWhere((item) => item.id == id);
    return _AndroidChoiceRow(
      key: ValueKey('android-action-$id'),
      icon: Icons.circle,
      iconColor: action.danger.dot,
      iconSize: 9,
      title: action.name,
      subtitle: enabled
          ? id == 'dump'
                ? c.backupDestinationLabel
                : id == 'flash_backup'
                ? 'Full image or Slot 0 · backs up first'
                : action.script
          : 'Coming later',
      selected: c.actionId == id,
      enabled: enabled,
      onTap: enabled ? () async => _selectAction(id) : null,
    );
  }

  Widget _actionsPanel(AppController c) {
    const advancedIds = ['flash_only', 'rdp_check'];
    return _panel(
      key: const ValueKey('android-actions-menu'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 330),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _actionChoice(c, 'check', enabled: true),
              const Divider(color: AppColors.line, height: 1),
              _actionChoice(c, 'dump', enabled: true),
              const Divider(color: AppColors.line, height: 1),
              _actionChoice(
                c,
                'flash_backup',
                enabled: c.isActionAvailable('flash_backup'),
              ),
              const Divider(color: AppColors.line, height: 1),
              _actionChoice(
                c,
                'flash_compat',
                enabled: c.isActionAvailable('flash_compat'),
              ),
              const Divider(color: AppColors.line, height: 1),
              _AndroidChoiceRow(
                key: const ValueKey('android-actions-advanced'),
                icon: Icons.tune_rounded,
                iconColor: AppColors.brand,
                title: 'Advanced',
                subtitle: 'More tools',
                enabled: true,
                onTap: () => setState(
                  () => _advancedActionsOpen = !_advancedActionsOpen,
                ),
                trailing: AnimatedRotation(
                  turns: _advancedActionsOpen ? 0.5 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: const Icon(
                    Icons.keyboard_arrow_down_rounded,
                    color: AppColors.mut,
                    size: 22,
                  ),
                ),
              ),
              if (_advancedActionsOpen) ...[
                const Divider(color: AppColors.line, height: 1),
                for (final id in advancedIds) ...[
                  _actionChoice(c, id, enabled: c.isActionAvailable(id)),
                  if (id != advancedIds.last)
                    const Divider(color: AppColors.line, height: 1),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _selectorCard({
    required Key key,
    required IconData icon,
    required String title,
    required String subtitle,
    required bool open,
    required VoidCallback onTap,
    required bool opensDown,
    double iconSize = 22,
    required Color iconColor,
    bool badgeIcon = false,
  }) => Material(
    key: key,
    color: AppColors.panel2,
    borderRadius: BorderRadius.circular(14),
    child: InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.brand.withValues(alpha: 0.55)),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              height: 28,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: badgeIcon
                      ? iconColor.withValues(alpha: 0.16)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: badgeIcon
                      ? Border.all(color: iconColor.withValues(alpha: 0.45))
                      : null,
                ),
                child: Center(
                  child: Icon(icon, color: iconColor, size: iconSize),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: AppColors.txt,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(fontSize: 12, color: AppColors.mut),
                  ),
                ],
              ),
            ),
            AnimatedRotation(
              turns: open ? 0.5 : 0,
              duration: const Duration(milliseconds: 180),
              child: Icon(
                opensDown
                    ? Icons.keyboard_arrow_down_rounded
                    : Icons.keyboard_arrow_up_rounded,
                color: AppColors.mut,
                size: 24,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final accent = c.stage.accent;
    return ColoredBox(
      key: const ValueKey('android-check-page'),
      color: AppColors.bg,
      child: Padding(
        // Tight on purpose. The hero card below is Expanded, so every pixel
        // saved in this header lands in the card, where the CTA needs it.
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    gradient: SweepGradient(
                      colors: [
                        AppColors.brand,
                        AppColors.brand2,
                        AppColors.pop,
                        AppColors.brand,
                      ],
                    ),
                  ),
                  child: const Icon(
                    Icons.bolt,
                    size: 19,
                    color: Color(0xFF04120F),
                  ),
                ),
                const SizedBox(width: 11),
                const Text(
                  'x3utils',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: AppColors.txt,
                  ),
                ),
                const Spacer(),
                SizedBox(
                  key: const ValueKey('android-title-menu'),
                  width: 48,
                  height: 48,
                  child: _TitleMenu(c: c, onSettings: widget.onSettings),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Text(
              'CONNECTION',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 2.1,
                color: AppColors.mut,
              ),
            ),
            const SizedBox(height: 9),
            _selectorCard(
              key: const ValueKey('android-default-swd'),
              icon: c.mode.icon,
              iconColor: c.mode.color,
              badgeIcon: true,
              title: c.mode.title,
              subtitle: c.probeTransportLabel,
              open: _connectionOpen,
              onTap: _toggleConnection,
              opensDown: true,
            ),
            if (_connectionOpen) _connectionPanel(c),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxHeight < 500;
                  // The tightest rung exists for ONE case: the two idle
                  // firmware screens, where the firmware bar leaves the CTA no
                  // room. Every other phone screen holds far less content and
                  // ends up with a large void in the card, so squeezing its
                  // gaps to 4-6 px only made elements touch each other while
                  // the space sat unused. Key the rung to the CONTENT, not to
                  // the viewport.
                  final needsTightGaps =
                      c.stage == StageState.idle && c.action.needsFirmware;
                  final roomyCompact =
                      compact &&
                      (!needsTightGaps || constraints.maxHeight >= 450);
                  final verticalPadding = compact ? 10.0 : 20.0;
                  final sectionGap = compact
                      ? (roomyCompact ? 18.0 : 6.0)
                      : 24.0;
                  final controlGap = compact
                      ? (roomyCompact ? 12.0 : 7.0)
                      : 14.0;
                  final visualGap = compact
                      ? (roomyCompact ? 12.0 : 4.0)
                      : 24.0;
                  final titleGap = compact ? (roomyCompact ? 8.0 : 4.0) : 8.0;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    margin: EdgeInsets.only(
                      top: compact ? 12.0 : 14.0,
                      bottom: verticalPadding,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: AppColors.brand.withValues(alpha: 0.55),
                      ),
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
                                    alpha: c.stage == StageState.idle
                                        ? 0.05
                                        : 0.16,
                                  ),
                                  Colors.transparent,
                                ],
                              ),
                            ),
                          ),
                        ),
                        SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 20,
                          ),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              minHeight: math.max(
                                0,
                                constraints.maxHeight -
                                    verticalPadding * 2 -
                                    40,
                              ),
                            ),
                            child: Center(
                              child: SizedBox(
                                width: constraints.maxWidth,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (c.stage != StageState.idle) ...[
                                      Text(
                                        c.heroEyebrow.toUpperCase(),
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: 1.8,
                                          color: accent,
                                        ),
                                      ),
                                      SizedBox(height: compact ? 6 : 8),
                                    ],
                                    Text(
                                      c.stage == StageState.idle
                                          ? c.action.name
                                          : c.heroTitle,
                                      textAlign: TextAlign.center,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: compact ? 25 : 27,
                                        fontWeight: FontWeight.w800,
                                        color: AppColors.txt,
                                      ),
                                    ),
                                    // The idle sub-line is dropped on the two
                                    // firmware screens. The title already
                                    // names the action, the pinned Actions
                                    // card repeats the same subtitle, and the
                                    // firmware bar makes these the only phone
                                    // screens where the CTA runs out of card.
                                    // Every running/guided state keeps its
                                    // message: that one is live evidence.
                                    if (c.stage != StageState.idle ||
                                        !c.action.needsFirmware) ...[
                                      SizedBox(height: titleGap),
                                      Text(
                                        c.stage == StageState.idle
                                            ? c.action.sub
                                            : c.heroMessage,
                                        textAlign: TextAlign.center,
                                        maxLines: compact ? 2 : null,
                                        overflow: compact
                                            ? TextOverflow.ellipsis
                                            : TextOverflow.clip,
                                        style: TextStyle(
                                          fontSize: compact ? 13 : 14,
                                          height: compact ? 1.35 : 1.4,
                                          color: c.stage == StageState.fail
                                              ? AppColors.danger
                                              : AppColors.dim,
                                        ),
                                      ),
                                    ],
                                    SizedBox(height: visualGap),
                                    Center(
                                      child: _Visual(
                                        c: c,
                                        accent: accent,
                                        pulse: _pulse,
                                      ),
                                    ),
                                    if (c.stage == StageState.idle &&
                                        c.action.needsFirmware) ...[
                                      SizedBox(height: controlGap),
                                      _FirmwareBar(
                                        key: const ValueKey(
                                          'android-firmware-bar',
                                        ),
                                        c: c,
                                        onPick: widget.onPickFirmware,
                                        onPickZip: widget.onPickZip,
                                        phone: true,
                                      ),
                                    ],
                                    SizedBox(height: sectionGap),
                                    Center(
                                      child: _StageButtons(
                                        c: c,
                                        onStart: widget.onStart,
                                        stackGuidedOnPhone: true,
                                        phone: true,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            const Text(
              'ACTIONS',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 2.1,
                color: AppColors.mut,
              ),
            ),
            const SizedBox(height: 9),
            if (_actionsOpen) _actionsPanel(c),
            if (_actionsOpen) const SizedBox(height: 8),
            _selectorCard(
              key: const ValueKey('android-check-action'),
              icon: Icons.circle,
              iconColor: c.action.danger.dot,
              iconSize: 9,
              title: c.action.name,
              subtitle: c.actionId == 'dump'
                  ? c.backupDestinationLabel
                  : c.actionId == 'flash_backup'
                  ? 'Full image or Slot 0 · backs up first'
                  : c.action.script,
              open: _actionsOpen,
              onTap: _toggleActions,
              opensDown: false,
            ),
          ],
        ),
      ),
    );
  }
}

class _AndroidChoiceRow extends StatelessWidget {
  const _AndroidChoiceRow({
    super.key,
    required this.icon,
    required this.iconColor,
    this.badgeIcon = false,
    required this.title,
    required this.subtitle,
    this.iconSize = 19,
    this.selected = false,
    this.enabled = false,
    this.onTap,
    this.trailing,
  });

  final IconData icon;
  final Color iconColor;
  final bool badgeIcon;
  final double iconSize;
  final String title;
  final String subtitle;
  final bool selected;
  final bool enabled;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Material(
    color: selected
        ? AppColors.brand.withValues(alpha: 0.08)
        : Colors.transparent,
    borderRadius: BorderRadius.circular(10),
    child: InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              height: 28,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: badgeIcon && enabled
                      ? iconColor.withValues(alpha: selected ? 0.20 : 0.10)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: badgeIcon
                      ? Border.all(
                          color: enabled
                              ? iconColor.withValues(
                                  alpha: selected ? 0.55 : 0.28,
                                )
                              : AppColors.line,
                        )
                      : null,
                ),
                child: Center(
                  child: Icon(
                    icon,
                    size: iconSize,
                    color: enabled ? iconColor : AppColors.mut,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: enabled ? AppColors.txt : AppColors.mut,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11,
                      color: enabled ? AppColors.dim : AppColors.mut,
                    ),
                  ),
                ],
              ),
            ),
            trailing ??
                Icon(
                  selected
                      ? Icons.check_rounded
                      : enabled
                      ? Icons.chevron_right_rounded
                      : Icons.lock_outline_rounded,
                  size: 18,
                  color: selected ? AppColors.brand : AppColors.mut,
                ),
          ],
        ),
      ),
    ),
  );
}

class _DialogScrollView extends StatefulWidget {
  const _DialogScrollView({required this.child});

  final Widget child;

  @override
  State<_DialogScrollView> createState() => _DialogScrollViewState();
}

class _DialogScrollViewState extends State<_DialogScrollView> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: _controller,
      child: SingleChildScrollView(
        controller: _controller,
        padding: const EdgeInsets.only(right: 10),
        child: widget.child,
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
          Text(
            c.browserMode ? 'AT32F415 · WebUSB' : 'AT32F415 · X3 controller',
            style: const TextStyle(fontSize: 12, color: AppColors.mut),
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
      icon: c.phoneMode
          ? null
          : const Icon(Icons.menu_rounded, size: 18, color: AppColors.dim),
      tooltip: 'Menu',
      padding: c.phoneMode ? EdgeInsets.zero : const EdgeInsets.all(8),
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
              // The live engine line, moved here from the foot of Settings.
              // The old hand-written variants named a fixed transport, so the
              // desktop one claimed OpenOCD even with the swdart backend ON.
              // engineDescription reports what is actually selected.
              applicationLegalese:
                  'ST-LINK utilities for X3 scooters\n${c.engineDescription}',
            );
        }
      },
      itemBuilder: (_) => [
        // Android shows the console entry too (see android_console.dart); it
        // drives the same consoleOpen flag the swipe pager listens to. Desktop
        // already showed this item, so it is unchanged.
        _mi(
          'console',
          Icons.terminal_rounded,
          c.consoleOpen ? 'Hide console' : 'Show console',
        ),
        _mi('settings', Icons.settings_rounded, 'Settings…'),
        const PopupMenuDivider(),
        _mi('about', Icons.info_outline_rounded, 'About'),
      ],
      child: c.phoneMode
          ? const SizedBox.expand(
              child: Icon(Icons.menu_rounded, size: 28, color: AppColors.dim),
            )
          : null,
    );
  }

  PopupMenuItem<String> _mi(String v, IconData i, String t) => PopupMenuItem(
    key: ValueKey('title-menu-$v'),
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
              (a) =>
                  a.section == Section.standard &&
                  !a.hidden &&
                  c.isActionAvailable(a.id),
            ))
              _ActionTile(c: c, action: a),
            if (c.hasAdvancedOptions) ...[
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
                            (a) =>
                                a.section == Section.advanced &&
                                !a.hidden &&
                                c.isActionAvailable(a.id),
                          ))
                            _ActionTile(c: c, action: a),
                        ],
                      )
                    : const SizedBox(width: double.infinity),
              ),
            ],
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
      child: Stack(
        children: [
          Material(
            color: selected
                ? AppColors.brand.withValues(alpha: 0.08)
                : AppColors.panel,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => c.selectMode(mode),
              onSecondaryTapDown: (d) =>
                  _showModeMenu(context, d.globalPosition),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
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
                        color: selected
                            ? mode.color.withValues(alpha: 0.20)
                            : const Color(0x0DFFFFFF),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: selected
                              ? mode.color.withValues(alpha: 0.55)
                              : AppColors.line,
                        ),
                      ),
                      child: Icon(
                        mode.icon,
                        size: 15,
                        color: selected
                            ? mode.color
                            : mode.color.withValues(alpha: 0.45),
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
          // Same selected-rail marker the action tiles use, so "selected"
          // reads identically in both rail groups.
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
            large: c.phoneMode,
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
            large: c.phoneMode,
            onTap: () => c.setCountdown(c.countdownSeconds + 1),
          ),
        ],
      ),
    );
  }
}

class _StepBtn extends StatelessWidget {
  const _StepBtn({required this.icon, required this.onTap, this.large = false});
  final IconData icon;
  final VoidCallback onTap;
  final bool large;

  @override
  Widget build(BuildContext context) {
    if (!large) {
      return Material(
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
    return Material(
      color: AppColors.panel2,
      shape: const CircleBorder(side: BorderSide(color: AppColors.line2)),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 36,
          height: 36,
          child: Icon(icon, size: 18, color: AppColors.txt),
        ),
      ),
    );
  }
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
                  if (c.resultPathLabel != null) ...[
                    Text(
                      c.resultPathLabel!,
                      style: const TextStyle(color: AppColors.dim),
                    ),
                    const SizedBox(height: 6),
                  ],
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: kHeroBlockWidth,
                    ),
                    child: DesktopPathDisplay(
                      path: c.resultPath!,
                      action: c.browserMode || c.androidMode
                          ? DesktopPathAction.copy
                          : DesktopPathAction.reveal,
                    ),
                  ),
                ],
                if (c.resultPath != null && c.resultMetadataPath != null) ...[
                  const SizedBox(height: 10),
                  _PillButton(
                    label: 'Show backup info',
                    onTap: () => _showBackupInfo(
                      context,
                      c.resultPath!,
                      c.resultMetadataPath!,
                    ),
                    bg: AppColors.line,
                    fg: AppColors.txt,
                    border: AppColors.line2,
                    small: true,
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
                if (c.stage == StageState.idle &&
                    c.actionId == 'dump' &&
                    c.extraBackupAvailable) ...[
                  const SizedBox(height: 14),
                  _ExtraBackupToggle(c: c),
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
                    c.actionId == 'flash_compat' &&
                    !c.browserMode) ...[
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

/// Standalone Backup BETA opt-in. It is deliberately action-local and
/// transient: Backup + Flash and SHU compat never inherit this request.
class _ExtraBackupToggle extends StatelessWidget {
  const _ExtraBackupToggle({required this.c});

  final AppController c;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: kHeroBlockWidth),
    child: InkWell(
      key: const ValueKey('extra-backup-toggle'),
      onTap: () => c.setExtraBackup(!c.extraBackup),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 8),
        child: Row(
          children: [
            Icon(
              c.extraBackup
                  ? Icons.check_box_rounded
                  : Icons.check_box_outline_blank_rounded,
              size: 19,
              color: c.extraBackup ? AppColors.brand : AppColors.mut,
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Extra backup (BETA)',
                    style: TextStyle(
                      color: c.extraBackup ? AppColors.txt : AppColors.dim,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    'Capture SRAM, read flash twice, compare every byte, and '
                    'save a verified secondary copy plus _EXTRA.json.',
                    style: TextStyle(color: AppColors.mut, fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Reveals local backup identity data only after the operator asks for it.
///
/// Opening the dialog is the first deliberate step; the per-unit values behind
/// it stay masked until [_InfoDialog]'s Reveal is pressed, so the dialog can be
/// shown or screenshotted without exposing them.
Future<void> _showBackupInfo(
  BuildContext context,
  String dumpPath,
  String metadataPath,
) async {
  late Map<String, Object?> metadata;
  try {
    metadata = DumpMetadata.readJson(metadataPath);
    // A sidecar records the first byte-only analysis. For the exact shared MCU
    // banner, the operator may add the one fact those bytes cannot contain:
    // which scooter model's version table to use. This never runs a target
    // action or changes the backup bytes.
    final raw = FileInfo.inspect(dumpPath);
    if (DumpMetadata.needsMcuModelDeclaration(metadata) && raw.needsMcuModel) {
      final model = await _showMcuModelPicker(context, FileInfo.mcuModels);
      if (!context.mounted || model == null) return;
      metadata = DumpMetadata.declareMcuModel(dumpPath, metadataPath, model);
    }
    final report = InfoReport(
      title: 'Backup info',
      intro:
          'Read from the local sidecar. Identity fields stay hidden until you '
          'reveal them; Copy all copies these rows as text.',
      rows: DumpMetadata.rows(metadata),
    );
    if (!context.mounted) return;
    await _showInfoReport(context, report);
  } catch (e) {
    if (!context.mounted) return;
    await _showInfoReport(
      context,
      InfoReport(title: 'Backup info unavailable', message: '$e'),
    );
  }
}

Future<void> _showInfoReport(BuildContext context, InfoReport report) =>
    showDialog<void>(
      context: context,
      barrierColor: const Color(0xB3040A0F),
      builder: (ctx) => _InfoDialog(report: report),
    );

class _InfoDialog extends StatefulWidget {
  const _InfoDialog({required this.report});

  final InfoReport report;

  @override
  State<_InfoDialog> createState() => _InfoDialogState();
}

class _InfoDialogState extends State<_InfoDialog> {
  bool _revealed = false;
  bool _copied = false;
  Timer? _copiedReset;

  @override
  void dispose() {
    _copiedReset?.cancel();
    super.dispose();
  }

  /// Copy all hands over the rows as they read on screen, column-aligned so a
  /// paste into a message or a report stays legible. It is deliberately
  /// independent of Reveal: masking protects the screen, and an operator who
  /// asks for the values gets the values.
  void _copy() {
    final labelWidth =
        widget.report.rows.fold<int>(0, (w, f) => math.max(w, f.label.length)) +
        2;
    Clipboard.setData(
      ClipboardData(
        text: widget.report.rows
            .map((field) => field.plainLine(labelWidth))
            .join('\n'),
      ),
    );
    _copiedReset?.cancel();
    setState(() => _copied = true);
    _copiedReset = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final hasSecrets = widget.report.rows.any((field) => field.hasSecret);
    return Dialog(
      backgroundColor: AppColors.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: AppColors.line2),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.report.title,
                style: const TextStyle(
                  color: AppColors.txt,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (widget.report.intro != null) ...[
                const SizedBox(height: 6),
                Text(
                  widget.report.intro!,
                  style: const TextStyle(color: AppColors.dim, height: 1.4),
                ),
              ],
              const SizedBox(height: 18),
              if (widget.report.message != null)
                Text(
                  widget.report.message!,
                  style: const TextStyle(color: AppColors.dim, height: 1.45),
                ),
              for (final field in widget.report.rows)
                _InfoRow(field.label, field.display(revealed: _revealed)),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (hasSecrets) ...[
                    _PillButton(
                      label: _revealed ? 'Hide' : 'Reveal',
                      onTap: () => setState(() => _revealed = !_revealed),
                      bg: AppColors.line,
                      border: AppColors.line2,
                      small: true,
                    ),
                    const SizedBox(width: 10),
                  ],
                  if (widget.report.rows.isNotEmpty) ...[
                    _PillButton(
                      label: _copied ? 'Copied' : 'Copy all',
                      onTap: _copy,
                      bg: AppColors.line,
                      border: AppColors.line2,
                      small: true,
                    ),
                    const SizedBox(width: 10),
                  ],
                  _PillButton(
                    label: 'Close',
                    onTap: () => Navigator.pop(context),
                    bg: AppColors.line,
                    border: AppColors.line2,
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
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 11),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 86,
          child: Text(
            label,
            style: const TextStyle(
              color: AppColors.dim,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: const TextStyle(
              color: AppColors.txt,
              fontFamily: kMono,
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ),
      ],
    ),
  );
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
        : '${c.unpackPayloadLength} bytes · ${c.unpackFormatLabel} · '
              '${c.unpackProtectionLabel}';
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
                  'Inspect the package, then recover its firmware to a local '
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
        return _IdleShimmerPlate(
          key: const ValueKey('android-idle-visual'),
          size: 84,
        );
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
  const _IdleShimmerPlate({super.key, this.size = 84});

  final double size;

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
            width: widget.size,
            height: widget.size,
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
                    child: Icon(
                      Icons.bolt,
                      color: AppColors.brand,
                      size: widget.size < 84 ? 34 : 38,
                    ),
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
  const _StageButtons({
    required this.c,
    required this.onStart,
    this.stackGuidedOnPhone = false,
    this.phone = false,
  });
  final AppController c;
  final Future<void> Function() onStart;
  final bool stackGuidedOnPhone;
  final bool phone;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    final centerText = phone;
    switch (c.stage) {
      case StageState.idle:
        final needsDeviceProbe = c.deviceProbeBlocksCurrentAction;
        children.add(
          c.actionId == 'make_zip3'
              ? _Zip3PackButton(c: c, onStart: onStart)
              : _PillButton(
                  label: needsDeviceProbe
                      ? c.deviceProbeActionLabel
                      : c.action.cta,
                  onTap: needsDeviceProbe
                      ? c.deviceProbeSelectable
                            ? () => c.selectDeviceProbe()
                            : null
                      : c.canStart
                      ? onStart
                      : null,
                  gradient: needsDeviceProbe
                      ? const [Color(0xFFFFC44D), AppColors.hold]
                      : c.action.danger == DangerLevel.hard
                      ? const [Color(0xFFFF6472), AppColors.danger]
                      : [AppColors.brand, AppColors.brand2],
                  fg: needsDeviceProbe
                      ? const Color(0xFF160F00)
                      : c.action.danger == DangerLevel.hard
                      ? Colors.white
                      : const Color(0xFF04120F),
                  phone: phone,
                  centerText: centerText,
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
            phone: phone,
            centerText: centerText,
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
              phone: phone,
              centerText: centerText,
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
            phone: phone,
            centerText: centerText,
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
            phone: phone,
            centerText: centerText,
          ),
        );
        if (!c.failureNeedsInput || c.showingCompatRecovery) {
          children.add(
            _PillButton(
              label: 'Dismiss',
              onTap: c.dismiss,
              bg: AppColors.line,
              fg: AppColors.txt,
              border: AppColors.line2,
              phone: phone,
              centerText: centerText,
            ),
          );
        }
        break;
    }
    if (stackGuidedOnPhone &&
        (c.stage == StageState.hold ||
            c.stage == StageState.release ||
            c.stage == StageState.fail)) {
      return SizedBox(
        key: const ValueKey('android-guided-stage-buttons'),
        width: math.min(280.0, MediaQuery.sizeOf(context).width - 80),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const SizedBox(height: 10),
              children[i],
            ],
          ],
        ),
      );
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
    phone: phone,
    centerText: phone,
  );
}

/// Selection gate for SHU compat: recent VCU and known MCU firmware versions are not
/// supported, so entering the action requires acknowledging the known version
/// ceilings after a short countdown. Anything except acceptance keeps the
/// previous action selected.
/// MCU firmware carries no model identity and the binaries differ per model, so
/// the operator declares which scooter this is. Deliberately worded as a
/// selection, not a check — nothing here can verify the answer.
Future<String?> _showMcuModelPicker(BuildContext context, List<String> models) {
  return showDialog<String>(
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
            const Text(
              'Which scooter is this?',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.txt,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'This is MCU firmware. Unlike the VCU, an MCU image does not say '
              'which model it belongs to, so x3utils cannot work it out from '
              'the backup. Your answer only selects which firmware versions to '
              'compare against — it is not checked.',
              style: TextStyle(
                fontSize: 13,
                height: 1.45,
                color: AppColors.dim,
              ),
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final m in models)
                  _PillButton(
                    label: m.toUpperCase(),
                    onTap: () => Navigator.pop(ctx, m),
                    bg: AppColors.line,
                    fg: AppColors.txt,
                    border: AppColors.line2,
                    small: true,
                  ),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _PillButton(
                  label: 'Cancel',
                  onTap: () => Navigator.pop(ctx, null),
                  bg: AppColors.line,
                  fg: AppColors.txt,
                  border: AppColors.line2,
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
              'G3 MCU — 1.5.9\n'
              'ZT3 VCU — 1.5.9\n'
              'ZT3 MCU — 1.6.0\n'
              'GT3 VCU — 1.7.2 — for reference only:\n'
              'x3utils does not support SHU compatible on GT3 at any version',
              style: TextStyle(fontSize: 13, height: 1.5, color: AppColors.dim),
            ),
            const SizedBox(height: 20),
            _TimedWarningActions(
              onCancel: () => Navigator.pop(ctx, false),
              onContinue: () => Navigator.pop(ctx, true),
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
            _TimedWarningActions(
              onCancel: () => Navigator.pop(ctx, false),
              onContinue: () => Navigator.pop(ctx, true),
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
class _TimedWarningActions extends StatelessWidget {
  const _TimedWarningActions({
    required this.onCancel,
    required this.onContinue,
  });

  final VoidCallback onCancel;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.sizeOf(context).width < 600;
    final cancel = _PillButton(
      label: 'Cancel',
      onTap: onCancel,
      bg: AppColors.line,
      fg: AppColors.txt,
      border: AppColors.line2,
      small: true,
      phone: phone,
      centerText: phone,
    );
    final proceed = _CountdownPillButton(
      label: 'I understand — continue',
      seconds: 5,
      onTap: onContinue,
      phone: phone,
    );
    if (phone) {
      return Column(
        key: const ValueKey('phone-timed-warning-actions'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [cancel, const SizedBox(height: 10), proceed],
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [cancel, const SizedBox(width: 10), proceed],
    );
  }
}

class _CountdownPillButton extends StatefulWidget {
  const _CountdownPillButton({
    required this.label,
    required this.seconds,
    required this.onTap,
    this.phone = false,
  });
  final String label;
  final int seconds;
  final VoidCallback onTap;
  final bool phone;

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
      phone: widget.phone,
      centerText: widget.phone,
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
    this.phone = false,
    this.centerText = false,
  });
  final String label;
  final VoidCallback? onTap;
  final List<Color>? gradient;
  final Color? bg;
  final Color fg;
  final Color? border;
  final bool small;
  final bool phone;
  final bool centerText;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final textCentered = centerText || phone;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Container(
            height: phone ? (small ? 48 : 52) : null,
            padding: EdgeInsets.symmetric(
              horizontal: small ? 16 : 22,
              vertical: phone ? 0 : (small ? 10 : 12),
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
            child: textCentered
                ? Align(
                    alignment: Alignment.center,
                    widthFactor: 1,
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: small ? 13 : 14,
                        fontWeight: FontWeight.w700,
                        color: fg,
                      ),
                    ),
                  )
                : Text(
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

/// Pack's primary action defaults to zip3.2. The arrow only changes the output
/// format; choosing a menu item never starts the operation.
class _Zip3PackButton extends StatelessWidget {
  const _Zip3PackButton({required this.c, required this.onStart});

  final AppController c;
  final Future<void> Function() onStart;

  @override
  Widget build(BuildContext context) {
    const fg = Color(0xFF04120F);
    final label = c.zip3Format == Zip3Format.rev2
        ? 'Pack zip 3.2'
        : 'Pack zip 3';
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.brand, AppColors.brand2],
          ),
          borderRadius: BorderRadius.circular(999),
          boxShadow: [
            BoxShadow(
              color: AppColors.brand2.withValues(alpha: 0.35),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Opacity(
              opacity: c.canStart ? 1 : 0.45,
              child: InkWell(
                borderRadius: const BorderRadius.horizontal(
                  left: Radius.circular(999),
                ),
                onTap: c.canStart ? onStart : null,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(22, 12, 16, 12),
                  child: Text(
                    label,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: fg,
                    ),
                  ),
                ),
              ),
            ),
            Container(width: 1, height: 24, color: fg.withValues(alpha: 0.2)),
            PopupMenuButton<Zip3Format>(
              tooltip: 'Choose package format',
              position: PopupMenuPosition.under,
              color: AppColors.panel2,
              onSelected: c.setZip3Format,
              itemBuilder: (context) => [
                CheckedPopupMenuItem(
                  value: Zip3Format.rev2,
                  checked: c.zip3Format == Zip3Format.rev2,
                  child: const Text('Pack zip 3.2'),
                ),
                CheckedPopupMenuItem(
                  value: Zip3Format.legacy,
                  checked: c.zip3Format == Zip3Format.legacy,
                  child: const Text('Pack zip 3'),
                ),
              ],
              child: const Padding(
                padding: EdgeInsets.fromLTRB(12, 12, 16, 12),
                child: Icon(Icons.arrow_drop_down_rounded, color: fg, size: 20),
              ),
            ),
          ],
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
          if (c.deviceProbeControlAvailable)
            Flexible(
              child: Tooltip(
                message: c.androidMode
                    ? 'Grant Android USB access to the connected ST-Link'
                    : 'Select or change the ST-Link used by WebUSB',
                child: InkWell(
                  onTap: c.deviceProbeSelectable ? c.selectDeviceProbe : null,
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: _stat(
                      'USB',
                      c.backendStatusLabel,
                      led: _backendLed,
                      valueColor:
                          c.deviceProbeSelectable && c.backendStatus != 'ready'
                          ? AppColors.hold
                          : null,
                      flexibleValue: true,
                    ),
                  ),
                ),
              ),
            )
          else
            _stat(c.backendName, c.backendStatus, led: _backendLed),
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

  Color get _backendLed => c.backendStatus == 'ready'
      ? AppColors.ok
      : c.backendStatus == 'missing' ||
            c.backendStatus == 'unsupported' ||
            c.backendStatus == 'disconnected'
      ? AppColors.danger
      : AppColors.hold;

  Widget _stat(
    String k,
    String v, {
    Color? led,
    Color? valueColor,
    bool flexibleValue = false,
  }) {
    final value = Text(
      v,
      overflow: flexibleValue ? TextOverflow.ellipsis : null,
      style: TextStyle(fontSize: 12, color: valueColor ?? AppColors.dim),
    );
    return Row(
      mainAxisSize: flexibleValue ? MainAxisSize.max : MainAxisSize.min,
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
        if (flexibleValue) Expanded(child: value) else value,
      ],
    );
  }

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
                Text(
                  '${widget.c.backendName} console',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: AppColors.txt,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  widget.c.browserMode ? 'session output' : 'stdout · stderr',
                  style: const TextStyle(color: AppColors.mut, fontSize: 12),
                ),
                const SizedBox(width: 14),
                if (!widget.c.browserMode) _LogToggle(c: widget.c),
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
    super.key,
    required this.c,
    required this.onPick,
    required this.onPickZip,
    this.phone = false,
  });
  final AppController c;
  final Future<void> Function() onPick;
  final Future<void> Function() onPickZip;
  final bool phone;
  @override
  Widget build(BuildContext context) {
    final path = c.firmwarePath;
    final name = path?.split(RegExp(r'[\\/]')).last;
    final has = name != null;
    // The two flash actions share the scoped two-line bar; every other firmware
    // action writes one fixed kind of file and keeps the single-line picker.
    // Retired flash_slot0 keeps the two-line bar (it needs the .zip button) but
    // has no scope to choose.
    final scoped = c.hasFlashScope;
    final slot0 = c.isSlotAction;
    final twoLine = scoped || c.actionId == 'flash_slot0';

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
                  label: has
                      ? 'Change'
                      : c.actionId == 'file_info'
                      ? 'Choose .bin / .zip'
                      : 'Choose .bin',
                  onTap: () => onPick(),
                  bg: AppColors.line,
                  fg: AppColors.txt,
                  border: AppColors.line2,
                  small: true,
                  phone: phone,
                  centerText: phone,
                ),
              ],
            ),
          ],
        ),
      );
    }

    // The phone drops this line. It is the last block the hero card can give
    // back to the CTA, and the scope control directly above already carries
    // the same choice. A height-gated version was tried and reverted: the
    // threshold landed between gesture and 3-button navigation, so the line
    // appeared or vanished with a system setting. Desktop keeps the wording.
    final hint = has || phone
        ? null
        : slot0
        ? 'Choose a slot-sized .bin or import a VCU/MCU zip3 or zip3.2 package.'
        : 'zip3 and zip3.2 packages contain slot firmware — select Slot 0 only.';
    return Container(
      constraints: const BoxConstraints(maxWidth: kHeroBlockWidth),
      padding: EdgeInsets.fromLTRB(14, phone ? 8 : 10, 14, phone ? 9 : 11),
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
          SizedBox(height: phone ? 8 : 10),
          const Divider(height: 1, color: AppColors.line),
          SizedBox(height: phone ? 8 : 10),
          if (scoped) ...[
            _FlashScopeControl(c: c),
            SizedBox(height: phone ? 8 : 10),
          ],
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  key: const ValueKey('firmware-pick-bin'),
                  width: double.infinity,
                  child: _PillButton(
                    label: 'Choose .bin',
                    onTap: () => onPick(),
                    bg: AppColors.line,
                    fg: AppColors.txt,
                    border: AppColors.line2,
                    small: true,
                    phone: phone,
                    centerText: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  key: const ValueKey('firmware-pick-zip'),
                  width: double.infinity,
                  child: _PillButton(
                    label: 'Choose .zip',
                    onTap: slot0 ? () => onPickZip() : null,
                    bg: AppColors.line,
                    fg: AppColors.txt,
                    border: AppColors.line2,
                    small: true,
                    phone: phone,
                    centerText: true,
                  ),
                ),
              ),
            ],
          ),
          if (hint != null) ...[
            SizedBox(height: phone ? 6 : 8),
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

class _FlashScopeControl extends StatelessWidget {
  const _FlashScopeControl({required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('firmware-scope'),
      height: c.phoneMode ? 48 : 42,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0x30000000),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.line2),
      ),
      child: Row(
        children: [
          _item('Full image', FlashScope.fullImage),
          _item('Slot 0 only', FlashScope.slot0),
        ],
      ),
    );
  }

  Widget _item(String label, FlashScope scope) {
    final selected = c.flashScope == scope;
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: selected ? null : () => c.setFlashScope(scope),
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
/// preselected from a readable VCU/MCU banner), the legacy-only enforce-model
/// checkbox, and an editable package name.
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
              if (c.zip3Format == Zip3Format.legacy) ...[
                const SizedBox(height: 10),
                _EnforceModelToggle(c: c),
              ],
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

/// Faint opt-ins under the "Make SHU compatible" pill: after the patched image
/// flashes, also repackage BOTH the patched and the stock firmware as
/// BLE-loadable packages. Each ticked format produces two files.
///
/// Two boxes rather than one because two generations of the BLE app are in the
/// field — 3.x reads only legacy zip3, 4.x is expected to read both — and the
/// operator, not x3utils, knows which one their phone is running. Off by
/// default; MCU packages use the operator-declared model.
class _CompatZip3Toggle extends StatelessWidget {
  const _CompatZip3Toggle({required this.c});
  final AppController c;

  Widget _box(String label, bool on, void Function(bool) set) => InkWell(
    onTap: () => set(!on),
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
            label,
            style: TextStyle(
              fontSize: 12,
              color: on ? AppColors.txt : AppColors.dim,
            ),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    // Both formats are offered: SHU 4.2 reads zip3.2, and legacy zip3 covers
    // 3.x and 4.x, so the operator picks by the app version their scooter's
    // phone is running. Each ticked box packs both the patched and stock images.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _box(
          'Also make zip 3 (all SHU versions)',
          c.compatMakeZip3,
          c.setCompatMakeZip3,
        ),
        _box(
          'Also make zip 3.2 (SHU 4.2+)',
          c.compatMakeZip32,
          c.setCompatMakeZip32,
        ),
      ],
    );
  }
}

/// The legacy zip3 "Enforce model" checkbox. Zip3.2 uses `models` and has no
/// `enforceModel` field, so the form hides this control for the default format.
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

/// Collapsed "Advanced" group at the end of Settings. It starts closed on
/// purpose: these switches are bench instruments, not everyday settings. The
/// caller owns the rows, so the group only owns the open/closed state.
class _AdvancedGroup extends StatefulWidget {
  const _AdvancedGroup({required this.children});
  final List<Widget> children;
  @override
  State<_AdvancedGroup> createState() => _AdvancedGroupState();
}

class _AdvancedGroupState extends State<_AdvancedGroup> {
  bool _open = false;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      InkWell(
        key: const ValueKey('settings-advanced-caret'),
        onTap: () => setState(() => _open = !_open),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              AnimatedRotation(
                turns: _open ? 0.25 : 0,
                duration: const Duration(milliseconds: 150),
                child: const Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: AppColors.dim,
                ),
              ),
              const SizedBox(width: 6),
              const Text(
                'Advanced',
                style: TextStyle(
                  color: AppColors.txt,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
      if (_open)
        for (int i = 0; i < widget.children.length; i++) ...[
          SizedBox(height: i == 0 ? 10 : 14),
          widget.children[i],
        ],
    ],
  );
}

class _AccentPicker extends StatelessWidget {
  const _AccentPicker({required this.c, required this.onChanged});
  final AppController c;
  final VoidCallback onChanged;
  @override
  Widget build(BuildContext context) {
    final itemCount = c.phoneMode
        ? math.min(4, kAccents.length)
        : kAccents.length;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < itemCount; i++) ...[
          if (i > 0) SizedBox(width: c.phoneMode ? 6 : 10),
          Tooltip(
            message: kAccents[i].name,
            child: GestureDetector(
              onTap: () {
                c.setAccent(i);
                onChanged();
              },
              child: SizedBox(
                key: ValueKey('accent-choice-$i'),
                width: c.phoneMode ? 40 : 26,
                height: c.phoneMode ? 40 : 26,
                child: Center(
                  child: Container(
                    width: c.phoneMode ? 32 : 26,
                    height: c.phoneMode ? 32 : 26,
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
          for (final m in c.availableModes)
            DropdownMenuItem(value: m, child: Text(m.title)),
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
