import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

import 'package:quickshare/core/crypto/hkdf.dart';
import 'package:quickshare/core/crypto/spake2.dart';
import 'package:quickshare/core/network/code_pake.dart';
import 'package:quickshare/core/network/session_code.dart';

/// Finding an internet sender by its ten-digit code.
///
/// The code is a little over 33 bits and the only secret two strangers share,
/// and the meeting place is public: a relay and the Worker see every message
/// and may drop, repeat or forge any of them. So nothing here is derived from
/// the code in a way that can be tried at home.
///
/// What the public sees is, in order:
///
///  1. a topic that is a function of **12 bits** of the code and nothing else,
///     so thousands of unrelated sessions share every topic;
///  2. the receiver's SPAKE2 share, which depends on the code only in a way
///     that cannot be tested without the sender's private scalar;
///  3. the sender's share and its confirmation, which an impostor can check a
///     single guess against, and which the sender's budget counts;
///  4. everything after that, sealed under a key only a holder of the code
///     can derive, on topics only such a holder can name.
///
/// This file holds the parts that are pure: the topic arithmetic, the wire
/// formats, the key schedule and the seal. The two ends that use them are
/// `InternetCodeSender` and `InternetCodeSearch`.
abstract final class InternetCode {
  static const int version = 1;

  /// Domain of every hash, key and label in the exchange, so none can be read
  /// off another protocol that happens to use the same code.
  static const String domain = 'directdrop-internet-code-v1';

  /// `n`, mixed into both identities: a run of the protocol cannot be replayed
  /// into another.
  static const int nonceLength = 16;
  static const int topicLength = 16;

  /// How many bits of the code a request topic reveals.
  static const int bucketBits = 12;

  // Bounds on what is read from the public, checked before anything is
  // parsed. Each is a few times the honest size.
  static const int maxRequestBytes = 512;
  static const int maxReplyBytes = 512;
  static const int maxConfirmBytes = 1024;
  static const int maxPayloadBytes = 6144;

  /// The longest offer string a sender will publish or a receiver accept. The
  /// Worker's room holds 8 KiB, and a real offer is well under one.
  static const int maxOfferChars = 4096;

  /// The device name a receiver announces, after cleaning.
  static const int maxNameChars = 40;

  /// What an announced name may be before it is cleaned; anything longer is
  /// not a name this protocol's receivers send.
  static const int maxRawNameChars = 128;

  /// 12 bits of a domain-separated hash of the code.
  static int bucket(SessionCode code) {
    final digest = sha256.convert(utf8.encode('$domain/bucket/${code.code}'));
    return (digest.bytes[0] << 4) | (digest.bytes[1] >> 4);
  }

  /// The topic requests for a code are published on: HKDF of the 12 bits, in
  /// the same 22-character spelling every other topic has, which is what the
  /// Worker's room-id check accepts.
  static String requestTopicForBucket(int bucket) {
    assert(bucket >= 0 && bucket < (1 << bucketBits));
    return encode(hkdfSha256(
      [bucket >> 8, bucket & 0xff],
      info: utf8.encode('$domain/request-topic'),
      length: topicLength,
    ));
  }

  static String requestTopic(SessionCode code) =>
      requestTopicForBucket(bucket(code));

  static Uint8List randomBytes(int length, [Random? random]) {
    final source = random ?? Random.secure();
    return Uint8List.fromList(
        List<int>.generate(length, (_) => source.nextInt(256)));
  }

  static String newReplyTopic([Random? random]) =>
      encode(randomBytes(topicLength, random));

  /// Unpadded base64url, the one spelling of every field.
  static String encode(List<int> bytes) => CodePake.encode(bytes);

