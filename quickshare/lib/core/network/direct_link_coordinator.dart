import 'dart:async';

import 'package:quickshare/core/crypto/link_secret.dart';
import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/network/local_hotspot_service.dart';
import 'package:quickshare/core/network/peer_link_service.dart';
import 'package:quickshare/core/network/session_code.dart';

/// The platform half of building the link: raise a network, join one, make
/// sure the radio is on.
///
/// Abstracted from [LocalHotspotService] so the coordinator's decision tree —
/// who hosts, what happens when it fails — can be tested without a Wi-Fi
/// radio. The default implementation wraps the platform services; the tests
/// answer for platforms the CI runner is not.
abstract interface class DirectLinkDriver {
  /// Whether this device can raise a network at all. A platform answer, cheap
  /// enough to consult while deciding: Android, Linux and Windows can;
  /// iOS and macOS cannot.
  bool get canHost;

  /// Raise a network named from [code] and return the live credentials.
  ///
  /// The returned pair can differ from the code's — Android's hotspot API
  /// names the network itself — and when it does, the returned pair is what
  /// actually went on air. [HotspotCredentials.hostAddress] must be non-null:
  /// a network whose interface never got an address is not up, whatever the
  /// platform callback said.
  ///
  /// Throws [HotspotException] when the network did not come up.
  Future<HotspotCredentials> host(SessionCode code);

  /// Join the network [credentials] describes. Throws on failure.
  Future<void> joinNetwork(HotspotCredentials credentials);

  /// Bring Wi-Fi to a state where hosting or joining can work, asking the
  /// person where the platform demands they do it. False means it ended off.
  Future<bool> ensureWifiReady();

  /// Take down whatever [host] raised. Never throws.
  Future<void> stopHosting();

  /// Leave whatever network was joined via [joinNetwork]. Never throws.
  Future<void> leaveNetwork();

  /// Whether this device can raise or join a peer-to-peer Wi-Fi link — the
  /// radio AirDrop uses, with no access point between the two devices.
  ///
  /// Apple only, and that is exactly why it is here: an iPhone and a Mac can
  /// neither host a network nor be hosted by the other, so this is the one
  /// rung that reaches the pair nothing else does.
  bool get canPeerLink;

  /// Announce [serviceName] and forward whatever a peer sends to the server
  /// already listening on [localPort]. Throws when the link did not come up.
  Future<void> hostPeerLink(String serviceName, int localPort);

  /// Find [serviceName] and return a loopback port that reaches it. The
  /// caller then talks to `127.0.0.1:<port>` as if it were the far side.
  Future<int> joinPeerLink(String serviceName);

  /// Take down whatever [hostPeerLink] or [joinPeerLink] raised. Never throws.
  Future<void> stopPeerLink();
}

/// Which side of the session raises the network, and how to reach it.
///
/// Sent by the sender as the first frame of the rendezvous' metadata channel:
/// `{"link": ...}`. The rule the matrix fixes is "the sender hosts when it
/// can, otherwise the receiver does" — but a sender that *should* host and
/// fails (an adapter that will not act as an access point) redelegates with
/// the same message, so the receiver never has to know why it was asked.
class DirectLinkDirective {
  final bool receiverHosts;

  /// The network's name and passphrase, sealed against a key neither side
  /// transmitted. Opaque here: only `LinkSecret` knows what is inside.
  final String? sealedCredentials;

  /// The sender's public half for this negotiation, so the receiver can open
  /// [sealedCredentials] and seal its own.
  final String? senderPublicKey;

  /// The Bonjour name of a peer-to-peer link the sender has raised, when the
  /// rendezvous took that rung. Non-null only for [DirectLinkDirective.overPeerLink].
  final String? peerLinkService;

  /// The session code's ten digits, carried so a receiver that connected
  /// without them — picked off the sender's list, no QR involved — can still
  /// name a network it is asked to raise after the session it belongs to.
  final String? codeDigits;

  /// The sender raised the network itself. The credentials ride along sealed
  /// — even when they could be derived from the session code — so the joiner
  /// never has to guess at a network that is not there yet.
  const DirectLinkDirective.hostBySender({
    required String sealedCredentials,
    required String senderPublicKey,
    String? codeDigits,
  }) : this._(
            receiverHosts: false,
            sealedCredentials: sealedCredentials,
            senderPublicKey: senderPublicKey,
            codeDigits: codeDigits);

