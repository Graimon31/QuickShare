// The Swift bridges cut and put back frames with the same rules as Dart.
//
// There is no iPhone or Mac in the test run, and the bridges can only be
// reached through CoreBluetooth. But the part that decides what a frame is —
// how it is cut for a limit, what an assembler accepts and what it refuses —
// is plain Swift in a delimited region of `QuickShareBluetooth.swift` that
// needs nothing but Foundation. This extracts that region, compiles it with the
// `swiftc` that ships with Xcode, and runs it on the same inputs as the Dart
// code: every case below is run by both, and the results must be identical.
//
// What it does not cover is everything that talks to CoreBluetooth: the
// `updateValue` that answers false and the `peripheralManagerIsReady` that
// follows, the central's `maximumUpdateValueLength`, the timers. Those are
// checked by `ble_advertisement_contract_test.dart` reading the source, and by
// the bridges building.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:quickshare/core/transfer/ble_frame.dart';

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _unhex(String hex) => Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16)
    ]);

/// Bytes that are not text and not all alike, so nothing is read as either.
Uint8List _frameOf(int size) =>
    Uint8List.fromList(List.generate(size, (i) => (i * 7 + 3) % 256));

String _region(String path) {
  final text = File(path).readAsStringSync();
  final from = text.indexOf('// MARK: - BEGIN QuickShareBleFrame');
  const endMark = '// MARK: - END QuickShareBleFrame';
  final to = text.indexOf(endMark) + endMark.length;
  expect(from, isNonNegative, reason: path);
  expect(to, greaterThan(from), reason: path);
  return text.substring(from, to);
}

const _harness = r'''
import Foundation

func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

func unhex(_ text: String) -> Data {
    var bytes: [UInt8] = []
    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        bytes.append(UInt8(text[index..<next], radix: 16)!)
        index = next
    }
    return Data(bytes)
}

let input = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let cases = try JSONSerialization.jsonObject(with: input) as! [[String: Any]]
var results: [[String: Any]] = []

for item in cases {
    let name = item["name"] as! String
    var events: [String] = []
    if item["kind"] as! String == "split" {
        let frame = unhex(item["frame"] as! String)
        do {
            let parts = try QuickShareBleFrame.split(
                frame, frameId: UInt8(item["id"] as! Int), notificationBytes: item["limit"] as! Int)
            events = parts.map(hex)
        } catch let error as QuickShareBleFrameError {
            events = ["!" + error.problem.rawValue]
        }
    } else {
        var assembler = QuickShareBleFrameAssembler()
        for step in item["steps"] as! [String] {
            if step == "expire" {
                if let fault = assembler.expire() {
                    events.append("!" + fault.problem.rawValue)
                } else {
                    events.append("none")
                }
                continue
            }
            if step == "reset" {
                assembler.reset()
                continue
            }
            do {
                switch try assembler.accept(unhex(step)) {
                case .need: break
                case .frame(let frame): events.append(hex(frame))
                }
            } catch let error as QuickShareBleFrameError {
                events.append("!" + error.problem.rawValue)
            }
        }
        events.append(assembler.isAssembling ? "assembling" : "idle")
    }
    results.append(["name": name, "events": events])
}

let output = try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys])
print(String(data: output, encoding: .utf8)!)
''';

/// What Dart does with the same steps, in the harness's words.
List<String> _dartAssemble(List<String> steps) {
  final events = <String>[];
  late BleFrameAssembler assembler;
  assembler = BleFrameAssembler(
    onFrame: (frame) => events.add(_hex(frame)),
    onFault: (fault) => events.add('!${fault.problem.name}'),
    timeout: const Duration(days: 1),
  );
  for (final step in steps) {
    if (step == 'expire') {
      final before = events.length;
      assembler.expire();
      if (events.length == before) events.add('none');
    } else if (step == 'reset') {
      assembler.reset();
    } else {
      assembler.add(_unhex(step));
    }
  }
  events.add(assembler.isAssembling ? 'assembling' : 'idle');
  assembler.dispose();
  return events;
}

