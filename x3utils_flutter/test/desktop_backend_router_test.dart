import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:x3utils_flutter/app_controller.dart';
import 'package:x3utils_flutter/engine/desktop_backend_router.dart';
import 'package:x3utils_flutter/engine/hardware_backend.dart';
import 'package:x3utils_flutter/engine/swdart_backend.dart';
import 'package:x3utils_flutter/main.dart';
import 'package:x3utils_flutter/models.dart';

const _fullCapabilities = HardwareCapabilities(
  connectionModes: {
    ConnectionMode.defaultSwd,
    ConnectionMode.cloneC45,
    ConnectionMode.genuineC45,
    ConnectionMode.powerRace,
  },
  check: true,
  dump: true,
  flashFull: true,
  flashSlot0: true,
  protectionCheck: true,
  protectionRescue: true,
);

const _currentSwdartCapabilities = HardwareCapabilities(
  connectionModes: {
    ConnectionMode.defaultSwd,
    ConnectionMode.cloneC45,
    ConnectionMode.genuineC45,
  },
  check: true,
  dump: true,
  flashFull: true,
  flashSlot0: true,
  protectionCheck: true,
  protectionRescue: false,
);

class _RecordingBackend implements HardwareBackend {
  _RecordingBackend(this.name, this.capabilities);

  @override
  final String name;

  @override
  final HardwareCapabilities capabilities;

  final normalAttempts = <HardwareRequest>[];
  final protectionAttempts = <HardwareProtectionRequest>[];
  int cancellations = 0;
  int continues = 0;

  @override
  Future<HardwareResult> run(
    HardwareRequest request,
    HardwareCallbacks callbacks,
  ) async {
    normalAttempts.add(request);
    if (!capabilities.supports(request.operation, request.mode)) {
      throw UnsupportedError('$name does not implement this request');
    }
    final isFlash =
        request.operation == HardwareOperation.flashFull ||
        request.operation == HardwareOperation.flashSlot0;
    return HardwareResult(
      0,
      HardwareEvidence(
        caught: true,
        dumped: request.operation == HardwareOperation.dump,
        erased: isFlash,
        wrote: isFlash,
        verified: isFlash,
        resetRunning: isFlash,
      ),
      bytes: request.operation == HardwareOperation.dump
          ? Uint8List(131072)
          : null,
    );
  }

  @override
  Future<HardwareProtectionResult> runProtection(
    HardwareProtectionRequest request,
    HardwareProtectionCallbacks callbacks,
  ) async {
    protectionAttempts.add(request);
    if (!capabilities.supportsProtection(request.operation, request.mode)) {
      throw UnsupportedError('$name does not implement protection');
    }
    return const HardwareProtectionResult(
      0,
      HardwareProtectionVerdict.notProtected,
    );
  }

  @override
  bool sendContinue({required bool protection}) {
    continues++;
    return true;
  }

  @override
  void cancel() => cancellations++;
}

DesktopBackendRouter _router(
  _RecordingBackend openOcd,
  _RecordingBackend swdart,
) => DesktopBackendRouter(openOcd: openOcd, swdart: swdart);

HardwareCallbacks _callbacks(List<String> lines) => HardwareCallbacks(
  onLine: lines.add,
  onProgress: (_) {},
  onGuided: (_) {},
  onCaught: () {},
  onAttempt: (_, _) {},
);

