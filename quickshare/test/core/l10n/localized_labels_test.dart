// Nothing the user reads is decided by the code that recorded it.
//
// DD-17. The `.arb` files matched key for key, which is what a localization
// check usually looks at, and both screens that matter were still English
// under a Russian interface. The reason was not a missing translation: the
// bloc composed the sentence itself — `'Transfer failed unexpectedly'`,
// `'${report.role} … in ${took}s'`, `route: 'Local network'` — and wrote it
// into the journal or the error state as a finished string. A phrase written
// at that moment can only be in one language, and it is not necessarily the
// one the app is set to now.
//
// So the recorded value is a value, and this is where it becomes words.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/diagnostics/transfer_report.dart';
import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/l10n/localized_labels.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';

/// Every `FailureCode` constant, read from the source rather than listed
/// here. A code added to that file and forgotten in `localizedFailure` is
/// exactly the regression this guards, and a hand-kept copy of the list
/// would be forgotten in the same commit.
List<String> declaredFailureCodes() {
  for (final base in ['.', '..', 'quickshare']) {
    final f = File('$base/lib/core/errors/failures.dart');
    if (!f.existsSync()) continue;
    final source = f.readAsStringSync();
    final matches = RegExp(r"static const \w+ = '(\w+)';").allMatches(source);
    final codes = [for (final m in matches) m.group(1)!];
    if (codes.isEmpty) fail('found failures.dart but no codes in it');
    return codes;
  }
  fail('could not find lib/core/errors/failures.dart');
}

