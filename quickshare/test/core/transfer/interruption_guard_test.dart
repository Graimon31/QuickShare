// Backgrounding an app mid-transfer is not a mistake and not rare: a message
// arrives, a password needs copying, the screen locks itself. iOS suspends the
// process and the open socket dies with it, so the transfer reports a failure
// that has nothing to do with the network. What it needs is a judgement about
// the person — did they come back? — and that is what this makes.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/transfer/interruption_guard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TransferInterruptionGuard guard;

  setUp(() {
    guard = TransferInterruptionGuard(grace: const Duration(milliseconds: 200));
    guard.attach();
  });

  tearDown(() => guard.detach());

  void lifecycle(AppLifecycleState state) =>
      guard.didChangeAppLifecycleState(state);

  test('an untouched transfer is never treated as interrupted', () async {
    expect(guard.wasInterrupted, isFalse);
    expect(await guard.awaitVerdict(), equals(ResumeVerdict.resume));
  });

  test('coming back inside the window resumes', () async {
    lifecycle(AppLifecycleState.paused);
    expect(guard.wasInterrupted, isTrue);
    expect(guard.isWaitingForReturn, isTrue);

    final verdict = guard.awaitVerdict();
    lifecycle(AppLifecycleState.resumed);

    expect(await verdict, equals(ResumeVerdict.resume));
    expect(guard.wasInterrupted, isFalse,
        reason: 'the interruption is spent once it has been answered');
  });

  test('staying away past the window gives up', () async {
    lifecycle(AppLifecycleState.paused);
    expect(await guard.awaitVerdict(), equals(ResumeVerdict.giveUp));
  });

  test('a glance at a notification is not an interruption', () async {
    // `inactive` is a banner, a call, the app switcher. Acting on it would
    // abandon a transfer every time the user looks up.
    lifecycle(AppLifecycleState.inactive);
    expect(guard.wasInterrupted, isFalse);
    expect(guard.isWaitingForReturn, isFalse);
  });

  test('the process going away is not something to wait out', () async {
    lifecycle(AppLifecycleState.paused);
    final verdict = guard.awaitVerdict();
    lifecycle(AppLifecycleState.detached);
    expect(await verdict, equals(ResumeVerdict.giveUp));
  });

  test('leaving twice restarts the window rather than shortening it',
      () async {
    lifecycle(AppLifecycleState.paused);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    lifecycle(AppLifecycleState.paused);

    // Had the first timer survived, this would already have expired.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(guard.isWaitingForReturn, isTrue);
  });

  test('a transfer starting over forgets the last interruption', () async {
    lifecycle(AppLifecycleState.paused);
    guard.reset();
    expect(guard.wasInterrupted, isFalse);
    expect(await guard.awaitVerdict(), equals(ResumeVerdict.resume));
  });
}