List<String> _dartSplit(Uint8List frame, int id, int limit) {
  try {
    return [
      for (final part in BleFrameSplitter()
          .split(frame, notificationBytes: limit, frameId: id))
        _hex(part)
    ];
  } on BleFrameException catch (e) {
    return ['!${e.problem.name}'];
  }
}

/// Why this cannot run here, or null when it can: the Swift compiler comes
/// with Xcode, so only a Mac that has it can compile the bridges' code.
String? _whyNot() {
  if (!Platform.isMacOS) {
    return 'the Swift bridges are compiled on macOS only';
  }
  try {
    if (Process.runSync('which', ['swiftc']).exitCode != 0) {
      return 'swiftc is not installed (Xcode command line tools)';
    }
  } catch (_) {
    return 'swiftc cannot be looked for';
  }
  return null;
}

void main() {
  group('compiled and run', () {
    late List<Map<String, Object?>> cases;
    late Map<String, List<String>> expected;
    late Map<String, List<String>> actual;

    setUpAll(() {
      final cutter = BleFrameSplitter(firstId: 0);
      final part = <int, List<Uint8List>>{};
      List<Uint8List> parts(int size, int limit, int id) => part.putIfAbsent(
          size * 1000000 + limit * 1000 + id,
          () => cutter.split(_frameOf(size),
              notificationBytes: limit, frameId: id));

      cases = [];
      expected = {};

      void split(String name, int size, int id, int limit) {
        cases.add({
          'name': name,
          'kind': 'split',
          'frame': _hex(_frameOf(size)),
          'id': id,
          'limit': limit,
        });
        expected[name] = _dartSplit(_frameOf(size), id, limit);
      }

      void assemble(String name, List<String> steps) {
        cases.add({'name': name, 'kind': 'assemble', 'steps': steps});
        expected[name] = _dartAssemble(steps);
      }

      List<String> hexes(Iterable<Uint8List> ps) => [for (final p in ps) _hex(p)];

      // -- cutting ----------------------------------------------------------
      for (final limit in [5, 20, 182, 244, 512]) {
        for (final size in [0, 1, 15, 16, 17, 100, 203, 225, 1000, 3072, 3073]) {
          for (final id in [0, 7, 255]) {
            split('split $size @ $limit id $id', size, id, limit);
          }
        }
      }
      for (final limit in [-3, 0, 1, 4]) {
        split('split 50 @ $limit', 50, 1, limit);
      }
      split('split 300 @ 5 (too many parts)', 300, 1, 5);

      // -- putting together --------------------------------------------------
      for (final limit in [20, 182, 512]) {
        assemble('whole 203 @ $limit', hexes(parts(203, limit, 4)));
        assemble('whole 225 @ $limit', hexes(parts(225, limit, 5)));
        assemble('whole 3072 @ $limit', hexes(parts(3072, limit, 6)));
      }
      assemble('two frames in a row', [
        ...hexes(parts(203, 20, 1)),
        ...hexes(parts(225, 182, 2)),
        ...hexes(parts(81, 20, 2)),
      ]);

      final p = parts(100, 20, 9);
      final q = parts(100, 20, 10);
      assemble('part skipped', [_hex(p[0]), _hex(p[1]), ...hexes(p.skip(3))]);
      assemble('part repeated', [_hex(p[0]), _hex(p[1]), _hex(p[1]), _hex(p[2])]);
      assemble('first part twice', [_hex(p[0]), _hex(p[0])]);
      assemble('part with no beginning', [_hex(p[3])]);
      assemble('part after the end', [...hexes(p), _hex(p.last)]);
      assemble('part of another frame', [_hex(p[0]), _hex(p[1]), _hex(q[2])]);
      assemble('another frame begins', [_hex(p[0]), _hex(p[1]), _hex(q[0])]);
      final lying = Uint8List.fromList(p[1])..[3] = p.length + 1;
      assemble('count changes', [_hex(p[0]), _hex(lying)]);
      assemble('count zero', [_hex(Uint8List.fromList([0xD1, 1, 0, 0, 65]))]);
      assemble('index past count', [_hex(Uint8List.fromList([0xD1, 1, 3, 3, 65]))]);
      assemble('header only', [_hex(Uint8List.fromList([0xD1, 1, 0, 1]))]);
      assemble('empty notification', ['']);
      assemble('foreign notification', ['000102030405']);
      assemble('bare JSON', [_hex(Uint8List.fromList(utf8.encode('{"link":{}}')))]);
      assemble('bare JSON mid-frame',
          [_hex(p[0]), _hex(Uint8List.fromList(utf8.encode('{"x":1}')))]);
      assemble('too large', [
        for (var i = 0; i < 250; i++)
          _hex(Uint8List.fromList([0xD1, 5, i, 250, ...List.filled(16, 0x41)]))
      ]);
      assemble('nothing after a fault', [
        _hex(p[0]),
        _hex(p[2]),
        ...hexes(p.skip(3)),
        ...hexes(parts(50, 20, 11)),
      ]);
      assemble('reset takes the fault back', [
        _hex(p[0]),
        _hex(p[2]),
        'reset',
        ...hexes(parts(50, 20, 11)),
      ]);
      assemble('a frame still going', [_hex(p[0]), _hex(p[1])]);
      assemble('timeout', [_hex(p[0]), _hex(p[1]), 'expire']);
      assemble('timeout with nothing to time out', ['expire']);
      assemble('timeout after a whole frame', [...hexes(p), 'expire']);
      assemble('nothing after a timeout', [_hex(p[0]), 'expire', _hex(p[1])]);
    });

    test('Dart and Swift give the same answer to every case', () async {
      final dir = Directory.systemTemp.createTempSync('ble_frame_swift');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/region.swift').writeAsStringSync(
          'import Foundation\n\n'
          '${_region('macos/Runner/QuickShareBluetooth.swift')}\n');
      File('${dir.path}/main.swift').writeAsStringSync(_harness);
      File('${dir.path}/cases.json').writeAsStringSync(jsonEncode(cases));

      final compiled = await Process.run('swiftc', [
        '-O',
        '${dir.path}/region.swift',
        '${dir.path}/main.swift',
        '-o',
        '${dir.path}/harness',
      ]);
      expect(compiled.exitCode, 0,
          reason: 'the Swift region does not compile:\n${compiled.stderr}');

      final ran =
          await Process.run('${dir.path}/harness', ['${dir.path}/cases.json']);
      expect(ran.exitCode, 0, reason: '${ran.stderr}');
      final results = jsonDecode(ran.stdout as String) as List;
      actual = {
        for (final r in results)
          (r as Map)['name'] as String:
              [for (final e in r['events'] as List) e as String]
      };

      expect(actual.keys.toSet(), expected.keys.toSet());
      final differences = <String>[];
      for (final name in expected.keys) {
        if (jsonEncode(actual[name]) != jsonEncode(expected[name])) {
          differences.add('$name\n  Dart:  ${expected[name]}\n  Swift: ${actual[name]}');
        }
      }
      expect(differences, isEmpty,
          reason: '${differences.length} of ${expected.length} cases differ:\n'
              '${differences.take(5).join('\n')}');
      // ignore: avoid_print
      print('SWIFT_CONFORMANCE ${expected.length} cases, identical in Dart and Swift');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('and the cases are not all the same kind of nothing', () {
      // A comparison of two empty answers would pass for any pair of
      // implementations; the cases have to reach every outcome there is.
      final outcomes = {for (final e in expected.values) ...e};
      for (final wanted in [
        '!emptyFrame', '!frameTooLarge', '!notificationTooSmall',
        '!tooManyParts', '!unframed', '!notAFrame', '!tooShort', '!badHeader',
        '!orphanPart', '!interrupted', '!interleaved', '!duplicatePart',
        '!missingPart', '!countChanged', '!tooLarge', '!timedOut', 'none',
        'assembling', 'idle',
      ]) {
        expect(outcomes, contains(wanted), reason: 'no case reaches $wanted');
      }
      expect(expected['whole 225 @ 20']!.first.length, greaterThan(200),
          reason: 'a frame came out of the assembler');
    });
  }, skip: _whyNot());
}