void main() {
  test('global selection delegates normal work without fallback', () async {
    final openOcd = _RecordingBackend('OpenOCD', _fullCapabilities);
    final swdart = _RecordingBackend('swdart', _currentSwdartCapabilities);
    final router = _router(openOcd, swdart);
    final lines = <String>[];

    await router.run(
      const HardwareRequest(
        operation: HardwareOperation.flashSlot0,
        mode: ConnectionMode.cloneC45,
        countdown: 3,
      ),
      _callbacks(lines),
    );
    expect(openOcd.normalAttempts, hasLength(1));
    expect(swdart.normalAttempts, isEmpty);
    expect(lines.single, contains('backend route: OpenOCD'));

    router.select(DesktopBackendSelection.swdart);
    lines.clear();
    await router.run(
      const HardwareRequest(
        operation: HardwareOperation.check,
        mode: ConnectionMode.defaultSwd,
        countdown: 0,
      ),
      _callbacks(lines),
    );
    expect(openOcd.normalAttempts, hasLength(1));
    expect(swdart.normalAttempts, hasLength(1));
    expect(lines.single, contains('backend route: swdart'));

    lines.clear();
    await router.run(
      HardwareRequest(
        operation: HardwareOperation.flashSlot0,
        mode: ConnectionMode.defaultSwd,
        countdown: 0,
        bytes: Uint8List(0x1000),
      ),
      _callbacks(lines),
    );
    expect(swdart.normalAttempts, hasLength(2));
    expect(swdart.normalAttempts.last.operation, HardwareOperation.flashSlot0);
    expect(openOcd.normalAttempts, hasLength(1));
    expect(lines.single, contains('backend route: swdart'));

    lines.clear();
    await router.run(
      const HardwareRequest(
        operation: HardwareOperation.check,
        mode: ConnectionMode.genuineC45,
        countdown: 0,
      ),
      _callbacks(lines),
    );
    expect(swdart.normalAttempts, hasLength(3));
    expect(swdart.normalAttempts.last.mode, ConnectionMode.genuineC45);
    expect(openOcd.normalAttempts, hasLength(1));
    expect(lines.single, contains('backend route: swdart'));

    lines.clear();
    await router.run(
      const HardwareRequest(
        operation: HardwareOperation.check,
        mode: ConnectionMode.cloneC45,
        countdown: 3,
      ),
      _callbacks(lines),
    );
    expect(swdart.normalAttempts, hasLength(4));
    expect(swdart.normalAttempts.last.mode, ConnectionMode.cloneC45);
    expect(openOcd.normalAttempts, hasLength(1));
    expect(lines.single, contains('backend route: swdart'));
  });

  test('unsupported swdart work fails without trying OpenOCD', () async {
    final openOcd = _RecordingBackend('OpenOCD', _fullCapabilities);
    final swdart = _RecordingBackend('swdart', _currentSwdartCapabilities);
    final router = _router(openOcd, swdart)
      ..select(DesktopBackendSelection.swdart);

    await expectLater(
      router.run(
        const HardwareRequest(
          operation: HardwareOperation.check,
          mode: ConnectionMode.powerRace,
          countdown: 3,
        ),
        _callbacks(<String>[]),
      ),
      throwsA(isA<UnsupportedError>()),
    );

    expect(swdart.normalAttempts, hasLength(1));
    expect(openOcd.normalAttempts, isEmpty);
  });

  test('global selection also governs protection and control', () async {
    final openOcd = _RecordingBackend('OpenOCD', _fullCapabilities);
    final swdart = _RecordingBackend('swdart', _fullCapabilities);
    final router = _router(openOcd, swdart)
      ..select(DesktopBackendSelection.swdart);
    final lines = <String>[];

    await router.runProtection(
      const HardwareProtectionRequest(
        operation: HardwareProtectionOperation.check,
        mode: ConnectionMode.genuineC45,
        countdown: 3,
      ),
      HardwareProtectionCallbacks(
        onLine: lines.add,
        onChunk: (_) {},
        onGuided: (_) {},
      ),
    );
    expect(swdart.protectionAttempts, hasLength(1));
    expect(openOcd.protectionAttempts, isEmpty);
    expect(lines.single, contains('backend route: swdart'));

    expect(router.sendContinue(protection: true), isTrue);
    router.cancel();
    expect(swdart.continues, 1);
    expect(swdart.cancellations, 1);
    expect(openOcd.continues, 0);
    expect(openOcd.cancellations, 0);
  });

  test('controller restores swdart selection but keeps full surface', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'desktopHardwareBackend': DesktopBackendSelection.swdart.name,
      'defaultAutoRetry': 0,
    });
    final openOcd = _RecordingBackend('OpenOCD', _fullCapabilities);
    final swdart = _RecordingBackend('swdart', _currentSwdartCapabilities);
    final controller = AppController(backend: _router(openOcd, swdart));
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);

    expect(controller.desktopBackendSelectorAvailable, isTrue);
    expect(controller.useSwdartDesktop, isTrue);
    expect(controller.backendName, 'swdart');
    expect(controller.availableModes, ConnectionMode.values);
    expect(controller.isActionAvailable('rdp_check'), isTrue);
    expect(controller.isActionAvailable('flash_only'), isTrue);
    controller.selectAction('flash_backup');
    expect(controller.hasFlashScope, isTrue);

    controller.selectAction('check');
    controller.selectMode(ConnectionMode.cloneC45);
    await controller.start();
    expect(controller.stage, StageState.ok);
    expect(swdart.normalAttempts, hasLength(1));
    expect(swdart.normalAttempts.single.mode, ConnectionMode.cloneC45);
    expect(openOcd.normalAttempts, isEmpty);
  });

  testWidgets('Settings exposes and applies the global swdart switch', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 768);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final controller = AppController(
      backend: DesktopBackendRouter(
        openOcd: _RecordingBackend('OpenOCD', _fullCapabilities),
        swdart: SwdartBackend(),
      ),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(controller: controller)),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Settings'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);

    // The experimental switches live behind the collapsed Advanced caret at
    // the end of Settings, so the group must be opened before they exist.
    final backendSwitch = find.byKey(
      const ValueKey('desktop-swdart-backend-switch'),
    );
    final caret = find.byKey(const ValueKey('settings-advanced-caret'));
    expect(caret, findsOneWidget);
    expect(backendSwitch, findsNothing);
    await tester.ensureVisible(caret);
    await tester.tap(caret);
    await tester.pump(const Duration(milliseconds: 300));
    expect(backendSwitch, findsOneWidget);
    expect(
      find.textContaining('no automatic OpenOCD fallback'),
      findsOneWidget,
    );

    // Shipping default from 2.1.0: a fresh install is already on swdart, so
    // the switch starts ON and the first tap turns it OFF.
    expect(controller.useSwdartDesktop, isTrue);
    expect(controller.backendName, 'swdart');

    final prefs = await SharedPreferences.getInstance();
    await tester.ensureVisible(backendSwitch);
    await tester.tap(backendSwitch);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(controller.useSwdartDesktop, isFalse);
    expect(controller.backendName, 'OpenOCD');
    expect(
      prefs.getString('desktopHardwareBackend'),
      DesktopBackendSelection.openOcd.name,
    );

    await tester.ensureVisible(backendSwitch);
    await tester.tap(backendSwitch);
    await tester.pump();
    expect(controller.useSwdartDesktop, isTrue);
    expect(
      prefs.getString('desktopHardwareBackend'),
      DesktopBackendSelection.swdart.name,
    );

    final loaderSwitch = find.byKey(
      const ValueKey('desktop-swdart-loader-switch'),
    );
    expect(loaderSwitch, findsOneWidget);
    expect(controller.useSwdartLoaderDesktop, isTrue);
    await tester.ensureVisible(loaderSwitch);
    await tester.tap(loaderSwitch);
    await tester.pump();
    expect(controller.useSwdartLoaderDesktop, isFalse);
    expect(prefs.getBool('desktopSwdartLoader'), isFalse);
    expect(controller.engineDescription, contains('direct word writes'));
  });

  test('saved desktop direct-write preference is applied at startup', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'desktopHardwareBackend': DesktopBackendSelection.swdart.name,
      'desktopSwdartLoader': false,
    });
    final swdart = SwdartBackend();
    final controller = AppController(
      backend: DesktopBackendRouter(
        openOcd: _RecordingBackend('OpenOCD', _fullCapabilities),
        swdart: swdart,
      ),
    );
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);

    expect(controller.desktopSwdartLoaderSelectorAvailable, isTrue);
    expect(controller.useSwdartLoaderDesktop, isFalse);
    expect(swdart.useAt32Loader, isFalse);
    expect(controller.engineDescription, contains('direct word writes'));
  });

  test(
    'Advanced logging toggle persists and reaches the swdart backend',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final swdart = SwdartBackend();
      final controller = AppController(
        backend: DesktopBackendRouter(
          openOcd: _RecordingBackend('OpenOCD', _fullCapabilities),
          swdart: swdart,
        ),
      );
      addTearDown(controller.dispose);
      await Future<void>.delayed(Duration.zero);

      expect(controller.loaderDiagnosticsAvailable, isTrue);
      // ON by default from 2.1.0: an intermittent field failure must arrive
      // with its register baseline and per-chunk log already recorded.
      expect(controller.loaderDiagnostics, isTrue);
      expect(swdart.loaderDiagnostics, isTrue);

      controller.setLoaderDiagnostics(false);
      expect(swdart.loaderDiagnostics, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('loaderDiagnostics'), isFalse);

      controller.setLoaderDiagnostics(true);
      expect(swdart.loaderDiagnostics, isTrue);
      expect(prefs.getBool('loaderDiagnostics'), isTrue);
    },
  );

  test(
    'Advanced logging hides with the SRAM loader when swdart is off, '
    'and keeps its stored value',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final swdart = SwdartBackend();
      final controller = AppController(
        backend: DesktopBackendRouter(
          openOcd: _RecordingBackend('OpenOCD', _fullCapabilities),
          swdart: swdart,
        ),
      );
      addTearDown(controller.dispose);
      await Future<void>.delayed(Duration.zero);

      expect(controller.loaderDiagnosticsAvailable, isTrue);
      expect(controller.desktopSwdartLoaderSelectorAvailable, isTrue);
      expect(controller.loaderDiagnostics, isTrue);

      // Both rows are swdart-only and must disappear together: the
      // diagnostics describe the SRAM loader, which does not exist here.
      controller.setUseSwdartDesktop(false);
      expect(controller.loaderDiagnosticsAvailable, isFalse);
      expect(controller.desktopSwdartLoaderSelectorAvailable, isFalse);

      // Hidden, NOT cleared. Nothing was written to the key, so the operator's
      // choice survives the round trip.
      expect(controller.loaderDiagnostics, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('loaderDiagnostics'), isNull);

      controller.setUseSwdartDesktop(true);
      expect(controller.loaderDiagnosticsAvailable, isTrue);
      expect(controller.loaderDiagnostics, isTrue);
      expect(swdart.loaderDiagnostics, isTrue);
    },
  );

  test('an OpenOCD run never raises the untested-package warning', () async {
    // OpenOCD reports no part-level identity, so its evidence leaves
    // targetTested null. Null must stay silent: reading it as "untested" would
    // warn on every OpenOCD run about a chip nothing was measured on.
    SharedPreferences.setMockInitialValues(<String, Object>{
      'desktopHardwareBackend': DesktopBackendSelection.openOcd.name,
    });
    final controller = AppController(
      backend: DesktopBackendRouter(
        openOcd: _RecordingBackend('OpenOCD', _fullCapabilities),
        swdart: SwdartBackend(),
      ),
    );
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);

    expect(controller.useSwdartDesktop, isFalse);
    expect(controller.untestedTargetWarning, isNull);
  });

  test('saved Advanced logging preference is applied at startup', () async {
    // false, not true: true is now the default, so only a saved false proves
    // that the stored preference beats the default.
    SharedPreferences.setMockInitialValues(<String, Object>{
      'loaderDiagnostics': false,
    });
    final swdart = SwdartBackend();
    final controller = AppController(
      backend: DesktopBackendRouter(
        openOcd: _RecordingBackend('OpenOCD', _fullCapabilities),
        swdart: swdart,
      ),
    );
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);

    expect(controller.loaderDiagnostics, isFalse);
    expect(swdart.loaderDiagnostics, isFalse);
  });

  test('fresh desktop install ships on swdart', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final controller = AppController(
      backend: DesktopBackendRouter(
        openOcd: _RecordingBackend('OpenOCD', _fullCapabilities),
        swdart: SwdartBackend(),
      ),
    );
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);

    expect(controller.useSwdartDesktop, isTrue);
    expect(controller.useSwdartLoaderDesktop, isTrue);
    expect(controller.loaderDiagnostics, isTrue);
  });

  test('an explicit OpenOCD choice survives the new default', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'desktopHardwareBackend': DesktopBackendSelection.openOcd.name,
    });
    final controller = AppController(
      backend: DesktopBackendRouter(
        openOcd: _RecordingBackend('OpenOCD', _fullCapabilities),
        swdart: SwdartBackend(),
      ),
    );
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);

    expect(controller.useSwdartDesktop, isFalse);
    expect(controller.backendName, 'OpenOCD');
  });
}
