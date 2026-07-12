import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'app_controller.dart';
import 'engine/firmware.dart';
import 'models.dart';
import 'theme.dart';

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
    if (a.danger != DangerLevel.none) {
      final ok = await _showConfirm(a);
      if (ok != true) return;
    }
    c.start();
  }

  /// CLI muscle-memory: Enter fires the primary CTA for the current stage
  /// (Start / guided Continue / Done / Retry). Running stages ignore it, so
  /// Enter can never cancel a flash mid-write.
  void _onEnter() {
    switch (c.stage) {
      case StageState.idle:
        if (!(c.action.needsFirmware && c.firmwarePath == null)) _onStart();
        break;
      case StageState.hold:
      case StageState.release:
        if (c.showContinue) c.continueStep();
        break;
      case StageState.ok:
      case StageState.warn:
        c.dismiss();
        break;
      case StageState.fail:
        c.retry();
        break;
      case StageState.count:
      case StageState.connect:
      case StageState.run:
        break;
    }
  }

  Future<void> _pickFirmware() async {
    const group = XTypeGroup(label: 'firmware', extensions: ['bin']);
    final file = await openFile(acceptedTypeGroups: [group]);
    if (file == null) return;
    // Validate for the current kind so we never remember a wrong-sized bin.
    final check = c.isSlotAction
        ? Firmware.validateSlot(file.path)
        : Firmware.validate(file.path, requireSize: true);
    if (!check.ok) {
      // A rejected pick leaves no confirmed-good selection for this kind —
      // clear it so Start doesn't stay lit on a stale/invalid file.
      c.setFirmware(null);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(check.message,
              style: const TextStyle(color: Colors.white)),
          backgroundColor: AppColors.danger,
          behavior: SnackBarBehavior.floating,
        ));
      return;
    }
    c.setFirmware(file.path);
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
                child: Icon(hard ? Icons.warning_amber_rounded : Icons.bolt,
                    color: accent, size: 24),
              ),
              const SizedBox(height: 14),
              Text(hard ? 'Heads up — this is destructive' : 'Confirm ${a.name}',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.txt)),
              const SizedBox(height: 8),
              Text(_confirmBody(a),
                  style: const TextStyle(
                      fontSize: 13, height: 1.5, color: AppColors.dim)),
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

  String _confirmBody(FlashAction a) => switch (a.id) {
        'flash_only' =>
          'No backup will be taken. If this write goes wrong there is nothing to restore from. Only do this if you already have a good dump.',
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
                  maxHeight: MediaQuery.of(ctx).size.height * 0.85),
              child: SingleChildScrollView(
                child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.settings_rounded,
                        color: AppColors.brand, size: 22),
                    SizedBox(width: 10),
                    Text('Settings',
                        style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: AppColors.txt)),
                  ],
                ),
                const SizedBox(height: 18),
                _SettingRow(
                  label: 'Default connection',
                  child: _ModeDropdown(c: c, onChanged: () => setLocal(() {})),
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
                            c.setDefaultCountdown(c.defaultCountdown - 1);
                            setLocal(() {});
                          }),
                      SizedBox(
                        width: 30,
                        child: Text('${c.defaultCountdown}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontFamily: kMono,
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: AppColors.txt)),
                      ),
                      _StepBtn(
                          icon: Icons.add,
                          onTap: () {
                            c.setDefaultCountdown(c.defaultCountdown + 1);
                            setLocal(() {});
                          }),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                _SettingRow(
                  label: 'Theme accent',
                  child: _AccentPicker(c: c, onChanged: () => setLocal(() {})),
                ),
                const Divider(color: AppColors.line, height: 28),
                _BackupSettingsSection(c: c),
                const Divider(color: AppColors.line, height: 28),
                Text('x3utils  ·  v$kAppVersion',
                    style: const TextStyle(
                        color: AppColors.dim,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                const Text('Engine: bundled OpenOCD (frozen) · AT32F415',
                    style: TextStyle(color: AppColors.mut, fontSize: 12)),
                const SizedBox(height: 20),
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
                              onPickFirmware: _pickFirmware)),
                    ],
                  );

                  // Pinned → dock alongside (pushes content up, stays put).
                  if (c.consoleOpen && c.consolePinned) {
                    return Column(
                      children: [
                        Expanded(child: mainRow),
                        _ConsolePanel(
                            c: c, height: h, maxHeight: maxH, docked: true),
                      ],
                    );
                  }

                  // Unpinned → float over, but reserve its height so the hero
                  // centers ABOVE it instead of being hidden behind it.
                  return Stack(
                    children: [
                      Padding(
                        padding: EdgeInsets.only(
                            bottom:
                                c.consoleOpen && !c.consolePinned ? h : 0),
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
                          offset:
                              c.consoleOpen ? Offset.zero : const Offset(0, 1),
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeOutCubic,
                          child: _ConsolePanel(
                              c: c, height: h, maxHeight: maxH, docked: false),
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
                colors: [AppColors.brand, AppColors.brand2, AppColors.pop, AppColors.brand],
              ),
              boxShadow: [
                BoxShadow(color: AppColors.brand.withValues(alpha: 0.5), blurRadius: 18),
              ],
            ),
            child: const Icon(Icons.bolt, size: 16, color: Color(0xFF04120F)),
          ),
          const SizedBox(width: 11),
          const Text('x3utils',
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w800, color: AppColors.txt)),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: AppColors.brand.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: AppColors.brand.withValues(alpha: 0.35)),
            ),
            child: Text('v$kAppVersion',
                style: TextStyle(
                    fontFamily: kMono,
                    fontSize: 11,
                    color: AppColors.brand,
                    fontWeight: FontWeight.w600)),
          ),
          const Spacer(),
          const Text('AT32F415 · X3 controller',
              style: TextStyle(fontSize: 12, color: AppColors.mut)),
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
  const _BarIconButton(
      {required this.icon, required this.onTap, this.tooltip, this.active = false});
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
              applicationVersion: 'v$kAppVersion',
              applicationLegalese:
                  'ST-LINK utilities for X3 scooters · AT32F415 · bundled OpenOCD',
            );
        }
      },
      itemBuilder: (_) => [
        _mi('console', Icons.terminal_rounded,
            c.consoleOpen ? 'Hide console' : 'Show console'),
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
            for (final m in c.modesIn(Section.standard)) _ModeTile(c: c, mode: m),
            if (c.mode.guided) ...[
              const SizedBox(height: 8),
              _CountdownStepper(c: c),
            ],
            const SizedBox(height: 20),
            const _RailLabel('Actions'),
            for (final a in kActions.where((a) => a.section == Section.standard))
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
                        for (final a
                            in kActions.where((a) => a.section == Section.advanced))
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
        child: Text(text.toUpperCase(),
            style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.6,
                color: AppColors.mut)),
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
              const Text('ADVANCED',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.6,
                      color: AppColors.mut)),
              const SizedBox(width: 7),
              Icon(c.advancedOpen ? Icons.lock_open_rounded : Icons.lock_outline_rounded,
                  size: 12, color: AppColors.mut),
              const Spacer(),
              AnimatedRotation(
                turns: c.advancedOpen ? 0.5 : 0,
                duration: const Duration(milliseconds: 200),
                child: const Icon(Icons.expand_more_rounded,
                    size: 18, color: AppColors.dim),
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
          pos & const Size(40, 40), Offset.zero & overlay.size),
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
        color: selected ? AppColors.brand.withValues(alpha: 0.08) : AppColors.panel,
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
                      : AppColors.line),
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
                        color: selected ? Colors.transparent : AppColors.line),
                  ),
                  child: Text(mode.tag,
                      style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                          color: selected ? const Color(0xFF04120F) : AppColors.dim)),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(mode.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: AppColors.txt)),
                      Text(mode.sub,
                          style: const TextStyle(fontSize: 11, color: AppColors.dim)),
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
            child: Text('Hold countdown',
                style: TextStyle(fontSize: 12, color: AppColors.dim)),
          ),
          _StepBtn(icon: Icons.remove, onTap: () => c.setCountdown(c.countdownSeconds - 1)),
          SizedBox(
            width: 30,
            child: Text('${c.countdownSeconds}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontFamily: kMono,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppColors.txt)),
          ),
          _StepBtn(icon: Icons.add, onTap: () => c.setCountdown(c.countdownSeconds + 1)),
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
              onTap: () => c.selectAction(action.id),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                      color: selected ? AppColors.line2 : Colors.transparent),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                          color: action.danger.dot, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(action.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.txt)),
                          Text(action.script,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontFamily: kMono,
                                  fontSize: 11,
                                  color: AppColors.dim)),
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

