// What the two halves of the "real remote peer" check share.
//
// `ci_peer_sender.dart` runs on one machine, `ci_peer_receiver.dart` on another,
// and between them is nothing but the public internet: the real Nostr relays,
// the real DirectDrop Worker, the real TURN credentials. Neither half is a
// stand-in for the other, and nothing in this file knows which machine it is
// on, so the check runs in both directions with the same two programs:
//
//     to-runner   a Mac sends (random code, random file), a GitHub runner
//                 receives what `ci-peer/peer.json` says
//     to-mac      a GitHub runner sends (the code and the file's seed come from
//                 `peer.json`, which the Mac wrote), the Mac receives
//
// over the same two pieces:
//
//     CiPeerOfferHost    hosts an offer under a code and hands it to exactly
//                        one named receiver (what the app's internet tab does)
//     ciPeerReceive      types the code, finds the sender, takes the file and
//                        checks it byte for byte (what the code screen does)
//
// Both are built from the same classes the app is built from, with the real
// public services behind them; nothing is replaced in memory. See
// CI_PEER.md for how to run them.
//
// Not named `*_test.dart`, so `flutter test integration_test/` does not pick
// it up.
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:convert/convert.dart' show AccumulatorSink, hex;
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/network/internet_code.dart';
import 'package:quickshare/core/network/internet_code_sender.dart';
import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/core/signaling/answer_channel.dart';
import 'package:quickshare/core/signaling/code_mailbox_factory.dart';
import 'package:quickshare/core/signaling/rendezvous_channels.dart';
import 'package:quickshare/core/signaling/sealed_envelope.dart';
import 'package:quickshare/core/signaling/serverless_qr.dart';
import 'package:quickshare/core/webrtc/compact_sdp.dart';
import 'package:quickshare/core/webrtc/ice_servers.dart';
import 'package:quickshare/core/webrtc/relay_availability.dart';
import 'package:quickshare/core/webrtc/resume/receiver_link.dart';
import 'package:quickshare/core/webrtc/resume/resume_keys.dart';
import 'package:quickshare/features/receiver/data/client/code_lookup.dart';
import 'package:quickshare/features/receiver/data/client/code_search.dart';
import 'package:quickshare/features/receiver/data/client/code_session_resolver.dart';
import 'package:quickshare/features/receiver/data/qr/qr_payload_decoder.dart';
import 'package:quickshare/features/receiver/data/transports/webrtc_receiver_transport.dart';
import 'package:quickshare/features/sender/data/transports/webrtc_transfer_transport.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';
import 'package:quickshare/features/sender/domain/entities/transfer_session.dart';

// ─── Settings ──────────────────────────────────────────────────────────────

/// Every setting, read from `--dart-define`. The names are the same for both
/// directions of the check: a define says what the check is about, not which
/// machine it is on.
abstract final class CiPeerDefines {
  /// The ten digits. Receiver: the ones it types. Sender: only in the mode where
  /// the code is given (see [seed]); otherwise the sender makes one up.
  static const String code = String.fromEnvironment('CI_PEER_CODE');

  /// The device name the receiver announces to the sender. Receiver only.
  static const String name = String.fromEnvironment('CI_PEER_NAME');

  /// The one device name the sender will hand its offer to. Sender only.
  static const String expectName =
      String.fromEnvironment('CI_PEER_EXPECT_NAME');

  /// How big the file is. The sender makes one this size (default 50 MiB, but
  /// the mode where the code is given has no default); the receiver refuses
  /// anything else.
  static const int bytes =
      int.fromEnvironment('CI_PEER_BYTES', defaultValue: -1);

  /// SHA-256 of the file, hex. Receiver only, and only when it is not given a
  /// [seed] to work the hash out from.
  static const String sha256Hex = String.fromEnvironment('CI_PEER_SHA256');

  /// 64 hex digits that stand for the whole file: the bytes are
  /// [ciPeerSeededBlocks] of it. When the machine that picks the code is also
  /// the one that receives, it picks this too and works out the hash itself.
  ///
  /// Sender: given together with [code], [expectName] and [bytes], it makes the
  /// sender offer exactly that file under exactly that code, and not a random
  /// one under a code of its own. Receiver: given instead of [sha256Hex].
  static const String seed = String.fromEnvironment('CI_PEER_SEED');

  /// Where the sender writes `{code, bytes, sha256, ...}` and, in the end, its
  /// result. Empty: a file in the system temporary folder, whose path is
  /// printed. Not used where the code is given.
  static const String out = String.fromEnvironment('CI_PEER_OUT');

  /// How long the sender waits for a receiver to connect, from the moment its
  /// code is printed. The runner needs time to build.
  static const int waitMinutes =
      int.fromEnvironment('CI_PEER_WAIT_MINUTES', defaultValue: 40);

  /// How long a transfer may take once the receiver has connected.
  static const int transferMinutes =
      int.fromEnvironment('CI_PEER_TRANSFER_MINUTES', defaultValue: 20);

  /// How old an offer may get before the sender builds a fresh one *under the
  /// same code*. The app does this every `sessionCodeLifetime` too — but it
  /// changes the code as well, which is the one thing this check must not do.
  /// An offer carries relay candidates and credentials that live for a limited
  /// time, so one held for forty minutes would test the clock, not the app.
  static const int offerRefreshSeconds = int.fromEnvironment(
      'CI_PEER_OFFER_REFRESH_SECONDS',
      defaultValue: 300 /* AppConstants.sessionCodeLifetime */);

  /// The receiver's search is tried this many times before it gives up; a
  /// search that finds nothing is retyped, as a person would. Ignored when
  /// [findMinutes] says how long to search instead.
  static const int findAttempts =
      int.fromEnvironment('CI_PEER_FIND_ATTEMPTS', defaultValue: 5);

