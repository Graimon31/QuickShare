// What a device says on the local network, and when it says it.
//
// There is no list of devices any more. mDNS survives for exactly one job: a
// receiver who was handed a ten-digit code has to find the one device that is
// offering it. So the sender says a very small thing — a random name, a port,
// a one-byte hint — only while an offer is on its screen, and the receiver
// listens only after a whole code has been typed and never draws what it
// hears.
//
// This file pins what goes on the air. The platform responder itself cannot be
// exercised headless; `integration_test/code_rendezvous_device_test.dart` does
// that against the real one.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nsd/nsd.dart' as nsd;

import 'package:quickshare/core/network/lan_discovery.dart';
import 'package:quickshare/core/network/session_code.dart';

/// What the platform responder was asked to do, in order.
class _Responder {
  final List<nsd.Service> registered = [];
  final List<nsd.Registration> unregistered = [];
  final List<String> log = [];
  var _next = 0;

  Future<nsd.Registration> register(nsd.Service service) async {
    registered.add(service);
    log.add('register ${service.name}');
    return nsd.Registration('reg-${_next++}', service);
  }

  Future<void> unregister(nsd.Registration registration) async {
    unregistered.add(registration);
    log.add('unregister ${registration.service.name}');
  }
}

String _printable(nsd.Service s) => [
      s.name,
      s.type,
      '${s.port}',
      ...?s.txt?.entries.map((e) => '${e.key}=${utf8.decode(e.value ?? [])}'),
    ].join('|');