class _MainArea extends StatelessWidget {
  const _MainArea(
      {required this.c, required this.onStart, required this.onPickFirmware});
  final AppController c;
  final Future<void> Function() onStart;
  final Future<void> Function() onPickFirmware;

  @override
  Widget build(BuildContext context) {
    final a = c.action;
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
                    Text(a.name,
                        style: const TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.w800,
                            color: AppColors.txt)),
                    const SizedBox(height: 5),
                    Text(a.sub,
                        style: const TextStyle(
                            fontSize: 13, height: 1.45, color: AppColors.dim)),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 200),
                child: Wrap(
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
                c: c, onStart: onStart, onPickFirmware: onPickFirmware)),
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
              width: 6, height: 6, decoration: BoxDecoration(color: col, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Text(data.label.toUpperCase(),
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  color: col)),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────── hero stage

class _HeroStage extends StatefulWidget {
  const _HeroStage(
      {required this.c, required this.onStart, required this.onPickFirmware});
  final AppController c;
  final Future<void> Function() onStart;
  final Future<void> Function() onPickFirmware;
  @override
  State<_HeroStage> createState() => _HeroStageState();
}

class _HeroStageState extends State<_HeroStage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))
        ..repeat();

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
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
                  gradient: RadialGradient(
                    center: Alignment.topCenter,
                    radius: 1.1,
                    colors: [
                      accent.withValues(alpha: c.stage == StageState.idle ? 0.05 : 0.16),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            Center(
              child: SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(c.eyebrow.toUpperCase(),
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 2.8,
                                color: accent)),
                        const SizedBox(height: 14),
                        Text(c.title,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontSize: 30,
                                fontWeight: FontWeight.w800,
                                height: 1.08,
                                color: AppColors.txt)),
                        const SizedBox(height: 12),
                        Text(c.sub,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontSize: 14, height: 1.5, color: AppColors.dim)),
                        const SizedBox(height: 22),
                        _Visual(c: c, accent: accent, pulse: _pulse),
                        if (c.stage == StageState.idle &&
                            c.action.needsFirmware) ...[
                          const SizedBox(height: 20),
                          _FirmwareBar(c: c, onPick: widget.onPickFirmware),
                        ],
                        const SizedBox(height: 26),
                        _StageButtons(c: c, onStart: widget.onStart),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
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
        return Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(
            color: AppColors.brand.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppColors.line2),
          ),
          child: Icon(Icons.bolt, color: AppColors.brand, size: 38),
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
              child: Text('${c.countdownValue}',
                  style: TextStyle(
                      fontFamily: kMono,
                      fontSize: 56,
                      fontWeight: FontWeight.w800,
                      color: accent)),
            ),
          ),
        );
      case StageState.connect:
        return SizedBox(
          width: 64,
          height: 64,
          child: CircularProgressIndicator(
              strokeWidth: 5, color: accent, backgroundColor: AppColors.line2),
        );
      case StageState.run:
        return _Progress(c: c);
      case StageState.ok:
        return _ResultBadge(accent: accent, icon: Icons.check_rounded);
      case StageState.warn:
        return _ResultBadge(accent: accent, icon: Icons.lock_rounded);
      case StageState.fail:
        return _ResultBadge(accent: accent, icon: Icons.close_rounded);
    }
  }
}