  /// A device name as the sender's screen may show it: no control or
  /// direction-changing characters, one line, at most [maxNameChars].
  ///
  /// The name is whatever the other end chose to type into a public mailbox.
  /// It is displayed as data and never interpreted — this only keeps it from
  /// changing how the rest of the dialog reads.
  static String cleanName(String raw) {
    final visible = String.fromCharCodes([
      for (final rune in raw.runes) _isInvisible(rune) ? 0x20 : rune,
    ]);
    final stripped = visible.replaceAll(RegExp(r'\s+'), ' ').trim();
    final runes = stripped.runes.toList();
    if (runes.length <= maxNameChars) return stripped;
    return '${String.fromCharCodes(runes.take(maxNameChars - 1))}\u2026';
  }

  /// Control characters, and the ones that move, hide or reverse text: the
  /// soft hyphen, the Arabic letter mark, zero-width and direction marks, line
  /// and paragraph separators, embeddings and overrides, isolates, the byte
  /// order mark and the interlinear annotation anchors.
  static bool _isInvisible(int c) =>
      c < 0x20 ||
      (c >= 0x7f && c <= 0x9f) ||
      c == 0xad ||
      c == 0x61c ||
      c == 0x180e ||
      (c >= 0x200b && c <= 0x200f) ||
      (c >= 0x2028 && c <= 0x202e) ||
      (c >= 0x2060 && c <= 0x206f) ||
      c == 0xfeff ||
      (c >= 0xfff9 && c <= 0xfffb);

  static bool _isTopic(Object? value) =>
      value is String &&
      value.length == 22 &&
      CodePake.decode(value, length: topicLength) != null;
}

/// Every number that bounds the exchange, in one place so that a test can
/// shrink them and the owner can read them.
class InternetCodeTimings {
  const InternetCodeTimings({
    this.requestMaxAge = const Duration(minutes: 2),
    this.minRequestGap = const Duration(seconds: 1),
    this.maxAttemptsPerCode = 30,
    this.maxPendingExchanges = 8,
    this.confirmWait = const Duration(seconds: 30),
    this.dialogTimeout = const Duration(seconds: 90),
    this.payloadHold = const Duration(seconds: 60),
    this.findTimeout = const Duration(seconds: 20),
    this.approvalWait = const Duration(seconds: 95),
    this.maxRepliesChecked = 16,
  });

  /// Sender: a request older (or further in the future) than this is dropped.
  final Duration requestMaxAge;

  /// Sender: at most one SPAKE2 run per this long; the rest are dropped.
  final Duration minRequestGap;

  /// Sender: how many requests one code ever pays for.
  final int maxAttemptsPerCode;

  /// Sender: how many exchanges may wait for their confirmation at once.
  final int maxPendingExchanges;

  /// Sender: how long an exchange waits for the receiver's confirmation after
  /// replying.
  final Duration confirmWait;

  /// Sender: how long a person has to answer the dialog.
  final Duration dialogTimeout;

  /// Sender: how long the offer is held in place after it was handed over, for
  /// the answer to arrive.
  final Duration payloadHold;

  /// Receiver: from publishing the request to a reply that proves the code.
  final Duration findTimeout;

  /// Receiver: from confirming to the offer or a refusal. Longer than the
  /// sender's dialog, so a person who takes the whole time is still heard.
  final Duration approvalWait;

  /// Receiver: how many replies one search will check. A reply costs two
  /// curve multiplications; the topic is unguessable, but a relay sees it.
  final int maxRepliesChecked;
}

/// `{v, n, pA, reply, ts}`: the receiver's request, published in the clear on
/// the request topic.
class CodeRequest {
  const CodeRequest({
    required this.n,
    required this.pA,
    required this.reply,
    required this.ts,
  });

  /// 2100-01-01T00:00:00Z.
  static const int _lastSecond = 4102444800;

  final Uint8List n;
  final Uint8List pA;

  /// The topic the receiver is already listening on.
  final String reply;

