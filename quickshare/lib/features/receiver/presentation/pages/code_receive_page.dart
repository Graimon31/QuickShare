import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/network/app_presence.dart';
import 'package:quickshare/core/network/lan_discovery.dart';
import 'package:quickshare/core/network/network_info_service.dart';
import 'package:quickshare/core/network/session_code.dart';
import 'package:quickshare/core/network/session_tls_identity.dart';
import 'package:quickshare/core/utils/app_logger.dart';
import 'package:quickshare/shared/models/qr_payload.dart';
import 'package:quickshare/shared/widgets/nearby_devices_panel.dart';
import 'package:quickshare/features/receiver/presentation/bloc/receiver_bloc.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';
import 'package:quickshare/l10n/gen/app_localizations.dart';

class CodeReceivePage extends StatefulWidget {
  final String? initialCode;
  const CodeReceivePage({super.key, this.initialCode});

  @override
  State<CodeReceivePage> createState() => _CodeReceivePageState();
}

class _CodeReceivePageState extends State<CodeReceivePage> {
  final _controller = TextEditingController();

  /// The app's own presence, not one of this screen's making: being
  /// discoverable is not a property of standing on this page, and the typed
  /// code is matched against the same list the panel draws.
  String? _inputError;
  SessionCode? _failedCode;
  bool _isSubmitting = false;

  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    // initialCode: ten digits, or a directdrop://join?p=<payload> link.
    if (widget.initialCode != null && widget.initialCode!.isNotEmpty) {
      _controller.text = widget.initialCode!;
      WidgetsBinding.instance.addPostFrameCallback((_) => _submit());
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _reset() {
    setState(() {
      _controller.clear();
      _inputError = null;
      _failedCode = null;
      _isSubmitting = false;
    });
  }

  Future<void> _submit() async {
    if (_isSubmitting) return;
    final raw = _controller.text.trim();
    if (raw.isEmpty) {
      setState(() =>
          _inputError = AppLocalizations.of(context).codeReceivePasteError);
      return;
    }
    setState(() {
      _isSubmitting = true;
      _inputError = null;
      _failedCode = null;
    });

    // Ten digits mean a device in this room rather than a link from somewhere
    // else, and those are resolved against what is on the network rather than
    // parsed — there is nothing inside a code but the code.
    final code = SessionCode.parse(raw);
    if (code != null) {
      await _startFromCode(code);
      return;
    }

    try {
      if (!mounted) return;
      // The full pasted string so `n`/`s`/`c` preview fields survive; the
      // bloc routes it to QHTP or the serverless WebRTC path.
      context.read<ReceiverBloc>().add(QRCodeScanned(raw, fromPaste: true));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _inputError = AppLocalizations.of(context).codeReceiveParseError;
      });
    }
  }


  /// Finds the device offering [code] and starts collecting from it.
  ///
  /// The code is never sent anywhere. Each side derives the same two things
  /// from it — a public identifier, which the sender advertises, and the
  /// session token, which authenticates the fetch — so matching one against
  /// the network is enough to open a session that nobody else can.
  /// Finds the device offering [code] and starts collecting from it.
  ///
  /// The code is never sent anywhere. Each side derives the same two things
  /// from it — a public identifier, which the sender advertises, and the
  /// session token, which authenticates the fetch — so matching one against
  /// the network is enough to open a session that nobody else can.
  ///
  /// If mDNS TXT record is delayed, stale, or cached, this falls back to probing
  /// candidate peers directly over LAN with the bearer token to verify authorship.
  Future<void> _startFromCode(SessionCode code) async {
    final l10n = AppLocalizations.of(context);
    AppLogger.info('Resolving session code: publicId=${code.publicId}', tag: 'CODE');

    final presence = AppPresence.instance.presence;
    DiscoveredPeer? match = (presence?.current ?? const [])
        .where((peer) => peer.sessionPublicId == code.publicId)
        .firstOrNull;

    if (match == null) {
      if (presence != null) {
        unawaited(presence.refresh());
      }

      // Collect candidate IP addresses and ports to probe
      final candidateAddresses = <InternetAddress>{};
      final candidatePorts = <InternetAddress, Set<int>>{};

      for (final peer in presence?.current ?? const <DiscoveredPeer>[]) {
        if (!peer.address.isLoopback) {
          candidateAddresses.add(peer.address);
          candidatePorts.putIfAbsent(peer.address, () => {}).addAll([
            if (peer.port > 0) peer.port,
            AppConstants.serverPortMin, // 8000
            AppConstants.serverPortMin + 1, // 8001
          ]);
        }
      }

      // Also gather the local subnet candidate IPs (e.g. 192.168.3.1)
      try {
        final localIp = await NetworkInfoService().getLocalIpAddress();
        if (localIp != null && localIp.isNotEmpty) {
          final lastDot = localIp.lastIndexOf('.');
          if (lastDot != -1) {
            final prefix = localIp.substring(0, lastDot);
            final gw = InternetAddress.tryParse('$prefix.1');
            if (gw != null && !candidateAddresses.contains(gw)) {
              candidateAddresses.add(gw);
              candidatePorts.putIfAbsent(gw, () => {}).add(AppConstants.serverPortMin);
            }
          }
        }
      } catch (_) {}

      QRPayload? directPayload;

      Future<QRPayload?> probeCandidates() async {
        for (final addr in candidateAddresses) {
          final ports = candidatePorts[addr] ?? {AppConstants.serverPortMin};
          for (final port in ports) {
            final payload = await _probeCandidate(addr, port, code);
            if (payload != null) return payload;
          }
        }
        return null;
      }

      try {
        final results = await Future.wait([
          if (presence != null)
            presence.peers
                .map((peers) => peers
                    .where((peer) => peer.sessionPublicId == code.publicId)
                    .firstOrNull)
                .where((peer) => peer != null)
                .first
                .timeout(const Duration(seconds: 4))
                .catchError((_) => null)
          else
            Future.value(null),
          probeCandidates(),
        ]);

        match = results[0] as DiscoveredPeer?;
        directPayload = results[1] as QRPayload?;
      } catch (_) {}

      if (directPayload != null) {
        if (!mounted) return;
        AppLogger.info(
          'Direct LAN probe matched session code with ${directPayload.ip}:${directPayload.port}',
          tag: 'CODE',
        );
        context
            .read<ReceiverBloc>()
            .add(QRCodeScanned(directPayload.encode(), fromPaste: true));
        return;
      }

      match ??= presence?.current
          .where((peer) => peer.sessionPublicId == code.publicId)
          .firstOrNull;
    }

    if (!mounted) return;

    if (match == null) {
      AppLogger.warning(
        'Sender with code ${code.publicId} not found via mDNS or direct probe',
        tag: 'CODE',
      );
      setState(() {
        _isSubmitting = false;
        _failedCode = code;
        _inputError = l10n.codeReceiveNotFoundLan;
      });
      return;
    }

    AppLogger.info(
      'Session code ${code.publicId} matched peer: ${match.name} at ${match.address.address}:${match.port}',
      tag: 'CODE',
    );

    final targetPeer = match;
    final client =
        HttpClient(context: SecurityContext(withTrustedRoots: false));
    client.connectionTimeout = const Duration(seconds: 4);
    client.badCertificateCallback = (X509Certificate cert, String host, int p) {
      if (targetPeer.tlsFingerprint.isEmpty) return true;
      return SessionTlsIdentity.fingerprintOf(cert.der) == targetPeer.tlsFingerprint;
    };

    try {
      final invitePort = AppPresence.instance.presence?.invitePort ?? 0;
      final uri = Uri.parse(
          'https://${targetPeer.address.address}:${targetPeer.port}/v2/invite/request');
      final request =
          await client.postUrl(uri).timeout(const Duration(seconds: 4));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({
        'code': code.code,
        'invitePort': invitePort,
      }));
      final response =
          await request.close().timeout(const Duration(seconds: 20));
      if (response.statusCode == HttpStatus.ok) {
        final bodyText = await response.transform(utf8.decoder).join();
        final data = jsonDecode(bodyText) as Map<String, dynamic>;
        if (data['outcome'] == 'accepted') {
          final token = data['token'] as String?;
          if (token != null && token.isNotEmpty && mounted) {
            final payload = QRPayload(
              version: AppConstants.qhtpPayloadVersion,
              ip: match.address.address,
              port: match.port,
              token: token,
              sessionId: data['sessionId'] as String? ?? token,
              mode: 'http-lan',
              tlsFingerprint: match.tlsFingerprint,
              itemCount: data['itemCount'] as int? ?? 1,
              fileSize: data['totalBytes'] as int? ?? 0,
            );
            context
                .read<ReceiverBloc>()
                .add(QRCodeScanned(payload.encode(), fromPaste: true));
            return;
          }
        } else {
          if (!mounted) return;
          setState(() {
            _isSubmitting = false;
            _failedCode = code;
            _inputError = l10n.inviteDeclined;
          });
          return;
        }
      } else {
        if (!mounted) return;
        setState(() {
          _isSubmitting = false;
          _failedCode = code;
          _inputError = l10n.codeReceiveNotFoundLan;
        });
        return;
      }
    } catch (e) {
      AppLogger.warning(
          'Could not request invite from ${match.address.address}:${match.port}: $e',
          tag: 'CODE');
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _failedCode = code;
        _inputError = l10n.inviteUnreachable;
      });
      return;
    } finally {
      client.close(force: true);
    }
  }

  Future<QRPayload?> _probeCandidate(
    InternetAddress address,
    int port,
    SessionCode code,
  ) async {
    final client = HttpClient(context: SecurityContext(withTrustedRoots: false));
    client.connectionTimeout = const Duration(milliseconds: 1500);
    String? tlsFingerprint;
    client.badCertificateCallback = (X509Certificate cert, String host, int p) {
      tlsFingerprint = SessionTlsIdentity.fingerprintOf(cert.der);
      return true;
    };

    try {
      final uri = Uri.parse('https://${address.address}:$port/v2/invite/request');
      final request =
          await client.postUrl(uri).timeout(const Duration(milliseconds: 1500));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({
        'code': code.code,
        'invitePort': 0,
      }));
      final response =
          await request.close().timeout(const Duration(milliseconds: 1500));
      if (response.statusCode == HttpStatus.ok && tlsFingerprint != null) {
        final bodyText = await response.transform(utf8.decoder).join();
        final data = jsonDecode(bodyText) as Map<String, dynamic>;
        final token = data['token'] as String?;
        if (token != null && token.isNotEmpty) {
          return QRPayload(
            version: AppConstants.qhtpPayloadVersion,
            ip: address.address,
            port: port,
            token: token,
            sessionId: data['sessionId'] as String? ?? token,
            mode: 'http-lan',
            tlsFingerprint: tlsFingerprint!,
            itemCount: data['itemCount'] as int? ?? 1,
            fileSize: data['totalBytes'] as int? ?? 0,
          );
        }
      }
    } catch (_) {
      // Not a matching QHTP server or port unreachable
    } finally {
      client.close(force: true);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: AppColors.voidBg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          l10n.codeReceiveTitle,
          style: GoogleFonts.inter(
              color: Colors.white, fontWeight: FontWeight.w600),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => context.go('/'),
        ),
      ),
      body: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 24.0),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 540),
              child: BlocConsumer<ReceiverBloc, ReceiverState>(
                listener: (context, state) {
                  if (state is QRParsed || state is ReceiverError) {
                    setState(() => _isSubmitting = false);
                  }
                  if (state is ReceiverError) {
                    setState(() => _inputError = state.message);
                  }
                },
                builder: (context, state) {
                  if (state is QRParsed) {
                    return _buildConfirm(context, l10n, state);
                  }
                  return _buildIdle(context, l10n);
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIdle(BuildContext context, AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Being on this screen is what makes this device receivable: the panel
        // announces it and answers invitations. Nothing here is tappable — a
        // listed device is one that can see *us*, and the transfer starts when
        // one of them asks.
        NearbyDevicesPanel(
          presence: AppPresence.instance.presence,
          onSelected: (peer) => _onPeerSelected(peer, l10n),
        ),
        const SizedBox(height: 24),
        Text(
          l10n.nearbyOrPaste,
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppColors.textSecondary,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          l10n.codeReceivePastePrompt,
          style: GoogleFonts.inter(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 14),
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: const Color.fromRGBO(255, 255, 255, 0.08),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: const Color.fromRGBO(255, 255, 255, 0.25),
                  width: 1,
                ),
              ),
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                autofocus: true,
                maxLines: 3,
                minLines: 1,
                style: GoogleFonts.firaCode(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  hintText: l10n.codeReceiveHint,
                  hintStyle: GoogleFonts.inter(
                      color: Colors.white.withValues(alpha: 0.40)),
                ),
                onSubmitted: (_) => _submit(),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () async {
                  final data = await Clipboard.getData(Clipboard.kTextPlain);
                  if (data?.text != null) {
                    setState(() => _controller.text = data!.text!);
                  }
                },
                icon: const Icon(Icons.paste_rounded,
                    size: 18, color: Colors.white),
                label: Text(l10n.codeReceivePasteButton,
                    style: GoogleFonts.inter(
                        color: Colors.white, fontWeight: FontWeight.w600)),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: const BorderSide(
                      color: Color.fromRGBO(255, 255, 255, 0.3)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _isSubmitting ? null : _submit,
                icon: _isSubmitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.download_rounded,
                        size: 18, color: Colors.white),
                label: Text(
                    _isSubmitting
                        ? l10n.codeReceiveSearchingLan
                        : l10n.codeReceiveReceiveButton,
                    style: GoogleFonts.inter(
                        color: Colors.white, fontWeight: FontWeight.w600)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  elevation: 6,
                ),
              ),
            ),
          ],
        ),
        if (_inputError != null) ...[
          const SizedBox(height: 16),
          Text(_inputError!,
              style: GoogleFonts.inter(color: AppColors.error, fontSize: 14)),
          if (_failedCode != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () {
                final code = _failedCode!;
                context.go(
                  '/receive/bluetooth'
                  '?token=${Uri.encodeQueryComponent(code.sessionToken)}'
                  '&cid=${Uri.encodeQueryComponent(code.publicId)}',
                );
              },
              icon: const Icon(Icons.bluetooth_searching,
                  size: 18, color: AppColors.primary),
              label: Text(
                l10n.codeReceiveTryBluetooth,
                style: GoogleFonts.inter(
                    color: AppColors.primary, fontWeight: FontWeight.w600),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppColors.primary),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                padding:
                    const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
              ),
            ),
          ],
        ],
      ],
    );
  }

  Widget _buildConfirm(
      BuildContext context, AppLocalizations l10n, QRParsed state) {
    final payload = state.payload;
    final preview = state.qhtpPreview;
    final itemCount = preview?.itemCount ?? payload.itemCount;
    final sizeBytes = preview?.totalBytes ?? payload.fileSize;
    final isMany = itemCount > 1;
    final title = payload.fileName.isNotEmpty
        ? payload.fileName
        : (itemCount > 0
            ? l10n.sharedItemsCount(itemCount)
            : l10n.codeReceiveIncomingTransfer);
    final sizeBits = <String>[
      if (itemCount > 1) l10n.sharedItemsCount(itemCount),
      if (sizeBytes > 0)
        FileMetadata(name: '', path: '', size: sizeBytes, mimeType: '')
            .sizeFormatted,
    ];
    final sizeLabel = sizeBits.isNotEmpty
        ? sizeBits.join(' · ')
        : l10n.codeReceiveSizeUnknown;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.codeReceiveFileFound,
          style: GoogleFonts.inter(
              fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white),
        ),
        const SizedBox(height: 14),
        ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color.fromRGBO(255, 255, 255, 0.08),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.success, width: 1.5),
              ),
              child: Row(
                children: [
                  Icon(
                    isMany
                        // A folder now arrives as a folder, so it should not
                        // be announced with an archive icon.
                        ? Icons.folder_rounded
                        : Icons.insert_drive_file_rounded,
                    color: AppColors.success,
                    size: 38,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: GoogleFonts.inter(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Colors.white),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          sizeLabel,
                          style: GoogleFonts.inter(
                              fontSize: 14,
                              color: Colors.white.withValues(alpha: 0.70)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () {
                  context.read<ReceiverBloc>().add(CancelDownload());
                  _reset();
                },
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: const BorderSide(
                      color: Color.fromRGBO(255, 255, 255, 0.3)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
                child: Text(l10n.commonCancel,
                    style: GoogleFonts.inter(
                        color: Colors.white, fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton(
                onPressed: () {
                  if (_isSubmitting) return;
                  setState(() => _isSubmitting = true);
                  context.go(
                    '/receive/download',
                    extra: {'payload': state.payload},
                  );
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.secondaryDark,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  elevation: 6,
                ),
                child: Text(l10n.codeReceiveDownloadButton,
                    style: GoogleFonts.inter(
                        color: Colors.white, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ],
    );
  }

  void _onPeerSelected(DiscoveredPeer peer, AppLocalizations l10n) {
    if (peer.isServing) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              '${peer.name}: ${l10n.codeReceivePastePrompt.toLowerCase()}',
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      _focusNode.requestFocus();
    } else {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              '${peer.name} ${l10n.nearbyIdle.toLowerCase()}',
            ),
            duration: const Duration(seconds: 3),
          ),
        );
    }
  }
}
