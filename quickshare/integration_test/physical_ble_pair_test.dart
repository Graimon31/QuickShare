// Mac and physical iPhone, real BLE rendezvous and the app's
// direct-link/QHTP pipeline. No camera: a temporary authenticated test-control
// endpoint passes the current QR payload. This endpoint uses plaintext HTTP;
// use a trusted LAN and a fresh random PAIR_BLE_CONTROL for each run. It is
// never used to carry file bytes. Start the Mac sender first. Both devices use
// PAIR_BLE_CONTROL; the receiver also needs PAIR_BLE_HOST and PAIR_BLE_PORT printed
// by the sender. PAIR_BLE_ROLE is sender or receiver.
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:quickshare/core/diagnostics/transfer_report.dart';
import 'package:quickshare/core/errors/exceptions.dart';
import 'package:quickshare/core/network/network_info_service.dart';
import 'package:quickshare/core/storage/receive_destination.dart';
import 'package:quickshare/core/storage/save_location_store.dart';
import 'package:quickshare/core/storage/transfer_cache.dart';
import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/features/receiver/data/store/session_state_store.dart';
import 'package:quickshare/features/receiver/data/transports/bluetooth_receiver_session.dart';
import 'package:quickshare/features/receiver/data/transports/bluetooth_receiver_transport.dart';
import 'package:quickshare/features/sender/data/indexer/file_indexer.dart';
import 'package:quickshare/features/sender/data/qr/qr_payload_encoder.dart';
import 'package:quickshare/features/sender/data/repositories/sender_repository_impl.dart';
import 'package:quickshare/features/sender/data/server/local_http_server.dart';
import 'package:quickshare/features/sender/domain/transports/transfer_transport.dart';
import 'package:quickshare/features/sender/presentation/bloc/sender_bloc.dart';
import 'package:quickshare/shared/models/bluetooth_qr_payload.dart';

import 'physical_test_config.dart';

final role = physicalString(
    'PAIR_BLE_ROLE', const String.fromEnvironment('PAIR_BLE_ROLE'));
final controlSecret = physicalString(
    'PAIR_BLE_CONTROL', const String.fromEnvironment('PAIR_BLE_CONTROL'));
final host = physicalString(
    'PAIR_BLE_HOST', const String.fromEnvironment('PAIR_BLE_HOST'));
final port =
    physicalInt('PAIR_BLE_PORT', const int.fromEnvironment('PAIR_BLE_PORT'));
final qrOverride = physicalString('PAIR_BLE_QR', '');
const filename = 'physical-ble-payload.bin';
const bytes = 512 * 1024;

