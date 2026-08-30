import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/features/sender/presentation/bloc/sender_bloc.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';

/// Walks the sender through handing a network to the other device.
///
/// Two codes in sequence rather than one, because they are read by two
/// different things. The first is a plain `WIFI:` payload that any phone
/// camera recognises and offers to join — no app required on that side yet.
/// The second is the ordinary transfer locator, and it only means anything
/// once the other device is actually on the network.
class LocalNetworkPage extends StatefulWidget {
  final VoidCallback? onCancel;

  const LocalNetworkPage({super.key, this.onCancel});

  @override
  State<LocalNetworkPage> createState() => _LocalNetworkPageState();
}

class _LocalNetworkPageState extends State<LocalNetworkPage> {
  bool _joined = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(l10n.localNetTitle),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () {
            // Cancelling has to tear the hotspot down too, otherwise the Wi-Fi
            // radio stays in access-point mode with nobody using it.
            context.read<SenderBloc>().add(CancelSending());
            widget.onCancel?.call();
          },
        ),
      ),
      body: BlocBuilder<SenderBloc, SenderState>(
        builder: (context, state) {
          if (state is HotspotStarting) {
            return _Busy(message: l10n.localNetCreating);
          }
          if (state is LocalNetworkReady) {
            return _ready(context, l10n, state);
          }
          if (state is SenderError) {
            return _failed(context, l10n, state.message);
          }
          // Transferring / complete are handled by the progress route.
          return _Busy(message: l10n.localNetWorking);
        },
      ),
    );
  }

  Widget _ready(
      BuildContext context, AppLocalizations l10n, LocalNetworkReady state) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Step(
                  number: 1,
                  title: l10n.localNetStep1Title,
                  subtitle: l10n.localNetStep1Subtitle,
                  active: !_joined,
                  child: Column(
                    children: [
                      _QrCard(data: state.wifiQr),
                      const SizedBox(height: 12),
                      _CredentialRow(
                          label: l10n.localNetNetworkLabel,
                          value: state.credentials.ssid),
                      if (state.credentials.passphrase.isNotEmpty)
                        _CredentialRow(
                            label: l10n.localNetPasswordLabel,
                            value: state.credentials.passphrase),
                      const SizedBox(height: 8),
                      Text(
                        l10n.localNetNoInternetNote,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: Colors.white38),
                      ),
                      const SizedBox(height: 12),
                      if (!_joined)
                        FilledButton(
                          onPressed: () => setState(() => _joined = true),
                          child: Text(l10n.localNetJoinedButton),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                _Step(
                  number: 2,
                  title: l10n.localNetStep2Title,
                  subtitle: l10n.localNetStep2Subtitle(
                      state.credentials.hostAddress ?? ''),
                  active: _joined,
                  child: _joined
                      ? _QrCard(data: state.transferQr)
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _failed(BuildContext context, AppLocalizations l10n, String message) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off_rounded, size: 48, color: Colors.white38),
            const SizedBox(height: 16),
            Text(message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: Colors.white70)),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () =>
                  context.read<SenderBloc>().add(StartLocalNetwork()),
              child: Text(l10n.commonRetry),
            ),
          ],
        ),
      ),
    );
  }
}

class _Busy extends StatelessWidget {
  final String message;
  const _Busy({required this.message});

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 20),
            Text(message,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: Colors.white70)),
          ],
        ),
      );
}

class _Step extends StatelessWidget {
  final int number;
  final String title;
  final String subtitle;
  final bool active;
  final Widget child;

  const _Step({
    required this.number,
    required this.title,
    required this.subtitle,
    required this.active,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: active ? 1 : 0.45,
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: active
                ? theme.colorScheme.primary.withValues(alpha: 0.5)
                : Colors.white.withValues(alpha: 0.08),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 13,
                  backgroundColor: active
                      ? theme.colorScheme.primary
                      : Colors.white.withValues(alpha: 0.12),
                  child: Text('$number',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(subtitle,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: Colors.white54)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

class _QrCard extends StatelessWidget {
  final String data;
  const _QrCard({required this.data});

  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
          ),
          child: QrImageView(
            data: data,
            version: QrVersions.auto,
            size: 200,
            backgroundColor: Colors.white,
          ),
        ),
      );
}

class _CredentialRow extends StatelessWidget {
  final String label;
  final String value;
  const _CredentialRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('$label: ',
              style:
                  theme.textTheme.bodySmall?.copyWith(color: Colors.white38)),
          SelectableText(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
