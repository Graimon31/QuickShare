import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// Where a search for a typed code has got to, as the screen shows it.
enum CodeSearchPhase {
  /// Looking: on the local network and on the internet at once.
  searching,

  /// A sender proved it holds the code and a person over there is being asked.
  awaitingApproval,
}

/// What a screen holds on to while a code is being looked for: a way to stop
/// it at any moment, and the phases to draw.
///
/// Stopping is complete. Whatever either search had open — a browse, a
/// connection to a candidate, a mailbox and every topic it listened on, a
/// timer — is released before [CodeLookup.find] returns, whichever stage the
/// search was in.
class CodeSearchControl {
  final _cancelled = Completer<void>();
  final _phases = StreamController<CodeSearchPhase>.broadcast();
  CodeSearchPhase _phase = CodeSearchPhase.searching;

  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;

  CodeSearchPhase get phase => _phase;
  Stream<CodeSearchPhase> get phases => _phases.stream;

  /// Stops the search. Idempotent.
  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  void _report(CodeSearchPhase phase) {
    if (_phase == phase || isCancelled) return;
    _phase = phase;
    if (!_phases.isClosed) _phases.add(phase);
  }

  /// Says the search has reached [phase], as a search does. For tests of the
  /// screen that draws it.
  @visibleForTesting
  void reportForTesting(CodeSearchPhase phase) => _report(phase);

  /// Releases the phase stream. Called by whoever made the control, once the
  /// search it was made for is over.
  Future<void> dispose() async {
    cancel();
    if (!_phases.isClosed) await _phases.close();
  }
}

/// The rule that lets two searches run side by side: **the first to prove the
/// code wins**, and the other is stopped.
///
/// Proving is not finding. A candidate on the network, or an answer in the
/// mailbox, is only a claim until it has run the exchange that nobody without
/// the code can complete. A search that has a proof asks the arbiter for the
/// right to go on and tell that sender who it is; only one is ever given it,
/// so a receiver reveals its name to at most one device.
class CodeSearchArbiter {
  CodeSearchArbiter(this.control) {
    control.whenCancelled.then((_) => _stopAll());
  }

  final CodeSearchControl control;
  final _gates = <SearchGate>[];
  SearchGate? _winner;

  /// The side that won, or null while nobody has.
  String? get winner => _winner?.side;

  /// A gate for one search. [side] only names it.
  SearchGate gate(String side) {
    final gate = SearchGate._(this, side);
    _gates.add(gate);
    if (control.isCancelled) gate._stop();
    return gate;
  }

  bool _claim(SearchGate gate) {
    if (control.isCancelled) return false;
    if (_winner == null) {
      _winner = gate;
      for (final other in _gates) {
        if (!identical(other, gate)) other._stop();
      }
      return true;
    }
    return identical(_winner, gate);
  }

  /// Stops every search without calling the person's cancel: for the moment
  /// one of them has failed in a way that makes the others pointless.
  void abort() => _stopAll();

  void _stopAll() {
    for (final gate in _gates) {
      gate._stop();
    }
  }
}

/// One search's view of the arbiter.
class SearchGate {
  SearchGate._(this._arbiter, this.side);

  final CodeSearchArbiter _arbiter;
  final String side;
  final _stopped = Completer<void>();

  /// Completes when this search should drop everything it holds: the person
  /// cancelled, or the other search won.
  Future<void> get stopped => _stopped.future;
  bool get isStopped => _stopped.isCompleted;

  /// Asks for the right to reveal this device to the sender just proved.
  /// False means someone else already has it, or the person cancelled.
  bool tryClaim() => _arbiter._claim(this);

  /// The search is now waiting on a person at the other end.
  void awaitingApproval() =>
      _arbiter.control._report(CodeSearchPhase.awaitingApproval);

  void _stop() {
    if (!_stopped.isCompleted) _stopped.complete();
  }
}