  /// How long the receiver keeps searching, retyping the code each time a
  /// search finds nothing, for a sender that is not up yet (the other machine
  /// is still building). Zero: not that; [findAttempts] searches instead. A
  /// receiver given a [seed] searches for [defaultSeededFindMinutes] unless
  /// told otherwise, because a seed means the sender is somebody else's job
  /// that has not started.
  static const int findMinutes =
      int.fromEnvironment('CI_PEER_FIND_MINUTES', defaultValue: 0);

  /// Sender-only physical recovery probe. Zero leaves the link untouched.
  static const int interruptBytes =
      int.fromEnvironment('CI_PEER_INTERRUPT_BYTES', defaultValue: 0);

  static const int defaultBytes = 50 * 1024 * 1024;
  static const int defaultSeededFindMinutes = 40;

  static const Duration waitFor = Duration(minutes: waitMinutes);
  static const Duration transferFor = Duration(minutes: transferMinutes);
  static const Duration offerLifetime = Duration(seconds: offerRefreshSeconds);

  /// How long the receiver searches, or null for [findAttempts] searches.
  static const Duration? findFor = findMinutes > 0
      ? Duration(minutes: findMinutes)
      : (seed != '' ? Duration(minutes: defaultSeededFindMinutes) : null);
}

// ─── Small, pure helpers (covered by test/integration/ci_peer_support_test) ──

/// Whether [announced] is the device [expected] named, after the same cleaning
/// the sender applies to every name that comes out of the public mailbox.
bool ciPeerNameMatches(String expected, String announced) {
  final want = InternetCode.cleanName(expected);
  return want.isNotEmpty && want == InternetCode.cleanName(announced);
}

/// What is wrong with the receiver's settings, one sentence each. Empty means
/// the receiver can start.
///
/// The file is described either by its [sha256Hex] or by a [seedHex] it is made
/// from, and by both is an error: two descriptions that could disagree are one
/// too many.
List<String> ciPeerReceiverProblems({
  required String code,
  required String name,
  required int bytes,
  required String sha256Hex,
  String seedHex = '',
}) =>
    [
      if (SessionCode.parse(code) == null)
        'CI_PEER_CODE is not a ten-digit code',
      if (InternetCode.cleanName(name).isEmpty) 'CI_PEER_NAME is empty',
      if (bytes <= 0) 'CI_PEER_BYTES is missing or not a positive number',
      if (seedHex.isNotEmpty && sha256Hex.isNotEmpty)
        'give CI_PEER_SHA256 or CI_PEER_SEED, not both'
      else if (seedHex.isNotEmpty && !_isHex64(seedHex))
        'CI_PEER_SEED is not 64 hex digits'
      else if (seedHex.isEmpty && !_isHex64(sha256Hex))
        'CI_PEER_SHA256 is not 64 hex digits',
    ];

/// What is wrong with the settings of a sender that is *given* its code and its
/// file: the mode of the runner that sends to a Mac. Empty means it can start.
List<String> ciPeerGivenSenderProblems({
  required String code,
  required String expectName,
  required int bytes,
  required String seedHex,
}) =>
    [
      if (SessionCode.parse(code) == null)
        'CI_PEER_CODE is not a ten-digit code',
      if (InternetCode.cleanName(expectName).isEmpty)
        'CI_PEER_EXPECT_NAME is empty',
      if (bytes <= 0) 'CI_PEER_BYTES is missing or not a positive number',
      if (!_isHex64(seedHex)) 'CI_PEER_SEED is not 64 hex digits',
    ];

bool _isHex64(String text) => RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(text);

/// Whether a search that has come up empty should be typed again: after
/// [attempt] searches and [elapsed] since the first, with [pause] to wait
/// before the next. With [findFor] it is time that decides, and the next search
/// must be able to start before the time is up; without, it is [findAttempts].
bool ciPeerMaySearchAgain({
  required int attempt,
  required Duration elapsed,
  required int findAttempts,
  required Duration pause,
  Duration? findFor,
}) =>
    findFor != null ? elapsed + pause < findFor : attempt < findAttempts;

/// [text] as something safe to put in a log or a summary: it came from the
/// other end, so anything but plain characters becomes `?`.
String ciPeerPlainText(String text) {
  final plain = text.replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '?');
  return plain.length <= 80 ? plain : plain.substring(0, 80);
}

/// Speed of [bytes] moved in [took], in the two units people compare.
({double mibPerSecond, double mbitPerSecond}) ciPeerSpeed(
    int bytes, Duration took) {
  final seconds = took.inMicroseconds / Duration.microsecondsPerSecond;
  if (seconds <= 0) return (mibPerSecond: 0, mbitPerSecond: 0);
  return (
    mibPerSecond: bytes / seconds / (1024 * 1024),
    mbitPerSecond: bytes * 8 / seconds / 1e6,
  );
}

/// Writes [bytes] random bytes to [file] and returns their SHA-256, hex. The
/// file is streamed, never held whole, and random: a file that compresses
/// would measure the compressor and not the path.
Future<String> ciPeerWriteRandomFile(File file, int bytes, {Random? random}) {
  // Cryptographically random only to pick the seed: one native call per byte
  // would be the slowest part of the whole check.
  final source = random ?? Random(Random.secure().nextInt(1 << 32));
  Iterable<Uint8List> blocks() sync* {
    const block = 1024 * 1024;
    var left = bytes;
    while (left > 0) {
      final size = min(block, left);
      final chunk = Uint8List(size);
      final view = ByteData.sublistView(chunk);
      var i = 0;
      for (; i + 4 <= size; i += 4) {
        view.setUint32(i, source.nextInt(1 << 32));
      }
      for (; i < size; i++) {
        chunk[i] = source.nextInt(256);
      }
      yield chunk;
      left -= size;
    }
  }

  return _writeAndHash(file, blocks());
}

