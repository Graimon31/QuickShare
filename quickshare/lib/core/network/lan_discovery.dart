import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:quickshare/core/network/network_info_service.dart';
import 'package:quickshare/core/utils/app_logger.dart';

/// A device that has announced itself on this network, as last heard.
///
/// The address is taken from the datagram's own sender rather than from a
/// field inside it: a device that gets its address wrong — or lies about it —
/// then simply cannot be reached, instead of poisoning the list with an
/// address that belongs to somebody else.
class DiscoveredPeer {
  /// Stable across announcements from the same session, so a peer heard twice
  /// is one row rather than two.
  final String id;

  /// What to show in the list. Chosen by the far side; treated as display text
  /// and nothing else.
  final String name;

  /// 'ios', 'android', 'macos', 'windows', 'linux' — or anything else a future
  /// build sends. Only ever used to pick an icon, so an unknown value is not
  /// an error.
  final String platform;

  final InternetAddress address;

  /// The QHTP port this peer serves on, or 0 when it is only listening for
  /// invitations rather than offering a session.
  final int port;

  /// Certificate fingerprint to pin, when this peer is already serving. Empty
  /// for an idle peer, which has no server and therefore no certificate yet.
  final String tlsFingerprint;

  /// Where to send this peer an invitation, or 0 when it is not accepting
  /// them.
  ///
  /// Separate from [port], which is where its own files are served from: a
  /// device can be ready to receive without offering anything, and usually is.
  /// Zero also covers a peer on a build from before invitations existed, which
  /// simply never mentions the field.
  final int invitePort;

  /// When this peer was last heard from, for [isStale].
  final DateTime lastSeen;

  const DiscoveredPeer({
    required this.id,
    required this.name,
    required this.platform,
    required this.address,
    required this.port,
    required this.lastSeen,
    this.tlsFingerprint = '',
    this.invitePort = 0,
  });

  /// Whether this peer is offering a session right now, as opposed to merely
  /// being present.
  bool get isServing => port > 0;

  /// Whether this peer can be asked to accept a transfer.
  bool get acceptsInvitations => invitePort > 0;

  bool isStale(DateTime now, Duration after) =>
      now.difference(lastSeen) > after;

  DiscoveredPeer copyWith({DateTime? lastSeen}) => DiscoveredPeer(
        id: id,
        name: name,
        platform: platform,
        address: address,
        port: port,
        tlsFingerprint: tlsFingerprint,
        invitePort: invitePort,
        lastSeen: lastSeen ?? this.lastSeen,
      );

  @override
  String toString() =>
      'DiscoveredPeer($name, $platform, ${address.address}:$port)';
}

/// What one device shouts into the network so the others can list it.
///
/// Deliberately small: every field costs bytes in a datagram that goes out
/// several times a second to every device in the room, and anything that is
/// not needed to *draw a row and open a socket* belongs in the session itself,
/// behind the token.
class DiscoveryAnnouncement {
  static const int version = 1;

  final String id;
  final String name;
  final String platform;
  final int port;
  final String tlsFingerprint;

  /// Where this device listens for invitations, or 0 when it is not.
  final int invitePort;

  const DiscoveryAnnouncement({
    required this.id,
    required this.name,
    required this.platform,
    this.port = 0,
    this.tlsFingerprint = '',
    this.invitePort = 0,
  });

  /// A request for everyone present to announce themselves immediately.
  ///
  /// Without it a device that has just opened the app waits out a whole
  /// announcement interval before anything appears on screen, which reads as
  /// "nobody is here" rather than "still looking". A join is one packet and
  /// the replies are the announcements that were going to be sent anyway.
  static const String queryMarker = '?';

  Map<String, dynamic> toJson() => {
        'v': version,
        'id': id,
        'n': name,
        'os': platform,
        if (port > 0) 'p': port,
        if (tlsFingerprint.isNotEmpty) 'tf': tlsFingerprint,
        if (invitePort > 0) 'ip': invitePort,
      };

  List<int> encode() => utf8.encode(jsonEncode(toJson()));

  /// The "everybody speak up" packet, which carries no payload of its own.
  static List<int> encodeQuery() => utf8.encode(queryMarker);

  static bool isQuery(List<int> datagram) {
    if (datagram.length != 1) return false;
    return datagram.first == queryMarker.codeUnitAt(0);
  }

  /// Parses one datagram, or returns null if it is not one of ours.
  ///
  /// Null rather than throwing because this runs on every packet arriving on a
  /// multicast group that other software shares: a neighbour's unrelated
  /// traffic is an ordinary event, not an error worth a stack trace.
  static DiscoveryAnnouncement? decode(List<int> datagram) {
    try {
      final decoded = jsonDecode(utf8.decode(datagram));
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['v'] != version) return null;

      final id = decoded['id'];
      final name = decoded['n'];
      final platform = decoded['os'];
      if (id is! String || id.isEmpty) return null;
      if (name is! String || name.isEmpty) return null;
      if (platform is! String || platform.isEmpty) return null;

      final port = decoded['p'];
      final invitePort = decoded['ip'];
      return DiscoveryAnnouncement(
        id: id,
        name: name,
        platform: platform,
        port: port is int && port > 0 && port < 65536 ? port : 0,
        tlsFingerprint: decoded['tf'] as String? ?? '',
        invitePort:
            invitePort is int && invitePort > 0 && invitePort < 65536
                ? invitePort
                : 0,
      );
    } catch (_) {
      return null;
    }
  }
}

