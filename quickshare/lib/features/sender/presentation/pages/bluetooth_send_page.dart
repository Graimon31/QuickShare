import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:quickshare/core/router/send_routes.dart';
import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/features/sender/presentation/bloc/sender_bloc.dart';
import 'package:quickshare/core/l10n/localized_labels.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';
import 'package:quickshare/features/sender/presentation/widgets/offer_lifecycle_guard.dart';
import 'package:quickshare/shared/widgets/offer_countdown.dart';
import 'package:quickshare/shared/widgets/copy_value_row.dart';
import 'package:quickshare/shared/widgets/transfer_phase_loader.dart';

/// Shows a QR and a numeric code for the same nearby Bluetooth offer.
class BluetoothSendPage extends StatelessWidget {
  const BluetoothSendPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) context.read<SenderBloc>().add(CancelSending());
      },
      child: OfferLifecycleGuard(
        child: Scaffold(
          backgroundColor: AppColors.voidBg,
          appBar: AppBar(
            title: Text(l10n.btSendTitle),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
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
              } else if (state is SenderError) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(
                  localizedFailure(AppLocalizations.of(context),
                      code: state.code, fallback: state.message),
                  style: const TextStyle(color: Colors.white),
                )));
                context.go(SendRoutes.home);
              }
            },
            builder: (context, state) {
              if (state is! BluetoothAdvertising) {
                return Center(
                  child: TransferPhaseLoader(
                    phaseLabel: l10n.btSendPreparing,
                    detail: l10n.btSendPreparingDetail,
                    icon: Icons.bluetooth_searching_rounded,
                  ),
                );
              }

              // Scrollable rather than centered: on a small screen a centered
              // column pushes the cancel button below the fold, unreachable.
              return SafeArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24.0),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 520),
                      child: Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: AppColors.glassFill,
                          borderRadius: BorderRadius.circular(28),
                          border: Border.all(color: AppColors.glassBorder),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Hero(
                              tag: 'qr-hero',
                              child: Material(
                                color: Colors.transparent,
                                child: Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: QrImageView(
                                    // Keyed by what it encodes, so a QR that
                                    // changes under a new token is a new widget
                                    // and not the old one repainted.
                                    key: ValueKey(state.qrData),
                                    data: state.qrData,
                                    version: QrVersions.auto,
                                    size: 220,
                                  ),
                                ),
                              ),
                            ).animate().fadeIn(),
                            if (state.code != null) ...[
                              const SizedBox(height: 20),
                              CopyValueRow(
                                icon: Icons.pin_rounded,
                                label: l10n.codeLabel,
                                value: state.code!.display,
                                copiedMessage: l10n.codeCopied,
                                copyTooltip: l10n.commonCopy,
                              ),
                            ],
                            const SizedBox(height: 24),
                            Text(
                              l10n.btSendScanPrompt,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.textPrimary),
                            ).animate().fadeIn(),
                            const SizedBox(height: 8),
                            Text(
                              l10n.btSendAutoConnectNote,
                              textAlign: TextAlign.center,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(
                                    color: AppColors.textSecondary,
                                  ),
                            ).animate().fadeIn(delay: 200.ms),
                            const SizedBox(height: 16),
                            const Icon(
                              Icons.bluetooth_searching,
                              size: 48,
                              color: AppColors.primary,
                            )
                                .animate(onPlay: (c) => c.repeat(reverse: true))
                                .scale(
                                  begin: const Offset(1, 1),
                                  end: const Offset(1.1, 1.1),
                                  duration: 1.seconds,
                                ),
                            const SizedBox(height: 16),
                            Text(
                              '${state.session.fileMetadata.name} (${state.session.fileMetadata.sizeFormatted})',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(
                                    color: AppColors.textPrimary,
                                  ),
                              textAlign: TextAlign.center,
                            ).animate().fadeIn(delay: 400.ms),
                            const SizedBox(height: 12),
                            if (state.expiresAt != null)
                              OfferCountdown(
                                  expiresAt: state.expiresAt!,
                                  showsCode: state.code != null),
                            const SizedBox(height: 24),
                            OutlinedButton.icon(
                              onPressed: () {
                                context.read<SenderBloc>().add(CancelSending());
                                context.go(SendRoutes.home);
                              },
                              icon: const Icon(Icons.close),
                              label: Text(l10n.commonCancel),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.error,
                                side: const BorderSide(color: AppColors.error),
                              ),
                            ),
                          ],
                        ),
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
}
