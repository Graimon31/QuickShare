import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/network/device_presence.dart';
import 'package:quickshare/core/network/lan_discovery.dart';
import 'package:quickshare/core/transfer/invitation_listener.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';
import 'package:quickshare/shared/widgets/nearby_devices_panel.dart';

/// A presence that answers whatever the test wants, without a socket.
class _StubPresence extends DevicePresence {
  _StubPresence({this.announces = true});

  final bool announces;
  final _controller = StreamController<List<DiscoveredPeer>>.broadcast();
  List<DiscoveredPeer> _peers = const [];

  @override
  Stream<List<DiscoveredPeer>> get peers => _controller.stream;

  @override
  List<DiscoveredPeer> get current => _peers;

  @override
  Future<bool> start({String? name, InvitationPrompt? onInvitation}) async =>
      announces;

  @override
  Future<void> dispose() async {
    await _controller.close();
  }

  void emit(List<DiscoveredPeer> peers) {
    _peers = peers;
    _controller.add(peers);
  }
}

DiscoveredPeer peer({
  String id = 'a',
  String name = 'Bob Desktop',
  String platform = 'windows',
  int port = 0,
}) =>
    DiscoveredPeer(
      id: id,
      name: name,
      platform: platform,
      address: InternetAddress('192.168.1.42'),
      port: port,
      lastSeen: DateTime.now(),
    );

void main() {
  Future<void> pump(
    WidgetTester tester,
    _StubPresence presence, {
    void Function(DiscoveredPeer)? onSelected,
    bool servingOnly = false,
  }) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: NearbyDevicesPanel(
          presence: presence,
          servingOnly: servingOnly,
          onSelected: onSelected ?? (_) {},
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('a device that answers becomes a row you can tap', (tester) async {
    final presence = _StubPresence();
    DiscoveredPeer? picked;
    await pump(tester, presence, onSelected: (p) => picked = p);

    presence.emit([peer(name: 'Bob Desktop')]);
    await tester.pump();

    expect(find.text('Bob Desktop'), findsOneWidget);

    await tester.tap(find.text('Bob Desktop'));
    expect(picked?.name, equals('Bob Desktop'));
  });

  testWidgets('an empty network says nobody has answered yet', (tester) async {
    await pump(tester, _StubPresence(announces: true));
    await tester.pump();

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l10n.nearbyEmpty), findsOneWidget);
    expect(find.text(l10n.nearbyBlocked), findsNothing);
  });

  testWidgets('a network that blocks discovery says so instead',
      (tester) async {
    // The distinction the panel exists to make. Telling somebody "no devices"
    // on a network that blocks multicast leaves them waiting for a list that
    // can never fill, with no hint that the code below is the way out.
    await pump(tester, _StubPresence(announces: false));
    await tester.pump();

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l10n.nearbyBlocked), findsOneWidget);
    expect(find.text(l10n.nearbyEmpty), findsNothing);
  });

  testWidgets('a receiving screen hides devices with nothing to send',
      (tester) async {
    // A device that is merely present is a row that cannot be tapped there.
    final presence = _StubPresence();
    await pump(tester, presence, servingOnly: true);

    presence.emit([
      peer(id: 'idle', name: 'Idle Phone'),
      peer(id: 'busy', name: 'Sending Mac', port: 8000),
    ]);
    await tester.pump();

    expect(find.text('Sending Mac'), findsOneWidget);
    expect(find.text('Idle Phone'), findsNothing);
  });

  testWidgets('a sending screen lists everyone, serving or not',
      (tester) async {
    final presence = _StubPresence();
    await pump(tester, presence);

    presence.emit([
      peer(id: 'idle', name: 'Idle Phone'),
      peer(id: 'busy', name: 'Sending Mac', port: 8000),
    ]);
    await tester.pump();

    expect(find.text('Idle Phone'), findsOneWidget);
    expect(find.text('Sending Mac'), findsOneWidget);
  });

  testWidgets('a device that leaves stops being listed', (tester) async {
    final presence = _StubPresence();
    await pump(tester, presence);

    presence.emit([peer(name: 'Bob Desktop')]);
    await tester.pump();
    expect(find.text('Bob Desktop'), findsOneWidget);

    presence.emit(const []);
    await tester.pump();
    expect(find.text('Bob Desktop'), findsNothing);
  });

  testWidgets('the panel stops announcing when it leaves the screen',
      (tester) async {
    // Otherwise a socket and a two-second timer outlive every screen that ever
    // showed the list.
    final presence = _StubPresence();
    await pump(tester, presence);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();

    expect(() => presence.emit([peer()]), throwsStateError,
        reason: 'the stream is closed once the panel is disposed');
  });
}
