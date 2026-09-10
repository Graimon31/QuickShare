import 'dart:convert';

import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/features/sender/domain/entities/qhtp_manifest.dart';

/// Why a manifest was refused before a byte of the transfer moved.
class ManifestRejected implements Exception {
  final String message;
  const ManifestRejected(this.message);
  @override
  String toString() => message;
}

/// Checks a manifest against the same limits the indexer enforces on the
/// sending side — from the receiver's side, where the sender is not trusted.
///
/// ## Why this exists
///
/// [FileIndexer] applies `qhtpMaxPathDepth`, `qhtpMaxRelPathChars`,
/// `qhtpMaxFileCount` and `qhtpManifestMaxBytes` while it walks a selection,
/// and every one of them is a limit on what a *hostile manifest* could ask
/// for: a tree thousands of levels deep, a path that will not fit any
/// filesystem, a JSON document sized to exhaust memory before it finishes
/// parsing. The receiver checked the file count and the session's byte total
/// and nothing else, so a sender that did not run the real indexer — or ran a
/// patched one — reached the loop that creates directories with none of it.
///
/// The walkthrough already promised the manifest-size check ("rejected if
/// Content-Length is above 32 MB"). It was never written.
class ManifestGuard {
  const ManifestGuard();

  /// Throws [ManifestRejected] if the raw body is too large to be a manifest
  /// for a session this build will accept.
  ///
  /// Checked against the byte length, before `jsonDecode`, because the point
  /// is to not parse a document built to be expensive to parse. A
  /// `Content-Length` header would let this happen even earlier, but it is
  /// advisory and a hostile server need not send an honest one — the body is
  /// the thing that is actually true.
  void checkSize(int bodyBytes) {
    if (bodyBytes > AppConstants.qhtpManifestMaxBytes) {
      final mb = (bodyBytes / (1024 * 1024)).toStringAsFixed(1);
      const limit = AppConstants.qhtpManifestMaxBytes ~/ (1024 * 1024);
      throw ManifestRejected(
          'The sending device offered a $mb MB manifest; this transfer '
          'accepts at most $limit MB.');
    }
  }

  /// Throws [ManifestRejected] if any item names a path this device should
  /// not be asked to create.
  ///
  /// Mirrors [FileIndexer._validatePathString] and its depth check. Traversal
  /// (`..`, absolute paths) is caught again in `materializePath` when the
  /// path is turned into a real one — this is the earlier, cheaper refusal
  /// that also stops the transfer starting at all.
  void checkPaths(QhtpManifest manifest) {
    for (final item in manifest.items) {
      final path = item.path;

      if (path.isEmpty) {
        throw const ManifestRejected('An item in the manifest has no path.');
      }
      if (utf8.encode(path).length > AppConstants.qhtpMaxRelPathChars) {
        throw const ManifestRejected('An item path is longer than the limit.');
      }

      final segments = path.split('/');
      if (segments.length > AppConstants.qhtpMaxPathDepth) {
        throw const ManifestRejected(
            'An item is nested deeper than the folder limit.');
      }
      for (final segment in segments) {
        if (segment.isEmpty || segment == '.' || segment == '..') {
          throw ManifestRejected('An item path contains "$segment".');
        }
        if (segment.contains(r'\') || segment.contains('\x00')) {
          throw const ManifestRejected(
              'An item path contains a character no filesystem accepts.');
        }
      }
    }
  }

  /// Both checks, in the order they get cheaper to run: size first, since it
  /// runs on bytes and short-circuits parsing entirely.
  void check({required int bodyBytes, required QhtpManifest manifest}) {
    checkSize(bodyBytes);
    checkPaths(manifest);
  }
}
