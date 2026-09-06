import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/transfer/invitation_listener.dart';
import 'package:quickshare/core/transfer/invitation_sender.dart';
import 'package:quickshare/core/transfer/transfer_invitation.dart';

void main() {
  const invitation = TransferInvitation(
    senderName: "Farman's MacBook",
    senderPlatform: 'macos',
    itemCount: 3,
    totalBytes: 12345678,
    port: 8000,
    sessionId: 'session-1',
    token: 'the-session-token',
    tlsFingerprint: 'the-fingerprint',
  );

  final loopback = InternetAddress.loopbackIPv4;

  group('the handshake, end to end over a real socket', () {
    late InvitationListener listener;

    tearDown(() async => listener.stop());

    test('a yes carries everything needed to fetch the files', () async {
      TransferInvitation? seen;
      listener = InvitationListener(onInvitation: (i) async {
        seen = i;
        return true;
      });
      final port = await listener.start();

      final result = await InvitationSender().invite(
        address: loopback,
        port: port,
        invitation: invitation,
      );

      expect(result.accepted, isTrue);
      // The invitation is the private half of discovery: the announcement
      // cannot carry these, because everyone on the network reads it.
      expect(seen!.token, equals('the-session-token'));
      expect(seen!.port, equals(8000));
      expect(seen!.tlsFingerprint, equals('the-fingerprint'));
      expect(seen!.senderName, equals("Farman's MacBook"));
    });

    test('a no is a no, not an error', () async {
      listener = InvitationListener(onInvitation: (_) async => false);
      final port = await listener.start();

      final result = await InvitationSender().invite(
        address: loopback,
        port: port,
        invitation: invitation,
      );

      expect(result.outcome, equals(InvitationOutcome.declined));
    });

    test('the person is told what they are agreeing to', () async {
      // Somebody offered 40 GB should get to know before they say yes.
      TransferInvitation? seen;
      listener = InvitationListener(onInvitation: (i) async {
        seen = i;
        return true;
      });
      final port = await listener.start();

      await InvitationSender()
          .invite(address: loopback, port: port, invitation: invitation);

      expect(seen!.itemCount, equals(3));
      expect(seen!.totalBytes, equals(12345678));
    });

    test('a second sender is told to wait, not queued behind a dialog',
        () async {
      // Two prompts nobody can see is worse than one honest refusal.
      final firstPromptShown = Completer<void>();
      final release = Completer<bool>();
      listener = InvitationListener(onInvitation: (_) async {
        if (!firstPromptShown.isCompleted) firstPromptShown.complete();
        return release.future;
      });
      final port = await listener.start();

      final first = InvitationSender()
          .invite(address: loopback, port: port, invitation: invitation);
      await firstPromptShown.future;

      final second = await InvitationSender()
          .invite(address: loopback, port: port, invitation: invitation);
      expect(second.outcome, equals(InvitationOutcome.busy));

      release.complete(true);
      expect((await first).accepted, isTrue);
    });

    test('junk on the port is refused without disturbing anyone', () async {
      var prompted = false;
      listener = InvitationListener(onInvitation: (_) async {
        prompted = true;
        return true;
      });
      final port = await listener.start();

      final client = HttpClient();
      final request = await client
          .postUrl(Uri.parse('http://${loopback.address}:$port/invite'));
      request.write('not an invitation at all');
      final response = await request.close();
      client.close();

      expect(response.statusCode, equals(400));
      expect(prompted, isFalse,
          reason: 'anyone can reach this port; junk must not raise a dialog');
    });
  });

  group('when nothing is listening', () {
    test('an unreachable device is not reported as a refusal', () async {
      // Telling somebody their friend declined when the machine was asleep is
      // worse than saying nothing.
      final result = await InvitationSender().invite(
        address: loopback,
        // Nothing is bound here; the OS refuses the connection immediately.
        port: 1,
        invitation: invitation,
      );

      expect(result.outcome, equals(InvitationOutcome.unreachable));
      expect(result.accepted, isFalse);
    });
  });

  group('silence', () {
    test('an ignored dialog declines rather than starting a transfer',
        () async {
      // The safe direction, and the one worth a real test: a transfer nobody
      // agreed to must not begin because the prompt was left on screen. The
      // window is injectable so this takes milliseconds instead of the 45
      // seconds a person gets.
      final listener = InvitationListener(
        onInvitation: (_) => Completer<bool>().future, // nobody ever answers
        answerWindow: const Duration(milliseconds: 100),
      );
      final port = await listener.start();
      addTearDown(listener.stop);

      final result = await InvitationSender().invite(
        address: loopback,
        port: port,
        invitation: invitation,
      );

      expect(result.accepted, isFalse);
      expect(result.outcome, equals(InvitationOutcome.declined),
          reason: 'silence is a decline, not a network failure');
    });
  });

  group('the wire format', () {
    test('survives a round trip', () {
      final decoded = TransferInvitation.decode(invitation.encode())!;

      expect(decoded.token, equals(invitation.token));
      expect(decoded.sessionId, equals(invitation.sessionId));
      expect(decoded.port, equals(invitation.port));
      expect(decoded.tlsFingerprint, equals(invitation.tlsFingerprint));
      expect(decoded.senderName, equals(invitation.senderName));
      expect(decoded.senderPlatform, equals(invitation.senderPlatform));
    });

    test('an invitation missing what it takes to fetch is refused', () {
      // Accepting one of these would put a dialog in front of somebody for a
      // transfer that cannot happen.
      String without(String key) {
        final json = invitation.toJson()..remove(key);
        return json.entries
            .map((e) => '"${e.key}":${e.value is String ? '"${e.value}"' : e.value}')
            .join(',')
            .let((body) => '{$body}');
      }

      for (final key in ['token', 'sid', 'tf', 'port', 'name']) {
        expect(TransferInvitation.decode(without(key)), isNull,
            reason: 'an invitation without "$key" cannot be acted on');
      }
    });

    test('a future version is ignored rather than guessed at', () {
      expect(
        TransferInvitation.decode('{"v":99,"name":"x","token":"y"}'),
        isNull,
      );
    });

    test('nonsense sizes show as unknown rather than refusing the offer', () {
      // The sizes are for the dialog, not for the transfer.
      final json = invitation.toJson()
        ..['items'] = -5
        ..['bytes'] = 'lots';
      final decoded = TransferInvitation.decode(
          json.entries.map((e) {
            final value = e.value is String ? '"${e.value}"' : e.value;
            return '"${e.key}":$value';
          }).join(',').let((body) => '{$body}'));

      expect(decoded, isNotNull);
      expect(decoded!.itemCount, isZero);
      expect(decoded.totalBytes, isZero);
    });
  });
}

extension<T> on T {
  R let<R>(R Function(T) transform) => transform(this);
}
