// The CoreBluetooth callbacks need hardware, but the wire command validation
// is pure Swift. Compile both actual bridge implementations and exercise the
// byte limit; check the callback wiring separately below.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String region(String source, String begin, String end) {
  final start = source.indexOf(begin);
  expect(start, greaterThanOrEqualTo(0), reason: begin);
  final finish = source.indexOf(end, start + begin.length);
  expect(finish, greaterThan(start), reason: end);
  return source.substring(start, finish);
}

void main() {
  for (final platform in ['ios', 'macos']) {
    final path = '$platform/Runner/QuickShareBluetooth.swift';
    late String source;
    setUp(() => source = File(path).readAsStringSync());

    test('$platform validates pairing commands in compiled Swift', () async {
      final swiftAvailable = Platform.isMacOS &&
          (await Process.run('which', ['swiftc'])).exitCode == 0;
      if (!swiftAvailable) return;
      final helper = region(source, '// MARK: - BEGIN QuickSharePairingControl',
          '// MARK: - END QuickSharePairingControl');
      final dir = await Directory.systemTemp.createTemp('ble-pairing-');
      try {
        final file = File('${dir.path}/main.swift');
        await file.writeAsString('''
import Foundation
$helper
let cases: [(String, Bool)] = [
  ("PAIR:", true),
  ("PAIR:" + String(repeating: "a", count: 175), true),
  ("PAIR:" + String(repeating: "a", count: 176), false),
  ("PAIR:" + String(repeating: "é", count: 87) + "a", true),
  ("PAIR:" + String(repeating: "é", count: 88), false),
  ("pair:abc", false), ("START:abc", false)
]
for (value, expected) in cases {
  if QuickSharePairingControl.isValid(value) != expected { exit(1) }
}
''');
        final build =
            await Process.run('swiftc', [file.path, '-o', '${dir.path}/check']);
        expect(build.exitCode, 0, reason: '${build.stdout}\n${build.stderr}');
        final run = await Process.run('${dir.path}/check', []);
        expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('$platform assembles bounded control frames independently per peer',
        () async {
      final swiftAvailable = Platform.isMacOS &&
          (await Process.run('which', ['swiftc'])).exitCode == 0;
      if (!swiftAvailable) return;
      final frame = region(source, '// MARK: - BEGIN QuickShareBleFrame',
          '// MARK: - END QuickShareBleFrame');
      final validation = region(
          source,
          '// MARK: - BEGIN QuickSharePairingControl',
          '// MARK: - END QuickSharePairingControl');
      final assembler = region(source, 'private func pairingCommandPart(',
              'private func writeControl(')
          .replaceFirst('private func', 'func');
      final dir = await Directory.systemTemp.createTemp('ble-control-');
      try {
        final file = File('${dir.path}/main.swift');
        await file.writeAsString('''
import Foundation
$frame
$validation
class Harness {
  var pairingInput: [UUID: (assembler: QuickShareBleFrameAssembler, started: Date)] = [:]
  $assembler
}
let h = Harness()
let a = UUID(), b = UUID()
let messageA = "PAIR:" + String(repeating: "a", count: 90)
let messageB = "PAIR:" + String(repeating: "b", count: 90)
let pa = try QuickShareBleFrame.split(Data(messageA.utf8), frameId: 1, notificationBytes: 20)
let pb = try QuickShareBleFrame.split(Data(messageB.utf8), frameId: 2, notificationBytes: 20)
var actualA: String? = nil
var actualB: String? = nil
for index in 0..<pa.count {
  let x = h.pairingCommandPart(pa[index], from: a)
  let y = h.pairingCommandPart(pb[index], from: b)
  if !x.accepted || !y.accepted { exit(1) }
  actualA = x.command ?? actualA
  actualB = y.command ?? actualB
}
if actualA != messageA || actualB != messageB { exit(2) }
let bad = h.pairingCommandPart(Data([0xd1, 0, 1, 2, 1]), from: a)
if bad.accepted { exit(3) }
let over = try QuickShareBleFrame.split(Data(("PAIR:" + String(repeating: "x", count: 176)).utf8), frameId: 3, notificationBytes: 20)
var rejected = false
for part in over { if !h.pairingCommandPart(part, from: a).accepted { rejected = true } }
if !rejected { exit(4) }
let good = h.pairingCommandPart(try QuickShareBleFrame.split(Data("PAIR:ok".utf8), frameId: 4, notificationBytes: 20)[0], from: a)
if good.command != "PAIR:ok" { exit(5) }
''');
        final build =
            await Process.run('swiftc', [file.path, '-o', '${dir.path}/check']);
        expect(build.exitCode, 0, reason: '${build.stdout}\n${build.stderr}');
        final run = await Process.run('${dir.path}/check', []);
        expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('$platform pairs without START and disconnect preserves advertising',
        () {
      final ready = region(source, 'if pairingOnly {\n',
          'let writeType: CBCharacteristicWriteType');
      expect(ready, contains('pairingReadyEmitted = true'));
      expect(ready, contains('centralConnectTimeoutTimer?.invalidate()'));
      expect(ready, contains('"type": "pairingReady"'));
      expect(ready, contains('"deviceId": peripheral.identifier.uuidString'));
      expect(ready, contains('return'));
      expect(ready, isNot(contains('START:')));
      expect(ready, isNot(contains('.hello(')));
      expect(ready, isNot(contains('.capabilities(')));
      final disconnect = region(
          source,
          'private func disconnectPairing()',
          platform == 'ios'
              ? 'private func cancelTransfer()'
              : 'private func cancelAll()');
      for (final required in [
        'cancelPeripheralConnection',
        'targetPeripheral = nil',
        'discovered.removeAll()',
        'resetFrames()',
        'pairingOnly = false'
      ]) {
        expect(disconnect, contains(required));
      }
      expect(disconnect, isNot(contains('stopAdvertising')));
      expect(source,
          contains('guard peripheral === targetPeripheral else { return }'));
      final connect = region(source, 'private func connect(deviceId:',
          'private func finishPairingDisconnect(');
      expect(
          connect,
          contains(
              'disconnectingPairingPeers.contains(peripheral.identifier)'));
      expect(connect, contains('deferredReconnectId = deviceId'));
      expect(source,
          contains('if finishPairingDisconnect(peripheral) { return }'));
      expect(source, contains('if !pairingOnly,'));
      expect(source, contains('"type": "pairingFrame"'));
      expect(source,
          contains('"deviceId": targetPeripheral?.identifier.uuidString'));
    });

    test(
        '$platform routes bounded commands and targets every queued frame part',
        () {
      final dispatch = region(
          source, 'case "sendPairingCommand":', 'case "disconnectPairing":');
      expect(dispatch, contains('QuickSharePairingControl.isValid(command)'));
      expect(dispatch, contains('sendPairingCommand(command, result)'));
      final receive = region(
          source,
          'if let command, command.hasPrefix("PAIR:")',
          '// Always ahead of START');
      expect(receive, contains('QuickSharePairingControl.isValid(command)'));
      expect(receive, contains('.invalidAttributeValueLength'));
      expect(receive, contains('request.central.identifier.uuidString'));
      expect(receive, contains('"type": "pairingCommand"'));
      expect(receive, contains('continue'));
      expect(source, contains('OutgoingPart(data: part, peerId: peerId'));
      expect(source, contains('metadataCentrals[peerId]'));
      expect(source, contains('onSubscribedCentrals: recipients'));
      expect(source, contains('notificationBytes(peerId: peerId)'));
      expect(source, contains('maximumWriteValueLength(for: .withResponse)'));
      expect(source, contains('didWriteValueFor characteristic:'));
      expect(
          source, contains('QuickShareBleFrameAssembler(maxFrameBytes: 180)'));
      expect(source, contains('pairingInput[peer]'));
      expect(source, contains('pairingInput.removeValue(forKey: peer)'));
      expect(source, contains('dataCentrals.remove(central.identifier)'));
      expect(source, contains('dataCentrals.isEmpty && !'));
      expect(source, contains('"type": "pairingDisconnected"'));
    });
  }
}
