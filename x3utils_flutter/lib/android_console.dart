// Swipe-to-console for Android, kept deliberately self-contained.
//
// By design this does NOT reuse the desktop `_ConsolePanel`: the line rendering
// below is a private copy so the mobile console and the desktop/web console can
// evolve independently. The trade-off is that a change to one does not
// propagate to the other — accepted on purpose to keep the two decoupled.
//
// The console is reached by swiping left from the check page or via the
// hamburger "Show console" entry; both drive `AppController.consoleOpen`, which
// the pager below animates to. Swipe back or tap the back arrow to return.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_controller.dart';
import 'theme.dart';

/// Two-page horizontal pager: the existing Android check page on the left, a
/// full-screen console on the right. The page position is kept in sync with the
/// controller's [AppController.consoleOpen] flag so the swipe and the hamburger
/// menu entry agree on one source of truth.
class AndroidConsolePager extends StatefulWidget {
  const AndroidConsolePager({
    super.key,
    required this.c,
    required this.checkPage,
  });

  final AppController c;
  final Widget checkPage;

  @override
  State<AndroidConsolePager> createState() => _AndroidConsolePagerState();
}

class _AndroidConsolePagerState extends State<AndroidConsolePager> {
  final PageController _pc = PageController();

  @override
  void initState() {
    super.initState();
    widget.c.addListener(_syncPage);
  }

  @override
  void dispose() {
    widget.c.removeListener(_syncPage);
    _pc.dispose();
    super.dispose();
  }

  /// Drive the page from consoleOpen when the change came from outside a drag
  /// (e.g. the back arrow). The isScrolling guard keeps this from fighting an
  /// in-progress swipe or our own settle animation.
  void _syncPage() {
    if (!_pc.hasClients) return;
    if (_pc.position.isScrollingNotifier.value) return;
    final target = widget.c.consoleOpen ? 1 : 0;
    final current = (_pc.page ?? 0).round();
    if (current == target) return;
    _pc.animateToPage(
      target,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    return PageView(
      controller: _pc,
      onPageChanged: (i) {
        final open = i == 1;
        if (widget.c.consoleOpen != open) widget.c.toggleConsole();
      },
      children: [
        widget.checkPage,
        AndroidConsolePage(c: widget.c),
      ],
    );
  }
}

/// Full-screen read-only console for the phone. Own scroll controller and own
/// line colouring — no dependency on the desktop console widget.
class AndroidConsolePage extends StatefulWidget {
  const AndroidConsolePage({super.key, required this.c});

  final AppController c;

  @override
  State<AndroidConsolePage> createState() => _AndroidConsolePageState();
}

class _AndroidConsolePageState extends State<AndroidConsolePage> {
  final ScrollController _sc = ScrollController();

  @override
  void dispose() {
    _sc.dispose();
    super.dispose();
  }

  void _copy() {
    final c = widget.c;
    final body = c.console.join('\n');
    final text = body.isEmpty ? '' : '${c.contextHeader()}\n\n$body';
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
    final c = widget.c;
    final lines = c.console;
    // Keep pinned to the newest line.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_sc.hasClients) _sc.jumpTo(_sc.position.maxScrollExtent);
    });
    return ColoredBox(
      color: const Color(0xFF080B10),
      child: SafeArea(
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(4, 4, 12, 10),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: AppColors.line)),
              ),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Back',
                    icon: const Icon(
                      Icons.arrow_back_rounded,
                      color: AppColors.dim,
                      size: 22,
                    ),
                    onPressed: () {
                      if (c.consoleOpen) c.toggleConsole();
                    },
                  ),
                  Icon(
                    Icons.terminal_rounded,
                    size: 16,
                    color: AppColors.brand,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${c.backendName} console',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppColors.txt,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  _ConsoleAction(label: 'Copy', onTap: _copy),
                  const SizedBox(width: 16),
                  _ConsoleAction(label: 'Clear', onTap: c.clearConsole),
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
            // Browser only, on purpose. In the APK the top arrow and the swipe
            // are both reliable; in Chrome the swipe back starts at the left
            // edge, which is where Android's system back gesture and Chrome's
            // overscroll-to-history both live, so it is the one control that
            // can be taken away by the browser. This pill is the thumb-reachable
            // replacement. Un-gate it if it earns a place in the APK too.
            if (c.browserMode) _BackPill(c: c),
          ],
        ),
      ),
    );
  }

  // Private copy of the desktop console's colouring, intentionally duplicated
  // to keep the mobile console decoupled from _ConsolePanel (see file header).
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

/// Thumb-reachable "back to the app" control for the browser console.
///
/// Full-width target at the bottom of the screen, where the top-left arrow is
/// the hardest reach on a phone and the swipe is contested by the browser.
class _BackPill extends StatelessWidget {
  const _BackPill({required this.c});

  final AppController c;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
    child: SizedBox(
      width: double.infinity,
      height: 48,
      child: OutlinedButton.icon(
        onPressed: () {
          if (c.consoleOpen) c.toggleConsole();
        },
        icon: const Icon(Icons.arrow_back_rounded, size: 18),
        label: const Text('Back'),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.txt,
          side: const BorderSide(color: AppColors.line2),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
    ),
  );
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
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Text(
        label,
        style: TextStyle(
          color: AppColors.brand,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}
