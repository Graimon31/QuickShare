// A transfer is joined by a QR code or by ten digits, and by nothing else.
//
// The `directdrop://join` link existed for one case: an internet offer sent to
// a computer, which has no camera and — until the code could be found over the
// internet — no digits that worked for it. The code is found over the internet
// now, so the link, the screen that opened it, the route to that screen, the
// plugin that listened for it and the scheme the operating systems were told
// to hand to this app are all gone.
//
// This is a source check, and a blunt one: the names below are the pieces of
// that path. If one comes back, so has the way in, and whoever brings it back
// should read this comment first.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Matched as plain text in every `.dart` file under `lib/`.
const _gone = <String>[
  'directdrop://',
  'deep_link_service',
  'DeepLinkService',
  'deep_link',
  'ShareLinkContents',
  'buildPayloadLink',
  'parseShareLink',
  '/receive/link',
  'link_receive_page',
  'LinkReceivePage',
  'app_links',
  'AppLinks',
  'deepLinkScheme',
  'deepLinkHost',
  'qrDisplayShareLink',
  'linkReceiveOpening',
];

/// The bytes read as Latin-1, which cannot fail: a resource file may be in any
/// encoding, and every pattern looked for here is plain ASCII.
String _read(File file) => latin1.decode(file.readAsBytesSync());

Iterable<File> _files(String root, bool Function(String path) wanted) sync* {
  final dir = Directory(root);
  if (!dir.existsSync()) return;
  for (final f in dir.listSync(recursive: true, followLinks: false)) {
    if (f is File && wanted(f.path)) yield f;
  }
}

void main() {
  test('the sources under lib/ carry no piece of the link path', () {
    final dart = _files('lib', (p) => p.endsWith('.dart')).toList();
    expect(dart, isNotEmpty, reason: 'found no sources — the scan broke');

    final hits = <String>[];
    for (final file in dart) {
      final text = _read(file);
      for (final name in _gone) {
        if (text.contains(name)) hits.add('${file.path}: $name');
      }
    }
    expect(hits, isEmpty, reason: 'the link path is back:\n${hits.join('\n')}');
  });

  test('the files that carried it are gone', () {
    expect(File('lib/core/deep_link/deep_link_service.dart').existsSync(), isFalse);
    expect(Directory('lib/core/deep_link').existsSync(), isFalse);
    expect(
        File('lib/features/receiver/presentation/pages/link_receive_page.dart')
            .existsSync(),
        isFalse);
  });

  test('the translations carry nothing about opening or sharing a link', () {
    for (final arb in ['lib/l10n/app_en.arb', 'lib/l10n/app_ru.arb']) {
      final text = _read(File(arb));
      for (final key in ['linkReceive', 'qrDisplayShareLink', 'qrDisplayLinkCopied']) {
        expect(text.contains('"$key'), isFalse, reason: '$arb has $key');
      }
    }
  });

  test('no sender screen offers to copy or share a link', () {
    for (final file in _files('lib/features/sender/presentation',
        (p) => p.endsWith('.dart'))) {
      final text = _read(file);
      expect(text.contains('Icons.link'), isFalse, reason: file.path);
      expect(text.contains('Share.share'), isFalse, reason: file.path);
    }
  });

  group('the app asks no operating system for a scheme', () {
    test('the dependency that listened for it is not one', () {
      expect(_read(File('pubspec.yaml')).contains('app_links'),
          isFalse);
      expect(_read(File('pubspec.lock')).contains('app_links'),
          isFalse);
    });

    test('Android declares no intent filter for it', () {
      final manifest =
          _read(File('android/app/src/main/AndroidManifest.xml'));
      expect(manifest.contains('directdrop'), isFalse);
      expect(manifest.contains('BROWSABLE'), isFalse,
          reason: 'nothing outside the app opens it');
    });

    test('iOS and macOS declare no URL type', () {
      for (final plist in ['ios/Runner/Info.plist', 'macos/Runner/Info.plist']) {
        final text = _read(File(plist));
        expect(text.contains('CFBundleURLTypes'), isFalse, reason: plist);
        expect(text.contains('CFBundleURLSchemes'), isFalse, reason: plist);
        expect(text.contains('<string>directdrop</string>'), isFalse,
            reason: plist);
      }
    });

    test('Windows and Linux register no handler for it', () {
      for (final file in [
        ..._files('windows', (p) => p.endsWith('.rc') || p.endsWith('.cpp')),
        ..._files('packaging', (p) => true),
        ..._files('linux', (p) => p.endsWith('.desktop') || p.endsWith('.cc')),
      ]) {
        final text = _read(file);
        expect(text.contains('URL Protocol'), isFalse, reason: file.path);
        expect(text.contains('x-scheme-handler'), isFalse, reason: file.path);
        expect(text.contains('directdrop://'), isFalse, reason: file.path);
      }
    });

    test('no generated plugin registrant mentions the plugin', () {
      for (final path in [
        'macos/Flutter/GeneratedPluginRegistrant.swift',
        'windows/flutter/generated_plugin_registrant.cc',
        'windows/flutter/generated_plugins.cmake',
        'linux/flutter/generated_plugin_registrant.cc',
        'linux/flutter/generated_plugins.cmake',
      ]) {
        final file = File(path);
        if (!file.existsSync()) continue;
        expect(_read(file).contains('app_links'), isFalse,
            reason: path);
      }
    });
  });
}
