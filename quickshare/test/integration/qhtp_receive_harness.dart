// A real sender and a real receiver on loopback, in scratch directories, for
// the tests that care about what lands on the receiver's disk.
//
// Nothing here is a stand-in: the server is `LocalHttpServer`, the manifest
// comes from `FileIndexer`, the receiver is `QhtpReceiverClient` writing into a
// real temp directory and keeping its resume state in another. The only thing
// that is injected is a Dio interceptor, which counts what the receiver asks
// for and lets a test do something to the filesystem at an exact moment — the
// way a user (or an attacker) could while a transfer is in flight.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/storage/disk_space.dart';
import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/features/receiver/data/client/qhtp_receiver_client.dart';
import 'package:quickshare/features/receiver/data/store/session_state_store.dart';
import 'package:quickshare/features/receiver/domain/entities/qhtp_receive_result.dart';
import 'package:quickshare/features/sender/data/indexer/file_indexer.dart';
import 'package:quickshare/features/sender/data/server/local_http_server.dart';
import 'package:quickshare/shared/models/qr_payload.dart';

class _FakeWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}
  @override
  Future<bool> get enabled async => false;
}

/// Installs the no-op wakelock the server's session start needs.
void installFakeWakelock() {
  wakelockPlusPlatformInstance = _FakeWakelock();
}

/// What the receiver asked the sender for, in order.
class RecordedRequest {
  RecordedRequest(this.method, this.path, {this.body, this.range});

  final String method;
  final String path;
  final Object? body;
  final String? range;

  bool get isFile =>
      path.contains('/v2/files/') && !path.endsWith('/digest');
  bool get isDigest => path.endsWith('/digest');
  bool get isComplete => path.endsWith('/v2/session/complete');

  String? get fileId => isFile ? p.url.basename(path) : null;
}

typedef RequestHook = FutureOr<void> Function(RecordedRequest request);

class QhtpHarness {
  QhtpHarness._(this.source, this.target, this.state, this.outside);

  /// The sender's selection. Its basename is the top-level folder the
  /// receiver creates under [target].
  final Directory source;

  /// The destination the user chose.
  final Directory target;

  /// Where session resume state lives.
  final Directory state;

  /// A directory the receiver must never write into — the stand-in for "the
  /// rest of the user's disk" in every symlink test.
  final Directory outside;

  LocalHttpServer? _server;

  /// The sender's server, for the tests that act on it mid-session.
  LocalHttpServer get server => _server!;
  late QRPayload payload;
  late QhtpIndexerResult indexed;

  final List<RecordedRequest> requests = [];

  static Future<QhtpHarness> create() async {
    final h = QhtpHarness._(
      await Directory.systemTemp.createTemp('qhtp_src_'),
      await Directory.systemTemp.createTemp('qhtp_dst_'),
      await Directory.systemTemp.createTemp('qhtp_state_'),
      await Directory.systemTemp.createTemp('qhtp_outside_'),
    );
    return h;
  }

  /// Where [relative] (as the sender's selection names it) lands under the
  /// destination when nothing is in the way.
  String received(String relative) =>
      p.join(target.path, p.basename(source.path), relative);

  String get sessionId => payload.sessionId!;

  /// Writes [files] into the selection and serves them.
  ///
  /// [checksums] false is the production shape for a big session: the
  /// manifest carries no digest and the receiver has to ask the sender for
  /// each one.
  Future<void> serve(
    Map<String, List<int>> files, {
    bool checksums = true,
    String sessionId = 'safety-session',
  }) async {
    for (final entry in files.entries) {
      final f = File(p.join(source.path, entry.key));
      f.parent.createSync(recursive: true);
      f.writeAsBytesSync(entry.value);
    }
    indexed = await FileIndexer().buildResult(
      sessionId: sessionId,
      paths: [source.path],
      includeChecksums: checksums,
    );
    final server = _server = LocalHttpServer();
    const token = 'safety-token';
    final port = await server.startQhtpSession(
      manifest: indexed.manifest,
      itemIdToAbsPathMap: indexed.itemIdToAbsPathMap,
      authToken: token,
    );
    payload = QRPayload(
      version: 2,
      ip: '127.0.0.1',
      port: port,
      token: token,
      sessionId: indexed.manifest.sessionId,
      mode: 'http-lan',
      tlsFingerprint: server.tlsFingerprint!,
    );
  }

