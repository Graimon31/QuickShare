import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/features/receiver/data/client/code_lookup.dart';
import 'package:quickshare/features/receiver/data/client/code_session_resolver.dart';
import 'package:quickshare/features/receiver/presentation/bloc/receiver_bloc.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';

/// Where a receiver types the ten digits a sender is showing.
///
/// Digits and nothing else. A computer has no camera to scan with and joins
/// only this way; a phone reaches the same screen from the scanner's "Enter
/// code". There is no field for a pasted link or a raw QR: the QR is scanned,
/// and a share link opens from outside the app (see `LinkReceivePage`).
class CodeReceivePage extends StatefulWidget {
  /// How the typed code is looked for. The real network search unless a test
  /// supplies its own.
  final CodeLookup? lookup;

  const CodeReceivePage({super.key, this.lookup});

  @override
  State<CodeReceivePage> createState() => _CodeReceivePageState();
}

class _CodeReceivePageState extends State<CodeReceivePage> {
  final _controller = TextEditingController();

  String? _inputError;
  bool _isSubmitting = false;

  final FocusNode _focusNode = FocusNode();

  late final CodeLookup _lookup = widget.lookup ?? CodeLookup();

  @override
  void dispose() {
    _focusNode.dispose();
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

    // Only a whole code starts anything. Half of one is not a search, and
    // searching is the one thing that puts this device on the network.
    final code = SessionCode.parse(_controller.text);
    if (code == null) {
      setState(() =>
          _inputError = AppLocalizations.of(context).codeReceiveCodeInvalid);
      return;
    }
    setState(() {
      _isSubmitting = true;
      _inputError = null;
    });
    await _startFromCode(code);
  }

  /// Finds the device offering [code] and starts collecting from it.
  ///
  /// The code never leaves this device. It is the password of a proof run
  /// against every device that might be the sender, bound to the TLS
  /// certificate each presents: a device that does not hold the code cannot
  /// answer in a way this side accepts, and until one does, nothing — not the
  /// code, not this device's name — has been sent to anyone. What an
  /// announcement says about itself (its hint, its fingerprint) only decides
  /// who is asked first; it is never what is trusted. See
  /// [CodeSessionResolver].
  Future<void> _startFromCode(SessionCode code) async {
    final l10n = AppLocalizations.of(context);

    final outcome = await _lookup.find(code);

    if (!mounted) return;

    switch (outcome) {
      case CodeSessionFound(:final payload):
        AppLogger.info(
          'Session code matched ${payload.senderName ?? 'a sender'} at '
          '${payload.ip}:${payload.port}',
          tag: 'CODE',
        );
        context
            .read<ReceiverBloc>()
            .add(QRCodeScanned(payload.encode(), fromPaste: true));
      case CodeSessionDeclined():
        _fail(l10n.inviteDeclined);
      case CodeSessionNotFound():
        AppLogger.warning(
          'No device proved it holds the session code',
          tag: 'CODE',
        );
        _fail(l10n.codeReceiveNotFoundLan);
      case CodeSessionUpdateRequired():
        _fail(l10n.codeReceiveUpdateRequired);
      case CodeSessionUnreachable():
        _fail(l10n.inviteUnreachable);
    }
  }

  void _fail(String message) {
    setState(() {
      _isSubmitting = false;
      _inputError = message;
    });
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
          l10n.codeReceivePrompt,
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
                focusNode: _focusNode,
                autofocus: true,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                // Digits, with the space or dash people put in the middle of
                // them. A pasted link has no digits to keep, so it leaves
                // nothing behind.
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9 \-]')),
                  LengthLimitingTextInputFormatter(14),
                ],
                onChanged: (_) {
                  if (_inputError != null) setState(() => _inputError = null);
                },
                style: GoogleFonts.firaCode(
                    color: Colors.white, fontSize: 22, letterSpacing: 2),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  hintText: l10n.codeReceiveHint,
                  hintStyle: GoogleFonts.firaCode(
                      color: Colors.white.withValues(alpha: 0.40),
                      fontSize: 22,
                      letterSpacing: 2),
                ),
                onSubmitted: (_) => _submit(),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          onPressed: _isSubmitting ? null : _submit,
          icon: _isSubmitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.download_rounded,
                  size: 18, color: Colors.white),
          label: Text(
              _isSubmitting
                  ? l10n.codeReceiveSearchingLan
                  : l10n.codeReceiveReceiveButton,
              style: GoogleFonts.inter(
                  color: Colors.white, fontWeight: FontWeight.w600)),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            elevation: 6,
          ),
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
