import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/features/receiver/presentation/bloc/receiver_bloc.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';
import 'package:quickshare/shared/widgets/transfer_phase_loader.dart';

/// Where a `directdrop://join?p=…` link opened from outside the app lands.
///
/// There is no field for a link anywhere in the app: a connection is made
/// with a scanned QR or with typed digits. This is the exception that cannot
/// be either — the link a sender copies from an internet offer and sends
/// through a messenger, to a computer that has no camera and no digits for
/// that path. It hands the link to the receiver exactly as a scan would, and
/// moves on to the same preview, which asks before anything starts.
class LinkReceivePage extends StatefulWidget {
  final String link;

  const LinkReceivePage({super.key, required this.link});

  @override
  State<LinkReceivePage> createState() => _LinkReceivePageState();
}

class _LinkReceivePageState extends State<LinkReceivePage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context
          .read<ReceiverBloc>()
          .add(QRCodeScanned(widget.link, fromPaste: true));
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: AppColors.voidBg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => context.go('/'),
        ),
      ),
      body: BlocConsumer<ReceiverBloc, ReceiverState>(
        listenWhen: (previous, next) => next is QRParsed,
        listener: (context, state) => context.go('/receive/preview'),
        builder: (context, state) {
          if (state is ReceiverError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      state.message,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                          color: AppColors.error, fontSize: 15),
                    ),
                    const SizedBox(height: 24),
                    OutlinedButton(
                      onPressed: () => context.go('/'),
                      child: Text(l10n.errorGoHome),
                    ),
                  ],
                ),
              ),
            );
          }
          return Center(
            child: TransferPhaseLoader(
              phaseLabel: l10n.linkReceiveOpening,
              detail: l10n.linkReceiveOpeningDetail,
              icon: Icons.link_rounded,
            ),
          );
        },
      ),
    );
  }
}
