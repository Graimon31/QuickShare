// Runtime overrides are for the standalone physical-device test entry point.
// Existing --dart-define values remain usable by ordinary integration runs.
import 'dart:convert';
import 'dart:io';

// devicectl launch environment variables do not reliably reach Dart on iOS.
// The controller can place this test-only JSON file in the app's private temp
// directory before launching. Read it once so all settings belong to one run.
final Map<String, String> _fileConfig = _readFileConfig();

Map<String, String> _readFileConfig() {
  final file =
      File('${Directory.systemTemp.path}/directdrop-physical-config.json');
  if (!file.existsSync()) return const {};
  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map ||
      decoded.keys.any((key) => key is! String) ||
      decoded.values.any((value) => value is! String)) {
    throw const FormatException(
        'Physical test config must contain string keys and values');
  }
  return Map<String, String>.from(decoded);
}

String? _runtime(String name) =>
    Platform.environment['DIRECTDROP_TEST_$name'] ?? _fileConfig[name];

String physicalString(String name, String fallback) =>
    _runtime(name) ?? fallback;

int physicalInt(String name, int fallback) {
  final value = _runtime(name);
  return value == null ? fallback : int.parse(value);
}

bool physicalBool(String name, bool fallback) {
  final value = _runtime(name);
  if (value == null) return fallback;
  if (value == 'true') return true;
  if (value == 'false') return false;
  throw FormatException('Physical test config $name must be true or false');
}
