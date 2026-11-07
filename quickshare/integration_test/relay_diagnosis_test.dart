// When the connection cannot be made, does the person get the TRUE reason?
//
// The reason a session has no relay is known only at the very start — when the
// Worker is asked for credentials — and is needed only at the very end, when
// ICE gives up. Every unit test covers one half: the Worker client in
// isolation, the diagnosis in isolation, the bloc with a mock transport. What
// none of them can show is the wiring *inside the two real transports* — the
// fetch, the peer connection, the deadline, the diagnosis, the typed failure
// — and what finally reaches the two screens. This runs the real thing:
// `WebRtcTransferTransport` under a real `SenderBloc`, `WebRtcReceiverTransport`
// under a real `ReceiverBloc`, flutter_webrtc underneath, and a fake Worker on
// a loopback port whose answer is switched from case to case.
//
// Two runs, because one build setting decides what the cases mean. The Worker
// address must be the loopback one the fake binds (the test refuses to run
// against anything else, so it can never talk to the production Worker):
//
//   Failure cases — relay-only, so that a missing relay is a missing path:
//
//     flutter test integration_test/relay_diagnosis_test.dart -d macos \
//         --dart-define=QUICKSHARE_WORKER_URL=http://127.0.0.1:18787 \
//         --dart-define=QUICKSHARE_FORCE_RELAY=true
//
//   Success cases — the Worker answers 429 and a direct path still works:
//
//     flutter test integration_test/relay_diagnosis_test.dart -d macos \
//         --dart-define=QUICKSHARE_WORKER_URL=http://127.0.0.1:18787
//
// Each run executes only its own half and says so for the rest; the port may be
// any free one. One file per invocation on macOS.
//
// Everything is hermetic. The answer travels over an in-process channel, so no
// Nostr relay or Worker mailbox is involved (as in serverless_e2e_test.dart);
// path_provider is pointed at a scratch directory, so nothing is written to
// Downloads, Documents or the app's saved settings; Bluetooth announcing is
// replaced with a silent stand-in, because the real one would start
// advertising from the developer's machine.
//
// Lines worth reading in the output:
//
//     RELAY_CASE <name> reason=<...> elapsed_ms=<...> surface=<text>
//         one per case and per side (`<case>:sender`, `<case>:receiver`):
//         the reason that reached the screen, the real time from the start of
//         that side's session to the failure being shown, and the sentence
//         the person reads
//     RELAY_SETUP <case> ...   how long the Worker fetch kept setup waiting
// ignore_for_file: avoid_print, depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/diagnostics/transfer_report.dart';
import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/l10n/localized_labels.dart';
import 'package:quickshare/core/network/peer_link_service.dart';
import 'package:quickshare/core/signaling/answer_channel.dart';
import 'package:quickshare/core/storage/durable_file.dart';
import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/core/webrtc/ice_servers.dart';
import 'package:quickshare/core/webrtc/relay_availability.dart';
import 'package:quickshare/features/receiver/data/qr/qr_payload_decoder.dart';
import 'package:quickshare/features/receiver/data/transports/webrtc_receiver_transport.dart';
import 'package:quickshare/features/receiver/domain/repositories/receiver_repository.dart';
import 'package:quickshare/features/receiver/domain/usecases/download_file_usecase.dart';
import 'package:quickshare/features/receiver/presentation/bloc/receiver_bloc.dart';
import 'package:quickshare/features/sender/data/transports/webrtc_transfer_transport.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';
import 'package:quickshare/features/sender/domain/repositories/sender_repository.dart';
import 'package:quickshare/features/sender/domain/transports/transfer_transport.dart';
import 'package:quickshare/features/sender/presentation/bloc/sender_bloc.dart';
import 'package:quickshare/features/sender/presentation/pages/network_fallback_page.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';
import 'package:quickshare/l10n/gen/app_localizations_en.dart';
import 'package:quickshare/shared/models/qr_payload.dart';

import '../test/support/fake_mailbox.dart';

// --- stand-ins for what the machine does not need to do for this test ------

class _MockSenderRepository extends Mock implements SenderRepository {}

class _MockReceiverRepository extends Mock implements ReceiverRepository {}

class _MockDownload extends Mock implements DownloadFileUseCase {}

/// The native Wi-Fi Direct side, which an internet send never touches.
class _NoPeerLink extends PeerLinkService {
  const _NoPeerLink();
  @override
  bool get supported => false;
  @override
  Future<void> stop() async {}
}

/// Every directory path_provider hands out is a folder under [root].
class _ScratchPaths extends PathProviderPlatform {
  _ScratchPaths(this.root);
  final Directory root;

  Future<String> _dir(String name) async =>
      (Directory(p.join(root.path, name))..createSync(recursive: true)).path;

  @override
  Future<String?> getTemporaryPath() => _dir('tmp');
  @override
  Future<String?> getApplicationSupportPath() => _dir('support');
  @override
  Future<String?> getLibraryPath() => _dir('library');
  @override
  Future<String?> getApplicationDocumentsPath() => _dir('documents');
  @override
  Future<String?> getApplicationCachePath() => _dir('cache');
  @override
  Future<String?> getDownloadsPath() => _dir('downloads');
}

/// A received file that takes its time, so a transfer can be made to outlast
/// the connect deadline without touching the network.
class _SlowDurableFile extends DurableFile {
  _SlowDurableFile(super.finalPath,
      {super.staged, super.base, required this.perChunk});
  final Duration perChunk;

