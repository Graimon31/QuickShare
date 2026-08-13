import os

base_dir = os.path.dirname(os.path.abspath(__file__))

files = {
    "lib/features/receiver/domain/entities/download_session.dart": """import 'package:equatable/equatable.dart';
import 'package:quickshare/shared/models/qr_payload.dart';

enum DownloadStatus { idle, connecting, downloading, verifying, completed, failed, cancelled }

class DownloadSession extends Equatable {
  final String id;
  final QRPayload payload;
  final String? localSavePath;
  final int downloadedBytes;
  final int totalBytes;
  final DownloadStatus status;
  final DateTime? startedAt;

  const DownloadSession({
    required this.id,
    required this.payload,
    this.localSavePath,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.status = DownloadStatus.idle,
    this.startedAt,
  });

  double get progressPercent => totalBytes > 0 ? downloadedBytes / totalBytes : 0.0;

  @override
  List<Object?> get props => [
        id,
        payload,
        localSavePath,
        downloadedBytes,
        totalBytes,
        status,
        startedAt,
      ];
}
""",
    "lib/features/receiver/domain/repositories/receiver_repository.dart": """import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/shared/models/qr_payload.dart';

abstract class ReceiverRepository {
  Future<Either<Failure, QRPayload>> parseQRCode(String rawData);
  Future<Either<Failure, bool>> checkServerAvailability(String ip, int port, String token);
  Future<Either<Failure, String>> downloadFile(QRPayload payload, {void Function(int received, int total)? onProgress});
  Future<Either<Failure, bool>> verifyChecksum(String filePath, String expectedChecksum);
  Future<Either<Failure, String>> saveToFinalLocation(String tempPath, String fileName);
}
""",
    "lib/features/receiver/domain/usecases/download_file_usecase.dart": """import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/shared/models/qr_payload.dart';
import 'package:quickshare/features/receiver/domain/repositories/receiver_repository.dart';

class DownloadFileUseCase {
  final ReceiverRepository repository;

  DownloadFileUseCase(this.repository);

  Future<Either<Failure, String>> call(QRPayload payload, {void Function(int received, int total)? onProgress}) async {
    final serverCheck = await repository.checkServerAvailability(payload.ip, payload.port, payload.token);
    if (serverCheck is Left) return Left((serverCheck as Left<Failure, bool>).value);

    final downloadResult = await repository.downloadFile(payload, onProgress: onProgress);
    if (downloadResult is Left) return Left((downloadResult as Left<Failure, String>).value);

    final tempPath = (downloadResult as Right<Failure, String>).value;

    final verifyResult = await repository.verifyChecksum(tempPath, payload.checksum);
    if (verifyResult is Left) return Left((verifyResult as Left<Failure, bool>).value);

    return repository.saveToFinalLocation(tempPath, payload.fileName);
  }
}
""",
    "lib/features/receiver/data/client/http_file_downloader.dart": """import 'dart:io';
import 'package:dio/dio.dart';
import 'package:quickshare/core/errors/exceptions.dart';

class HttpFileDownloader {
  final Dio dio;

  HttpFileDownloader({Dio? dioClient}) : dio = dioClient ?? Dio() {
    dio.options.connectTimeout = const Duration(seconds: 3);
    dio.options.receiveTimeout = const Duration(seconds: 0);
  }

  Future<String> download({
    required String url,
    required String token,
    required String savePath,
    void Function(int, int)? onProgress,
  }) async {
    int attempts = 0;
    while (attempts < 3) {
      try {
        await dio.download(
          url,
          savePath,
          options: Options(
            headers: {'Authorization': 'Bearer $token'},
          ),
          onReceiveProgress: onProgress,
        );
        return savePath;
      } on DioException catch (e) {
        attempts++;
        if (attempts >= 3) {
          throw NetworkException('Download failed after 3 attempts: ${e.message}');
        }
        await Future.delayed(Duration(seconds: attempts));
      } catch (e) {
        throw ServerException('Unknown error during download: $e');
      }
    }
    throw NetworkException('Download failed');
  }
}
""",
    "lib/features/receiver/data/qr/qr_payload_decoder.dart": """import 'package:quickshare/shared/models/qr_payload.dart';
import 'package:quickshare/core/errors/exceptions.dart';

class QRPayloadDecoder {
  QRPayload decode(String rawQRData) {
    try {
      final payload = QRPayload.decode(rawQRData);
      if (payload.ip.isEmpty || payload.port <= 0 || payload.token.isEmpty || payload.fileName.isEmpty || payload.fileSize <= 0) {
         throw Exception('Invalid payload fields');
      }
      return payload;
    } catch (e) {
      throw ServerException('Invalid QR Code data: $e');
    }
  }
}
""",
    "lib/features/receiver/data/repositories/receiver_repository_impl.dart": """import 'dart:io';
import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:quickshare/core/utils/either.dart';
import 'package:quickshare/core/errors/failures.dart';
import 'package:quickshare/core/errors/exceptions.dart';
import 'package:quickshare/shared/models/qr_payload.dart';
import 'package:quickshare/features/receiver/domain/repositories/receiver_repository.dart';
import 'package:quickshare/features/receiver/data/client/http_file_downloader.dart';
import 'package:quickshare/features/receiver/data/qr/qr_payload_decoder.dart';

class ReceiverRepositoryImpl implements ReceiverRepository {
  final HttpFileDownloader downloader;
  final QRPayloadDecoder decoder;
  final Dio dio;

  ReceiverRepositoryImpl({
    required this.downloader,
    required this.decoder,
    Dio? dioClient,
  }) : dio = dioClient ?? Dio();

  @override
  Future<Either<Failure, QRPayload>> parseQRCode(String rawData) async {
    try {
      final payload = decoder.decode(rawData);
      return Right(payload);
    } catch (e) {
      return Left(FileFailure('Invalid QR Code'));
    }
  }

  @override
  Future<Either<Failure, bool>> checkServerAvailability(String ip, int port, String token) async {
    try {
      final response = await dio.head(
        'http://$ip:$port/download',
        options: Options(
          headers: {'Authorization': 'Bearer $token'},
          sendTimeout: const Duration(seconds: 3),
          receiveTimeout: const Duration(seconds: 3),
        ),
      );
      if (response.statusCode == 200) {
        return Right(true);
      }
      return Left(ServerFailure('Server not available'));
    } catch (e) {
      return Left(NetworkFailure('Connection failed: $e'));
    }
  }

  @override
  Future<Either<Failure, String>> downloadFile(QRPayload payload, {void Function(int received, int total)? onProgress}) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final tempPath = '${tempDir.path}/${payload.fileName}';
      final url = 'http://${payload.ip}:${payload.port}/download';
      
      final resultPath = await downloader.download(
        url: url,
        token: payload.token,
        savePath: tempPath,
        onProgress: onProgress,
      );
      return Right(resultPath);
    } catch (e) {
      return Left(NetworkFailure('Download failed: $e'));
    }
  }

  @override
  Future<Either<Failure, bool>> verifyChecksum(String filePath, String expectedChecksum) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return Left(FileFailure('File not found'));
      
      final stream = file.openRead();
      final hash = await sha256.bind(stream).first;
      
      if (hash.toString() == expectedChecksum) {
        return Right(true);
      }
      return Left(FileFailure('Checksum verification failed'));
    } catch (e) {
      return Left(FileFailure('Failed to verify checksum: $e'));
    }
  }

  @override
  Future<Either<Failure, String>> saveToFinalLocation(String tempPath, String fileName) async {
    try {
      final downloadDir = await getDownloadsDirectory();
      final finalDir = downloadDir?.path ?? '/storage/emulated/0/Download';
      final finalPath = '$finalDir/$fileName';
      
      final tempFile = File(tempPath);
      await tempFile.copy(finalPath);
      await tempFile.delete();
      
      return Right(finalPath);
    } catch (e) {
      return Left(FileFailure('Failed to save file: $e'));
    }
  }
}
""",
    "lib/features/receiver/presentation/bloc/receiver_bloc.dart": """import 'dart:async';
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:quickshare/shared/models/qr_payload.dart';
import 'package:quickshare/features/receiver/domain/usecases/download_file_usecase.dart';
import 'package:quickshare/features/receiver/domain/repositories/receiver_repository.dart';

abstract class ReceiverEvent extends Equatable {
  const ReceiverEvent();
  @override
  List<Object> get props => [];
}

class StartScanning extends ReceiverEvent {}
class QRCodeScanned extends ReceiverEvent {
  final String rawData;
  const QRCodeScanned(this.rawData);
  @override
  List<Object> get props => [rawData];
}
class StartDownload extends ReceiverEvent {}
class CancelDownload extends ReceiverEvent {}
class DownloadProgressUpdate extends ReceiverEvent {
  final int received;
  final int total;
  const DownloadProgressUpdate(this.received, this.total);
  @override
  List<Object> get props => [received, total];
}
class DownloadCompleted extends ReceiverEvent {
  final String filePath;
  const DownloadCompleted(this.filePath);
  @override
  List<Object> get props => [filePath];
}
class DownloadFailed extends ReceiverEvent {
  final String error;
  const DownloadFailed(this.error);
  @override
  List<Object> get props => [error];
}

abstract class ReceiverState extends Equatable {
  const ReceiverState();
  @override
  List<Object?> get props => [];
}

class ReceiverInitial extends ReceiverState {}
class Scanning extends ReceiverState {}
class QRParsed extends ReceiverState {
  final QRPayload payload;
  const QRParsed(this.payload);
  @override
  List<Object> get props => [payload];
}
class Connecting extends ReceiverState {}
class Downloading extends ReceiverState {
  final double progress;
  final int speedBps;
  final String fileName;
  const Downloading(this.progress, this.speedBps, this.fileName);
  @override
  List<Object> get props => [progress, speedBps, fileName];
}
class Verifying extends ReceiverState {}
class DownloadComplete extends ReceiverState {
  final String filePath;
  final String fileName;
  const DownloadComplete(this.filePath, this.fileName);
  @override
  List<Object> get props => [filePath, fileName];
}
class ReceiverError extends ReceiverState {
  final String message;
  final bool canRetry;
  const ReceiverError(this.message, {this.canRetry = true});
  @override
  List<Object> get props => [message, canRetry];
}

class ReceiverBloc extends Bloc<ReceiverEvent, ReceiverState> {
  final DownloadFileUseCase downloadFileUseCase;
  final ReceiverRepository repository;
  QRPayload? _currentPayload;
  DateTime? _lastUpdate;
  int _lastReceived = 0;

  ReceiverBloc({required this.downloadFileUseCase, required this.repository}) : super(ReceiverInitial()) {
    on<StartScanning>((event, emit) => emit(Scanning()));
    
    on<QRCodeScanned>((event, emit) async {
      final result = await repository.parseQRCode(event.rawData);
      result.fold(
        (failure) => emit(const ReceiverError('Invalid QR Code')),
        (payload) {
          _currentPayload = payload;
          emit(QRParsed(payload));
        }
      );
    });

    on<StartDownload>((event, emit) async {
      if (_currentPayload == null) return;
      emit(Connecting());
      _lastUpdate = DateTime.now();
      _lastReceived = 0;
      
      final result = await downloadFileUseCase.call(
        _currentPayload!,
        onProgress: (received, total) {
          add(DownloadProgressUpdate(received, total));
        },
      );
      
      result.fold(
        (failure) => add(DownloadFailed(failure.message)),
        (path) => add(DownloadCompleted(path)),
      );
    });

    on<DownloadProgressUpdate>((event, emit) {
      if (_currentPayload == null) return;
      final now = DateTime.now();
      final diff = now.difference(_lastUpdate ?? now).inMilliseconds;
      int speed = 0;
      if (diff > 0) {
        speed = ((event.received - _lastReceived) / (diff / 1000)).round();
      }
      _lastUpdate = now;
      _lastReceived = event.received;
      
      final progress = event.total > 0 ? event.received / event.total : 0.0;
      if (progress >= 1.0) {
        emit(Verifying());
      } else {
        emit(Downloading(progress, speed, _currentPayload!.fileName));
      }
    });

    on<DownloadCompleted>((event, emit) {
      if (_currentPayload != null) {
        emit(DownloadComplete(event.filePath, _currentPayload!.fileName));
      }
    });

    on<DownloadFailed>((event, emit) {
      emit(ReceiverError(event.error));
    });

    on<CancelDownload>((event, emit) {
      _currentPayload = null;
      emit(ReceiverInitial());
    });
  }
}
""",
    "lib/features/receiver/presentation/pages/qr_scan_page.dart": """import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:quickshare/features/receiver/presentation/bloc/receiver_bloc.dart';
import 'package:quickshare/shared/widgets/scan_overlay.dart';
import 'package:quickshare/features/receiver/presentation/pages/download_progress_page.dart';

class QRScanPage extends StatefulWidget {
  const QRScanPage({Key? key}) : super(key: key);

  @override
  State<QRScanPage> createState() => _QRScanPageState();
}

class _QRScanPageState extends State<QRScanPage> with SingleTickerProviderStateMixin {
  late MobileScannerController cameraController;
  late AnimationController _animationController;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    cameraController = MobileScannerController();
    _animationController = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
    context.read<ReceiverBloc>().add(StartScanning());
  }

  @override
  void dispose() {
    cameraController.dispose();
    _animationController.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_isProcessing) return;
    final List<Barcode> barcodes = capture.barcodes;
    for (final barcode in barcodes) {
      if (barcode.rawValue != null) {
        _isProcessing = true;
        HapticFeedback.mediumImpact();
        context.read<ReceiverBloc>().add(QRCodeScanned(barcode.rawValue!));
        break;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: BlocConsumer<ReceiverBloc, ReceiverState>(
        listener: (context, state) {
          if (state is QRParsed) {
            cameraController.stop();
            showModalBottomSheet(
              context: context,
              builder: (ctx) => _buildFileBottomSheet(context, state),
              isDismissible: false,
            );
          } else if (state is ReceiverError) {
            _isProcessing = false;
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(state.message)));
          }
        },
        builder: (context, state) {
          return Stack(
            children: [
              MobileScanner(
                controller: cameraController,
                onDetect: _onDetect,
              ),
              ScanOverlay(
                animationController: _animationController,
                cutoutSize: 250,
                borderColor: Theme.of(context).primaryColor,
              ),
              Positioned(
                top: 50,
                left: 20,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 30),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
              Positioned(
                bottom: 50,
                left: 0,
                right: 0,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton(
                      icon: ValueListenableBuilder(
                        valueListenable: cameraController.torchState,
                        builder: (context, state, child) {
                          return Icon(
                            state == TorchState.on ? Icons.flash_on : Icons.flash_off,
                            color: Colors.white,
                            size: 30,
                          );
                        },
                      ),
                      onPressed: () => cameraController.toggleTorch(),
                    ),
                    const Text('Point camera at the QR code', style: TextStyle(color: Colors.white, fontSize: 16)),
                    IconButton(
                      icon: const Icon(Icons.flip_camera_ios, color: Colors.white, size: 30),
                      onPressed: () => cameraController.switchCamera(),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildFileBottomSheet(BuildContext context, QRParsed state) {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('File Detected', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          ListTile(
            leading: const Icon(Icons.insert_drive_file, size: 40),
            title: Text(state.payload.fileName),
            subtitle: Text('${(state.payload.fileSize / 1024 / 1024).toStringAsFixed(2)} MB'),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              TextButton(
                onPressed: () {
                  context.read<ReceiverBloc>().add(StartScanning());
                  _isProcessing = false;
                  cameraController.start();
                  Navigator.pop(context);
                },
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(context);
                  context.read<ReceiverBloc>().add(StartDownload());
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(builder: (_) => const DownloadProgressPage()),
                  );
                },
                child: const Text('Download'),
              ),
            ],
          )
        ],
      ).animate().slideY(begin: 1.0, end: 0.0).fadeIn(),
    );
  }
}
""",
    "lib/features/receiver/presentation/pages/download_progress_page.dart": """import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:quickshare/features/receiver/presentation/bloc/receiver_bloc.dart';
import 'package:quickshare/features/receiver/presentation/pages/complete_page.dart';
import 'package:quickshare/shared/widgets/progress_indicator_widget.dart';

class DownloadProgressPage extends StatelessWidget {
  const DownloadProgressPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        final confirm = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Cancel Download?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
              TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Yes')),
            ],
          ),
        );
        if (confirm == true) {
          context.read<ReceiverBloc>().add(CancelDownload());
        }
        return confirm ?? false;
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Downloading...')),
        body: BlocConsumer<ReceiverBloc, ReceiverState>(
          listener: (context, state) {
            if (state is DownloadComplete) {
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (_) => CompletePage(fileName: state.fileName, filePath: state.filePath)),
              );
            } else if (state is ReceiverError) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(state.message)));
              Navigator.pop(context);
            }
          },
          builder: (context, state) {
            if (state is Connecting) {
              return const Center(child: CircularProgressIndicator());
            } else if (state is Downloading) {
              return Center(
                child: CustomProgressIndicator(
                  progress: state.progress,
                  speedBytesPerSec: state.speedBps,
                  fileName: state.fileName,
                ),
              );
            } else if (state is Verifying) {
              return const Center(child: Text('Verifying file integrity...'));
            }
            return const SizedBox();
          },
        ),
      ),
    );
  }
}
""",
    "lib/features/receiver/presentation/pages/complete_page.dart": """import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

class CompletePage extends StatelessWidget {
  final String fileName;
  final String filePath;

  const CompletePage({Key? key, required this.fileName, required this.filePath}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.check_circle, color: Colors.green, size: 120)
                .animate()
                .scale(duration: 500.ms, curve: Curves.easeOutBack)
                .fadeIn(),
            const SizedBox(height: 24),
            const Text('File Received!', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 32),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  children: [
                    const Icon(Icons.file_present, size: 40),
                    const SizedBox(width: 16),
                    Expanded(child: Text(fileName, style: const TextStyle(fontSize: 16))),
                  ],
                ),
              ),
            ).animate().slideY(begin: 0.5, end: 0.0).fadeIn(),
            const SizedBox(height: 40),
            ElevatedButton(
              onPressed: () {
                // Handle open file
              },
              child: const Text('Open File'),
            ),
            TextButton(
              onPressed: () => Navigator.popUntil(context, (route) => route.isFirst),
              child: const Text('Receive Another'),
            )
          ],
        ),
      ),
    );
  }
}
""",
    "lib/shared/widgets/scan_overlay.dart": """import 'package:flutter/material.dart';

class ScanOverlay extends StatelessWidget {
  final AnimationController animationController;
  final double cutoutSize;
  final Color borderColor;

  const ScanOverlay({
    Key? key,
    required this.animationController,
    required this.cutoutSize,
    required this.borderColor,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _ScanOverlayPainter(
        animation: animationController,
        cutoutSize: cutoutSize,
        borderColor: borderColor,
      ),
      child: Container(),
    );
  }
}

class _ScanOverlayPainter extends CustomPainter {
  final Animation<double> animation;
  final double cutoutSize;
  final Color borderColor;

  _ScanOverlayPainter({
    required this.animation,
    required this.cutoutSize,
    required this.borderColor,
  }) : super(repaint: animation);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black54
      ..style = PaintingStyle.fill;

    final center = Offset(size.width / 2, size.height / 2);
    final rect = Rect.fromCenter(center: center, width: cutoutSize, height: cutoutSize);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(16));

    final path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRRect(rrect)
      ..fillType = PathFillType.evenOdd;

    canvas.drawPath(path, paint);

    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    const double lineLength = 30.0;
    
    // Top Left
    canvas.drawLine(rect.topLeft, rect.topLeft.translate(lineLength, 0), borderPaint);
    canvas.drawLine(rect.topLeft, rect.topLeft.translate(0, lineLength), borderPaint);
    
    // Top Right
    canvas.drawLine(rect.topRight, rect.topRight.translate(-lineLength, 0), borderPaint);
    canvas.drawLine(rect.topRight, rect.topRight.translate(0, lineLength), borderPaint);
    
    // Bottom Left
    canvas.drawLine(rect.bottomLeft, rect.bottomLeft.translate(lineLength, 0), borderPaint);
    canvas.drawLine(rect.bottomLeft, rect.bottomLeft.translate(0, -lineLength), borderPaint);
    
    // Bottom Right
    canvas.drawLine(rect.bottomRight, rect.bottomRight.translate(-lineLength, 0), borderPaint);
    canvas.drawLine(rect.bottomRight, rect.bottomRight.translate(0, -lineLength), borderPaint);

    // Animated Line
    final lineY = rect.top + (rect.height * animation.value);
    final linePaint = Paint()
      ..color = borderColor.withOpacity(0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    canvas.drawLine(
      Offset(rect.left + 10, lineY),
      Offset(rect.right - 10, lineY),
      linePaint,
    );
  }

  @override
  bool shouldRepaint(covariant _ScanOverlayPainter oldDelegate) => true;
}
"""
}

for filepath, content in files.items():
    full_path = os.path.join(base_dir, filepath)
    os.makedirs(os.path.dirname(full_path), exist_ok=True)
    with open(full_path, "w") as f:
        f.write(content)
    print(f"Created {full_path}")