Uint8List fixture() => Uint8List.fromList(
    List<int>.generate(bytes, (i) => ((i * 71) ^ (i >> 5) ^ 173) & 255));

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('physical BLE rendezvous and Wi-Fi file transfer',
      (tester) async {
    await tester.pumpWidget(const Directionality(
        textDirection: TextDirection.ltr, child: SizedBox.shrink()));
    String? diagnosticToken;
    String? diagnosticLocator;
    String sanitize(String value) {
      var sanitized = value;
      for (final secret in [
        controlSecret,
        diagnosticToken,
        diagnosticLocator
      ]) {
        if (secret != null && secret.isNotEmpty) {
          sanitized = sanitized.replaceAll(secret, '[redacted]');
        }
      }
      // Advertised names and Bonjour service names can incorporate a locator.
      return sanitized
          .replaceAll(RegExp(r'name=\S+'), 'name=[redacted]')
          .replaceAllMapped(RegExp(r'Peer link (hosting as|joined) \S+'),
              (match) => 'Peer link ${match[1]} [redacted]')
          .replaceAll(RegExp(r'connecting to .*'), 'connecting to [redacted]')
          .replaceAll(RegExp(r'START:\S+'), 'START:[redacted]');
    }

    final diagnostics = AppLogger.logStream.listen((line) {
      const tags = ['BLE_NATIVE', 'BT_RECEIVER', 'BLE_RECEIVER', 'PEERLINK'];
      if (tags.any((tag) => line.contains('[$tag]'))) {
        print('PAIR_BLE_LOG ${sanitize(line)}');
      }
    });
    addTearDown(diagnostics.cancel);
    expect(['sender', 'receiver'], contains(role));
    expect(RegExp(r'^[A-Za-z0-9]{16,64}$').hasMatch(controlSecret), isTrue,
        reason: 'use a fresh random alphanumeric control secret');
    final workspace = await Directory.systemTemp.createTemp('dd_ble_physical_');
    addTearDown(() async {
      if (await workspace.exists()) await workspace.delete(recursive: true);
    });
    final expectedHash = sha256.convert(fixture()).toString();

    if (role == 'sender') {
      expect(Platform.isMacOS || Platform.isIOS, isTrue,
          reason: 'the sender must be a Mac or iPhone');
      final file = File(p.join(workspace.path, filename));
      await file.writeAsBytes(fixture(), flush: true);
      final localServer = LocalHttpServer();
      final repo = SenderRepositoryImpl(
        localServer: localServer,
        networkInfoService: NetworkInfoService(),
        qrEncoder: QRPayloadEncoder(),
        indexer: FileIndexer(),
      );
      final bloc = SenderBloc(
        repository: repo,
        diagnostics: TransferDiagnostics(overrideDir: () => workspace),
      );
      addTearDown(() async {
        await bloc.close();
        repo.dispose();
      });
      final completed = Completer<void>();
      String? currentQr;
      final states = bloc.stream.listen((state) {
        print('PAIR_BLE_STATE ${state.runtimeType}');
        if (state is BluetoothAdvertising) currentQr = state.qrData;
        if (state is SenderError && !completed.isCompleted) {
          completed.completeError(StateError('sender error: ${state.message}'));
        }
        if (state is TransferComplete && !completed.isCompleted) {
          completed.complete();
        }
      });
      addTearDown(states.cancel);
      final control = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      addTearDown(() => control.close(force: true));
      final controlSub = control.listen((request) async {
        if (request.method != 'GET' ||
            request.uri.path != '/offer' ||
            request.headers.value('x-pair-secret') != controlSecret) {
          request.response.statusCode = HttpStatus.forbidden;
        } else if (currentQr == null) {
          request.response.statusCode = HttpStatus.serviceUnavailable;
        } else {
          request.response.headers.contentType = ContentType.text;
          request.response.write(currentQr);
        }
        await request.response.close();
      });
      addTearDown(controlSub.cancel);
      for (final interface in await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false)) {
        for (final address in interface.addresses) {
          print('PAIR_BLE_ADDRESS ${interface.name} ${address.address}');
        }
      }
      print('PAIR_BLE_PORT=${control.port}');
      bloc.add(StartQhtpSend([file.path], mode: TransportType.bluetooth));
      await completed.future.timeout(const Duration(minutes: 12));
      print('PAIR_BLE_SENDER_COMPLETE');
      return;
    }

    expect(Platform.isMacOS || Platform.isIOS, isTrue,
        reason: 'the receiver must be a Mac or iPhone');
    BluetoothQrPayload? qr;
    if (qrOverride.isNotEmpty) {
      qr = BluetoothQrPayload.tryDecode(qrOverride);
      expect(qr, isNotNull,
          reason: 'controller must provide a valid Bluetooth QR payload');
    } else {
      final address = InternetAddress.tryParse(host);
      expect(address, isNotNull);
      expect(address!.type, InternetAddressType.IPv4);
      expect(address.isLoopback, isFalse);
      expect(port, inInclusiveRange(1, 65535));
      final http = HttpClient();
      addTearDown(() => http.close(force: true));
      final deadline = DateTime.now().add(const Duration(minutes: 2));
      while (qr == null && DateTime.now().isBefore(deadline)) {
        final request = await http.getUrl(
            Uri(scheme: 'http', host: host, port: port, path: '/offer'));
        request.headers.set('x-pair-secret', controlSecret);
        final response = await request.close();
        final body =
            await response.transform(const SystemEncoding().decoder).join();
        if (response.statusCode == HttpStatus.ok) {
          qr = BluetoothQrPayload.tryDecode(body);
          expect(qr, isNotNull,
              reason: 'sender must provide a valid Bluetooth QR payload');
        } else {
          expect(response.statusCode, HttpStatus.serviceUnavailable,
              reason: 'control endpoint rejected the receiver');
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }
    }
    expect(qr, isNotNull, reason: 'sender never advertised');
    final offer = qr!;
    diagnosticToken = offer.token;
    diagnosticLocator = offer.locator;
    expect(offer.locator, isNotEmpty);
    // This deletes only the record created for this fresh random BLE token.
    addTearDown(() => SessionStateStore().deleteState(offer.token));
    final cache = TransferCache(overrideRoot: () => workspace);
    final locationStore = SaveLocationStore(
      overrideDir: () => Directory(p.join(workspace.path, 'config')),
    );
    if (Platform.isMacOS) {
      final receiveDir = Directory(p.join(workspace.path, 'receive'));
      await receiveDir.create(recursive: true);
      await locationStore.set(receiveDir.path);
    }
    final destination = await ReceiveDestination.resolve(
      cache: cache,
      saveLocation: locationStore,
    );
    addTearDown(destination.release);
    if (Platform.isMacOS) {
      final workspacePath = await workspace.resolveSymbolicLinks();
      final destinationPath =
          await Directory(destination.path).resolveSymbolicLinks();
      expect(p.isWithin(workspacePath, destinationPath), isTrue,
          reason: 'the receiver must write into this run’s workspace');
    }
    final transport = BluetoothReceiverTransport();
    addTearDown(transport.dispose);
    final radioFailures = transport.failures.listen((failure) {
      print('PAIR_BLE_RADIO_FAILURE code=${sanitize(failure.code)} '
          'message=${sanitize(failure.message)}');
    });
    addTearDown(radioFailures.cancel);
    final receiver = BluetoothReceiverSession(transport: transport);
    addTearDown(receiver.cancel);
    late final BluetoothReceiverSessionResult result;
    try {
      result = await receiver
          .run(
            token: offer.token,
            locator: offer.locator,
            destination: destination,
            onProgress: (received, total, name) =>
                print('PAIR_BLE_PROGRESS $received/$total $name'),
            onVerifying: () => print('PAIR_BLE_VERIFYING'),
          )
          .timeout(const Duration(minutes: 5));
    } on FileException catch (error) {
      print(
          'PAIR_BLE_RECEIVER_FAILURE code=${sanitize(error.code ?? "<none>")} '
          'message=${sanitize(error.message)}');
      rethrow;
    } catch (error) {
      print('PAIR_BLE_RECEIVER_FAILURE type=${error.runtimeType} '
          'message=${sanitize(error.toString())}');
      rethrow;
    }
    expect(result.items, hasLength(1));
    final received = File(p.join(destination.path, filename));
    expect(await received.exists(), isTrue);
    expect(await received.length(), bytes);
    final actualHash =
        (await sha256.bind(received.openRead()).first).toString();
    expect(actualHash, expectedHash);
    print('PAIR_BLE_SHA256=$actualHash');
    print('PAIR_BLE_RECEIVER_COMPLETE');
  }, timeout: const Timeout(Duration(minutes: 15)));
}
