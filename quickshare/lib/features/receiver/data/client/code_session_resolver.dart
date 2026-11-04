import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/crypto/spake2.dart';
import 'package:quickshare/core/network/code_pake.dart';
import 'package:quickshare/core/network/lan_discovery.dart';
import 'package:quickshare/core/network/network_info_service.dart';
import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/core/network/session_tls_identity.dart';
import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/features/receiver/data/client/code_search.dart';
import 'package:quickshare/shared/models/qr_payload.dart';

/// Where a candidate sender might be listening.
typedef ProbeTarget = ({InternetAddress address, int port});

/// How asking for a session by its code ended.
sealed class CodeSessionOutcome {
  const CodeSessionOutcome();
}

/// A sender that proved it holds the code, and agreed.
class CodeSessionFound extends CodeSessionOutcome {
  final QRPayload payload;
  const CodeSessionFound(this.payload);
}

/// A sender reached over the internet that proved it holds the code, and
/// agreed. [payload] is the offer it handed over, exactly what its QR code
/// holds: from here the receiver goes the way a scan goes.
class CodeSessionFoundOnline extends CodeSessionOutcome {
  final String payload;
  const CodeSessionFoundOnline(this.payload);
}

/// A sender that proved it holds the code, and said no.
class CodeSessionDeclined extends CodeSessionOutcome {
  const CodeSessionDeclined();
}

/// Nothing was found on the local network, and the public services that
/// carry the internet search could not be reached at all. Told apart from
/// [CodeSessionNotFound] because "check the code" would be the wrong advice.
class CodeSessionNoNetwork extends CodeSessionOutcome {
  const CodeSessionNoNetwork();
}

/// Nothing that could prove it holds the code was found: no sender, or the
/// wrong code, or a different network. Deliberately one answer — telling
/// those apart would tell a stranger which of them he is looking at.
class CodeSessionNotFound extends CodeSessionOutcome {
  const CodeSessionNotFound();
}

/// The only devices that answered speak a protocol this build does not, or the
/// reverse.
class CodeSessionUpdateRequired extends CodeSessionOutcome {
  const CodeSessionUpdateRequired();
}

/// A sender proved itself and then stopped answering.
class CodeSessionUnreachable extends CodeSessionOutcome {
  const CodeSessionUnreachable();
}

/// Finds the device offering a session code and asks it for the session.
///
/// ## What is trusted
///
/// Nothing a device says about itself. Not its name, not the fingerprint it
/// announced over mDNS, not the hint it announced for the code, not what it
/// reports about its own port or certificate. Any of those can be written by
/// anyone on the network, and the code is a little over 33 bits: a device
/// handed the code can hand back a session of its own, and one sent anything
/// derived from it can try the whole space at home.
///
/// What is trusted is a proof. Each candidate is asked to run SPAKE2 with the
/// code as the password, bound to the fingerprint of the certificate the
/// receiver was actually served on that connection (see [CodePake]). Only a
/// device that holds the code — and holds the private key of the certificate
/// it presented — answers with a confirmation that verifies. Until one does,
/// the candidate has been sent a single curve point that depends on nothing it
/// could test. The code is never sent, this device's name is never sent, and
/// the session is pinned to the fingerprint that was proved, not to anything
/// announced.
///
/// ## Which candidates
///
/// Every device that announced the hint of this code, and the addresses that
/// could be a sender without having announced anything, concurrently. A hint
/// is announced by whoever wants to be picked, so one match is not "the"
/// sender, and an impostor that answers slowly or never must not be able to
/// hold up the real one: the first candidate to verify wins and the rest are
/// dropped. A device that announced a *different* hint is never contacted at
/// all — it has said it is offering something else.
class CodeSessionResolver {
  /// Senders currently heard on the network. Nothing here is ever shown.
  final List<RendezvousCandidate> Function() peers;

  /// New lists as they are heard, so a sender whose announcement is late is
  /// still found within [discoveryWindow]. Null when nothing is listening.
  final Stream<List<RendezvousCandidate>>? peerUpdates;

  /// Asks the network to announce again.
  final Future<void> Function()? refresh;

  /// Addresses worth trying whether or not anyone announced them, given the
  /// candidates whose hint matches. Defaults to [defaultProbeTargets].
  final Future<List<ProbeTarget>> Function(List<RendezvousCandidate> matching)?
      probeTargets;

  /// What the sender's person is shown when asked to approve.
  final String deviceName;

  /// How long one candidate has, from the first connection to a verdict.
  /// Isolated from the others, and from [inviteTimeout].
  final Duration candidateTimeout;

