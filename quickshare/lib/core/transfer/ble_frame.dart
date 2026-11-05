import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

/// How one negotiation frame crosses the metadata characteristic.
///
/// ## Why a frame is cut up at all
///
/// A notification carries at most what the two devices agreed on when they
/// connected — the ATT MTU less three bytes. That is 20 bytes until somebody
/// asks for more, 182 on an iPhone (it asks for 185 and takes no other number),
/// 244 on an Android phone that requested 247. A `link` frame with sealed
/// credentials is 203 bytes and a `serve` frame 225, so a frame that does not
/// fit the limit of the device on the other end cannot be sent whole, and the
/// platforms do not refuse the one that is too long: they cut it to the limit
/// and say nothing, which reaches the receiver as half a JSON document.
///
/// So a frame is cut into parts that each fit, here, and put back together on
/// the far side. The limit is read from the platform where the platform says
/// it (Apple `maximumUpdateValueLength`, Android and Windows
/// `getMaximumNotifyLength`, BlueZ the `mtu` of a write) and is [defaultNotificationBytes]
/// where it does not. Nothing is shrunk to fit and nothing is dropped.
///
/// ## The part
///
/// ```text
/// byte 0   marker       0xD1 — never `{`, which is what an unframed JSON frame starts with
/// byte 1   frame id     wraps at 256; every part of one frame carries the same
/// byte 2   part index   0-based, strictly increasing
/// byte 3   part count   1..255, the same in every part
/// byte 4.. payload      at least one byte
/// ```
///
/// The channel is neither encrypted nor bonded, so anybody within range can
/// write a part of their own. The assembler therefore believes nothing it is
/// not owed: parts must arrive in order, none may repeat or be skipped, the
/// count may not change, the whole may not outgrow [maxFrameBytes], and a frame
/// that has begun must end within [assemblyTimeout]. Anything else is a
/// [BleFrameException] with the reason, never a hang, never memory that grows
/// without bound, and never a frame that was quietly cut short.
///
/// Parts of one frame are never interleaved with another's: the sender sends one
/// frame at a time, and a part that does not belong to the frame in progress is
/// a fault. ATT delivers notifications of one connection in order, so there is
/// no reordering to tolerate — a part that is out of order was lost, or is
/// somebody else's.
///
/// The Swift bridges (`ios/` and `macos/Runner/QuickShareBluetooth.swift`) carry
/// the same format in a delimited region that is the same text in both, and
/// `test/core/transfer/ble_frame_swift_test.dart` compiles it and runs it
/// against what this file produces.
class BleFrame {
  const BleFrame._();

  /// First byte of every part. Not `{` (0x7B), so a sender of generation 4 or
  /// below — whose frames are bare JSON — is recognised for what it is.
  static const int marker = 0xD1;

  /// Bytes before the payload: marker, frame id, part index, part count.
  static const int headerBytes = 4;

  /// The most parts one frame may have; the count is one byte.
  static const int maxParts = 255;

  /// The largest frame, in bytes of JSON.
  ///
  /// Real ones are a little over 200. The size of a `serve` frame is the size
  /// of the folder's name and the device's name on top of that, which is at most
  /// about 1.5 KB for names of the longest the file systems allow. 3 KB is room
  /// for that twice over and still fits [maxParts] at the smallest part a
  /// connection carries (3072 / 16 = 192), so a frame that is too big for the
  /// limit is too big for a reason, not an accident of the arithmetic.
  static const int maxFrameBytes = 3072;

  /// What one notification carries when nobody has said better: the 23-byte
  /// default ATT MTU less its three bytes of header. Used wherever a platform
  /// does not report what was negotiated, which is the safe thing to assume —
  /// a connection never carries less.
  static const int defaultNotificationBytes = 20;

  /// What a receiver says when a frame arrived and could not be used: lost,
  /// damaged, or not a frame at all — as opposed to a sender that is an older
  /// build, which has its own words (`BleControlProtocol.senderTooOldMessage`).
  /// The Swift bridges say the same sentence, and a test holds them to it.
  static const String damagedMessage =
      'A message from the sending device was lost or damaged on the way, so the '
      'transfer could not be set up.';