/// Cyrillic anywhere in the string. Crude on purpose: the point is not which
/// words were chosen, it is that the Russian build is not showing English.
final _cyrillic = RegExp(r'[Ѐ-ӿ]');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppLocalizations ru;
  late AppLocalizations en;

  setUpAll(() async {
    ru = await AppLocalizations.delegate.load(const Locale('ru'));
    en = await AppLocalizations.delegate.load(const Locale('en'));
  });

  group('failures', () {
    test('every failure the app names itself has Russian words for it', () {
      final untranslated = <String>[];
      for (final code in declaredFailureCodes()) {
        final shown =
            localizedFailure(ru, code: code, fallback: 'FELL BACK TO ENGLISH');
        if (shown == 'FELL BACK TO ENGLISH' || !_cyrillic.hasMatch(shown)) {
          untranslated.add(code);
        }
      }
      expect(untranslated, isEmpty,
          reason: 'these codes reach a Russian screen as English: '
              '$untranslated');
    });

    test('the generic transport failure is not English any more', () {
      // The one the screen showed for everything, including the dozen
      // failures the app could name precisely.
      final shown = localizedFailure(ru,
          code: FailureCode.transferFailedUnexpectedly,
          fallback: 'Transfer failed unexpectedly');
      expect(shown, isNot(contains('Transfer failed')));
      expect(_cyrillic.hasMatch(shown), isTrue);
    });

    test('an older receiver is told to update in its own language', () {
      for (final code in [
        FailureCode.receiverTooOldForDirectLink,
        FailureCode.receiverTooOldToPair,
      ]) {
        expect(_cyrillic.hasMatch(localizedFailure(ru, code: code, fallback: '')),
            isTrue);
        expect(localizedFailure(en, code: code, fallback: ''),
            contains('older version'));
      }
    });

    test('a caught exception still shows its own text', () {
      // No table covers a `DioException`, and inventing a vague sentence in
      // place of the only words that exist for it helps nobody.
      const raw = 'DioException: Connection closed before full header';
      expect(localizedFailure(ru, code: null, fallback: raw), equals(raw));
      expect(
          localizedFailure(ru, code: 'somethingAddedLater', fallback: raw),
          equals(raw));
    });
  });

  group('the journal', () {
    TransferReport report({
      TransferRole role = TransferRole.sent,
      TransferRoute route = TransferRoute.localNetwork,
      String failure = '',
      String? failureCode,
    }) =>
        TransferReport(
          at: DateTime(2026, 9, 10, 18, 4),
          role: role,
          route: route,
          bytes: 64 * 1000 * 1000,
          took: const Duration(seconds: 8),
          failure: failure,
          failureCode: failureCode,
        );

    test('every route has a Russian name', () {
      for (final route in TransferRoute.values) {
        final shown = route.localized(ru);
        expect(shown, isNotEmpty, reason: '$route');
        if (route == TransferRoute.bluetooth) continue; // a brand, not a word
        expect(_cyrillic.hasMatch(shown), isTrue,
            reason: '$route reads as "$shown" on a Russian screen');
      }
    });

    test('the same report reads as English or Russian on demand', () {
      final sent = report(route: TransferRoute.directWifiLink);
      expect(sent.route.localized(en), equals('Direct Wi-Fi link'));
      expect(_cyrillic.hasMatch(sent.route.localized(ru)), isTrue);
    });

    test('what this device did is one sentence, not three fragments', () {
      // "sent" + size + "in Ns" is three pieces in English and one clause in
      // Russian, with the verb agreeing with neither of the others — so the
      // whole line is a translated string with the numbers dropped in.
      expect(report(role: TransferRole.sent).outcome(en),
          equals('Sent 64 MB in 8s'));
      expect(report(role: TransferRole.received).outcome(en),
          equals('Received 64 MB in 8s'));

      final sentRu = report(role: TransferRole.sent).outcome(ru);
      final receivedRu = report(role: TransferRole.received).outcome(ru);
      expect(sentRu, contains('64 MB'));
      expect(sentRu, contains('8'));
      expect(_cyrillic.hasMatch(sentRu), isTrue);
      expect(sentRu, isNot(equals(receivedRu)),
          reason: 'which end this device was is part of the sentence');
    });

    test('a failed entry shows the reason in the same language', () {
      final failed = report(
          failure: 'Cancelled', failureCode: FailureCode.cancelledHere);
      expect(failed.succeeded, isFalse);
      expect(_cyrillic.hasMatch(failed.outcome(ru)), isTrue);
      expect(failed.outcome(ru), isNot(contains('Cancelled')));
    });

    test('a failure with no code keeps the only words it has', () {
      final failed = report(failure: 'SocketException: Broken pipe');
      expect(failed.succeeded, isFalse);
      expect(failed.outcome(ru), equals('SocketException: Broken pipe'));
    });
  });

  group('the diagnostics block stays English', () {
    // It is pasted to whoever is being asked for help, who does not
    // necessarily have this app, let alone this language. Translating it
    // would move the translation problem to the person answering.
    test('the summary and the stored reason are English whatever is on screen',
        () {
      final report = TransferReport(
        at: DateTime(2026, 9, 10, 18, 4),
        role: TransferRole.sent,
        route: TransferRoute.internetRelayed,
        bytes: 1024,
        took: const Duration(seconds: 2),
        failure: 'Connection lost',
        failureCode: FailureCode.transferFailedUnexpectedly,
      );
      expect(report.summary, contains('Route: Internet (relayed)'));
      expect(report.summary, contains('Failed: Connection lost'));
      expect(_cyrillic.hasMatch(report.summary), isFalse);
    });
  });

  group('the two languages stay level', () {
    // Not the defect DD-17 was — the keys already matched, and both screens
    // were still English — but the guard belongs next to the fix: a code
    // added with only an English string reads as English on a Russian
    // screen, which is the same failure by a different route.
    Map<String, dynamic> arb(String name) {
      for (final base in ['.', '..', 'quickshare']) {
        final f = File('$base/lib/l10n/$name');
        if (f.existsSync()) {
          return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        }
      }
      fail('could not find lib/l10n/$name');
    }

    test('every English string has a Russian one', () {
      final en = arb('app_en.arb');
      final ru = arb('app_ru.arb');
      // `@key` entries are placeholder metadata, declared once in the
      // template; only the strings themselves have to exist in both.
      final missing = [
        for (final key in en.keys)
          if (!key.startsWith('@') && !ru.containsKey(key)) key
      ];
      expect(missing, isEmpty,
          reason: 'these read as English under a Russian interface: $missing');
    });

    test('and nothing is translated that no longer exists', () {
      final en = arb('app_en.arb');
      final ru = arb('app_ru.arb');
      final orphans = [
        for (final key in ru.keys)
          if (!key.startsWith('@') && !en.containsKey(key)) key
      ];
      expect(orphans, isEmpty);
    });
  });

  group('a journal written by an older build', () {
    // There is one on every device that has ever completed a transfer, and
    // it stores the English phrase where the value now goes. Reading those
    // back as "unknown" would blank the history for exactly the people who
    // have one.
    test('the phrases the old build wrote still name a route', () {
      expect(TransferRoute.fromJson('Local network'),
          equals(TransferRoute.localNetwork));
      expect(TransferRoute.fromJson('Direct Wi-Fi link'),
          equals(TransferRoute.directWifiLink));
      expect(TransferRoute.fromJson('Internet (relayed)'),
          equals(TransferRoute.internetRelayed));
      expect(TransferRoute.fromJson('Bluetooth'),
          equals(TransferRoute.bluetooth));
      expect(TransferRole.fromJson('received'),
          equals(TransferRole.received));
    });

    test('and one it never wrote is unknown rather than a crash', () {
      expect(TransferRoute.fromJson('route 7'), equals(TransferRoute.unknown));
      expect(TransferRoute.fromJson(null), equals(TransferRoute.unknown));
      expect(TransferRoute.fromJson(''), equals(TransferRoute.unknown));
    });

    test('a round trip through disk keeps the value', () {
      final json = TransferReport(
        at: DateTime(2026, 9, 10, 18, 4),
        role: TransferRole.received,
        route: TransferRoute.internetPeerToPeer,
        bytes: 10,
        took: const Duration(seconds: 1),
        failure: 'boom',
        failureCode: FailureCode.linkSetupFailed,
      ).toJson();
      expect(json['route'], equals('internetPeerToPeer'));
      expect(json['role'], equals('received'));

      final back = TransferReport.fromJson(json);
      expect(back.route, equals(TransferRoute.internetPeerToPeer));
      expect(back.role, equals(TransferRole.received));
      expect(back.failureCode, equals(FailureCode.linkSetupFailed));
    });
  });
}
