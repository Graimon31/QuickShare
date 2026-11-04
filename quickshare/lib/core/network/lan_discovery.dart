import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:nsd/nsd.dart' as nsd;

import 'package:quickshare/core/utils/app_logger.dart';

/// How a receiver who was handed a ten-digit code finds the device offering it.
///
/// This is the only thing mDNS is used for, and it is deliberately small.
/// There is no list of devices: a device that is not showing an offer says
/// nothing on the network at all, receivers never say anything, and what a
/// sender says while its offer is on screen is a random name, a port and one
/// byte of the code's hash — enough for a receiver who already has the code to
/// skip most of the machines in range, and nothing that identifies a person,
/// a machine or a session.
///
/// Neither a hint that matches nor one that does not proves anything about the
/// device that announced it. The code itself is proved to the device it is
/// dialled on, over that device's own certificate (see `CodeSessionResolver`).
///
/// A Bonjour browser on the same network can still see that *an* anonymous
/// DirectDrop offer exists. It cannot see whose, what, or how to join it.
///
/// DNS-SD goes through each platform's own responder rather than a multicast
/// socket of our own: since iOS 14 an app may not send or receive arbitrary
/// multicast without an entitlement Apple does not give to free accounts, and
/// a raw socket there fails with "No route to host" on every send.
const String rendezvousServiceType = '_directdrop._tcp';

/// What one offer says on the network, as DNS-SD records.
///
/// Three TXT values, all of which the resolver needs and none of which says
/// anything about who is offering: the protocol version, the port to dial, and
/// the hint. The instance name is random and changes with every rotation, so a
/// record cannot be followed from one code to the next either.
class RendezvousRecord {
  /// Bumped when a receiver must refuse what this build says.
  static const int version = 1;

  /// A random token. Never the device name, never derived from the code.
  final String instanceName;

  /// The port the QHTP server answers on. Also the SRV record's port.
  final int port;

  /// [SessionCode.discoveryHint]: one byte of the code's hash.
  final String hint;

  const RendezvousRecord({
    required this.instanceName,
    required this.port,
    required this.hint,
  });

  factory RendezvousRecord.forOffer({
    required int port,
    required String hint,
    Random? random,
  }) {
    final source = random ?? Random.secure();
    final token = List.generate(6, (_) => source.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return RendezvousRecord(instanceName: 'dd-$token', port: port, hint: hint);
  }

  static Uint8List _bytes(String value) =>
      Uint8List.fromList(utf8.encode(value));

  Map<String, Uint8List?> toTxt() => {
        'v': _bytes('$version'),
        'p': _bytes('$port'),
        'ch': _bytes(hint),
      };

  nsd.Service toService(String type) =>
      nsd.Service(name: instanceName, type: type, port: port, txt: toTxt());
}

/// Says that an offer exists, for as long as it does.
abstract class RendezvousAdvertiser {
  /// Puts the offer on the air under a fresh random name, withdrawing whatever
  /// was there before. Called when an offer appears and on every rotation.
  Future<void> advertise({required int port, required String hint});

  /// Withdraws it. Safe to call when nothing is on the air.
  Future<void> stop();
}

/// [RendezvousAdvertiser] over the platform's DNS-SD responder.
///
/// Best effort, in the one way that matters: a network that carries no mDNS —
/// guest Wi-Fi, a captive portal, client isolation — must not fail an offer,
/// because the QR still works there. Failure is logged and the offer goes on.
class NsdRendezvousAdvertiser implements RendezvousAdvertiser {
  NsdRendezvousAdvertiser({
    String? serviceType,
    Future<nsd.Registration> Function(nsd.Service service)? register,
    Future<void> Function(nsd.Registration registration)? unregister,
    Random? random,
    this.callTimeout = const Duration(seconds: 10),
  })  : _type = serviceType ?? rendezvousServiceType,
        _register = register ?? nsd.register,
        _unregister = unregister ?? nsd.unregister,
        _random = random;

  final String _type;
  final Future<nsd.Registration> Function(nsd.Service) _register;
  final Future<void> Function(nsd.Registration) _unregister;
  final Random? _random;

  /// Registration can sit for a long time while the responder retries under a
  /// new name on each conflict. None of that is worth holding an offer for.
  final Duration callTimeout;

  nsd.Registration? _registration;
  RendezvousRecord? _current;

  /// Calls run one after another, so a rotation that arrives while the last
  /// registration is still being made waits for it instead of racing it.
  Future<void> _tail = Future<void>.value();

