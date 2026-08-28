import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:quickshare/core/utils/app_logger.dart';

/// The two interfaces this app actually has translations for.
///
/// Not a raw `Locale` at rest: a string that survives a typo-free round trip
/// through JSON is worth more than validating one on every read.
enum AppLanguage {
  english('en'),
  russian('ru');

  final String code;
  const AppLanguage(this.code);

  static AppLanguage? fromCode(String? code) => switch (code) {
        'en' => AppLanguage.english,
        'ru' => AppLanguage.russian,
        _ => null,
      };
}

/// Persists the user's language choice.
///
/// Null — the default, nothing ever written — means "follow the system",
/// which [AppLocalizations]'s own delegate already resolves correctly on its
/// own. A file only appears here once someone has deliberately overridden
/// that, which is also why `read()` returning null is not an error case to
/// work around: it is the common one.
class LocaleStore {
  static const _fileName = 'language.json';

  final Directory Function()? _overrideDir;

  const LocaleStore({Directory Function()? overrideDir})
      : _overrideDir = overrideDir;

  Future<File> _file() async {
    final dir = _overrideDir?.call() ?? await getApplicationSupportDirectory();
    if (!await dir.exists()) await dir.create(recursive: true);
    return File(p.join(dir.path, _fileName));
  }

  Future<AppLanguage?> read() async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      return AppLanguage.fromCode((await file.readAsString()).trim());
    } catch (e) {
      AppLogger.warning('Could not read the language choice: $e', tag: 'I18N');
      return null;
    }
  }

  Future<void> set(AppLanguage language) async {
    final file = await _file();
    await file.writeAsString(language.code);
  }

  /// Reverts to following the system language.
  Future<void> clear() async {
    final file = await _file();
    if (await file.exists()) await file.delete();
  }
}
