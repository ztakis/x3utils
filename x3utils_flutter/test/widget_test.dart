import 'dart:ui' show Offset, Size;

import 'package:flutter/widgets.dart' show Scrollable;
import 'package:flutter_test/flutter_test.dart';
import 'package:x3utils_flutter/main.dart';

void main() {
  testWidgets('App boots and shows the default action', (
    WidgetTester tester,
  ) async {
    // The desktop app starts at 1200x800; Flutter's 800x600 test default is
    // narrower than the supported layout and overflows the status/console rows.
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(const X3UtilsApp());
    // Title bar brand + the default "Check connection" action are present.
    expect(find.text('x3utils'), findsOneWidget);
    expect(find.text('Check connection'), findsWidgets);
  });

  testWidgets('Flash Only exposes centered full and slot-0 scopes', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
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
    final railScroll = find.ancestor(
      of: find.text('Flash Only'),
      matching: find.byType(Scrollable),
    );
    await tester.fling(railScroll, const Offset(0, -200), 1000);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Flash Only'));
    await tester.pump();
    expect(find.text('Flash Only — no safety nets'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.tap(find.text('I understand — continue'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Choose a full image'), findsOneWidget);
    expect(find.text('Full image'), findsOneWidget);
    expect(find.text('Slot 0 only'), findsOneWidget);
    expect(find.text('Choose .zip'), findsOneWidget);

    await tester.tap(find.text('Slot 0 only'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Choose slot-0 firmware'), findsOneWidget);
  });

  testWidgets('Make zip3 shows the offline packer form', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
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
    final railScroll = find.ancestor(
      of: find.text('Flash slot 0'),
      matching: find.byType(Scrollable),
    );
    await tester.fling(railScroll, const Offset(0, -200), 1000);
    await tester.pump(const Duration(milliseconds: 500));
    // Opening Make zip3 shows an untimed "what is this for" intro; Continue
    // enters the action (no countdown, unlike the Flash Only gate).
    await tester.tap(find.text('Make zip3').first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('What Make zip3 is for'), findsOneWidget);
    await tester.tap(find.text('Continue'));
    await tester.pump(const Duration(milliseconds: 300));

    // The identity form and its controls are present.
    expect(find.text('PACKAGE IDENTITY'), findsOneWidget);
    expect(find.text('Type'), findsOneWidget);
    expect(find.text('Model'), findsOneWidget);
    expect(find.textContaining('Enforce model'), findsOneWidget);
    expect(find.text('Package name'), findsOneWidget);
  });
}