  /// Unix seconds, the receiver's clock.
  final int ts;

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode({
        'v': InternetCode.version,
        'n': InternetCode.encode(n),
        'pA': InternetCode.encode(pA),
        'reply': reply,
        'ts': ts,
      })));

  /// The request in [raw], or null for anything that is not exactly one:
  /// oversized, not JSON, not an object, another version, a field of the
  /// wrong type, length or spelling.
  static CodeRequest? tryParse(Uint8List raw) {
    final json = _object(raw, InternetCode.maxRequestBytes);
    if (json == null || json['v'] != InternetCode.version) return null;
    final n = CodePake.decode(json['n'], length: InternetCode.nonceLength);
    final pA = CodePake.decode(json['pA'], length: Spake2.shareLength);
    final reply = json['reply'];
    final ts = json['ts'];
    if (n == null || pA == null || ts is! int) return null;
    // A timestamp that cannot be a date this decade is not worth the date
    // arithmetic: it is the cheapest thing in the message to forge.
    if (ts < 0 || ts > _lastSecond) return null;
    if (!InternetCode._isTopic(reply)) return null;
    return CodeRequest(n: n, pA: pA, reply: reply as String, ts: ts);
  }
}

/// `{v, pB, cB}`: the sender's share and its proof of the code.
class CodeReply {
  const CodeReply({required this.pB, required this.cB});

  final Uint8List pB;
  final Uint8List cB;

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode({
        'v': InternetCode.version,
        'pB': InternetCode.encode(pB),
        'cB': InternetCode.encode(cB),
      })));

  static CodeReply? tryParse(Uint8List raw) {
    final json = _object(raw, InternetCode.maxReplyBytes);
    if (json == null || json['v'] != InternetCode.version) return null;
    final pB = CodePake.decode(json['pB'], length: Spake2.shareLength);
    final cB = CodePake.decode(json['cB'], length: CodePake.tagLength);
    if (pB == null || cB == null) return null;
    return CodeReply(pB: pB, cB: cB);
  }

  /// A well-formed reply that speaks another version of this protocol. Told
  /// apart from garbage so that the person is sent to update instead of being
  /// told the code is wrong.
  static bool isOtherVersion(Uint8List raw) {
    final json = _object(raw, InternetCode.maxReplyBytes);
    final v = json?['v'];
    return v is int && v != InternetCode.version;
  }
}

/// The JSON object in [raw], or null. The size is checked before anything is
/// decoded.
Map<String, dynamic>? _object(Uint8List raw, int limit) {
  if (raw.isEmpty || raw.length > limit) return null;
  try {
    final json = jsonDecode(utf8.decode(raw));
    return json is Map<String, dynamic> ? json : null;
  } catch (_) {
    return null;
  }
}

/// The curve arithmetic of the exchange. Each step runs on its own isolate —
/// one scalar multiplication is about five milliseconds, a run does four per
/// side — unless [inline] is set, which a test under a fake clock needs: an
/// isolate's answer arrives on the real event loop, which a fake one never
/// pumps.
class InternetCodePake {
  const InternetCodePake({this.inline = false});

  final bool inline;

  static const String _aad = '${InternetCode.domain}/pake';
  static const String _passwordInfo = '${InternetCode.domain}/password';

  Future<T> _run<T>(T Function() job) =>
      inline ? Future<T>.sync(job) : Isolate.run(job);

  /// The code as a scalar: HKDF to 64 bytes, reduced modulo the group order.
  static BigInt passwordScalar(SessionCode code) {
    final okm = hkdfSha256(
      utf8.encode(code.code),
      info: utf8.encode(_passwordInfo),
      length: 64,
    );
    var v = BigInt.zero;
    for (final byte in okm) {
      v = (v << 8) | BigInt.from(byte);
    }
    return v % Spake2.order;
  }

  /// A and B each carry the domain and `n`. The receiver has no identity the
  /// sender could check and needs none: what it proves is that it knows the
  /// code, in this run.
  static List<int> identityA(List<int> n) =>
      [...utf8.encode('${InternetCode.domain}/A/'), ...n];
  static List<int> identityB(List<int> n) =>
      [...utf8.encode('${InternetCode.domain}/B/'), ...n];

