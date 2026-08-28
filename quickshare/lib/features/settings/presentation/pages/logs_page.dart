import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';

/// The app's own log, on screen.
///
/// The log file itself sits in the app's documents directory, which on a
/// phone means "nowhere you can reach without a computer attached" — exactly
/// when the transfer failing is the phone's. Copying it from here turns
/// "describe what happened" into an artefact that can be pasted into a
/// message.
class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  String? _content;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final content = await AppLogger.getLogFileContent();
    if (mounted) setState(() => _content = content);
  }

  Future<void> _copyAll() async {
    final content = _content;
    if (content == null || content.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: content));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).settingsDetailsCopied)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: AppColors.voidBg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(l10n.settingsLogs),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.canPop() ? context.pop() : context.go('/'),
        ),
        actions: [
          IconButton(
            tooltip: l10n.logsCopyAll,
            icon: const Icon(Icons.copy_rounded),
            onPressed: (_content?.isNotEmpty ?? false) ? _copyAll : null,
          ),
        ],
      ),
      body: SafeArea(
        child: _content == null
            ? const Center(child: CircularProgressIndicator())
            : _content!.isEmpty
                ? Center(
                    child: Text(
                      l10n.logsEmpty,
                      style:
                          const TextStyle(color: AppColors.textSecondary),
                    ),
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: SelectableText(
                      _content!,
                      style: GoogleFonts.robotoMono(
                        color: AppColors.textSecondary,
                        fontSize: 11,
                        height: 1.4,
                      ),
                    ),
                  ),
      ),
    );
  }
}
