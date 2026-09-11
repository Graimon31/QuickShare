// macOS entitlements required for sandbox operation and persistent save location bookmarks.
//
// C5. Saving to a custom folder requires a security-scoped bookmark. In a sandboxed
// macOS app, creating and resolving security-scoped bookmarks fails unless the
// `com.apple.security.files.bookmarks.app-scope` entitlement is granted.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const bookmarkEntitlement =
      'com.apple.security.files.bookmarks.app-scope';

  String stripXmlComments(String content) =>
      content.replaceAll(RegExp(r'<!--.*?-->', multiLine: true, dotAll: true), '');

  test('DebugProfile.entitlements declares security-scoped bookmarks', () {
    final file = File('macos/Runner/DebugProfile.entitlements');
    expect(file.existsSync(), isTrue,
        reason: 'macos/Runner/DebugProfile.entitlements is missing');
    final stripped = stripXmlComments(file.readAsStringSync());
    expect(stripped, contains('<key>$bookmarkEntitlement</key>'));
  });

  test('Release.entitlements declares security-scoped bookmarks', () {
    final file = File('macos/Runner/Release.entitlements');
    expect(file.existsSync(), isTrue,
        reason: 'macos/Runner/Release.entitlements is missing');
    final stripped = stripXmlComments(file.readAsStringSync());
    expect(stripped, contains('<key>$bookmarkEntitlement</key>'));
  });

  test('Xcode project points to entitlements for both debug and release', () {
    final project =
        File('macos/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    expect(project, contains('Runner/DebugProfile.entitlements'));
    expect(project, contains('Runner/Release.entitlements'));
  });
}
