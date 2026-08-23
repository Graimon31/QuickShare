import 'dart:convert';

/// The control messages the sender and receiver exchange over the DataChannel.
///
/// Kept in one file so the two transports cannot drift: they are written in
/// separate layers of the app and every earlier protocol change had to be
/// mirrored by hand in both.
///
/// ## Wire format
///
/// Text frames are JSON control messages, binary frames are payload bytes for
/// whichever file is currently open. A multi-file session looks like:
///
/// ```
/// {"type":"manifest","files":[{...},{...}],"totalBytes":N}
/// {"type":"file-start","index":0}   <binary>...   {"type":"file-end","index":0}
/// {"type":"file-start","index":1}   <binary>...   {"type":"file-end","index":1}
/// {"type":"complete"}
/// ```
///
/// ## Compatibility
///
/// A sender that only knows the old single-file protocol opens with
/// `file-meta` instead of `manifest` and never sends `file-start`/`file-end`.
/// [TransferProtocol.isLegacySingleFile] identifies that case so the receiver
/// can keep handling it — an app on an older build is not a corrupt peer.
class TransferProtocol {
  const TransferProtocol._();

  static const manifest = 'manifest';
  static const fileStart = 'file-start';
  static const fileEnd = 'file-end';
  static const complete = 'complete';

  /// The sender is stopping on purpose.
  ///
  /// Without it the receiver cannot tell "the person on the other end pressed
  /// Cancel" from "the network dropped": both look like the channel going
  /// quiet, and the receiver has to sit through its disconnect grace period
  /// before saying anything at all. A deliberate stop should be immediate and
  /// should say so.
  static const cancelled = 'cancelled';

  /// Older single-file openers, both spellings that have shipped.
  static const legacyFileMeta = 'file-meta';
  static const legacyMetadata = 'metadata';
  static const legacyFileComplete = 'file-complete';

  static bool isLegacySingleFile(String? type) =>
      type == legacyFileMeta || type == legacyMetadata;

  static String buildManifest(List<TransferItem> files) => jsonEncode({
        'type': manifest,
        'files': [for (final f in files) f.toJson()],
        'totalBytes': files.fold<int>(0, (sum, f) => sum + f.size),
      });

  static String buildFileStart(int index) =>
      jsonEncode({'type': fileStart, 'index': index});

  static String buildFileEnd(int index) =>
      jsonEncode({'type': fileEnd, 'index': index});

  static String buildComplete() => jsonEncode({'type': complete});

  static String buildCancelled() => jsonEncode({'type': cancelled});

  /// Parses a manifest body into its items.
  ///
  /// Throws [FormatException] on anything malformed rather than returning a
  /// half-built list: a session that starts from a manifest nobody can read
  /// would write files to unpredictable places.
  static List<TransferItem> parseManifest(Map<String, dynamic> json) {
    final raw = json['files'];
    if (raw is! List || raw.isEmpty) {
      throw const FormatException('manifest carries no files');
    }
    return [
      for (final entry in raw)
        TransferItem.fromJson(Map<String, dynamic>.from(entry as Map)),
    ];
  }
}

/// One file inside a transfer session.
class TransferItem {
  final String name;
  final int size;
  final String mimeType;

  /// Whether the payload bytes for this item are gzip-compressed per chunk.
  ///
  /// Decided per item rather than per session: a folder of documents and
  /// photos should compress the documents and leave the photos alone.
  final bool compressed;

  const TransferItem({
    required this.name,
    required this.size,
    required this.mimeType,
    required this.compressed,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'size': size,
        'mime': mimeType,
        'compressed': compressed,
      };

  factory TransferItem.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    if (name is! String || name.isEmpty) {
      throw const FormatException('manifest item has no name');
    }
    final size = json['size'];
    if (size is! int || size < 0) {
      throw FormatException('manifest item "$name" has an invalid size');
    }
    return TransferItem(
      name: name,
      size: size,
      mimeType: json['mime'] as String? ?? 'application/octet-stream',
      compressed: json['compressed'] as bool? ?? false,
    );
  }

  @override
  String toString() => 'TransferItem($name, $size bytes, $mimeType'
      '${compressed ? ', gzip' : ''})';
}