/// The C45 contact visual: a wire with an arrow either pointing INTO the pad
/// (hold — press the wire on) or OUT of it (release — pull the wire off), with
/// a pulsing glowing contact dot.
class _Pad extends StatelessWidget {
  const _Pad(
      {required this.accent, required this.pulse, required this.release});
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
              accent: accent, t: pulse.value, release: release),
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
        size.width - padSize, (size.height - padSize) / 2, padSize, padSize);
    final rrect = RRect.fromRectAndRadius(padRect, const Radius.circular(18));
    final center = padRect.center;

    // pulse intensity (smooth)
    final g = 0.5 + 0.5 * math.sin(t * 2 * math.pi);

    // pad body
    canvas.drawRRect(
        rrect, Paint()..color = const Color(0xFF1B2331));
    canvas.drawRRect(
        rrect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = AppColors.line2);

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
        ..shader = ui.Gradient.linear(
            tail, tip, [AppColors.mut, accent]),
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
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 10 + 4 * g));
    canvas.drawCircle(
        center,
        15,
        Paint()
          ..color = accent.withValues(alpha: 0.35)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
    canvas.drawCircle(center, 11, Paint()..color = accent);
    canvas.drawCircle(center.translate(-3, -3), 3.5,
        Paint()..color = Colors.white.withValues(alpha: 0.55));
  }

  @override
  bool shouldRepaint(_PadPainter old) =>
      old.t != t || old.accent != accent || old.release != release;
}

