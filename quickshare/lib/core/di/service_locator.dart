import 'package:get_it/get_it.dart';

// Core
import 'package:quickshare/core/localization/locale_controller.dart';
import 'package:quickshare/core/network/network_info_service.dart';
import 'package:quickshare/core/permissions/permission_service.dart';

// Sender
import 'package:quickshare/features/sender/data/indexer/file_indexer.dart';
import 'package:quickshare/features/sender/data/server/local_http_server.dart';
import 'package:quickshare/features/sender/data/qr/qr_payload_encoder.dart';
import 'package:quickshare/features/sender/data/repositories/sender_repository_impl.dart';
import 'package:quickshare/features/sender/domain/repositories/sender_repository.dart';
import 'package:quickshare/features/sender/presentation/bloc/sender_bloc.dart';

// Receiver
import 'package:quickshare/features/receiver/data/client/http_file_downloader.dart';
import 'package:quickshare/features/receiver/data/client/qhtp_receiver_client.dart';
import 'package:quickshare/features/receiver/data/store/session_state_store.dart';
import 'package:quickshare/features/receiver/data/qr/qr_payload_decoder.dart';
import 'package:quickshare/features/receiver/data/repositories/receiver_repository_impl.dart';
import 'package:quickshare/features/receiver/domain/repositories/receiver_repository.dart';
import 'package:quickshare/features/receiver/domain/usecases/download_file_usecase.dart';
import 'package:quickshare/features/receiver/presentation/bloc/receiver_bloc.dart';

/// Global service locator instance.
final GetIt sl = GetIt.instance;

class ServiceLocator {
  static Future<void> init() async {
    // ─── Core Services ───────────────────────────────────────
    // Eager, not lazy: it starts reading the saved language choice from disk
    // the moment the app launches, and the first frame should not be the one
    // that triggers that read.
    sl.registerSingleton<LocaleController>(LocaleController());
    sl.registerLazySingleton<NetworkInfoService>(
      () => NetworkInfoService(),
    );
    sl.registerLazySingleton<PermissionService>(
      () => PermissionService(),
    );

    // ─── Sender Feature ──────────────────────────────────────
    sl.registerLazySingleton<FileIndexer>(
      () => FileIndexer(),
    );
    sl.registerLazySingleton<LocalHttpServer>(
      () => LocalHttpServer(),
    );
    sl.registerLazySingleton<QRPayloadEncoder>(
      () => QRPayloadEncoder(),
    );

    sl.registerLazySingleton<SenderRepository>(
      () => SenderRepositoryImpl(
        localServer: sl<LocalHttpServer>(),
        networkInfoService: sl<NetworkInfoService>(),
        qrEncoder: sl<QRPayloadEncoder>(),
        indexer: sl<FileIndexer>(),
      ),
    );

    sl.registerFactory<SenderBloc>(
      () => SenderBloc(repository: sl<SenderRepository>()),
    );

    // ─── Receiver Feature ────────────────────────────────────
    sl.registerLazySingleton<SessionStateStore>(
      () => SessionStateStore(),
    );
    sl.registerLazySingleton<QhtpReceiverClient>(
      () => QhtpReceiverClient(store: sl<SessionStateStore>()),
    );
    sl.registerLazySingleton<HttpFileDownloader>(
      () => HttpFileDownloader(),
    );
    sl.registerLazySingleton<QRPayloadDecoder>(
      () => QRPayloadDecoder(),
    );

    sl.registerLazySingleton<ReceiverRepository>(
      // No `qhtpClient` here on purpose: without one the repository runs the
      // session in a worker isolate, which is the point — decrypting and
      // writing stop sharing a thread with the screen. Passing a client is
      // how a test says "watch this transport", and the app is not a test.
      () => ReceiverRepositoryImpl(
        downloader: sl<HttpFileDownloader>(),
        decoder: sl<QRPayloadDecoder>(),
      ),
    );

    sl.registerLazySingleton<DownloadFileUseCase>(
      () => DownloadFileUseCase(sl<ReceiverRepository>()),
    );

    sl.registerFactory<ReceiverBloc>(
      () => ReceiverBloc(
        downloadFileUseCase: sl<DownloadFileUseCase>(),
        repository: sl<ReceiverRepository>(),
      ),
    );
  }
}