  @override
  Future<void> add(List<int> bytes) async {
    await Future<void>.delayed(perChunk);
    return super.add(bytes);
  }
}

// --- the answer's trip, in process ------------------------------------------

/// Carries the sealed answer from receiver to sender without leaving the
/// process. [publishAck] is how long `publish` keeps its caller waiting after
/// the payload has already been delivered — a real relay acknowledges after
/// the subscriber may well have seen the message.
class _Bus {
  final _answers = StreamController<Uint8List>.broadcast();
  Duration publishAck = Duration.zero;
  String? topic;
  int published = 0;
  DateTime? publishedAt;
  DateTime? ackReturnedAt;

  AnswerChannel side() => _BusSide(this);

  Future<void> dispose() async {
    if (!_answers.isClosed) await _answers.close();
  }
}

class _BusSide implements AnswerChannel {
  _BusSide(this._bus);
  final _Bus _bus;

  @override
  String get name => 'in-process';

  @override
  Stream<Uint8List> get answers => _bus._answers.stream;

  @override
  Future<void> subscribe(String topic) async => _bus.topic = topic;

  @override
  Future<void> publish(String topic, Uint8List payload) async {
    expect(topic, _bus.topic,
        reason: 'both sides must derive the same topic from the seed');
    _bus.published++;
    _bus.publishedAt = DateTime.now();
    if (!_bus._answers.isClosed) _bus._answers.add(payload);
    if (_bus.publishAck > Duration.zero) {
      await Future<void>.delayed(_bus.publishAck);
    }
    _bus.ackReturnedAt = DateTime.now();
  }

  @override
  Future<void> close() async {
    // Each bloc closes "its" channel when its session ends; the bus outlives
    // both so the other side's answer is never cut off by the first closer.
  }
}

// --- the Worker, faked -------------------------------------------------------

class _FakeWorker {
  _FakeWorker(this.port);
  final int port;

  HttpServer? _server;
  int status = 200;
  Map<String, String> headers = const {};
  Object? body = const <String, Object?>{};
  Duration delay = Duration.zero;
  final turnRequests = <DateTime>[];

  bool get listening => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server!.listen(_handle, onError: (Object _) {});
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  void answer(int status, Object? body,
      {Map<String, String> headers = const {},
      Duration delay = Duration.zero}) {
    this.status = status;
    this.body = body;
    this.headers = headers;
    this.delay = delay;
  }

  /// A well-formed 200 whose only TURN address is a port nothing listens on.
  void answerWithDeadRelay() => answer(200, {
        'cloudflare': {
          'iceServers': [
            {
              'urls': [
                'turn:127.0.0.1:1?transport=udp',
                'turn:127.0.0.1:1?transport=tcp',
              ],
              'username': 'fake-user',
              'credential': 'fake-credential',
            }
          ],
        },
        'expiresAt': DateTime.now()
            .toUtc()
            .add(const Duration(minutes: 30))
            .toIso8601String(),
      });

  Future<void> _handle(HttpRequest request) async {
    final isTurn = request.method == 'POST' && request.uri.path == '/turn';
    if (isTurn) turnRequests.add(DateTime.now());
    final status = this.status;
    final headers = this.headers;
    final body = this.body;
    final delay = this.delay;
    try {
      await request.drain<void>();
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      final response = request.response;
      if (!isTurn) {
        response.statusCode = HttpStatus.notFound;
      } else {
        response.statusCode = status;
        headers.forEach(response.headers.set);
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode(body));
      }
      await response.close();
    } catch (_) {
      // The client gave up first (that is the point of the timeout case).
    }
  }
}

// --- the cases -----------------------------------------------------------------

class _Case {
  const _Case(this.name, this.reason, this.code, this.configure,
      {this.status, this.retryAfter});

  final String name;

  /// Null: a relay was offered and the connection failed anyway.
  final RelayUnavailableReason? reason;
  final String code;
  final void Function(_FakeWorker worker) configure;
  final int? status;
  final Duration? retryAfter;
}

final _cases = <_Case>[
  _Case(
    'rate_limited',
    RelayUnavailableReason.rateLimited,
    FailureCode.noPathRelayLimited,
    (w) => w
        .answer(429, {'error': 'rate_limited'}, headers: {'Retry-After': '42'}),
    status: 429,
    retryAfter: const Duration(seconds: 42),
  ),
  _Case(
    'relay_disabled',
    RelayUnavailableReason.relayDisabled,
    FailureCode.noPathRelayOff,
    (w) => w.answer(503, {'error': 'relay_disabled'}),
    status: 503,
  ),
  _Case(
    'relay_unconfigured',
    RelayUnavailableReason.relayUnconfigured,
    FailureCode.noPathRelayOff,
    (w) => w.answer(503, {'error': 'relay_unconfigured'}),
    status: 503,
  ),
  _Case(
    'provider_error',
    RelayUnavailableReason.providerError,
    FailureCode.noPathRelayUnreachable,
    (w) => w.answer(502, {'error': 'provider_error'}),
    status: 502,
  ),
  _Case(
    'unreachable',
    RelayUnavailableReason.unreachable,
    FailureCode.noPathRelayUnreachable,
    (w) {}, // the server is closed by the test body
  ),
  _Case(
    'timeout',
    RelayUnavailableReason.timeout,
    FailureCode.noPathRelayUnreachable,
    (w) => w.answer(200, {}, delay: const Duration(seconds: 8)),
  ),
  _Case(
    'dead_turn',
    null,
    FailureCode.noPathRelayWasAvailable,
    (w) => w.answerWithDeadRelay(),
  ),
];