  /// The most one notification can carry whatever the connection negotiated: an
  /// attribute value is at most 512 bytes. A platform that answers with more
  /// than that is not to be believed.
  static const int maxNotificationBytes = 512;

  /// How long a frame that has begun may take to finish.
  ///
  /// A frame at the smallest part is a dozen notifications and arrives in well
  /// under a second. Ten seconds is for a radio having a bad time, and it is an
  /// absolute bound from the first part, not a gap between two: a stream of
  /// parts that never completes a frame is no better than silence.
  static const Duration assemblyTimeout = Duration(seconds: 10);

  /// Whether [first] — the first byte of something received — says the sender
  /// does not frame its notifications at all. Bare JSON starts with `{`; every
  /// sender of generation 4 and below sends it so, and no framed sender starts a
  /// notification with it.
  static bool looksUnframed(int first) => first == 0x7B;
}

/// What is wrong with a frame, or a part of one.
enum BleFrameProblem {
  // -- the sender's, when cutting a frame up --------------------------------

  /// There is nothing to send.
  emptyFrame,

  /// The frame is longer than [BleFrame.maxFrameBytes]. A real excess: it would
  /// not be sent whatever the connection carried.
  frameTooLarge,

  /// The connection carries too little for a part to hold even one byte.
  notificationTooSmall,

  /// At this connection's size the frame would need more than
  /// [BleFrame.maxParts] parts.
  tooManyParts,

  // -- the receiver's, when putting one together ----------------------------

  /// A notification that starts with `{`: the bare JSON of a sender that does
  /// not frame its notifications. This is the one problem that says the other
  /// side is an older build; nothing else here does.
  unframed,

  /// A notification that does not start with the marker, and does not start
  /// like bare JSON either: not ours, or damaged.
  notAFrame,

  /// Less than a header and one byte of payload.
  tooShort,

  /// A part count of zero, or an index at or past the count.
  badHeader,

  /// A part from the middle of a frame whose beginning never arrived.
  orphanPart,

  /// The first part of a new frame arrived while another had not finished.
  interrupted,

  /// A part of some other frame arrived while one was in progress.
  interleaved,

  /// A part that has been seen already, or an earlier one.
  duplicatePart,

  /// A part arrived with others before it still missing.
  missingPart,

  /// The part count differs from what the frame's first part said.
  countChanged,

  /// The frame has grown past [BleFrame.maxFrameBytes] before it ended.
  tooLarge,

  /// The frame did not finish within its time.
  timedOut,
}

/// A frame that cannot be sent or received as it is, and why.
class BleFrameException implements Exception {
  const BleFrameException(this.problem, this.message);

  final BleFrameProblem problem;

  /// English and technical: it goes to the log and, where there is nothing
  /// better, to the screen. The problem is what code decides on.
  final String message;

  /// Whether this is the sender saying it does not frame its notifications, as
  /// opposed to a frame that was damaged on the way.
  bool get isOlderSender => problem == BleFrameProblem.unframed;

  @override
  String toString() => message;
}

/// Cuts frames into parts, for one connection.
///
/// Holds the frame counter, so one instance per session: two frames in a row
/// carry different ids and a stray part of the first cannot pass for the
/// second's.
class BleFrameSplitter {
  /// [firstId] is for a test that has to know the first frame's id. Otherwise
  /// the counter starts anywhere, so the ids of one session tell a listener
  /// nothing about where it is in the sequence.
  BleFrameSplitter({int? firstId, Random? random})
      : _nextId = (firstId ?? (random ?? Random.secure()).nextInt(256)) & 0xFF;

  int _nextId;

