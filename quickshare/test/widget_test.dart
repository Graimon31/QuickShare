import 'package:flutter_test/flutter_test.dart';
import 'package:quickshare/app.dart';
import 'package:quickshare/core/di/service_locator.dart';

void main() {
  tearDown(() async {
    await sl.reset();
  });

  testWidgets('QuickShareApp smoke test', (WidgetTester tester) async {
    await ServiceLocator.init();
    await tester.pumpWidget(const QuickShareApp());
    expect(find.byType(QuickShareApp), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
  });
}




