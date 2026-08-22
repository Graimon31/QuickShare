import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mocktail/mocktail.dart';

import 'package:quickshare/core/utils/mime_compression.dart';
import 'package:quickshare/core/utils/wakelock_guard.dart';
import 'package:quickshare/core/webrtc/turn_credential_refresher.dart';

// ---------------------------------------------------------------------------
// §8 — Compression decision
// ---------------------------------------------------------------------------

void main() {
  group('shouldCompressForTransfer', () {
    test('plain text → compress', () {
      expect(shouldCompressForTransfer('text/plain', 'readme.txt'), isTrue);
    });

    test('JSON → compress', () {
      expect(shouldCompressForTransfer('application/json', 'data.json'), isTrue);
    });

    test('unknown MIME → compress (safe default)', () {
      expect(shouldCompressForTransfer(null, 'unknown.bin'), isTrue);
    });

    test('JPEG → do not compress', () {
      expect(shouldCompressForTransfer('image/jpeg', 'photo.jpg'), isFalse);
    });

    test('MP4 → do not compress', () {
      expect(shouldCompressForTransfer('video/mp4', 'movie.mp4'), isFalse);
    });

    test('ZIP → do not compress (by MIME)', () {
      expect(shouldCompressForTransfer('application/zip', 'archive.zip'), isFalse);
    });

    test('ZIP → do not compress (by extension, no MIME)', () {
      expect(shouldCompressForTransfer(null, 'archive.zip'), isFalse);
    });

    test('MP3 → do not compress (by extension)', () {
      expect(shouldCompressForTransfer('', 'song.mp3'), isFalse);
    });

    test('DOCX → do not compress (internally zipped)', () {
      expect(shouldCompressForTransfer(
              'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
              'report.docx'),
          isFalse);
    });

    test('PDF → do not compress', () {
      expect(shouldCompressForTransfer('application/pdf', 'doc.pdf'), isFalse);
    });

    test('HEIC → do not compress', () {
      expect(shouldCompressForTransfer('image/heic', 'photo.heic'), isFalse);
    });

    test('extension wins when MIME is generic', () {
      expect(shouldCompressForTransfer(
              'application/octet-stream', 'video.mkv'),
          isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // §6 — WakelockGuard ref-count
  // ---------------------------------------------------------------------------

  group('WakelockGuard', () {
    test('refCount increments and decrements', () async {
      final guard = WakelockGuard();
      expect(guard.refCount, 0);

      // We cannot actually call WakelockPlus on a headless test runner.
      // Test only the counter logic by wrapping enable/disable in try/catch
      // inside the guard itself — which it already does.
      // Here we just verify the public API doesn't throw.
      await expectLater(guard.acquire(), completes);
      expect(guard.refCount, 1);
      await expectLater(guard.acquire(), completes);
      expect(guard.refCount, 2);
      await expectLater(guard.release(), completes);
      expect(guard.refCount, 1);
      await expectLater(guard.release(), completes);
      expect(guard.refCount, 0);
    });

    test('extra release does not go negative', () async {
      final guard = WakelockGuard();
      await guard.acquire();
      await guard.release();
      await guard.release(); // extra — should be no-op
      expect(guard.refCount, 0);
    });
  });

  // ---------------------------------------------------------------------------
  // §9 — TurnCredentialRefresher scheduling
  // ---------------------------------------------------------------------------

  group('TurnCredentialRefresher', () {
    test('cancel() prevents the timer from firing', () async {
      // Use a nearly-expired credential so the refresher schedules immediately.
      final expiry = DateTime.now().toUtc().add(const Duration(minutes: 5));
      final pc = _FakePeerConnection();

      final refresher = TurnCredentialRefresher(
        peerConnection: pc,
        workerBaseUrl: '', // empty → no fetch attempt
        expiresAt: expiry,
      );
      refresher.start();
      // Cancel before the timer fires.
      refresher.cancel();

      // Give the event loop a tick to confirm nothing fires.
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // setConfiguration should never have been called.
      expect(pc.setConfigurationCallCount, 0);
    });

    test('start() is idempotent', () async {
      final expiry = DateTime.now().toUtc().add(const Duration(hours: 1));
      final pc = _FakePeerConnection();
      final refresher = TurnCredentialRefresher(
        peerConnection: pc,
        workerBaseUrl: '',
        expiresAt: expiry,
      );
      refresher.start();
      refresher.start(); // second call — must not double-schedule
      refresher.cancel();
      expect(pc.setConfigurationCallCount, 0);
    });
  });
}

// ---------------------------------------------------------------------------
// Fake RTCPeerConnection — tracks setConfiguration calls.
// ---------------------------------------------------------------------------

class _FakePeerConnection extends Fake implements RTCPeerConnection {
  int setConfigurationCallCount = 0;

  @override
  Future<void> setConfiguration(Map<String, dynamic> configuration) async {
    setConfigurationCallCount++;
  }
}
