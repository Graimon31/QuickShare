// Standalone on-device test entry point for a signed release build, without
// Flutter Drive or a VM service. This uses test_api runner internals (the same
// machinery flutter_test's standalone runner uses); it is experimental until
// BOTH passing and intentionally failing probe runs have been observed.
//
// --dart-define=PHYSICAL_SUITE=probe|ui|storage|qhtp|ble|internet_sender|
//   internet_receiver|ui_pair
// --dart-define=PHYSICAL_RUN=<fresh alphanumeric run id>
// --dart-define=PROBE_EXPECT_FAILURE=true  (probe only: intentionally fails)
// The selected suite's ordinary defines (PAIR_ROLE etc.) still apply. Native
// suite effects and permissions remain the same as the underlying test.
// ignore_for_file: avoid_print, implementation_imports
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/common.dart' show Failure;
import 'package:integration_test/integration_test.dart';
// test_api is supplied transitively by flutter_test for this standalone runner.
// ignore: depend_on_referenced_packages
import 'package:test_api/src/backend/declarer.dart';
// ignore: depend_on_referenced_packages
import 'package:test_api/src/backend/group.dart';
// ignore: depend_on_referenced_packages
import 'package:test_api/src/backend/live_test.dart';
// ignore: depend_on_referenced_packages
import 'package:test_api/src/backend/runtime.dart';
// ignore: depend_on_referenced_packages
import 'package:test_api/src/backend/state.dart' as backend;
// ignore: depend_on_referenced_packages
import 'package:test_api/src/backend/suite.dart';
// ignore: depend_on_referenced_packages
import 'package:test_api/src/backend/suite_platform.dart';
// ignore: depend_on_referenced_packages
import 'package:test_api/src/backend/test.dart' as backend;

import 'ci_peer_receiver.dart' as internet_receiver;
import 'ci_peer_sender.dart' as internet_sender;
import 'physical_ble_pair_test.dart' as ble;
import 'physical_test_config.dart';
import 'physical_peer_qhtp_test.dart' as qhtp;
import 'physical_storage_native_test.dart' as storage;
import 'physical_ui_navigation_test.dart' as ui;
import 'physical_ui_transfer_test.dart' as ui_pair;

final suiteName = physicalString('PHYSICAL_SUITE',
    const String.fromEnvironment('PHYSICAL_SUITE', defaultValue: 'probe'));
final runId = physicalString(
    'PHYSICAL_RUN', const String.fromEnvironment('PHYSICAL_RUN'));
final probeFailure = physicalBool(
    'PROBE_EXPECT_FAILURE', const bool.fromEnvironment('PROBE_EXPECT_FAILURE'));

void probe() {
  testWidgets('release probe renders and checks expectations', (tester) async {
    await tester.pumpWidget(const Directionality(
        textDirection: TextDirection.ltr,
        child: Text('physical release probe')));
    expect(find.text('physical release probe'), findsOneWidget);
    expect(Platform.isIOS || Platform.isMacOS, isTrue);
    expect(probeFailure, isFalse,
        reason: 'intentional failing-probe verification');
  });
}

Future<void> main() async {
  // A paired run needs the host's runtime-generated port and TLS fingerprint
  // before its test finishes. Persist just the coordination markers so the
  // device controller can retrieve them without attaching a debug VM service.
  final safeId =
      RegExp(r'^[A-Za-z0-9_-]{1,48}$').hasMatch(runId) ? runId : 'invalid';
  final events =
      File('${Directory.systemTemp.path}/directdrop-physical-$safeId.events');
  await events.writeAsString('', flush: true);
  await runZoned(
    _run,
    zoneSpecification: ZoneSpecification(print: (self, parent, zone, line) {
      final diagnostic = line.startsWith('PAIR_') ||
          line.startsWith('STORAGE_CHECK') ||
          line.startsWith('UI_CHECK') ||
          line.startsWith('UI_PAIR_') ||
          (line.startsWith('CI_PEER') &&
              !line.startsWith('CI_PEER_CODE=') &&
              !line.startsWith('CI_PEER_JSON=') &&
              !line.startsWith('CI_PEER_RESULT_JSON=') &&
              !line.startsWith('CI_PEER_OUT='));
      if (diagnostic) {
        events.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
      }
      parent.print(zone, line);
    }),
  );
}