/// Writes the file [seedHex] stands for, [bytes] long, and returns its SHA-256.
/// Two machines given the same seed and size write the same bytes.
Future<String> ciPeerWriteSeededFile(File file, int bytes, String seedHex) =>
    _writeAndHash(file, ciPeerSeededBlocks(seedHex, bytes));

/// SHA-256, hex, of the file [seedHex] stands for, without writing it: what the
/// machine that picked the seed expects to receive.
Future<String> ciPeerSeededSha256(int bytes, String seedHex) async {
  final digest = AccumulatorSink<Digest>();
  final hash = sha256.startChunkedConversion(digest);
  for (final block in ciPeerSeededBlocks(seedHex, bytes)) {
    hash.add(block);
    // 50 MiB takes a few seconds; the event loop is not held for all of them.
    await Future<void>.delayed(Duration.zero);
  }
  hash.close();
  return digest.events.single.toString();
}

/// The bytes of the file that [seedHex] (64 hex digits, 32 bytes) stands for,
/// [bytes] long, in blocks of [blockSize].
///
/// Block `i` of 32 bytes is `SHA-256("directdrop-ci-peer-file-v1" || seed ||
/// i)`, with `i` as eight bytes, big-endian; the file is the blocks one after
/// another, cut at [bytes]. Chosen because anybody can check it with nothing
/// but a SHA-256 tool and because it is not compressible: a file that
/// compresses would measure the compressor and not the path.
///
/// The seed is not a secret (it is in a public repository next to the code),
/// and the file is worth nothing to anyone.
Iterable<Uint8List> ciPeerSeededBlocks(String seedHex, int bytes,
    {int blockSize = 1024 * 1024}) sync* {
  if (!_isHex64(seedHex)) {
    throw ArgumentError.value(seedHex, 'seedHex', 'not 64 hex digits');
  }
  if (blockSize <= 0 || blockSize % 32 != 0) {
    throw ArgumentError.value(
        blockSize, 'blockSize', 'must be a multiple of 32');
  }
  final prefix = utf8.encode(ciPeerSeedDomain);
  final seed = hex.decode(seedHex.toLowerCase());
  final input = Uint8List(prefix.length + seed.length + 8)
    ..setRange(0, prefix.length, prefix)
    ..setRange(prefix.length, prefix.length + seed.length, seed);
  final counter = ByteData.sublistView(input, prefix.length + seed.length);
  var index = 0;
  var left = bytes;
  while (left > 0) {
    final size = min(blockSize, left);
    final chunk = Uint8List(size);
    for (var at = 0; at < size; at += 32) {
      counter.setUint64(0, index++);
      final block = sha256.convert(input).bytes;
      chunk.setRange(at, min(at + 32, size), block);
    }
    yield chunk;
    left -= size;
  }
}

/// What the seeded file's blocks are hashed under; see [ciPeerSeededBlocks].
const String ciPeerSeedDomain = 'directdrop-ci-peer-file-v1';

/// Writes [blocks] to [file] one at a time and returns their SHA-256, hex.
Future<String> _writeAndHash(File file, Iterable<Uint8List> blocks) async {
  final digest = AccumulatorSink<Digest>();
  final hash = sha256.startChunkedConversion(digest);
  final sink = file.openWrite();
  try {
    for (final chunk in blocks) {
      sink.add(chunk);
      hash.add(chunk);
      await sink.flush();
    }
    hash.close();
  } finally {
    await sink.close();
  }
  return digest.events.single.toString();
}