class _Progress extends StatelessWidget {
  const _Progress({required this.c});
  final AppController c;
  @override
  Widget build(BuildContext context) {
    final a = c.action;
    final done = c.stageDone.where((d) => d).length;
    final frac = a.stages.isEmpty ? 0.0 : done / a.stages.length;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: frac,
              minHeight: 8,
              backgroundColor: const Color(0x14FFFFFF),
              valueColor: AlwaysStoppedAnimation(AppColors.brand),
            ),
          ),
          const SizedBox(height: 16),
          for (var i = 0; i < a.stages.length; i++)
            _StageRow(
              label: a.stages[i],
              done: i < c.stageDone.length && c.stageDone[i],
              active: i == c.activeStage &&
                  !(i < c.stageDone.length && c.stageDone[i]),
            ),
        ],
      ),
    );
  }
}

class _StageRow extends StatelessWidget {
  const _StageRow(
      {required this.label, required this.done, required this.active});
  final String label;
  final bool done;
  final bool active;
  @override
  Widget build(BuildContext context) {
    final color = done
        ? AppColors.dim
        : active
            ? AppColors.txt
            : AppColors.mut;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: done ? AppColors.ok : Colors.transparent,
              border: Border.all(
                  color: done
                      ? AppColors.ok
                      : active
                          ? AppColors.brand
                          : AppColors.line2,
                  width: 2),
            ),
            child: done
                ? const Icon(Icons.check, size: 12, color: Color(0xFF04120F))
                : active
                    ? SizedBox(
                        width: 9,
                        height: 9,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: AppColors.brand))
                    : null,
          ),
          const SizedBox(width: 11),
          Text(label,
              style: TextStyle(
                  fontSize: 13,
                  color: color,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400)),
        ],
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
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius), -math.pi / 2,
        2 * math.pi * fraction.clamp(0.0, 1.0), false, fg);
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
        final needsFirmware =
            c.action.needsFirmware && c.firmwarePath == null;
        children.add(_PillButton(
          label: c.action.cta,
          onTap: needsFirmware ? null : onStart,
          gradient: c.action.danger == DangerLevel.hard
              ? const [Color(0xFFFF6472), AppColors.danger]
              : [AppColors.brand, AppColors.brand2],
          fg: c.action.danger == DangerLevel.hard
              ? Colors.white
              : const Color(0xFF04120F),
        ));
        break;
      case StageState.hold:
      case StageState.release:
        final rel = c.stage == StageState.release;
        children.add(_PillButton(
          label: c.continueLabel,
          onTap: c.showContinue ? c.continueStep : null,
          gradient: rel
              ? const [Color(0xFFFF9A5C), AppColors.release]
              : const [Color(0xFFFFC44D), AppColors.hold],
          fg: const Color(0xFF160F00),
        ));
        children.add(_cancel(c));
        break;
      case StageState.count:
      case StageState.connect:
      case StageState.run:
        children.add(_cancel(c));
        break;
      case StageState.ok:
      case StageState.warn:
        children.add(_PillButton(
          label: 'Done',
          onTap: c.dismiss,
          gradient: [AppColors.brand, AppColors.brand2],
          fg: const Color(0xFF04120F),
        ));
        break;
      case StageState.fail:
        children.add(_PillButton(
          label: 'Retry',
          onTap: () => c.retry(),
          gradient: [AppColors.brand, AppColors.brand2],
          fg: const Color(0xFF04120F),
        ));
        children.add(_PillButton(
          label: 'Dismiss',
          onTap: c.dismiss,
          bg: AppColors.line,
          fg: AppColors.txt,
          border: AppColors.line2,
        ));
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
                horizontal: small ? 16 : 22, vertical: small ? 10 : 12),
            decoration: BoxDecoration(
              color: gradient == null ? (bg ?? Colors.transparent) : null,
              gradient: gradient == null
                  ? null
                  : LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: gradient!),
              borderRadius: BorderRadius.circular(999),
              border: border == null ? null : Border.all(color: border!),
              boxShadow: gradient == null
                  ? null
                  : [
                      BoxShadow(
                          color: gradient!.last.withValues(alpha: 0.35),
                          blurRadius: 18,
                          offset: const Offset(0, 8)),
                    ],
            ),
            child: Text(label,
                style: TextStyle(
                    fontSize: small ? 13 : 14,
                    fontWeight: FontWeight.w700,
                    color: fg)),
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
          _stat('OpenOCD', c.openOcdStatus,
              led: c.openOcdStatus == 'ready'
                  ? AppColors.ok
                  : c.openOcdStatus == 'missing'
                      ? AppColors.danger
                      : AppColors.hold),
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
              child: Text(c.consoleOpen ? '▾ Console' : '▤ Console',
                  style: TextStyle(
                      fontSize: 12,
                      color: AppColors.brand,
                      fontWeight: FontWeight.w600)),
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
                    boxShadow: [BoxShadow(color: led, blurRadius: 8)])),
            const SizedBox(width: 7),
          ],
          Text('$k ',
              style: const TextStyle(fontSize: 12, color: AppColors.mut)),
          Text(v, style: const TextStyle(fontSize: 12, color: AppColors.dim)),
        ],
      );

  Widget _sep() => Container(
      width: 1,
      height: 18,
      margin: const EdgeInsets.symmetric(horizontal: 14),
      color: AppColors.line);
}