/// The list of peers currently on the network, kept from announcements.
///
/// Split out from the socket so the part with the rules in it — when a peer
/// appears, when it is replaced, when it disappears — can be tested without a
/// network at all. Everything here is synchronous and deterministic; the
/// socket half only feeds it bytes and a clock.
class PeerRegistry {
  /// How long a peer survives without being heard from.
  ///
  /// Three announcement intervals rather than one: Wi-Fi drops individual
  /// multicast datagrams routinely, and a device blinking out of the list
  /// because one packet was lost is worse than a device lingering two seconds
  /// after it really left.
  static const Duration presenceTimeout = Duration(seconds: 7);

  final Map<String, DiscoveredPeer> _peers = {};

  /// Peers heard recently enough to still be there, most recently seen first.
  List<DiscoveredPeer> visible(DateTime now) {
    final live = _peers.values
        .where((peer) => !peer.isStale(now, presenceTimeout))
        .toList()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return live;
  }

  /// Records an announcement. Returns true when this changed what a list on
  /// screen would show, so a caller can avoid rebuilding for a heartbeat that
  /// says exactly what the last one did.
  bool record(
    DiscoveryAnnouncement announcement,
    InternetAddress from,
    DateTime now, {
    String? ignoreId,
  }) {
    // Our own announcements come straight back to us on the multicast group.
    // Listing yourself as a peer is not useful and is confusing on a screen
    // that means "devices near you".
    if (ignoreId != null && announcement.id == ignoreId) return false;

    final existing = _peers[announcement.id];
    final peer = DiscoveredPeer(
      id: announcement.id,
      name: announcement.name,
      platform: announcement.platform,
      address: from,
      port: announcement.port,
      tlsFingerprint: announcement.tlsFingerprint,
      invitePort: announcement.invitePort,
      lastSeen: now,
    );
    _peers[announcement.id] = peer;

    if (existing == null) return true;
    return existing.name != peer.name ||
        existing.address != peer.address ||
        existing.port != peer.port ||
        existing.tlsFingerprint != peer.tlsFingerprint ||
        existing.invitePort != peer.invitePort;
  }

  /// Drops peers nobody has heard from. Returns true if anything went.
  bool prune(DateTime now) {
    final before = _peers.length;
    _peers.removeWhere((_, peer) => peer.isStale(now, presenceTimeout));
    return _peers.length != before;
  }

  void clear() => _peers.clear();
}

/// Announces this device on the local network and lists the others.
///
/// A plain UDP multicast group rather than mDNS: the discovery this needs is
/// "who is running this app on this network", which is one packet in each
/// direction, while a conforming mDNS responder is a protocol with a plugin
/// and native code on all five platforms behind it. `RawDatagramSocket` is in
/// `dart:io` and behaves the same everywhere.
///
/// Note the whole thing is best effort and says so: networks that block
/// multicast — guest Wi-Fi, most captive portals, anything with client
/// isolation — will produce an empty list forever, and the UI has to offer the
/// QR path rather than leaving somebody staring at a spinner.
class LanDiscoveryService {
  /// Link-local scope: routers do not forward 224.0.0.0/24 beyond the subnet,
  /// which is exactly the reach "devices near you" should have.
  static final InternetAddress multicastGroup =
      InternetAddress('224.0.0.171');

  static const int multicastPort = 53319;

  /// How often a device repeats itself. Fast enough that a list feels live,
  /// slow enough that ten devices in a room cost a handful of packets a
  /// second between them.
  static const Duration announceInterval = Duration(seconds: 2);

  final int port;
  final InternetAddress group;

  RawDatagramSocket? _socket;
  Timer? _announceTimer;
  Timer? _pruneTimer;
  DiscoveryAnnouncement? _self;

  final NetworkInfoService _networkInfo = NetworkInfoService();
  final PeerRegistry _registry = PeerRegistry();
  final StreamController<List<DiscoveredPeer>> _peersController =
      StreamController<List<DiscoveredPeer>>.broadcast();

  LanDiscoveryService({InternetAddress? group, int? port})
      : group = group ?? multicastGroup,
        port = port ?? multicastPort;

  /// The current list, and every change to it.
  Stream<List<DiscoveredPeer>> get peers => _peersController.stream;

  List<DiscoveredPeer> get current => _registry.visible(DateTime.now());

  bool get isRunning => _socket != null;