/// What the fallback page (sender) says for each code, and what the failure
/// snackbar (receiver) says — both straight from the English translations, so
/// a rewording changes the test's expectation with it.
String _senderSentence(AppLocalizations l10n, String code) => switch (code) {
      FailureCode.noPathRelayLimited => l10n.fallbackNoRouteBodyRelayLimited,
      FailureCode.noPathRelayUnreachable =>
        l10n.fallbackNoRouteBodyRelayUnreachable,
      FailureCode.noPathRelayOff => l10n.fallbackNoRouteBodyRelayOff,
      FailureCode.noPathRelayWasAvailable =>
        l10n.fallbackNoRouteBodyRelayWasAvailable,
      _ => l10n.fallbackNoRouteBody,
    };

// --- one session -----------------------------------------------------------------

class _Outcome {
  _Outcome({
    required this.senderStates,
    required this.receiverStates,
    required this.senderElapsed,
    required this.receiverElapsed,
    required this.senderSetup,
    required this.receiverSetup,
  });

  final List<SenderState> senderStates;
  final List<ReceiverState> receiverStates;
  final Duration senderElapsed;
  final Duration receiverElapsed;
  final Duration senderSetup;
  final Duration receiverSetup;

  SenderState get sender => senderStates.last;
  ReceiverState get receiver => receiverStates.last;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // The Worker the transports will talk to is whatever this build was told to,
  // and the fake has to be listening exactly there. Anything else would be the
  // production Worker.
  final workerUri = Uri.tryParse(AppConstants.workerBaseUrl);
  final fakeWorkerPort = (workerUri != null &&
          (workerUri.host == '127.0.0.1' || workerUri.host == 'localhost') &&
          workerUri.hasPort)
      ? workerUri.port
      : null;
  const forced = AppConstants.forceRelay;
  final l10n = AppLocalizationsEn();

  final logLines = <String>[];
  late StreamSubscription<String> logSub;
  late Directory scratch;
  late PathProviderPlatform originalPaths;
  late _FakeWorker worker;
  final states = Random();

  setUpAll(() async {
    if (fakeWorkerPort == null) {
      fail('QUICKSHARE_WORKER_URL is "${AppConstants.workerBaseUrl}". This '
          'test must be pointed at a loopback port it can bind, e.g. '
          '--dart-define=QUICKSHARE_WORKER_URL=http://127.0.0.1:18787 — it '
          'will not run against a real Worker.');
    }
    logSub = AppLogger.logStream.listen(logLines.add);
    scratch = Directory.systemTemp.createTempSync('dd_relay_diag_');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _ScratchPaths(scratch);
    worker = _FakeWorker(fakeWorkerPort);
    await worker.start();
    print(forced
        ? 'RELAY_DIAG_MODE failure cases (QUICKSHARE_FORCE_RELAY=true); the '
            'success cases are skipped — run without the define for them'
        : 'RELAY_DIAG_MODE success cases (no QUICKSHARE_FORCE_RELAY); the '
            'failure cases are skipped — run with the define for them');
    print('RELAY_DIAG_SETUP worker=${AppConstants.workerBaseUrl} '
        'forceRelay=$forced kDebugMode=$kDebugMode '
        'policy=${IceServers.transportPolicy()} scratch=${scratch.path}');
  });