  /// The parts of [frame], each at most [notificationBytes] long.
  ///
  /// [notificationBytes] is what one notification can carry on this
  /// connection: for ATT, the MTU less three. [frameId] overrides the counter
  /// for a test.
  ///
  /// Throws [BleFrameException] when the frame is empty, is past
  /// [BleFrame.maxFrameBytes], or the connection is so small it would need more
  /// than [BleFrame.maxParts] parts — and sends nothing in any of those cases.
  List<Uint8List> split(Uint8List frame,
      {required int notificationBytes, int? frameId}) {
    if (frame.isEmpty) {
      throw const BleFrameException(
          BleFrameProblem.emptyFrame, 'There is no frame to send.');
    }
    if (frame.length > BleFrame.maxFrameBytes) {
      throw BleFrameException(
          BleFrameProblem.frameTooLarge,
          'A ${frame.length}-byte frame is past the ${BleFrame.maxFrameBytes} '
          'bytes a Bluetooth frame may have.');
    }
    final payload = notificationBytes - BleFrame.headerBytes;
    if (payload < 1) {
      throw BleFrameException(
          BleFrameProblem.notificationTooSmall,
          'A Bluetooth notification of $notificationBytes bytes cannot carry '
          'a part of a frame: the header alone is ${BleFrame.headerBytes}.');
    }
    final count = (frame.length + payload - 1) ~/ payload;
    if (count > BleFrame.maxParts) {
      throw BleFrameException(
          BleFrameProblem.tooManyParts,
          'A ${frame.length}-byte frame needs $count parts of $payload bytes '
          'at $notificationBytes bytes a notification, and a frame may have '
          '${BleFrame.maxParts}.');
    }

    final id = (frameId ?? _nextId) & 0xFF;
    if (frameId == null) _nextId = (_nextId + 1) & 0xFF;

    final parts = <Uint8List>[];
    for (var index = 0; index < count; index++) {
      final from = index * payload;
      final to = min(from + payload, frame.length);
      final part = Uint8List(BleFrame.headerBytes + (to - from));
      part[0] = BleFrame.marker;
      part[1] = id;
      part[2] = index;
      part[3] = count;
      part.setRange(BleFrame.headerBytes, part.length, frame, from);
      parts.add(part);
    }
    return parts;
  }
}

/// Puts the parts of a frame back together.
///
/// One instance per connection. Feed it every notification of the metadata
/// characteristic, in the order they arrive, with [add]; a finished frame comes
/// out of [onFrame] and anything wrong with what came in out of [onFault]. Both
/// are called from inside [add] or from the timer, and never both for the same
/// input.
///
/// **A fault is final until [reset].** Once one part is missing, repeated or not
/// ours, the parts that follow it say nothing a receiver can believe, and
/// reporting each of them would bury the first, which is the one that says what
/// happened. So the assembler holds what it was fed no longer, ignores the rest,
/// and waits for the owner to decide: end the session (what both receivers do),
/// or [reset] and start over on a new connection.
class BleFrameAssembler {
  BleFrameAssembler({
    required this.onFrame,
    required this.onFault,
    this.timeout = BleFrame.assemblyTimeout,
    this.maxFrameBytes = BleFrame.maxFrameBytes,
  });

  final void Function(Uint8List frame) onFrame;
  final void Function(BleFrameException fault) onFault;
  final Duration timeout;
  final int maxFrameBytes;

  // Copying, not borrowing: a platform may reuse the buffer a notification
  // arrived in, and a part held by reference would change under the frame.
  final BytesBuilder _bytes = BytesBuilder();
  Timer? _timer;
  bool _assembling = false;
  bool _faulted = false;
  int _id = 0;
  int _count = 0;
  int _next = 0;

  /// Whether a frame has begun and not ended.
  bool get isAssembling => _assembling;

  /// Whether a fault has been reported and nothing has been taken since; see the
  /// class comment.
  bool get hasFaulted => _faulted;