  /// Neither device can raise a network, and both are Apple: the sender put
  /// the session on a peer-to-peer Wi-Fi link instead, and the receiver joins
  /// it by name. No access point exists, so there is nothing to hand over but
  /// the name.
  const DirectLinkDirective.overPeerLink({
    required String serviceName,
    String? senderPublicKey,
    String? codeDigits,
  }) : this._(
            receiverHosts: false,
            peerLinkService: serviceName,
            senderPublicKey: senderPublicKey,
            codeDigits: codeDigits);

  /// The receiver has to raise it — the sender cannot (iPhone, Mac), or
  /// tried and failed.
  const DirectLinkDirective.hostByReceiver({
    String? senderPublicKey,
    String? codeDigits,
  }) : this._(
            receiverHosts: true,
            senderPublicKey: senderPublicKey,
            codeDigits: codeDigits);

  const DirectLinkDirective._({
    required this.receiverHosts,
    required this.codeDigits,
    this.sealedCredentials,
    this.senderPublicKey,
    this.peerLinkService,
  });

  Map<String, Object?> toJson() => {
        'host': peerLinkService != null
            ? 'peerlink'
            : (receiverHosts ? 'receiver' : 'sender'),
        if (sealedCredentials != null) 'sealed': sealedCredentials,
        if (senderPublicKey != null) 'kex': senderPublicKey,
        if (peerLinkService != null) 'service': peerLinkService,
        if (codeDigits != null) 'code': codeDigits,
      };

  static DirectLinkDirective? fromJson(Map<String, Object?> json) {
    final codeDigits = json['code'];
    final digits = codeDigits is String && codeDigits.isNotEmpty
        ? codeDigits
        : null;
    final kex = json['kex'];
    final senderKey = kex is String && kex.isNotEmpty ? kex : null;
    switch (json['host']) {
      case 'peerlink':
        final service = json['service'];
        if (service is! String || service.isEmpty) return null;
        return DirectLinkDirective.overPeerLink(
            serviceName: service,
            senderPublicKey: senderKey,
            codeDigits: digits);
      case 'receiver':
        return DirectLinkDirective.hostByReceiver(
            senderPublicKey: senderKey, codeDigits: digits);
      case 'sender':
        final sealed = json['sealed'];
        if (sealed is! String || sealed.isEmpty) return null;
        // Without the sender's public half the credentials cannot be opened,
        // so a directive missing it is not one.
        if (senderKey == null) return null;
        return DirectLinkDirective.hostBySender(
            sealedCredentials: sealed,
            senderPublicKey: senderKey,
            codeDigits: digits);
      default:
        return null;
    }
  }
}

/// Where the file actually is, sent by the sender once the link is up: the
/// session's QHTP server address on the network the two devices just built.
/// The pull that follows is the ordinary one — nothing about the transfer
/// knows the network underneath it is a minute old.
class LinkServeInfo {
  final String ip;
  final int port;
  final String token;

  /// The session certificate's fingerprint, to pin the pull to.
  ///
  /// Carried for the same reason the QR carries it: the session speaks TLS
  /// with a certificate signed by nobody, so the only thing that says the
  /// server on the other end is the one that raised this link is the
  /// fingerprint the sender names here. Without it the receiver has an
  /// address and a token and no way to check either — and it refuses rather
  /// than falling back to plaintext, so a frame without this reaches the
  /// person as "update the sending device" and no file at all.
  final String tlsFingerprint;

  const LinkServeInfo({
    required this.ip,
    required this.port,
    required this.token,
    required this.tlsFingerprint,
  });

  Map<String, Object?> toJson() =>
      {'ip': ip, 'port': port, 'token': token, 'tf': tlsFingerprint};

  static LinkServeInfo? fromJson(Map<String, Object?> json) {
    final ip = json['ip'];
    final port = json['port'];
    final token = json['token'];
    final fingerprint = json['tf'];
    if (ip is! String || ip.isEmpty) return null;
    if (port is! int || port <= 0) return null;
    if (token is! String || token.isEmpty) return null;
    // Absent is refused here rather than downstream: a frame with no
    // fingerprint cannot open a session, so treating it as unreadable says
    // so at the edge instead of halfway through a transfer.
    if (fingerprint is! String || fingerprint.isEmpty) return null;
    return LinkServeInfo(
        ip: ip, port: port, token: token, tlsFingerprint: fingerprint);
  }
}