// ─────────────────────────────────────────── console drawer

class _ConsolePanel extends StatefulWidget {
  const _ConsolePanel(
      {required this.c,
      required this.height,
      required this.maxHeight,
      required this.docked});
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
    final text =
        body.isEmpty ? '' : '${widget.c.contextHeader()}\n\n$body';
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(text.isEmpty ? 'Console is empty' : 'Console copied',
            style: const TextStyle(
                color: AppColors.txt, fontWeight: FontWeight.w600)),
        duration: const Duration(milliseconds: 1200),
        behavior: SnackBarBehavior.floating,
        width: 200,
        backgroundColor: AppColors.elev,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: AppColors.line2)),
      ));
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
          BoxShadow(color: Color(0x66000000), blurRadius: 30, offset: Offset(0, -12)),
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
                const Text('OpenOCD console',
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppColors.txt,
                        fontSize: 13)),
                const SizedBox(width: 10),
                const Text('stdout · stderr',
                    style: TextStyle(color: AppColors.mut, fontSize: 12)),
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
                    child: Text('// waiting for first action…',
                        style: TextStyle(
                            fontFamily: kMono, color: AppColors.mut, fontSize: 12)),
                  )
                : ListView.builder(
                    controller: _sc,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    itemCount: lines.length,
                    itemBuilder: (_, i) => Text(lines[i],
                        style: TextStyle(
                            fontFamily: kMono,
                            fontSize: 12,
                            height: 1.55,
                            color: _lineColor(lines[i]))),
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
          child: Text(label,
              style: TextStyle(
                  color: AppColors.brand,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
        ),
      );
}