Future<void> _run() async {
  final safeId =
      RegExp(r'^[A-Za-z0-9_-]{1,48}$').hasMatch(runId) ? runId : 'invalid';
  final resultFile =
      File('${Directory.systemTemp.path}/directdrop-physical-$safeId.json');
  final records = <Map<String, Object?>>[];
  Future<void> write(String status,
      {String? error,
      bool? bindingPassed,
      Map<String, Object?>? bindingResults}) async {
    final output = <String, Object?>{
      'run': safeId,
      'suite': suiteName,
      'status': status,
      'release': kReleaseMode,
      'probe_expect_failure': probeFailure,
      'tests': records,
      if (bindingPassed != null) 'binding_passed': bindingPassed,
      if (bindingResults != null) 'binding_results': bindingResults,
      if (error != null) 'error': error,
    };
    final json = jsonEncode(output);
    await resultFile.writeAsString('$json\n', flush: true);
    print('PHYSICAL_RUN_RESULT=$json');
  }

  try {
    await write('running');
    if (safeId == 'invalid' && runId != 'invalid') {
      throw ArgumentError(
          'PHYSICAL_RUN must contain 1–48 alphanumeric, underscore or hyphen characters');
    }
    if (probeFailure && suiteName != 'probe') {
      throw ArgumentError('PROBE_EXPECT_FAILURE is only permitted for probe');
    }
    final runSuite = <String, void Function()>{
      'probe': probe,
      'ui': ui.main,
      'storage': storage.main,
      'qhtp': qhtp.main,
      'ble': ble.main,
      'internet_sender': internet_sender.main,
      'internet_receiver': internet_receiver.main,
      'ui_pair': ui_pair.main,
    }[suiteName];
    if (runSuite == null) {
      throw ArgumentError('Unknown PHYSICAL_SUITE: $suiteName');
    }
    final declarer = Declarer();
    final flutterFailures = <String, List<String>>{};
    late IntegrationTestWidgetsFlutterBinding binding;
    declarer.declare(() {
      binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
      final previousReporter = reportTestException;
      reportTestException = (details, description) {
        final stack = details.stack;
        flutterFailures.putIfAbsent(description, () => []).add(
            '${details.exceptionAsString()}${stack == null ? '' : '\n$stack'}');
        previousReporter(details, description);
      };
      runSuite();
    });
    final root = declarer.build();
    final suite = Suite(root, SuitePlatform(Runtime.vm));
    Future<bool> runLive(LiveTest live, {required bool isTest}) async {
      // test_api intercepts print in its own zone and does not forward it to
      // the outer zone. Subscribe before starting so progress and connection
      // markers are available to the device controller while the test runs.
      final messages = live.onMessage.listen((message) => print(message.text));
      try {
        await live.run();
        await Future<void>.delayed(Duration.zero);
      } finally {
        await messages.cancel();
      }
      final state = live.state;
      final errors = [
        for (final e in live.errors) '${e.error}\n${e.stackTrace}'
      ];
      final flutterErrors = isTest
          ? (flutterFailures[live.test.name] ?? const <String>[])
          : const <String>[];
      final bindingFailure =
          isTest && binding.results[live.test.name] is Failure;
      errors.addAll(flutterErrors);
      final passed = state.status == backend.Status.complete &&
          state.result == backend.Result.success &&
          errors.isEmpty &&
          !bindingFailure;
      records.add({
        'name': live.test.name,
        'kind': isTest ? 'test' : 'fixture',
        'status': passed ? state.result.toString() : 'failure',
        'passed': passed,
        if (errors.isNotEmpty) 'errors': errors
      });
      return passed;
    }

    Future<void> walk(Group group, List<Group> parents) async {
      final chain = [...parents, group];
      if (group.metadata.skip) {
        records.add({
          'name': group.name,
          'kind': 'group',
          'status': 'skipped',
          'passed': false
        });
        return;
      }
      var ready = true;
      if (group.setUpAll != null) {
        ready = await runLive(group.setUpAll!.load(suite, groups: chain),
            isTest: false);
      }
      if (ready) {
        for (final entry in group.entries) {
          if (entry is Group) {
            await walk(entry, chain);
          } else if (entry is backend.Test) {
            if (entry.metadata.skip) {
              records.add({
                'name': entry.name,
                'kind': 'test',
                'status': 'skipped',
                'passed': false
              });
            } else {
              await runLive(entry.load(suite, groups: chain), isTest: true);
            }
          }
        }
      }
      if (group.tearDownAll != null) {
        await runLive(group.tearDownAll!.load(suite, groups: chain),
            isTest: false);
      }
    }

    await walk(root, []);
    final bindingPassed = await binding.allTestsPassed.future
        .timeout(const Duration(seconds: 20));
    final bindingResults = <String, Object?>{
      for (final e in binding.results.entries)
        e.key: flutterFailures.containsKey(e.key)
            ? flutterFailures[e.key]!.join('\n')
            : e.value is Failure
                ? (e.value as Failure).details
                : e.value.toString(),
    };
    final tests = records.where((r) => r['kind'] == 'test').toList();
    final passed = tests.isNotEmpty &&
        records.every((r) => r['passed'] == true) &&
        bindingPassed;
    await write(passed ? 'passed' : 'failed',
        bindingPassed: bindingPassed, bindingResults: bindingResults);
  } catch (error, stack) {
    await write('error', error: '$error\n$stack');
  }
}
