/// How long a transfer waits before it decides its connection is dead.
///
/// Both ends decide for themselves, from what they can see, because a dead
/// path looks the same from either side and there is nobody to ask:
///
///  * the **sender** watches its own send buffer. Data leaves it only as the
///    far end acknowledges what is already in flight, so a buffer that has not
///    shrunk by a single byte for [sendNoDrain] is a path that carries nothing
///    back, whatever ICE still says;
///  * the **receiver** watches what arrives. The sender puts a small frame on
///    the channel every [pingEvery] when it has nothing bigger to say, so a
///    channel that has delivered nothing at all for [receiveSilence] is dead,
///    not idle.
///
/// ## Why these numbers
///
/// The transport underneath retransmits with a timeout that doubles each time
/// (half a second, one, two, four, eight, ...). A hiccup of a few seconds is
/// therefore over before the third or fourth retransmission and the transfer
/// goes on by itself; ten seconds without a byte means four or five of them
/// have already gone unanswered, which no ordinary loss produces. The cost of
/// being wrong in the early direction is small and bounded (an automatic
/// reconnection, and a banner for a few seconds), and the cost of waiting is
/// paid by a person looking at a frozen percentage — the old thirty-odd
/// seconds is what this replaces. The receiver's figure is a little longer
/// than the sender's so that the end that can see the cause first is the one
/// that acts first.
class StallPolicy {
  const StallPolicy({
    this.sendNoDrain = const Duration(seconds: 7),
    this.receiveSilence = const Duration(seconds: 20),
    this.suspectAfter = const Duration(seconds: 5),
    this.iceDisconnectedGrace = const Duration(seconds: 8),
    this.pingEvery = const Duration(seconds: 2),
    this.helloWait = const Duration(seconds: 8),
    this.doneWait = const Duration(seconds: 15),
    this.legacyHelloWait = const Duration(seconds: 4),
  });

  /// Sender: how long the send buffer may sit without shrinking.
  final Duration sendNoDrain;

  /// Receiver: how long the channel may deliver nothing at all, with the
  /// sender's pings counted.
  final Duration receiveSilence;

  /// Receiver: quiet for this long, it starts listening for a reconnection
  /// offer without yet calling the connection dead, so that an offer from a
  /// sender that noticed first is not missed.
  final Duration suspectAfter;

  /// How long ICE may stay `disconnected` before it is treated as dead.
  final Duration iceDisconnectedGrace;

  /// Sender: how often it puts a small frame on an otherwise quiet channel.
  final Duration pingEvery;

  /// A new link is open; how long the sender waits for the receiver's first
  /// word before it counts the link as unusable.
  final Duration helloWait;

  /// Sender: everything is sent; how long it waits for the receiver to say it
  /// has the lot before it suspects the link.
  final Duration doneWait;

  /// Sender: on the very first link, how long it waits for a receiver to
  /// announce itself before it takes it for a build that predates reconnection
  /// and carries on the old way.
  final Duration legacyHelloWait;
}

/// How hard a transfer tries to get a dead connection back, and when it stops.
///
/// Three things bound it, because each guards against a different way of
/// trying for ever:
///
///  * [maxAttempts] failed attempts in a row end the session. An attempt is a
///    whole new connection (offer, answer, ICE, first word from the far end),
///    so three is a lot;
///  * [totalBudget] caps the time spent reconnecting over the whole session,
///    however the attempts are spread: a path that dies every thirty seconds
///    must not turn a transfer into an hour of banners;
///  * [maxInterruptions] caps how many times the connection may be lost and
///    regained, for the same reason.
///
/// A successful reconnection that then moves at least [progressBytes] of real
/// data gives the attempts back: it was a real recovery, and the next drop is
/// a fresh problem, not the third try of the last one.
class ReconnectPolicy {
  const ReconnectPolicy({
    this.maxAttempts = 3,
    this.attemptTimeout = const Duration(seconds: 45),
    this.totalBudget = const Duration(minutes: 5),
    this.maxInterruptions = 12,
    this.progressBytes = 256 * 1024,
    this.pauseBetweenAttempts = const [
      Duration(seconds: 2),
      Duration(seconds: 5),
    ],
  });

  final int maxAttempts;

  /// One attempt, from publishing the offer to the first word on the new
  /// channel.
  final Duration attemptTimeout;

  /// All the time a session may spend reconnecting, added up.
  final Duration totalBudget;

  final int maxInterruptions;

  /// Data that has to move on a recovered link before the attempts are
  /// counted afresh.
  final int progressBytes;

  /// The wait before the second attempt, before the third, and so on; the last
  /// entry repeats.
  final List<Duration> pauseBetweenAttempts;

  Duration pauseBefore(int attempt) {
    if (attempt <= 1 || pauseBetweenAttempts.isEmpty) return Duration.zero;
    final i = attempt - 2;
    return pauseBetweenAttempts[
        i < pauseBetweenAttempts.length ? i : pauseBetweenAttempts.length - 1];
  }
}

/// Why a session stopped trying.
enum ReconnectGaveUp {
  /// [ReconnectPolicy.maxAttempts] attempts in a row failed.
  attempts,

  /// [ReconnectPolicy.totalBudget] was spent.
  budget,

  /// [ReconnectPolicy.maxInterruptions] drops, however well each was mended.
  interruptions,
}

/// The running count of a session's reconnections against a
/// [ReconnectPolicy]. Pure: the clock is passed in, so a test needs no timers.
class ReconnectLedger {
  ReconnectLedger(this.policy, {DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final ReconnectPolicy policy;
  final DateTime Function() _now;

  int _attemptsInARow = 0;
  int _interruptions = 0;
  Duration _spent = Duration.zero;
  DateTime? _lostAt;
  int _bytesSinceRecovery = 0;
  bool _recovered = false;

  int get attemptsInARow => _attemptsInARow;
  int get interruptions => _interruptions;
  Duration get spent => _spent + (_lostAt == null ? Duration.zero : _now().difference(_lostAt!));
  bool get isReconnecting => _lostAt != null;

  /// Data moved on a link that was recovered; once enough has, the next
  /// interruption starts with all its attempts again.
  void moved(int bytes) {
    if (!_recovered) return;
    _bytesSinceRecovery += bytes;
    if (_bytesSinceRecovery >= policy.progressBytes) {
      _attemptsInARow = 0;
      _recovered = false;
    }
  }

  /// The connection was lost. Idempotent while the loss lasts.
  void lost() {
    if (_lostAt != null) return;
    _lostAt = _now();
    _interruptions++;
  }

  /// Whether another attempt may be made now, and if not, why not.
  ReconnectGaveUp? get exhausted {
    if (_interruptions > policy.maxInterruptions) {
      return ReconnectGaveUp.interruptions;
    }
    if (spent >= policy.totalBudget) return ReconnectGaveUp.budget;
    if (_attemptsInARow >= policy.maxAttempts) return ReconnectGaveUp.attempts;
    return null;
  }

  /// The number (from 1) of the attempt about to start.
  int startAttempt() {
    _attemptsInARow++;
    return _attemptsInARow;
  }

  /// A new link is up and the far end has spoken.
  void recovered() {
    final at = _lostAt;
    if (at != null) _spent += _now().difference(at);
    _lostAt = null;
    _recovered = true;
    _bytesSinceRecovery = 0;
  }
}
