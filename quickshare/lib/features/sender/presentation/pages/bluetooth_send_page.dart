import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/features/sender/presentation/bloc/sender_bloc.dart';
import 'package:quickshare/shared/widgets/transfer_phase_loader.dart';

/// Shows the Bluetooth session QR while this device advertises the BLE service.
class BluetoothSendPage extends StatelessWidget {
  const BluetoothSendPage({super.key});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) context.read<SenderBloc>().add(CancelSending());
      },
      child: Scaffold(
        backgroundColor: AppColors.voidBg,
        appBar: AppBar(
          title: const Text('Bluetooth'),
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
              context.go('/send');
            } else if (state is SenderError) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text(state.message)));
              context.go('/send');
            }
          },
          builder: (context, state) {
            if (state is! BluetoothAdvertising) {
              return const Center(
                child: TransferPhaseLoader(
                  phaseLabel: 'Preparing Bluetooth…',
                  detail: 'Making this device discoverable',
                  icon: Icons.bluetooth_searching_rounded,
                ),
              );
            }
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
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
                      mainAxisAlignment: MainAxisAlignment.center,
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
                        const Text(
                          'Scan this QR code on the receiving device',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: AppColors.textPrimary),
                        ).animate().fadeIn(),
                        const SizedBox(height: 8),
                        Text(
                          'The receiving device will connect over Bluetooth and start the transfer automatically.',
                          textAlign: TextAlign.center,
                          style:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: AppColors.textSecondary,
                                  ),
                        ).animate().fadeIn(delay: 200.ms),
                        const SizedBox(height: 16),
                        const Icon(
                          Icons.bluetooth_searching,
                          size: 48,
                          color: AppColors.primary,
                        ).animate(onPlay: (c) => c.repeat(reverse: true)).scale(
                              begin: const Offset(1, 1),
                              end: const Offset(1.1, 1.1),
                              duration: 1.seconds,
                            ),
                        const SizedBox(height: 16),
                        Text(
                          '${state.session.fileMetadata.name} (${state.session.fileMetadata.sizeFormatted})',
                          style:
                              Theme.of(context).textTheme.titleMedium?.copyWith(
                                    color: AppColors.textPrimary,
                                  ),
                          textAlign: TextAlign.center,
                        ).animate().fadeIn(delay: 400.ms),
                        const SizedBox(height: 48),
                        OutlinedButton.icon(
                          onPressed: () {
                            context.read<SenderBloc>().add(CancelSending());
                            context.go('/send');
                          },
                          icon: const Icon(Icons.close),
                          label: const Text('Cancel'),
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
            );
          },
        ),
      ),
    );
  }
}