  /// The id the manifest gave the item at [relative].
  String idOf(String relative) => indexed.manifest.items
      .firstWhere((i) => i.path == '${p.basename(source.path)}/$relative')
      .id;

  SessionStateStore get store => SessionStateStore(storeDirectory: state.path);

  /// A receiver against this sender.
  ///
  /// [onRequest] runs before each request leaves, awaited, so a test can
  /// change the disk at a precise point: after the destination name was
  /// chosen and before the bytes arrive, say.
  QhtpReceiverClient client({
    RequestHook? onRequest,
    DiskSpaceProbe? diskSpace,
    RandomAccessFile Function(RandomAccessFile)? wrapSink,
    bool failDigests = false,
  }) {
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) async {
          final path = options.uri.path;
          final record = RecordedRequest(
            options.method,
            path,
            body: options.data,
            range: options.headers['Range'] as String?,
          );
          requests.add(record);
          if (record.isDigest && failDigests) {
            handler.reject(DioException(
              requestOptions: options,
              type: DioExceptionType.connectionError,
              error: 'digest endpoint unavailable (test)',
            ));
            return;
          }
          await onRequest?.call(record);
          handler.next(options);
        },
      ));
    return QhtpReceiverClient(
      dioClient: dio,
      store: store,
      diskSpace: diskSpace,
      debugWrapSink: wrapSink,
    );
  }

  /// File requests the receiver made for [relative] — body requests, not
  /// digest lookups.
  int fileRequestsFor(String relative) =>
      requests.where((r) => r.isFile && r.fileId == idOf(relative)).length;

  /// The body of the completion POST, or null when none was sent.
  Map<String, dynamic>? get completionBody {
    final post = requests.where((r) => r.isComplete).toList();
    if (post.isEmpty) return null;
    final body = post.last.body;
    if (body is Map) return body.cast<String, dynamic>();
    if (body is String) return jsonDecode(body) as Map<String, dynamic>;
    return null;
  }

  /// Everything under [dir], as `relative path -> length` for files, so a
  /// test can prove a directory was left exactly as it was.
  static Map<String, Object> snapshot(Directory dir) {
    final out = <String, Object>{};
    if (!dir.existsSync()) return out;
    for (final e in dir.listSync(recursive: true, followLinks: false)) {
      final rel = p.relative(e.path, from: dir.path);
      if (e is File) {
        out[rel] = '${e.lengthSync()}:${base64.encode(e.readAsBytesSync())}';
      } else if (e is Link) {
        out[rel] = 'link->${e.targetSync()}';
      } else {
        out[rel] = 'dir';
      }
    }
    return out;
  }

  Future<void> dispose() async {
    await _server?.stop();
    _server = null;
    for (final d in [source, target, state, outside]) {
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
  }
}

/// Unwraps a result, failing the test with the failure's text when it is not
/// a success.
QhtpReceiveResult expectReceived(Either<Failure, QhtpReceiveResult> result) {
  QhtpReceiveResult? ok;
  result.fold(
    (failure) =>
        fail('expected a successful receive, got "${failure.message}" '
            '(code ${failure.code})'),
    (value) => ok = value,
  );
  return ok!;
}

/// The failure, failing the test when the receive succeeded.
Failure expectRefused(Either<Failure, QhtpReceiveResult> result) {
  Failure? refused;
  result.fold(
    (failure) => refused = failure,
    (_) => fail('expected the receive to be refused, but it succeeded'),
  );
  return refused!;
}
