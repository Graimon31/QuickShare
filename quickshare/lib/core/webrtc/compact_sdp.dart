import 'dart:convert';
import 'dart:typed_data';

/// A WebRTC DataChannel offer/answer is almost entirely boilerplate. Only the
/// ICE credentials, the DTLS fingerprint and the candidate list actually differ
/// between sessions, so those are the only things worth carrying in a QR code
/// or pushing through a signaling channel — everything else is rebuilt from a
/// template on the far side.
///
/// A full gathered offer runs 6.5–8.4 KB. The same session survives here in
/// roughly 100–250 bytes, which is the difference between a QR code that has to
/// be held against the screen and one that scans across a desk.
class CompactSdp {
  final String iceUfrag;
  final String icePwd;

  /// SHA-256 DTLS fingerprint, 32 raw bytes (not the colon-separated hex form).
  final Uint8List fingerprint;

  /// 'actpass' for an offer, 'active' for an answer.
  final String setup;
  final List<CompactCandidate> candidates;

  const CompactSdp({
    required this.iceUfrag,
    required this.icePwd,
    required this.fingerprint,
    required this.setup,
    required this.candidates,
  });

  static const int _magic = 0x5153; // "QS"
  static const int _version = 1;

  static const _setupCodes = <String, int>{
    'actpass': 0,
    'active': 1,
    'passive': 2,
  };

  /// Pulls the session-specific fields out of a full SDP body.
  factory CompactSdp.fromSdp(String sdp) {
    String? ufrag, pwd, setup;
    Uint8List? fp;
    final candidates = <CompactCandidate>[];

    for (final raw in sdp.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (line.startsWith('a=ice-ufrag:')) {
        ufrag = line.substring(12);
      } else if (line.startsWith('a=ice-pwd:')) {
        pwd = line.substring(10);
      } else if (line.startsWith('a=setup:')) {
        setup = line.substring(8);
      } else if (line.startsWith('a=fingerprint:sha-256 ')) {
        fp = _hexToBytes(line.substring(22));
      } else if (line.startsWith('a=candidate:')) {
        final c = CompactCandidate.tryParse(line);
        if (c != null) candidates.add(c);
      }
    }

    if (ufrag == null || pwd == null || fp == null) {
      throw const FormatException('SDP is missing ice-ufrag, ice-pwd or a '
          'sha-256 fingerprint — cannot compact it');
    }
    return CompactSdp(
      iceUfrag: ufrag,
      icePwd: pwd,
      fingerprint: fp,
      setup: setup ?? 'actpass',
      candidates: candidates,
    );
  }

  Uint8List toBytes() {
    final out = BytesBuilder();
    out.addByte(_magic >> 8);
    out.addByte(_magic & 0xFF);
    out.addByte(_version);
    out.addByte(_setupCodes[setup] ?? 0);

    final u = utf8.encode(iceUfrag);
    final p = utf8.encode(icePwd);
    out.addByte(u.length);
    out.add(u);
    out.addByte(p.length);
    out.add(p);

    if (fingerprint.length != 32) {
      throw FormatException('SHA-256 fingerprint must be 32 bytes, '
          'got ${fingerprint.length}');
    }
    out.add(fingerprint);

    out.addByte(candidates.length);
    for (final c in candidates) {
      out.add(c.toBytes());
    }
    return out.toBytes();
  }

  factory CompactSdp.fromBytes(Uint8List bytes) {
    var i = 0;
    int u8() {
      if (i >= bytes.length) throw const FormatException('truncated payload');
      return bytes[i++];
    }

    if (bytes.length < 4 || (u8() << 8 | u8()) != _magic) {
      throw const FormatException('not a CompactSdp payload');
    }
    final version = u8();
    if (version != _version) {
      throw FormatException('unsupported CompactSdp version $version');
    }
    final setupCode = u8();

    List<int> take(int n) {
      if (i + n > bytes.length) throw const FormatException('truncated payload');
      final slice = bytes.sublist(i, i + n);
      i += n;
      return slice;
    }

    final ufrag = utf8.decode(take(u8()));
    final pwd = utf8.decode(take(u8()));
    final fp = Uint8List.fromList(take(32));

    final count = u8();
    final candidates = <CompactCandidate>[];
    for (var n = 0; n < count; n++) {
      final c = CompactCandidate.readFrom(bytes, i);
      candidates.add(c.value);
      i = c.nextOffset;
    }

    return CompactSdp(
      iceUfrag: ufrag,
      icePwd: pwd,
      fingerprint: fp,
      setup: _setupCodes.entries
          .firstWhere((e) => e.value == setupCode,
              orElse: () => const MapEntry('actpass', 0))
          .key,
      candidates: candidates,
    );
  }