  /// What is on the air now, or null.
  RendezvousRecord? get current => _current;

  @override
  Future<void> advertise({required int port, required String hint}) =>
      _enqueue(() async {
        await _withdraw();
        final record = RendezvousRecord.forOffer(
            port: port, hint: hint, random: _random);
        try {
          _registration =
              await _register(record.toService(_type)).timeout(callTimeout);
          _current = record;
        } catch (e) {
          // The offer is still good over the QR.
          AppLogger.warning(
              'Not announcing this offer for code entry on this network: $e',
              tag: 'DISCOVERY');
        }
      });

  @override
  Future<void> stop() => _enqueue(_withdraw);

  Future<void> _withdraw() async {
    final registration = _registration;
    _registration = null;
    _current = null;
    if (registration == null) return;
    try {
      await _unregister(registration).timeout(callTimeout);
    } catch (_) {
      // Already gone, or the responder went away with the network.
    }
  }

  Future<void> _enqueue(Future<void> Function() op) {
    final next = _tail.then((_) => op());
    _tail = next.catchError((Object _) {});
    return next;
  }
}

/// A sender that announced itself, as heard — and nothing more than that.
///
/// The address is the one the responder resolved, never one the sender wrote
/// into its own record: a device that gets its own address wrong, or lies
/// about it, can only make itself unreachable.
class RendezvousCandidate {
  final InternetAddress address;
  final int port;

  /// What the sender claims about the code on offer. A prefilter only.
  final String hint;

  const RendezvousCandidate({
    required this.address,
    required this.port,
    required this.hint,
  });

  static String? _text(Map<String, Uint8List?>? txt, String key) {
    final value = txt?[key];
    if (value == null || value.isEmpty) return null;
    try {
      return utf8.decode(value);
    } catch (_) {
      // Opaque bytes on Apple platforms, so anything can turn up here.
      return null;
    }
  }

  /// Reads a resolved service, or null if it is not one of ours — an older or
  /// newer build, a half-resolved record, or something else on the same type.
  static RendezvousCandidate? fromService(nsd.Service service) {
    final txt = service.txt;
    if (_text(txt, 'v') != '${RendezvousRecord.version}') return null;

    final port = int.tryParse(_text(txt, 'p') ?? '');
    if (port == null || port <= 0 || port > 65535) return null;

    final hint = _text(txt, 'ch');
    if (hint == null || hint.isEmpty) return null;

    final addresses = service.addresses ?? const <InternetAddress>[];
    final usable = addresses.where((a) => !a.isLoopback).toList();
    if (usable.isEmpty) return null;
    final address = usable.firstWhere(
      (a) => a.type == InternetAddressType.IPv4,
      orElse: () => usable.first,
    );

    return RendezvousCandidate(address: address, port: port, hint: hint);
  }

  @override
  String toString() => 'RendezvousCandidate(${address.address}:$port, $hint)';
}

/// Listens for offers — and only for as long as it is asked to.
///
/// Started when a complete code has been typed, stopped when the search ends.
/// What it hears is handed to the resolver and to nothing else; no screen
/// draws it.
abstract class RendezvousBrowser {
  /// Every change to what has been heard.
  Stream<List<RendezvousCandidate>> get candidates;

  List<RendezvousCandidate> get current;

  bool get isRunning;

  /// Begins browsing. False when the platform would not — the search carries
  /// on without it.
  Future<bool> start();

  /// Reads what the platform has collected so far, now.
  Future<void> refresh();

  Future<void> stop();
}

class NsdRendezvousBrowser implements RendezvousBrowser {
  NsdRendezvousBrowser({
    String? serviceType,
    Future<nsd.Discovery> Function(String type)? startDiscovery,
    Future<void> Function(nsd.Discovery discovery)? stopDiscovery,
    Future<nsd.Service> Function(nsd.Service service)? resolve,
    this.callTimeout = const Duration(seconds: 10),
  })  : _type = serviceType ?? rendezvousServiceType,
        _startDiscovery = startDiscovery ??
            ((type) => nsd.startDiscovery(type,
                autoResolve: true, ipLookupType: nsd.IpLookupType.v4)),
        _stopDiscovery = stopDiscovery ?? nsd.stopDiscovery,
        _resolve = resolve ?? nsd.resolve;

  /// How often to go back over the platform's list. A record can be announced
  /// before its TXT and address are readable, and only a second look catches
  /// it.
  static const Duration reconcileInterval = Duration(seconds: 1);

