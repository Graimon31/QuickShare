import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:flutter/services.dart';

import 'package:quickshare/core/di/service_locator.dart';
import 'package:quickshare/core/diagnostics/transfer_report.dart';
import 'package:quickshare/core/localization/locale_controller.dart';
import 'package:quickshare/core/localization/locale_store.dart';
import 'package:quickshare/core/storage/save_destination.dart';
import 'package:quickshare/core/storage/save_location_store.dart';
import 'package:quickshare/core/storage/transfer_cache.dart';
import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';

/// Settings: what the app is holding on disk, where finished transfers go,
/// which language it speaks, and what its last few transfers actually did.
class SettingsPage extends StatefulWidget {
  final TransferCache cache;
  final TransferDiagnostics diagnostics;
  final SaveLocationStore saveLocation;
  final LocaleController? localeController;

  const SettingsPage({
    super.key,
    this.cache = const TransferCache(),
    this.diagnostics = const TransferDiagnostics(),
    this.saveLocation = const SaveLocationStore(),
    this.localeController,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int? _cacheBytes;
  bool _clearing = false;
  List<TransferReport> _transfers = const [];

  /// Only desktop platforms let an app write into a folder the user picked,
  /// outside its own sandbox. iOS and Android have no such folder to offer.
  final bool _isDesktop = SaveDestination.forCurrentPlatform().isDesktop;

  SaveLocation? _saveLocation;
  bool _loadingLocation = true;
  bool _changingLocation = false;

  late final LocaleController _localeController =
      widget.localeController ?? sl<LocaleController>();

  @override
  void initState() {
    super.initState();
    _measure();
    _loadTransfers();
    if (_isDesktop) _loadSaveLocation();
  }

  Future<void> _loadSaveLocation() async {
    final location = await widget.saveLocation.read();
    if (mounted) {
      setState(() {
        _saveLocation = location;
        _loadingLocation = false;
      });
    }
  }

  /// Opens the folder picker and, on a real choice, records it.
  ///
  /// On macOS the bookmark has to be created immediately after the picker
  /// returns — the sandbox's grant for the folder is transient, and anything
  /// that delays past this call risks it having already lapsed.
  Future<void> _changeLocation() async {
    if (_changingLocation) return;
    final l10n = AppLocalizations.of(context);
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: l10n.settingsSaveLocationPickerTitle,
    );
    if (path == null || !mounted) return;

    setState(() => _changingLocation = true);
    try {
      await widget.saveLocation.set(path);
      if (!mounted) return;
      setState(() => _saveLocation = SaveLocation(path: path));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.settingsSaveLocationError(e.toString()))),
      );
    } finally {
      if (mounted) setState(() => _changingLocation = false);
    }
  }

  Future<void> _useDefault() async {
    await widget.saveLocation.clear();
    if (mounted) setState(() => _saveLocation = null);
  }

  Future<void> _loadTransfers() async {
    final transfers = await widget.diagnostics.recent();
    if (mounted) setState(() => _transfers = transfers);
  }

  Future<void> _measure() async {
    final bytes = await widget.cache.size();
    if (mounted) setState(() => _cacheBytes = bytes);
  }

  Future<void> _clear() async {
    if (_clearing) return;
    final l10n = AppLocalizations.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surfaceDark,
        title: Text(l10n.settingsClearCacheTitle),
        content: Text(l10n.settingsClearCacheBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.commonClear),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _clearing = true);
    final freed = await widget.cache.clear();
    if (!mounted) return;

    setState(() {
      _clearing = false;
      _cacheBytes = 0;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      // The number is what distinguishes "cleared" from "did nothing".
      content: Text(freed > 0
          ? l10n.settingsCacheFreed(TransferCache.formatBytes(freed))
          : l10n.settingsCacheNothingToClear),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: AppColors.voidBg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(l10n.settingsTitle),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.canPop() ? context.pop() : context.go('/'),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _sectionTitle(l10n.settingsStorage),
            Container(
              decoration: BoxDecoration(
                color: AppColors.glassFill,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.glassBorder),
              ),
              child: Material(
                color: Colors.transparent,
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.folder_outlined,
                          color: AppColors.primary),
                      title: Text(l10n.settingsCache,
                          style: const TextStyle(color: AppColors.textPrimary)),
                      subtitle: Text(
                        _cacheBytes == null
                            ? l10n.settingsCacheMeasuring
                            : TransferCache.formatBytes(_cacheBytes!),
                        style: const TextStyle(color: AppColors.textSecondary),
                      ),
                      trailing: _clearing
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : TextButton(
                              onPressed: (_cacheBytes ?? 0) > 0 ? _clear : null,
                              child: Text(l10n.commonClear),
                            ),
                    ),
                    const Divider(height: 1, color: AppColors.glassBorder),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                      child: Text(
                        l10n.settingsCacheDescription,
                        style: const TextStyle(
                            color: AppColors.textSecondary, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_isDesktop) ...[
              const SizedBox(height: 24),
              _sectionTitle(l10n.settingsSaveLocation),
              _saveLocationCard(l10n),
            ],
            const SizedBox(height: 24),
            _sectionTitle(l10n.settingsLanguage),
            _languageCard(l10n),
            const SizedBox(height: 24),
            _sectionTitle(l10n.settingsLastTransfers),
            _transferCard(l10n),
            const SizedBox(height: 24),
            _sectionTitle(l10n.settingsLogs),
            _logsCard(l10n),
          ],
        ),
      ),
    );
  }

  /// The log file, one tap away.
  ///
  /// On a phone the file sits in the app's sandbox where nobody can reach it
  /// without a computer — and the phone is exactly where the interesting
  /// failures happen. This row opens an on-screen copy.
  Widget _logsCard(AppLocalizations l10n) => Container(
        decoration: BoxDecoration(
          color: AppColors.glassFill,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.glassBorder),
        ),
        child: Material(
          color: Colors.transparent,
          child: ListTile(
            leading: const Icon(Icons.article_outlined,
                color: AppColors.primary),
            title: Text(l10n.settingsLogs,
                style: const TextStyle(color: AppColors.textPrimary)),
            subtitle: Text(
              l10n.settingsLogsSubtitle,
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 12),
            ),
            trailing: const Icon(Icons.chevron_right_rounded,
                color: AppColors.textSecondary),
            onTap: () => context.push('/settings/logs'),
          ),
        ),
      );

  /// Where "automatic" saves land, and the one control to change it.
  ///
  /// The default stays whatever this platform already used — Downloads on
  /// macOS and Linux, the platform equivalent on Windows — so nothing here
  /// changes behaviour until a person deliberately picks a folder.
  Widget _saveLocationCard(AppLocalizations l10n) {
    final isCustom = _saveLocation != null;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.glassFill,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Material(
        color: Colors.transparent,
        child: Column(
          children: [
            ListTile(
              leading: Icon(
                isCustom
                    ? Icons.folder_special_outlined
                    : Icons.download_outlined,
                color: AppColors.primary,
              ),
              title: Text(
                isCustom
                    ? _saveLocation!.path
                    : l10n.settingsSaveLocationDefault,
                style: const TextStyle(color: AppColors.textPrimary),
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                _loadingLocation
                    ? l10n.settingsSaveLocationReading
                    : (isCustom
                        ? l10n.settingsSaveLocationCustomSubtitle
                        : l10n.settingsSaveLocationDefaultSubtitle),
                style: const TextStyle(color: AppColors.textSecondary),
              ),
              trailing: _changingLocation
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : TextButton(
                      onPressed: _loadingLocation ? null : _changeLocation,
                      child: Text(l10n.commonChange),
                    ),
            ),
            if (isCustom) ...[
              const Divider(height: 1, color: AppColors.glassBorder),
              ListTile(
                dense: true,
                title: Text(l10n.settingsSaveLocationUseDefault,
                    style: const TextStyle(
                        color: AppColors.warning, fontSize: 13)),
                onTap: _changingLocation ? null : _useDefault,
              ),
            ],
            const Divider(height: 1, color: AppColors.glassBorder),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Text(
                l10n.settingsSaveLocationFootnote,
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// English or Russian, picked here and applied everywhere in the app
  /// immediately — [LocaleController] is what makes that immediate part
  /// happen, since [MaterialApp] listens to it directly.
  ///
  /// Plain [ListTile]s with a checkmark rather than [RadioListTile]: nothing
  /// else on this screen uses Material's `Radio`, and `RadioListTile`'s own
  /// `groupValue`/`onChanged` are deprecated as of Flutter 3.32 in favour of
  /// a `RadioGroup` ancestor — a second widget just to manage two rows here.
  Widget _languageCard(AppLocalizations l10n) {
    return ValueListenableBuilder<Locale?>(
      valueListenable: _localeController,
      builder: (context, locale, _) {
        final current = locale == null
            ? _localeController.effective(Localizations.localeOf(context))
            : (AppLanguage.fromCode(locale.languageCode) ??
                AppLanguage.english);

        Widget languageTile(AppLanguage language, String label) => ListTile(
              title: Text(label,
                  style: const TextStyle(color: AppColors.textPrimary)),
              trailing: current == language
                  ? const Icon(Icons.check_rounded, color: AppColors.primary)
                  : null,
              onTap: () => _localeController.setLanguage(language),
            );

        return Container(
          decoration: BoxDecoration(
            color: AppColors.glassFill,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.glassBorder),
          ),
          child: Material(
            color: Colors.transparent,
            child: Column(
              children: [
                languageTile(AppLanguage.english, l10n.settingsLanguageEnglish),
                const Divider(
                    height: 1, color: AppColors.glassBorder, indent: 16),
                languageTile(AppLanguage.russian, l10n.settingsLanguageRussian),
                const Divider(height: 1, color: AppColors.glassBorder),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: Text(
                    l10n.settingsLanguageFootnote,
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// What the recent transfers actually did.
  ///
  /// The route is the point. A relayed internet session and a direct one look
  /// identical behind a progress ring and differ by an order of magnitude, and
  /// until now the only way to tell them apart was to open a log file on the
  /// machine that did the sending — which, when that machine belongs to
  /// somebody else in another city, means it may as well not exist.
  Widget _transferCard(AppLocalizations l10n) => Container(
        decoration: BoxDecoration(
          color: AppColors.glassFill,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.glassBorder),
        ),
        child: Material(
          color: Colors.transparent,
          child: Column(
            children: [
              // Shown even when there is nothing yet. Hiding the section made an
              // empty history indistinguishable from a build without the
              // feature, which is exactly the question somebody asked while
              // looking at this screen.
              if (_transfers.isEmpty)
                ListTile(
                  leading: const Icon(Icons.history_rounded,
                      color: AppColors.textSecondary),
                  title: Text(l10n.settingsNoTransfersYet,
                      style: const TextStyle(color: AppColors.textPrimary)),
                  subtitle: Text(
                    l10n.settingsNoTransfersYetSubtitle,
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 12),
                  ),
                ),
              for (final report in _transfers) ...[
                ListTile(
                  leading: Icon(
                    report.succeeded
                        ? Icons.check_circle_outline_rounded
                        : Icons.error_outline_rounded,
                    color: report.succeeded
                        ? AppColors.primary
                        : AppColors.warning,
                  ),
                  title: Text(
                    '${report.route} — '
                    '${TransferReport.formatRate(report.bytesPerSecond)}',
                    style: const TextStyle(color: AppColors.textPrimary),
                  ),
                  subtitle: Text(
                    report.succeeded
                        ? '${report.role} ${TransferReport.formatBytes(report.bytes)} '
                            'in ${report.took.inSeconds}s'
                        : report.failure,
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 12),
                  ),
                  trailing: IconButton(
                    tooltip: l10n.settingsCopyDetails,
                    icon: const Icon(Icons.copy_rounded,
                        color: AppColors.textSecondary, size: 18),
                    onPressed: () => _copy(report, l10n),
                  ),
                ),
                const Divider(height: 1, color: AppColors.glassBorder),
              ],
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Text(
                  l10n.settingsTransferFootnote,
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      );

  Future<void> _copy(TransferReport report, AppLocalizations l10n) async {
    await Clipboard.setData(ClipboardData(text: report.summary));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.settingsDetailsCopied)),
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 12,
            letterSpacing: 1.2,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
}