  /// Starts listening, and announces [self] until [stop].
  ///
  /// Failure here is not fatal to anything: a device that cannot open the
  /// group still transfers perfectly well over a scanned QR code, so this
  /// reports the problem and returns false rather than throwing into a UI that
  /// has a working alternative.
  Future<bool> start(DiscoveryAnnouncement self) async {
    if (_socket != null) await stop();
    _self = self;

    try {
      final lan = await _networkInfo.primaryLanInterface();
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        port,
        reuseAddress: true,
        reusePort: !Platform.isWindows, // Windows has no SO_REUSEPORT.
      );
      // Both halves have to name the interface, and for different reasons:
      // joining on it is what makes the group's traffic arrive, and
      // IP_MULTICAST_IF is what makes our own packets leave through it.
      if (lan != null) {
        socket.joinMulticast(group, lan);
        _pinOutgoingInterface(socket, lan);
      } else {
        socket.joinMulticast(group);
      }
      socket.multicastLoopback = true;
      _socket = socket;

      socket.listen(_onEvent, onError: (Object e) {
        AppLogger.warning('Discovery socket error: $e', tag: 'DISCOVERY');
      });

      _announce();
      _query();
      _announceTimer = Timer.periodic(announceInterval, (_) => _announce());
      _pruneTimer = Timer.periodic(announceInterval, (_) => _pruneNow());

      AppLogger.info(
          'Announcing as "${self.name}" on ${group.address}:$port'
          '${lan == null ? ' (no LAN interface found — using the default '
              'route, which a VPN may own)' : ' via ${lan.name}'}',
          tag: 'DISCOVERY');
      return true;
    } on SocketException catch (e) {
      AppLogger.warning(
          'Could not join the discovery group — this network may block '
          'multicast; the QR path still works: ${e.message}',
          tag: 'DISCOVERY');
      await stop();
      return false;
    } catch (e) {
      AppLogger.warning('Discovery did not start: $e', tag: 'DISCOVERY');
      await stop();
      return false;
    }
  }

  /// Replaces what this device says about itself — used when a session opens
  /// and the announcement gains a port to dial.
  void update(DiscoveryAnnouncement self) {
    _self = self;
    if (_socket != null) _announce();
  }

  Future<void> stop() async {
    _announceTimer?.cancel();
    _announceTimer = null;
    _pruneTimer?.cancel();
    _pruneTimer = null;
    try {
      _socket?.leaveMulticast(group);
    } catch (_) {
      // Already gone, or never joined.
    }
    _socket?.close();
    _socket = null;
    _registry.clear();
    _self = null;
  }

  Future<void> dispose() async {
    await stop();
    await _peersController.close();
  }

  /// `IP_MULTICAST_IF` — sends through [interface] rather than through
  /// whatever the routing table prefers.
  ///
  /// This is the difference between discovery working and silently doing
  /// nothing on any machine with an always-on VPN: the tunnel holds the
  /// default route, so without this every announcement leaves into it and no
  /// device on the actual network ever hears one. The symptom is an empty
  /// list, identical to a network that blocks multicast.
  ///
  /// The option number is not portable — BSD (so macOS and iOS) and Windows
  /// use 9, Linux and Android use 32 — and there is no constant for it in
  /// `dart:io`.
  void _pinOutgoingInterface(RawDatagramSocket socket, NetworkInterface interface) {
    final address = interface.addresses
        .where((a) => a.type == InternetAddressType.IPv4)
        .firstOrNull;
    if (address == null) return;

    final optionValue = Platform.isLinux || Platform.isAndroid ? 32 : 9;
    try {
      socket.setRawOption(RawSocketOption(
        RawSocketOption.levelIPv4,
        optionValue,
        address.rawAddress,
      ));
    } on OSError catch (e) {
      // Not fatal: the socket still works, it just may send through the wrong
      // interface. Worth a line, because that is the shape of the bug.
      AppLogger.warning(
          'Could not pin discovery to ${interface.name}: ${e.message}',
          tag: 'DISCOVERY');
    } catch (e) {
      AppLogger.warning('Could not pin discovery to ${interface.name}: $e',
          tag: 'DISCOVERY');
    }
  }

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final datagram = _socket?.receive();
    if (datagram == null) return;

    if (DiscoveryAnnouncement.isQuery(datagram.data)) {
      // Somebody just arrived and wants the room to speak up.
      _announce();
      return;
    }

    final announcement = DiscoveryAnnouncement.decode(datagram.data);
    if (announcement == null) return;

    final changed = _registry.record(
      announcement,
      datagram.address,
      DateTime.now(),
      ignoreId: _self?.id,
    );
    if (changed) _emit();
  }

  void _announce() {
    final self = _self;
    final socket = _socket;
    if (self == null || socket == null) return;
    try {
      socket.send(self.encode(), group, port);
    } on SocketException catch (e) {
      AppLogger.warning('Announcement not sent: ${e.message}',
          tag: 'DISCOVERY');
    }
  }

  void _query() {
    try {
      _socket?.send(DiscoveryAnnouncement.encodeQuery(), group, port);
    } on SocketException {
      // The periodic announcements still bring the list up, just slower.
    }
  }

  void _pruneNow() {
    if (_registry.prune(DateTime.now())) _emit();
  }

  void _emit() {
    if (_peersController.isClosed) return;
    _peersController.add(_registry.visible(DateTime.now()));
  }
}