  /// How long to keep listening for an announcement that has not arrived yet
  /// before concluding there is nobody.
  final Duration discoveryWindow;

  /// How long a person on the sender's side has to decide.
  final Duration inviteTimeout;

  CodeSessionResolver({
    required this.peers,
    this.peerUpdates,
    this.refresh,
    this.probeTargets,
    required this.deviceName,
    this.candidateTimeout = const Duration(seconds: 5),
    this.discoveryWindow = const Duration(seconds: 4),
    this.inviteTimeout = const Duration(seconds: 95),
  });

  /// The usual suspects: the address of every candidate that announced this
  /// code's hint, on the port it announced, and the first address of this
  /// device's subnet on the ports a sender starts at, where a router that
  /// hosts is.
  ///
  /// For the networks where multicast is blocked and nothing is announced.
  static Future<List<ProbeTarget>> defaultProbeTargets(
      List<RendezvousCandidate> matching) async {
    final targets = <InternetAddress, Set<int>>{};
    for (final candidate in matching) {
      if (candidate.address.isLoopback) continue;
      targets.putIfAbsent(candidate.address, () => {}).add(candidate.port);
    }

    try {
      final localIp = await NetworkInfoService().getLocalIpAddress();
      if (localIp != null && localIp.isNotEmpty) {
        final lastDot = localIp.lastIndexOf('.');
        if (lastDot != -1) {
          final gateway =
              InternetAddress.tryParse('${localIp.substring(0, lastDot)}.1');
          if (gateway != null) {
            targets.putIfAbsent(gateway, () => {}).addAll([
              AppConstants.serverPortMin,
              AppConstants.serverPortMin + 1,
            ]);
          }
        }
      }
    } catch (_) {}

    return [
      for (final entry in targets.entries)
        for (final port in entry.value) (address: entry.key, port: port),
    ];
  }

  /// Finds the sender of [code], and asks it for the session.
  ///
  /// With a [gate], the search is one of two running side by side: it stops
  /// when the gate does, and it must win the gate before it reveals this
  /// device to the sender it just proved.
  Future<CodeSessionOutcome> resolve(SessionCode code,
      {SearchGate? gate}) async {
    final hint = code.discoveryHint;
    final winner = Completer<_Verified?>();
    final started = <String>{};
    final clients = <HttpClient>{};
    var running = 0;
    var windowOpen = peerUpdates != null;
    var sawUpdateRequired = false;
    var sawWrongProof = false;
    Timer? window;
    StreamSubscription<List<RendezvousCandidate>>? updates;

    void settle() {
      if (!windowOpen && running == 0 && !winner.isCompleted) {
        winner.complete(null);
      }
    }

    void launch(InternetAddress address, int port) {
      if (winner.isCompleted) return;
      if (!started.add('${address.address}:$port')) return;
      running++;
      _authenticate(address, port, code, clients).then((result) {
        switch (result) {
          case _Verified():
            if (winner.isCompleted) {
              result.client.close(force: true);
            } else {
              winner.complete(result);
            }
          case _Failed(:final verdict):
            if (verdict == _Verdict.updateRequired) sawUpdateRequired = true;
            if (verdict == _Verdict.wrongProof) sawWrongProof = true;
        }
      }).whenComplete(() {
        running--;
        settle();
      });
    }

    var announcedMatch = false;
    List<RendezvousCandidate> matching(List<RendezvousCandidate> heard) =>
        [for (final c in heard) if (c.hint == hint) c];

    void consider(List<RendezvousCandidate> heard) {
      for (final candidate in matching(heard)) {
        announcedMatch = true;
        launch(candidate.address, candidate.port);
      }
    }

    final heard = peers();
    consider(heard);
    if (!announcedMatch) unawaited(refresh?.call());

    updates = peerUpdates?.listen(consider);
    if (windowOpen) {
      window = Timer(discoveryWindow, () {
        windowOpen = false;
        settle();
      });
    }

    final targets =
        await (probeTargets ?? defaultProbeTargets)(matching(heard));
    for (final target in targets) {
      launch(target.address, target.port);
    }
    settle();

    final _Verified? verified;
    try {
      verified = gate == null
          ? await winner.future
          : await Future.any<_Verified?>([
              winner.future,
              gate.stopped.then<_Verified?>((_) => null),
            ]);
    } finally {
      window?.cancel();
      await updates?.cancel();
    }

    // Whatever is still talking to a candidate that lost is not wanted: it may
    // be an impostor holding a connection open, and nothing it could still say
    // matters.
    for (final client in clients) {
      if (verified == null || !identical(client, verified.client)) {
        client.close(force: true);
      }
    }

    if (verified == null) {
      if (gate != null && gate.isStopped) return const CodeSessionNotFound();
      // A device that answered the proof and failed it outranks one that
      // could not run it: a wrong code is the more useful thing to say.
      if (sawWrongProof) return const CodeSessionNotFound();
      if (sawUpdateRequired) return const CodeSessionUpdateRequired();
      return const CodeSessionNotFound();
    }

    // Proved is not chosen: with another search running, only the first to
    // prove the code gets to say who this device is.
    if (gate != null && !gate.tryClaim()) {
      verified.client.close(force: true);
      return const CodeSessionNotFound();
    }

    AppLogger.info(
      'Session code proved to ${verified.address.address}:${verified.port}',
      tag: 'CODE',
    );
    gate?.awaitingApproval();
    return _invite(verified, gate);
  }

