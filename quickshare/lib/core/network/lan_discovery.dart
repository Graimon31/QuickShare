import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nsd/nsd.dart' as nsd;

import 'package:quickshare/core/utils/app_logger.dart';

/// A device that has announced itself on this network, as last heard.
///
/// The address comes from the resolved mDNS record rather than from anything
/// the device claims about itself in a payload: a device that gets its own
/// address wrong then simply cannot be reached, instead of poisoning the list
/// with an address belonging to somebody else.
class DiscoveredPeer {
  /// Stable for as long as the far side keeps announcing, so a device heard
  /// twice is one row rather than two.
  final String id;

  /// What to show in the list. Chosen by the far side; treated as display text
  /// and nothing else.
  final String name;

  /// 'ios', 'android', 'macos', 'windows', 'linux' — or anything else a future
  /// build sends. Only ever used to pick an icon, so an unknown value is not
  /// an error.
  final String platform;

  final InternetAddress address;

  /// The QHTP port this peer serves on, or 0 when it is only present rather
  /// than offering a session.
  final int port;

  /// Certificate fingerprint to pin, when this peer is already serving. Empty
  /// for an idle peer, which has no server and therefore no certificate yet.
  final String tlsFingerprint;

  /// Where to send this peer an invitation, or 0 when it is not accepting
  /// them.
  ///
  /// Separate from [port], which is where its own files are served from: a
  /// device can be ready to receive without offering anything, and usually is.
  final int invitePort;

  /// Identifies the session this peer is offering, for somebody who was told
  /// its code. Empty when the peer is not offering one.
  ///
  /// Derived from the code and not reversible: it lets a receiver who has the
  /// code pick the right sender out of several, without telling everyone else
  /// in range what the code is.
  final String sessionPublicId;

  const DiscoveredPeer({
    required this.id,
    required this.name,
    required this.platform,
    required this.address,
    required this.port,
    this.tlsFingerprint = '',
    this.invitePort = 0,
    this.sessionPublicId = '',
  });

  /// Whether this peer is offering a session right now, as opposed to merely
  /// being present.
  bool get isServing => port > 0;

  /// Whether this peer can be asked to accept a transfer.
  bool get acceptsInvitations => invitePort > 0;

  @override
  String toString() =>
      'DiscoveredPeer($name, $platform, ${address.address}:$port)';
}

/// What one device publishes about itself, as DNS-SD TXT records.
///
/// Deliberately small. Every value travels in a TXT record, which has a
/// practical ceiling of a few hundred bytes, and anything not needed to *draw
/// a row and open a socket* belongs in the session itself, behind the token.
class DiscoveryAnnouncement {
  static const int version = 1;

  final String id;
  final String name;
  final String platform;
  final int port;
  final String tlsFingerprint;
  final int invitePort;

  /// The public half of this session's code — see
  /// [DiscoveredPeer.sessionPublicId]. Empty when nothing is on offer.
  final String sessionPublicId;

  const DiscoveryAnnouncement({
    required this.id,
    required this.name,
    required this.platform,
    this.port = 0,
    this.tlsFingerprint = '',
    this.invitePort = 0,
    this.sessionPublicId = '',
  });

  static Uint8List _bytes(String value) =>
      Uint8List.fromList(utf8.encode(value));

  /// The TXT records this device advertises.
  ///
  /// Keys are kept to the short forms DNS-SD prefers — the specification
  /// suggests nine characters or fewer, and a record repeated by every device
  /// on the network several times a minute is not the place to spell things
  /// out.
  Map<String, Uint8List?> toTxt() => {
        'v': _bytes('$version'),
        'id': _bytes(id),
        'n': _bytes(name),
        'os': _bytes(platform),
        if (port > 0) 'p': _bytes('$port'),
        if (tlsFingerprint.isNotEmpty) 'tf': _bytes(tlsFingerprint),
        if (invitePort > 0) 'ip': _bytes('$invitePort'),
        if (sessionPublicId.isNotEmpty) 'cid': _bytes(sessionPublicId),
      };

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

  static int _number(Map<String, Uint8List?>? txt, String key) {
    final raw = _text(txt, key);
    final parsed = raw == null ? null : int.tryParse(raw);
    if (parsed == null || parsed <= 0 || parsed > 65535) return 0;
    return parsed;
  }

