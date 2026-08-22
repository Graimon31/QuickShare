import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';

import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/features/sender/presentation/bloc/sender_bloc.dart';
import 'package:quickshare/shared/widgets/progress_indicator_widget.dart';
import 'package:quickshare/shared/widgets/transfer_phase_loader.dart';

class SenderProgressPage extends StatelessWidget {
  const SenderProgressPage({super.key});

  void _showCancelDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel Transfer?'),
        content: const Text('Are you sure you want to stop sending this file?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('No'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              context.read<SenderBloc>().add(CancelSending());
            },
            child: const Text('Yes, Cancel'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final state = context.read<SenderBloc>().state;
        if (state is Transferring) {
          _showCancelDialog(context);
        } else {
          context.go('/send');
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.voidBg,
        appBar: AppBar(
          title: const Text('Transferring File'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              final state = context.read<SenderBloc>().state;
              if (state is Transferring) {
                _showCancelDialog(context);
              } else {
                context.go('/send');
              }
            },
          ),
        ),
        body: BlocConsumer<SenderBloc, SenderState>(
          listener: (context, state) {
            if (state is SenderInitial) {
              context.go('/send');
            }
          },
          builder: (context, state) {
            if (state is TransferComplete) {
              return Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.check_circle_rounded,
                        color: AppColors.success,
                        size: 100,
                      ).animate().scale().fadeIn(),
                      const SizedBox(height: 24),
                      Text(
                        'Transfer Complete!',
                        style:
                            Theme.of(context).textTheme.headlineSmall?.copyWith(
                                  color: AppColors.textPrimary,
                                  fontWeight: FontWeight.w700,
                                ),
                      ).animate().fadeIn(delay: 200.ms),
                      const SizedBox(height: 8),
                      Text(
                        state.file.name,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                              color: AppColors.textSecondary,
                            ),
                      ).animate().fadeIn(delay: 400.ms),
                      const SizedBox(height: 48),
                      FilledButton(
                        onPressed: () {
                          context.read<SenderBloc>().add(CancelSending());
                          context.go('/send');
                        },
                        child: const Text('Send Another File'),
                      ).animate().fadeIn(delay: 600.ms),
                    ],
                  ),
                ),
              );
            }

            if (state is Transferring) {
              return Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(32.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Hero(
                        tag: 'qr-hero',
                        child: Material(
                          color: Colors.transparent,
                          child: CustomProgressIndicator(
                            progress: state.progress,
                            speedBytesPerSec: state.speedBps.toDouble(),
                            fileName: '',
                          ),
                        ),
                      ).animate().fadeIn(),
                      const SizedBox(height: 32),
                      Text(
                        'Sending...',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 32),
                      OutlinedButton.icon(
                        onPressed: () => _showCancelDialog(context),
                        icon: const Icon(Icons.close),
                        label: const Text('Cancel'),
                      ),
                    ],
                  ),
                ),
              );
            }

            if (state is SenderError) {
              return Center(
                child: TransferPhaseLoader(
                  phaseLabel: 'Transfer failed',
                  detail: state.message,
                  icon: Icons.error_outline_rounded,
                ),
              );
            }

            return const Center(
              child: TransferPhaseLoader(
                phaseLabel: 'Preparing transfer…',
                icon: Icons.sync_rounded,
              ),
            );
          },
        ),
      ),
    );
  }
}
