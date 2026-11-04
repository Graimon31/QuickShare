// Devices do not see each other.
//
// A connection happens through a QR code or a digit code, and through nothing
// else. There was a second way once — every device announced its name on the
// local network, listed the others, and could push a plaintext invitation to
// one it picked — and it is gone. This file is the tripwire that notices if
// any part of it comes back.
//
// It reads the source, which is blunt but exact: the things asserted absent
// are class names and a port number, and a reintroduction would have to use
// them.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Iterable<File> _dartFiles(String root) sync* {
  final dir = Directory(root);
  if (!dir.existsSync()) return;
  for (final e in dir.listSync(recursive: true)) {
    if (e is File &&
        e.path.endsWith('.dart') &&
        !e.path.contains('/l10n/gen/')) {
      yield e;
    }
  }
}

/// Source without comments, so that a sentence explaining what is gone does
/// not trip the test that it is gone.
String _code(File f) => f
    .readAsStringSync()
    .split('\n')
    .map((l) => l.trimLeft().startsWith('//') ? '' : l)
    .join('\n');

void main() {
  group('no invitation machinery', () {
    const gone = [
      'InvitationSender',
      'InvitationListener',
      'TransferInvitation',
      'InvitationDialog',
      'showInvitationDialog',
      'InvitationOutcome',
      'AppPresence',
      'DevicePresence',
      'NearbyDevicesPanel',
      'ServingSession',
      'DiscoveredPeer',
      'DiscoveryAnnouncement',
      'LanDiscoveryService',
    ];

    for (final name in gone) {
      test('nothing under lib/ or integration_test/ mentions $name', () {
        final offenders = [
          for (final root in ['lib', 'integration_test'])
            for (final f in _dartFiles(root))
              if (_code(f).contains(name)) f.path,
        ];
        expect(offenders, isEmpty);
      });
    }

    test('the files are gone', () {
      for (final path in [
        'lib/core/transfer/invitation_sender.dart',
        'lib/core/transfer/invitation_listener.dart',
        'lib/core/transfer/transfer_invitation.dart',
        'lib/shared/widgets/invitation_dialog.dart',
        'lib/shared/widgets/nearby_devices_panel.dart',
        'lib/core/network/app_presence.dart',
        'lib/core/network/device_presence.dart',
      ]) {
        expect(File(path).existsSync(), isFalse, reason: path);
      }
    });

    test('the invitation port is bound by nothing and sent to by nothing', () {
      final offenders = [
        for (final root in ['lib', 'integration_test'])
          for (final f in _dartFiles(root))
            if (_code(f).contains('53317')) f.path,
      ];
      expect(offenders, isEmpty);
    });

    test('nothing under lib/ builds a plaintext http:// URL to another device',
        () {
      final plaintext = RegExp(r'''['"]http://\$''');
      final offenders = [
        for (final f in _dartFiles('lib'))
          if (plaintext.hasMatch(_code(f))) f.path,
      ];
      expect(offenders, isEmpty,
          reason: 'every device-to-device request is HTTPS with a pinned '
              'certificate');
    });
  });
}
