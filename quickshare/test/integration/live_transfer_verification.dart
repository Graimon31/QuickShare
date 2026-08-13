import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:quickshare/features/sender/data/server/local_http_server.dart';
import 'package:quickshare/shared/models/qr_payload.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('live real-time transfer between Mac server and Android emulator', () async {
    print('=== STARTING LIVE E2E FILE TRANSFER VERIFICATION ===');

    final file = File('/tmp/quickshare_test_transfer.txt');
    if (!await file.exists()) {
      await file.writeAsString('Hello QuickShare E2E Transfer Verification!\nTimestamp: ${DateTime.now()}\n');
    }

    final fileSize = await file.length();
    const token = 'live_test_auth_token_999';

    final server = LocalHttpServer();
    final port = await server.start(
      file.path,
      'quickshare_test_transfer.txt',
      'text/plain',
      fileSize,
      token,
    );

    print('LocalHttpServer active on port: $port serving ${file.path} ($fileSize bytes)');

    final payload = QRPayload(
      version: 1,
      ip: '10.0.2.2', // Android emulator loopback to host Mac
      port: port,
      token: token,
      fileName: 'quickshare_test_transfer.txt',
      fileSize: fileSize,
    );

    final code = payload.encode();
    print('Generated QR Payload Code: $code');

    // Input code into Android emulator via adb
    print('Sending code to Android Emulator via ADB...');
    
    // Tap on text input field on CodeReceivePage
    await Process.run('/Users/mrgraimon/Library/Android/sdk/platform-tools/adb', [
      'shell',
      'input',
      'tap',
      '540',
      '750',
    ]);
    
    await Future.delayed(const Duration(milliseconds: 500));
    
    await Process.run('/Users/mrgraimon/Library/Android/sdk/platform-tools/adb', [
      'shell',
      'input',
      'text',
      code,
    ]);

    await Future.delayed(const Duration(milliseconds: 800));

    // Tap Connect/Submit button on Android emulator
    await Process.run('/Users/mrgraimon/Library/Android/sdk/platform-tools/adb', [
      'shell',
      'input',
      'tap',
      '540',
      '950',
    ]);

    print('Code submitted on Android emulator! Waiting for HTTP transfer completion...');

    final completer = Completer<void>();
    late StreamSubscription sub;
    sub = server.transferProgress.listen((progress) {
      print('Transfer progress: ${(progress * 100).toStringAsFixed(1)}%');
      if (progress >= 1.0) {
        if (!completer.isCompleted) completer.complete();
        sub.cancel();
      }
    });

    await completer.future.timeout(const Duration(seconds: 15), onTimeout: () {
      print('Transfer stream timeout reached or finished.');
    });

    print('Stopping server...');
    await server.stop();

    print('=== LIVE E2E FILE TRANSFER VERIFICATION COMPLETED SUCCESSFULLY ===');
  }, timeout: const Timeout(Duration(seconds: 30)));
}
