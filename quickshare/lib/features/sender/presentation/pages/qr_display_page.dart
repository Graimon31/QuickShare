import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/deep_link/deep_link_service.dart';
import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/features/sender/domain/transports/transfer_transport.dart';
import 'package:quickshare/features/sender/presentation/bloc/sender_bloc.dart';
import 'package:quickshare/shared/widgets/transfer_phase_loader.dart';

class QRDisplayPage extends StatefulWidget {
  const QRDisplayPage({super.key});

  @override
  State<QRDisplayPage> createState() => _QRDisplayPageState();
}

class _QRDisplayPageState extends State<QRDisplayPage> {
  late Timer _timer;
  int _secondsLeft = AppConstants.sessionTimeoutSeconds;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_secondsLeft > 0) {
        setState(() => _secondsLeft--);
      } else {
        _timer.cancel();
        context.read<SenderBloc>().add(CancelSending());
      }
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  String _formatTime(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  void _copyToClipboard(String text, String message) {
    Clipboard.setData(ClipboardData(text: text));
    HapticFeedback.mediumImpact();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppColors.secondaryDark,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Widget _copyRow({
    required IconData icon,
    required String label,
    required String value,
    required String copiedMessage,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: const Color.fromRGBO(255, 255, 255, 0.08),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: const Color.fromRGBO(255, 255, 255, 0.25),
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Icon(icon, color: AppColors.primary, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        color: Colors.white.withValues(alpha: 0.55),
                      ),
                    ),
                    const SizedBox(height: 2),
                    SelectableText(
                      value,
                      maxLines: 3,
                      style: GoogleFonts.firaCode(
                        fontSize: 13,
                        color: Colors.white.withValues(alpha: 0.9),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.copy_rounded,
                    color: Colors.white, size: 20),
                onPressed: () => _copyToClipboard(value, copiedMessage),
                tooltip: 'Copy',
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          context.read<SenderBloc>().add(CancelSending());
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.voidBg,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: Text(
            'Share File',
            style: GoogleFonts.inter(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () {
              context.read<SenderBloc>().add(CancelSending());
              context.go('/send');
            },
          ),
        ),
        body: BlocConsumer<SenderBloc, SenderState>(
          listener: (context, state) {
            if (state is Transferring) {
              context.go('/send/progress');
            } else if (state is SenderInitial) {
              context.go('/send');
            }
          },
          builder: (context, state) {
            if (state is! QRReady) {
              return const Center(
                child: TransferPhaseLoader(
                  phaseLabel: 'Preparing share…',
                  detail: 'Generating a secure QR session',
                  icon: Icons.qr_code_2_rounded,
                ),
              );
            }

            final isInternet = state.mode == TransportType.internet;
            final showShareLink = defaultTargetPlatform == TargetPlatform.macOS ||
                defaultTargetPlatform == TargetPlatform.windows ||
                defaultTargetPlatform == TargetPlatform.linux;
            final shareLink = showShareLink
                ? DeepLinkService.buildPayloadLink(
                    state.qrData,
                    name: state.session.fileMetadata.name,
                    bytes: state.totalBytes > 0
                        ? state.totalBytes
                        : state.session.fileMetadata.size,
                    itemCount: state.itemCount,
                  )
                : null;

            return ScrollConfiguration(
              behavior:
                  ScrollConfiguration.of(context).copyWith(scrollbars: false),
              child: SingleChildScrollView(
                clipBehavior: Clip.none,
                padding: const EdgeInsets.symmetric(
                    horizontal: 24.0, vertical: 24.0),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // Subtitle instruction
                        Text(
                          showShareLink
                              ? 'Scan the QR or share the link'
                              : (isInternet
                                  ? 'Share this link to receive the file'
                                  : 'Scan this QR code to receive the file'),
                          textAlign: TextAlign.center,
                          style: GoogleFonts.inter(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ).animate().fadeIn(),

                        if (!isInternet) ...[
                          const SizedBox(height: 6),
                          Text(
                            'On the phone: open QuickShare → Receive and scan this QR.\n'
                            'The Wi‑Fi line below is only for diagnostics — it is NOT the QR content.',
                            textAlign: TextAlign.center,
                            style: GoogleFonts.inter(
                              fontSize: 13,
                              color: Colors.white.withValues(alpha: 0.70),
                            ),
                          ).animate().fadeIn(),
                        ],

                        const SizedBox(height: 24),

                        // Glassmorphic Card Container for QR Code
                        Hero(
                          tag: 'qr-hero',
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(24),
                            child: BackdropFilter(
                              filter:
                                  ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                              child: Container(
                                padding: const EdgeInsets.all(20.0),
                                decoration: BoxDecoration(
                                  color: const Color.fromRGBO(
                                      255, 255, 255, 0.10),
                                  borderRadius: BorderRadius.circular(24),
                                  border: Border.all(
                                    color: const Color.fromRGBO(
                                        255, 255, 255, 0.35),
                                    width: 1.5,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.35),
                                      blurRadius: 28,
                                      offset: const Offset(0, 8),
                                    ),
                                  ],
                                ),
                                child: Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: QrImageView(
                                    data: state.qrData,
                                    version: QrVersions.auto,
                                    size: 260.0,
                                    backgroundColor: Colors.white,
                                    errorCorrectionLevel: QrErrorCorrectLevel.L,
                                    errorStateBuilder: (ctx, err) {
                                      return SizedBox(
                                        width: 240,
                                        height: 240,
                                        child: Center(
                                          child: Text(
                                            'QR Render Error: $err',
                                            style: const TextStyle(color: Colors.red, fontSize: 12),
                                            textAlign: TextAlign.center,
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ).animate().scale(delay: 150.ms, duration: 350.ms),

                        if (shareLink != null) ...[
                          const SizedBox(height: 20),
                          _copyRow(
                            icon: Icons.link,
                            label: 'Share link',
                            value: shareLink,
                            copiedMessage: 'Link copied to clipboard',
                          ).animate().fadeIn(delay: 250.ms),
                        ],

                        if (!isInternet) ...[
                          const SizedBox(height: 12),
                          _copyRow(
                            icon: Icons.wifi_tethering_rounded,
                            label: 'Sender Wi‑Fi address',
                            value:
                                '${state.session.localIp}:${state.session.serverPort}',
                            copiedMessage: 'Wi‑Fi address copied',
                          ).animate().fadeIn(delay: 280.ms),
                        ],

                        const SizedBox(height: 20),

                        // File info & Folder Size & Timeout countdown
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                          decoration: BoxDecoration(
                            color: const Color.fromRGBO(255, 255, 255, 0.06),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            children: [
                              Text(
                                state.itemCount > 1
                                    ? '${state.itemCount} files'
                                    : state.session.fileMetadata.name,
                                style: GoogleFonts.inter(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Total size: ${_formatBytes(state.totalBytes > 0 ? state.totalBytes : state.session.fileMetadata.size)}',
                                style: GoogleFonts.inter(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.primary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),

                        Text(
                          'Session expires in ${_formatTime(_secondsLeft)}',
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppColors.error,
                          ),
                        ),

                        const SizedBox(height: 24),

                        // Cancel Transfer Button
                        OutlinedButton.icon(
                          onPressed: () {
                            context.read<SenderBloc>().add(CancelSending());
                            context.go('/send');
                          },
                          icon: const Icon(Icons.close,
                              size: 18, color: AppColors.error),
                          label: Text(
                            'Cancel Transfer',
                            style: GoogleFonts.inter(
                              color: AppColors.error,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(
                                color: AppColors.error, width: 1.2),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 24, vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(24),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
  }
}
