import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/features/receiver/data/transports/bluetooth_receiver_transport.dart';
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
    _startScan();
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
      final path = await _transport.connect(device.id);
      if (!mounted) return;
      setState(() {
        _phase = _Phase.completed;
        _savedPath = path;
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
    return Scaffold(
      backgroundColor: AppColors.voidBg,
      appBar: AppBar(
        title: const Text('Nearby devices'),
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
              child: _buildBody(theme),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    switch (_phase) {
      case _Phase.scanning:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.sessionToken == null
                  ? 'Looking for nearby Macs…'
                  : 'Looking for the Mac from the QR code…',
              style: theme.textTheme.titleMedium?.copyWith(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            if (_devices.isEmpty)
              const TransferPhaseLoader(
                phaseLabel: 'Scanning for nearby devices…',
                detail: 'Keep Bluetooth enabled on both devices',
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
          phaseLabel: 'Connecting over Bluetooth…',
          detail: 'Pairing with $_fileName',
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
            Text('File received',
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
                onPressed: () => context.go('/'), child: const Text('Done')),
          ],
        );

      case _Phase.failed:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(Icons.error_outline_rounded,
                size: 72, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text('Connection failed',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              _error ?? 'Unknown error',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            OutlinedButton(
                onPressed: _startScan, child: const Text('Scan again')),
          ],
        );
    }
  }
}
