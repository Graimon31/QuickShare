import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:nsd/nsd.dart' as nsd;

import 'package:quickshare/core/transfer/invitation_listener.dart';
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

  DiscoveredPeer copyWith({
    String? id,
    String? name,
    String? platform,
    InternetAddress? address,
    int? port,
    String? tlsFingerprint,
    int? invitePort,
    String? sessionPublicId,
  }) {
    return DiscoveredPeer(
      id: id ?? this.id,
      name: name ?? this.name,
      platform: platform ?? this.platform,
      address: address ?? this.address,
      port: port ?? this.port,
      tlsFingerprint: tlsFingerprint ?? this.tlsFingerprint,
      invitePort: invitePort ?? this.invitePort,
      sessionPublicId: sessionPublicId ?? this.sessionPublicId,
    );
  }

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
  final String ipAddress;
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
    this.ipAddress = '',
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
        if (ipAddress.isNotEmpty) 'a': _bytes(ipAddress),
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

    // Prefer the actual network address resolved by the mDNS responder over
    // the self-reported 'a' TXT record. Fall back to 'a' only when
    // service.addresses is omitted by the platform responder (e.g. iOS/macOS nsd).
    InternetAddress? address;
    final addresses = service.addresses;
    if (addresses != null && addresses.isNotEmpty) {
      final nonLoopbackIpv4 = addresses.where(
        (a) => a.type == InternetAddressType.IPv4 && !a.isLoopback,
      ).toList();
      if (nonLoopbackIpv4.isNotEmpty) {
        address = nonLoopbackIpv4.first;
      } else {
        final nonLoopback = addresses.where((a) => !a.isLoopback).toList();
        if (nonLoopback.isNotEmpty) {
          address = nonLoopback.first;
        }
      }
    }

    if (address == null) {
      final txtIp = _text(txt, 'a');
      if (txtIp != null && txtIp.isNotEmpty) {
        final parsed = InternetAddress.tryParse(txtIp);
        if (parsed != null && !parsed.isLoopback) {
          address = parsed;
        }
      }
    }

    if (address == null) return null;

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
  final Set<Completer<dynamic>> _pendingCalls = {};

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

  /// How long a device has to accept a connection before it is not counted as
  /// answering. A listening socket on the same network answers in about a
  /// millisecond; this is the budget for a lost packet, not for a slow device.
  static const Duration reachabilityBudget = Duration(milliseconds: 600);

  /// Missed answers before a device leaves the list.
  ///
  /// More than one because Wi-Fi drops packets, and a device blinking out of
  /// the list and back is worse than one that lingers a couple of seconds.
  static const int strikesBeforeGone = 2;

  /// Consecutive probes a device has failed, by id.
  final Map<String, int> _strikes = {};

  final Future<bool> Function(InternetAddress address, int port) _answersOn;

  LanDiscoveryService({
    String? serviceType,
    Future<bool> Function(InternetAddress address, int port)? answersOn,
  })  : type = serviceType ?? LanDiscoveryService.serviceType,
        _answersOn = answersOn ?? _opensASocket;

  static Future<bool> _opensASocket(InternetAddress address, int port) async {
    try {
      final socket =
          await Socket.connect(address, port, timeout: reachabilityBudget);
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Bounds one call into the platform's responder, with a timer this service
  /// can cancel.
  Future<T> _bounded<T>(Future<T> call, String what) {
    final completer = Completer<T>();
    _pendingCalls.add(completer);
    late final Timer timer;
    timer = Timer(platformCallTimeout, () {
      _pendingTimeouts.remove(timer);
      _pendingCalls.remove(completer);
      if (!completer.isCompleted) {
        completer.completeError(TimeoutException(what));
      }
    });
    _pendingTimeouts.add(timer);

    void settle(void Function() body) {
      timer.cancel();
      _pendingTimeouts.remove(timer);
      _pendingCalls.remove(completer);
      if (!completer.isCompleted) body();
    }

    call.then((value) => settle(() => completer.complete(value)),
        onError: (Object error, StackTrace stack) =>
            settle(() => completer.completeError(error, stack)));

    return completer.future;
  }

  /// The current list, and every change to it.
  Stream<List<DiscoveredPeer>> get peers => _peersController.stream;

  List<DiscoveredPeer> get current => List.unmodifiable(_peers.values);

  bool get isRunning => _discovery != null;

  /// Triggers an immediate discovery refresh across the network.
  Future<void> refresh() => _reconcileNow();

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

    final suffix = self.id.length >= 6 ? self.id.substring(0, 6) : self.id;
    final maxBaseLen = 63 - 1 - suffix.length;
    final baseName = self.name.length > maxBaseLen
        ? self.name.substring(0, maxBaseLen)
        : self.name;
    final wireName = suffix.isNotEmpty ? '$baseName-$suffix' : baseName;

    try {
      _registration = await _bounded(
        nsd.register(
          nsd.Service(
            name: wireName,
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
        // Stale mDNS records on discovery start fire 'found' events.
        // Never put an unverified service directly into _peers without checking
        // TCP reachability first; schedule a reconcile pass to probe it.
        unawaited(_reconcileNow());
      case nsd.ServiceStatus.lost:
        _peers.remove(peer.id);
        _strikes.remove(peer.id);
        _emit();
    }
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

    final candidates = resolved
        .whereType<DiscoveredPeer>()
        .where((p) => p.id != _self?.id)
        .toList();

    // Being announced is not the same as being there, and the gap between the
    // two is not small: a record outlives the app that published it by the
    // best part of an hour, and an app that is force-quit or suspended never
    // gets to say goodbye at all. The list was showing a phone whose app had
    // been closed for minutes — and, because each launch announces a fresh
    // identifier, sometimes showing it twice from two different launches.
    //
    // So each one is asked. A device that answers on the port it published is
    // there; a device that does not is a leftover record, whatever the
    // responder still believes.
    final answered = await Future.wait(candidates.map((c) async {
      // If we don't already have this peer active in _peers, it is a new or
      // previously-dropped candidate. Require it to actually answer TCP right
      // now before admitting it. Never grant grace strikes to dead candidates.
      if (!_peers.containsKey(c.id)) {
        final port = c.port > 0 ? c.port : c.invitePort;
        if (port <= 0) return true;
        if (c.address.isLoopback) return false;
        final ok = (c.port > 0 && await _answersOn(c.address, c.port)) ||
            (c.invitePort > 0 && await _answersOn(c.address, c.invitePort)) ||
            (c.invitePort != InvitationListener.defaultPort &&
                await _answersOn(c.address, InvitationListener.defaultPort));
        if (ok) {
          _strikes.remove(c.id);
          return true;
        }
        return false;
      }
      return stillThere(c);
    }));

    for (var i = 0; i < candidates.length; i++) {
      if (!answered[i]) continue;
      final peer = candidates[i];

      // Deduplicate: if an existing peer has the same IP and port but different ID,
      // the remote app restarted under a fresh ID. Replace the stale entry.
      final targetEndpoint =
          '${peer.address.address}:${peer.port > 0 ? peer.port : peer.invitePort}';
      final staleKeys = _peers.entries
          .where((e) =>
              e.key != peer.id &&
              '${e.value.address.address}:${e.value.port > 0 ? e.value.port : e.value.invitePort}' ==
                  targetEndpoint)
          .map((e) => e.key)
          .toList();
      for (final staleKey in staleKeys) {
        final stalePeer = _peers.remove(staleKey);
        _strikes.remove(staleKey);
        if (stalePeer != null) {
          AppLogger.info(
              'Deduplicated stale peer: "${stalePeer.name}" ($staleKey)',
              tag: 'DISCOVERY');
        }
        changed = true;
      }

      seen.add(peer.id);
      final existing = _peers[peer.id];
      if (existing == null ||
          existing.port != peer.port ||
          existing.invitePort != peer.invitePort ||
          existing.sessionPublicId != peer.sessionPublicId ||
          existing.address != peer.address) {
        if (existing == null) {
          AppLogger.info(
              'Discovered peer: "${peer.name}" (${peer.platform}) at ${peer.address.address}:${peer.port > 0 ? peer.port : peer.invitePort}',
              tag: 'DISCOVERY');
        }
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

    // Before removing any peer that wasn't seen in this pass, verify if it is
    // still answering on TCP. A dropped mDNS resolve or busy responder must not
    // drop a device that is right here and answering on its socket.
    final activeEndpoints = seen
        .map((id) => _peers[id])
        .whereType<DiscoveredPeer>()
        .map((p) => '${p.address.address}:${p.port > 0 ? p.port : p.invitePort}')
        .toSet();

    final candidateIds = candidates.map((c) => c.id).toSet();
    final gone = <String>[];
    for (final id in _peers.keys) {
      if (seen.contains(id)) continue;
      final peer = _peers[id];
      final endpoint = peer != null
          ? '${peer.address.address}:${peer.port > 0 ? peer.port : peer.invitePort}'
          : null;
      if (!candidateIds.contains(id) &&
          peer != null &&
          endpoint != null &&
          !activeEndpoints.contains(endpoint) &&
          await stillThere(peer)) {
        seen.add(id);
        activeEndpoints.add(endpoint);
        continue;
      }
      gone.add(id);
    }

    for (final id in gone) {
      final gonePeer = _peers.remove(id);
      _strikes.remove(id);
      if (gonePeer != null) {
        AppLogger.info('Peer left: "${gonePeer.name}"', tag: 'DISCOVERY');
      }
      changed = true;
    }

    if (changed) _emit();
  }

  /// Whether [peer] answers where it said it could be reached.
  ///
  /// A device that publishes no port to be reached on cannot be asked, so it
  /// is taken at its word rather than dropped — that is an older build or one
  /// that is only browsing, not a stale record.
  ///
  /// A single missed answer is not enough to remove it: [strikesBeforeGone]
  /// consecutive ones are, because a device flickering out of the list and
  /// back on one lost packet is worse than one that lingers a second longer.
  @visibleForTesting
  Future<bool> stillThere(DiscoveredPeer peer) async {
    final port = peer.port > 0 ? peer.port : peer.invitePort;
    if (port <= 0) return true;
    if (peer.address.isLoopback) return false;

    bool reachable = false;
    if (peer.port > 0 && await _answersOn(peer.address, peer.port)) {
      reachable = true;
    } else if (peer.invitePort > 0 &&
        await _answersOn(peer.address, peer.invitePort)) {
      reachable = true;
    } else if (peer.invitePort != InvitationListener.defaultPort &&
        await _answersOn(peer.address, InvitationListener.defaultPort)) {
      reachable = true;
    }

    if (reachable) {
      _strikes.remove(peer.id);
      return true;
    }

    final missed = (_strikes[peer.id] ?? 0) + 1;
    _strikes[peer.id] = missed;
    if (missed < strikesBeforeGone) return true;

    if (_peers.containsKey(peer.id)) {
      AppLogger.info(
          '${peer.name} stopped answering on :$port — dropping it from the list',
          tag: 'DISCOVERY');
    }
    return false;
  }

  /// Asks the platform for one service's current record.
  ///
  /// Falls back to what the browser already handed us when the responder will
  /// not answer: a device we can still see is better listed from a stale
  /// record than dropped off the screen because one resolve timed out.
  Future<DiscoveredPeer?> _reread(nsd.Service service) async {
    try {
      var resolved = await _bounded(nsd.resolve(service), 'resolve timed out');
      final mergedTxt = resolved.txt ?? service.txt;
      final port = (resolved.port != null && resolved.port! > 0)
          ? resolved.port
          : service.port;
      final host = resolved.host ?? service.host;

      if (resolved.addresses == null || resolved.addresses!.isEmpty) {
        final txtIp = DiscoveryAnnouncement._text(mergedTxt, 'a');
        if (txtIp != null && txtIp.isNotEmpty) {
          final parsed = InternetAddress.tryParse(txtIp);
          if (parsed != null && !parsed.isLoopback) {
            resolved = nsd.Service(
              name: resolved.name,
              type: resolved.type,
              host: host,
              port: port,
              txt: mergedTxt,
              addresses: [parsed],
            );
          }
        } else {
          if (host != null && host.isNotEmpty) {
            try {
              final lookedUp = await InternetAddress.lookup(
                host,
                type: InternetAddressType.IPv4,
              );
              resolved = nsd.Service(
                name: resolved.name,
                type: resolved.type,
                host: host,
                port: port,
                txt: mergedTxt,
                addresses: lookedUp,
              );
            } catch (_) {}
          }
        }
      } else if (resolved.txt == null && service.txt != null) {
        resolved = nsd.Service(
          name: resolved.name,
          type: resolved.type,
          host: host,
          port: port,
          txt: service.txt,
          addresses: resolved.addresses,
        );
      }
      final peer = DiscoveryAnnouncement.peerFrom(resolved);
      if (peer != null) {
        return peer;
      }
    } catch (_) {
      // Gone again, or the responder is busy.
    }
    // If resolve failed, check if we already have this peer resolved in _peers
    for (final existing in _peers.values) {
      final prefix = existing.id.length >= 6 ? existing.id.substring(0, 6) : existing.id;
      final sName = service.name ?? '';
      if (sName.startsWith(existing.name) || sName.contains(prefix)) {
        return existing;
      }
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
    _strikes.clear();

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
    for (final c in List.of(_pendingCalls)) {
      if (!c.isCompleted) c.completeError(StateError('cancelled'));
    }
    _pendingCalls.clear();
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
