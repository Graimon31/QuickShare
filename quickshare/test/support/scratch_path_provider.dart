import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// A path_provider that answers every question with one folder.
///
/// A test that needs a destination folder used to mock the plugin's method
/// channel. That works on macOS only by accident: the package's default
/// implementation is the channel-backed one, and only there. On Windows and
/// Linux the platform implementations register themselves with the plugin
/// registrant, which `flutter test` does not run, so the default is still the
/// channel one — and its `getDownloadsPath` throws "Functionality only
/// available on macOS" before it ever looks at the mock. Replacing the
/// platform object itself works the same everywhere.
class ScratchPathProvider extends PathProviderPlatform {
  ScratchPathProvider(this.path);

  /// What every question is answered with.
  final String path;

  @override
  Future<String?> getTemporaryPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationCachePath() async => path;

  @override
  Future<String?> getDownloadsPath() async => path;

  @override
  Future<String?> getLibraryPath() async => path;

  @override
  Future<String?> getExternalStoragePath() async => path;

  @override
  Future<List<String>?> getExternalCachePaths() async => [path];

  @override
  Future<List<String>?> getExternalStoragePaths(
          {StorageDirectory? type}) async =>
      [path];
}

/// Makes `getDownloadsDirectory()` and every other path_provider call answer
/// with [path] until the current test ends, then puts the previous platform
/// back. Call it from `setUp` or from the test itself.
void answerPathProviderWith(String path) {
  final original = PathProviderPlatform.instance;
  PathProviderPlatform.instance = ScratchPathProvider(path);
  addTearDown(() => PathProviderPlatform.instance = original);
}
