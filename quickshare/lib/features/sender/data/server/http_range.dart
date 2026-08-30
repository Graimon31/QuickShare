/// Parsing of the `Range` request header for the QHTP file route.
///
/// Split out of the server so it can be tested without opening a socket. The
/// inline version it replaces had two defects that a unit test would have
/// caught immediately: a suffix range (`bytes=-500`) served the *first* 501
/// bytes instead of the last 500, and the end offset was taken from the client
/// verbatim, so `bytes=0-999999999` produced a `Content-Length` of a gigabyte
/// on a two-kilobyte file and the response died mid-flight with
/// "Content size below specified contentLength".
library;

enum RangeOutcome {
  /// No usable `Range` header — serve the whole representation with 200.
  ///
  /// Also covers syntactically invalid headers: RFC 9110 §14.2 says an invalid
  /// Range must be ignored rather than rejected.
  absent,

  /// Serve [ByteRangeResult.range] with 206.
  satisfiable,

  /// Serve 416 with `Content-Range: bytes * /size`.
  unsatisfiable,
}

/// An inclusive byte range, as used on the wire.
class ByteRange {
  final int start;
  final int end;

  const ByteRange(this.start, this.end);

  int get length => end - start + 1;

  @override
  String toString() => 'bytes $start-$end';

  @override
  bool operator ==(Object other) =>
      other is ByteRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}

class ByteRangeResult {
  final RangeOutcome outcome;
  final ByteRange? range;

  const ByteRangeResult(this.outcome, [this.range]);

  static const absent = ByteRangeResult(RangeOutcome.absent);
  static const unsatisfiable = ByteRangeResult(RangeOutcome.unsatisfiable);
}

/// Resolves [header] against a representation of [totalSize] bytes.
///
/// Only the single-range `bytes=` form is honoured. A multipart range request
/// is answered with the whole file, which RFC 9110 explicitly permits — the
/// receiver only ever asks for one open-ended range, so supporting
/// `multipart/byteranges` would be code with no caller.
ByteRangeResult parseRangeHeader(String? header, int totalSize) {
  if (header == null) return ByteRangeResult.absent;

  final trimmed = header.trim();
  // Range units are case-insensitive.
  if (!trimmed.toLowerCase().startsWith('bytes=')) {
    return ByteRangeResult.absent;
  }

  final spec = trimmed.substring(6).trim();
  if (spec.isEmpty || spec.contains(',')) return ByteRangeResult.absent;

  final dash = spec.indexOf('-');
  if (dash < 0) return ByteRangeResult.absent;

  final firstPart = spec.substring(0, dash).trim();
  final lastPart = spec.substring(dash + 1).trim();

  // An empty representation cannot satisfy any range at all.
  if (totalSize <= 0) return ByteRangeResult.unsatisfiable;

  if (firstPart.isEmpty) {
    // Suffix form: bytes=-N means the LAST N bytes, not the first N.
    if (lastPart.isEmpty) return ByteRangeResult.absent;
    final suffixLength = int.tryParse(lastPart);
    if (suffixLength == null) return ByteRangeResult.absent;
    if (suffixLength <= 0) return ByteRangeResult.unsatisfiable;
    final start = suffixLength >= totalSize ? 0 : totalSize - suffixLength;
    return ByteRangeResult(
        RangeOutcome.satisfiable, ByteRange(start, totalSize - 1));
  }

  final start = int.tryParse(firstPart);
  if (start == null) return ByteRangeResult.absent;
  if (start >= totalSize) return ByteRangeResult.unsatisfiable;

  if (lastPart.isEmpty) {
    // Open-ended: everything from start to the end of the representation.
    return ByteRangeResult(
        RangeOutcome.satisfiable, ByteRange(start, totalSize - 1));
  }

  final requestedEnd = int.tryParse(lastPart);
  if (requestedEnd == null) return ByteRangeResult.absent;
  if (requestedEnd < start) return ByteRangeResult.absent; // invalid, ignore

  // Clamping is what keeps Content-Length honest. Without it the header
  // promises bytes the file does not have and the connection is torn down.
  final end = requestedEnd >= totalSize ? totalSize - 1 : requestedEnd;
  return ByteRangeResult(RangeOutcome.satisfiable, ByteRange(start, end));
}
