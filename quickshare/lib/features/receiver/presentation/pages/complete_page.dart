import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:open_file/open_file.dart';

import 'package:quickshare/core/storage/received_item.dart';
import 'package:quickshare/core/storage/save_coordinator.dart';
import 'package:quickshare/core/storage/save_destination.dart';
import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/shared/widgets/pressable_scale.dart';

/// What happened to a finished transfer, and — on a phone, for documents —
/// the one question the app ever asks.
///
/// The placement rule lives in [SaveDestination]; this screen only runs it and
/// shows the result. Photos and videos are already in the gallery by the time
/// it is drawn, and on desktop everything is already in Downloads.
class CompletePage extends StatefulWidget {
  final String fileName;
  final String filePath;

  /// Everything that arrived, still in the transfer cache.
  ///
  /// Empty for the transports not yet moved onto the cache (QHTP, Bluetooth),
  /// which write straight to their destination; the screen then just reports
  /// [filePath] as before.
  final List<ReceivedItem> items;

  final SaveCoordinator? coordinator;

  const CompletePage({
    super.key,
    required this.fileName,
    required this.filePath,
    this.items = const [],
    this.coordinator,
  });

  @override
  State<CompletePage> createState() => _CompletePageState();
}

class _CompletePageState extends State<CompletePage> {
  late final SaveCoordinator _coordinator = widget.coordinator ??
      SaveCoordinator(destination: SaveDestination.forCurrentPlatform());

  List<SaveOutcome> _outcomes = const [];
  bool _working = true;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _runAutomaticSave();
  }

  Future<void> _runAutomaticSave() async {
    if (widget.items.isEmpty) {
      setState(() => _working = false);
      return;
    }
    final outcomes = await _coordinator.runAutomatic(widget.items);
    if (mounted) {
      setState(() {
        _outcomes = outcomes;
        _working = false;
      });
    }
  }

  List<SaveOutcome> get _pending =>
      _outcomes.where((o) => o.awaitingDecision).toList();

  List<SaveOutcome> get _failures => _outcomes.where((o) => o.failed).toList();

  int get _savedCount => _outcomes.where((o) => o.item.isSaved).length;

  Future<void> _saveePending() async {
    final pending = _pending;
    if (pending.isEmpty) return;

    final directory = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Where should these go?',
    );
    if (directory == null || !mounted) return;

    setState(() => _working = true);
    final saved = await _coordinator.saveChosen(
        pending.map((o) => o.item).toList(), directory);
    if (!mounted) return;

    // Replace the pending entries with their outcomes, leave the rest alone.
    final byPath = {for (final o in saved) o.item.cachePath: o};
    setState(() {
      _outcomes = [
        for (final o in _outcomes) byPath[o.item.cachePath] ?? o,
      ];
      _working = false;
    });
  }

  /// Leaves, dropping anything the user chose not to keep.
  ///
  /// This is the "went back to the main menu without saving" case from the
  /// requirements: the cache is not a second copy of the user's files, it is
  /// a staging area, and staging that nobody claimed is deleted.
  Future<void> _leave(String route) async {
    if (_leaving) return;
    _leaving = true;
    if (_outcomes.isNotEmpty) {
      await _coordinator.discardUnsaved(_outcomes);
    }
    if (mounted) context.go(route);
  }

  @override
  Widget build(BuildContext context) {
    // Back gesture and system back count as leaving too.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave('/');
      },
      child: Scaffold(
        backgroundColor: AppColors.voidBg,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _failures.isNotEmpty
                          ? Icons.error_outline_rounded
                          : Icons.check_circle_rounded,
                      color: _failures.isNotEmpty
                          ? AppColors.warning
                          : AppColors.success,
                      size: 112,
                    )
                        .animate()
                        .scale(duration: 500.ms, curve: Curves.easeOutBack)
                        .fadeIn(),
                    const SizedBox(height: 24),
                    Text(
                      'Received!',
                      style: Theme.of(context)
                          .textTheme
                          .headlineMedium
                          ?.copyWith(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _statusLine(),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppColors.textSecondary),
                    ),
                    const SizedBox(height: 16),
                    _summaryCard(),
                    const SizedBox(height: 32),
                    ..._actions(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _statusLine() {
    if (_working) return 'Saving…';
    if (widget.items.isEmpty) return widget.fileName;

    final pending = _pending.length;
    final failed = _failures.length;
    final parts = <String>[];
    if (_savedCount > 0) parts.add('$_savedCount saved');
    if (pending > 0) parts.add('$pending waiting for you');
    if (failed > 0) parts.add('$failed could not be saved');
    return parts.isEmpty ? widget.fileName : parts.join(' · ');
  }

  Widget _summaryCard() {
    final items = widget.items.isEmpty
        ? [widget.fileName]
        : widget.items.map((i) => i.name).toList();
    final shown = items.take(4).toList();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.glassFill,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final name in shown)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  const Icon(Icons.insert_drive_file_outlined,
                      color: AppColors.primary, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppColors.textPrimary),
                    ),
                  ),
                ],
              ),
            ),
          if (items.length > shown.length)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('and ${items.length - shown.length} more',
                  style: const TextStyle(color: AppColors.textSecondary)),
            ),
          for (final failure in _failures)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('${failure.item.name}: ${failure.error}',
                  style: const TextStyle(
                      color: AppColors.warning, fontSize: 12)),
            ),
        ],
      ),
    ).animate().slideY(begin: 0.5, end: 0.0).fadeIn();
  }

  List<Widget> _actions() {
    if (_working) {
      return const [Center(child: CircularProgressIndicator())];
    }

    final pending = _pending;
    return [
      if (pending.isNotEmpty)
        _primaryButton(
          pending.length == 1
              ? 'Save to device'
              : 'Save ${pending.length} files to device',
          _saveePending,
        )
      else
        _primaryButton(
          'Open',
          () => OpenFile.open(
            _outcomes
                    .firstWhere(
                      (o) => o.item.isSaved && o.item.savedPath != 'gallery',
                      orElse: () => SaveOutcome(
                        item: ReceivedItem(
                          cachePath: widget.filePath,
                          name: widget.fileName,
                          size: 0,
                          mimeType: '',
                        ),
                      ),
                    )
                    .item
                    .savedPath ??
                widget.filePath,
          ),
        ),
      const SizedBox(height: 12),
      TextButton(
        onPressed: () => _leave('/receive'),
        child: const Text('Receive Another'),
      ),
      TextButton(
        onPressed: () => _leave('/'),
        child: Text(
          pending.isEmpty ? 'Done' : "Don't save",
          style: TextStyle(
              color: pending.isEmpty
                  ? AppColors.textSecondary
                  : AppColors.warning),
        ),
      ),
    ];
  }

  Widget _primaryButton(String label, VoidCallback onPressed) {
    return PressableScale(
      onPressed: onPressed,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          gradient: AppColors.primaryGradient,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Center(
          child: Text(label,
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 16)),
        ),
      ),
    );
  }
}
