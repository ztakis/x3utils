import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:flutter/material.dart'
    show
        CheckedPopupMenuItem,
        Icon,
        Icons,
        InkWell,
        MaterialApp,
        SelectableText;
import 'package:flutter/services.dart' show SystemChannels;
import 'package:flutter/widgets.dart'
    show Axis, NeverScrollableScrollPhysics, PageView, ValueKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:x3utils_flutter/app_controller.dart';
import 'package:x3utils_flutter/engine/dump_metadata.dart';
import 'package:x3utils_flutter/engine/firmware.dart';
import 'package:x3utils_flutter/engine/hardware_backend.dart';
import 'package:x3utils_flutter/engine/pack_zip3.dart';
import 'package:x3utils_flutter/engine/swdart_backend.dart';
import 'package:x3utils_flutter/main.dart';
import 'package:x3utils_flutter/models.dart';

class _UsbProbeBackend implements HardwareBackend, HardwareDeviceBackend {
  _UsbProbeBackend([
    this._status = const HardwareDeviceStatus(
      HardwareDeviceState.selectionRequired,
    ),
    this.failure,
  ]);

  HardwareDeviceStatus _status;
  final HardwareException? failure;
  HardwareDeviceStatusListener? _listener;
  bool cancelSelection = true;
  int selectionCalls = 0;

  @override
  String get name => 'fake WebUSB';

  @override
  HardwareCapabilities get capabilities => const HardwareCapabilities(
    connectionModes: {ConnectionMode.defaultSwd},
    check: true,
    dump: true,
    flashFull: true,
    flashSlot0: true,
    protectionCheck: true,
    protectionRescue: false,
  );

  @override
  HardwareDeviceStatus get deviceStatus => _status;

  @override
  Future<HardwareDeviceStatus> refreshDevice() async => _status;

  @override
  Future<HardwareDeviceStatus> selectDevice() async {
    selectionCalls++;
    if (cancelSelection) {
      throw const HardwareException(
        HardwareFailureKind.userCancelled,
        'No device selected.',
      );
    }
    _status = const HardwareDeviceStatus(
      HardwareDeviceState.ready,
      productName: 'Fake ST-Link',
    );
    _listener?.call(_status);
    return _status;
  }

  @override
  void watchDevice(HardwareDeviceStatusListener listener) {
    _listener = listener;
  }

  @override
  Future<HardwareResult> run(
    HardwareRequest request,
    HardwareCallbacks callbacks,
  ) async {
    final error = failure;
    if (error != null) throw error;
    return const HardwareResult(0, HardwareEvidence(caught: true));
  }

  @override
  Future<HardwareProtectionResult> runProtection(
    HardwareProtectionRequest request,
    HardwareProtectionCallbacks callbacks,
  ) => throw UnsupportedError('not used');

  @override
  bool sendContinue({required bool protection}) => false;

  @override
  void cancel() {}
}

class _GuidedBackend implements HardwareBackend {
  final started = Completer<void>();
  final result = Completer<HardwareResult>();
  HardwareCallbacks? callbacks;
  HardwareRequest? request;
  int continues = 0;

  @override
  String get name => 'fake guided backend';

  @override
  HardwareCapabilities get capabilities => const HardwareCapabilities(
    connectionModes: {ConnectionMode.defaultSwd, ConnectionMode.cloneC45},
    check: true,
    dump: true,
    flashFull: true,
    flashSlot0: true,
    protectionCheck: true,
    protectionRescue: false,
  );

  @override
  Future<HardwareResult> run(
    HardwareRequest request,
    HardwareCallbacks callbacks,
  ) {
    this.request = request;
    this.callbacks = callbacks;
    if (!started.isCompleted) started.complete();
    return result.future;
  }

  void emit(HardwareGuidedStage stage) {
    callbacks?.onGuided(HardwareGuidedEvent(stage));
  }

  void complete() {
    if (!result.isCompleted) {
      result.complete(const HardwareResult(0, HardwareEvidence(caught: true)));
    }
  }

  @override
  Future<HardwareProtectionResult> runProtection(
    HardwareProtectionRequest request,
    HardwareProtectionCallbacks callbacks,
  ) => throw UnsupportedError('not used');

  @override
  bool sendContinue({required bool protection}) {
    continues++;
    return true;
  }

  @override
  void cancel() => complete();
}