/// The rendezvous messages the negotiation rides on.
///
/// The BLE channel implements this (the directive as a metadata frame, the
/// offer as an `AP:` control write — see `BleControlProtocol`); the tests
/// implement it with lists and completers.
abstract interface class DirectLinkSignal {
  Future<void> sendDirective(DirectLinkDirective directive);

  Stream<DirectLinkDirective> get directives;

  /// Receiver → sender: the credentials of the network the receiver raised,
  /// sealed. Opaque to everything between here and the far side's
  /// `LinkSecret`.
  Future<void> sendApOffer(String sealed);

  Stream<String> get apOffers;

  /// Receiver → sender: this side's public half for the negotiation.
  Future<void> sendKeyExchange(String publicKey);

  /// The far side's public half, as it arrives. Readable by anyone listening,
  /// which is what makes a key exchange the right shape here: the secret both
  /// sides derive from it never crosses the wire.
  Stream<String> get peerKeys;
}

sealed class DirectLinkOutcome {
  const DirectLinkOutcome();
}

/// The devices share a network. [hosting] says which side of this call
/// raised it; [credentials] describe it either way.
class DirectLinkReady extends DirectLinkOutcome {
  final HotspotCredentials credentials;
  final bool hosting;
  const DirectLinkReady({required this.credentials, required this.hosting});
}

/// The devices are on a peer-to-peer Wi-Fi link — no access point between
/// them, the radio AirDrop uses.
///
/// [localPort] is where the file is, and it is loopback: the link is exposed
/// as an ordinary port on this machine, so the receiver pulls from
/// `127.0.0.1:<localPort>` and the transfer never learns what carried it.
/// Null on the hosting side, which serves rather than pulls.
class DirectLinkOverPeerLink extends DirectLinkOutcome {
  final bool hosting;
  final int? localPort;
  const DirectLinkOverPeerLink({required this.hosting, this.localPort});
}

/// The ladder ran out. [message] names what was wrong, not which rung
/// failed — but in English, because this file has no locale. [code] is the
/// same fact as a value, and it is what the screen translates; the message
/// is what the log keeps.
class DirectLinkUnavailable extends DirectLinkOutcome {
  final String message;

  /// See [FailureCode]. Always set: every message here is one this file
  /// wrote, so every one of them can be translated.
  final String code;

  const DirectLinkUnavailable(this.message, this.code);
}

/// Builds the Wi-Fi link a Bluetooth-paired transfer then runs over.
///
/// ## Why this exists
///
/// Bluetooth is the rendezvous — who is present, which session may start —
/// and nothing more: at BLE speeds a photo library is an afternoon. The file
/// itself crosses a network the two devices raise between them, the way
/// AirDrop's does. This class owns the negotiation and the recovery ladder;
/// the transports above it never learn whether the bytes moved over a router
/// or a hotspot.
///
/// ## The ladder
///
/// An error from [runSender]/[runReceiver] is the last rung, not the first.
/// Before it: the radio is checked and switched on where the platform allows,
/// hosting is retried, the role is redelegated to the other device when this
/// one cannot do it, joins are retried against a network that may still be
/// coming up, and [probeLink] — when the caller supplies one — verifies the
/// link at L3 before the outcome is declared. What remains is the genuinely
/// hopeless: a radio that stayed off, two devices that can neither host nor
/// be hosted.
///
/// The methods are not cancellable; every wait inside is bounded, so a caller
/// that loses interest just stops awaiting and tears the driver down.
class DirectLinkCoordinator {
  final DirectLinkDriver driver;
  final DirectLinkSignal signal;

  /// See the class doc — this is the L3 rung of the ladder. Null trusts the
  /// platform calls, which is the right answer only where no better probe
  /// exists.
  final Future<bool> Function()? probeLink;

  final int hostAttempts;
  final int joinAttempts;
  final int offerRounds;
  final Duration retryPause;
  final Duration apOfferTimeout;