  /// Runs the proof against one candidate. Never throws: every failure is a
  /// verdict, and the only difference between verdicts is what the person is
  /// finally told.
  Future<_AttemptResult> _authenticate(
    InternetAddress address,
    int port,
    SessionCode code,
    Set<HttpClient> clients,
  ) async {
    final client =
        HttpClient(context: SecurityContext(withTrustedRoots: false));
    client.connectionTimeout = const Duration(milliseconds: 1500);
    clients.add(client);

    // The certificate this connection was served, recorded rather than
    // judged: whether it is the sender's is what the proof is for. Pinned
    // after that — a second connection on this client that presents anything
    // else is refused, so the proof and the request that follows it cannot be
    // answered by different devices.
    String? served;
    client.badCertificateCallback = (X509Certificate cert, String host, int p) {
      final fingerprint = SessionTlsIdentity.fingerprintOf(cert.der);
      served ??= fingerprint;
      return fingerprint == served;
    };

    try {
      return await _prove(client, address, port, code, () => served)
          .timeout(candidateTimeout);
    } catch (_) {
      client.close(force: true);
      return const _Failed(_Verdict.noAnswer);
    }
  }

  Future<_AttemptResult> _prove(
    HttpClient client,
    InternetAddress address,
    int port,
    SessionCode code,
    String? Function() served,
  ) async {
    final base = 'https://${address.address}:$port';

    // Pre-filter: a host that does not even claim to speak this protocol is
    // not worth the arithmetic. Says nothing about whether it is trusted — it
    // is a request with no secret in it, answered by whoever is there.
    final health = await (await client.getUrl(Uri.parse('$base/v2/health')))
        .close();
    if (health.statusCode != HttpStatus.ok) {
      await health.drain<void>();
      return const _Failed(_Verdict.noAnswer);
    }
    final healthData = jsonDecode(await _readBounded(health));
    if (healthData is! Map || healthData['protocol'] != 'QHTP') {
      return const _Failed(_Verdict.noAnswer);
    }
    final fingerprint = served();
    if (fingerprint == null) return const _Failed(_Verdict.noAnswer);

    // A share of this candidate's own: reusing one across devices would let
    // two of them compare notes.
    final begun = await CodePake.begin(code);
    final request = await client.postUrl(Uri.parse('$base${CodePake.startPath}'));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({'pA': CodePake.encode(begun.share)}));
    final response = await request.close();

