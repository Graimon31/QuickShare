import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/features/receiver/presentation/bloc/receiver_bloc.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';

/// Shows the scanned session metadata (folder size, item count) before starting the transfer.
///
/// Reads [QRParsed] from [ReceiverBloc] so navigation never depends on go_router
/// `extra` (which is easy to lose and previously made the scan "do nothing").
class TransferPreviewPage extends StatefulWidget {
  const TransferPreviewPage({super.key});

  @override
  State<TransferPreviewPage> createState() => _TransferPreviewPageState();
}

class _TransferPreviewPageState extends State<TransferPreviewPage> {
  static const _previewDuration = Duration(milliseconds: 1200);
  Timer? _timer;
  bool _started = false;
  QRParsed? _parsed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = context.read<ReceiverBloc>().state;
      if (state is QRParsed) {
        setState(() => _parsed = state);
        _timer = Timer(_previewDuration, _startTransfer);
      } else {
        // No session in bloc — go back to scanner instead of crashing.
        context.go('/receive');
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startTransfer() {
    if (!mounted || _started) return;
    final parsed = _parsed;
    if (parsed == null) return;
    _started = true;
    _timer?.cancel();
    // Kick off download first so the next page always has an in-flight job.
    context.read<ReceiverBloc>().add(
          StartDownload(payload: parsed.payload),
        );
    context.go(
      '/receive/download',
      extra: {'payload': parsed.payload},
    );
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    return FileMetadata(
      name: '',
      path: '',
      size: bytes,
      mimeType: '',
    ).sizeFormatted;
  }

  @override
  Widget build(BuildContext context) {
    final parsed = _parsed;
    if (parsed == null) {
      return const Scaffold(
        backgroundColor: AppColors.voidBg,
        body: Center(
          child: CircularProgressIndicator(color: AppColors.primary),
        ),
      );
    }
    final payload = parsed.payload;
    final preview = parsed.qhtpPreview;
    final isQhtp = payload.isQhtp;
    final itemCount = preview?.itemCount ??
        (payload.itemCount > 0 ? payload.itemCount : (isQhtp ? 0 : 1));
    final totalBytes = isQhtp
        ? (preview?.totalBytes ?? payload.fileSize)
        : payload.fileSize;
    final title = isQhtp
        ? (payload.fileName.isNotEmpty
            ? payload.fileName
            : (itemCount > 0
                ? '$itemCount ${itemCount == 1 ? 'file' : 'files'}'
                : 'Folder Transfer'))
        : payload.fileName;

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: AppColors.voidBg,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 96,
                      height: 96,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: AppColors.primaryGradient,
                      ),
                      child: Icon(
                        isQhtp
                            ? Icons.folder_zip_rounded
                            : Icons.insert_drive_file_rounded,
                        color: Colors.white,
                        size: 48,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Ready to Receive',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        color: Colors.white.withOpacity(0.9),
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 12),
                      decoration: BoxDecoration(
                        color: const Color.fromRGBO(255, 255, 255, 0.08),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: const Color.fromRGBO(255, 255, 255, 0.2),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.data_usage_rounded,
                              color: AppColors.primary, size: 22),
                          const SizedBox(width: 10),
                          Text(
                            totalBytes > 0
                                ? 'Folder size: ${_formatBytes(totalBytes)}'
                                : 'Calculating size…',
                            style: GoogleFonts.inter(
                              color: AppColors.primary,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 32),
                    const LinearProgressIndicator(
                      minHeight: 4,
                      color: AppColors.primary,
                      backgroundColor: AppColors.glassFillStrong,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Starting file transfer…',
                      style: GoogleFonts.inter(
                        color: Colors.white.withOpacity(0.6),
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 28),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        OutlinedButton(
                          onPressed: () {
                            _timer?.cancel();
                            context.read<ReceiverBloc>().add(CancelDownload());
                            context.go('/');
                          },
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(
                                color: Color.fromRGBO(255, 255, 255, 0.3)),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 24, vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          child: Text(
                            'Cancel',
                            style: GoogleFonts.inter(color: Colors.white),
                          ),
                        ),
                        const SizedBox(width: 16),
                        ElevatedButton.icon(
                          onPressed: _startTransfer,
                          icon: const Icon(Icons.download_rounded, size: 18),
                          label: Text(
                            'Start Now',
                            style: GoogleFonts.inter(
                                fontWeight: FontWeight.w600),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 24, vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
