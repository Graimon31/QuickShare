import 'package:flutter_test/flutter_test.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';
import 'package:quickshare/features/sender/domain/entities/transfer_session.dart';

void main() {
  const file = FileMetadata(
    name: 'a.txt',
    path: '/tmp/a.txt',
    size: 10,
    mimeType: 'text/plain',
  );

  test('legacy session defaults isQhtp false', () {
    final s = TransferSession(
      id: '1',
      fileMetadata: file,
      serverPort: 8000,
      authToken: 'tok',
      localIp: '192.168.1.1',
      startedAt: DateTime.now(),
    );
    expect(s.isQhtp, isFalse);
  });

  test('QHTP session sets isQhtp true and copyWith preserves', () {
    final s = TransferSession(
      id: 'sid',
      fileMetadata: file,
      serverPort: 8123,
      authToken: 'tok',
      localIp: '10.0.0.2',
      startedAt: DateTime.now(),
      isQhtp: true,
    );
    expect(s.isQhtp, isTrue);
    expect(s.copyWith(status: TransferStatus.serving).isQhtp, isTrue);
    expect(s.copyWith(isQhtp: false).isQhtp, isFalse);
  });
}
