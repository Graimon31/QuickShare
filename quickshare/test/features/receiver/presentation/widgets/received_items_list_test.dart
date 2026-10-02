import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/storage/received_item.dart';
import 'package:quickshare/features/receiver/presentation/widgets/received_items_list.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('dd_items_list_'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  testWidgets('opening a folder lists what is inside it', (tester) async {
    final trip = Directory(p.join(root.path, 'trip'))..createSync();
    File(p.join(trip.path, 'a.jpg')).writeAsStringSync('12345');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ReceivedItemsList(items: [
          ReceivedItem(
            cachePath: trip.path,
            name: 'trip',
            size: 5,
            mimeType: 'inode/directory',
            isDirectory: true,
          ),
        ]),
      ),
    ));

    // The listing reads the real disk, which lives outside the fake-async
    // zone widget tests run in — runAsync lets the read actually finish.
    await tester.runAsync(() async {
      await tester.tap(find.text('trip'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    expect(find.text('a.jpg'), findsOneWidget);
  });

  testWidgets('a folder that cannot be read opens to nothing, not a crash',
      (tester) async {
    final gone = p.join(root.path, 'vanished');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ReceivedItemsList(items: [
          ReceivedItem(
            cachePath: gone,
            name: 'vanished',
            size: 0,
            mimeType: 'inode/directory',
            isDirectory: true,
          ),
        ]),
      ),
    ));

    await tester.runAsync(() async {
      await tester.tap(find.text('vanished'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
