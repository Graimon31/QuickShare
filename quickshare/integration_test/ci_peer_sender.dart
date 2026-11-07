// The sending half of the real remote peer check: this machine offers a file
// by its ten-digit code over the real internet, and a receiver somewhere else
// — a GitHub-hosted runner — takes it.
//
//     flutter test integration_test/ci_peer_sender.dart -d macos \
//         --dart-define=CI_PEER_EXPECT_NAME=ci-peer-1a2b3c
//
// It prints one line, `CI_PEER_CODE=<ten digits>`, as soon as the code answers
// requests, and writes `{code, name, bytes, sha256}` to a file whose path it
// prints (`CI_PEER_OUT=...`). The receiver gets those from
// `ci-peer/peer.json` (see CI_PEER.md). When the receiver is done it writes the
// result into the same file: success or failure, the ICE path that carried the
// bytes and the candidate type on each end, the time, the speed.
//
// Everything is the app's own and the public services are the real ones: the
// Nostr relays and the DirectDrop Worker carry the code exchange and the
// sealed answer, the Worker hands out the TURN credentials. Nothing is
// replaced in memory. Run it under the VPN you normally have on.
//
// Defines (all optional but the first):
//
//     CI_PEER_EXPECT_NAME      the one receiver name that is accepted
//     CI_PEER_BYTES            size of the random file; default 50 MiB
//     CI_PEER_OUT              where the JSON goes; default: the app's temporary
//                              folder (the app is sandboxed on macOS, so a path
//                              outside it, other than ~/Downloads, is refused)
//     CI_PEER_WAIT_MINUTES     how long to wait for the receiver; default 40
//     CI_PEER_TRANSFER_MINUTES how long the transfer may take; default 20
//     CI_PEER_OFFER_REFRESH_SECONDS
//                              how old the offer gets before it is rebuilt
//                              under the same code; default 300, as in the app
//     QUICKSHARE_FORCE_RELAY=true
//                              relay candidates only (debug builds)
//
// Run `flutter build macos --debug` afterwards: an integration run replaces the
// app bundle with its own.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';

import 'ci_peer_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a file is offered by its code to the one receiver that is named',
    () async {
      if (CiPeerDefines.expectName.trim().isEmpty) {
        fail('CI_PEER_EXPECT_NAME is required: it is the one device name the '
            'sender will accept. The code ends up in a public repository, and '
            'without a name any device that reads it would be handed the file.');
      }
      const size = CiPeerDefines.bytes > 0
          ? CiPeerDefines.bytes
          : CiPeerDefines.defaultBytes;

      final workspace = Directory.systemTemp.createTempSync('dd_ci_peer_send_');
      addTearDown(() => workspace.deleteSync(recursive: true));
      final source = File(p.join(workspace.path, 'ci-peer-payload.zip'));

      print('CI_PEER making $size random bytes');
      final digest = await ciPeerWriteRandomFile(source, size);
      print('CI_PEER the file is ready, SHA-256 $digest');

      final code = SessionCode.generate();
      final outPath = CiPeerDefines.out.isNotEmpty
          ? CiPeerDefines.out
          : p.join(Directory.systemTemp.path, 'ci_peer_${code.code}.json');

      Map<String, Object?> document(Map<String, Object?>? result) => {
            'code': code.code,
            'name': CiPeerDefines.expectName,
            'bytes': size,
            'sha256': digest,
            if (result != null) 'result': result,
          };

      /// A path the sandbox refuses must not stop the check: the same JSON is
      /// printed on one line, and the file is a convenience.
      bool write(Map<String, Object?> content) {
        try {
          File(outPath).parent.createSync(recursive: true);
          File(outPath).writeAsStringSync(
              '${const JsonEncoder.withIndent('  ').convert(content)}\n');
          return true;
        } catch (e) {
          print('CI_PEER could not write $outPath (${e.runtimeType})');
          return false;
        }
      }

      final host = CiPeerOfferHost(
        file: FileMetadata(
          name: 'ci-peer-payload.zip',
          path: source.path,
          size: size,
          mimeType: 'application/zip',
        ),
        code: code,
        expectName: CiPeerDefines.expectName,
        waitFor: CiPeerDefines.waitFor,
        transferFor: CiPeerDefines.transferFor,
        offerLifetime: CiPeerDefines.offerLifetime,
      );

      final report = await host.run(onListening: () {
        final written = write(document(null));
        print('CI_PEER_CODE=${code.code}');
        print('CI_PEER_OUT=$outPath${written ? '' : ' (not written)'}');
        print('CI_PEER_JSON=${jsonEncode(document(null))}');
      });

      final finished = document(report.toJson());
      write(finished);
      print('CI_PEER_RESULT_JSON=${jsonEncode(finished)}');
      print('CI_PEER ---- sender result ----');
      for (final line in report.lines()) {
        print('CI_PEER $line');
      }

      expect(report.status, 'success',
          reason: report.error ?? 'the sender did not finish');
    },
    // The wait for the receiver, the transfer after it, and slack for the file
    // to be made and everything torn down.
    timeout: Timeout(CiPeerDefines.waitFor +
        CiPeerDefines.transferFor +
        const Duration(minutes: 10)),
  );
}
