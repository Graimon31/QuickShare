// How many times, and for how long, a transfer tries to get its connection
// back. The ledger is pure, so the clock is a variable.
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/webrtc/resume/reconnect_policy.dart';

void main() {
  late DateTime clock;
  DateTime now() => clock;
  setUp(() => clock = DateTime(2026, 11, 7, 12));

  test('three attempts in a row and then it stops, saying why', () {
    final ledger = ReconnectLedger(const ReconnectPolicy(), now: now);
    ledger.lost();
    for (var i = 1; i <= 3; i++) {
      expect(ledger.exhausted, isNull, reason: 'before attempt $i');
      expect(ledger.startAttempt(), i);
    }
    expect(ledger.exhausted, ReconnectGaveUp.attempts);
  });

  test('the budget is the time spent reconnecting, over the whole session',
      () {
    const policy = ReconnectPolicy(totalBudget: Duration(minutes: 1));
    final ledger = ReconnectLedger(policy, now: now);

    ledger.lost();
    clock = clock.add(const Duration(seconds: 40));
    ledger.recovered();
    expect(ledger.exhausted, isNull);

    // Time spent with the link up does not count.
    clock = clock.add(const Duration(minutes: 30));
    expect(ledger.exhausted, isNull);

    ledger.lost();
    clock = clock.add(const Duration(seconds: 19));
    expect(ledger.exhausted, isNull);
    clock = clock.add(const Duration(seconds: 2));
    expect(ledger.exhausted, ReconnectGaveUp.budget);
  });

  test('a recovery that then moves real data gives the attempts back', () {
    final ledger = ReconnectLedger(
        const ReconnectPolicy(progressBytes: 1000),
        now: now);
    ledger.lost();
    ledger.startAttempt();
    ledger.startAttempt();
    ledger.recovered();
    expect(ledger.attemptsInARow, 2);

    ledger.moved(400);
    expect(ledger.attemptsInARow, 2, reason: 'not enough yet');
    ledger.moved(700);
    expect(ledger.attemptsInARow, 0);
  });

  test('a link that drops again before moving anything keeps the count', () {
    final ledger = ReconnectLedger(
        const ReconnectPolicy(progressBytes: 1000),
        now: now);
    ledger.lost();
    ledger.startAttempt();
    ledger.startAttempt();
    ledger.startAttempt();
    ledger.recovered();
    ledger.moved(10);
    ledger.lost();
    expect(ledger.exhausted, ReconnectGaveUp.attempts,
        reason: 'a path that comes up and dies at once is not a recovery');
  });

  test('the number of interruptions is capped however well each is mended',
      () {
    final ledger = ReconnectLedger(
        const ReconnectPolicy(maxInterruptions: 2, progressBytes: 1),
        now: now);
    for (var i = 0; i < 3; i++) {
      ledger.lost();
      ledger.startAttempt();
      ledger.recovered();
      ledger.moved(5);
    }
    ledger.lost();
    expect(ledger.exhausted, ReconnectGaveUp.interruptions);
  });

  test('losing the connection twice without recovering is one interruption',
      () {
    final ledger = ReconnectLedger(const ReconnectPolicy(), now: now);
    ledger.lost();
    ledger.lost();
    expect(ledger.interruptions, 1);
  });

  test('the pause before an attempt grows, and the last one repeats', () {
    const policy = ReconnectPolicy(pauseBetweenAttempts: [
      Duration(seconds: 2),
      Duration(seconds: 5),
    ]);
    expect(policy.pauseBefore(1), Duration.zero);
    expect(policy.pauseBefore(2), const Duration(seconds: 2));
    expect(policy.pauseBefore(3), const Duration(seconds: 5));
    expect(policy.pauseBefore(9), const Duration(seconds: 5));
  });

  test('the defaults are the ones the policy documents', () {
    const stall = StallPolicy();
    expect(stall.sendNoDrain, lessThan(const Duration(seconds: 30)),
        reason: 'the point is to notice sooner than the old 30 s');
    expect(stall.receiveSilence, greaterThan(stall.pingEvery * 3),
        reason: 'a few missed pings are not a dead link');
    expect(stall.suspectAfter, lessThan(stall.receiveSilence));
    const policy = ReconnectPolicy();
    expect(policy.maxAttempts, 3);
    expect(policy.totalBudget, greaterThan(policy.attemptTimeout));
  });
}
