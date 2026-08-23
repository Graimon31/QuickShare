/// Decides whether a file should be compressed before being sent over a
/// DataChannel or BLE characteristic.
///
/// Compressing already-compressed formats wastes CPU and typically makes the
/// payload *larger* — a ZIP of a JPEG is bigger than the JPEG itself. Only
/// formats that are actually compressible benefit.
///
/// The list is conservative by design: unknown types default to "try
/// compressing" because the cost of a useless gzip pass is small (~5 ms for
/// a 16 KB chunk on a mid-range device) while the cost of skipping compression
/// on a compressible format (text, JSON logs, raw sensor data) is unbounded.
library mime_compression;

/// Returns `true` when the payload should be run through gzip before sending.
///
/// [mime] is the MIME type reported by the sender (may be null or empty).
/// [name] is the file basename, used as a fallback when [mime] is generic.
bool shouldCompressForTransfer(String? mime, String name) {
  final m = (mime ?? '').toLowerCase().trim();
  final ext = _ext(name).toLowerCase();

  // Already-compressed containers — skip.
  if (_alreadyCompressedMime(m)) return false;
  if (_alreadyCompressedExt(ext)) return false;

  return true;
}

/// Extracts the lowercase extension (without the dot), e.g. "mp4" from
/// "movie.MP4". Returns '' for names with no dot.
String _ext(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1);
}

bool _alreadyCompressedMime(String m) {
  if (m.isEmpty) { return false; }
  // Image formats
  if (m.startsWith('image/jpeg') ||
      m.startsWith('image/jpg') ||
      m.startsWith('image/png') ||
      m.startsWith('image/gif') ||
      m.startsWith('image/webp') ||
      m.startsWith('image/heic') ||
      m.startsWith('image/heif') ||
      m.startsWith('image/avif') ||
      m.startsWith('image/bmp')) { return true; } // bmp compresses but poorly

  // Video
  if (m.startsWith('video/')) { return true; }

  // Audio
  if (m.startsWith('audio/')) { return true; }

  // Archives / compressed containers
  if (m == 'application/zip' ||
      m == 'application/x-zip-compressed' ||
      m == 'application/gzip' ||
      m == 'application/x-gzip' ||
      m == 'application/x-bzip2' ||
      m == 'application/x-xz' ||
      m == 'application/x-7z-compressed' ||
      m == 'application/x-rar-compressed' ||
      m == 'application/vnd.rar' ||
      m == 'application/x-tar' ||
      m == 'application/zstd') { return true; }

  // Office formats (internally zipped)
  if (m == 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' ||
      m == 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' ||
      m == 'application/vnd.openxmlformats-officedocument.presentationml.presentation' ||
      m == 'application/vnd.oasis.opendocument.text' ||
      m == 'application/vnd.oasis.opendocument.spreadsheet' ||
      m == 'application/epub+zip') { return true; }

  // PDF is compressed internally — marginal benefit, skip gzip pass.
  if (m == 'application/pdf') { return true; }

  return false;
}

bool _alreadyCompressedExt(String ext) {
  const compressed = {
    // Images
    'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'heif', 'avif',
    // Camera RAW. Not obvious from the name, and no MIME type resolves for
    // any of them, so without this a 60 MB frame off a DSLR gets a full gzip
    // pass on the send path for nothing: the formats already carry their own
    // lossless compression internally. Uncompressed TIFF is deliberately not
    // here — that one really does shrink.
    'dng', 'cr2', 'cr3', 'nef', 'arw', 'orf', 'raf', 'rw2', 'mrw', 'srf',
    // Video
    'mp4', 'mkv', 'mov', 'avi', 'webm', 'm4v', 'wmv', 'flv', 'ts', 'mts',
    'm2ts', '3gp', 'mpg', 'mpeg', 'vob', 'mxf', 'asf', 'ogv', 'f4v', 'divx',
    'rm', 'rmvb',
    // Audio
    'mp3', 'aac', 'ogg', 'opus', 'flac', 'm4a', 'wma', 'wav', // wav is PCM but big
    // Archives
    'zip', 'gz', 'bz2', 'xz', '7z', 'rar', 'zst', 'br',
    // Office (OOXML / ODF are zipped)
    'docx', 'xlsx', 'pptx', 'odt', 'ods', 'odp', 'epub',
    // Documents
    'pdf',
    // Packages
    'apk', 'ipa', 'deb', 'rpm', 'dmg', 'pkg', 'jar', 'war', 'ear',
    // Fonts (often compressed)
    'woff', 'woff2',
  };
  return compressed.contains(ext);
}
