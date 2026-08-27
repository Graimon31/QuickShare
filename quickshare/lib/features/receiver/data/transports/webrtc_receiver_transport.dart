import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/utils/wakelock_guard.dart';
import 'package:quickshare/core/webrtc/ice_servers.dart';
import 'package:quickshare/core/webrtc/ice_gathering.dart';
import 'package:quickshare/core/webrtc/idle_watchdog.dart';
import 'package:quickshare/core/webrtc/sdp_compressor.dart';
import 'package:quickshare/core/webrtc/transfer_protocol.dart';
import 'package:quickshare/core/webrtc/turn_credential_refresher.dart';
import 'package:quickshare/features/sender/data/signaling/webrtc_signaling_client.dart';
import 'package:quickshare/features/sender/domain/entities/transfer_session.dart';
import 'package:quickshare/core/utils/app_logger.dart';

/// Raised when the sender deliberately stopped the transfer.
///
/// Separate from a generic failure so the screen can say "the sender
/// cancelled" instead of "connection error" — the two are the same silence on
/// the wire but mean opposite things to whoever is watching.
class TransferCancelledBySender implements Exception {
  const TransferCancelledBySender();

  @override
  String toString() => 'the sender cancelled the transfer';
}

/// Progress for a link-based (WebRTC) receive.
class WebRtcReceiveProgress {
  final String phase; // 'connecting' | 'transferring' | 'completed' | 'failed'
  final String fileName;
  final int received;
  final int total;
  final int speedBps;
  final String? detail;

  const WebRtcReceiveProgress({
    required this.phase,
    required this.fileName,
    required this.received,
    required this.total,
    required this.speedBps,
    this.detail,
  });
}

/// Receives a file over a WebRTC DataChannel after joining a share room.
class WebRtcReceiverTransport {
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  WebRtcSignalingClient? _signaling;
  StreamSubscription<Map<String, dynamic>>? _signalSub;

  final _progressController =
      StreamController<WebRtcReceiveProgress>.broadcast();
  final _statusController = StreamController<TransferStatus>.broadcast();

  Stream<WebRtcReceiveProgress> get progressStream => _progressController.stream;
  Stream<TransferStatus> get statusStream => _statusController.stream;

  final _completion = Completer<String>();

  int _totalBytes = 0;
  int _receivedBytes = 0;
  IOSink? _fileSink;
  String _fileName = 'received_file';
  String? _targetPath;
  bool _isRemoteDescSet = false;
  final List<RTCIceCandidate> _pendingCandidates = [];

  DateTime _lastTick = DateTime.now();
  int _lastBytes = 0;
  int _speedBps = 0;
  String _baseDir = '';
  final _gathering = IceGatheringTracker();

  /// Watches for the peer going silent mid-transfer — the serverless path has
  /// no signaling channel to report a disconnect through, so ICE state and a
  /// lack of incoming bytes are the only signals available.
  IdleWatchdog? _idleWatchdog;
  static const _idleTimeout = Duration(seconds: 30);

  /// How long ICE may sit in `disconnected` before giving up — matches the
  /// sender's grace period ([WebRtcTransferTransport._iceRecoveryGrace]) for
  /// the same reason: routine on a relay path under a VPN, not fatal on its
  /// own.
  static const _iceRecoveryGrace = Duration(seconds: 20);
  Timer? _iceRecoveryTimer;

  /// §8 — whether the incoming binary stream is gzip-compressed.
  bool _isCompressed = false;

  /// Set when the sender announced it was stopping, so the ICE teardown that
  /// follows is not reported a second time as a connection error.
  bool _cancelledBySender = false;

  /// The manifest for a multi-file session, and where we are inside it.
  ///
  /// Empty for a legacy single-file sender, which opens with `file-meta` and
  /// never sends a manifest — that path is kept working rather than treated as
  /// a protocol error, because an older build is not a broken peer.
  List<TransferItem> _manifest = const [];

