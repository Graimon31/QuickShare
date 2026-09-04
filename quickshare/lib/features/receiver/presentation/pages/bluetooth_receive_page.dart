import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:quickshare/core/network/peer_link_service.dart';
import 'package:quickshare/core/storage/transfer_cache.dart';
import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/features/receiver/data/client/isolated_qhtp_receiver.dart';
import 'package:quickshare/shared/models/qr_payload.dart';
import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/features/receiver/data/transports/bluetooth_receiver_transport.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';
import 'package:quickshare/shared/widgets/progress_indicator_widget.dart';
import 'package:quickshare/shared/widgets/transfer_phase_loader.dart';

/// Bluetooth receive can use a QR session token to select the intended Mac
/// automatically, while retaining manual discovery for direct use.
class BluetoothReceivePage extends StatefulWidget {
  final String? sessionToken;

  const BluetoothReceivePage({super.key, this.sessionToken});

  @override
  State<BluetoothReceivePage> createState() => _BluetoothReceivePageState();
}

enum _Phase { scanning, connecting, transferring, completed, failed }

class _BluetoothReceivePageState extends State<BluetoothReceivePage> {
  final _transport = BluetoothReceiverTransport();
  final _devices = <BluetoothDevice>[];

  _Phase _phase = _Phase.scanning;
  String _fileName = '';
  int _received = 0;
  int _total = 0;
  String? _savedPath;
  String? _error;
  bool _autoConnectAttempted = false;

  @override
  void initState() {
    super.initState();
    _transport.devices.listen((d) {
      if (!mounted) return;
      if (!_devices.any((e) => e.id == d.id)) {
        setState(() => _devices.add(d));
      }
      if (widget.sessionToken != null && !_autoConnectAttempted) {
        _autoConnectAttempted = true;
        _connect(d);
      }
    });
    _tryDirectLinkThenScan();
  }

  /// Takes the direct Wi-Fi link when the sender is offering one, and falls
  /// back to the Bluetooth transfer when it is not.
  ///
  /// Same button, same promise — nothing nearby needs a network — but the
  /// bytes travel over the only radio that can carry them at speed. Bluetooth
  /// itself tops out at 2 Mbit/s for BLE, which is what Apple leaves open to
  /// apps, so 200 MB over it is twenty minutes at the theoretical best.
  ///
  /// Everything about this is best effort. An older sender, a non-Apple one,
  /// Wi-Fi switched off, no session token to look up — each simply falls
  /// through to the scan that was here before.
  Future<void> _tryDirectLinkThenScan() async {
    final token = widget.sessionToken;
    if (token == null || token.isEmpty || !PeerLinkService.isSupported) {
      await _startScan();
      return;
    }

    setState(() {
      _phase = _Phase.connecting;
      _fileName = AppLocalizations.of(context).btReceiveLookingForLink;
    });

    try {
      final port = await const PeerLinkService().join(
        serviceName: PeerLinkService.serviceNameFor(token),
        timeout: const Duration(seconds: 8),
      );
      if (!mounted) return;
      await _receiveOverDirectLink(token, port);
      return;
    } on PeerLinkException catch (e) {
      AppLogger.info('No direct link for this transfer, using Bluetooth: $e',
          tag: 'PEERLINK');
    }
    if (mounted) await _startScan();
  }

  Future<void> _receiveOverDirectLink(String token, int port) async {
    setState(() {
      _phase = _Phase.transferring;
      _fileName = AppLocalizations.of(context).btReceiveDirectLinkPlaceholder;
    });

    final session = await const TransferCache().sessionDirectory();
    // The worker, like every other receive path: this one runs on a phone by
    // definition, which is where sharing a thread with the screen hurts most.
    final result = await IsolatedQhtpReceiver().downloadSession(
      // The session id is only ever a local key for resume state; the server
      // is reached with the address and token alone. The Bluetooth session
      // token is the natural choice — it is stable across a retry, which is
      // exactly what resuming wants.
      payload: QRPayload(
        version: 2,
        ip: '127.0.0.1',
        port: port,
        token: token,
        sessionId: token,
        mode: 'http-lan',
      ),
      targetBaseDir: session.path,
      onProgress: (progress) {
        if (!mounted || progress.phase != 'transferring') return;
        setState(() {
          _received = progress.sessionReceived;
          _total = progress.sessionTotal;
          if (progress.itemPath.isNotEmpty) _fileName = progress.itemPath;
        });
      },
    );
    await const PeerLinkService().stop();
    if (!mounted) return;

    result.fold(
      (failure) {
        // Falling back rather than failing. The direct link is an optimisation
        // the user never asked for by name; if it does not deliver, the
        // Bluetooth transfer they did ask for is still there and still works.
        // Showing "connection failed" here sent people to tap Scan again,
        // which quietly did this anyway — badly, and only after alarming them.
        AppLogger.info(
            'The direct link did not deliver (${failure.message}); '
            'falling back to Bluetooth',
            tag: 'PEERLINK');
        unawaited(_startScan());
      },
      (received) {
        final items = TransferCache.itemsIn(session);
        context.go('/receive/complete', extra: {
          'filePath': received.preferredResultPath,
          'fileName':
              items.length == 1 ? items.single.name : received.displayName,
          'items': items,
        });
      },
    );
  }

