import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/features/receiver/presentation/bloc/receiver_bloc.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';

class CodeReceivePage extends StatefulWidget {
  final String? initialCode;
  const CodeReceivePage({super.key, this.initialCode});

  @override
  State<CodeReceivePage> createState() => _CodeReceivePageState();
}

class _CodeReceivePageState extends State<CodeReceivePage> {
  final _controller = TextEditingController();
  String? _inputError;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    // initialCode: bare room, or full quickshare://join?room=&sig=
    if (widget.initialCode != null && widget.initialCode!.isNotEmpty) {
      _controller.text = widget.initialCode!;
      WidgetsBinding.instance.addPostFrameCallback((_) => _submit());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _reset() {
    setState(() {
      _controller.clear();
      _inputError = null;
      _isSubmitting = false;
    });
  }

  Future<void> _submit() async {
    if (_isSubmitting) return;
    final raw = _controller.text.trim();
    if (raw.isEmpty) {
      setState(() =>
          _inputError = AppLocalizations.of(context).codeReceivePasteError);
      return;
    }
    setState(() {
      _isSubmitting = true;
      _inputError = null;
    });

    try {
      if (!mounted) return;
      // The full pasted string so `n`/`s`/`c` preview fields survive; the
      // bloc routes it to QHTP or the serverless WebRTC path.
      context.read<ReceiverBloc>().add(QRCodeScanned(raw, fromPaste: true));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _inputError = AppLocalizations.of(context).codeReceiveParseError;
      });
    }
  }


  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: AppColors.voidBg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          l10n.codeReceiveTitle,
          style: GoogleFonts.inter(
              color: Colors.white, fontWeight: FontWeight.w600),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => context.go('/'),
        ),
      ),
      body: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 24.0),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 540),
              child: BlocConsumer<ReceiverBloc, ReceiverState>(
                listener: (context, state) {
                  if (state is QRParsed || state is ReceiverError) {
                    setState(() => _isSubmitting = false);
                  }
                  if (state is ReceiverError) {
                    setState(() => _inputError = state.message);
                  }
                },
                builder: (context, state) {
                  if (state is QRParsed) {
                    return _buildConfirm(context, l10n, state);
                  }
                  return _buildIdle(context, l10n);
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIdle(BuildContext context, AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.codeReceivePastePrompt,
          style: GoogleFonts.inter(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 14),
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: const Color.fromRGBO(255, 255, 255, 0.08),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: const Color.fromRGBO(255, 255, 255, 0.25),
                  width: 1,
                ),
              ),
              child: TextField(
                controller: _controller,
                autofocus: true,
                maxLines: 3,
                minLines: 1,
                style: GoogleFonts.firaCode(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  hintText: l10n.codeReceiveHint,
                  hintStyle: GoogleFonts.inter(
                      color: Colors.white.withValues(alpha: 0.40)),
                ),
                onSubmitted: (_) => _submit(),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () async {
                  final data = await Clipboard.getData(Clipboard.kTextPlain);
                  if (data?.text != null) {
                    setState(() => _controller.text = data!.text!);
                  }
                },
                icon: const Icon(Icons.paste_rounded,
                    size: 18, color: Colors.white),
                label: Text(l10n.codeReceivePasteButton,
                    style: GoogleFonts.inter(
                        color: Colors.white, fontWeight: FontWeight.w600)),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: const BorderSide(
                      color: Color.fromRGBO(255, 255, 255, 0.3)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _isSubmitting ? null : _submit,
                icon: const Icon(Icons.download_rounded,
                    size: 18, color: Colors.white),
                label: Text(l10n.codeReceiveReceiveButton,
                    style: GoogleFonts.inter(
                        color: Colors.white, fontWeight: FontWeight.w600)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  elevation: 6,
                ),
              ),
            ),
          ],
        ),
        if (_inputError != null) ...[
          const SizedBox(height: 16),
          Text(_inputError!,
              style: GoogleFonts.inter(color: AppColors.error, fontSize: 14)),
        ],
      ],
    );
  }

  Widget _buildConfirm(
      BuildContext context, AppLocalizations l10n, QRParsed state) {
    final payload = state.payload;
    final preview = state.qhtpPreview;
    final itemCount = preview?.itemCount ?? payload.itemCount;
    final sizeBytes = preview?.totalBytes ?? payload.fileSize;
    final isMany = itemCount > 1;
    final title = payload.fileName.isNotEmpty
        ? payload.fileName
        : (itemCount > 0
            ? l10n.sharedItemsCount(itemCount)
            : l10n.codeReceiveIncomingTransfer);
    final sizeBits = <String>[
      if (itemCount > 1) l10n.sharedItemsCount(itemCount),
      if (sizeBytes > 0)
        FileMetadata(name: '', path: '', size: sizeBytes, mimeType: '')
            .sizeFormatted,
    ];
    final sizeLabel = sizeBits.isNotEmpty
        ? sizeBits.join(' · ')
        : l10n.codeReceiveSizeUnknown;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.codeReceiveFileFound,
          style: GoogleFonts.inter(
              fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white),
        ),
        const SizedBox(height: 14),
        ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color.fromRGBO(255, 255, 255, 0.08),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.success, width: 1.5),
              ),
              child: Row(
                children: [
                  Icon(
                    isMany
                        // A folder now arrives as a folder, so it should not
                        // be announced with an archive icon.
                        ? Icons.folder_rounded
                        : Icons.insert_drive_file_rounded,
                    color: AppColors.success,
                    size: 38,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: GoogleFonts.inter(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Colors.white),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          sizeLabel,
                          style: GoogleFonts.inter(
                              fontSize: 14,
                              color: Colors.white.withValues(alpha: 0.70)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () {
                  context.read<ReceiverBloc>().add(CancelDownload());
                  _reset();
                },
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: const BorderSide(
                      color: Color.fromRGBO(255, 255, 255, 0.3)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
                child: Text(l10n.commonCancel,
                    style: GoogleFonts.inter(
                        color: Colors.white, fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton(
                onPressed: () {
                  if (_isSubmitting) return;
                  setState(() => _isSubmitting = true);
                  context.go(
                    '/receive/download',
                    extra: {'payload': state.payload},
                  );
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.secondaryDark,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  elevation: 6,
                ),
                child: Text(l10n.codeReceiveDownloadButton,
                    style: GoogleFonts.inter(
                        color: Colors.white, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ],
    );
  }

}