  /// Absolute paths of everything written so far, in manifest order.
  final List<String> _writtenPaths = [];

  /// Bytes across the entire session, so progress does not snap back to zero
  /// once per file.
  int _sessionTotalBytes = 0;
  int _sessionReceivedBytes = 0;

  List<String> get receivedPaths => List.unmodifiable(_writtenPaths);

  /// §6 — keeps CPU/display alive during the transfer.
  final _wakelockGuard = WakelockGuard();

  /// §9 — refreshes TURN credentials before they expire.
  TurnCredentialRefresher? _turnRefresher;

  /// A backstop against `_completion` never resolving at all, not a deadline
  /// on how long a transfer may take.
  ///
  /// Real failure detection is `_onIceStateChanged` plus the idle watchdog
  /// (armed once data starts flowing, in `_handleMessage`). This used to be
  /// 75 seconds counted across the *entire* transfer rather than just
  /// connection setup — the same bug `receiveWithSdpOffer` had and was fixed
  /// for, just not here. Any file that took longer than 75s over a relay was
  /// killed by this method while still healthy; at the ~1-3 MB/s a TURN
  /// relay realistically manages, that is anything upward of roughly 100 MB.
  static const _transferBackstop = Duration(minutes: 30);

  String sanitizeFileName(String name) {
    final base = p
        .basename(name)
        .replaceAll(RegExp(r'[\x00-\x1F\x7F/\\:*?"<>|]'), '_')
        .trim();
    if (base.isEmpty || base.replaceAll('.', '').isEmpty) return 'received_file';
    return base;
  }

  String resolveTargetPath(String fileName, String baseDir) {
    // An empty base makes p.isWithin('', 'photo.jpg') return true and the
    // guard below wave through a relative path, which lands the file in the
    // process working directory. Reject it outright rather than trusting every
    // caller to have set the destination.
    if (baseDir.isEmpty || !p.isAbsolute(baseDir)) {
      throw Exception('Receive directory is not set (got "$baseDir")');
    }
    final resolved = p.normalize(p.join(baseDir, sanitizeFileName(fileName)));
    if (!p.isWithin(baseDir, resolved)) {
      throw Exception('Path traversal detected in "$fileName"');
    }
    return resolved;
  }

  Future<Map<String, dynamic>> _buildIceConfiguration() =>
      IceServers.configurationDynamic();

  /// Starts the TURN credential refresh timer (§9).
  Future<void> _startTurnRefresher({DateTime? expiresAt}) async {
    _turnRefresher?.cancel();
    final workerUrl = AppConstants.workerBaseUrl.trim();
    if (workerUrl.isEmpty || _peerConnection == null) return;

    _turnRefresher = TurnCredentialRefresher(
      peerConnection: _peerConnection!,
      workerBaseUrl: workerUrl,
      expiresAt: expiresAt,
    );
    _turnRefresher!.start();
  }

