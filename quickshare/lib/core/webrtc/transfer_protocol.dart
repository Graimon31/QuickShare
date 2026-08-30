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
/// ## Folders
///
/// An item carries `path` as well as `name`: the relative path it has to keep
/// on the far side, root folder included — `Trip/Day 1/IMG_0042.HEIC`. That is
/// what lets a folder travel as a folder instead of being flattened or zipped.
/// `path` is omitted when it would only repeat `name`, which is every plain
/// file, so an ordinary multi-file manifest is byte-for-byte what it was.
///
/// ## Large manifests
///
/// A folder can hold tens of thousands of files, and one JSON frame listing
/// them all would be several megabytes — well past what a DataChannel will
/// carry in a single message. Past [maxManifestFrameBytes] the manifest is
/// split instead:
///
/// ```
/// {"type":"manifest-begin","count":N,"totalBytes":B,"parts":P}
/// {"type":"manifest-part","index":0,"files":[...]}   ... up to P-1
/// ```
///
/// The receiver has the whole list once it has seen every part, and only then
/// does the first `file-start` arrive. Sessions small enough to fit keep
/// sending the single `manifest` frame.
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

  /// Openers for a manifest too large to fit one DataChannel message.
  static const manifestBegin = 'manifest-begin';
  static const manifestPart = 'manifest-part';

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

  /// The largest manifest frame this protocol will put on the wire.
  ///
  /// Well under the 64 KB the payload chunks already use, which is itself well
  /// under what libwebrtc will accept in one message. The headroom is for the
  /// estimate below being an estimate: it counts each item's own JSON and the
  /// envelope, not the encoder's exact output.
  static const int maxManifestFrameBytes = 49152;

  static String buildManifest(List<TransferItem> files) => jsonEncode({
        'type': manifest,
        'files': [for (final f in files) f.toJson()],
        'totalBytes': files.fold<int>(0, (sum, f) => sum + f.size),
      });

  /// The manifest as the frames it actually has to be sent in.
  ///
  /// One `manifest` frame whenever the whole list fits, which is every session
  /// this protocol used to be able to express. A folder of thousands of files
  /// does not fit, and a single frame that large is not sent slowly — it is
  /// refused outright by the data channel, taking the session with it. Those
  /// are split into a `manifest-begin` announcing how many parts follow, then
  /// the parts.
  static List<String> buildManifestFrames(
    List<TransferItem> files, {
    int maxFrameBytes = maxManifestFrameBytes,
  }) {
    final single = buildManifest(files);
    if (utf8.encode(single).length <= maxFrameBytes) return [single];

    final totalBytes = files.fold<int>(0, (sum, f) => sum + f.size);
    final frames = <String>[];
    final parts = <List<TransferItem>>[];

    // Room for `{"type":"manifest-part","index":NNNN,"files":[]}` and the
    // commas between entries, so a part cannot overshoot on its envelope.
    const envelopeBytes = 64;
    var current = <TransferItem>[];
    var currentBytes = envelopeBytes;
    for (final file in files) {
      final entryBytes = utf8.encode(jsonEncode(file.toJson())).length + 1;
      if (current.isNotEmpty && currentBytes + entryBytes > maxFrameBytes) {
        parts.add(current);
        current = <TransferItem>[];
        currentBytes = envelopeBytes;
      }
      current.add(file);
      currentBytes += entryBytes;
    }
    if (current.isNotEmpty) parts.add(current);

    frames.add(jsonEncode({
      'type': manifestBegin,
      'count': files.length,
      'totalBytes': totalBytes,
      'parts': parts.length,
    }));
    for (var index = 0; index < parts.length; index++) {
      frames.add(jsonEncode({
        'type': manifestPart,
        'index': index,
        'files': [for (final f in parts[index]) f.toJson()],
      }));
    }
    return frames;
  }

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

  /// Where this file sits inside the selection, relative to the destination.
  ///
  /// `IMG_0042.HEIC` for a file the sender picked directly, and
  /// `Trip/Day 1/IMG_0042.HEIC` for one inside a folder they picked. The
  /// receiver rebuilds those directories rather than flattening the tree —
  /// which is the whole reason a folder no longer has to be zipped to travel
  /// over this channel.
  ///
  /// Always POSIX-separated on the wire, whatever the sender's platform uses
  /// locally, and always relative: a receiver that is handed anything else
  /// treats it as hostile and falls back to [name].
  final String path;

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
    String? path,
  }) : path = path ?? name;

  /// Whether this item carries a folder structure to rebuild.
  bool get hasFolderPath => path != name;

  Map<String, dynamic> toJson() => {
        'name': name,
        'size': size,
        'mime': mimeType,
        'compressed': compressed,
        // Only when it says something `name` does not. Every plain file would
        // otherwise pay for a field that repeats its own name, and a manifest
        // of ten thousand of them pays ten thousand times.
        if (hasFolderPath) 'path': path,
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
    final rawPath = json['path'];
    return TransferItem(
      name: name,
      size: size,
      mimeType: json['mime'] as String? ?? 'application/octet-stream',
      compressed: json['compressed'] as bool? ?? false,
      // A sender on an older build sends no path at all, which is not an
      // error — it is a session with no folders in it.
      path: rawPath is String && rawPath.isNotEmpty ? rawPath : null,
    );
  }

  @override
  String toString() => 'TransferItem($name, $size bytes, $mimeType'
      '${hasFolderPath ? ', at $path' : ''}'
      '${compressed ? ', gzip' : ''})';
}