  /// How long to wait for the far side's public half before giving up on a
  /// private link. It is written as soon as that side connects, so this is a
  /// bound on a message already in flight rather than on anyone's decision.
  final Duration keyExchangeTimeout;

  /// How long the receiver keeps working through what the sender proposes.
  /// Must outlast the sender's whole ladder, or the rung that reaches an
  /// Apple pair arrives after this side has stopped listening.
  final Duration negotiationBudget;

  const DirectLinkCoordinator({
    required this.driver,
    required this.signal,
    this.probeLink,
    this.hostAttempts = 2,
    this.joinAttempts = 3,
    this.offerRounds = 2,
    this.retryPause = const Duration(milliseconds: 700),
    this.apOfferTimeout = const Duration(seconds: 8),
    this.keyExchangeTimeout = const Duration(seconds: 8),
    this.negotiationBudget = const Duration(seconds: 45),
  });

  /// The sender's half: host when this device can, delegate when it cannot
  /// or failed to, and put the session on a peer-to-peer link when neither
  /// device can raise a network at all.
  ///
  /// [servingPort] is where this device is already serving the session. It is
  /// what the peer-to-peer rung forwards to, and without it that rung is
  /// skipped — there would be nothing on the other end of the link.
  Future<DirectLinkOutcome> runSender(SessionCode code,
      {int? servingPort}) async {
    if (!await driver.ensureWifiReady()) {
      return const DirectLinkUnavailable(
          'Wi-Fi is turned off. The transfer builds a direct Wi-Fi link '
          'between the devices, so it cannot start without it.',
          FailureCode.linkWifiOff);
    }

    // Before anything that could carry credentials. The far side writes its
    // public half as soon as it is connected, so this is normally already in
    // hand; waiting for it is what makes the rest of this method able to seal.
    final secret = await LinkSecret.generate();
    final peerKey = await _firstFrom(signal.peerKeys, keyExchangeTimeout);
    if (peerKey == null) {
      return const DirectLinkUnavailable(
          'The other device did not answer the setup for a private link. '
          'Make sure it is running the current version and try again.',
          FailureCode.linkPeerSilentAtSetup);
    }

    if (driver.canHost) {
      for (var attempt = 0; attempt < hostAttempts; attempt++) {
        final creds = await _tryHost(code);
        if (creds != null) {
          await signal.sendDirective(DirectLinkDirective.hostBySender(
              sealedCredentials: await secret.seal(
                ssid: creds.ssid,
                passphrase: creds.passphrase,
                sessionId: code.publicId,
                peerPublicKey: peerKey,
              ),
              senderPublicKey: secret.publicKey,
              codeDigits: code.code));
          if (await _probe()) {
            return DirectLinkReady(credentials: creds, hosting: true);
          }
          // The network is up but the peer never appeared on it. Start over
          // rather than wait on a link only one device is using.
          await driver.stopHosting();
        }
        await Future<void>.delayed(retryPause);
      }
    }

    // This device cannot host, or tried and could not: the receiver raises
    // the network. The directive is resent each round — an offer that raced
    // a lost BLE write costs a round, not the session.
    for (var round = 0; round < offerRounds; round++) {
      await signal.sendDirective(DirectLinkDirective.hostByReceiver(
          senderPublicKey: secret.publicKey, codeDigits: code.code));
      final sealed = await _firstFrom(signal.apOffers, apOfferTimeout);
      if (sealed == null) continue;
      final offer = await secret.open(
          sealed: sealed, sessionId: code.publicId, peerPublicKey: peerKey);
      // A frame that will not open is somebody else's, or stale, or being
      // probed at: the round is spent, the session is not.
      if (offer == null) continue;
      final joined = await _joinWithRetries(HotspotCredentials(
          ssid: offer.ssid, passphrase: offer.passphrase));
      if (joined != null) return joined;
    }

    // Last, and only here. Neither device raised a network: this one cannot,
    // and the other never offered one — which between two Apple devices is
    // not a failure but the ordinary case, since neither can host and neither
    // can be hosted. A peer-to-peer link needs no access point, and reaching
    // that pair is the whole reason it exists.
    //
    // Last rather than first because the sender cannot tell whether the far
    // side can join one: it has no acknowledgement to wait for, so "every
    // other rung was tried and nobody offered" is the evidence it uses
    // instead. A receiver that cannot join simply lets the directive pass.
    if (servingPort != null && driver.canPeerLink) {
      final name = PeerLinkService.serviceNameFor(code.sessionToken);
      for (var attempt = 0; attempt < hostAttempts; attempt++) {
        try {
          await driver.hostPeerLink(name, servingPort);
          await signal.sendDirective(DirectLinkDirective.overPeerLink(
              serviceName: name,
              senderPublicKey: secret.publicKey,
              codeDigits: code.code));
          return const DirectLinkOverPeerLink(hosting: true);
        } on Error {
          rethrow;
        } catch (_) {
          await driver.stopPeerLink();
        }
        await Future<void>.delayed(retryPause);
      }
    }

    return const DirectLinkUnavailable(
        'Could not set up the direct Wi-Fi link. Keep the devices next to '
        'each other and try again.',
        FailureCode.linkSetupFailed);
  }

