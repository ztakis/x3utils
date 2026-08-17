// The phone TIER (layout + reduced action set) is separate from the Android
// PLATFORM (USB-host transport, scoped storage, permission wording). They
// coincide in the APK and diverge in the mobile web build at /m/.
//
// These tests exist because that split is invisible at a call site: every
// `c.phoneMode` and `c.androidMode` in main.dart looks identical, and putting
// one on the wrong flag produces a build that renders correctly and lies to the
// operator about where its backups went.

import 'dart:ui' show Size;

import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter/widgets.dart' show ValueKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:x3utils_flutter/app_controller.dart';
import 'package:x3utils_flutter/engine/android_backup_store.dart';
import 'package:x3utils_flutter/main.dart';
import 'package:x3utils_flutter/models.dart';

void main() {
  // AppController reads SharedPreferences from its constructor, so even the
  // pure-logic cases need the binding and a mock store.
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('phone tier is separate from the Android platform', () {
    test('mobile web is the phone tier WITHOUT the Android platform', () {
      final c = AppController(phoneMode: true, browserMode: true);
      addTearDown(c.dispose);

      expect(c.phoneMode, isTrue, reason: 'compact layout + reduced actions');
      expect(c.androidMode, isFalse, reason: 'no USB-host, no scoped storage');
      expect(c.browserMode, isTrue);
    });

    test('the APK gets the phone tier for free — androidMode implies it', () {
      final c = AppController(androidMode: true);
      addTearDown(c.dispose);

      // phoneMode defaults to androidMode. If this ever fails, the split has
      // changed the shipping APK, which it must not.
      expect(c.phoneMode, isTrue);
      expect(c.androidMode, isTrue);
    });

    test('desktop is neither', () {
      final c = AppController(browserMode: false, androidMode: false);
      addTearDown(c.dispose);

      expect(c.phoneMode, isFalse);
      expect(c.androidMode, isFalse);
    });

    test('desktop web is not the phone tier', () {
      final c = AppController(browserMode: true, androidMode: false);
      addTearDown(c.dispose);

      expect(c.browserMode, isTrue);
      expect(c.phoneMode, isFalse, reason: '/ keeps the full web layout');
    });
  });

  group('platform-worded labels follow the platform, not the tier', () {
    test('transport label names the transport actually in use', () {
      final web = AppController(phoneMode: true, browserMode: true);
      addTearDown(web.dispose);
      final apk = AppController(androidMode: true);
      addTearDown(apk.dispose);

      expect(web.probeTransportLabel, 'ST-LINK · WebUSB');
      expect(apk.probeTransportLabel, 'ST-LINK · USB OTG');
    });

    test('backup destination is only claimed when it is knowable', () {
      final web = AppController(phoneMode: true, browserMode: true);
      addTearDown(web.dispose);
      final apk = AppController(androidMode: true);
      addTearDown(apk.dispose);

      // Android publishes through scoped storage to a folder it chose. Chrome
      // hands the file to the browser, which decides — so naming a path there
      // would be a guess presented as fact.
      expect(apk.backupDestinationLabel, androidBackupDirectoryLabel);
      expect(web.backupDestinationLabel, 'Browser download');
      expect(web.backupDestinationLabel, isNot(contains('Downloads/')));
    });
  });

  group('the reduced feature set follows the tier', () {
    test('mobile web offers the phone connection modes, not the full list', () {
      final web = AppController(phoneMode: true, browserMode: true);
      addTearDown(web.dispose);
      final desktopWeb = AppController(browserMode: true, androidMode: false);
      addTearDown(desktopWeb.dispose);

      expect(web.availableModes, contains(ConnectionMode.defaultSwd));
      expect(
        web.availableModes.length,
        lessThanOrEqualTo(desktopWeb.availableModes.length),
        reason: 'the phone tier is a subset of the web build',
      );
    });

    test('Make zip3 stays off the phone, as it is off the web build', () {
      final web = AppController(phoneMode: true, browserMode: true);
      addTearDown(web.dispose);

      expect(web.isActionAvailable('make_zip3'), isFalse);
      expect(web.isActionAvailable('check'), isTrue);
    });
  });

  group('mobile web renders the phone tree', () {
    Future<AppController> pumpMobileWeb(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final controller = AppController(phoneMode: true, browserMode: true);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(home: HomeScreen(controller: controller)),
      );
      await tester.pump();
      return controller;
    }

    testWidgets('the phone layout appears without the Android wording', (
      tester,
    ) async {
      await pumpMobileWeb(tester);

      // The tier came through: this is the compact tree, not the desktop one.
      expect(find.byKey(const ValueKey('android-check-page')), findsOneWidget);
      expect(find.byKey(const ValueKey('android-default-swd')), findsOneWidget);

      // The platform did NOT come through with it.
      expect(find.text('ST-LINK · WebUSB'), findsWidgets);
      expect(find.text('ST-LINK · USB OTG'), findsNothing);
    });

    testWidgets('the console back pill is browser-only', (tester) async {
      final c = await pumpMobileWeb(tester);

      c.toggleConsole();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.text('Back'),
        findsOneWidget,
        reason:
            'Chrome contests the left-edge swipe, so the bottom pill is the '
            'one back control the browser cannot take away',
      );
    });

    testWidgets('the APK console has no back pill', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final c = AppController(androidMode: true);
      addTearDown(c.dispose);
      await tester.pumpWidget(MaterialApp(home: HomeScreen(controller: c)));
      await tester.pump();

      c.toggleConsole();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Back'), findsNothing);
    });
  });
}