  Future<void> _startScan() async {
    setState(() {
      _phase = _Phase.scanning;
      _devices.clear();
      _error = null;
      _autoConnectAttempted = false;
    });
    try {
      await _transport.startScanning(sessionToken: widget.sessionToken);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _connect(BluetoothDevice device) async {
    await _transport.stopScanning();
    setState(() {
      _phase = _Phase.connecting;
      _fileName = device.name;
    });

    final sub = _transport.progressStream.listen((p) {
      if (!mounted) return;
      setState(() {
        _phase =
            p.phase == 'completed' ? _Phase.completed : _Phase.transferring;
        _fileName = p.fileName;
        _received = p.received;
        _total = p.total;
      });
    });

    try {
      // Into the transfer cache, like every other transport: a Bluetooth
      // transfer used to write straight into Documents on iOS and Downloads
      // elsewhere, so a photo sent this way never reached the gallery and a
      // document was never asked about.
      final session = await const TransferCache().sessionDirectory();
      final path = await _transport.connect(device.id, targetDir: session.path);
      if (!mounted) return;
      setState(() {
        _phase = _Phase.completed;
        _savedPath = path;
      });
      // The completion screen owns placement — gallery, Downloads, or a
      // question — so this page hands over rather than declaring itself done.
      final items = TransferCache.itemsIn(session);
      if (!mounted) return;
      context.go('/receive/complete', extra: {
        'filePath': path,
        'fileName': items.length == 1 ? items.single.name : _fileName,
        'items': items,
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      await sub.cancel();
    }
  }

  String _fmt(int bytes) {
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

  @override
  void dispose() {
    _transport.cancel();
    _transport.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: AppColors.voidBg,
      appBar: AppBar(
        title: Text(l10n.btReceiveTitle),
        leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => context.go('/')),
        actions: [
          if (_phase == _Phase.scanning)
            IconButton(icon: const Icon(Icons.refresh), onPressed: _startScan),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: AppColors.glassFill,
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: AppColors.glassBorder),
              ),
              child: _buildBody(theme, l10n),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme, AppLocalizations l10n) {
    switch (_phase) {
      case _Phase.scanning:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.sessionToken == null
                  ? l10n.btReceiveLookingNearby
                  : l10n.btReceiveLookingQr,
              style: theme.textTheme.titleMedium?.copyWith(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            if (_devices.isEmpty)
              TransferPhaseLoader(
                phaseLabel: l10n.btReceiveScanning,
                detail: l10n.btReceiveScanningDetail,
                icon: Icons.bluetooth_searching_rounded,
              )
            else
              ..._devices.map(
                (d) => Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  decoration: BoxDecoration(
                    color: AppColors.glassFillStrong,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.glassBorder),
                  ),
                  child: ListTile(
                    leading:
                        const Icon(Icons.laptop_mac, color: AppColors.primary),
                    title: Text(d.name,
                        style: const TextStyle(color: AppColors.textPrimary)),
                    trailing: const Icon(Icons.chevron_right,
                        color: AppColors.textSecondary),
                    onTap: () => _connect(d),
                  ),
                ),
              ),
          ],
        );

      case _Phase.connecting:
        return TransferPhaseLoader(
          phaseLabel: l10n.btReceiveConnecting,
          detail: l10n.btReceivePairingWith(_fileName),
          icon: Icons.bluetooth_connected_rounded,
        );

      case _Phase.transferring:
        return Column(
          children: [
            CustomProgressIndicator(
              progress: _total > 0 ? _received / _total : 0,
              speedBytesPerSec: 0,
              fileName: _fileName,
              showSpeed: false,
            ),
            const SizedBox(height: 12),
            Text(
              '${_fmt(_received)}${_total > 0 ? ' / ${_fmt(_total)}' : ''}',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        );

      case _Phase.completed:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(Icons.check_circle_outline_rounded,
                size: 72, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text(l10n.transferFileReceived,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(_fileName,
                textAlign: TextAlign.center, style: theme.textTheme.bodyLarge),
            if (_savedPath != null) ...[
              const SizedBox(height: 4),
              Text(
                _savedPath!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 24),
            OutlinedButton(
                onPressed: () => context.go('/'), child: Text(l10n.commonDone)),
          ],
        );

      case _Phase.failed:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(Icons.error_outline_rounded,
                size: 72, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text(l10n.btReceiveConnectionFailed,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              _error ?? l10n.commonUnknownError,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            OutlinedButton(
                onPressed: _startScan, child: Text(l10n.btReceiveScanAgain)),
          ],
        );
    }
  }
}
