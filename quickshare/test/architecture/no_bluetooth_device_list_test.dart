// Devices are not listed.
//
// A sender is joined by its QR code or its code and by nothing else: no device
// shows up on another device's screen, and no receiver advertises itself to be
// picked. The Bluetooth waiting list was that, built three ways — the receiver
// advertised, the sender scanned and listed what it saw, the person picked a
// row — and it was removed on purpose.
//
// This is a source check, and a blunt one: the names below are the pieces of
// that list. If one comes back, so has the list, and the person who brings it
// back should be reading this comment first.
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/l10n/gen/app_localizations.dart';

/// The names of the pieces of the waiting list. Matched as plain text.
const _removed = <String>[
  // What the owner's decision names.
  'startWaitingAdvertisement',
  'BluetoothReceiverAnnouncer',
  'BleWaitingPeer',
  'SendToWaitingReceiver',
  'BluetoothReceivePage',
  '/receive/bluetooth',
  'startReceiverAdvertising',
  // The rest of the same path: the event a received serve frame became, the
  // announcement a sender turned into a row, and the sender's way of
  // connecting to the row that was picked.
  'BluetoothServeReceived',
  'BluetoothReceiverAnnounced',
  'waitingReceivers',
  'connectToReceiver',
];

Iterable<File> _files(String root, bool Function(String path) wanted) sync* {
  final dir = Directory(root);
  if (!dir.existsSync()) return;
  for (final f in dir.listSync(recursive: true, followLinks: false)) {
    if (f is File && wanted(f.path)) yield f;
  }
}

void main() {
  test('the sources under lib/ carry no piece of the waiting list', () {
    final dart = _files('lib', (p) => p.endsWith('.dart')).toList();
    expect(dart, isNotEmpty, reason: 'found no sources — the scan broke');

    final hits = <String>[];
    for (final file in dart) {
      final text = file.readAsStringSync();
      for (final name in _removed) {
        if (text.contains(name)) hits.add('${file.path}: $name');
      }
    }
    expect(hits, isEmpty, reason: 'the removed list is back:\n${hits.join('\n')}');
  });

  test('the files that were the list are gone', () {
    for (final path in [
      'lib/features/receiver/data/transports/bluetooth_receiver_announcer.dart',
      'lib/features/receiver/presentation/pages/bluetooth_receive_page.dart',
    ]) {
      expect(File(path).existsSync(), isFalse, reason: path);
    }
  });

  test('the Apple bridges no longer offer to advertise as a receiver', () {
    final swift = [
      ..._files('ios/Runner', (p) => p.endsWith('.swift')),
      ..._files('macos/Runner', (p) => p.endsWith('.swift')),
    ];
    expect(swift, isNotEmpty, reason: 'found no Swift sources — the scan broke');

    final hits = <String>[];
    for (final file in swift) {
      final text = file.readAsStringSync();
      for (final name in const ['startReceiverAdvertising', 'waitingAsReceiver']) {
        if (text.contains(name)) hits.add('${file.path}: $name');
      }
    }
    expect(hits, isEmpty, reason: hits.join('\n'));
  });

  test('no string exists only to describe the list', () {
    const keys = [
      'nearbyTitle',
      'nearbyReady',
      'nearbyOrPaste',
      'btReceiveTitle',
      'btReceiveLookingNearby',
      'btReceiveLookingQr',
      'btReceiveScanning',
      'btReceiveScanningDetail',
      'btReceiveConnecting',
      'btReceivePairingWith',
      'btReceiveConnectionFailed',
      'btReceiveScanAgain',
      'btReceiveCodePrompt',
      'btReceiveCodeInvalid',
      'btReceiveWaitingToBeChosen',
      'btReceiveWaitingDetail',
      'btReceiveDirectLinkPlaceholder',
      'btReceiveLookingForLink',
      'qrScanBluetoothReceive',
      'codeNotFound',
      'codeHint',
    ];
    final arbs = _files('lib/l10n', (p) => p.endsWith('.arb')).toList();
    expect(arbs, hasLength(2), reason: 'expected the English and Russian files');

    final hits = <String>[];
    for (final file in arbs) {
      final text = file.readAsStringSync();
      for (final key in keys) {
        if (text.contains('"$key"') || text.contains('"@$key"')) {
          hits.add('${file.path}: $key');
        }
      }
    }
    expect(hits, isEmpty, reason: hits.join('\n'));
  });

  group('what the Bluetooth entry and screen say', () {
    // Words that promise a search or a list, in the two languages the app has.
    final promises = RegExp(
      r'list|nearby|discover|search|find|look|pick a|choose a|'
      r'списк|рядом|поиск|ищ|видим|выберите устройств',
      caseSensitive: false,
    );

    for (final code in ['en', 'ru']) {
      test('in $code they do not promise to find or list devices', () async {
        final l10n = await AppLocalizations.delegate.load(Locale(code));
        final shown = {
          // What the home screen says under the Bluetooth-started option, and
          // the title the file screen wears when it was chosen.
          'homeAirdropAltSubtitle': l10n.homeAirdropAltSubtitle,
          'homeAirdropAltTitle': l10n.homeAirdropAltTitle(l10n.homeAirdropTitle),
          'btSendPreparingDetail': l10n.btSendPreparingDetail,
          'btSendScanPrompt': l10n.btSendScanPrompt,
          'btSendAutoConnectNote': l10n.btSendAutoConnectNote,
        };
        for (final e in shown.entries) {
          expect(promises.hasMatch(e.value), isFalse,
              reason: '${e.key} in $code: "${e.value}"');
        }
      });

      test('in $code they say that a phone receives and a computer does not',
          () async {
        final l10n = await AppLocalizations.delegate.load(Locale(code));
        final note = l10n.btSendAutoConnectNote.toLowerCase();
        final phone = code == 'en' ? 'phone' : 'телефон';
        final computer = code == 'en' ? 'computer' : 'компьютер';
        expect(note, contains(phone));
        expect(note, contains(computer));
        expect(l10n.homeAirdropAltSubtitle.toLowerCase(), contains(phone));
      });
    }
  });
}