  /// The receiver's first step: its scalar and its share, `pA`.
  Future<Spake2> begin(SessionCode code) => _run(
      () => Spake2.start(role: Spake2Role.a, w: passwordScalar(code)));

  /// The receiver's second step. Throws [Spake2Exception] for a share that is
  /// not a point of the group.
  Future<Spake2Keys> complete(
    Spake2 begun, {
    required Uint8List n,
    required List<int> senderShare,
  }) =>
      _run(() => begun.finish(
            senderShare,
            identityA: identityA(n),
            identityB: identityB(n),
            aad: utf8.encode(_aad),
          ));

  /// The sender's whole run. Throws [Spake2Exception] for a share that is not
  /// a point of the group.
  Future<PakeReply> respond(
    SessionCode code, {
    required Uint8List n,
    required List<int> receiverShare,
  }) =>
      _run(() {
        final b = Spake2.start(role: Spake2Role.b, w: passwordScalar(code));
        final keys = b.finish(
          receiverShare,
          identityA: identityA(n),
          identityB: identityB(n),
          aad: utf8.encode(_aad),
        );
        return PakeReply(b.share, keys);
      });
}

/// What the exchange derives from `Ke` and `n`: the key everything after the
/// proof is sealed under, and the two topics only a holder of the code can
/// name.
class InternetCodeKeys {
  InternetCodeKeys._(this.aeadKey, this.confirmTopic, this.payloadTopic);

  final Uint8List aeadKey;

  /// Where the receiver's confirmation goes, and the sender listens.
  final String confirmTopic;

  /// Where the sender's offer (or refusal) goes, and the receiver listens.
  final String payloadTopic;

  factory InternetCodeKeys.derive(Uint8List ke, Uint8List n) {
    Uint8List expand(String label, int length) => hkdfSha256(ke,
        salt: n,
        info: utf8.encode('${InternetCode.domain}/$label'),
        length: length);
    return InternetCodeKeys._(
      expand('aead', 32),
      InternetCode.encode(expand('confirm-topic', InternetCode.topicLength)),
      InternetCode.encode(expand('payload-topic', InternetCode.topicLength)),
    );
  }
}

/// Which message a sealed envelope is. Bound into the associated data so that
/// one cannot be replayed as the other.
enum SealRole { confirm, payload, cancel }

/// ChaCha20-Poly1305 over the exchange's messages: `nonce ‖ ciphertext ‖ tag`.
class InternetCodeSeal {
  const InternetCodeSeal._();

  static final _cipher = Chacha20.poly1305Aead();
  static const int _nonceLength = 12;
  static const int _macLength = 16;

  static List<int> _aad(SealRole role, Uint8List n) => [
        ...utf8.encode(
            '${InternetCode.domain}/${role.name}/v${InternetCode.version}/'),
        ...n,
      ];

  static Future<Uint8List> seal({
    required Uint8List key,
    required SealRole role,
    required Uint8List n,
    required List<int> plaintext,
    Random? random,
  }) async {
    final nonce = InternetCode.randomBytes(_nonceLength, random);
    final box = await _cipher.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: nonce,
      aad: _aad(role, n),
    );
    return Uint8List.fromList(
        [...box.nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  /// The plaintext, or null when [envelope] is too short, was altered, was
  /// sealed under another key, for another run or as another message. Never
  /// throws: what arrives on a public topic is not the caller's to trust.
  static Future<Uint8List?> open({
    required Uint8List key,
    required SealRole role,
    required Uint8List n,
    required Uint8List envelope,
  }) async {
    if (envelope.length <= _nonceLength + _macLength) return null;
    try {
      final clear = await _cipher.decrypt(
        SecretBox(
          envelope.sublist(_nonceLength, envelope.length - _macLength),
          nonce: envelope.sublist(0, _nonceLength),
          mac: Mac(envelope.sublist(envelope.length - _macLength)),
        ),
        secretKey: SecretKey(key),
        aad: _aad(role, n),
      );
      return Uint8List.fromList(clear);
    } catch (_) {
      return null;
    }
  }
}
