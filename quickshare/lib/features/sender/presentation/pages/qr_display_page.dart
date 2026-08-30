import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
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
import 'package:quickshare/l10n/gen/app_localizations.dart';
import 'package:quickshare/shared/widgets/copy_value_row.dart';
import 'package:quickshare/shared/widgets/session_expired_panel.dart';
import 'package:quickshare/shared/widgets/transfer_phase_loader.dart';

class QRDisplayPage extends StatefulWidget {
  const QRDisplayPage({super.key});

  @override
  State<QRDisplayPage> createState() => _QRDisplayPageState();
}

class _QRDisplayPageState extends State<QRDisplayPage> {
  Timer? _timer;
  int _secondsLeft = AppConstants.sessionTimeoutSeconds;
  bool _expired = false;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_secondsLeft > 0) {
        setState(() => _secondsLeft--);
      } else {
        _timer?.cancel();
        setState(() => _expired = true);
        // The QR is dead from this moment on; tear the session down so
        // nobody connects to something the countdown already killed.
        context.read<SenderBloc>().add(CancelSending());
      }
    });
  }

  void _refreshSession() {
    setState(() {
      _expired = false;
      _secondsLeft = AppConstants.sessionTimeoutSeconds;
    });
    _startTimer();
    context.read<SenderBloc>().add(RestartSession());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _formatTime(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
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
            l10n.qrDisplayTitle,
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
              // Expiry lands here too (the session is cancelled underneath),
              // but then the expired panel owns the screen.
              if (!_expired) context.go('/send');
            }
          },
          builder: (context, state) {
            if (_expired) {
              return SessionExpiredPanel(onRefresh: _refreshSession);
            }
            if (state is! QRReady) {
              return Center(
                child: TransferPhaseLoader(
                  phaseLabel: l10n.qrDisplayPreparing,
                  detail: l10n.qrDisplayPreparingDetail,
                  icon: Icons.qr_code_2_rounded,
                ),
              );
            }

            final isInternet = state.mode == TransportType.internet;
            // The Room Link goes everywhere: it is the one way to hand a
            // session over without a camera, so it is not platform-gated.
            final shareLink = DeepLinkService.buildPayloadLink(
              state.qrData,
              name: state.session.fileMetadata.name,
              bytes: state.totalBytes > 0
                  ? state.totalBytes
                  : state.session.fileMetadata.size,
              itemCount: state.itemCount,
            );

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
                          l10n.qrDisplayScanOrShare,
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
                            l10n.qrDisplayPhoneHint,
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
                              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                              child: Container(
                                padding: const EdgeInsets.all(20.0),
                                decoration: BoxDecoration(
                                  color:
                                      const Color.fromRGBO(255, 255, 255, 0.10),
                                  borderRadius: BorderRadius.circular(24),
                                  border: Border.all(
                                    color: const Color.fromRGBO(
                                        255, 255, 255, 0.35),
                                    width: 1.5,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color:
                                          Colors.black.withValues(alpha: 0.35),
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
                                            l10n.qrDisplayRenderError('$err'),
                                            style: const TextStyle(
                                                color: Colors.red,
                                                fontSize: 12),
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

                        const SizedBox(height: 20),
                        CopyValueRow(
                          icon: Icons.link,
                          label: l10n.qrDisplayShareLinkLabel,
                          value: shareLink,
                          copiedMessage: l10n.qrDisplayLinkCopied,
                          copyTooltip: l10n.commonCopy,
                        ).animate().fadeIn(delay: 250.ms),

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
                                // A folder by its own name; a pile of
                                // loose files by how many there are.
                                state.folderName ??
                                    (state.itemCount > 1
                                        ? l10n.sharedItemsCount(state.itemCount)
                                        : state.session.fileMetadata.name),
                                style: GoogleFonts.inter(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 4),
                              if (state.totalBytes > 0 ||
                                  state.session.fileMetadata.size > 0)
                                Text(
                                  l10n.qrDisplayTotalSize(_formatBytes(
                                      state.totalBytes > 0
                                          ? state.totalBytes
                                          : state.session.fileMetadata.size)),
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
                          l10n.qrDisplaySessionExpires(
                              _formatTime(_secondsLeft)),
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
                            l10n.qrDisplayCancelTransfer,
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