/// SHA-256 of [file], hex, read as a stream.
Future<String> ciPeerHashFile(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

/// Appends [markdown] to the GitHub Actions step summary, when there is one.
/// False when there is none or it could not be written (a sandboxed app may
/// not reach the runner's file; the workflow then writes the summary itself).
Future<bool> ciPeerAppendStepSummary(String markdown,
    {Map<String, String>? environment}) async {
  final path = (environment ?? Platform.environment)['GITHUB_STEP_SUMMARY'];
  if (path == null || path.isEmpty) return false;
  try {
    await File(path)
        .writeAsString('$markdown\n', mode: FileMode.append, flush: true);
    return true;
  } catch (e) {
    print('CI_PEER the step summary could not be written (${e.runtimeType})');
    return false;
  }
}

/// How one side of the check ended, in a form that goes to a log, to a JSON
/// file and to a step summary alike.
class CiPeerReport {
  CiPeerReport(this.role);

  /// `sender` or `receiver`.
  final String role;

  /// `running`, `success`, `failure` or `timeout`.
  String status = 'running';
  String? error;
  final Map<String, Object?> fields = {};

  bool get succeeded => status == 'success';

  Map<String, Object?> toJson() => {
        'role': role,
        'status': status,
        if (error != null) 'error': error,
        ...fields,
      };

  /// One line per fact, `key: value`, in the order they were recorded.
  List<String> lines() => [
        for (final e in toJson().entries)
          if (e.value != null) '${e.key}: ${e.value}',
      ];

  String markdown({String? title}) {
    final head = title ?? 'DirectDrop remote peer check ($role)';
    final icon = succeeded ? 'OK' : 'FAILED';
    final buffer = StringBuffer()
      ..writeln('### $head: $icon')
      ..writeln()
      ..writeln('| | |')
      ..writeln('|---|---|');
    for (final e in toJson().entries) {
      if (e.value == null) continue;
      final value = '${e.value}'.replaceAll('|', r'\|').replaceAll('\n', ' ');
      buffer.writeln('| ${e.key} | $value |');
    }
    return buffer.toString();
  }
}

/// `CI_PEER <elapsed> <role> <what>`, flushed at once: these lines are what a
/// person watching a terminal or a CI log reads.
void Function(String) ciPeerLogger(String role) {
  final clock = Stopwatch()..start();
  return (line) {
    final s = (clock.elapsedMilliseconds / 1000).toStringAsFixed(1);
    print('CI_PEER +${s}s $role $line');
  };
}

/// The relay policy this build runs with, which says whether
/// `QUICKSHARE_FORCE_RELAY` took effect.
String ciPeerRelayPolicy() => IceServers.transportPolicy();

// ─── The sender ────────────────────────────────────────────────────────────

/// One offer: a peer connection with its data channel, the sealed drop point
/// its answer will arrive on, and the QR string a receiver is handed.
class _Offer {
  _Offer({
    required this.transport,
    required this.channel,
    required this.qr,
    required this.subscriptions,
  }) : builtAt = DateTime.now();

  final WebRtcTransferTransport transport;
  final AnswerChannel channel;
  final String qr;
  final DateTime builtAt;
  final List<StreamSubscription<Object?>> subscriptions;

  Future<void> close() async {
    for (final s in subscriptions) {
      unawaited(s.cancel());
    }
    subscriptions.clear();
    try {
      await channel.close();
    } catch (_) {}
    try {
      await transport.stopSharing();
    } catch (_) {}
  }
}

/// Hosts an offer for [file] under [code] on the real public services, and
/// hands it to exactly one receiver: the one that announces [expectName].
///
/// What the app's internet tab does, with the one thing it must not do taken
/// out: the code never changes. Everything else an offer is is rebuilt every
/// [offerLifetime], as the app rebuilds it — see
/// [CiPeerDefines.offerRefreshSeconds] — because the offer, not the code, is
/// what goes stale.
///
/// A name is no secret (it will sit in a public repository next to the code),
/// so this keeps out the receiver that was not meant, not the one that read
/// the repository; and there is only ever one: once a receiver is accepted,
/// every other is refused, and the code stops answering the moment its answer
/// arrives. The file is random bytes and worth nothing.
class CiPeerOfferHost {
  CiPeerOfferHost({
    required this.file,
    required this.code,
    required this.expectName,
    required this.waitFor,
    required this.transferFor,
    required this.offerLifetime,
    this.answerWait = const Duration(minutes: 2),
    this.quietAfterRequest = const Duration(seconds: 45),
    this.interruptBytes = 0,
    void Function(String)? log,
  }) : _log = log ?? ciPeerLogger('sender');

  final FileMetadata file;
  final SessionCode code;
  final String expectName;

  /// How long to wait for a receiver to be accepted and to answer.
  final Duration waitFor;

  /// How long the transfer may take once the answer is in.
  final Duration transferFor;

  /// How old an offer may get before it is replaced under the same code.
  final Duration offerLifetime;

  /// How long an accepted receiver has to deliver its answer.
  final Duration answerWait;

  /// A request seen this recently means an exchange may be in flight, and the
  /// listener is not replaced under it.
  final Duration quietAfterRequest;

  /// Zero disables fault injection; otherwise cut the native sender link once.
  final int interruptBytes;
  final void Function(String) _log;
  final CiPeerReport report = CiPeerReport('sender');

  final _done = Completer<void>();
  final _holds = <Object>{};
  final _refused = <String>[];
  final _clock = Stopwatch();
  Stopwatch? _transfer;
  Stopwatch? _connect;
  Timer? _tickTimer;
  Timer? _answerTimer;
  Timer? _transferTimer;

  _Offer? _current;
  _Offer? _committed;

  /// Every offer built and not yet closed, so that none is left standing
  /// whichever way a refresh ends.
  final _live = <_Offer>{};
  InternetCodeSender? _sender;
  String? _approvedName;
  DateTime _lastRequestAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _seenAttempts = 0;
  int _offersBuilt = 0;
  bool _refreshing = false;
  int _loggedDecile = 0;
  bool _interruptionRequested = false;
  bool _sawReconnecting = false;
  bool _sawResumedTransfer = false;
  late DateTime _deadline;

  bool get _ended => _done.isCompleted;

  /// Runs until a receiver has been served, the wait has run out, or something
  /// has failed; never throws. [onListening] is called once the code answers
  /// requests — the moment it may be shown.
  Future<CiPeerReport> run({FutureOr<void> Function()? onListening}) async {
    _clock.start();
    report.fields['relay_policy'] = ciPeerRelayPolicy();
    try {
      if (interruptBytes < 0 || interruptBytes >= file.size) {
        throw ArgumentError(
            'interrupt threshold must be zero or below file size');
      }
      _current = await _buildOffer();
      await _listen();
      _deadline = DateTime.now().add(waitFor);
      _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
      await onListening?.call();
      _log('waiting up to ${waitFor.inMinutes} min for "$expectName"; '
          'the offer is rebuilt every ${offerLifetime.inSeconds}s under the '
          'same code');
      await _done.future;
    } catch (e, st) {
      _finish('failure', 'the sender could not start: $e');
      _log('start-up failure: $e\n$st');
    }
    await _shutdown();
    return report;
  }

  // ── What the app builds for the internet tab ──

  /// Mirrors `SenderBloc._startInternetOffer` and `_prepareServerlessQr`: a
  /// peer connection and its offer, then the sealed drop point the answer will
  /// arrive on, subscribed before the offer goes anywhere.
  Future<_Offer> _buildOffer() async {
    final transport = WebRtcTransferTransport();
    await transport.initialize();
    final subs = <StreamSubscription<Object?>>[];
    AnswerChannel? channel;
    try {
      subs
        ..add(transport.statusStream.listen((s) => _onStatus(transport, s)))
        ..add(transport.progressStream.listen((v) => _onProgress(transport, v)))
        ..add(transport.noUsablePath.listen((d) => _onNoPath(transport, d)))
        ..add(transport.relayBlockedStream
            .listen((b) => _onRelayBlocked(transport, b)));

      await transport.startSharingServerless(file, files: [file]);
      final sdp = await transport.createLocalOfferSdp();
      if (sdp == null || sdp.isEmpty) {
        throw StateError('WebRTC produced no local offer');
      }
      final qr = ServerlessQr(
        seed: SealedEnvelope.newSeed(),
        offer: ServerlessQr.trimForQr(CompactSdp.fromSdp(sdp)),
        fileName: file.name,
        fileSize: file.size,
        itemCount: 1,
      );
      transport.configureResume(ResumeSetup(
        keys: ResumeKeys.derive(
            seed: qr.seed, offerFingerprint: qr.offerFingerprint),
        mailboxFactory: buildCodeMailbox,
      ));
      final topic = await qr.topic;
      channel = buildRendezvousChannel(
        acceptPayload: (sealed) async {
          try {
            await SealedEnvelope.open(
              envelope: sealed,
              seed: qr.seed,
              offerFingerprint: qr.offerFingerprint,
            );
            return true;
          } catch (_) {
            return false;
          }
        },
      );
      await channel.subscribe(topic);
      final offer = _Offer(
        transport: transport,
        channel: channel,
        qr: qr.encode(),
        subscriptions: subs,
      );
      subs.add(channel.answers.listen((sealed) {
        unawaited(_onAnswer(offer, qr, sealed));
      }));
      _offersBuilt++;
      _live.add(offer);
      _log('offer #$_offersBuilt ready: ${qr.offer.candidates.length} '
          'candidates, answers on ${channel.name}');
      return offer;
    } catch (_) {
      for (final s in subs) {
        unawaited(s.cancel());
      }
      try {
        await channel?.close();
      } catch (_) {}
      try {
        await transport.stopSharing();
      } catch (_) {}
      rethrow;
    }
  }

  /// Starts answering requests for the code with whatever offer is current.
  /// Mirrors `SenderBloc._startCodeRendezvous`; the same real mailbox.
  Future<void> _listen() async {
    final sender = InternetCodeSender(
      mailbox: buildCodeMailbox(),
      code: code,
      // Read when a receiver is accepted, not before: the offer replaced since
      // is the one that is handed out.
      offer: () async => _current?.qr,
      approve: _approve,
      hold: _holds.add,
      release: _holds.remove,
    );
    await sender.start();
    _sender = sender;
    _seenAttempts = 0;
  }

  Future<void> _stopListening() async {
    final sender = _sender;
    _sender = null;
    await sender?.stop();
  }

  Future<void> _closeOffer(_Offer offer) {
    _live.remove(offer);
    return offer.close();
  }

  // ── The one receiver ──

  Future<bool> _approve(String announced) async {
    final shown = jsonEncode(announced);
    if (_approvedName != null) {
      _log('refused $shown: a receiver was already accepted');
      return false;
    }
    if (!ciPeerNameMatches(expectName, announced)) {
      if (_refused.length < 5) _refused.add(announced);
      _log('refused $shown: not the receiver this check is for');
      report.fields['refused'] = List<String>.of(_refused);
      return false;
    }
    _approvedName = announced;
    _connect = Stopwatch()..start();
    _log('accepted $shown; handing it the offer');
    _answerTimer = Timer(answerWait, () {
      if (_committed == null) {
        _finish('failure',
            'the accepted receiver never answered within ${answerWait.inSeconds}s');
      }
    });
    return true;
  }

  Future<void> _onAnswer(
      _Offer offer, ServerlessQr qr, Uint8List sealed) async {
    if (_committed != null || _ended) return;
    final Uint8List opened;
    try {
      opened = await SealedEnvelope.open(
        envelope: sealed,
        seed: qr.seed,
        offerFingerprint: qr.offerFingerprint,
      );
    } catch (_) {
      // Public topics carry other people's traffic.
      return;
    }
    if (_committed != null || _ended) return;
    _committed = offer;
    _answerTimer?.cancel();
    // As the app does when the answer opens: the offer is taken, so the code
    // answers nobody else from here.
    _sender?.answered();
    unawaited(_stopListening());
    report.fields['receiver_name'] = _approvedName;
    report.fields['waited_seconds'] =
        (_clock.elapsedMilliseconds / 1000).round();
    _log('the sealed answer opened; applying it');
    try {
      await offer.transport.handleDirectAnswer(
          CompactSdp.fromBytes(opened).toSdp(isOffer: false), 'answer');
    } catch (e) {
      _finish('failure', 'applying the receiver\'s answer failed: $e');
      return;
    }
    _transferTimer = Timer(transferFor, () {
      _finish('timeout',
          'the transfer did not finish within ${transferFor.inMinutes} min of the answer');
    });
  }

  // ── What the committed transport says ──

  bool _isCommitted(WebRtcTransferTransport transport) =>
      !_ended && identical(_committed?.transport, transport);

  void _onStatus(WebRtcTransferTransport transport, TransferStatus status) {
    if (!_isCommitted(transport)) return;
    _log('transport: ${status.name}');
    switch (status) {
      case TransferStatus.transferring:
        if (_sawReconnecting && !_sawResumedTransfer) {
          _sawResumedTransfer = true;
          print('CI_PEER_RECOVERY_RESUMED');
        }
        _transfer ??= Stopwatch()..start();
        if (_connect != null && report.fields['connect_seconds'] == null) {
          report.fields['connect_seconds'] =
              (_connect!.elapsedMilliseconds / 1000).toStringAsFixed(1);
        }
      case TransferStatus.reconnecting:
        if (_interruptionRequested) {
          _sawReconnecting = true;
          print('CI_PEER_RECOVERY_RECONNECTING');
        }
      case TransferStatus.completed:
        if (interruptBytes > 0 &&
            (!_interruptionRequested ||
                !_sawReconnecting ||
                !_sawResumedTransfer)) {
          _finish('failure',
              'recovery probe did not observe interruption, reconnecting and resumed transfer');
        } else if (interruptBytes > 0 &&
            ciPeerRelayPolicy() == 'relay' &&
            transport.lastIcePath?.name != 'relayed') {
          _finish(
              'failure', 'replacement link did not report a relayed ICE path');
        } else {
          if (interruptBytes > 0) print('CI_PEER_RECOVERY_COMPLETE');
          _finish('success');
        }
      case TransferStatus.failed:
        _finish('failure', 'the transport reported a failed transfer');
      case TransferStatus.cancelled:
      case TransferStatus.timedOut:
        _finish('failure', 'the transport ended the session: ${status.name}');
      default:
        break;
    }
  }

  void _onProgress(WebRtcTransferTransport transport, double fraction) {
    if (!_isCommitted(transport)) return;
    final bytesSent = (file.size * fraction).floor();
    if (interruptBytes > 0 &&
        !_interruptionRequested &&
        bytesSent >= interruptBytes &&
        fraction < 1) {
      _interruptionRequested = true;
      report.fields['interrupt_at_bytes'] = bytesSent;
      report.fields['ice_path_before_interrupt'] = transport.lastIcePath?.name;
      report.fields['ice_pair_before_interrupt'] = transport.lastIcePair;
      print('CI_PEER_RECOVERY_INTERRUPT bytes=$bytesSent');
      unawaited(transport.interruptLinkForTest().catchError((Object e) {
        _finish('failure', 'interrupting native link failed: $e');
      }));
    }
    final decile = (fraction * 10).floor();
    if (decile <= _loggedDecile) return;
    _loggedDecile = decile;
    final watch = _transfer;
    final rate = watch == null
        ? ''
        : ' (${ciPeerSpeed((file.size * fraction).round(), watch.elapsed).mibPerSecond.toStringAsFixed(2)} MiB/s so far)';
    _log('sent ${decile * 10}%$rate');
  }

  void _onNoPath(WebRtcTransferTransport transport, NoPathDiagnosis d) {
    if (!_isCommitted(transport)) return;
    _finish('failure', d.summary);
  }

  void _onRelayBlocked(
      WebRtcTransferTransport transport, RelayLimitExceeded b) {
    if (!_isCommitted(transport)) return;
    _finish('failure', 'refused to send over the relay: $b');
  }

  // ── Keeping the offer fresh, and the clock ──

  void _tick() {
    if (_ended) return;
    final now = DateTime.now();

    final sender = _sender;
    if (sender != null && sender.attempts != _seenAttempts) {
      _seenAttempts = sender.attempts;
      _lastRequestAt = now;
    }

    if (_committed == null && _approvedName == null && now.isAfter(_deadline)) {
      _finish('timeout',
          'no receiver connected within ${waitFor.inMinutes} minutes of the code being shown');
      return;
    }

    if (_committed != null || _approvedName != null) return;
    if (_refreshing || _holds.isNotEmpty) return;
    final current = _current;
    if (current == null || now.difference(current.builtAt) < offerLifetime) {
      return;
    }
    if (now.difference(_lastRequestAt) < quietAfterRequest) return;
    unawaited(_refresh());
  }

  /// Replaces the offer under the same code, as `_rotateInternet` replaces it
  /// under a new one. The new offer is built before anything is taken down, so
  /// the code stops answering only for as long as it takes to swap the
  /// listener.
  Future<void> _refresh() async {
    _refreshing = true;
    _Offer? fresh;
    try {
      _log('the offer is ${offerLifetime.inSeconds}s old; building a fresh one '
          'under the same code');
      fresh = await _buildOffer();
      // A receiver may have turned up while that was being built.
      if (_ended ||
          _committed != null ||
          _approvedName != null ||
          _holds.isNotEmpty) {
        await _closeOffer(fresh);
        return;
      }
      final old = _current;
      _current = fresh;
      fresh = null;
      await _stopListening();
      await _listenWithRetries();
      if (old != null) await _closeOffer(old);
      _log('offer replaced; same code');
    } catch (e) {
      _log('refreshing the offer failed: $e');
      if (fresh != null) await _closeOffer(fresh);
      if (_sender == null && !_ended) {
        _finish('failure',
            'the code stopped answering and could not be restored: $e');
      }
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _listenWithRetries() async {
    Object? last;
    for (var i = 0; i < 3; i++) {
      try {
        await _listen();
        return;
      } catch (e) {
        last = e;
        await Future<void>.delayed(const Duration(seconds: 3));
      }
    }
    throw StateError('the public mailbox could not be reached again: $last');
  }

  // ── The end ──

  void _finish(String status, [String? error]) {
    if (_ended) return;
    report.status = status;
    report.error = error;
    final transport = _committed?.transport;
    report.fields['ice_path'] = transport?.lastIcePath?.name;
    report.fields['ice_pair'] = transport?.lastIcePair;
    report.fields['offers_built'] = _offersBuilt;
    if (interruptBytes > 0) {
      report.fields['recovery_interrupted'] = _interruptionRequested;
      report.fields['recovery_reconnecting'] = _sawReconnecting;
      report.fields['recovery_resumed'] = _sawResumedTransfer;
    }
    final watch = _transfer;
    if (watch != null) {
      final took = watch.elapsed;
      final speed = ciPeerSpeed(file.size, took);
      report.fields['transfer_seconds'] =
          (took.inMilliseconds / 1000).toStringAsFixed(1);
      if (status == 'success') {
        report.fields['speed_mib_s'] = speed.mibPerSecond.toStringAsFixed(2);
        report.fields['speed_mbit_s'] = speed.mbitPerSecond.toStringAsFixed(1);
      }
    }
    report.fields['total_seconds'] =
        (_clock.elapsedMilliseconds / 1000).round();
    if (status == 'success') {
      // The sender knows what it sent and that the transport finished. That
      // the bytes arrived whole is for the receiver to say.
      report.fields['verified_by'] =
          'the receiver (compares size and SHA-256); see its summary';
    }
    _log('finished: $status${error == null ? '' : ' ($error)'}');
    _done.complete();
  }

  Future<void> _shutdown() async {
    _tickTimer?.cancel();
    _answerTimer?.cancel();
    _transferTimer?.cancel();
    await _stopListening();
    for (final offer in _live.toList()) {
      await _closeOffer(offer);
    }
  }
}

// ─── The receiver ──────────────────────────────────────────────────────────

/// How the receiver looks for a sender once: by default what the code screen
/// does, [CodeLookup.find]. A parameter so that the way a search that breaks,
/// finds nothing or is refused is dealt with can be tested without the network.
typedef CiPeerLookup = Future<CodeSessionOutcome> Function(
    SessionCode code, String deviceName, CodeSearchControl control);

Future<CodeSessionOutcome> _lookInTheApp(
        SessionCode code, String deviceName, CodeSearchControl control) =>
    CodeLookup(deviceName: deviceName).find(code, control: control);

/// Finds the sender of [code] the way the code screen does (the local network
/// and the internet together), takes the file it offers, and checks it against
/// [expectedBytes] and [expectedSha256]. Never throws: every way it can end,
/// including every mismatch, is a `failure` in the returned report.
///
/// A search that finds nothing is typed again after [findPause]: [findAttempts]
/// times, or, when [findFor] is given, for as long as that, which is how a
/// receiver waits for a sender that is still being built on another machine.
/// A search that *breaks* (the VPN dropped the relays for a minute) is the same
/// as one that found nothing: it is retried, not fatal. What does end the
/// search at once is an answer: a sender that declines this device, or one that
/// speaks another version.
Future<CiPeerReport> ciPeerReceive({
  required SessionCode code,
  required String name,
  required int expectedBytes,
  required String expectedSha256,
  required Directory destination,
  int findAttempts = 5,
  Duration? findFor,
  Duration findPause = const Duration(seconds: 10),
  Duration transferFor = const Duration(minutes: 20),
  CiPeerLookup lookup = _lookInTheApp,
  void Function(String)? log,
}) async {
  final say = log ?? ciPeerLogger('receiver');
  final report = CiPeerReport('receiver')
    ..fields['relay_policy'] = ciPeerRelayPolicy()
    ..fields['device_name'] = name
    ..fields['bytes_expected'] = expectedBytes
    ..fields['sha256_expected'] = expectedSha256.toLowerCase();
  final clock = Stopwatch()..start();
  WebRtcReceiverTransport? transport;
  AnswerChannel? channel;

  void fail(String why) {
    if (report.status == 'running') {
      report.status = 'failure';
      report.error = why;
    }
    say('FAILED: $why');
  }

  try {
    // ── 1. Typing the code ──
    String? offerText;
    var lastEnd = 'nothing';
    final budget = findFor == null
        ? '$findAttempts searches'
        : findFor.inSeconds < 120
            ? '${findFor.inSeconds}s of searching'
            : '${findFor.inMinutes} min of searching';
    for (var attempt = 1; offerText == null; attempt++) {
      final control = CodeSearchControl();
      final phases =
          control.phases.listen((phase) => say('search: ${phase.name}'));
      final search = Stopwatch()..start();
      CodeSessionOutcome outcome;
      try {
        outcome = await lookup(code, name, control);
        lastEnd = outcome.runtimeType.toString();
      } catch (e) {
        // A search that broke has found nothing; whether that is the end is
        // for the budget to say, as for a search that came back empty.
        outcome = const CodeSessionNotFound();
        lastEnd = 'a search that broke (${e.runtimeType})';
      } finally {
        await phases.cancel();
        await control.dispose();
      }
      say('search $attempt: $lastEnd '
          'after ${(search.elapsedMilliseconds / 1000).toStringAsFixed(1)}s '
          '(${(clock.elapsedMilliseconds / 1000).toStringAsFixed(0)}s in)');
      report.fields['find_attempts'] = attempt;
      if (outcome is CodeSessionFoundOnline) {
        offerText = outcome.payload;
        report.fields['find_seconds'] =
            (clock.elapsedMilliseconds / 1000).toStringAsFixed(1);
      } else if (outcome is CodeSessionFound) {
        fail('the code was found on the local network, not over the internet; '
            'this check is about the internet path');
        return report;
      } else if (outcome is CodeSessionDeclined) {
        fail('the sender declined this device: its name is not the one the '
            'sender expects, or another receiver was already accepted');
        return report;
      } else if (outcome is CodeSessionUpdateRequired) {
        fail('the sender speaks another version of the code protocol');
        return report;
      } else {
        if (!ciPeerMaySearchAgain(
          attempt: attempt,
          elapsed: clock.elapsed,
          findAttempts: findAttempts,
          pause: findPause,
          findFor: findFor,
        )) {
          break;
        }
        await Future<void>.delayed(findPause);
      }
    }
    if (offerText == null) {
      fail('no sender answered the code in $budget (the last search ended in '
          '$lastEnd)');
      return report;
    }

    // ── 2. What the offer says, before anything is accepted ──
    final payload = QRPayloadDecoder().decode(offerText);
    if (payload.mode != QRPayloadDecoder.serverlessMode) {
      fail('the offer is not an internet (WebRTC) offer: ${payload.mode}');
      return report;
    }
    report.fields['offered_file'] = ciPeerPlainText(payload.fileName);
    report.fields['bytes_offered'] = payload.fileSize;
    if (payload.fileSize != expectedBytes || payload.itemCount != 1) {
      fail('the offer announces ${payload.itemCount} item(s) of '
          '${payload.fileSize} bytes; expected one of $expectedBytes');
      return report;
    }

    // ── 3. What ReceiverBloc._runServerlessTransfer does ──
    final qr = ServerlessQr.decode(payload.sdpOffer!);
    final topic = await qr.topic;
    final drop = buildRendezvousChannel();
    channel = drop;
    final receiving = WebRtcReceiverTransport();
    transport = receiving;
    final transfer = Stopwatch();
    var sawReconnect = false;
    var sawResume = false;
    final progress = receiving.progressStream.listen((e) {
      if (e.phase == 'reconnecting') {
        sawReconnect = true;
        print('CI_PEER_RECOVERY_RECEIVER_RECONNECTING');
      } else if (sawReconnect && !sawResume && e.phase == 'transferring') {
        sawResume = true;
        print('CI_PEER_RECOVERY_RECEIVER_RESUMED');
      }
      if (e.phase == 'transferring' && !transfer.isRunning) {
        transfer.start();
        say('bytes are flowing');
      }
    });
    final connect = Stopwatch()..start();

    final String saved;
    try {
      saved = await receiving.receiveWithSdpOffer(
        qr.offer.toSdp(isOffer: true),
        targetDir: destination.path,
        resume: ResumeSetup(
          keys: ResumeKeys.derive(
              seed: qr.seed, offerFingerprint: qr.offerFingerprint),
          mailboxFactory: buildCodeMailbox,
        ),
        deliverAnswer: (answerSdp) async {
          say('delivering the sealed answer on ${drop.name}');
          await drop.publish(
            topic,
            await SealedEnvelope.seal(
              plaintext: ServerlessQr.trimForQr(CompactSdp.fromSdp(answerSdp))
                  .toBytes(),
              seed: qr.seed,
              offerFingerprint: qr.offerFingerprint,
            ),
          );
        },
      ).timeout(transferFor);
    } on TimeoutException {
      fail('the file did not arrive within ${transferFor.inMinutes} min');
      return report;
    } on IceNegotiationFailed catch (e) {
      fail(e.diagnosis.summary);
      return report;
    } finally {
      await progress.cancel();
    }
    transfer.stop();
    connect.stop();
    final tookTransfer =
        transfer.elapsedMicroseconds > 0 ? transfer.elapsed : connect.elapsed;
    say('the transport says the file is in: $saved');

    // ── 4. No false success: every claim is checked against the disk ──
    final landed = File(saved);
    if (!landed.existsSync()) {
      fail('the transport returned a path that is not a file: $saved');
      return report;
    }
    if (!p.isWithin(destination.path, saved)) {
      fail('the file was written outside the destination: $saved');
      return report;
    }
    final size = landed.lengthSync();
    report.fields['bytes_received'] = size;
    final digest = await ciPeerHashFile(landed);
    report.fields['sha256_received'] = digest;
    final speed = ciPeerSpeed(size, tookTransfer);
    report.fields['transfer_seconds'] =
        (tookTransfer.inMilliseconds / 1000).toStringAsFixed(1);
    report.fields['speed_mib_s'] = speed.mibPerSecond.toStringAsFixed(2);
    report.fields['speed_mbit_s'] = speed.mbitPerSecond.toStringAsFixed(1);
    report.fields['recovery_reconnecting'] = sawReconnect;
    report.fields['recovery_resumed'] = sawResume;
    report.fields['ice_path'] = receiving.lastIcePath?.name;
    report.fields['ice_pair'] = receiving.lastIcePair;

    if (size != expectedBytes) {
      fail('size differs: received $size bytes, expected $expectedBytes');
      return report;
    }
    if (digest != expectedSha256.toLowerCase()) {
      fail('SHA-256 differs: received $digest, expected '
          '${expectedSha256.toLowerCase()}');
      return report;
    }
    final others = destination
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path != landed.path)
        .map((f) => p.basename(f.path))
        .toList();
    if (others.isNotEmpty) {
      fail('the destination holds more than the one file: $others');
      return report;
    }

    report.status = 'success';
    say('verified: $size bytes, SHA-256 matches');
  } catch (e, st) {
    fail('${e.runtimeType}: $e');
    say('$st');
  } finally {
    report.fields['total_seconds'] = (clock.elapsedMilliseconds / 1000).round();
    if (!report.succeeded) {
      // A transfer that broke still says which path it was on: that is what
      // tells a relay that stopped carrying bytes from a path never found.
      final path = transport?.lastIcePath;
      if (path != null) {
        report.fields['ice_path'] ??= path.name;
        report.fields['ice_pair'] ??= transport?.lastIcePair;
      }
      try {
        await transport?.cancel();
      } catch (_) {}
    }
    try {
      await channel?.close();
    } catch (_) {}
  }
  return report;
}