  /// Reads a resolved service, or returns null if it is not one of ours.
  ///
  /// Null rather than throwing: the same service type can be answered by an
  /// older build, a half-resolved record, or something else entirely, and none
  /// of those are worth unwinding the stack for.
  static DiscoveredPeer? peerFrom(nsd.Service service) {
    final txt = service.txt;
    if (_text(txt, 'v') != '$version') return null;

    final id = _text(txt, 'id');
    final name = _text(txt, 'n');
    final platform = _text(txt, 'os');
    if (id == null || id.isEmpty) return null;
    if (name == null || name.isEmpty) return null;
    if (platform == null || platform.isEmpty) return null;

    // Without an address there is nothing to connect to, however well-formed
    // the rest of the record is. `firstWhere` with a fallback is not enough
    // here: an empty list makes the fallback itself throw, and a resolve that
    // came back with no addresses at all is an ordinary event rather than an
    // error worth unwinding the stack for.
    final addresses = service.addresses;
    if (addresses == null || addresses.isEmpty) return null;
    final address = addresses.firstWhere(
      (a) => a.type == InternetAddressType.IPv4,
      orElse: () => addresses.first,
    );

    return DiscoveredPeer(
      id: id,
      name: name,
      platform: platform,
      address: address,
      port: _number(txt, 'p'),
      tlsFingerprint: _text(txt, 'tf') ?? '',
      invitePort: _number(txt, 'ip'),
      sessionPublicId: _text(txt, 'cid') ?? '',
    );
  }
}

/// Announces this device on the local network and lists the others.
///
/// DNS-SD (Bonjour / mDNS) through each platform's own API, rather than a
/// multicast socket of our own. That choice is forced rather than preferred:
/// since iOS 14 an app may not send or receive arbitrary multicast without
/// `com.apple.developer.networking.multicast`, an entitlement Apple grants by
/// application and does not offer to free accounts at all. A socket bound to a
/// group of our own simply fails there — "No route to host" on every send,
/// which looks exactly like an empty room from the outside.
///
/// mDNS is exempt because it goes through the system responder rather than a
/// raw socket, and it is the same mechanism AirPlay and printers use. It also
/// happens to be a standard, so this interoperates rather than only talking to
/// itself.
///
/// Still best effort: networks that isolate clients — guest Wi-Fi, captive
/// portals — carry no mDNS between devices either, and there the list stays
/// empty however long anyone waits.
class LanDiscoveryService {
  /// The DNS-SD service type. Already declared in `NSBonjourServices` on both
  /// Apple platforms, without which iOS refuses to browse at all.
  static const String serviceType = '_directdrop._tcp';

  /// How long any single call into the platform's responder may take.
  ///
  /// Registration in particular can sit for a long time — the responder
  /// retries under a new name on each conflict, and on a busy network that
  /// adds up. None of that is worth a screen that never finishes loading: a
  /// list that stays empty is a worse outcome than a list that says so, but
  /// both beat a spinner that never stops.
  static const Duration platformCallTimeout = Duration(seconds: 10);

  /// The type actually advertised. Overridable so two test files can run in
  /// parallel without each one's devices turning up in the other's list —
  /// the same isolation a separate multicast group used to give.
  final String type;

  /// Timers behind the timeouts below, so they can be cancelled rather than
  /// left to fire into a service that is already gone.
  ///
  /// `Future.timeout` schedules a timer nobody can reach, which outlives
  /// [stop] and keeps a torn-down screen alive in a widget test — and, less
  /// visibly, in the app.
  final Set<Timer> _pendingTimeouts = {};

  nsd.Registration? _registration;
  nsd.Discovery? _discovery;
  DiscoveryAnnouncement? _self;

  final Map<String, DiscoveredPeer> _peers = {};

  /// Re-reads what the browser has collected, on a timer.
  ///
  /// A service is announced once and resolved once, and the two can race: a
  /// device that appears while we are already browsing is reported the instant
  /// its announcement lands, which is sometimes before its TXT record and
  /// address are available to read. That record parses to nothing, and with
  /// only a one-shot "found" event it would never be looked at again — so the
  /// device that turned up second stayed invisible for as long as the screen
  /// was open, while one that was already there when browsing began appeared
  /// straight away.
  ///
  /// The browser keeps the full list regardless of whether we could read an
  /// entry, so going back over it is enough to catch up.
  Timer? _reconcile;

  /// How often to go back over the browser's list. Fast enough that a device
  /// somebody just opened shows up while they are still looking at the screen.
  static const Duration reconcileInterval = Duration(seconds: 2);
  final StreamController<List<DiscoveredPeer>> _peersController =
      StreamController<List<DiscoveredPeer>>.broadcast();

  LanDiscoveryService({String? serviceType})
      : type = serviceType ?? LanDiscoveryService.serviceType;