  /// Takes one notification. Never throws: a problem goes to [onFault].
  void add(Uint8List part) {
    if (_faulted) return;
    if (part.isEmpty) {
      return _fault(BleFrameProblem.tooShort,
          'An empty notification arrived on the frame channel.');
    }
    if (part[0] != BleFrame.marker) {
      if (!_assembling && BleFrame.looksUnframed(part[0])) {
        return _fault(
            BleFrameProblem.unframed,
            'A ${part.length}-byte notification of bare JSON arrived: the '
            'sender does not cut its frames into parts.');
      }
      return _fault(
          BleFrameProblem.notAFrame,
          'A ${part.length}-byte notification that is not a part of a frame '
          '(it starts with 0x${part[0].toRadixString(16).padLeft(2, '0')}).');
    }
    if (part.length <= BleFrame.headerBytes) {
      return _fault(
          BleFrameProblem.tooShort,
          'A ${part.length}-byte part has a header and nothing after it.');
    }

    final id = part[1];
    final index = part[2];
    final count = part[3];
    if (count == 0 || index >= count) {
      return _fault(BleFrameProblem.badHeader,
          'A part says it is number $index of $count.');
    }

    if (!_assembling) {
      if (index != 0) {
        return _fault(
            BleFrameProblem.orphanPart,
            'Part $index of $count of frame $id arrived with no beginning: '
            'the earlier parts were lost, or this is not from the sender.');
      }
      _begin(id, count);
    } else {
      if (id != _id) {
        return _fault(
            index == 0
                ? BleFrameProblem.interrupted
                : BleFrameProblem.interleaved,
            index == 0
                ? 'Frame $id began while frame $_id had $_next of $_count '
                    'parts.'
                : 'Part $index of frame $id arrived inside frame $_id.');
      }
      if (count != _count) {
        return _fault(
            BleFrameProblem.countChanged,
            'Frame $_id said it had $_count parts, and then part $index said '
            '$count.');
      }
      if (index < _next) {
        return _fault(BleFrameProblem.duplicatePart,
            'Part $index of frame $_id arrived twice.');
      }
      if (index > _next) {
        return _fault(
            BleFrameProblem.missingPart,
            'Part $index of frame $_id arrived with part $_next still '
            'missing: a part was lost.');
      }
    }

    final payload = part.length - BleFrame.headerBytes;
    if (_bytes.length + payload > maxFrameBytes) {
      return _fault(
          BleFrameProblem.tooLarge,
          'Frame $_id is past $maxFrameBytes bytes at part $index of $_count.');
    }
    _bytes.add(Uint8List.sublistView(part, BleFrame.headerBytes));
    _next = index + 1;

    if (_next == _count) {
      final frame = _bytes.takeBytes();
      _reset();
      onFrame(frame);
    }
  }

  void _begin(int id, int count) {
    _assembling = true;
    _id = id;
    _count = count;
    _next = 0;
    _bytes.clear();
    _timer?.cancel();
    _timer = Timer(timeout, expire);
  }

  /// Gives up on the frame in progress, as if its time had run out: reports
  /// [BleFrameProblem.timedOut] and leaves the assembler empty. The clock calls
  /// it; so may a test that does not want to wait. Nothing happens when no
  /// frame has begun.
  void expire() {
    if (!_assembling) return;
    _fault(
        BleFrameProblem.timedOut,
        'Frame $_id did not finish: $_next of $_count parts arrived in '
        '${timeout.inMilliseconds / 1000} seconds.');
  }

  void _fault(BleFrameProblem problem, String message) {
    _reset();
    _faulted = true;
    onFault(BleFrameException(problem, message));
  }

  void _reset() {
    _timer?.cancel();
    _timer = null;
    _assembling = false;
    _bytes.clear();
    _id = 0;
    _count = 0;
    _next = 0;
  }

  /// Forgets a frame in progress, stops its clock and takes back the last
  /// fault: the next part is the first of a new stream. Nothing is reported.
  /// For a new connection.
  void reset() {
    _reset();
    _faulted = false;
  }

  /// Stops the clock for good; call when the connection is finished with.
  void dispose() => _reset();
}
