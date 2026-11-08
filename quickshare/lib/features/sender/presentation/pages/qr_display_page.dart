import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:quickshare/core/router/send_routes.dart';
import 'package:quickshare/core/l10n/localized_labels.dart';
import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/features/sender/data/server/local_http_server.dart';
import 'package:quickshare/features/sender/presentation/bloc/sender_bloc.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';
import 'package:quickshare/features/sender/presentation/widgets/offer_lifecycle_guard.dart';
import 'package:quickshare/shared/widgets/copy_value_row.dart';
import 'package:quickshare/shared/widgets/offer_countdown.dart';
import 'package:quickshare/shared/widgets/transfer_phase_loader.dart';
import 'package:quickshare/core/utils/byte_format.dart';

class QRDisplayPage extends StatefulWidget {
  const QRDisplayPage({super.key});

  @override
  State<QRDisplayPage> createState() => _QRDisplayPageState();
}

class _QRDisplayPageState extends State<QRDisplayPage> {
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
      child: OfferLifecycleGuard(
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
              context.go(SendRoutes.home);
            },
          ),
        ),
        body: BlocConsumer<SenderBloc, SenderState>(
          listener: (context, state) {
            if (state is Transferring) {
              context.go('/send/progress');
            } else if (state is SenderInitial) {
              context.go(SendRoutes.home);
            } else if (state is InviteApprovalRequested) {
              _showApprovalDialog(context, state);
            } else if (state is SenderError) {
              // The one state this page never handled. Everything that is
              // not QRReady draws "Preparing share…", so a session that
              // died after the QR route was entered — an unreadable
              // selection, a server that dropped, a certificate that never
              // arrived — left a spinner turning for ever: no reason on
              // screen, no way forward, and indistinguishable from a walk
              // that was merely slow. Say what happened and go back to the
              // screen the session can be started from again, which is what
              // the Bluetooth page has always done.
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(
                  localizedFailure(AppLocalizations.of(context),
                      code: state.code, fallback: state.message),
                  style: const TextStyle(color: Colors.white),
                ),
                behavior: SnackBarBehavior.floating,
              ));
              context.go(SendRoutes.home);
            }
          },
          builder: (context, state) {
            final qrState = state is InviteApprovalRequested
                ? state.previousState
                : (state is QRReady ? state : null);
            if (qrState == null) {
              return Center(
                child: TransferPhaseLoader(
                  phaseLabel: l10n.qrDisplayPreparing,
                  detail: l10n.qrDisplayPreparingDetail,
                  icon: Icons.qr_code_2_rounded,
                ),
              );
            }

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
                          l10n.qrDisplayScanOrEnterCode,
                          textAlign: TextAlign.center,
                          style: GoogleFonts.inter(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ).animate().fadeIn(),

                        const SizedBox(height: 6),
                        Text(
                          l10n.qrDisplayPhoneHint,
                          textAlign: TextAlign.center,
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            color: Colors.white.withValues(alpha: 0.70),
                          ),
                        ).animate().fadeIn(),

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
                                    data: qrState.qrData,
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
                        // The same ten digits whichever way the offer travels: a
                        // computer types them, and the app looks for the sender
                        // on the local network and over the internet at once.
                        if (qrState.code != null)
                          CopyValueRow(
                            icon: Icons.pin_rounded,
                            label: l10n.codeLabel,
                            value: qrState.code!.display,
                            copiedMessage: l10n.codeCopied,
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
                                qrState.folderName ??
                                    (qrState.itemCount > 1
                                        ? l10n.sharedItemsCount(qrState.itemCount)
                                        : qrState.session.fileMetadata.name),
                                style: GoogleFonts.inter(
                                    fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 4),
                              if (qrState.totalBytes > 0 ||
                                  qrState.session.fileMetadata.size > 0)
                                Text(
                                  l10n.qrDisplayTotalSize(_formatBytes(
                                      qrState.totalBytes > 0
                                          ? qrState.totalBytes
                                          : qrState.session.fileMetadata.size)),
                                  style: GoogleFonts.inter(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.primary,
                                  ),
                                )
                              // The QR is complete and scannable; only the
                              // size is not known yet. Said out loud, because
                              // a missing size on a screen that has one a
                              // second later reads as a glitch.
                              else if (qrState.indexing)
                                Text(
                                  l10n.qrDisplayStillCounting,
                                  style: GoogleFonts.inter(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),

                        if (qrState.expiresAt != null)
                          OfferCountdown(expiresAt: qrState.expiresAt!),

                        const SizedBox(height: 24),

                        // Cancel Transfer Button
                        OutlinedButton.icon(
                          onPressed: () {
                            context.read<SenderBloc>().add(CancelSending());
                            context.go(SendRoutes.home);
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
      ),
    );
  }

  Future<void> _showApprovalDialog(
    BuildContext context,
    InviteApprovalRequested requestState,
  ) async {
    final bloc = context.read<SenderBloc>();
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => _ApprovalDialog(request: requestState.request),
    );
    bloc.add(RespondToInviteApproval(
      requestId: requestState.request.id,
      accepted: accepted ?? false,
    ));
  }

  String _formatBytes(int bytes) => ByteFormat.size(bytes);
}

class _ApprovalDialog extends StatefulWidget {
  final TransferApprovalRequest request;

  const _ApprovalDialog({required this.request});

  @override
  State<_ApprovalDialog> createState() => _ApprovalDialogState();
}

class _ApprovalDialogState extends State<_ApprovalDialog> {
  int _remainingSeconds = 90;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    widget.request.decision.then((_) {
      // The request can end while this route is still being built, or while
      // another route is above it. Remove this particular route after the
      // frame rather than popping whichever route happens to be on top.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final route = ModalRoute.of(context);
        if (route != null && route.isActive) {
          Navigator.of(context).removeRoute(route);
        }
      });
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_remainingSeconds <= 1) {
        timer.cancel();
        Navigator.of(context).pop(false);
      } else {
        setState(() => _remainingSeconds--);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final addressText = widget.request.remoteAddress != null
        ? ' (${widget.request.remoteAddress!.address})'
        : '';
    final sizeStr = widget.request.totalBytes > 0
        ? ByteFormat.size(widget.request.totalBytes)
        : l10n.inviteUnknownSize;

    return AlertDialog(
      title: Text(l10n.inviteTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.inviteApprovalBody(
              widget.request.deviceName,
              addressText,
              widget.request.itemCount,
              sizeStr,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            l10n.inviteApprovalExpiresIn(_remainingSeconds),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.inviteDecline),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.inviteAccept),
        ),
      ],
    );
  }
}
