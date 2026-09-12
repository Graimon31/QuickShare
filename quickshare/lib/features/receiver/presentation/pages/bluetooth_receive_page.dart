import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:quickshare/core/l10n/localized_labels.dart';
import 'package:quickshare/core/network/direct_link_coordinator.dart';
import 'package:quickshare/core/network/direct_link_driver.dart';
import 'package:quickshare/core/network/local_hotspot_service.dart';
import 'package:quickshare/core/network/network_info_service.dart';
import 'package:quickshare/core/storage/transfer_cache.dart';
import 'package:quickshare/features/receiver/data/client/isolated_qhtp_receiver.dart';
import 'package:quickshare/shared/models/qr_payload.dart';
import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/features/receiver/data/transports/bluetooth_receiver_transport.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';
import 'package:quickshare/shared/widgets/progress_indicator_widget.dart';
import 'package:quickshare/shared/widgets/transfer_phase_loader.dart';
import 'package:quickshare/core/utils/byte_format.dart';

/// Bluetooth receive can use a QR session token to select the intended Mac
/// automatically, while retaining manual discovery for direct use.
class BluetoothReceivePage extends StatefulWidget {
  final String? sessionToken;

  /// The public half of the sender's session code, from the QR. What the
  /// sender advertises, and therefore what a scan can match on.
  final String? publicId;

  const BluetoothReceivePage({super.key, this.sessionToken, this.publicId});

  @override
  State<BluetoothReceivePage> createState() => _BluetoothReceivePageState();
}

enum _Phase { scanning, connecting, waiting, transferring, completed, failed }

class _BluetoothReceivePageState extends State<BluetoothReceivePage> {
  final BleReceiver _transport = BluetoothReceiverTransport.forPlatform();
  final _devices = <BluetoothDevice>[];

  _Phase _phase = _Phase.scanning;
  String _fileName = '';
  int _received = 0;
  int _total = 0;
  String? _savedPath;
  String? _error;
  bool _autoConnectAttempted = false;

  /// Two routes can finish this session — an old sender's bytes arriving
  /// over BLE, or the direct-link pull. Whichever gets there first wins;
  /// the second finds this set and stands down.
  bool _completed = false;

  /// Prevents duplicate serve frames from spawning multiple concurrent
  /// IsolatedQhtpReceiver instances into the same session directory.
  bool _receiveStarted = false;

  /// The loopback port a joined peer-to-peer link reaches the sender on.
  ///
  /// Set only when the rendezvous took that rung, and it overrides the
  /// address the sender sends: on a link with no access point the sender's
  /// own address is not routable from here, and its end of the link is.
  int? _peerLinkPort;

  /// Bytes are arriving over BLE itself, which only a sender older than
  /// protocol generation 4 still does. Set from the progress stream so the
  /// coordinator's timeout — "no directive ever came" — is not read as a
  /// failure while such a transfer is visibly working.
  bool _bleProgressSeen = false;

  /// Set when the person typed the code instead of scanning the QR. Both
  /// arrive at the same two values, which is the point of deriving them from
  /// the digits rather than sending them. The code itself is kept as well:
  /// if the link negotiation asks this device to raise the network, the code
  /// names it.
  String? _typedToken;
  String? _typedPublicId;
  SessionCode? _typedCode;

  /// Set once a search for one particular session has gone long enough that
  /// "still looking" stops being the honest word for it. Without this a code
  /// with no sender behind it scanned for ever behind a spinner.
  bool _searchGaveUp = false;
  Timer? _searchClock;
  final _codeField = TextEditingController();
  String? _codeError;
  bool _joinedAsGuest = false;

  String? get _token => _typedToken ?? widget.sessionToken;

  /// True when this screen already knows which session it wants — scanned
  /// from a QR or derived from typed digits. Connecting then means starting.
  bool get _hasSessionInHand => (_token ?? '').isNotEmpty;
  String? get _publicId => _typedPublicId ?? widget.publicId;

  @override
  void initState() {
    super.initState();
    _transport.devices.listen((d) {
      if (!mounted) return;
      if (!_devices.any((e) => e.id == d.id)) {
        setState(() => _devices.add(d));
      }
      // Announcing is automatic; accepting a transfer is not.
      //
      // With no session in hand this connects and says who this device is,
      // then waits to be picked — the only way it can appear on the sending
      // screen at all, since a device that has not spoken cannot be polled
      // for over this radio, and no START is written either way.
      //
      // With a session in hand the connection writes START and the transfer
      // begins, so it waits for the person to choose the device. It used to
      // fire at whichever sender the scan happened to surface first, which
      // is not the same thing as the one they meant even when they had just
      // scanned its code.
      if (!_autoConnectAttempted && !_hasSessionInHand) {
        _autoConnectAttempted = true;
        _connect(d);
      }
    });
    _startScan();
  }

