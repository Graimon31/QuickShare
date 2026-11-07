// The receiving half of the real remote peer check: a machine that is not on
// the sender's network types the sender's code, finds the sender over the
// internet, takes the file and checks it byte for byte. It runs in two modes,
// picked by which defines are given.
//
// **A GitHub runner receives, a Mac sent** (`to-runner`). The file is described
// by its SHA-256:
//
//     flutter test integration_test/ci_peer_receiver.dart -d macos \
//         --dart-define=CI_PEER_CODE=1234567890 \
//         --dart-define=CI_PEER_NAME=ci-peer-1a2b3c \
//         --dart-define=CI_PEER_BYTES=52428800 \
//         --dart-define=CI_PEER_SHA256=<64 hex digits>
//
// `.github/workflows/ci_peer.yml` runs it with the values in
// `ci-peer/peer.json`.
//
// **A Mac receives, a GitHub runner sends** (`to-mac`). The Mac picked the code
// and a seed that stands for the file, so it does not have a SHA-256 to give: it
// works the hash out from the seed and the size, and fails on any difference
// from what arrives. The sender is a runner that is still being built, so the
// search is typed again and again, for as long as `CI_PEER_FIND_MINUTES` says
// (40 by default in this mode), until a sender answers:
//
//     flutter test integration_test/ci_peer_receiver.dart -d macos \
//         --dart-define=CI_PEER_CODE=1234567890 \
//         --dart-define=CI_PEER_NAME=ci-peer-1a2b3c \
//         --dart-define=CI_PEER_BYTES=52428800 \
//         --dart-define=CI_PEER_SEED=<64 hex digits>
//
// `integration_test/ci_peer_to_mac.sh` picks all of it, pushes the runner's
// half and starts this.
//
// The search is the code screen's own: the local network and the internet
// together, the real Nostr relays and the real Worker. The answer goes back
// sealed through the same public channels, and the bytes travel on whatever
// path ICE chooses — through the real TURN relay when nothing direct works.
//
// It fails on any difference at all: the size, the SHA-256, a sender that
// declines, a file that never arrives, anything left in the destination but
// the one file. A run that did not verify the bytes does not pass. The file is
// received into a temporary folder that is deleted at the end.
//
// The result goes to the log, and to `$GITHUB_STEP_SUMMARY` when that is set
// and writable. (A sandboxed macOS app usually cannot reach the runner's file;
// the workflow then writes the summary from the log, and this says so with
// `CI_PEER_SUMMARY_WRITTEN=no`.)
//
// Defines: CI_PEER_CODE, CI_PEER_NAME, CI_PEER_BYTES, and CI_PEER_SHA256 or
// CI_PEER_SEED (all required, the last two not together); CI_PEER_FIND_ATTEMPTS
// (default 5), CI_PEER_FIND_MINUTES (default: search for that long instead of
// FIND_ATTEMPTS times; 40 when a seed is given), CI_PEER_TRANSFER_MINUTES
// (default 20); QUICKSHARE_FORCE_RELAY=true for relay candidates only.
//
// Run `flutter build macos --debug` afterwards on a Mac: an integration run
// replaces the app bundle with its own.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:quickshare/core/network/session_code.dart';

import 'ci_peer_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a file arrives by its code from a sender on another network, whole',
    () async {
      final problems = ciPeerReceiverProblems(
        code: CiPeerDefines.code,
        name: CiPeerDefines.name,
        bytes: CiPeerDefines.bytes,
        sha256Hex: CiPeerDefines.sha256Hex,
        seedHex: CiPeerDefines.seed,
      );

      final CiPeerReport report;
      if (problems.isNotEmpty) {
        report = CiPeerReport('receiver')
          ..status = 'failure'
          ..error = 'the receiver was not given what it needs: '
              '${problems.join('; ')}';
      } else {
        final workspace = Directory.systemTemp.createTempSync('dd_ci_peer_recv_');
        addTearDown(() => workspace.deleteSync(recursive: true));
        final destination = Directory('${workspace.path}/incoming')
          ..createSync();
        // Told, or worked out from the seed it was given instead. Worked out
        // here, before the search starts, so that the seconds it takes are not
        // spent while a sender is waiting.
        final expected = CiPeerDefines.seed.isEmpty
            ? CiPeerDefines.sha256Hex
            : await ciPeerSeededSha256(CiPeerDefines.bytes, CiPeerDefines.seed);
        report = await ciPeerReceive(
          code: SessionCode.parse(CiPeerDefines.code)!,
          name: CiPeerDefines.name,
          expectedBytes: CiPeerDefines.bytes,
          expectedSha256: expected,
          destination: destination,
          findAttempts: CiPeerDefines.findAttempts,
          findFor: CiPeerDefines.findFor,
          transferFor: CiPeerDefines.transferFor,
        );
      }

      print('CI_PEER ---- receiver result ----');
      for (final line in report.lines()) {
        print('CI_PEER $line');
      }
      final written = await ciPeerAppendStepSummary(report.markdown(
          title: 'DirectDrop: receiving by code from a remote sender'));
      print('CI_PEER_SUMMARY_WRITTEN=${written ? 'yes' : 'no'}');
      print('CI_PEER_RESULT_JSON=${jsonEncode(report.toJson())}');

      expect(report.status, 'success',
          reason: report.error ?? 'the receiver did not finish');
    },
    // The search (a few attempts, or as long as asked), the transfer after it,
    // and slack for the hash and for everything to be torn down.
    timeout: Timeout((CiPeerDefines.findFor ??
            const Duration(minutes: CiPeerDefines.findAttempts)) +
        CiPeerDefines.transferFor +
        const Duration(minutes: 8)),
  );
}
