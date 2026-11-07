// The Bluetooth screen is a QR code, and only that.
//
// Another device in radio range announcing itself must not appear on this
// screen as a row to be picked: devices are joined by the QR or the code, and
// they do not see each other. This drives the real bloc over the real
// transport with the Apple bridge selected, lets the radio report receivers
// and passers-by the way the native side does, and then looks at what a person
// would see.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:quickshare/core/diagnostics/transfer_report.dart';
import 'package:quickshare/core/network/local_hotspot_service.dart';
import 'package:quickshare/core/network/peer_link_service.dart';
import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';
import 'package:quickshare/features/sender/domain/repositories/sender_repository.dart';
import 'package:quickshare/features/sender/domain/transports/transfer_transport.dart';
import 'package:quickshare/features/sender/presentation/bloc/sender_bloc.dart';
import 'package:quickshare/features/sender/presentation/pages/bluetooth_send_page.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';
import 'package:quickshare/shared/models/bluetooth_qr_payload.dart';

class _MockRepository extends Mock implements SenderRepository {}

class _MockHotspot extends Mock implements LocalHotspotService {}

class _SilentPeerLink extends PeerLinkService {
  const _SilentPeerLink();
  @override
  Future<void> stop() async {}
}

class _NoDiagnostics extends TransferDiagnostics {
  const _NoDiagnostics();
  @override
  Future<void> record(TransferReport report) async {}
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('quickshare/bluetooth');
  const events = MethodChannel('quickshare/bluetooth/events');
  const codec = StandardMethodCodec();

  /// What the native bridge says, as the event channel would deliver it.
  Future<void> radioSays(Map<String, Object?> event) async {
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      events.name,
      codec.encodeSuccessEnvelope(event),
      (_) {},
    );
  }

  setUp(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(methods,
        (call) async {
      if (call.method == 'startAdvertising') {
        await radioSays({'type': 'advertisingStarted'});
      }
      return null;
    });
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(events, (call) async => null);
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(methods, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(events, null);
  });

  testWidgets('shows the QR and no device, whoever the radio reports',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final bloc = await tester.runAsync(() async {
      final repository = _MockRepository();
      when(() => repository.stopServer(force: any(named: 'force')))
          .thenAnswer((_) async => const Right(null));
      when(() => repository.transferProgress)
          .thenAnswer((_) => const Stream.empty());
      when(() => repository.statusStream)
          .thenAnswer((_) => const Stream.empty());
      when(() => repository.approvalRequests)
          .thenAnswer((_) => const Stream.empty());
      final hotspot = _MockHotspot();
      when(hotspot.stopHosting).thenAnswer((_) async {});

      final bloc = SenderBloc(
        repository: repository,
        hotspotService: hotspot,
        peerLinkService: const _SilentPeerLink(),
        diagnostics: const _NoDiagnostics(),
      );
      bloc.add(const StartSendingWithTransport(
        FileMetadata(
          name: 'offer.bin',
          path: '/tmp/offer.bin',
          size: 5,
          mimeType: 'application/octet-stream',
        ),
        TransportType.bluetooth,
      ));
      await bloc.stream
          .firstWhere((s) => s is BluetoothAdvertising)
          .timeout(const Duration(seconds: 10));

      // Devices that announced themselves, and one that merely advertised the
      // same service. Neither is a row.
      await radioSays({'type': 'receiverAnnounced', 'name': 'Anna iPhone'});
      await radioSays({
        'type': 'deviceDiscovered',
        'id': 'AAAA-BBBB',
        'name': 'Boris MacBook',
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));
      return bloc;
    });

    try {
      expect(bloc!.state, isA<BluetoothAdvertising>());

      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BlocProvider<SenderBloc>.value(
            value: bloc, child: const BluetoothSendPage()),
      ));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      final shown = (bloc.state as BluetoothAdvertising).qrData;
      expect(find.byType(QrImageView), findsOneWidget);
      expect(BluetoothQrPayload.tryDecode(shown), isNotNull,
          reason: 'the code on screen is a Bluetooth session');

      expect(find.byType(ListTile), findsNothing);
      expect(find.text('Anna iPhone'), findsNothing);
      expect(find.text('Boris MacBook'), findsNothing);
      for (final word in ['Devices nearby', 'Ready to send', 'from the list']) {
        expect(find.textContaining(word), findsNothing, reason: word);
      }
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => bloc!.close());
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