void main() {
  testWidgets('App boots and shows the default action', (
    WidgetTester tester,
  ) async {
    // Keep coverage at the compact 1024x768 responsive viewport.
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 768);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(const X3UtilsApp());
    // Title bar brand + the default "Check connection" action are present.
    expect(find.text('x3utils'), findsOneWidget);
    expect(find.text('Check connection'), findsWidgets);
    expect(find.text('Ready to start'), findsOneWidget);
  });

  testWidgets(
    'Android pins connection above and action below the check surface',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'defaultConnMode': ConnectionMode.genuineC45.index,
      });
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final controller = AppController(androidMode: true);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(home: HomeScreen(controller: controller)),
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('android-check-page')), findsOneWidget);
      expect(find.byKey(const ValueKey('android-default-swd')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('android-check-action')),
        findsOneWidget,
      );
      expect(find.text('Default SWD'), findsOneWidget);
      expect(find.text('Check connection'), findsNWidgets(3));
      expect(find.text('Power-race'), findsNothing);
      expect(find.text('ACTIONS'), findsOneWidget);
      expect(find.text('Backup'), findsNothing);
      expect(find.text('Console'), findsNothing);
      expect(controller.availableModes, const [
        ConnectionMode.defaultSwd,
        ConnectionMode.powerRace,
        ConnectionMode.cloneC45,
      ]);
      expect(controller.mode, ConnectionMode.defaultSwd);
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('android-check-action')))
            .dy,
        greaterThan(
          tester
              .getBottomLeft(find.byKey(const ValueKey('android-default-swd')))
              .dy,
        ),
      );
      // 830, not the old 824: the outer bottom padding went 20 -> 14 when the
      // phone header was tightened to give the hero card its space back.
      expect(
        tester
            .getBottomLeft(find.byKey(const ValueKey('android-check-action')))
            .dy,
        closeTo(830, 1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Android enables Power-race and Clone C45 but hides Genuine C45',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final controller = AppController(androidMode: true);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(home: HomeScreen(controller: controller)),
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('android-default-swd')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(
        find.byKey(const ValueKey('android-connection-menu')),
        findsOneWidget,
      );
      expect(find.text('Power-race'), findsOneWidget);
      expect(find.text('C45 · Clone'), findsOneWidget);
      expect(find.text('Respawn connect'), findsOneWidget);
      expect(find.text('Guided hold / release'), findsOneWidget);
      expect(find.text('C45 · Genuine'), findsNothing);
      expect(find.text('Testing · nRST'), findsNothing);
      expect(find.text('Coming later'), findsNothing);
      expect(
        find.byKey(const ValueKey('android-hold-countdown')),
        findsOneWidget,
      );

      final powerRaceInk = tester.widget<InkWell>(
        find.descendant(
          of: find.byKey(const ValueKey('android-mode-power-race')),
          matching: find.byType(InkWell),
        ),
      );
      final cloneC45Ink = tester.widget<InkWell>(
        find.descendant(
          of: find.byKey(const ValueKey('android-mode-clone-c45')),
          matching: find.byType(InkWell),
        ),
      );
      expect(powerRaceInk.onTap, isNotNull);
      expect(cloneC45Ink.onTap, isNotNull);

      final before = controller.countdownSeconds;
      final countdownAdd = find.descendant(
        of: find.byKey(const ValueKey('android-hold-countdown')),
        matching: find.byIcon(Icons.add),
      );
      await tester.ensureVisible(countdownAdd);
      await tester.pump();
      await tester.tap(countdownAdd);
      await tester.pump();
      expect(controller.countdownSeconds, before + 1);
      await tester.tap(find.byKey(const ValueKey('android-mode-power-race')));
      await tester.pump();
      expect(controller.mode, ConnectionMode.powerRace);

      await tester.tap(find.byKey(const ValueKey('android-default-swd')));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(const ValueKey('android-mode-clone-c45')));
      await tester.pump();
      expect(controller.mode, ConnectionMode.cloneC45);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Android action dropup exposes only selected actions', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final controller = AppController(androidMode: true);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(controller: controller)),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('android-check-action')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byKey(const ValueKey('android-actions-menu')), findsOneWidget);
    expect(find.text('Backup'), findsOneWidget);
    expect(find.text('Backup + Flash'), findsOneWidget);
    expect(find.text('SHU compatible'), findsOneWidget);
    expect(find.text('Advanced'), findsOneWidget);

    final backupInk = tester.widget<InkWell>(
      find.descendant(
        of: find.byKey(const ValueKey('android-action-dump')),
        matching: find.byType(InkWell),
      ),
    );
    final flashInk = tester.widget<InkWell>(
      find.descendant(
        of: find.byKey(const ValueKey('android-action-flash_backup')),
        matching: find.byType(InkWell),
      ),
    );
    final shuInk = tester.widget<InkWell>(
      find.descendant(
        of: find.byKey(const ValueKey('android-action-flash_compat')),
        matching: find.byType(InkWell),
      ),
    );
    expect(backupInk.onTap, isNotNull);
    expect(flashInk.onTap, isNotNull);
    expect(shuInk.onTap, isNotNull);

    final backup = find.byKey(const ValueKey('android-action-dump'));
    await tester.ensureVisible(backup);
    await tester.pump();
    await tester.tap(backup);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(controller.actionId, 'dump');
    expect(controller.canStart, isTrue);
    expect(find.text('Start backup'), findsOneWidget);
    expect(find.text('Downloads/x3utils/backup'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('android-check-action')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    final advanced = find.byKey(const ValueKey('android-actions-advanced'));
    await tester.ensureVisible(advanced);
    await tester.pump();
    await tester.tap(advanced);
    await tester.pump(const Duration(milliseconds: 250));

    await tester.ensureVisible(
      find.byKey(const ValueKey('android-action-rdp_check')),
    );
    await tester.pump();

    expect(find.text('Flash Only'), findsOneWidget);
    expect(find.text('ZIP3 tools'), findsNothing);
    expect(find.text('Get file info'), findsNothing);
    expect(find.text('Check protection'), findsOneWidget);
    expect(find.text('Unlock / rescue'), findsNothing);
    final flashOnlyInk = tester.widget<InkWell>(
      find.descendant(
        of: find.byKey(const ValueKey('android-action-flash_only')),
        matching: find.byType(InkWell),
      ),
    );
    final protectionInk = tester.widget<InkWell>(
      find.descendant(
        of: find.byKey(const ValueKey('android-action-rdp_check')),
        matching: find.byType(InkWell),
      ),
    );
    expect(flashOnlyInk.onTap, isNotNull);
    expect(protectionInk.onTap, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android burger exposes phone-safe Settings and About', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{'accent': 6});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final controller = AppController(androidMode: true);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(controller: controller)),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Menu'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Settings…'), findsOneWidget);
    expect(find.text('About'), findsOneWidget);
    expect(find.textContaining('console', findRichText: true), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('title-menu-settings')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Hold countdown'), findsOneWidget);
    expect(find.text('Auto-retry'), findsOneWidget);
    expect(find.text('Theme accent'), findsOneWidget);
    expect(find.textContaining('Downloads/x3utils/backup'), findsOneWidget);
    expect(find.text('x3utils folder'), findsNothing);
    expect(controller.accentIndex, 1);
    for (var i = 0; i < 4; i++) {
      expect(find.byKey(ValueKey('accent-choice-$i')), findsOneWidget);
      expect(
        tester.getSize(find.byKey(ValueKey('accent-choice-$i'))),
        const Size(40, 40),
      );
    }
    expect(find.byKey(const ValueKey('accent-choice-4')), findsNothing);
    final settingsAdd = find.byIcon(Icons.add).first;
    final settingsAddButton = find
        .ancestor(of: settingsAdd, matching: find.byType(InkWell))
        .first;
    expect(tester.getSize(settingsAddButton), const Size(36, 36));
    final done = find.text('Done');
    final doneButton = find
        .ancestor(of: done, matching: find.byType(InkWell))
        .first;
    expect(done, findsOneWidget);
    expect(
      tester.getCenter(done).dy,
      closeTo(tester.getCenter(doneButton).dy, 1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android uses larger menu and semantic mode and action colors', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final controller = AppController(androidMode: true);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(controller: controller)),
    );
    await tester.pump();

    expect(
      tester.getSize(find.byKey(const ValueKey('android-title-menu'))),
      const Size(48, 48),
    );
    final menuIcon = tester.widget<Icon>(
      find.descendant(
        of: find.byKey(const ValueKey('android-title-menu')),
        matching: find.byIcon(Icons.menu_rounded),
      ),
    );
    expect(menuIcon.size, 28);

    await tester.tap(find.byKey(const ValueKey('android-default-swd')));
    await tester.pump();
    final raceIcon = tester.widget<Icon>(
      find.descendant(
        of: find.byKey(const ValueKey('android-mode-power-race')),
        matching: find.byIcon(ConnectionMode.powerRace.icon),
      ),
    );
    expect(raceIcon.color, ConnectionMode.powerRace.color);

    await tester.tap(find.byKey(const ValueKey('android-check-action')));
    await tester.pump();
    final checkAction = kActions.firstWhere((action) => action.id == 'check');
    final checkDot = tester.widget<Icon>(
      find.descendant(
        of: find.byKey(const ValueKey('android-action-check')),
        matching: find.byIcon(Icons.circle),
      ),
    );
    expect(checkDot.color, checkAction.danger.dot);
    expect(tester.takeException(), isNull);
  });

  test(
    'Android default backend advertises Clone and Race but not Genuine',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final controller = AppController(androidMode: true);
      addTearDown(controller.dispose);
      await Future<void>.delayed(Duration.zero);

      expect(controller.availableModes, const [
        ConnectionMode.defaultSwd,
        ConnectionMode.powerRace,
        ConnectionMode.cloneC45,
      ]);
      expect(controller.isActionAvailable('check'), isTrue);
      expect(controller.isActionAvailable('dump'), isTrue);
      expect(controller.isActionAvailable('flash_only'), isTrue);
      expect(controller.isActionAvailable('flash_backup'), isTrue);
      expect(controller.isActionAvailable('flash_compat'), isTrue);
      expect(controller.isActionAvailable('rdp_check'), isTrue);
      expect(controller.isActionAvailable('rdp_rescue'), isFalse);
    },
  );

  testWidgets(
    'Android Clone C45 stacks Hold and Release controls in the phone hero',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'defaultAutoRetry': 0,
      });
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final backend = _GuidedBackend();
      final controller = AppController(backend: backend, androidMode: true);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(home: HomeScreen(controller: controller)),
      );
      await tester.pump();
      controller.selectMode(ConnectionMode.cloneC45);
      controller.selectAction('check');
      await tester.pump();

      unawaited(controller.start());
      await tester.pump();

      expect(backend.started.isCompleted, isTrue);
      expect(backend.request?.mode, ConnectionMode.cloneC45);
      expect(find.text('Hold C45 → GND'), findsOneWidget);
      expect(find.text("I'm holding — continue"), findsOneWidget);
      var stack = find.byKey(const ValueKey('android-guided-stage-buttons'));
      expect(stack, findsOneWidget);
      expect(tester.getSize(stack).width, lessThanOrEqualTo(280));
      expect(
        tester.getTopLeft(find.text("I'm holding — continue")).dy,
        lessThan(tester.getTopLeft(find.text('Cancel')).dy),
      );
      final continueButton = find
          .ancestor(
            of: find.text("I'm holding — continue"),
            matching: find.byType(InkWell),
          )
          .first;
      final cancelButton = find
          .ancestor(of: find.text('Cancel'), matching: find.byType(InkWell))
          .first;
      expect(tester.getSize(continueButton).height, 52);
      expect(tester.getSize(cancelButton).height, 52);
      expect(
        tester.getCenter(find.text("I'm holding — continue")).dx,
        closeTo(tester.getCenter(continueButton).dx, 1),
      );
      expect(
        tester.getCenter(find.text('Cancel')).dx,
        closeTo(tester.getCenter(cancelButton).dx, 1),
      );

      backend.emit(HardwareGuidedStage.release);
      await tester.pump();

      expect(find.text('Release now'), findsOneWidget);
      expect(find.text('Released — continue'), findsOneWidget);
      stack = find.byKey(const ValueKey('android-guided-stage-buttons'));
      expect(stack, findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Released — continue')).dy,
        lessThan(tester.getTopLeft(find.text('Cancel')).dy),
      );
      expect(tester.takeException(), isNull);

      controller.cancel();
      await tester.pump();
      expect(controller.running, isFalse);
    },
  );

  testWidgets('Android failure CTAs stack and center in the phone hero', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final backend = _UsbProbeBackend(
      const HardwareDeviceStatus(
        HardwareDeviceState.ready,
        productName: 'Fake ST-Link',
      ),
      const HardwareException(
        HardwareFailureKind.targetContact,
        'target did not answer',
      ),
    );
    final controller = AppController(backend: backend, androidMode: true);
    addTearDown(controller.dispose);
    controller.setDefaultAutoRetry(0);

    await controller.start();
    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(controller: controller)),
    );
    await tester.pump();

    expect(controller.stage, StageState.fail);
    final primary = find.text('Retry');
    final dismiss = find.text('Dismiss');
    final stack = find.byKey(const ValueKey('android-guided-stage-buttons'));
    expect(stack, findsOneWidget);
    expect(primary, findsOneWidget);
    expect(dismiss, findsOneWidget);
    expect(
      tester.getTopLeft(primary).dy,
      lessThan(tester.getTopLeft(dismiss).dy),
    );
    expect(tester.getSize(stack).width, lessThanOrEqualTo(280));
    expect(
      tester.getCenter(primary).dx,
      closeTo(
        tester
            .getCenter(
              find.ancestor(of: primary, matching: find.byType(InkWell)).first,
            )
            .dx,
        1,
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Android Flash Only selection uses the timed vertical phone warning',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final controller = AppController(androidMode: true);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(home: HomeScreen(controller: controller)),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('android-check-action')));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(const ValueKey('android-actions-advanced')));
      await tester.pump(const Duration(milliseconds: 250));
      final flashOnly = find.byKey(const ValueKey('android-action-flash_only'));
      await tester.ensureVisible(flashOnly);
      await tester.tap(flashOnly);
      await tester.pump();

      expect(find.text('Flash Only — no safety nets'), findsOneWidget);
      expect(find.text('I understand — continue (5s)'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('phone-timed-warning-actions')),
        findsOneWidget,
      );
      expect(controller.actionId, 'check');
      expect(
        tester.getTopLeft(find.text('Cancel')).dy,
        lessThan(
          tester.getTopLeft(find.text('I understand — continue (5s)')).dy,
        ),
      );

      await tester.tap(find.text('Cancel'));
      await tester.pump(const Duration(milliseconds: 250));
      expect(controller.actionId, 'check');

      await tester.ensureVisible(flashOnly);
      await tester.tap(flashOnly);
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      await tester.tap(find.text('I understand — continue'));
      await tester.pump(const Duration(milliseconds: 250));

      expect(controller.actionId, 'flash_only');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Android SHU selection uses the timed vertical phone warning', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final controller = AppController(androidMode: true);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(controller: controller)),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('android-check-action')));
    await tester.pump(const Duration(milliseconds: 250));
    final shu = find.byKey(const ValueKey('android-action-flash_compat'));
    await tester.ensureVisible(shu);
    await tester.tap(shu);
    await tester.pump();

    expect(find.text('ATTENTION'), findsOneWidget);
    expect(find.text('I understand — continue (5s)'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('phone-timed-warning-actions')),
      findsOneWidget,
    );
    expect(controller.actionId, 'check');
    expect(
      tester.getTopLeft(find.text('Cancel')).dy,
      lessThan(tester.getTopLeft(find.text('I understand — continue (5s)')).dy),
    );

    await tester.pump(const Duration(seconds: 5));
    await tester.tap(find.text('I understand — continue'));
    await tester.pump(const Duration(milliseconds: 250));

    expect(controller.actionId, 'flash_compat');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android Flash Only keeps the hard warning before writing', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final controller = AppController(
      backend: _UsbProbeBackend(
        const HardwareDeviceStatus(
          HardwareDeviceState.ready,
          productName: 'Fake ST-Link',
        ),
      ),
      androidMode: true,
    );
    addTearDown(controller.dispose);
    controller.selectAction('flash_only');
    final firmware = Uint8List.fromList(
      List<int>.generate(Firmware.expectedSize, (index) => index % 251),
    );
    const banner = 'SCOOTER_VCU_xxG3';
    firmware.setRange(0x1400, 0x1400 + banner.length, banner.codeUnits);
    expect(controller.selectFirmwareBytes('incoming.bin', firmware).ok, isTrue);

    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(controller: controller)),
    );
    await tester.pump();
    final start = find.text('Flash without backup');
    await tester.ensureVisible(start);
    await tester.tap(start);
    await tester.pump();

    expect(find.text('Compatibility warning'), findsOneWidget);
    expect(find.text('Flash anyway'), findsOneWidget);
    final confirmFlash = find
        .ancestor(of: find.text('Flash anyway'), matching: find.byType(InkWell))
        .first;
    expect(tester.getSize(confirmFlash).height, 48);
    expect(
      tester.getCenter(find.text('Flash anyway')).dx,
      closeTo(tester.getCenter(confirmFlash).dx, 1),
    );
    expect(controller.stage, StageState.idle);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(controller.stage, StageState.idle);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Android Backup + Flash stacks scope above equal firmware pickers',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final controller = AppController(androidMode: true);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(home: HomeScreen(controller: controller)),
      );
      await tester.pump();
      controller.selectAction('flash_backup');
      await tester.pump();

      final scope = find.text('Full image');
      final slotScope = find.text('Slot 0 only');
      final chooseBin = find.text('Choose .bin');
      final chooseZip = find.text('Choose .zip');
      await tester.ensureVisible(chooseZip);
      await tester.pump();

      expect(controller.actionId, 'flash_backup');
      expect(scope, findsOneWidget);
      expect(slotScope, findsOneWidget);
      expect(chooseBin, findsOneWidget);
      expect(chooseZip, findsOneWidget);
      expect(
        tester.getBottomLeft(slotScope).dy,
        lessThan(tester.getTopLeft(chooseBin).dy),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('firmware-pick-bin'))).width,
        closeTo(
          tester.getSize(find.byKey(const ValueKey('firmware-pick-zip'))).width,
          1,
        ),
      );

      InkWell zipButton() => tester.widget<InkWell>(
        find.ancestor(of: chooseZip, matching: find.byType(InkWell)).first,
      );
      expect(zipButton().onTap, isNull);
      await tester.tap(slotScope);
      await tester.pump();
      expect(controller.flashScope, FlashScope.slot0);
      expect(zipButton().onTap, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Android compact Backup + Flash keeps its CTA above Actions', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(370, 798);
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 48);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetPadding);
    final controller = AppController(androidMode: true);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(controller: controller)),
    );
    await tester.pump();
    controller.selectAction('flash_backup');
    await tester.pump();

    // Both lines were deliberately removed from the phone hero to give the CTA
    // its space back: the idle sub-line on every firmware screen, and the ZIP3
    // hint inside the firmware bar. Desktop keeps its own longer wording.
    expect(
      find.text('Back up, write and verify the selected scope.'),
      findsNothing,
    );
    expect(find.text('ZIP3/ZIP3.2: select Slot 0.'), findsNothing);
    final start = find.text('Start flash');
    final startButton = find
        .ancestor(of: start, matching: find.byType(InkWell))
        .first;
    expect(tester.getSize(startButton).height, greaterThanOrEqualTo(52));
    expect(tester.getSize(startButton).width, lessThan(240));
    expect(
      tester.getSize(find.byKey(const ValueKey('firmware-scope'))).height,
      48,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('android-idle-visual'))),
      const Size(84, 84),
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('android-firmware-bar'))).dy -
          tester
              .getBottomLeft(find.byKey(const ValueKey('android-idle-visual')))
              .dy,
      greaterThanOrEqualTo(6),
    );
    expect(
      tester.getTopLeft(startButton).dy -
          tester
              .getBottomLeft(find.byKey(const ValueKey('android-firmware-bar')))
              .dy,
      greaterThanOrEqualTo(5),
    );
    expect(
      tester.getBottomLeft(startButton).dy,
      lessThan(tester.getTopLeft(find.text('ACTIONS')).dy),
      reason: 'The complete CTA must stay above the pinned Actions label.',
    );
    expect(
      tester.getCenter(start).dx,
      closeTo(tester.getCenter(startButton).dx, 1),
    );
    expect(
      tester.getCenter(start).dy,
      closeTo(tester.getCenter(startButton).dy, 1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Desktop centers firmware picker labels', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 768);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final controller = AppController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(controller: controller)),
    );
    await tester.pump();
    controller.selectAction('flash_backup');
    await tester.pump();

    final chooseBin = find.text('Choose .bin');
    final chooseZip = find.text('Choose .zip');
    expect(chooseBin, findsOneWidget);
    expect(chooseZip, findsOneWidget);
    expect(
      tester.getCenter(chooseBin).dx,
      closeTo(
        tester.getCenter(find.byKey(const ValueKey('firmware-pick-bin'))).dx,
        1,
      ),
    );
    expect(
      tester.getCenter(chooseZip).dx,
      closeTo(
        tester.getCenter(find.byKey(const ValueKey('firmware-pick-zip'))).dx,
        1,
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Browser centers firmware picker labels', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 768);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final controller = AppController(
      browserMode: true,
      backupDownloader: (_, _) async {},
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(controller: controller)),
    );
    await tester.pump();
    controller.selectAction('flash_backup');
    await tester.pump();

    final chooseBin = find.text('Choose .bin');
    final chooseZip = find.text('Choose .zip');
    expect(chooseBin, findsOneWidget);
    expect(chooseZip, findsOneWidget);
    expect(
      tester.getCenter(chooseBin).dx,
      closeTo(
        tester.getCenter(find.byKey(const ValueKey('firmware-pick-bin'))).dx,
        1,
      ),
    );
    expect(
      tester.getCenter(chooseZip).dx,
      closeTo(
        tester.getCenter(find.byKey(const ValueKey('firmware-pick-zip'))).dx,
        1,
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android SafeArea follows gesture and button navigation insets', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 48);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetPadding);
    final controller = AppController(androidMode: true);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(controller: controller)),
    );
    await tester.pump();
    final selector = find.byKey(const ValueKey('android-check-action'));
    final buttonNavigationBottom = tester.getBottomLeft(selector).dy;
    expect(buttonNavigationBottom, lessThanOrEqualTo(844 - 48));

    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    await tester.pump();
    final gestureNavigationBottom = tester.getBottomLeft(selector).dy;
    expect(gestureNavigationBottom - buttonNavigationBottom, closeTo(24, 1));
    expect(gestureNavigationBottom, lessThanOrEqualTo(844 - 24));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android keeps USB permission on the main connection pill', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final controller = AppController(
      backend: _UsbProbeBackend(),
      androidMode: true,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(controller: controller)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.widgetWithText(InkWell, 'Connect ST-Link'), findsOneWidget);
    expect(find.text('Grant USB access'), findsNothing);
    expect(find.text('Not now'), findsNothing);
    expect(find.textContaining('OpenOCD'), findsNothing);
    expect(controller.canStart, isFalse);
  });

  testWidgets('Android connection pill performs one USB permission request', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final backend = _UsbProbeBackend()..cancelSelection = false;
    final controller = AppController(backend: backend, androidMode: true);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(controller: controller)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Grant USB access'), findsNothing);
    await tester.tap(find.widgetWithText(InkWell, 'Connect ST-Link'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(backend.selectionCalls, 1);
    expect(find.text('Not now'), findsNothing);
    expect(controller.deviceProbeReady, isTrue);
    expect(controller.canStart, isTrue);
  });

  testWidgets('browser UI exposes all swdart connection modes', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 768);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final controller = AppController(
      browserMode: true,
      backupDownloader: (_, _) async {},
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(controller: controller)),
    );
    await tester.pump();

    expect(find.text('Default SWD'), findsWidgets);
    expect(find.text('Check connection'), findsWidgets);
    expect(find.text('Backup'), findsOneWidget);
    expect(find.text('AT32F415 · WebUSB'), findsOneWidget);
    expect(find.textContaining('swdart'), findsWidgets);
    expect(find.text('Backup + Flash'), findsOneWidget);
    expect(find.text('SHU compatible'), findsOneWidget);
    expect(find.text('C45 · Clone'), findsOneWidget);
    expect(find.text('Power-race'), findsOneWidget);
    expect(find.text('ADVANCED'), findsOneWidget);

    // Genuine nRST starts in Advanced, like the desktop surface.
    expect(find.text('C45 · Genuine'), findsNothing);
    await tester.tap(find.text('ADVANCED'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('C45 · Genuine'), findsOneWidget);
    expect(find.text('Flash Only'), findsOneWidget);
  });

  testWidgets(
    'WebUSB uses only the Connect ST-Link pill for device selection',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1024, 768);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final backend = _UsbProbeBackend();
      final controller = AppController(
        backend: backend,
        browserMode: true,
        backupDownloader: (_, _) async {},
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(home: HomeScreen(controller: controller)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.widgetWithText(InkWell, 'Connect ST-Link'), findsOneWidget);
      expect(find.text('Not now'), findsNothing);

      await tester.tap(find.widgetWithText(InkWell, 'Connect ST-Link'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(backend.selectionCalls, 1);
      expect(find.widgetWithText(InkWell, 'Connect ST-Link'), findsOneWidget);
      expect(find.text('Not now'), findsNothing);
      expect(controller.canStart, isFalse);

      backend.cancelSelection = false;
      await tester.tap(find.widgetWithText(InkWell, 'Connect ST-Link'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(backend.selectionCalls, 2);
      expect(find.text('Connect ST-Link'), findsNothing);
      expect(controller.deviceProbeReady, isTrue);
      expect(controller.backendStatusLabel, 'Fake ST-Link');
    },
  );

  testWidgets('authorized WebUSB probe restores without onboarding', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 768);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final backend = _UsbProbeBackend(
      const HardwareDeviceStatus(
        HardwareDeviceState.ready,
        productName: 'Remembered ST-Link',
      ),
    );
    final controller = AppController(
      backend: backend,
      browserMode: true,
      backupDownloader: (_, _) async {},
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(controller: controller)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Connect ST-Link'), findsNothing);
    expect(controller.backendStatusLabel, 'Remembered ST-Link');
    expect(controller.canStart, isTrue);
  });

  testWidgets('disconnected WebUSB failure reconnects without setup dead end', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'defaultAutoRetry': 0,
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 768);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final backend = _UsbProbeBackend(
      const HardwareDeviceStatus(HardwareDeviceState.disconnected),
    )..cancelSelection = false;
    final controller = AppController(
      backend: backend,
      browserMode: true,
      backupDownloader: (_, _) async {},
    );
    addTearDown(controller.dispose);
    controller.setDefaultAutoRetry(0);

    await controller.start();
    expect(controller.stage, StageState.fail);
    expect(controller.failurePrimaryLabel, 'Connect ST-Link');

    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(controller: controller)),
    );
    await tester.pump();

    expect(find.text('Back to setup'), findsNothing);
    expect(find.text('Connect ST-Link'), findsOneWidget);

    await tester.tap(find.text('Connect ST-Link'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(controller.stage, StageState.idle);
    expect(controller.deviceProbeReady, isTrue);
    expect(find.text('Ready to start'), findsOneWidget);
    expect(find.text('Check connection'), findsWidgets);
  });

  testWidgets(
    'browser slot-0 Flash Only requires confirmation before writing',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1024, 768);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final controller = AppController(
        backend: SwdartBackend(),
        browserMode: true,
        backupDownloader: (_, _) async {},
      );
      addTearDown(controller.dispose);
      controller.selectAction('flash_only');
      controller.setFlashScope(FlashScope.slot0);
      final payload = Uint8List.fromList(
        List<int>.generate(0xE000, (i) => i % 251),
      );
      const banner = 'SCOOTER_VCU_xxG3';
      payload.setRange(0x400, 0x400 + banner.length, banner.codeUnits);
      final package = PackV3.makeZipV32(
        data: payload,
        name: 'G3 VCU test',
        typeFlag: 'VCU',
        model: 'g3',
        boards: const ['g3_VCU_AT32'],
      );
      expect(
        controller.loadSlotFirmwareFromZipBytes('package.zip', package).ok,
        isTrue,
      );

      await tester.pumpWidget(
        MaterialApp(home: HomeScreen(controller: controller)),
      );
      await tester.pump();
      await tester.tap(find.text('Flash without backup'));
      await tester.pump();

      expect(find.text('Compatibility warning'), findsOneWidget);
      expect(find.text('Flash anyway'), findsOneWidget);
      expect(controller.stage, StageState.idle);
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      expect(find.text('Compatibility warning'), findsNothing);
      expect(controller.stage, StageState.idle);
    },
  );

  testWidgets('backup info is revealed only from a result sidecar', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 768);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final dir = Directory.systemTemp.createTempSync('x3utils_backup_info_ui_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final dump = File('${dir.path}${Platform.pathSeparator}dump.bin')
      ..writeAsBytesSync([1]);
    final sidecar = File('${dir.path}${Platform.pathSeparator}dump.json')
      ..writeAsStringSync('''
{
  "schema": 1,
  "backup": "dump.bin",
  "dumpVerdict": "ok",
  "type": "VCU",
  "model": "g3",
  "version": "1.6.1",
  "versionVerdict": "identified",
  "serial": "1CGCC9926C8115",
  "serialState": "real",
  "uid": "C49B0DB900002193A70705E8",
  "uidState": "matched",
  "key": "fe801cb2d1ef41a6",
  "keyState": "defaultKey",
  "rand": "ffffffffffff",
  "zpPayloadLen": 59028,
  "zpEncLen": 59032,
  "zpState": "readable"
}
''');

    final copied = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(const X3UtilsApp());
    final dynamic homeState = tester.state(find.byType(HomeScreen));
    homeState.c.stage = StageState.ok;
    homeState.c.resultPath = dump.path;
    homeState.c.resultMetadataPath = sidecar.path;
    homeState.c.notifyListeners();
    await tester.pump();

    expect(find.text('Show backup info'), findsOneWidget);
    expect(find.text('C49B0DB900002193A70705E8'), findsNothing);

    await tester.tap(find.text('Show backup info'));
    await tester.pump();
    expect(find.text('Backup info'), findsOneWidget);
    expect(find.text('UID'), findsOneWidget);
    // Seven rows, not eight: a sidecar only exists for a dump that already
    // validated, so a Verdict row could only ever say `ok`.
    expect(find.byType(SelectableText), findsNWidgets(7));
    expect(find.text('Verdict'), findsNothing);

    // Opening the dialog reveals nothing per-unit: the identity rows keep
    // their shape and their state, but not their value.
    List<String?> shownValues() => tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((field) => field.data)
        .toList();
    expect(shownValues(), contains('•••• •••• •••• •••• •••• •••• (matched)'));
    expect(shownValues(), contains('••••••••••••••'));
    expect(shownValues(), contains('•• •• •• •• •• •• •• •• (default key)'));
    expect(shownValues(), contains('•• •• •• •• •• ••'));
    // Non-identity rows are never masked.
    expect(shownValues(), contains('G3 VCU 1.6.1 (identified)'));
    expect(shownValues(), contains('59028 payload / 59032 encoded (readable)'));

    await tester.tap(find.text('Reveal'));
    await tester.pump();
    expect(shownValues(), contains('C49B 0DB9 0000 2193 A707 05E8 (matched)'));
    expect(shownValues(), contains('1CGCC9926C8115'));
    expect(shownValues(), contains('FE 80 1C B2 D1 EF 41 A6 (default key)'));
    expect(shownValues(), contains('FF FF FF FF FF FF'));

    await tester.tap(find.text('Hide'));
    await tester.pump();
    expect(shownValues(), contains('•••• •••• •••• •••• •••• •••• (matched)'));

    // Copy all hands over the rows as read on screen — never the mask, and
    // never raw JSON.
    await tester.tap(find.text('Copy all'));
    await tester.pump();
    expect(copied, hasLength(1));
    expect(copied.single, isNot(contains('•')));
    expect(copied.single, isNot(contains('{')));
    expect(
      copied.single,
      '''
Backup    dump.bin
Firmware  G3 VCU 1.6.1 (identified)
Serial    1CGCC9926C8115
UID       C49B 0DB9 0000 2193 A707 05E8 (matched)
Key       FE 80 1C B2 D1 EF 41 A6 (default key)
Rand      FF FF FF FF FF FF
ZP        59028 payload / 59032 encoded (readable)'''
          .trim(),
    );
    expect(find.text('Copied'), findsOneWidget);
  });

  testWidgets('Get file info sits in Advanced between ZIP3 and protection', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 768);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(const X3UtilsApp());

    expect(find.text('Get file info'), findsNothing); // Advanced is collapsed
    await tester.tap(find.text('ADVANCED'));
    await tester.pump(const Duration(milliseconds: 250));

    double top(String label) => tester.getTopLeft(find.text(label)).dy;
    expect(top('Get file info'), greaterThan(top('ZIP3 tools')));
    expect(top('Get file info'), lessThan(top('Check protection')));

    // It selects like any other action and gets a normal hero page, which is
    // where display options can live later. Fired through the tile's own
    // callback because a fifth Advanced action sits below the fold of the
    // 1024x768 rail, which scrolls.
    final tile = tester.widget<InkWell>(
      find
          .ancestor(
            of: find.text('Get file info'),
            matching: find.byType(InkWell),
          )
          .first,
    );
    tile.onTap!();
    await tester.pump();
    final dynamic homeState = tester.state(find.byType(HomeScreen));
    expect(homeState.c.actionId, 'file_info');
    expect(find.text('Choose a file'), findsOneWidget);
    expect(find.text('Choose .bin / .zip'), findsOneWidget);
    expect(find.text('Show file info'), findsWidgets);
    // Reading a file is not a run: it must not be able to enter the busy or
    // verdict states, and its picker takes packages as well as images.
    expect(homeState.c.canStart, isFalse); // nothing picked yet
    expect(homeState.c.running, isFalse);
    expect(homeState.c.stage, StageState.idle);
    expect(homeState.c.hasFlashScope, isFalse);
    expect(homeState.c.isSlotAction, isFalse);
  });

  testWidgets('Backup info persists an operator-declared MCU model', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 768);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final dir = Directory.systemTemp.createTempSync('x3utils_backup_mcu_ui_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final bytes = List<int>.filled(131072, 0);
    bytes.setRange(0x1400, 0x1410, 'SCOOTER_MCU_0001'.codeUnits);
    final dump = File('${dir.path}${Platform.pathSeparator}dump.bin')
      ..writeAsBytesSync(bytes);
    final sidecar = DumpMetadata.writeValidatedSidecar(dump.path);

    await tester.pumpWidget(const X3UtilsApp());
    final dynamic homeState = tester.state(find.byType(HomeScreen));
    homeState.c.stage = StageState.ok;
    homeState.c.resultPath = dump.path;
    homeState.c.resultMetadataPath = sidecar;
    homeState.c.notifyListeners();
    await tester.pump();

    await tester.tap(find.text('Show backup info'));
    await tester.pump();
    expect(find.text('Which scooter is this?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(DumpMetadata.readJson(sidecar)['model'], isNull);

    await tester.tap(find.text('Show backup info'));
    await tester.pump();
    await tester.tap(find.text('G3'));
    await tester.pump();
    expect(find.text('Backup info'), findsOneWidget);
    expect(find.textContaining('operator-declared'), findsOneWidget);
    final persisted = DumpMetadata.readJson(sidecar);
    expect(persisted['model'], 'g3');
    expect(persisted['modelSource'], 'operatorDeclared');
  });

  testWidgets(
    'Get file info reuses the MCU picker and cancel only stops info',
    (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1024, 768);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final dir = Directory.systemTemp.createTempSync('x3utils_file_info_mcu_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final bytes = List<int>.filled(131072, 0);
      bytes.setRange(0x1400, 0x1410, 'SCOOTER_MCU_0001'.codeUnits);
      final file = File('${dir.path}${Platform.pathSeparator}mcu.bin')
        ..writeAsBytesSync(bytes);

      await tester.pumpWidget(const X3UtilsApp());
      final dynamic homeState = tester.state(find.byType(HomeScreen));
      homeState.c.selectAction('file_info');
      homeState.c.setFirmware(file.path);
      await tester.pump();

      await tester.tap(find.text('Show file info').last);
      await tester.pump();
      expect(find.text('Which scooter is this?'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pump();
      expect(find.text('Which scooter is this?'), findsNothing);
      expect(find.text('File info'), findsNothing);
      expect(homeState.c.firmwarePath, file.path);
      expect(homeState.c.running, isFalse);
      expect(homeState.c.stage, StageState.idle);

      await tester.tap(find.text('Show file info').last);
      await tester.pump();
      await tester.tap(find.text('G3'));
      await tester.pump();
      expect(find.text('File info'), findsOneWidget);
      expect(find.textContaining('operator-declared'), findsOneWidget);
      expect(homeState.c.running, isFalse);
      expect(homeState.c.stage, StageState.idle);
    },
  );

  testWidgets('SHU compat requires the timed firmware-version warning', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 768);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(const X3UtilsApp());

    // SHU compat lives in Advanced, which is collapsed at boot.
    await tester.tap(find.text('ADVANCED'));
    await tester.pump(const Duration(milliseconds: 250));
    final shuTile = tester.widget<InkWell>(
      find
          .ancestor(
            of: find.text('SHU compatible'),
            matching: find.byType(InkWell),
          )
          .first,
    );
    shuTile.onTap!();
    await tester.pump();

    expect(find.text('ATTENTION'), findsOneWidget);
    expect(find.textContaining('F3 VCU — 1.6.3'), findsOneWidget);
    expect(find.textContaining('G3 VCU — 1.6.3'), findsOneWidget);
    expect(find.textContaining('GT3 VCU — 1.7.2'), findsOneWidget);
    expect(find.textContaining('ZT3 VCU — 1.5.9'), findsOneWidget);
    expect(find.text('I understand — continue (5s)'), findsOneWidget);
    expect(find.text('Ready to start'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.tap(find.text('I understand — continue'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Make SHU compatible'), findsOneWidget);
    expect(find.text('ATTENTION'), findsNothing);
  });

  testWidgets('Flash Only exposes centered full and slot-0 scopes', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 768);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(const X3UtilsApp());

    final openConsole = find.text('▾ Console');
    if (openConsole.evaluate().isNotEmpty) {
      await tester.tap(openConsole);
      await tester.pump(const Duration(milliseconds: 300));
    }
    await tester.tap(find.text('ADVANCED'));
    await tester.pump(const Duration(milliseconds: 250));
    final flashTile = tester.widget<InkWell>(
      find
          .ancestor(of: find.text('Flash Only'), matching: find.byType(InkWell))
          .first,
    );
    flashTile.onTap!();
    await tester.pump();
    expect(find.text('Flash Only — no safety nets'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.tap(find.text('I understand — continue'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Choose firmware'), findsOneWidget);
    expect(find.text('Full image'), findsOneWidget);
    expect(find.text('Slot 0 only'), findsOneWidget);
    expect(find.text('Choose .zip'), findsOneWidget);

    await tester.tap(find.text('Slot 0 only'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.text('Choose a slot-sized .bin or zip3 package below.'),
      findsOneWidget,
    );
  });

  testWidgets('ZIP3 tools use a locked three-page workspace', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 768);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(const X3UtilsApp());

    final openConsole = find.text('▾ Console');
    if (openConsole.evaluate().isNotEmpty) {
      await tester.tap(openConsole);
      await tester.pump(const Duration(milliseconds: 300));
    }
    await tester.tap(find.text('ADVANCED'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('slice · pack · unpack'), findsOneWidget);
    expect(find.text('slice · pack · unpack · offline'), findsNothing);
    final zip3Tile = tester.widget<InkWell>(
      find
          .ancestor(of: find.text('ZIP3 tools'), matching: find.byType(InkWell))
          .first,
    );
    // ZIP3 tools currently opens directly; its intro modal is disabled pending
    // a rewrite for the three distinct Slice / Pack / Unpack workflows.
    zip3Tile.onTap!();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('What Pack zip3 is for'), findsNothing);

    // The identity form and its controls are present.
    expect(find.text('PACKAGE IDENTITY'), findsOneWidget);
    expect(find.text('Type'), findsOneWidget);
    expect(find.text('Model'), findsOneWidget);
    // Legacy zip3 is the default format, so its enforceModel option is shown
    // from the start — SHU 4.1 rejects zip3.2, so the default is the format the
    // app in the field actually reads.
    expect(find.textContaining('Enforce model'), findsOneWidget);
    expect(find.textContaining('Package name'), findsOneWidget);
    expect(find.text('Choose a backup dump'), findsOneWidget);
    expect(
      find.text('Choose a full 128 KB backup .bin below.'),
      findsOneWidget,
    );
    expect(find.text('Pack zip 3'), findsWidgets);

    // The split arrow changes format only. Selecting zip3.2 hides the legacy
    // metadata option, and does not start the pack operation.
    final dynamic zipHomeState = tester.state(find.byType(HomeScreen));
    await tester.tap(find.byTooltip('Choose package format'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // First entry is zip3.2; legacy is the default now, so this is the switch.
    await tester.tap(
      find.byType(CheckedPopupMenuItem<Zip3Format>).first,
      warnIfMissed: false,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(zipHomeState.c.zip3Format, Zip3Format.rev2);
    expect(zipHomeState.c.stage, StageState.idle);
    expect(find.textContaining('Enforce model'), findsNothing);
    expect(find.text('Pack zip 3.2'), findsOneWidget);

    final pageView = tester.widget<PageView>(find.byType(PageView));
    expect(pageView.scrollDirection, Axis.vertical);
    expect(pageView.physics, isA<NeverScrollableScrollPhysics>());
    expect(pageView.allowImplicitScrolling, isFalse);
    final chooseBinButton = find
        .ancestor(of: find.text('Choose .bin'), matching: find.byType(InkWell))
        .first;
    expect(
      tester.getSize(find.byKey(const ValueKey('zip3-slice'))).height,
      tester.getSize(chooseBinButton).height,
    );

    tester.widget<InkWell>(find.byKey(const ValueKey('zip3-pack'))).onTap!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.widget<PageView>(find.byType(PageView)).controller!.page, 1);
    expect(find.text('Choose a firmware payload'), findsOneWidget);
    expect(
      find.text('Choose the complete firmware .bin to package below.'),
      findsOneWidget,
    );
    expect(find.text('PACKAGE IDENTITY'), findsOneWidget);

    tester.widget<InkWell>(find.byKey(const ValueKey('zip3-unpack'))).onTap!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.widget<PageView>(find.byType(PageView)).controller!.page, 2);
    expect(find.text('Choose a zip3 package'), findsOneWidget);
    expect(find.text('PACKAGE DETAILS'), findsOneWidget);
    expect(find.text('Output filename'), findsOneWidget);
    expect(find.textContaining('.bin is added automatically'), findsOneWidget);
    expect(find.text('Unpack zip3'), findsOneWidget);
    final chooseZipInk = tester.widget<InkWell>(
      find
          .ancestor(
            of: find.text('Choose .zip'),
            matching: find.byType(InkWell),
          )
          .first,
    );
    expect(chooseZipInk.onTap, isNotNull);
    final unpackInk = tester.widget<InkWell>(
      find
          .ancestor(
            of: find.text('Unpack zip3'),
            matching: find.byType(InkWell),
          )
          .first,
    );
    expect(unpackInk.onTap, isNull);

    // A completed Unpack temporarily replaces the three-page setup with the
    // generic result hero. Done must restore page 2 because UNPACK remains the
    // selected workspace toggle.
    final dynamic homeState = tester.state(find.byType(HomeScreen));
    homeState.c.stage = StageState.ok;
    homeState.c.notifyListeners();
    await tester.pump();
    expect(find.byType(PageView), findsNothing);
    homeState.c.dismiss();
    await tester.pump();
    await tester.pump();
    expect(tester.widget<PageView>(find.byType(PageView)).controller!.page, 2);
    expect(find.text('Choose a zip3 package'), findsOneWidget);

    tester.widget<InkWell>(find.byKey(const ValueKey('zip3-slice'))).onTap!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.widget<PageView>(find.byType(PageView)).controller!.page, 0);
    expect(find.text('Choose a backup dump'), findsOneWidget);
  });
}