  /// The receiver's half: work through what the sender proposes until
  /// something lands.
  ///
  /// A directive this device cannot act on is let past rather than treated as
  /// the end — that is what makes the sender's ladder a ladder from this side
  /// too. An iPhone asked to raise a network cannot, and answering "no" would
  /// leave the sender waiting out an offer that was never coming; letting it
  /// pass leaves this device listening for the rung that does reach it, which
  /// between two Apple devices is the peer-to-peer link.
  ///
  /// [code] is nullable because a receiver can arrive without one — picked
  /// off the sender's list with no QR involved. Hosting needs it only to
  /// name the network; when neither the caller nor the directive carries
  /// one, a throwaway code names it instead, since the actual credentials
  /// travel in the offer either way.
  Future<DirectLinkOutcome> runReceiver([SessionCode? code]) async {
    if (!await driver.ensureWifiReady()) {
      return const DirectLinkUnavailable(
          'Wi-Fi is turned off. The transfer builds a direct Wi-Fi link '
          'between the devices, so it cannot start without it.',
          FailureCode.linkWifiOff);
    }

    // Sent before any directive can arrive, so the far side has this side's
    // public half by the time it has credentials to seal.
    final secret = await LinkSecret.generate();
    await signal.sendKeyExchange(secret.publicKey);

    final pending = <DirectLinkDirective>[];
    Completer<void>? waiting;
    final subscription = signal.directives.listen((directive) {
      pending.add(directive);
      final waiter = waiting;
      waiting = null;
      if (waiter != null && !waiter.isCompleted) waiter.complete();
    });

    // Long enough to outlast every rung the sender climbs, because the last
    // of them is the one that reaches an Apple pair and giving up before it
    // arrives is exactly the failure this is here to avoid.
    final deadline = DateTime.now().add(negotiationBudget);
    var heardAnything = false;
    try {
      while (DateTime.now().isBefore(deadline)) {
        if (pending.isEmpty) {
          final waiter = Completer<void>();
          waiting = waiter;
          await waiter.future
              .timeout(deadline.difference(DateTime.now()), onTimeout: () {});
          waiting = null;
          if (pending.isEmpty) break;
        }
        heardAnything = true;
        final outcome = await _actOn(pending.removeAt(0), code, secret);
        if (outcome != null) return outcome;
      }
    } finally {
      await subscription.cancel();
    }

    return heardAnything
        ? const DirectLinkUnavailable(
            'Could not set up the direct Wi-Fi link with the other device. '
            'Keep the devices next to each other and try again.',
            FailureCode.linkSetupFailed)
        : const DirectLinkUnavailable(
            'Lost contact with the sending device before the link was set '
            'up. Stay on this screen and try again.',
            FailureCode.linkPeerLost);
  }