  /// Rebuilds a full SDP body the native LibWebRTC parser accepts. CRLF is
  /// mandatory — Unix line endings make iOS reject the description outright.
  String toSdp({required bool isOffer}) {
    final lines = <String>[
      'v=0',
      'o=- 0 0 IN IP4 0.0.0.0',
      's=-',
      't=0 0',
      'a=group:BUNDLE 0',
      'a=extmap-allow-mixed',
      'a=msid-semantic: WMS',
      'm=application 9 UDP/DTLS/SCTP webrtc-datachannel',
      'c=IN IP4 0.0.0.0',
      'a=ice-ufrag:$iceUfrag',
      'a=ice-pwd:$icePwd',
      'a=ice-options:trickle',
      'a=fingerprint:sha-256 ${_bytesToHex(fingerprint)}',
      'a=setup:${isOffer ? setup : (setup == 'actpass' ? 'active' : setup)}',
      'a=mid:0',
      'a=sctp-port:5000',
      'a=max-message-size:262144',
      for (final c in candidates) c.toSdpLine(),
    ];
    return '${lines.join('\r\n')}\r\n';
  }

  static Uint8List _hexToBytes(String hex) {
    final clean = hex.replaceAll(':', '').replaceAll(' ', '');
    final out = Uint8List(clean.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  static String _bytesToHex(Uint8List bytes) => bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(':');
}

/// One ICE candidate squeezed into 8 bytes: 4 for the IPv4 address, 2 for the
/// port, 1 for the type and 1 for the component.
class CompactCandidate {
  final String address;
  final int port;

  /// 'host', 'srflx', 'prflx' or 'relay'.
  final String type;
  final int component;

  const CompactCandidate({
    required this.address,
    required this.port,
    required this.type,
    this.component = 1,
  });

  static const _typeCodes = <String, int>{
    'host': 0,
    'srflx': 1,
    'prflx': 2,
    'relay': 3,
  };

  /// a=candidate:<foundation> <component> <transport> <priority> <ip> <port> typ <type> ...
  /// IPv6, mDNS `.local` and link-local candidates are skipped: they cannot be
  /// packed into 4 bytes and are useless to a peer on another network anyway.
  static CompactCandidate? tryParse(String line) {
    final parts = line.split(' ');
    if (parts.length < 8 || parts[6] != 'typ') return null;
    final address = parts[4];
    if (!_isIpv4(address)) return null;
    final type = parts[7];
    if (!_typeCodes.containsKey(type)) return null;
    final port = int.tryParse(parts[5]);
    final component = int.tryParse(parts[1]) ?? 1;
    if (port == null || port < 0 || port > 65535) return null;
    return CompactCandidate(
      address: address,
      port: port,
      type: type,
      component: component,
    );
  }

  Uint8List toBytes() {
    final out = BytesBuilder();
    for (final octet in address.split('.')) {
      out.addByte(int.parse(octet));
    }
    out.addByte(port >> 8);
    out.addByte(port & 0xFF);
    out.addByte(_typeCodes[type]!);
    out.addByte(component);
    return out.toBytes();
  }

  static ({CompactCandidate value, int nextOffset}) readFrom(
      Uint8List bytes, int offset) {
    if (offset + 8 > bytes.length) {
      throw const FormatException('truncated candidate');
    }
    final address = bytes.sublist(offset, offset + 4).join('.');
    final port = bytes[offset + 4] << 8 | bytes[offset + 5];
    final type = _typeCodes.entries
        .firstWhere((e) => e.value == bytes[offset + 6],
            orElse: () => const MapEntry('host', 0))
        .key;
    return (
      value: CompactCandidate(
        address: address,
        port: port,
        type: type,
        component: bytes[offset + 7] == 0 ? 1 : bytes[offset + 7],
      ),
      nextOffset: offset + 8,
    );
  }

  /// Foundation and priority are regenerated rather than carried: the far side
  /// only needs a usable candidate, and ICE recomputes pair priorities itself.
  String toSdpLine() {
    final priority = switch (type) {
      'host' => 2122260223,
      'srflx' => 1686052607,
      'prflx' => 1685921535,
      _ => 41885439,
    };
    final foundation = Object.hash(address, type).abs() % 4294967295;
    return 'a=candidate:$foundation $component udp $priority $address $port '
        'typ $type generation 0';
  }

  static bool _isIpv4(String value) {
    final parts = value.split('.');
    if (parts.length != 4) return false;
    for (final p in parts) {
      final n = int.tryParse(p);
      if (n == null || n < 0 || n > 255) return false;
    }
    return true;
  }
}
