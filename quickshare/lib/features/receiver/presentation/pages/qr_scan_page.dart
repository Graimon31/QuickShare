import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:quickshare/features/receiver/presentation/bloc/receiver_bloc.dart';
import 'package:quickshare/shared/widgets/scan_overlay.dart';
import 'package:go_router/go_router.dart';
import 'package:quickshare/core/di/service_locator.dart';
import 'package:quickshare/core/permissions/permission_service.dart';
import 'package:quickshare/shared/models/bluetooth_qr_payload.dart';
import 'package:quickshare/core/theme/app_colors.dart';
import 'package:quickshare/core/theme/app_motion.dart';
import 'package:quickshare/shared/widgets/transfer_phase_loader.dart';

class QRScanPage extends StatefulWidget {
  const QRScanPage({super.key});

  @override
  State<QRScanPage> createState() => _QRScanPageState();
}

class _QRScanPageState extends State<QRScanPage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  MobileScannerController? cameraController;
  AnimationController? _animationController;
  CurvedAnimation? _scanAnimation;
  late final AnimationController _successController;
  bool _isProcessing = false;
  bool _isClosing = false;
  bool _isLocked = false;
  bool _reduceMotion = false;
  bool _cameraReleaseStarted = false;
  String? _statusHint;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _successController = AnimationController(
      vsync: this,
      duration: AppMotion.scanSuccess,
    );
    _initScanner();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!_isClosing && !_isProcessing) {
        _resumeCamera();
      }
      return;
    }

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _pauseCamera();
    }
  }

  Future<void> _initScanner() async {
    final granted = await sl<PermissionService>().requestCamera();
    if (!granted) {
      if (mounted && !_isClosing) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Camera permission required')));
        _closeScanner();
      }
      return;
    }
    if (!mounted || _isClosing) return;
    _reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    setState(() {
      cameraController = MobileScannerController(
        formats: const [BarcodeFormat.qrCode],
        detectionSpeed: DetectionSpeed.noDuplicates,
        detectionTimeoutMs: 500,
        returnImage: false,
      );
      _animationController =
          AnimationController(vsync: this, duration: AppMotion.scanCycle);
      _scanAnimation = CurvedAnimation(
        parent: _animationController!,
        curve: AppMotion.scanCurve,
      );
    });
    if (!_reduceMotion) _animationController?.repeat(reverse: true);
    if (mounted) context.read<ReceiverBloc>().add(StartScanning());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _isClosing = true;
    unawaited(_releaseCamera());
    _scanAnimation?.dispose();
    _animationController?.dispose();
    _successController.dispose();
    super.dispose();
  }

  void _closeScanner() => _navigateAfterCameraRelease('/');

  void _openCodeEntry() => _navigateAfterCameraRelease('/receive/code');

  void _navigateAfterCameraRelease(String location, {Object? extra}) {
    if (_isClosing) return;

    _isClosing = true;
    _isProcessing = true;
    _animationController?.stop();
    unawaited(_releaseCamera());

    if (mounted) {
      if (extra != null) {
        context.go(location, extra: extra);
      } else {
        context.go(location);
      }
    }
  }

  Future<void> _releaseCamera() async {
    if (_cameraReleaseStarted) return;
    _cameraReleaseStarted = true;

    final controller = cameraController;
    cameraController = null;
    if (controller == null) return;

    try {
      await controller.stop();
    } catch (_) {
    } finally {
      try {
        await controller.dispose();
      } catch (_) {}
    }
  }

  void _pauseCamera() {
    final controller = cameraController;
    if (controller == null || _cameraReleaseStarted) return;
    unawaited(_stopCamera(controller));
  }

  Future<void> _stopCamera(MobileScannerController controller) async {
    try {
      await controller.stop();
    } catch (_) {}
  }

  void _resumeCamera() {
    final controller = cameraController;
    if (_isClosing || _cameraReleaseStarted || controller == null) return;
    unawaited(_startCamera(controller));
  }

  Future<void> _startCamera(MobileScannerController controller) async {
    try {
      await controller.start();
    } catch (_) {}
  }

  void _resetForRescan() {
    _isProcessing = false;
    _successController.reset();
    if (mounted) {
      setState(() {
        _isLocked = false;
        _statusHint = null;
      });
    }
    _resumeCamera();
    if (!_reduceMotion) {
      _animationController?.repeat(reverse: true);
    }
  }

  void _onDetect(BarcodeCapture capture) {
    if (!mounted || _isClosing || _isProcessing) return;

    String? rawValue;
    for (final barcode in capture.barcodes) {
      // iOS Vision sometimes fills displayValue but leaves rawValue null.
      final value = barcode.rawValue ?? barcode.displayValue;
      if (value != null && value.trim().isNotEmpty) {
        rawValue = value.trim();
        break;
      }
    }
    if (rawValue == null) return;

    _isProcessing = true;
    setState(() {
      _isLocked = true;
      _statusHint = 'QR detected — opening transfer…';
    });
    _animationController?.stop();
    unawaited(_successController.forward(from: 0));
    HapticFeedback.mediumImpact();
    _pauseCamera();

    final bluetoothPayload = BluetoothQrPayload.tryDecode(rawValue);
    if (bluetoothPayload != null) {
      unawaited(_openBluetoothAfterSuccess(bluetoothPayload.token));
      return;
    }

    // Parse is local (no network). Navigation happens in the Bloc listener
    // as soon as QRParsed / ReceiverError is emitted.
    context.read<ReceiverBloc>().add(QRCodeScanned(rawValue));
  }

  Future<void> _openBluetoothAfterSuccess(String token) async {
    await Future<void>.delayed(AppMotion.scanSuccess);
    if (!mounted || _isClosing) return;
    _navigateAfterCameraRelease(
      '/receive/bluetooth?token=${Uri.encodeQueryComponent(token)}',
    );
  }

  Future<void> _openPreviewAfterParse() async {
    // Brief success flash, then leave the scanner. Do not await a long
    // animation — the user already waited for the camera lock.
    if (_successController.status != AnimationStatus.completed) {
      await _successController.forward();
    }
    if (!mounted || _isClosing) return;
    // No extra — TransferPreviewPage reads QRParsed from ReceiverBloc.
    _navigateAfterCameraRelease('/receive/preview');
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _closeScanner();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: BlocConsumer<ReceiverBloc, ReceiverState>(
          listenWhen: (prev, next) =>
              next is QRParsed || next is ReceiverError,
          listener: (context, state) {
            if (!mounted || _isClosing) return;

            if (state is QRParsed) {
              if (state.payload.mode == 'internet' || state.payload.ip == 'webrtc') {
                _navigateAfterCameraRelease('/receive/code?room=${state.payload.token}');
              } else {
                unawaited(_openPreviewAfterParse());
              }
            } else if (state is ReceiverError) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(state.message),
                  backgroundColor: AppColors.error,
                  behavior: SnackBarBehavior.floating,
                  duration: const Duration(seconds: 4),
                ),
              );
              _resetForRescan();
              context.read<ReceiverBloc>().add(StartScanning());
            }
          },
          builder: (context, state) {
            if (cameraController == null || _scanAnimation == null) {
              return const Center(
                child: TransferPhaseLoader(
                  phaseLabel: 'Preparing camera…',
                  detail: 'Camera access is being initialized',
                  icon: Icons.camera_alt_outlined,
                ),
              );
            }
            return Stack(
              children: [
                MobileScanner(
                  controller: cameraController!,
                  onDetect: _onDetect,
                  errorBuilder: (context, error, child) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'Camera error: ${error.errorCode.name}\n'
                          'Try closing and opening Receive again.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                    );
                  },
                ),
                ScanOverlay(
                  scanAnimation: _scanAnimation!,
                  successAnimation: _successController,
                  isSuccess: _isLocked,
                  reduceMotion: _reduceMotion,
                ),
                Positioned(
                  top: 50,
                  left: 20,
                  right: 20,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.close,
                            color: Colors.white, size: 30),
                        onPressed: _closeScanner,
                      ),
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          backgroundColor: AppColors.voidBg.withValues(alpha: 0.72),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20)),
                        ),
                        onPressed: _openCodeEntry,
                        icon: const Icon(Icons.keyboard, color: Colors.white),
                        label: const Text('Enter Code'),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  bottom: 50,
                  left: 16,
                  right: 16,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_statusHint != null) ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                          decoration: BoxDecoration(
                            color: AppColors.voidBg.withValues(alpha: 0.85),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: AppColors.primary),
                          ),
                          child: Text(
                            _statusHint!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          IconButton(
                            icon: ValueListenableBuilder<MobileScannerState>(
                              valueListenable: cameraController!,
                              builder: (context, state, child) {
                                return Icon(
                                  state.torchState == TorchState.on
                                      ? Icons.flash_on
                                      : Icons.flash_off,
                                  color: Colors.white,
                                  size: 30,
                                );
                              },
                            ),
                            onPressed: () => cameraController!.toggleTorch(),
                          ),
                          const Flexible(
                            child: Text(
                              'Point camera at the QR code',
                              textAlign: TextAlign.center,
                              style:
                                  TextStyle(color: Colors.white, fontSize: 15),
                            ),
                          ),
                          if (defaultTargetPlatform != TargetPlatform.iOS)
                            IconButton(
                              icon: const Icon(Icons.flip_camera_ios,
                                  color: Colors.white, size: 30),
                              onPressed: () =>
                                  cameraController!.switchCamera(),
                            )
                          else
                            const SizedBox(width: 48),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