  /// One proposal. Null means "this device could not take that one" — the
  /// caller keeps listening rather than declaring the session dead.
  Future<DirectLinkOutcome?> _actOn(DirectLinkDirective directive,
      SessionCode? code, LinkSecret secret) async {
    final peerLinkService = directive.peerLinkService;
    if (peerLinkService != null) {
      if (!driver.canPeerLink) return null;
      try {
        return DirectLinkOverPeerLink(
            hosting: false, localPort: await driver.joinPeerLink(peerLinkService));
      } on Error {
        rethrow;
      } catch (_) {
        await driver.stopPeerLink();
        return null;
      }
    }

    // Whatever the directive asks for, acting on it needs the far side's
    // public half: to open credentials it sent, or to seal the ones this
    // device is about to raise.
    final peerKey = directive.senderPublicKey;
    if (peerKey == null) return null;

    // Names this negotiation for the seal. Both sides derive it from the same
    // digits; a receiver that has none takes the sender's word for it, which
    // is the only thing binding the frame to a session at all on that path.
    final sessionId =
        code?.publicId ?? _sessionIdFrom(directive.codeDigits) ?? '';

    if (!directive.receiverHosts) {
      final sealed = directive.sealedCredentials;
      if (sealed == null) return null;
      final creds = await secret.open(
          sealed: sealed, sessionId: sessionId, peerPublicKey: peerKey);
      // Not ours, or tampered with, or from another session: let the sender's
      // ladder try the next rung rather than ending the negotiation on it.
      if (creds == null) return null;
      return _joinWithRetries(HotspotCredentials(
          ssid: creds.ssid, passphrase: creds.passphrase));
    }

    // Being asked to host by a device that cannot is the ordinary case
    // between two Apple devices, and it is not an answer this side can give.
    if (!driver.canHost) return null;

    final naming = code ??
        (directive.codeDigits != null
            ? SessionCode.parse(directive.codeDigits!)
            : null) ??
        SessionCode.generate();
    for (var attempt = 0; attempt < hostAttempts; attempt++) {
      final creds = await _tryHost(naming);
      if (creds != null) {
        // Always offer, even when the credentials could be derived from the
        // session code: a sender waiting on this never has to guess at a
        // network that is not there yet. Sealed, because an Android host's
        // network names itself and the pair it hands back is the live
        // passphrase of a network now on the air.
        await signal.sendApOffer(await secret.seal(
          ssid: creds.ssid,
          passphrase: creds.passphrase,
          sessionId: sessionId,
          peerPublicKey: peerKey,
        ));
        return DirectLinkReady(credentials: creds, hosting: true);
      }
      await Future<void>.delayed(retryPause);
    }
    return null;
  }

  /// The session's public identifier, derived from digits the directive
  /// carried. Null when it carried none — an empty name still binds both
  /// sides to the same value, which is all the seal needs of it.
  static String? _sessionIdFrom(String? codeDigits) {
    if (codeDigits == null || codeDigits.isEmpty) return null;
    return SessionCode.parse(codeDigits)?.publicId;
  }

  /// One hosting attempt. Null means the ladder should climb, not stop: the
  /// exception — whatever the driver failed with — is a fact about this
  /// attempt, not about the link.
  Future<HotspotCredentials?> _tryHost(SessionCode code) async {
    try {
      final creds = await driver.host(code);
      if (creds.hostAddress == null) {
        await driver.stopHosting();
        return null;
      }
      return creds;
    } on Error {
      rethrow;
    } catch (_) {
      await driver.stopHosting();
      return null;
    }
  }

  Future<DirectLinkReady?> _joinWithRetries(
      HotspotCredentials credentials) async {
    for (var attempt = 0; attempt < joinAttempts; attempt++) {
      try {
        await driver.joinNetwork(credentials);
        if (await _probe()) {
          return DirectLinkReady(credentials: credentials, hosting: false);
        }
        await driver.leaveNetwork();
      } on Error {
        rethrow;
      } catch (_) {
        // A network that is still coming up refuses the first join; the
        // pause below is what the retry is for.
        await driver.leaveNetwork();
      }
      await Future<void>.delayed(retryPause);
    }
    return null;
  }

  Future<bool> _probe() => probeLink?.call() ?? Future.value(true);

  /// The first thing [source] produces, or null when the wait runs out.
  ///
  /// Every wait in this class is bounded, so a caller that loses interest can
  /// simply stop awaiting and tear the driver down.
  Future<T?> _firstFrom<T>(Stream<T> source, Duration timeout) {
    final completer = Completer<T?>();
    late final StreamSubscription<T> sub;
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(null);
    });
    sub = source.listen((value) {
      if (!completer.isCompleted) completer.complete(value);
    }, onError: (_) {
      if (!completer.isCompleted) completer.complete(null);
    });
    return completer.future.whenComplete(() {
      timer.cancel();
      sub.cancel();
    });
  }

}
