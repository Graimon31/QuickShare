import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'package:quickshare/core/localization/locale_store.dart';

/// The app's current interface language, and the one place that changes it.
///
/// A `ValueNotifier<Locale?>` rather than an `AppLanguage?`: `MaterialApp`'s
/// own `locale` parameter wants exactly this type, and null already means
/// what it needs to mean here too — "follow the system", which
/// `AppLocalizations`'s generated delegate resolves on its own faithfully.
///
/// [MaterialApp.router] listens to this directly, so setting [language]
/// swaps the whole interface immediately — nobody has to restart the app to
/// see the language they just picked in Settings.
class LocaleController extends ValueNotifier<Locale?> {
  final LocaleStore _store;

  LocaleController({LocaleStore store = const LocaleStore()})
      : _store = store,
        super(null) {
    unawaited(_load());
  }

  Future<void> _load() async {
    final language = await _store.read();
    value = language == null ? null : Locale(language.code);
  }

  /// The language actually driving the UI right now, resolved from the
  /// system when nothing has been chosen. Read by Settings so its picker can
  /// highlight the right option without duplicating the resolution logic
  /// `MaterialApp` already does.
  AppLanguage effective(Locale systemLocale) {
    final chosen = value;
    if (chosen != null) return AppLanguage.fromCode(chosen.languageCode)!;
    return AppLanguage.fromCode(systemLocale.languageCode) ??
        AppLanguage.english;
  }

  Future<void> setLanguage(AppLanguage? language) async {
    if (language == null) {
      await _store.clear();
      value = null;
    } else {
      await _store.set(language);
      value = Locale(language.code);
    }
  }
}
