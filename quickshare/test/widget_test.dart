import 'package:flutter_test/flutter_test.dart';
import 'package:quickshare/app.dart';
import 'package:quickshare/core/di/service_locator.dart';

void main() {
  tearDown(() async {
    await sl.reset();
  });

  testWidgets('DirectDropApp smoke test', (WidgetTester tester) async {
    await ServiceLocator.init();
    await tester.pumpWidget(const DirectDropApp());
    expect(find.byType(DirectDropApp), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
  });
}