void main() {
  final hint = const SessionCode('1234567890').discoveryHint;

  NsdRendezvousAdvertiser advertiser(_Responder r, {int seed = 1}) =>
      NsdRendezvousAdvertiser(
        register: r.register,
        unregister: r.unregister,
        random: Random(seed),
      );

  group('a device that is not offering anything', () {
    test('has said nothing at all', () {
      final responder = _Responder();
      final adv = advertiser(responder);

      expect(responder.registered, isEmpty);
      expect(adv.current, isNull);
    });

    test('stopping something that never started asks the responder for '
        'nothing', () async {
      final responder = _Responder();
      await advertiser(responder).stop();

      expect(responder.log, isEmpty);
    });
  });

  group('an offer on screen', () {
    test('says a port and a hint, and nothing else', () async {
      final responder = _Responder();
      await advertiser(responder).advertise(port: 8000, hint: hint);

      expect(responder.registered, hasLength(1));
      final service = responder.registered.single;
      expect(service.type, '_directdrop._tcp');
      expect(service.port, 8000);

      final txt = {
        for (final e in service.txt!.entries) e.key: utf8.decode(e.value!),
      };
      expect(txt.keys.toSet(), {'v', 'p', 'ch'},
          reason: 'only what the resolver needs: protocol, port, hint');
      expect(txt['p'], '8000');
      expect(txt['ch'], hint);
    });

    test('never carries the device name, a token, a fingerprint or an address',
        () async {
      final responder = _Responder();
      final host = Platform.localHostname;
      const token = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';
      const fingerprint = 'AB:CD:EF:01:23:45';

      await advertiser(responder)
          .advertise(port: 8000, hint: const SessionCode('1234567890').discoveryHint);

      final everything = _printable(responder.registered.single);
      for (final secret in [host, token, fingerprint, '192.168.', '1234567890']) {
        expect(everything.toLowerCase(), isNot(contains(secret.toLowerCase())),
            reason: 'the advertisement contains "$secret"');
      }
      final keys = responder.registered.single.txt!.keys;
      for (final dropped in ['n', 'os', 'id', 'a', 'cid', 'tf', 'ip']) {
        expect(keys, isNot(contains(dropped)),
            reason: 'TXT key "$dropped" is a name, an address or a secret');
      }
    });

    test('is named at random, and differently each time it is registered',
        () async {
      final responder = _Responder();
      final adv = advertiser(responder);

      await adv.advertise(port: 8000, hint: hint);
      await adv.advertise(port: 8000, hint: hint);
      await adv.advertise(port: 8000, hint: hint);

      final names = responder.registered.map((s) => s.name).toList();
      expect(names.toSet(), hasLength(3), reason: '$names');
      for (final name in names) {
        expect(name, matches(RegExp(r'^[a-z0-9-]{8,40}$')),
            reason: 'an opaque token, nothing a person would recognise');
      }
    });

    test('a rotation replaces the registration: the old one is withdrawn '
        'before the new one goes out', () async {
      final responder = _Responder();
      final adv = advertiser(responder);

      await adv.advertise(port: 8000, hint: hint);
      final first = responder.registered.single.name;
      await adv.advertise(port: 8000, hint: '7f');

      expect(responder.log, [
        'register $first',
        'unregister $first',
        'register ${responder.registered.last.name}',
      ]);
      final txt = responder.registered.last.txt!;
      expect(utf8.decode(txt['ch']!), '7f', reason: 'the new hint is on air');
      expect(adv.current!.hint, '7f');
    });
  });

  group('after the offer ends', () {
    test('the registration is withdrawn and nothing remains', () async {
      final responder = _Responder();
      final adv = advertiser(responder);
      await adv.advertise(port: 8000, hint: hint);

      await adv.stop();

      expect(responder.unregistered, hasLength(1));
      expect(adv.current, isNull);
      await adv.stop();
      expect(responder.unregistered, hasLength(1),
          reason: 'withdrawn once, not once per call');
    });

    test('a responder that fails is not a reason to fail the offer', () async {
      final adv = NsdRendezvousAdvertiser(
        register: (_) async => throw StateError('no mDNS here'),
        unregister: (_) async {},
      );

      await adv.advertise(port: 8000, hint: hint);
      await adv.stop();
      expect(adv.current, isNull);
    });
  });

  group('reading what a sender said', () {
    Uint8List bytes(String v) => Uint8List.fromList(utf8.encode(v));

    nsd.Service service({
      Map<String, Uint8List?>? txt,
      List<InternetAddress>? addresses,
    }) =>
        nsd.Service(
          name: 'x1y2z3',
          type: '_directdrop._tcp',
          port: 8000,
          addresses: addresses ?? [InternetAddress('192.168.1.42')],
          txt: txt ??
              {
                'v': bytes('1'),
                'p': bytes('8123'),
                'ch': bytes('4f'),
              },
        );

    test('a candidate is an address, a port and a hint', () {
      final candidate = RendezvousCandidate.fromService(service());

      expect(candidate, isNotNull);
      expect(candidate!.address.address, '192.168.1.42');
      expect(candidate.port, 8123);
      expect(candidate.hint, '4f');
    });

    test('the address is the one the responder resolved, not one the sender '
        'claims', () {
      final txt = {
        'v': bytes('1'),
        'p': bytes('8123'),
        'ch': bytes('4f'),
        'a': bytes('10.9.9.9'),
      };
      final candidate = RendezvousCandidate.fromService(service(txt: txt));

      expect(candidate!.address.address, '192.168.1.42');
    });

    test('something that is not ours, or not finished resolving, is nothing',
        () {
      expect(
          RendezvousCandidate.fromService(
              service(txt: {'v': bytes('9'), 'p': bytes('1'), 'ch': bytes('4f')})),
          isNull);
      expect(RendezvousCandidate.fromService(service(txt: {})), isNull);
      expect(
          RendezvousCandidate.fromService(
              service(txt: {'v': bytes('1'), 'ch': bytes('4f')})),
          isNull,
          reason: 'no port: nothing to dial');
      expect(RendezvousCandidate.fromService(service(addresses: [])), isNull);
      expect(
          RendezvousCandidate.fromService(
              service(addresses: [InternetAddress.loopbackIPv4])),
          isNull,
          reason: 'a loopback address is this machine, not a sender');
    });
  });

  group('a receiver', () {
    test('has not started listening until it is told to', () {
      var browses = 0;
      final browser = NsdRendezvousBrowser(
        startDiscovery: (type) async {
          browses++;
          throw StateError('not under test');
        },
      );

      expect(browser.isRunning, isFalse);
      expect(browser.current, isEmpty);
      expect(browses, 0);
    });
  });
}