  final String _type;
  final Future<nsd.Discovery> Function(String) _startDiscovery;
  final Future<void> Function(nsd.Discovery) _stopDiscovery;
  final Future<nsd.Service> Function(nsd.Service) _resolve;
  final Duration callTimeout;

  nsd.Discovery? _discovery;
  Timer? _reconcileTimer;
  bool _reconciling = false;
  bool _stopped = false;

  final Map<String, RendezvousCandidate> _heard = {};
  final StreamController<List<RendezvousCandidate>> _controller =
      StreamController<List<RendezvousCandidate>>.broadcast();

  @override
  Stream<List<RendezvousCandidate>> get candidates => _controller.stream;

  @override
  List<RendezvousCandidate> get current => List.unmodifiable(_heard.values);

  @override
  bool get isRunning => _discovery != null;

  @override
  Future<bool> start() async {
    if (_discovery != null) return true;
    _stopped = false;
    try {
      final discovery = await _startDiscovery(_type).timeout(callTimeout);
      if (_stopped) {
        // Stopped while the platform was still starting: do not leave it
        // browsing for nobody.
        unawaited(_stopDiscovery(discovery).catchError((Object _) {}));
        return false;
      }
      _discovery = discovery;
      discovery.addServiceListener(_onEvent);
      _reconcileTimer =
          Timer.periodic(reconcileInterval, (_) => unawaited(refresh()));
      unawaited(refresh());
      return true;
    } catch (e) {
      AppLogger.warning(
          'Not listening for senders on this network — the search goes on '
          'without it: $e',
          tag: 'DISCOVERY');
      return false;
    }
  }

  void _onEvent(nsd.Service service, nsd.ServiceStatus status) {
    switch (status) {
      case nsd.ServiceStatus.found:
        unawaited(refresh());
      case nsd.ServiceStatus.lost:
        final name = service.name;
        if (name != null && _heard.remove(name) != null) _emit();
    }
  }

  @override
  Future<void> refresh() async {
    final discovery = _discovery;
    if (discovery == null || _reconciling) return;
    _reconciling = true;
    try {
      final services = List<nsd.Service>.of(discovery.services);
      final read = await Future.wait(services.map(_read));
      if (_discovery == null) return;

      var changed = false;
      final seen = <String>{};
      for (var i = 0; i < services.length; i++) {
        final name = services[i].name;
        final candidate = read[i];
        if (name == null) continue;
        seen.add(name);
        if (candidate == null) continue;
        final existing = _heard[name];
        if (existing == null ||
            existing.port != candidate.port ||
            existing.hint != candidate.hint ||
            existing.address != candidate.address) {
          _heard[name] = candidate;
          changed = true;
        }
      }
      for (final name in _heard.keys.toList()) {
        if (!seen.contains(name)) {
          _heard.remove(name);
          changed = true;
        }
      }
      if (changed) _emit();
    } finally {
      _reconciling = false;
    }
  }

  Future<RendezvousCandidate?> _read(nsd.Service service) async {
    var candidate = RendezvousCandidate.fromService(service);
    if (candidate != null) return candidate;
    try {
      var resolved = await _resolve(service).timeout(callTimeout);
      candidate = RendezvousCandidate.fromService(resolved);
      if (candidate != null) return candidate;

      // Apple's responder resolves the record and leaves the address to the
      // host name.
      final host = resolved.host ?? service.host;
      final txt = resolved.txt ?? service.txt;
      if ((resolved.addresses == null || resolved.addresses!.isEmpty) &&
          host != null &&
          host.isNotEmpty) {
        final looked = await InternetAddress.lookup(host,
            type: InternetAddressType.IPv4);
        resolved = nsd.Service(
          name: resolved.name,
          type: resolved.type,
          host: host,
          port: resolved.port ?? service.port,
          txt: txt,
          addresses: looked,
        );
        return RendezvousCandidate.fromService(resolved);
      }
    } catch (_) {
      // Gone again, or the responder is busy; the next pass will look.
    }
    return null;
  }

  void _emit() {
    if (_controller.isClosed) return;
    _controller.add(current);
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    _reconcileTimer?.cancel();
    _reconcileTimer = null;
    final discovery = _discovery;
    _discovery = null;
    _heard.clear();
    if (discovery != null) {
      discovery.removeServiceListener(_onEvent);
      try {
        await _stopDiscovery(discovery).timeout(callTimeout);
      } catch (_) {
        // Nothing left to stop.
      }
    }
    if (!_controller.isClosed) await _controller.close();
  }
}
