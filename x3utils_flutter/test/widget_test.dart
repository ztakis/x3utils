import 'package:flutter_test/flutter_test.dart';
import 'package:x3utils_flutter/main.dart';

void main() {
  testWidgets('App boots and shows the default action',
      (WidgetTester tester) async {
    await tester.pumpWidget(const X3UtilsApp());
    // Title bar brand + the default "Check connection" action are present.
    expect(find.text('x3utils'), findsOneWidget);
    expect(find.text('Check connection'), findsWidgets);
  });
}
