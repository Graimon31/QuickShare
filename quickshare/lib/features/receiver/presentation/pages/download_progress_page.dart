import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/features/receiver/presentation/bloc/receiver_bloc.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';
import 'package:quickshare/shared/models/qr_payload.dart';
import 'package:quickshare/shared/widgets/progress_indicator_widget.dart';
import 'package:quickshare/shared/widgets/transfer_phase_loader.dart';

class DownloadProgressPage extends StatefulWidget {
  final QRPayload? initialPayload;

  const DownloadProgressPage({super.key, this.initialPayload});

  @override
  State<DownloadProgressPage> createState() => _DownloadProgressPageState();
}

class _DownloadProgressPageState extends State<DownloadProgressPage> {
  bool _downloadStarted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _downloadStarted) return;
      final bloc = context.read<ReceiverBloc>();
      // Already in-flight (e.g. preview page kicked it off) — only listen.
      if (bloc.state is Connecting ||
          bloc.state is Downloading ||
          bloc.state is Verifying) {
        _downloadStarted = true;
        WakelockPlus.enable();
        return;
      }
      _downloadStarted = true;
      WakelockPlus.enable();
      bloc.add(StartDownload(payload: widget.initialPayload));
    });
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    super.dispose();
  }

  /// What the snackbar says. [ReceiverError.message] is a caught
  /// exception's own text where [ReceiverError.code] is null — nobody
  /// reading only Russian should have to parse a `DioException` to learn
  /// their transfer stopped, so a known [code] always wins.
  String _errorMessage(AppLocalizations l10n, ReceiverError state) {
    switch (state.code) {
      case FailureCode.senderUnreachable:
        return l10n.downloadErrorSenderUnreachable;
      case FailureCode.cancelledBySender:
        return l10n.downloadErrorCancelledBySender;
      default:
        return state.message;
    }
  }

  Widget _buildWakelockWarning(AppLocalizations l10n) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color.fromRGBO(255, 255, 255, 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color.fromRGBO(255, 255, 255, 0.15)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('💡', style: TextStyle(fontSize: 16)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.downloadWakelockWarning,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final confirm = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(l10n.downloadCancelTitle),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(l10n.commonNo),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(l10n.commonYes),
              ),
            ],
          ),
        );
        if (confirm == true && context.mounted) {
          WakelockPlus.disable();
          context.read<ReceiverBloc>().add(CancelDownload());
          context.go('/');
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.voidBg,
        appBar: AppBar(title: Text(l10n.downloadTitle)),
        body: BlocConsumer<ReceiverBloc, ReceiverState>(
          listener: (context, state) {
            if (state is Connecting ||
                state is Downloading ||
                state is Verifying) {
              WakelockPlus.enable();
            } else if (state is DownloadComplete) {
              WakelockPlus.disable();
              context.go('/receive/complete', extra: {
                'filePath': state.filePath,
                'fileName': state.fileName,
                'items': state.items,
                'placed': state.placed,
              });
            } else if (state is ReceiverError) {
              WakelockPlus.disable();
              ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(_errorMessage(l10n, state))));
              context.go('/');
            }
          },
          builder: (context, state) {
            if (state is Connecting) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    TransferPhaseLoader(
                      phaseLabel: l10n.downloadConnecting,
                      detail: l10n.downloadConnectingDetail,
                      icon: Icons.link_rounded,
                    ),
                    const SizedBox(height: 16),
                    _buildWakelockWarning(l10n),
                  ],
                ),
              );
            } else if (state is Downloading) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CustomProgressIndicator(
                      progress: state.progress,
                      speedBytesPerSec: state.speedBps.toDouble(),
                      fileName: state.fileName,
                    ),
                    const SizedBox(height: 16),
                    _buildWakelockWarning(l10n),
                  ],
                ),
              );
            } else if (state is Verifying) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    TransferPhaseLoader(
                      phaseLabel: l10n.downloadVerifying,
                      detail: l10n.downloadVerifyingDetail,
                      icon: Icons.verified_outlined,
                    ),
                    const SizedBox(height: 16),
                    _buildWakelockWarning(l10n),
                  ],
                ),
              );
            }
            return Center(
              child: TransferPhaseLoader(
                phaseLabel: l10n.downloadPreparing,
                detail: l10n.downloadPreparingDetail,
                icon: Icons.download_rounded,
              ),
            );
          },
        ),
      ),
    );
  }
}