  /// Connects serverlessly using an [sdpOffer] carried in the QR code.
  ///
  /// The answer goes back through [deliverAnswer] — a sealed drop through
  /// public infrastructure. An earlier version posted it straight to an
  /// address in the QR code instead, which could only ever work when the
  /// sender was reachable from the internet; the measurements in
  /// natfilter_result.txt showed a port-restricted NAT where that request
  /// never arrives, so both halves of that path are gone.
  Future<String> receiveWithSdpOffer(
    String sdpOffer, {
    String? targetDir,
    Future<void> Function(String answerSdp)? deliverAnswer,
  }) async {
    try {
      _emit('connecting', detail: 'Processing serverless SDP offer…');
      _statusController.add(TransferStatus.connecting);
      await _wakelockGuard.acquire(); // §6

      // This path returns a completer of its own; `_completion` belongs to the
      // room-based receive() and nothing here awaits it. _fail() still
      // completes it, so without a handler every serverless failure surfaces
      // as an unhandled async error alongside the real one.
      unawaited(_completion.future.then((_) {}, onError: (Object _) {}));

      // Resolve the destination before anything can arrive. Leaving this unset
      // used to make resolveTargetPath() return a bare relative name, which
      // put the incoming file in the process working directory — read-only
      // inside the iOS sandbox, and a surprise on desktop.
      _baseDir = targetDir ?? (await getApplicationDocumentsDirectory()).path;
      final baseDirectory = Directory(_baseDir);
      if (!baseDirectory.existsSync()) {
        baseDirectory.createSync(recursive: true);
      }

      final rawSdp = SdpCompressor.decompress(sdpOffer);

      _peerConnection = await createPeerConnection(await _buildIceConfiguration());
      await _startTurnRefresher(); // §9

      _peerConnection!.onDataChannel = (RTCDataChannel channel) {
        debugPrint('WebRTC receiver serverless: data channel received');
        _dataChannel = channel;
        channel.onMessage = _handleMessage;
      };

      // The answer is sealed and published once; like the offer, it has no
      // trickle path, so gathering has to finish before it is encoded.
      _peerConnection!.onIceCandidate = _gathering.observe;

      // This path previously had no ICE-state reaction whatsoever — a dead
      // connection here produced no error until the flat 120s timeout further
      // down expired, and that timeout counted the whole transfer, not just
      // the time since the connection actually died.
      _peerConnection!.onIceConnectionState = _onIceStateChanged;

      AppLogger.info('Receiver: decompressed offer, ${rawSdp.length} chars',
          tag: 'WEBRTC_RECEIVER');

      try {
        await _peerConnection!.setRemoteDescription(RTCSessionDescription(rawSdp, 'offer'));
      } catch (e, st) {
        AppLogger.error('Receiver setRemoteDescription failed for SDP length ${rawSdp.length}', error: e, stackTrace: st, tag: 'WEBRTC_RECEIVER');
        rethrow;
      }
      final answer = await _peerConnection!.createAnswer();
      await _peerConnection!.setLocalDescription(answer);

      await waitForUsableCandidates(_peerConnection!, _gathering,
          tag: 'WEBRTC_RECEIVER');

      final fullLocalDesc = await _peerConnection!.getLocalDescription();
      final finalAnswerSdp = fullLocalDesc?.sdp ?? answer.sdp;

      if (deliverAnswer != null) {
        AppLogger.info(
            'Receiver: delivering SDP answer through the signaling channel '
            '(${finalAnswerSdp?.length ?? 0} chars)',
            tag: 'WEBRTC_RECEIVER');
        await deliverAnswer(finalAnswerSdp ?? '');
      }

      final completer = Completer<String>();

      late StreamSubscription sub;
      sub = _statusController.stream.listen((status) {
        if (status == TransferStatus.completed) {
          sub.cancel();
          if (!completer.isCompleted) {
            completer.complete(_targetPath ?? p.join(_baseDir, 'received_file'));
          }
        } else if (status == TransferStatus.failed) {
          sub.cancel();
          if (!completer.isCompleted) {
            // This is what the caller actually awaits, so the distinction
            // between a deliberate stop and a broken connection has to survive
            // here too — `_completion` carries it, but nothing awaits that one.
            completer.completeError(_cancelledBySender
                ? const TransferCancelledBySender()
                : Exception('Serverless WebRTC transfer failed'));
          }
        }
      });

      // Real failure detection is _onIceStateChanged + the idle watchdog now;
      // this is only a backstop against a Future that never resolves for some
      // other reason. It used to be 120s counted across the *entire* transfer
      // rather than just connection setup, which would have killed any file
      // that took longer than two minutes over a relay even while healthy.
      return completer.future.timeout(
        const Duration(minutes: 30),
        onTimeout: () {
          sub.cancel();
          throw Exception(
              'Serverless transfer timed out (30 min backstop) without '
              'reaching a completed or failed state');
        },
      );
    } on TransferCancelledBySender {
      // Deliberate, and already reported. Re-wrapping it as a generic failure
      // here would undo the distinction the whole message exists to make.
      await _wakelockGuard.release(); // §6
      rethrow;
    } catch (e) {
      await _wakelockGuard.release(); // §6
      _statusController.add(TransferStatus.failed);
      throw Exception('receiveWithSdpOffer failed: $e');
    }
  }

