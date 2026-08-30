import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/deep_link/deep_link_service.dart';
import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/features/sender/presentation/bloc/sender_bloc.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';
import 'package:quickshare/shared/widgets/copy_value_row.dart';
import 'package:quickshare/shared/widgets/session_expired_panel.dart';
import 'package:quickshare/shared/widgets/transfer_phase_loader.dart';

/// Shows the Bluetooth session QR while this device advertises the BLE service.
class BluetoothSendPage extends StatefulWidget {
  const BluetoothSendPage({super.key});

  @override
  State<BluetoothSendPage> createState() => _BluetoothSendPageState();
}

class _BluetoothSendPageState extends State<BluetoothSendPage> {
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
        if (didPop) context.read<SenderBloc>().add(CancelSending());
      },
      child: Scaffold(
        backgroundColor: AppColors.voidBg,
        appBar: AppBar(
          title: Text(l10n.btSendTitle),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
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
            } else if (state is SenderError) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text(state.message)));
              context.go('/send');
            }
          },
          builder: (context, state) {
            if (_expired) {
              return SessionExpiredPanel(onRefresh: _refreshSession);
            }
            if (state is! BluetoothAdvertising) {
              return Center(
                child: TransferPhaseLoader(
                  phaseLabel: l10n.btSendPreparing,
                  detail: l10n.btSendPreparingDetail,
                  icon: Icons.bluetooth_searching_rounded,
                ),
              );
            }

            final shareLink = DeepLinkService.buildPayloadLink(
              state.qrData,
              name: state.session.fileMetadata.name,
              bytes: state.session.fileMetadata.size,
              itemCount: state.itemCount,
            );

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
                                  data: state.qrData,
                                  version: QrVersions.auto,
                                  size: 220,
                                ),
                              ),
                            ),
                          ).animate().fadeIn(),
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
                          const SizedBox(height: 16),
                          CopyValueRow(
                            icon: Icons.link,
                            label: l10n.qrDisplayShareLinkLabel,
                            value: shareLink,
                            copiedMessage: l10n.qrDisplayLinkCopied,
                            copyTooltip: l10n.commonCopy,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            l10n.qrDisplaySessionExpires(
                                _formatTime(_secondsLeft)),
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppColors.error,
                            ),
                          ),
                          const SizedBox(height: 24),
                          OutlinedButton.icon(
                            onPressed: () {
                              context.read<SenderBloc>().add(CancelSending());
                              context.go('/send');
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
    );
  }
}