  /// Bounds one call into the platform's responder, with a timer this service
  /// can cancel.
  Future<T> _bounded<T>(Future<T> call, String what) {
    final completer = Completer<T>();
    late final Timer timer;
    timer = Timer(platformCallTimeout, () {
      _pendingTimeouts.remove(timer);
      if (!completer.isCompleted) {
        completer.completeError(TimeoutException(what));
      }
    });
    _pendingTimeouts.add(timer);

    call.then((value) {
      timer.cancel();
      _pendingTimeouts.remove(timer);
      if (!completer.isCompleted) completer.complete(value);
    }, onError: (Object error, StackTrace stack) {
      timer.cancel();
      _pendingTimeouts.remove(timer);
      if (!completer.isCompleted) completer.completeError(error, stack);
    });

    return completer.future;
  }

  /// The current list, and every change to it.
  Stream<List<DiscoveredPeer>> get peers => _peersController.stream;

  List<DiscoveredPeer> get current => List.unmodifiable(_peers.values);

  bool get isRunning => _discovery != null;

  /// Starts browsing, and announces [self] until [stop].
  ///
  /// Failure is not fatal to anything: a device that cannot join the local
  /// network still transfers perfectly well over a scanned QR code or a typed
  /// code, so this reports the problem and returns false rather than throwing
  /// into a UI that has a working alternative.
  Future<bool> start(DiscoveryAnnouncement self) async {
    if (_discovery != null) await stop();
    _self = self;

    try {
      _discovery = await _bounded(
        nsd.startDiscovery(
          type,
          // Resolved records carry the TXT payload and the addresses, which is
          // the whole point — an unresolved name cannot be drawn or dialled.
          autoResolve: true,
          ipLookupType: nsd.IpLookupType.v4,
        ),
        'the responder did not start a browse in time',
      );
      _discovery!.addServiceListener(_onServiceEvent);
      _reconcile = Timer.periodic(reconcileInterval, (_) => _reconcileNow());

      await _publish(self);

      AppLogger.info(
          'Announcing as "${self.name}" over $type', tag: 'DISCOVERY');
      return true;
    } catch (e) {
      AppLogger.warning(
          'Local discovery unavailable on this network — the code path still '
          'works: $e',
          tag: 'DISCOVERY');
      await stop();
      return false;
    }
  }

  /// Replaces what this device says about itself — used when a session opens
  /// and the announcement gains a port to dial.
  ///
  /// DNS-SD has no "amend" operation, so this re-publishes. Kept off the
  /// caller's mind because the alternative is every call site knowing that.
  Future<void> update(DiscoveryAnnouncement self) async {
    _self = self;
    if (_discovery == null) return;
    await _publish(self);
  }

  Future<void> _publish(DiscoveryAnnouncement self) async {
    await _unpublish();

    // DNS-SD requires a port, and it is the one a peer would actually dial:
    // the invitation port when this device accepts transfers, the QHTP port
    // when it is serving one, and otherwise a placeholder that says "present,
    // nothing to open". The TXT records carry both explicitly, so nothing has
    // to infer which case this is from the port alone.
    final advertisedPort = self.invitePort > 0
        ? self.invitePort
        : (self.port > 0 ? self.port : 1);

    try {
      _registration = await _bounded(
        nsd.register(
          nsd.Service(
            name: self.name,
            type: type,
            port: advertisedPort,
            txt: self.toTxt(),
          ),
        ),
        'the responder did not publish in time',
      );
    } catch (e) {
      // Browsing without being listed is still useful: this device can see
      // others and send to them, it just cannot be sent to.
      AppLogger.warning('Not listed on this network: $e', tag: 'DISCOVERY');
    }
  }

  Future<void> _unpublish() async {
    final registration = _registration;
    _registration = null;
    if (registration == null) return;
    try {
      await _bounded(nsd.unregister(registration), 'unregister timed out');
    } catch (_) {
      // Already gone, or the responder went away with the network.
    }
  }

  void _onServiceEvent(nsd.Service service, nsd.ServiceStatus status) {
    final peer = DiscoveryAnnouncement.peerFrom(service);
    if (peer == null) {
      // Not ours, or not readable yet. The second case is the interesting one
      // and is why [_reconcile] exists — it will be re-read there once the
      // record fills in.
      return;
    }

    // Our own registration comes back through the browser like any other.
    // Listing this device on a screen that means "devices near you" is
    // nonsense.
    if (peer.id == _self?.id) return;

    switch (status) {
      case nsd.ServiceStatus.found:
        _peers[peer.id] = peer;
      case nsd.ServiceStatus.lost:
        _peers.remove(peer.id);
    }
    _emit();
  }