  /// Joins [roomCode] on [signalingUrl] (or [AppConstants.signalingServerUrl]).
  Future<String> receive(
    String roomCode, {
    String? targetDir,
    String? signalingUrl,
  }) async {
    try {
      _emit('connecting',
          detail: 'Contacting signaling server…');
      _statusController.add(TransferStatus.connecting);
      await _wakelockGuard.acquire(); // §6

      final url = (signalingUrl != null && signalingUrl.isNotEmpty)
          ? signalingUrl
          : AppConstants.signalingServerUrl;

      if (url.contains('localhost') || url.contains('127.0.0.1')) {
        throw Exception(
          'Signaling URL is localhost ($url). The phone cannot reach the '
          'sender\'s loopback. Rebuild the sender so the share link includes '
          'sig=ws://<sender-lan-ip>:3000, run signaling_server on the Mac, '
          'and keep the phone on the same Wi‑Fi (not LTE-only).',
        );
      }

      _signaling = WebRtcSignalingClient(serverUrl: url);

      _peerConnection = await createPeerConnection(await _buildIceConfiguration());
      await _startTurnRefresher(); // §9

      _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
        if (candidate.candidate == null) return;
        _signaling?.sendIceCandidate({
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        });
      };

      // The shared handler rather than a bespoke inline one: this used to
      // fail the instant ICE reported Disconnected, with no grace period —
      // a momentary blip (normal, recoverable) killed the transfer outright.
      // `_onIceStateChanged` gives it `_iceRecoveryGrace` (20s) to recover
      // before giving up, same as the QR/serverless path already does.
      _peerConnection!.onIceConnectionState = _onIceStateChanged;

      _peerConnection!.onDataChannel = (RTCDataChannel channel) {
        debugPrint('WebRTC receiver: data channel received');
        _dataChannel = channel;
        channel.onMessage = _handleMessage;
      };

      final baseDir = targetDir ??
          (await getDownloadsDirectory())?.path ??
          (await getApplicationDocumentsDirectory()).path;

      _signalSub = _signaling!.messages.listen((msg) async {
        try {
          switch (msg['type']) {
            case 'offer':
              _emit('connecting', detail: 'Negotiating peer connection…');
              await _handleOffer(
                  Map<String, dynamic>.from(msg['payload'] as Map));
              break;
            case 'ice-candidate':
              await _handleRemoteCandidate(
                  Map<String, dynamic>.from(msg['payload'] as Map));
              break;
            case 'peer-disconnected':
              if (!_completion.isCompleted) {
                if (_totalBytes > 0 && _receivedBytes >= _totalBytes) {
                  await _fileSink?.flush();
                  await _fileSink?.close();
                  _fileSink = null;
                  _statusController.add(TransferStatus.completed);
                  _emit('completed');
                  if (!_completion.isCompleted) {
                    _completion.complete(_targetPath ?? '');
                  }
                  await _cleanup();
                } else {
                  _fail('Sender disconnected before the transfer finished');
                }
              }
              break;
          }
        } catch (e) {
          _fail('Signaling error: $e');
        }
      });

      _emit('connecting', detail: 'Joining room $roomCode…');
      await _signaling!.joinRoom(roomCode);
      _baseDir = baseDir;
      _emit('connecting',
          detail:
              'Waiting for sender peer connection (keep the Mac share screen open)…');

      return await _completion.future.timeout(
        _transferBackstop,
        onTimeout: () {
          throw Exception(
            'No transfer completion after ${_transferBackstop.inMinutes} '
            'minutes. If nothing was happening at all, check:\n'
            '• Signaling server running on the sender machine\n'
            '• Share link contains sig=ws://… and phone can open that host:port\n'
            '• Same Wi‑Fi for LAN signaling (LTE often needs TURN)\n'
            '• Sender still on the Share / QR screen',
          );
        },
      );
    } catch (e) {
      await _wakelockGuard.release(); // §6
      _statusController.add(TransferStatus.failed);
      await _cleanup();
      rethrow;
    }
  }

  Future<void> _handleOffer(Map<String, dynamic> payload) async {
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(
          payload['sdp'] as String?, payload['type'] as String?),
    );
    _isRemoteDescSet = true;

    for (final c in _pendingCandidates) {
      await _peerConnection!.addCandidate(c);
    }
    _pendingCandidates.clear();

    final answer = await _peerConnection!.createAnswer();
    await _peerConnection!.setLocalDescription(answer);
    _signaling!.sendAnswer({'sdp': answer.sdp, 'type': answer.type});
  }

  Future<void> _handleRemoteCandidate(Map<String, dynamic> payload) async {
    final candidate = RTCIceCandidate(
      payload['candidate'] as String?,
      payload['sdpMid'] as String?,
      payload['sdpMLineIndex'] as int?,
    );
    if (_isRemoteDescSet) {
      await _peerConnection!.addCandidate(candidate);
    } else {
      _pendingCandidates.add(candidate);
    }
  }

  /// Serialises message handling.
  ///
  /// `onMessage` is a `void` callback, so an async handler assigned to it is
  /// invoked without ever being awaited: the next message starts running while
  /// the previous one is parked on a flush or a close. With per-file framing
  /// that is immediately fatal — `file-end` closes the sink while a chunk of
  /// the same file is still being written, and the write lands on a closed
  /// StreamSink. Chaining every message onto one future restores the ordering
  /// the wire protocol already guarantees.
  Future<void> _handlerChain = Future<void>.value();

  void _handleMessage(RTCDataChannelMessage message) {
    _handlerChain = _handlerChain.then((_) => _processMessage(message));
  }

  /// §8 — handles incoming DataChannel messages.
  ///
  /// Binary messages are decompressed if the sender advertised
  /// `"compressed": true` in the `file-meta` JSON.
  Future<void> _processMessage(RTCDataChannelMessage message) async {
    try {
      if (message.isBinary) {
        if (_fileSink == null) return;

        // §8: decompress if the sender said so.
        final bytes = _isCompressed
            ? GZipDecoder().decodeBytes(message.binary)
            : message.binary;

        _idleWatchdog?.kick();
        _fileSink!.add(bytes);
        _receivedBytes += bytes.length;
        // Progress is reported across the whole session, so a ten-photo
        // transfer does not snap back to 0% ten times.
        _sessionReceivedBytes += bytes.length;

        final now = DateTime.now();
        final delta = now.difference(_lastTick).inMilliseconds / 1000.0;
        if (delta >= 0.5) {
          _speedBps = ((_sessionReceivedBytes - _lastBytes) / delta).round();
          _lastTick = now;
          _lastBytes = _sessionReceivedBytes;
        }
        _emit('transferring');
        return;
      }

      final data = jsonDecode(message.text) as Map<String, dynamic>;
      final type = data['type'] as String?;

      switch (type) {
        case TransferProtocol.manifest:
          _manifest = TransferProtocol.parseManifest(data);
          _sessionTotalBytes =
              _manifest.fold<int>(0, (sum, i) => sum + i.size);
          _sessionReceivedBytes = 0;
          _writtenPaths.clear();
          _totalBytes = _sessionTotalBytes;
          _receivedBytes = 0;
          _lastBytes = 0;
          _lastTick = DateTime.now();
          _fileName = _manifest.length == 1
              ? sanitizeFileName(_manifest.first.name)
              : '${_manifest.length} files';
          _statusController.add(TransferStatus.transferring);
          _emit('transferring');
          _armIdleWatchdog();
          AppLogger.info(
              'Receiving ${_manifest.length} file(s), '
              '$_sessionTotalBytes bytes total',
              tag: 'WEBRTC_RECEIVER');

        case TransferProtocol.fileStart:
          final index = data['index'] as int?;
          if (index == null || index < 0 || index >= _manifest.length) {
            _fail('file-start referred to item $index, '
                'which is not in a manifest of ${_manifest.length}');
            return;
          }
          final item = _manifest[index];
          _isCompressed = item.compressed;
          _targetPath =
              _uniquePath(resolveTargetPath(sanitizeFileName(item.name), _baseDir));
          _fileSink = File(_targetPath!).openWrite();
          _emit('transferring');

        case TransferProtocol.fileEnd:
          await _fileSink?.flush();
          await _fileSink?.close();
          _fileSink = null;
          if (_targetPath != null) _writtenPaths.add(_targetPath!);

        case TransferProtocol.legacyFileMeta:
        case TransferProtocol.legacyMetadata:
          // Single-file sender on an older build: synthesise a one-item
          // manifest so everything downstream sees one shape.
          final item = TransferItem(
            name: data['name'] as String? ?? 'received_file',
            size: data['size'] as int? ?? 0,
            mimeType: data['mime'] as String? ?? 'application/octet-stream',
            compressed: (data['compressed'] as bool?) ?? false,
          );
          _manifest = [item];
          _sessionTotalBytes = item.size;
          _sessionReceivedBytes = 0;
          _writtenPaths.clear();
          _fileName = sanitizeFileName(item.name);
          _totalBytes = item.size;
          _isCompressed = item.compressed;
          _receivedBytes = 0;
          _lastBytes = 0;
          _lastTick = DateTime.now();
          _targetPath = _uniquePath(resolveTargetPath(_fileName, _baseDir));
          _fileSink = File(_targetPath!).openWrite();
          _statusController.add(TransferStatus.transferring);
          _emit('transferring');
          _armIdleWatchdog();

        case TransferProtocol.cancelled:
          // Deliberate stop: react now rather than waiting out the disconnect
          // grace period, and say what actually happened.
          AppLogger.info('Sender cancelled the transfer',
              tag: 'WEBRTC_RECEIVER');
          await _fileSink?.flush();
          await _fileSink?.close();
          _fileSink = null;
          _cancelledBySender = true;
          _idleWatchdog?.cancel();
          _fail('The sender cancelled the transfer');

        case TransferProtocol.complete:
        case TransferProtocol.legacyFileComplete:
          // A legacy sender closes the only file here rather than with
          // file-end, so flush whatever is still open.
          await _fileSink?.flush();
          await _fileSink?.close();
          _fileSink = null;
          if (_targetPath != null && !_writtenPaths.contains(_targetPath)) {
            _writtenPaths.add(_targetPath!);
          }
          _idleWatchdog?.cancel();

          if (_sessionTotalBytes > 0 &&
              _sessionReceivedBytes < _sessionTotalBytes) {
            _fail('Transfer completed prematurely: received '
                '$_sessionReceivedBytes of $_sessionTotalBytes bytes');
          } else {
            _statusController.add(TransferStatus.completed);
            _emit('completed');
            if (!_completion.isCompleted) {
              _completion.complete(_writtenPaths.isNotEmpty
                  ? _writtenPaths.first
                  : (_targetPath ?? ''));
            }
            await _cleanup();
          }
      }
    } catch (e) {
      _fail('Failed to write incoming file: $e');
    }
  }

  void _armIdleWatchdog() {
    _idleWatchdog ??= IdleWatchdog(
      timeout: _idleTimeout,
      onTimeout: () => _fail(
          'No data received for ${_idleTimeout.inSeconds}s — the '
          'connection appears to have died'),
    );
    _idleWatchdog!.kick();
  }

  String _uniquePath(String path) {
    var candidate = path;
    var counter = 1;
    while (File(candidate).existsSync()) {
      final ext = p.extension(path);
      final stem = p.basenameWithoutExtension(path);
      candidate = p.join(p.dirname(path), '$stem ($counter)$ext');
      counter++;
    }
    return candidate;
  }

  void _emit(String phase, {String? detail}) {
    if (_progressController.isClosed) return;
    _progressController.add(WebRtcReceiveProgress(
      phase: phase,
      fileName: _fileName,
      received: _sessionReceivedBytes,
      total: _sessionTotalBytes,
      speedBps: _speedBps,
      detail: detail,
    ));
  }

  /// Reacts to ICE state changes on the serverless path, which — unlike the
  /// room-based `receive()` — has no signaling channel left to carry a
  /// `peer-disconnected` message, so this and the idle watchdog are the only
  /// ways a dead connection is ever noticed here.
  ///
  /// `disconnected` gets a grace period rather than an immediate failure: it
  /// is routine on a relayed path under a VPN and usually recovers within
  /// seconds. Failing on the first blip would abort transfers that were never
  /// actually broken.
  void _onIceStateChanged(RTCIceConnectionState state) {
    AppLogger.info('Receiver ICE state: $state', tag: 'WEBRTC_RECEIVER');

    // A cancelled session tears its connection down by design; reporting that
    // as a fault would overwrite the real reason with a misleading one.
    if (_cancelledBySender) return;

    switch (state) {
      case RTCIceConnectionState.RTCIceConnectionStateConnected:
      case RTCIceConnectionState.RTCIceConnectionStateCompleted:
        _iceRecoveryTimer?.cancel();
        _iceRecoveryTimer = null;
      case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
        _iceRecoveryTimer?.cancel();
        _iceRecoveryTimer = Timer(_iceRecoveryGrace, () {
          _fail('ICE stayed disconnected for '
              '${_iceRecoveryGrace.inSeconds}s — giving up on this session');
        });
      case RTCIceConnectionState.RTCIceConnectionStateFailed:
      case RTCIceConnectionState.RTCIceConnectionStateClosed:
        _iceRecoveryTimer?.cancel();
        _iceRecoveryTimer = null;
        _fail('Peer connection failed (ICE $state)');
      default:
        break;
    }
  }

  void _fail(String reason) {
    debugPrint('WebRTC receive failed: $reason');
    _statusController.add(TransferStatus.failed);
    _emit('failed', detail: reason);
    if (!_completion.isCompleted) {
      _completion.completeError(_cancelledBySender
          ? const TransferCancelledBySender()
          : Exception(reason));
    }
    _cleanup();
  }

  Future<void> _cleanup() async {
    _idleWatchdog?.cancel();
    _iceRecoveryTimer?.cancel();
    _iceRecoveryTimer = null;
    _turnRefresher?.cancel(); // §9
    _turnRefresher = null;
    await _wakelockGuard.release(); // §6
    await _signalSub?.cancel();
    _signalSub = null;
    await _signaling?.dispose();
    _signaling = null;
    await _dataChannel?.close();
    _dataChannel = null;
    await _peerConnection?.close();
    _peerConnection = null;
  }

  Future<void> cancel() async {
    await _fileSink?.close();
    _fileSink = null;
    if (_targetPath != null) {
      final partial = File(_targetPath!);
      if (await partial.exists()) await partial.delete();
    }
    _statusController.add(TransferStatus.cancelled);
    if (!_completion.isCompleted) {
      _completion.completeError(Exception('Cancelled by user'));
    }
    await _cleanup();
  }
}
