import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/features/receiver/presentation/bloc/receiver_bloc.dart';
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

  Widget _buildWakelockWarning() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color.fromRGBO(255, 255, 255, 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color.fromRGBO(255, 255, 255, 0.15)),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('💡', style: TextStyle(fontSize: 16)),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Держите экран включенным и приложение открытым до окончания передачи файла.',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
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
        final confirm = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Cancel Download?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('No'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Yes'),
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
        appBar: AppBar(title: const Text('Downloading...')),
        body: BlocConsumer<ReceiverBloc, ReceiverState>(
          listener: (context, state) {
            if (state is Connecting || state is Downloading || state is Verifying) {
              WakelockPlus.enable();
            } else if (state is DownloadComplete) {
              WakelockPlus.disable();
              context.go('/receive/complete', extra: {
                'filePath': state.filePath,
                'fileName': state.fileName,
              });
            } else if (state is ReceiverError) {
              WakelockPlus.disable();
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text(state.message)));
              context.go('/');
            }
          },
          builder: (context, state) {
            if (state is Connecting) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const TransferPhaseLoader(
                      phaseLabel: 'Connecting to sender…',
                      detail: 'Preparing a secure transfer channel',
                      icon: Icons.link_rounded,
                    ),
                    const SizedBox(height: 16),
                    _buildWakelockWarning(),
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
                    _buildWakelockWarning(),
                  ],
                ),
              );
            } else if (state is Verifying) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const TransferPhaseLoader(
                      phaseLabel: 'Verifying transfer…',
                      detail: 'Checking file integrity',
                      icon: Icons.verified_outlined,
                    ),
                    const SizedBox(height: 16),
                    _buildWakelockWarning(),
                  ],
                ),
              );
            }
            return const Center(
              child: TransferPhaseLoader(
                phaseLabel: 'Preparing download…',
                detail: 'Waiting for the sender',
                icon: Icons.download_rounded,
              ),
            );
          },
        ),
      ),
    );
  }
}