  /// True while a pass is in flight, so a responder slower than
  /// [reconcileInterval] cannot queue ticks up behind itself.
  bool _reconciling = false;

  /// Goes back over everything the browser has, re-reading each record.
  ///
  /// Re-reading is the point, not an optimisation to skip. A device's TXT is
  /// what says whether it is offering a session, and changing it produces no
  /// browse event at all — `autoResolve` fires once, when the name first
  /// appears, and never again. So a device seen while it was idle stayed idle
  /// in this list for as long as it was on screen: the sender opened a
  /// session, published a port and a session id, and the receiver went on
  /// showing "waiting" and matching a typed code against nothing.
  ///
  /// The resolves go out together rather than one after another, so a pass
  /// costs one round trip however many devices are on the network.
  Future<void> _reconcileNow() async {
    final discovery = _discovery;
    if (discovery == null) return;
    if (_reconciling) return;
    _reconciling = true;
    try {
      await _reconcilePass(discovery);
    } finally {
      _reconciling = false;
    }
  }

  Future<void> _reconcilePass(nsd.Discovery discovery) async {
    var changed = false;
    final seen = <String>{};

    final services = List<nsd.Service>.of(discovery.services);
    final resolved = await Future.wait(services.map(_reread));

    for (final peer in resolved) {
      if (peer == null) continue;
      if (peer.id == _self?.id) continue;

      seen.add(peer.id);
      final existing = _peers[peer.id];
      if (existing == null ||
          existing.port != peer.port ||
          existing.invitePort != peer.invitePort ||
          existing.sessionPublicId != peer.sessionPublicId ||
          existing.address != peer.address) {
        // Worth a line: a device that never turns up here as serving is the
        // whole difference between a code that matches and one that reports
        // nothing nearby, and that is not visible from either end afterwards.
        if (existing?.isServing != peer.isServing) {
          AppLogger.info(
              peer.isServing
                  ? '${peer.name} is offering a session on :${peer.port}'
                  : '${peer.name} is no longer offering a session',
              tag: 'DISCOVERY');
        }
        _peers[peer.id] = peer;
        changed = true;
      }
    }

    // Anything the browser has dropped goes too, in case a "lost" event was
    // missed while a resolve was in flight.
    final gone = _peers.keys.where((id) => !seen.contains(id)).toList();
    for (final id in gone) {
      _peers.remove(id);
      changed = true;
    }

    if (changed) _emit();
  }

  /// Asks the platform for one service's current record.
  ///
  /// Falls back to what the browser already handed us when the responder will
  /// not answer: a device we can still see is better listed from a stale
  /// record than dropped off the screen because one resolve timed out.
  Future<DiscoveredPeer?> _reread(nsd.Service service) async {
    try {
      final peer = DiscoveryAnnouncement.peerFrom(
        await _bounded(nsd.resolve(service), 'resolve timed out'),
      );
      if (peer != null) return peer;
    } catch (_) {
      // Gone again, or the responder is busy.
    }
    return DiscoveryAnnouncement.peerFrom(service);
  }

  Future<void> stop() async {
    // First, before anything that can wait: a call still in flight is exactly
    // the case this is unwinding, and cancelling its timeout at the end of the
    // method means never reaching it. That left a ten-second timer alive after
    // the screen was gone.
    _cancelPendingTimeouts();
    _reconcile?.cancel();
    _reconcile = null;

    final discovery = _discovery;
    _discovery = null;
    await _unpublish();
    if (discovery != null) {
      discovery.removeServiceListener(_onServiceEvent);
      try {
        await _bounded(nsd.stopDiscovery(discovery), 'stop timed out');
      } catch (_) {
        // Nothing left to stop.
      }
    }
    _cancelPendingTimeouts();
    _peers.clear();
    _self = null;
  }

  void _cancelPendingTimeouts() {
    for (final timer in _pendingTimeouts) {
      timer.cancel();
    }
    _pendingTimeouts.clear();
  }

  Future<void> dispose() async {
    // Synchronously, before the first await: whoever is tearing this down may
    // itself be inside an async teardown, and a timer that survives until the
    // next microtask is a timer that outlives the screen.
    _cancelPendingTimeouts();
    await stop();
    await _peersController.close();
  }

  void _emit() {
    if (_peersController.isClosed) return;
    _peersController.add(List.unmodifiable(_peers.values));
  }
}
