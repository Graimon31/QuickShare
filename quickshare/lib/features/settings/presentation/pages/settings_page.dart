import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:flutter/services.dart';

import 'package:quickshare/core/diagnostics/transfer_report.dart';
import 'package:quickshare/core/storage/transfer_cache.dart';
import 'package:quickshare/core/theme/app_colors.dart';

/// Settings, currently one thing: what the app is holding on disk.
class SettingsPage extends StatefulWidget {
  final TransferCache cache;
  final TransferDiagnostics diagnostics;

  const SettingsPage({
    super.key,
    this.cache = const TransferCache(),
    this.diagnostics = const TransferDiagnostics(),
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int? _cacheBytes;
  bool _clearing = false;
  List<TransferReport> _transfers = const [];

  @override
  void initState() {
    super.initState();
    _measure();
    _loadTransfers();
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

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surfaceDark,
        title: const Text('Clear cache?'),
        content: const Text(
          'Anything received but not yet saved will be deleted. Files you '
          'already saved to this device are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
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
          ? 'Freed ${TransferCache.formatBytes(freed)}'
          : 'Nothing to clear'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.voidBg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Settings'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.canPop() ? context.pop() : context.go('/'),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _sectionTitle('Storage'),
            Container(
              decoration: BoxDecoration(
                color: AppColors.glassFill,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.glassBorder),
              ),
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.folder_outlined,
                        color: AppColors.primary),
                    title: const Text('Cache',
                        style: TextStyle(color: AppColors.textPrimary)),
                    subtitle: Text(
                      _cacheBytes == null
                          ? 'Measuring…'
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
                            onPressed:
                                (_cacheBytes ?? 0) > 0 ? _clear : null,
                            child: const Text('Clear'),
                          ),
                  ),
                  const Divider(height: 1, color: AppColors.glassBorder),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 12, 16, 16),
                    child: Text(
                      'Incoming transfers are held here until you save them. '
                      'Anything you do not save is removed automatically when '
                      'you leave the transfer.',
                      style: TextStyle(
                          color: AppColors.textSecondary, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            if (_transfers.isNotEmpty) ...[
              const SizedBox(height: 24),
              _sectionTitle('Last transfers'),
              _transferCard(),
            ],
          ],
        ),
      ),
    );
  }

  /// What the recent transfers actually did.
  ///
  /// The route is the point. A relayed internet session and a direct one look
  /// identical behind a progress ring and differ by an order of magnitude, and
  /// until now the only way to tell them apart was to open a log file on the
  /// machine that did the sending — which, when that machine belongs to
  /// somebody else in another city, means it may as well not exist.
  Widget _transferCard() => Container(
        decoration: BoxDecoration(
          color: AppColors.glassFill,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.glassBorder),
        ),
        child: Column(
          children: [
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
                  tooltip: 'Copy details',
                  icon: const Icon(Icons.copy_rounded,
                      color: AppColors.textSecondary, size: 18),
                  onPressed: () => _copy(report),
                ),
              ),
              const Divider(height: 1, color: AppColors.glassBorder),
            ],
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Text(
                'The route explains the speed. A direct link is the fastest, '
                'a relayed internet transfer the slowest — copy the details if '
                'you are asking someone for help.',
                style:
                    TextStyle(color: AppColors.textSecondary, fontSize: 12),
              ),
            ),
          ],
        ),
      );

  Future<void> _copy(TransferReport report) async {
    await Clipboard.setData(ClipboardData(text: report.summary));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Details copied')),
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