    // A build from before the proof existed answers behind its token wall,
    // and one that is newer than this would not be asked at all.
    if (response.statusCode == HttpStatus.notFound ||
        response.statusCode == HttpStatus.unauthorized) {
      await response.drain<void>();
      return const _Failed(_Verdict.updateRequired);
    }
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      return const _Failed(_Verdict.noAnswer);
    }

    final data = jsonDecode(await _readBounded(response));
    if (data is! Map) return const _Failed(_Verdict.wrongProof);
    final pakeId = data['pakeId'];
    final senderShare =
        CodePake.decode(data['pB'], length: Spake2.shareLength);
    final senderTag =
        CodePake.decode(data['cB'], length: CodePake.tagLength);
    if (pakeId is! String ||
        pakeId.isEmpty ||
        pakeId.length > 64 ||
        senderShare == null ||
        senderTag == null) {
      return const _Failed(_Verdict.wrongProof);
    }

    final Spake2Keys keys;
    try {
      keys = await CodePake.complete(begun,
          senderShare: senderShare, certFingerprint: fingerprint);
    } catch (_) {
      return const _Failed(_Verdict.wrongProof);
    }
    if (!keys.verifies(Spake2Role.b, senderTag)) {
      // Dropped without a word: whoever this is, it learns nothing from us.
      AppLogger.info(
        'Candidate ${address.address}:$port did not prove the code',
        tag: 'CODE',
      );
      return const _Failed(_Verdict.wrongProof);
    }

    return _Verified(
      client: client,
      address: address,
      port: port,
      fingerprint: fingerprint,
      pakeId: pakeId,
      confirmation: keys.confirmationA,
    );
  }

  /// The second round, to a sender that has proved itself: this device's
  /// confirmation, and only now its name.
  ///
  /// The session's token comes back in the response to this request — over the
  /// TLS connection the proof was made on — and nowhere else. There is no
  /// address for the sender to push it to: an earlier version offered one, and
  /// the sender then POSTed the token in plaintext to whatever was listening
  /// there.
  Future<CodeSessionOutcome> _invite(_Verified sender, SearchGate? gate) async {
    final client = sender.client;
    // The person here may give up while the person there is deciding. Closing
    // the connection is what ends the wait.
    unawaited(gate?.stopped.then((_) => client.close(force: true)));
    try {
      final uri = Uri.parse(
          'https://${sender.address.address}:${sender.port}/v2/invite/request');
      final request = await client.postUrl(uri).timeout(candidateTimeout);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({
        'pakeId': sender.pakeId,
        'cA': CodePake.encode(sender.confirmation),
        'deviceName': deviceName,
      }));
      final response = await request.close().timeout(inviteTimeout);

      if (response.statusCode == 426) {
        await response.drain<void>();
        return const CodeSessionUpdateRequired();
      }
      if (response.statusCode == HttpStatus.forbidden) {
        await response.drain<void>();
        return const CodeSessionNotFound();
      }
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return const CodeSessionUnreachable();
      }

      final data = jsonDecode(await _readBounded(response));
      if (data is! Map || data['outcome'] != 'accepted') {
        return const CodeSessionDeclined();
      }
      final token = data['token'];
      if (token is! String || token.isEmpty) {
        return const CodeSessionUnreachable();
      }
      final itemCount = data['itemCount'];
      final totalBytes = data['totalBytes'];
      final sessionId = data['sessionId'];
      final senderName = data['senderName'];
      return CodeSessionFound(QRPayload(
        version: AppConstants.qhtpPayloadVersion,
        ip: sender.address.address,
        port: sender.port,
        token: token,
        sessionId: sessionId is String ? sessionId : token,
        mode: 'http-lan',
        // The fingerprint that was proved. The response carries one too, and
        // it is ignored: a value the sender reports about itself was never
        // what established who it is.
        tlsFingerprint: sender.fingerprint,
        itemCount: itemCount is int ? itemCount : 1,
        fileSize: totalBytes is int ? totalBytes : 0,
        senderName: senderName is String ? senderName : null,
      ));
    } catch (e) {
      AppLogger.warning(
          'Could not request the session from '
          '${sender.address.address}:${sender.port}: $e',
          tag: 'CODE');
      return const CodeSessionUnreachable();
    } finally {
      client.close(force: true);
    }
  }

  /// A response body as text, refusing more than a few kilobytes: everything
  /// asked of an unauthenticated device is a few hundred bytes, and one that
  /// answers with more is not worth the memory.
  static Future<String> _readBounded(HttpClientResponse response,
      {int limit = 8192}) async {
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > limit) throw const FormatException('body too large');
    }
    return utf8.decode(bytes);
  }
}

enum _Verdict {
  /// Unreachable, silent, slow, not this protocol, or refused for a reason
  /// that says nothing about the code.
  noAnswer,

  /// Answered the proof's first round with a protocol this build does not
  /// share.
  updateRequired,

  /// Answered, and the answer did not verify: the wrong code, or a device in
  /// the middle, or something that merely sounds like a sender.
  wrongProof,
}

sealed class _AttemptResult {
  const _AttemptResult();
}

class _Failed extends _AttemptResult {
  final _Verdict verdict;
  const _Failed(this.verdict);
}

/// A sender that proved it holds the code and the certificate private key
/// behind [fingerprint].
class _Verified extends _AttemptResult {
  /// The connection the proof was made on. The request that follows goes over
  /// it, or over one that presents the same certificate.
  final HttpClient client;
  final InternetAddress address;
  final int port;
  final String fingerprint;
  final String pakeId;
  final List<int> confirmation;

  const _Verified({
    required this.client,
    required this.address,
    required this.port,
    required this.fingerprint,
    required this.pakeId,
    required this.confirmation,
  });
}