class _FirmwareBar extends StatelessWidget {
  const _FirmwareBar({required this.c, required this.onPick});
  final AppController c;
  final Future<void> Function() onPick;
  @override
  Widget build(BuildContext context) {
    final path = c.firmwarePath;
    final name = path?.split(RegExp(r'[\\/]')).last;
    final has = name != null;
    return Container(
      constraints: const BoxConstraints(maxWidth: 460),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: has ? AppColors.brand.withValues(alpha: 0.4) : AppColors.line2),
      ),
      child: Row(
        children: [
          Icon(has ? Icons.memory_rounded : Icons.folder_open_rounded,
              size: 18, color: has ? AppColors.brand : AppColors.mut),
          const SizedBox(width: 10),
          Expanded(
            child: Text(name ?? 'No firmware chosen',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontFamily: has ? kMono : null,
                    fontSize: 13,
                    color: has ? AppColors.txt : AppColors.dim)),
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
              Text('Save log',
                  style: TextStyle(
                      fontSize: 12,
                      color: on ? AppColors.brand : AppColors.mut,
                      fontWeight: FontWeight.w600)),
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
          child: Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined,
              size: 16, color: pinned ? AppColors.brand : AppColors.dim),
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
            child: Text(label,
                style: const TextStyle(
                    color: AppColors.txt,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
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
                      colors: [kAccents[i].brand, kAccents[i].pop]),
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
                              blurRadius: 8)
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
  late final TextEditingController _prefix =
      TextEditingController(text: widget.c.backupPrefix);

  @override
  void dispose() {
    _prefix.dispose();
    super.dispose();
  }

  Future<void> _browse() async {
    final dir = await getDirectoryPath();
    if (dir != null) {
      widget.c.setBackupFolder(dir);
      setState(() {});
    }
  }

  String _clean(String s) =>
      s.trim().replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '');

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final folder = c.backupFolder ?? '${Firmware.backupDirLabel}  (default)';
    final pre = _clean(_prefix.text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.folder_copy_rounded, size: 18, color: AppColors.brand),
            const SizedBox(width: 8),
            Text('Backups',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppColors.txt)),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            const Expanded(
                child: Text('Backup folder',
                    style: TextStyle(
                        color: AppColors.txt,
                        fontSize: 13,
                        fontWeight: FontWeight.w600))),
            _ConsoleAction(label: 'Browse…', onTap: () => _browse()),
            if (c.backupFolder != null) ...[
              const SizedBox(width: 14),
              _ConsoleAction(
                  label: 'Reset',
                  onTap: () {
                    c.setBackupFolder(null);
                    setState(() {});
                  }),
            ],
          ],
        ),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.panel2,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.line2),
          ),
          child: Text(folder,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontFamily: kMono, fontSize: 12, color: AppColors.dim)),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            const Expanded(
                child: Text('Filename prefix',
                    style: TextStyle(
                        color: AppColors.txt,
                        fontSize: 13,
                        fontWeight: FontWeight.w600))),
            SizedBox(
              width: 150,
              child: TextField(
                controller: _prefix,
                onChanged: (v) {
                  c.setBackupPrefix(v);
                  setState(() {});
                },
                style: const TextStyle(
                    color: AppColors.txt, fontSize: 13, fontFamily: kMono),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'none',
                  hintStyle: const TextStyle(color: AppColors.mut),
                  filled: true,
                  fillColor: AppColors.panel2,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppColors.line2)),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: AppColors.brand)),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text('${pre.isEmpty ? '' : '${pre}_'}dump_<time>.bin',
            style: const TextStyle(
                color: AppColors.mut, fontSize: 12, fontFamily: kMono)),
        const SizedBox(height: 10),
        Row(
          children: [
            const Expanded(
                child: Text('Keep a 2nd copy',
                    style: TextStyle(
                        color: AppColors.txt,
                        fontSize: 13,
                        fontWeight: FontWeight.w600))),
            Switch(
              value: c.secondCopy,
              activeThumbColor: AppColors.brand,
              onChanged: (v) {
                c.setSecondCopy(v);
                setState(() {});
              },
            ),
          ],
        ),
        Text(Firmware.secondCopyLabel,
            style: const TextStyle(
                color: AppColors.mut, fontSize: 12, fontFamily: kMono)),
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
              for (final m in ConnectionMode.values)
                DropdownMenuItem(
                    value: m, child: Text('${m.tag} · ${m.title}')),
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