  /// The receiver's half of the rendezvous: once the BLE channel is up, the
  /// sender's first metadata frame says who raises the direct Wi-Fi link,
  /// and its `serve` frame then says where the file is on it.
  ///
  /// A sender older than generation 4 never sends either; the bytes arriving
  /// over BLE itself are that case, and they keep their path.
  Future<void> _negotiateDirectLink() async {
    final outcome = await DirectLinkCoordinator(
      driver: LocalHotspotDriver(),
      signal: _ReceiverLinkSignal(_transport),
      probeLink: () async {
        for (var i = 0; i < 20; i++) {
          final ip = await NetworkInfoService().getLocalIpAddress();
          if (ip != null && !ip.startsWith('127.') && ip.isNotEmpty) {
            return true;
          }
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        return false;
      },
    ).runReceiver(_typedCode);
    if (!mounted || _completed) return;

    switch (outcome) {
      case DirectLinkUnavailable(message: final message, code: final code):
        // An old sender's transfer is bytes over this radio, visibly moving.
        // Only a generation-4 session can end here — and for one, the radio
        // will never carry anything, so waiting longer helps nobody.
        if (_bleProgressSeen) return;
        // Translated here rather than stored: `_error` is what the screen
        // shows, and the coordinator that produced this has no locale.
        final shown = localizedFailure(AppLocalizations.of(context),
            code: code, fallback: message);
        setState(() {
          _phase = _Phase.failed;
          _error = shown;
        });

      case DirectLinkOverPeerLink(localPort: final localPort):
        // No access point exists: the link is a loopback port on this
        // machine that reaches the sender's server. The address in the serve
        // frame belongs to the far side and means nothing here, so this is
        // where the file actually is.
        _peerLinkPort = localPort;

      case DirectLinkReady(hosting: final hosting):
        if (!hosting) {
          _joinedAsGuest = true;
        }
        // The link is up; the sender's serve frame names the rest.
        break;
    }
  }

  Future<void> _receiveOverDirectLink(LinkServeInfo serve) async {
    if (_completed || _receiveStarted) return;
    _receiveStarted = true;
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
        ip: _peerLinkPort != null ? '127.0.0.1' : serve.ip,
        port: _peerLinkPort ?? serve.port,
        token: serve.token,
        sessionId: serve.token,
        mode: 'http-lan',
        // What the pull is pinned to. The sender names it in the serve frame
        // because this path never showed a QR to carry it.
        tlsFingerprint: serve.tlsFingerprint,
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
    if (!mounted || _completed) return;

    result.fold(
      (failure) {
        if (_joinedAsGuest) {
          unawaited(LocalHotspotService().leaveNetwork());
        }
        setState(() {
          _phase = _Phase.failed;
          _error = failure.message;
        });
      },
      (received) {
        if (_joinedAsGuest) {
          unawaited(LocalHotspotService().leaveNetwork());
        }
        _completed = true;
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

  /// Takes the ten digits and looks for the device advertising them.
  ///
  /// The same two values the QR would have handed over — the token that
  /// authorises the transfer and the identifier the sender advertises — are
  /// both derived from the digits here, so nothing about the session has to
  /// travel between the devices for a typed code to work.
  Future<void> _useTypedCode() async {
    final l10n = AppLocalizations.of(context);
    final code = SessionCode.parse(_codeField.text);
    if (code == null) {
      setState(() => _codeError = l10n.btReceiveCodeInvalid);
      return;
    }
    setState(() {
      _codeError = null;
      _typedToken = code.sessionToken;
      _typedPublicId = code.publicId;
      _typedCode = code;
    });
    await _transport.stopScanning();
    if (!mounted) return;
    await _startScan();
  }

  /// How long to look for one named session before saying it is not here.
  static const Duration _searchBudget = Duration(seconds: 15);

  void _restartSearchClock() {
    _searchClock?.cancel();
    _searchGaveUp = false;
    if (_publicId == null || _publicId!.isEmpty) return;
    _searchClock = Timer(_searchBudget, () {
      if (mounted && _phase == _Phase.scanning && _devices.isEmpty) {
        setState(() => _searchGaveUp = true);
      }
    });
  }

  Future<void> _startScan() async {
    setState(() {
      _phase = _Phase.scanning;
      _devices.clear();
      _error = null;
      _autoConnectAttempted = false;
      _completed = false;
      _receiveStarted = false;
      _bleProgressSeen = false;
      _peerLinkPort = null;
      _joinedAsGuest = false;
    });
    _restartSearchClock();
    try {
      await _transport.startScanning(
          sessionToken: _token, publicId: _publicId);
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
      // File metadata or bytes on the radio itself mean the far side is
      // older than generation 4 — its transfer is the one that finishes
      // this session.
      if (p.phase == 'transferring') _bleProgressSeen = true;
      setState(() {
        _phase = switch (p.phase) {
          'completed' => _Phase.completed,
          // Announced and waiting to be picked. Nothing is transferring, and
          // showing a progress bar at zero for it reads as a stall.
          'waiting' => _Phase.waiting,
          _ => _Phase.transferring,
        };
        if (p.phase != 'waiting') _fileName = p.fileName;
        _received = p.received;
        _total = p.total;
      });
    });

    // The link the file actually crosses is negotiated over the channel the
    // moment it is up, and the sender's serve frame then names where to pull
    // from. Both subscriptions go in before the connect future is awaited —
    // for a generation-4 sender that future never resolves, because no bytes
    // were ever going to cross this radio.
    final serveSub = _transport.serveInfos.listen((serve) {
      unawaited(_receiveOverDirectLink(serve));
    });

    try {
      // Into the transfer cache, like every other transport: a Bluetooth
      // transfer used to write straight into Documents on iOS and Downloads
      // elsewhere, so a photo sent this way never reached the gallery and a
      // document was never asked about.
      final session = await const TransferCache().sessionDirectory();
      final connectFuture = _transport.connect(device.id,
          token: _token, targetDir: session.path);
      unawaited(_negotiateDirectLink());
      final path = await connectFuture;
      if (!mounted || _completed) return;
      _completed = true;
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
      if (!mounted || _completed || _receiveStarted) return;
      setState(() {
        _phase = _Phase.failed;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      await sub.cancel();
      await serveSub.cancel();
    }
  }

  String _fmt(int bytes) => ByteFormat.size(bytes);

  @override
  void dispose() {
    if (_joinedAsGuest) {
      unawaited(LocalHotspotService().leaveNetwork());
    }
    _searchClock?.cancel();
    _codeField.dispose();
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
              _token == null
                  ? l10n.btReceiveLookingNearby
                  : l10n.btReceiveLookingQr,
              style: theme.textTheme.titleMedium?.copyWith(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            if (_devices.isEmpty && _searchGaveUp)
              Text(
                l10n.codeNotFound,
                style: const TextStyle(color: AppColors.error, fontSize: 14),
              )
            else if (_devices.isEmpty)
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

            // Digits, for the case the list cannot solve on its own: several
            // devices in range look alike, and a camera is not always pointed
            // at the QR. The code names one of them without anything about the
            // session travelling between the two.
            const SizedBox(height: 24),
            Text(
              l10n.nearbyOrPaste,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _codeField,
              keyboardType: TextInputType.number,
              style: const TextStyle(
                  color: AppColors.textPrimary, letterSpacing: 2),
              decoration: InputDecoration(
                hintText: l10n.btReceiveCodePrompt,
                hintStyle: const TextStyle(color: AppColors.textSecondary),
                errorText: _codeError,
                filled: true,
                fillColor: AppColors.glassFillStrong,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: AppColors.glassBorder),
                ),
              ),
              onSubmitted: (_) => _useTypedCode(),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: _useTypedCode,
              icon: const Icon(Icons.download_rounded),
              label: Text(l10n.codeReceiveReceiveButton),
            ),
          ],
        );

      case _Phase.waiting:
        return TransferPhaseLoader(
          phaseLabel: l10n.btReceiveWaitingToBeChosen,
          detail: l10n.btReceiveWaitingDetail,
          icon: Icons.bluetooth_connected_rounded,
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

/// The receiver side of the rendezvous' signal channel.
///
/// Directives come in over the metadata characteristic; the receiver never
/// sends one — it does not decide who hosts, it is told. What goes out is
/// the credentials of the network it was asked to raise.
class _ReceiverLinkSignal implements DirectLinkSignal {
  final BleReceiver _transport;

  _ReceiverLinkSignal(this._transport);

  @override
  Future<void> sendDirective(DirectLinkDirective directive) =>
      throw UnsupportedError('a receiver sends no directives');

  @override
  Stream<DirectLinkDirective> get directives => _transport.linkDirectives;

  @override
  Future<void> sendApOffer(String sealed) => _transport.sendApOffer(sealed);

  @override
  Stream<String> get apOffers => const Stream.empty();

  @override
  Future<void> sendKeyExchange(String publicKey) =>
      _transport.sendKeyExchange(publicKey);

  /// The sender's public half arrives inside the directive, not on a channel
  /// of its own — it is already travelling that way and one frame is one
  /// fewer thing to lose.
  @override
  Stream<String> get peerKeys => const Stream.empty();
}