  tearDownAll(() async {
    if (fakeWorkerPort == null) return;
    await worker.stop();
    PathProviderPlatform.instance = originalPaths;
    await logSub.cancel();
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  Future<void> flushLogs() =>
      Future<void>.delayed(const Duration(milliseconds: 30));

  void boundedTeardown(String name, Future<void> Function() action) {
    addTearDown(() async {
      print('RELAY_TEARDOWN start $name');
      await action().timeout(const Duration(seconds: 10), onTimeout: () {
        throw TimeoutException('relay test teardown stalled: $name');
      });
      print('RELAY_TEARDOWN done $name');
    });
  }

  // A live desktop window may be occluded, leaving a pump waiting on a vsync
  // indefinitely. A warm-up frame still builds, lays out and paints the real
  // widget tree, so finder assertions can run without relying on that vsync.
  // This does not assert that pixels were presented on the physical display.
  Future<void> testFrame(String name, Future<void> Function() pump) async {
    final pending = pump();
    WidgetsBinding.instance.scheduleWarmUpFrame();
    await pending.timeout(const Duration(seconds: 10), onTimeout: () {
      throw TimeoutException('relay test frame stalled: $name');
    });
  }

  Directory fresh(String name) =>
      Directory(p.join(scratch.path, '${name}_${states.nextInt(1 << 30)}'))
        ..createSync(recursive: true);

  /// Runs one complete session through the real blocs and the real
  /// transports, and returns what each screen would have been given.
  Future<_Outcome> runSession({
    required Duration iceBudget,
    required Directory senderDiagnostics,
    required FileMetadata file,
    Duration publishAck = Duration.zero,
    Duration? slowChunks,
    bool interruptAfterProgress = false,
    Duration overall = const Duration(seconds: 90),
    void Function(
            WebRtcTransferTransport sender, WebRtcReceiverTransport receiver)?
        onTransports,
  }) async {
    final bus = _Bus()..publishAck = publishAck;
    final mailbox = FakeMailboxHub();
    boundedTeardown('bus', bus.dispose);

    final senderTransport =
        WebRtcTransferTransport(iceConnectBudget: iceBudget);
    final receiverTransport = WebRtcReceiverTransport(
      iceConnectBudget: iceBudget,
      debugFileFactory: slowChunks == null
          ? null
          : (path, {required staged, required base}) => _SlowDurableFile(path,
              staged: staged, base: base, perChunk: slowChunks),
    );
    onTransports?.call(senderTransport, receiverTransport);

    final repository = _MockSenderRepository();
    when(() => repository.transferProgress)
        .thenAnswer((_) => const Stream.empty());
    when(() => repository.statusStream).thenAnswer((_) => const Stream.empty());
    when(() => repository.stopServer(force: any(named: 'force')))
        .thenAnswer((_) async => const Right(null));
    when(() => repository.approvalRequests)
        .thenAnswer((_) => const Stream.empty());
    when(() => repository.lastQhtpClientAddress).thenReturn(null);
    when(() => repository.sessionTlsFingerprint).thenReturn('cert');

    final senderBloc = SenderBloc(
      repository: repository,
      peerLinkService: const _NoPeerLink(),
      diagnostics: TransferDiagnostics(overrideDir: () => senderDiagnostics),
      webRtcTransportFactory: () => senderTransport,
      rendezvousChannelFactory: ({acceptPayload}) => bus.side(),
      codeMailboxFactory: () => mailbox.endpoint('sender'),
    );
    final receiverBloc = ReceiverBloc(
      downloadFileUseCase: _MockDownload(),
      repository: _MockReceiverRepository(),
      serverlessTransportFactory: () => receiverTransport,
      rendezvousChannelFactory: bus.side,
      resumeMailboxFactory: () => mailbox.endpoint('receiver'),
    );
    boundedTeardown('sender bloc', senderBloc.close);
    boundedTeardown('receiver bloc', receiverBloc.close);

    final senderStates = <SenderState>[];
    final receiverStates = <ReceiverState>[];
    final senderSub = senderBloc.stream.listen(senderStates.add);
    final receiverSub = receiverBloc.stream.listen(receiverStates.add);
    boundedTeardown('sender states subscription', senderSub.cancel);
    boundedTeardown('receiver states subscription', receiverSub.cancel);

    final deadline = DateTime.now().add(overall);
    Future<T> until<T extends Object>(T? Function() probe, String what) async {
      while (true) {
        final found = probe();
        if (found != null) return found;
        if (DateTime.now().isAfter(deadline)) {
          fail('timed out waiting for $what; sender states '
              '${senderStates.map((s) => s.runtimeType).toList()}, receiver '
              'states ${receiverStates.map((s) => s.runtimeType).toList()}');
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }

    // ---- sender: what the person does on the sending device ----
    final senderStarted = Stopwatch()..start();
    senderBloc.add(StartQhtpSend([file.path], mode: TransportType.internet));
    final ready = await until<QRReady>(
        () => senderStates.whereType<QRReady>().firstOrNull, 'the sender QR');
    final senderSetup = senderStarted.elapsed;

    // ---- receiver: what the person does after scanning it ----
    final payload = QRPayload(
      version: 2,
      ip: '',
      port: 0,
      token: '',
      mode: QRPayloadDecoder.serverlessMode,
      sdpOffer: ready.qrData,
    );
    final receiverStarted = Stopwatch()..start();
    receiverBloc.add(StartDownload(payload: payload));
    await until<DateTime>(() => bus.publishedAt, 'the answer to be published');
    final receiverSetup = receiverStarted.elapsed;

    if (interruptAfterProgress) {
      await until<Downloading>(
          () => receiverStates
              .whereType<Downloading>()
              .where((s) => s.progress > 0 && s.progress < 1)
              .firstOrNull,
          'partial receiver progress before interrupting the native link');
      await senderTransport
          .interruptLinkForTest()
          .timeout(const Duration(seconds: 10));
    }

    // ---- both ends finish: failure surfaces or success ----
    Duration? senderEnd;
    Duration? receiverEnd;
    bool senderDone() =>
        senderStates.any((s) =>
            s is NoUsablePathFound ||
            s is SenderError ||
            s is TransferComplete) ||
        (senderStates.last is SenderInitial && senderStates.length > 2);
    bool receiverDone() =>
        receiverStates.any((s) => s is ReceiverError || s is DownloadComplete);

    while (!(senderDone() && receiverDone())) {
      if (senderEnd == null && senderDone()) senderEnd = senderStarted.elapsed;
      if (receiverEnd == null && receiverDone()) {
        receiverEnd = receiverStarted.elapsed;
      }
      if (DateTime.now().isAfter(deadline)) {
        fail(
            'the session never ended: sender ${senderStates.map((s) => s.runtimeType).toList()}, '
            'receiver ${receiverStates.map((s) => s.runtimeType).toList()}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    senderEnd ??= senderStarted.elapsed;
    receiverEnd ??= receiverStarted.elapsed;
    await flushLogs();

    return _Outcome(
      senderStates: senderStates,
      receiverStates: receiverStates,
      senderElapsed: senderEnd,
      receiverElapsed: receiverEnd,
      senderSetup: senderSetup,
      receiverSetup: receiverSetup,
    );
  }

  FileMetadata makeFile(String name, int bytes, int seed) {
    final rand = Random(seed);
    final data =
        Uint8List.fromList(List.generate(bytes, (_) => rand.nextInt(256)));
    final file = File(p.join(fresh('payload').path, name))
      ..writeAsBytesSync(data);
    return FileMetadata(
      name: name,
      path: file.path,
      size: bytes,
      mimeType: 'application/octet-stream',
    );
  }

  Future<TransferReport> firstReport(Directory? dir) async {
    final diagnostics = dir == null
        ? const TransferDiagnostics()
        : TransferDiagnostics(overrideDir: () => dir);
    // The bloc files the report away without making the screen wait for it.
    for (var i = 0; i < 80; i++) {
      final reports = await diagnostics.recent();
      if (reports.isNotEmpty) return reports.first;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    fail('no transfer report was ever recorded');
  }

  String reasonName(NoPathDiagnosis diagnosis) =>
      diagnosis.relayUnavailable?.reason.name ?? 'relayOffered';

  // ===========================================================================
  // The failure cases: relay-only, so no relay means no path
  // ===========================================================================
  group('a missing relay is reported as what it was', () {
    for (final c in _cases) {
      testWidgets(c.name, (tester) async {
        worker.turnRequests.clear();
        await worker.stop();
        if (c.name != 'unreachable') {
          c.configure(worker);
          await worker.start();
        }
        final restoreWorker = c.name == 'unreachable';
        addTearDown(() async {
          if (restoreWorker && !worker.listening) await worker.start();
        });

        final senderDiag = fresh('sender_diag');
        final logStart = logLines.length;
        final outcome = await runSession(
          iceBudget: const Duration(seconds: 10),
          senderDiagnostics: senderDiag,
          file: makeFile('payload.bin', 64 * 1024, 7),
          overall: const Duration(seconds: 90),
        );
        print('RELAY_STAGE ${c.name} session returned');

        // How long the Worker fetch itself kept each side waiting: from the
        // request reaching the fake to the fetch giving up, in the app's log.
        DateTime stamp(String line) =>
            DateTime.parse(line.substring(1, line.indexOf(']')));
        final gaveUpAt = logLines
            .skip(logStart)
            .where((l) => l.contains('Worker TURN credential fetch failed'))
            .map(stamp)
            .toList();
        final fetchMs = <int>[
          for (var i = 0;
              i < min(gaveUpAt.length, worker.turnRequests.length);
              i++)
            gaveUpAt[i].difference(worker.turnRequests[i]).inMilliseconds,
        ];

        // -- the policy really was relay-only on both transports ----
        expect(logLines.where((l) => l.contains('policy=relay')).length,
            greaterThanOrEqualTo(2),
            reason: 'FORCE_RELAY did not reach both peer connections');

        // -- sender ----------------------------------------------------
        final senderState = outcome.sender;
        expect(senderState, isA<NoUsablePathFound>(),
            reason: 'the sender ended in ${senderState.runtimeType}, not on '
                'the screen that explains a missing route');
        final noPath = senderState as NoUsablePathFound;
        final diagnosis = noPath.diagnosis!;
        expect(diagnosis.relayUnavailable?.reason, c.reason);
        expect(noPath.failureCode, c.code);
        if (c.status != null) {
          expect(diagnosis.relayUnavailable?.statusCode, c.status);
        }
        if (c.retryAfter != null) {
          expect(diagnosis.relayUnavailable?.retryAfter, c.retryAfter,
              reason: 'the Worker\'s Retry-After must survive the trip');
        }

        // The real fallback screen, given what the bloc handed the router.
        print('RELAY_STAGE ${c.name} render sender surface');
        await testFrame(
            '${c.name} sender surface',
            () => tester.pumpWidget(MaterialApp(
                  locale: const Locale('en'),
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  home: NetworkFallbackPage(noPathCode: noPath.failureCode),
                )));
        await Future<void>.delayed(const Duration(seconds: 1));
        await testFrame('${c.name} sender surface update', tester.pump);
        print('RELAY_STAGE ${c.name} sender surface rendered');
        final senderSurface = _senderSentence(l10n, c.code);
        expect(find.text(senderSurface), findsOneWidget,
            reason: 'the fallback page must show the sentence for ${c.code}');
        await testFrame('${c.name} remove sender surface',
            () => tester.pumpWidget(const SizedBox()));
        print('RELAY_STAGE ${c.name} sender surface removed');

        // The report the settings screen will list.
        final sentReport = await firstReport(senderDiag);
        print('RELAY_STAGE ${c.name} sender report read');
        expect(sentReport.succeeded, isFalse);
        expect(sentReport.bytes, 0,
            reason: 'an ICE failure before DataChannel open sent no file '
                'bytes, even if the manifest promised a whole file');
        expect(sentReport.failureCode, c.code);
        expect(sentReport.failure,
            contains('relay: ${c.reason?.name ?? 'offered'}'));

        print('RELAY_CASE ${c.name}:sender reason=${reasonName(diagnosis)} '
            'elapsed_ms=${outcome.senderElapsed.inMilliseconds} '
            'surface=$senderSurface');

        // -- receiver --------------------------------------------------
        final receiverState = outcome.receiver;
        expect(receiverState, isA<ReceiverError>(),
            reason: 'the receiver ended in ${receiverState.runtimeType}');
        final error = receiverState as ReceiverError;
        expect(error.code, c.code);
        expect(error.message, startsWith('No usable path'));
        expect(
            error.message, contains('relay: ${c.reason?.name ?? 'offered'}'));
        if (c.status != null) {
          expect(error.message, contains('HTTP ${c.status}'));
        }
        if (c.retryAfter != null) {
          expect(error.message,
              contains('retry after ${c.retryAfter!.inSeconds}s'));
        }
        final receiverSurface =
            localizedFailure(l10n, code: error.code, fallback: error.message);
        expect(
            receiverSurface,
            switch (c.code) {
              FailureCode.noPathRelayLimited => l10n.errorNoPathRelayLimited,
              FailureCode.noPathRelayUnreachable =>
                l10n.errorNoPathRelayUnreachable,
              FailureCode.noPathRelayOff => l10n.errorNoPathRelayOff,
              _ => l10n.errorNoPathRelayWasAvailable,
            },
            reason: 'the receiver must show the sentence for ${c.code}, not '
                'the raw English summary');
        final receivedReport = await firstReport(null);
        print('RELAY_STAGE ${c.name} receiver report read');
        expect(receivedReport.succeeded, isFalse);
        expect(receivedReport.failureCode, c.code);

        final receiverReason =
            RegExp(r'relay: (\w+)').firstMatch(error.message)?.group(1);
        print('RELAY_CASE ${c.name}:receiver reason=$receiverReason '
            'elapsed_ms=${outcome.receiverElapsed.inMilliseconds} '
            'surface=$receiverSurface');
        print('RELAY_SETUP ${c.name} sender_setup_ms='
            '${outcome.senderSetup.inMilliseconds} receiver_setup_ms='
            '${outcome.receiverSetup.inMilliseconds} worker_requests='
            '${worker.turnRequests.length} worker_fetch_ms=$fetchMs');

        // -- and the case's own claim ---------------------------------
        if (c.reason == null) {
          // A relay WAS offered: nobody may be told the relay service failed.
          for (final text in [senderSurface, receiverSurface]) {
            final lower = text.toLowerCase();
            expect(lower, isNot(contains('relay service')),
                reason:
                    'blamed the relay service for a relay that was offered');
            expect(lower, isNot(contains('switched off')));
            expect(lower, isNot(contains('limiting')));
            expect(lower, isNot(contains('could not be reached')));
          }
          expect(diagnosis.relayUnavailable, isNull);
          expect(worker.turnRequests.length, greaterThanOrEqualTo(2),
              reason: 'both peers should have fetched credentials');
        } else if (c.name == 'timeout') {
          // Bounded: the fetch gave up at its own limit (the Worker was told
          // to sit on the request for 8 s), and setup moved on.
          expect(fetchMs, hasLength(2));
          for (final ms in fetchMs) {
            expect(ms, inInclusiveRange(3500, 5500),
                reason: 'the Worker fetch must give up at its bound '
                    '(${IceServers.turnFetchTimeout.inSeconds} s), not wait '
                    'for the 8 s answer');
          }
        } else if (c.name == 'unreachable') {
          expect(worker.turnRequests, isEmpty,
              reason: 'the server was closed; nothing should have answered');
        } else {
          expect(worker.turnRequests.length, greaterThanOrEqualTo(2));
          for (final ms in fetchMs) {
            expect(ms, lessThan(1500), reason: 'a plain refusal is quick');
          }
        }

        // Setup is the Worker fetch (bounded) plus gathering (capped), on
        // each side — never open-ended, whatever the Worker does.
        final setupBound = IceServers.turnFetchTimeout +
            AppConstants.iceGatheringMaxWait +
            const Duration(milliseconds: 1500);
        expect(outcome.senderSetup, lessThan(setupBound),
            reason: 'sender setup was stuck past its bound');
        expect(outcome.receiverSetup, lessThan(setupBound),
            reason: 'receiver setup was stuck past its bound');

        // Terminated well inside the safety net, whatever ended it.
        expect(outcome.senderElapsed, lessThan(const Duration(seconds: 80)));
        expect(outcome.receiverElapsed, lessThan(const Duration(seconds: 80)));
      }, skip: !forced, timeout: const Timeout(Duration(minutes: 3)));
    }
  });

  // ===========================================================================
  // The success cases: no FORCE_RELAY, the Worker refuses, the transfer works
  // ===========================================================================
  group('a refusing Worker does not break a path that works', () {
    Future<void> refuseWith429() async {
      worker.turnRequests.clear();
      await worker.stop();
      worker.answer(429, {'error': 'rate_limited'},
          headers: {'Retry-After': '30'});
      await worker.start();
    }

    Uint8List bytesOf(FileMetadata f) => File(f.path).readAsBytesSync();

    testWidgets(
        'direct path over loopback: file arrives intact, nothing '
        'reports an error, the deadline never fires', (tester) async {
      await refuseWith429();
      final file = makeFile('payload.bin', 512 * 1024, 11);
      final senderDiag = fresh('sender_diag');
      WebRtcTransferTransport? sender;
      WebRtcReceiverTransport? receiver;
      final armedSamples = <bool>[];

      final before = logLines.length;
      final outcome = await runSession(
        iceBudget: const Duration(seconds: 20),
        senderDiagnostics: senderDiag,
        file: file,
        onTransports: (s, r) {
          sender = s;
          receiver = r;
        },
      );
      armedSamples
        ..add(sender!.iceDeadlineArmed)
        ..add(receiver!.iceDeadlineArmed);

      // No false error on either screen, at any point.
      expect(outcome.senderStates.whereType<NoUsablePathFound>(), isEmpty);
      expect(outcome.senderStates.whereType<SenderError>(), isEmpty,
          reason: outcome.senderStates
              .whereType<SenderError>()
              .map((e) => e.message)
              .join('; '));
      expect(outcome.receiverStates.whereType<ReceiverError>(), isEmpty,
          reason: outcome.receiverStates
              .whereType<ReceiverError>()
              .map((e) => e.message)
              .join('; '));

      // The file crossed, byte for byte.
      final done = outcome.receiver as DownloadComplete;
      expect(sha256.convert(File(done.filePath).readAsBytesSync()),
          sha256.convert(bytesOf(file)));
      expect(p.isWithin(scratch.path, done.filePath), isTrue,
          reason: 'it must have been written under the scratch directory');

      // The Worker did refuse, and the transports knew it — the direct path
      // won anyway.
      final mine = logLines.skip(before).toList();
      expect(worker.turnRequests.length, greaterThanOrEqualTo(2));
      expect(
          sender!.relayUnavailable?.reason, RelayUnavailableReason.rateLimited);
      expect(mine.where((l) => l.contains('relay=rateLimited')).length,
          greaterThanOrEqualTo(2));
      expect(mine.where((l) => l.contains('policy=all')).length,
          greaterThanOrEqualTo(2));
      expect(mine.where((l) => l.contains('policy=relay')), isEmpty);

      // Neither deadline fired, and neither is still running.
      expect(
          mine.where((l) => l.contains('ICE did not connect within')), isEmpty);
      expect(armedSamples, everyElement(isFalse));

      // And the sender filed a successful report over a free route.
      final report = await firstReport(senderDiag);
      expect(report.succeeded, isTrue, reason: report.failure);
      expect(report.bytes, file.size,
          reason: 'the sender journal must record the selected file size');
      expect(report.route, isNot(TransferRoute.internetRelayed));
      print(
          'RELAY_SUCCESS direct bytes=${file.size} route=${report.route.wire} '
          'sender_ms=${outcome.senderElapsed.inMilliseconds} '
          'receiver_ms=${outcome.receiverElapsed.inMilliseconds} '
          'worker_requests=${worker.turnRequests.length}');
    }, skip: forced, timeout: const Timeout(Duration(minutes: 3)));

    testWidgets('native WebRTC reconnect resumes an interrupted file',
        (tester) async {
      await refuseWith429();
      final file = makeFile('reconnect.bin', 8 * 1024 * 1024, 31);
      final outcome = await runSession(
        iceBudget: const Duration(seconds: 20),
        senderDiagnostics: fresh('reconnect_diag'),
        file: file,
        slowChunks: const Duration(milliseconds: 20),
        interruptAfterProgress: true,
        overall: const Duration(seconds: 120),
      );

      expect(
          outcome.senderStates
              .whereType<Transferring>()
              .any((state) => state.reconnecting),
          isTrue,
          reason:
              'the sender must report recovery after the native link closes');
      expect(outcome.senderStates.whereType<SenderError>(), isEmpty);
      expect(outcome.receiverStates.whereType<ReceiverError>(), isEmpty);
      expect(outcome.senderStates.whereType<TransferComplete>(), hasLength(1));
      expect(
          outcome.receiverStates.whereType<DownloadComplete>(), hasLength(1));
      expect(outcome.sender, isA<TransferComplete>());
      expect(outcome.receiver, isA<DownloadComplete>());
      final done = outcome.receiver as DownloadComplete;
      expect(done.items, hasLength(1));
      expect(sha256.convert(File(done.filePath).readAsBytesSync()),
          sha256.convert(File(file.path).readAsBytesSync()));
      final received = Directory(p.dirname(done.filePath))
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith('reconnect'));
      expect(received, hasLength(1),
          reason: 'resume must not duplicate the file');
    }, skip: forced, timeout: const Timeout(Duration(minutes: 3)));

    // The deadline guards the wait for a connection. A transfer that is
    // merely long must never meet it. The budget is shortened to 3 s and the
    // receiver is made slow enough that the transfer takes several times that.
    testWidgets('a healthy transfer that outlasts the deadline is not killed',
        (tester) async {
      await refuseWith429();
      const budget = Duration(seconds: 3);
      final file = makeFile('slow.bin', 4 * 1024 * 1024, 21); // 64 chunks
      final senderDiag = fresh('sender_diag');
      WebRtcTransferTransport? sender;
      WebRtcReceiverTransport? receiver;

      final before = logLines.length;
      final outcome = await runSession(
        iceBudget: budget,
        senderDiagnostics: senderDiag,
        file: file,
        slowChunks: const Duration(milliseconds: 150), // 64 x 150 ms ~ 9.6 s
        onTransports: (s, r) {
          sender = s;
          receiver = r;
        },
      );

      expect(outcome.receiver, isA<DownloadComplete>(),
          reason: outcome.receiver is ReceiverError
              ? (outcome.receiver as ReceiverError).message
              : '${outcome.receiver.runtimeType}');
      expect(outcome.senderStates.whereType<NoUsablePathFound>(), isEmpty);
      expect(outcome.senderStates.whereType<SenderError>(), isEmpty);

      // It really did run past the deadline — otherwise this proves nothing.
      expect(outcome.receiverElapsed, greaterThan(budget * 2),
          reason: 'the transfer must outlast the budget by a wide margin');

      final mine = logLines.skip(before).toList();
      expect(
          mine.where((l) => l.contains('ICE did not connect within')), isEmpty,
          reason: 'the connect deadline fired during a healthy transfer');
      expect(sender!.iceDeadlineArmed, isFalse);
      expect(receiver!.iceDeadlineArmed, isFalse);

      final done = outcome.receiver as DownloadComplete;
      expect(sha256.convert(File(done.filePath).readAsBytesSync()),
          sha256.convert(File(file.path).readAsBytesSync()));
      print('RELAY_SLOW healthy transfer receiver_ms='
          '${outcome.receiverElapsed.inMilliseconds} budget_ms='
          '${budget.inMilliseconds} deadline_fired=false');
    }, skip: forced, timeout: const Timeout(Duration(minutes: 3)));

    // The same, with the answer's delivery acknowledged late. A real rendezvous
    // channel's `publish` only returns once the relay has acknowledged, by
    // which time the sender has usually seen the answer and the connection is
    // already up. The receiver arms its deadline when `publish` returns — so
    // the deadline must not be started for a connection that already exists.
    testWidgets(
        'a connection that came up before the answer was acknowledged '
        'does not leave a deadline behind to kill the transfer',
        (tester) async {
      await refuseWith429();
      const budget = Duration(seconds: 3);
      const ack = Duration(seconds: 2);
      final file = makeFile('slow_ack.bin', 4 * 1024 * 1024, 22);
      final senderDiag = fresh('sender_diag');
      WebRtcReceiverTransport? receiver;

      final before = logLines.length;
      var iceAlreadyUp = false;
      final watcher = Timer.periodic(const Duration(milliseconds: 20), (_) {
        // Receiver ICE connected while the publish is still waiting for its ack.
        if (!iceAlreadyUp &&
            logLines.skip(before).any((l) =>
                l.contains('Receiver ICE state') &&
                (l.contains('Connected') || l.contains('Completed')))) {
          iceAlreadyUp = true;
        }
      });
      addTearDown(watcher.cancel);

      final outcome = await runSession(
        iceBudget: budget,
        senderDiagnostics: senderDiag,
        file: file,
        publishAck: ack,
        slowChunks: const Duration(milliseconds: 150),
        onTransports: (s, r) => receiver = r,
      );
      watcher.cancel();

      expect(iceAlreadyUp, isTrue,
          reason: 'precondition: ICE has to be connected before the ack '
              'returns, or this test shows nothing about arming late');

      final mine = logLines.skip(before).toList();
      expect(
          mine.where((l) => l.contains('ICE did not connect within')), isEmpty,
          reason: 'a deadline armed after the connection existed fired '
              'during a healthy transfer');
      expect(receiver!.iceDeadlineArmed, isFalse,
          reason: 'a deadline is still ticking for a connection that is up');
      expect(outcome.receiver, isA<DownloadComplete>(),
          reason: outcome.receiver is ReceiverError
              ? (outcome.receiver as ReceiverError).message
              : '${outcome.receiver.runtimeType}');
      expect(outcome.receiverElapsed, greaterThan(budget + ack),
          reason: 'the transfer must outlast the late-armed deadline');
      final done = outcome.receiver as DownloadComplete;
      expect(sha256.convert(File(done.filePath).readAsBytesSync()),
          sha256.convert(File(file.path).readAsBytesSync()));
      print(
          'RELAY_SLOW late-arm receiver_ms=${outcome.receiverElapsed.inMilliseconds} '
          'ack_ms=${ack.inMilliseconds} budget_ms=${budget.inMilliseconds} '
          'deadline_fired=false');
    }, skip: forced, timeout: const Timeout(Duration(minutes: 3)));
  });

  // ===========================================================================
  // FORCE_RELAY is a debug switch
  // ===========================================================================
  group('FORCE_RELAY', () {
    testWidgets('is honoured only where kDebugMode is true', (tester) async {
      // IceServers.transportPolicy():
      //     final force = forceRelay ?? (kDebugMode && AppConstants.forceRelay);
      // so a release build (kDebugMode == false) answers 'all' whatever the
      // define says. Every production call passes no explicit forceRelay.
      const expected = kDebugMode && AppConstants.forceRelay ? 'relay' : 'all';
      expect(IceServers.transportPolicy(), expected);
      expect(kDebugMode, !(kReleaseMode || kProfileMode));

      final viaTurnList = IceServers.configurationWithTurnServers(const []);
      expect(viaTurnList['iceTransportPolicy'], expected);
      final viaFallback = await IceServers.configurationDynamic(
          workerBaseUrl: '', timeout: const Duration(seconds: 1));
      expect(viaFallback.configuration['iceTransportPolicy'], expected);
      expect(viaFallback.relayUnavailable?.reason,
          RelayUnavailableReason.noWorkerUrl);

      if (!kDebugMode) {
        expect(IceServers.transportPolicy(), 'all',
            reason: 'FORCE_RELAY must be ignored outside debug builds');
      }
      print('FORCE_RELAY define=${AppConstants.forceRelay} kDebugMode='
          '$kDebugMode policy=${IceServers.transportPolicy()} '
          '(guard: kDebugMode && AppConstants.forceRelay)');
    });
  });
}
