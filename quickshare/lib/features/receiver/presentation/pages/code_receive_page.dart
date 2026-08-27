import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:quickshare/core/constants/app_constants.dart';
import 'package:quickshare/core/deep_link/deep_link_service.dart';
import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/features/receiver/data/transports/webrtc_receiver_transport.dart';
import 'package:quickshare/features/receiver/presentation/bloc/receiver_bloc.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';
import 'package:quickshare/shared/widgets/progress_indicator_widget.dart';
import 'package:quickshare/shared/widgets/transfer_phase_loader.dart';

class CodeReceivePage extends StatefulWidget {
  final String? initialCode;
  const CodeReceivePage({super.key, this.initialCode});

  @override
  State<CodeReceivePage> createState() => _CodeReceivePageState();
}

enum _Phase {
  idle,
  internetConnecting,
  internetTransferring,
  internetDone,
  internetFailed
}

class _CodeReceivePageState extends State<CodeReceivePage> {
  final _controller = TextEditingController();
  _Phase _phase = _Phase.idle;
  WebRtcReceiverTransport? _internetTransport;
  String? _inputError;

  String _fileName = '';
  int _received = 0;
  int _total = 0;
  int _speedBps = 0;
  String? _savedPath;
  String? _internetError;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    // initialCode: bare room, or full quickshare://join?room=&sig=
    if (widget.initialCode != null && widget.initialCode!.isNotEmpty) {
      _controller.text = widget.initialCode!;
      WidgetsBinding.instance.addPostFrameCallback((_) => _submit());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _internetTransport?.cancel();
    super.dispose();
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

  Future<void> _submit() async {
    if (_isSubmitting || _phase != _Phase.idle) return;
    final raw = _controller.text.trim();
    if (raw.isEmpty) {
      setState(() => _inputError = 'Paste the share link from the sender.');
      return;
    }
    setState(() {
      _isSubmitting = true;
      _inputError = null;
    });

    try {
      // Payload links (`?p=`) also use the directdrop scheme. Check those
      // first so a share is not mistaken for a legacy six-character room.
      if (DeepLinkService.parseShareLink(raw) == null) {
        final invite = DeepLinkService.parseInternetInvite(raw);
        if (invite != null) {
          await _startInternet(invite.roomCode,
              signalingUrl: invite.signalingUrl);
          return;
        }
      }

      if (!mounted) return;
      // Pass the full pasted string so `n`/`s`/`c` preview fields survive.
      context.read<ReceiverBloc>().add(QRCodeScanned(raw, fromPaste: true));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _inputError =
            'Could not read that link. Copy the share link under the QR on the sender.';
      });
    }
  }

  Future<void> _startInternet(String roomCode, {String? signalingUrl}) async {
    setState(() {
      _phase = _Phase.internetConnecting;
      _internetError = null;
      _fileName = '';
      _received = 0;
      _total = 0;
      _speedBps = 0;
    });

    final transport = WebRtcReceiverTransport();
    _internetTransport = transport;

    transport.progressStream.listen((p) {
      if (!mounted) return;
      setState(() {
        // Keep connecting UI until real bytes / file-meta arrive.
        switch (p.phase) {
          case 'completed':
            _phase = _Phase.internetDone;
            break;
          case 'failed':
            _phase = _Phase.internetFailed;
            _internetError = p.detail;
            break;
          case 'transferring':
            _phase = _Phase.internetTransferring;
            break;
          default:
            _phase = _Phase.internetConnecting;
        }
        if (p.fileName.isNotEmpty) _fileName = p.fileName;
        _received = p.received;
        _total = p.total;
        _speedBps = p.speedBps;
        if (p.detail != null && p.phase == 'connecting') {
          // Surface live status under the loader via phase detail path.
        }
      });
    });

    try {
      final path = await transport.receive(
        roomCode,
        signalingUrl: signalingUrl,
      );
      if (mounted) {
        setState(() {
          _phase = _Phase.internetDone;
          _savedPath = path;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.internetFailed;
          _internetError = e.toString().replaceAll('Exception: ', '');
          _isSubmitting = false;
        });
      }
    }
  }

  void _reset() {
    setState(() {
      _phase = _Phase.idle;
      _controller.clear();
      _internetError = null;
      _savedPath = null;
      _isSubmitting = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.voidBg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Receive a file',
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
              child: _phase == _Phase.idle
                  ? BlocConsumer<ReceiverBloc, ReceiverState>(
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
                          return _buildConfirm(context, state);
                        }
                        return _buildIdle(context);
                      },
                    )
                  : _buildInternetBody(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIdle(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Paste a code or share link',
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
                autofocus: true,
                maxLines: 3,
                minLines: 1,
                style: GoogleFonts.firaCode(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  hintText: 'directdrop://join?p=…',
                  hintStyle:
                      GoogleFonts.inter(color: Colors.white.withValues(alpha: 0.40)),
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
                label: Text('Paste',
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
                icon: const Icon(Icons.download_rounded,
                    size: 18, color: Colors.white),
                label: Text('Receive',
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
        ],
        if (defaultTargetPlatform == TargetPlatform.macOS) ...[
          const SizedBox(height: 24),
          Center(
            child: TextButton.icon(
              onPressed: () => context.push('/receive/bluetooth'),
              icon: const Icon(Icons.bluetooth_searching,
                  size: 18, color: AppColors.primary),
              label: Text(
                'Look for nearby devices instead',
                style:
                    GoogleFonts.inter(color: AppColors.primary, fontSize: 14),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildConfirm(BuildContext context, QRParsed state) {
    final payload = state.payload;
    final preview = state.qhtpPreview;
    final itemCount = preview?.itemCount ?? payload.itemCount;
    final sizeBytes = preview?.totalBytes ?? payload.fileSize;
    final isMany = itemCount > 1;
    final title = payload.fileName.isNotEmpty
        ? payload.fileName
        : (itemCount > 0
            ? '$itemCount ${itemCount == 1 ? 'file' : 'files'}'
            : 'Incoming transfer');
    final sizeBits = <String>[
      if (itemCount > 1) '$itemCount files',
      if (sizeBytes > 0)
        FileMetadata(name: '', path: '', size: sizeBytes, mimeType: '')
            .sizeFormatted,
    ];
    final sizeLabel = sizeBits.isNotEmpty
        ? sizeBits.join(' · ')
        : 'Size unknown until the transfer starts';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'File found',
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
                        ? Icons.folder_zip_rounded
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
                child: Text('Cancel',
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
                child: Text('Download',
                    style: GoogleFonts.inter(
                        color: Colors.white, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildInternetBody(BuildContext context) {
    switch (_phase) {
      case _Phase.internetConnecting:
        return TransferPhaseLoader(
          phaseLabel: 'Connecting to sender…',
          detail: _internetError ??
              'Keep the Mac on the Share screen. Same Wi‑Fi required for local signaling; LTE needs a public signaling + TURN server.',
          icon: Icons.public_rounded,
        );

      case _Phase.internetTransferring:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CustomProgressIndicator(
              progress: _total > 0 ? _received / _total : 0,
              speedBytesPerSec: _speedBps.toDouble(),
              fileName: _fileName,
              progressColor: AppColors.primary,
              speedColor: Colors.white.withValues(alpha: 0.75),
            ),
            const SizedBox(height: 12),
            Text(
              '${_fmt(_received)}${_total > 0 ? ' / ${_fmt(_total)}' : ''}'
              '${_speedBps > 0 ? '  ·  ${_fmt(_speedBps)}/s' : ''}',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                  fontSize: 14, color: Colors.white.withValues(alpha: 0.75)),
            ),
          ],
        );

      case _Phase.internetDone:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.check_circle_rounded,
                size: 72, color: AppColors.success),
            const SizedBox(height: 16),
            Text(
              'File received',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.white),
            ),
            const SizedBox(height: 8),
            Text(
              _fileName,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                  fontSize: 16, color: Colors.white.withValues(alpha: 0.9)),
            ),
            if (_savedPath != null) ...[
              const SizedBox(height: 6),
              Text(
                _savedPath!,
                textAlign: TextAlign.center,
                style: GoogleFonts.firaCode(
                    fontSize: 12, color: Colors.white.withValues(alpha: 0.50)),
              ),
            ],
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => context.go('/'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.secondaryDark,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
              ),
              child: Text('Done',
                  style: GoogleFonts.inter(
                      color: Colors.white, fontWeight: FontWeight.w600)),
            ),
          ],
        );

      case _Phase.internetFailed:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.error_outline_rounded,
                size: 72, color: AppColors.error),
            const SizedBox(height: 16),
            Text(
              'Transfer failed',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.white),
            ),
            const SizedBox(height: 8),
            Text(
              _internetError != null &&
                      (_internetError!.contains('Signaling') ||
                          _internetError!.contains('Cannot reach'))
                  ? 'Signaling server unreachable (${AppConstants.signalingServerUrl}). Specify a remote server using:\n--dart-define=QUICKSHARE_SIGNALING_URL=wss://your-server.com'
                  : (_internetError ?? 'Unknown error'),
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                  fontSize: 14, color: Colors.white.withValues(alpha: 0.70)),
            ),
            const SizedBox(height: 24),
            OutlinedButton(
              onPressed: _reset,
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                side: const BorderSide(color: AppColors.error),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
              ),
              child: Text(
                'Try another code',
                style: GoogleFonts.inter(
                    color: AppColors.error, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        );

      case _Phase.idle:
        return const SizedBox.shrink();
    }
  }
}
