// No file crosses Bluetooth, so no code receives one.
//
// Since protocol generation 4 the radio finds the other device and settles
// which of them raises a Wi-Fi network; the bytes cross that network over
// QHTP. The owner's decision is that a file does not travel over plain
// Bluetooth at all. What was left of the old road was worse than unused: a
// receiver wrote whatever arrived on a notification straight into a partial
// file and renamed it, with none of QHTP's length or digest checks, and the
// Apple senders carried a pump that nothing could reach.
//
// This is a source check, blunt on purpose: the names below are pieces of that
// road. If one comes back, so has the road.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Iterable<File> _files(String root, bool Function(String path) wanted) sync* {
  final dir = Directory(root);
  if (!dir.existsSync()) return;
  for (final f in dir.listSync(recursive: true, followLinks: false)) {
    if (f is File && wanted(f.path)) yield f;
  }
}

/// The names of the pieces, Dart side, wherever they are.
const _dartEverywhere = <String>[
  'handleDataForTesting',
  'handleMetadataForTesting',
  'sealCurrentFileForTesting',
  // The Apple roles that only the removed list used.
  'senderAsCentral',
  'forReceivers',
  'asSender',
];

/// The ones that are only the byte road inside the Bluetooth files — the WebRTC
/// receiver has a `_sealCurrentFile` and a gzip decoder of its own, and the
/// progress page has a `senderProgress` that is nothing to do with a radio.
const _dartInBluetoothFiles = <String>[
  // The receiver writing notification payloads into files.
  'UniversalBleReceiveProgress',
  'BluetoothReceiveProgress',
  '_sealCurrentFile',
  '_handleData',
  'GZipDecoder',
  // The sender's report of bytes it pushed, and the receiver's of bytes it got.
  'senderProgress',
  'senderCompleted',
  'receiverProgress',
  'receiverCompleted',
  'metadataReceived',
];

/// A file of the Bluetooth transports: `bluetooth_*.dart`, `*_bluetooth_*`,
/// `universal_ble_*`, `ble_*`. By its own name, so a path with `\` in it (CI
/// runs this on Windows too) reads the same.
bool _isBluetoothFile(String path) {
  final name = p.basename(path);
  return RegExp(r'(^|_)(bluetooth|ble)(_|\.)').hasMatch(name);
}

/// The same, Swift side.
const _swiftRemoved = <String>[
  'pumpSendQueue',
  'openCurrentSendItem',
  'sendFileHandle',
  'sendItemBytesSent',
  'pendingMetadataJSON',
  'receiveFileHandle',
  'sealCurrentReceiveFile',
  'resolveReceivePath',
  'senderProgress',
  'senderCompleted',
  'receiverProgress',
  'receiverCompleted',
  'metadataReceived',
  'senderAsCentral',
  'scanningForReceivers',
  'forReceivers',
  'asSender',
];

void main() {
  test('the Dart sources carry no piece of the byte road', () {
    final dart = _files('lib', (p) => p.endsWith('.dart')).toList();
    expect(dart, isNotEmpty, reason: 'found no sources — the scan broke');

    final hits = <String>[];
    for (final file in dart) {
      if (p.split(file.path).contains('gen')) continue;
      final text = file.readAsStringSync();
      for (final name in _dartEverywhere) {
        if (text.contains(name)) hits.add('${file.path}: $name');
      }
      if (!_isBluetoothFile(file.path)) continue;
      for (final name in _dartInBluetoothFiles) {
        if (text.contains(name)) hits.add('${file.path}: $name');
      }
    }
    expect(hits, isEmpty, reason: 'the byte road is back:\n${hits.join('\n')}');
  });

  test('the Swift bridges carry no piece of it either', () {
    final swift = [
      ..._files('ios/Runner', (p) => p.endsWith('.swift')),
      ..._files('macos/Runner', (p) => p.endsWith('.swift')),
    ];
    expect(swift, isNotEmpty, reason: 'found no Swift sources — the scan broke');

    final hits = <String>[];
    for (final file in swift) {
      final text = file.readAsStringSync();
      for (final name in _swiftRemoved) {
        if (text.contains(name)) hits.add('${file.path}: $name');
      }
    }
    expect(hits, isEmpty, reason: 'the byte road is back:\n${hits.join('\n')}');
  });

  test('the Bluetooth receiver touches no file', () {
    // A receiver that rendezvouses writes nothing: the files arrive through
    // QHTP, which has its own checks. If this one imports the file system, it
    // has started to write again.
    final text = File(
            'lib/features/receiver/data/transports/universal_ble_receiver_transport.dart')
        .readAsStringSync();
    for (final import in const [
      'dart:io',
      'package:archive/',
      'package:path_provider/',
      'core/storage/',
    ]) {
      expect(text, isNot(contains("'$import")), reason: import);
    }
  });

  test('no transport method takes a destination directory any more', () {
    // `targetDir` was where notification bytes landed.
    final hits = <String>[];
    for (final name in const [
      'bluetooth_receiver_transport.dart',
      'universal_ble_receiver_transport.dart',
    ]) {
      final path = 'lib/features/receiver/data/transports/$name';
      if (File(path).readAsStringSync().contains('targetDir')) hits.add(path);
    }
    expect(hits, isEmpty, reason: hits.join('\n'));
  });
}
