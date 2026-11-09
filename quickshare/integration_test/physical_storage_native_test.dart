// Native storage operations on the physical Mac and iPhone.
//
// Run separately on each device:
//   flutter test integration_test/physical_storage_native_test.dart -d macos
//   flutter drive --no-pub -d <iphone-device-id> \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/physical_storage_native_test.dart --publish-port
//
// Uses production save services and platform plugins. The iPhone run leaves one
// uniquely named PNG in Photos; remove that image manually after reviewing it.
// This does not exercise the app's native file picker or camera.
// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:quickshare/core/storage/media_saver.dart';
import 'package:quickshare/core/storage/received_item.dart';
import 'package:quickshare/core/storage/save_coordinator.dart';
import 'package:quickshare/core/storage/save_destination.dart';
import 'package:quickshare/core/storage/save_location_store.dart';
import 'package:quickshare/core/storage/transfer_cache.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native gallery, documents, folder, and default saves work',
      (tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    final platform = Platform.operatingSystem;
    expect(Platform.isIOS || Platform.isMacOS, isTrue,
        reason: 'this scenario is for the physical iPhone and Mac targets');
    final runId =
        '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}_${pid.toRadixString(36)}';
    final outputPrefix = 'DirectDrop_$runId';
    final temporaryDirectory = await getTemporaryDirectory();
    final cacheRoot = Directory(
        p.join(temporaryDirectory.path, '${outputPrefix}_cache_root'));
    final isolatedCache = TransferCache(overrideRoot: () => cacheRoot);
    final session = await isolatedCache.sessionDirectory();
    final documentsDirectory = await getApplicationDocumentsDirectory();
    final chosenDirectory =
        Directory(p.join(documentsDirectory.path, '${outputPrefix}_chosen'));
    final generatedDownloadPaths = <String>[];
    Directory? downloadsDirectory;
    Directory? configuredSaveDirectory;
    const saveLocation = SaveLocationStore();

    print('STORAGE_CHECK START platform=$platform run=$runId');

    try {
      await chosenDirectory.create(recursive: true);
      final documentName = '${outputPrefix}_document.txt';
      final folderName = '${outputPrefix}_folder';
      final documentBytes = Uint8List.fromList(
          'DirectDrop physical storage fixture $runId\n'.codeUnits);
      final documentFile = File(p.join(session.path, documentName))
        ..writeAsBytesSync(documentBytes);
      final folder = Directory(p.join(session.path, folderName))
        ..createSync(recursive: true);
      final folderFiles = <String, Uint8List>{
        'first.bin': Uint8List.fromList([0, 7, 19, 255, runId.length]),
        p.join('nested', 'second.txt'):
            Uint8List.fromList('nested fixture $runId'.codeUnits),
      };
      for (final entry in folderFiles.entries) {
        final file = File(p.join(folder.path, entry.key));
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(entry.value);
      }

      final documentItem =
          ReceivedItem.fromCacheFile(documentFile, 'text/plain');
      final folderItem =
          await ReceivedItem.fromCacheEntity(folder, 'inode/directory');
      final chosenOutcomes = await SaveCoordinator(
        destination: SaveDestination.forCurrentPlatform(),
        cache: isolatedCache,
      ).saveChosen([documentItem, folderItem], chosenDirectory.path);
      expect(chosenOutcomes, hasLength(2));
      for (final outcome in chosenOutcomes) {
        expect(outcome.failed, isFalse,
            reason: 'saveChosen must successfully save ${outcome.item.name}: '
                '${outcome.error}');
        expect(outcome.item.savedPath, isNotNull);
      }

      final savedDocument = File(chosenOutcomes[0].item.savedPath!);
      expect(await savedDocument.exists(), isTrue);
      expect(await _sha256File(savedDocument), _sha256Bytes(documentBytes));
      final savedFolder = Directory(chosenOutcomes[1].item.savedPath!);
      expect(await savedFolder.exists(), isTrue);
      expect(await _treeHashes(savedFolder), {
        for (final entry in folderFiles.entries)
          p.normalize(entry.key): _sha256Bytes(entry.value),
      });
      print('STORAGE_CHECK PASS saveChosen document+folder verified in app '
          'Documents; target=${chosenDirectory.path}');

      if (Platform.isIOS) {
        final galleryName = '${outputPrefix}_gallery.png';
        final pngBytes = await _makeValidPng();
        final galleryFile = File(p.join(session.path, galleryName))
          ..writeAsBytesSync(pngBytes);
        expect(await _isPng(galleryFile), isTrue);
        final galleryItem =
            ReceivedItem.fromCacheFile(galleryFile, 'image/png');
        print('STORAGE_CHECK ACTION saving $galleryName to Photos; respond to '
            'any iOS photo permission prompt');
        final savedGalleryItem =
            await const MediaSaver().saveToGallery(galleryItem);
        expect(savedGalleryItem.savedPath, 'gallery');
        print('STORAGE_CHECK PASS Photos accepted $galleryName; the unique '
            'image remains in Photos for manual cleanup');
      } else if (Platform.isMacOS) {
        final actualDownloadsDirectory = await getDownloadsDirectory();
        downloadsDirectory = actualDownloadsDirectory;
        try {
          configuredSaveDirectory = await saveLocation.resolveForWriting();
        } finally {
          await saveLocation.release();
        }
        if (actualDownloadsDirectory == null &&
            configuredSaveDirectory == null) {
          throw StateError('Mac did not resolve Downloads or a saved folder');
        }
        final defaultOutputRoot =
            actualDownloadsDirectory ?? documentsDirectory;
        final pngBytes = await _makeValidPng();
        final photo = File(p.join(session.path, '${outputPrefix}_image.png'))
          ..writeAsBytesSync(pngBytes);
        final automaticFile = ReceivedItem.fromCacheFile(photo, 'image/png');
        // A second unique folder exercises automatic folder placement too.
        final automaticFolder =
            Directory(p.join(session.path, '${outputPrefix}_automatic_folder'))
              ..createSync(recursive: true);
        final automaticFolderBytes =
            Uint8List.fromList('automatic folder $runId'.codeUnits);
        File(p.join(automaticFolder.path, 'payload.txt'))
            .writeAsBytesSync(automaticFolderBytes);
        final automaticFolderItem = await ReceivedItem.fromCacheEntity(
            automaticFolder, 'inode/directory');

        final automaticOutcomes = await SaveCoordinator(
          destination: SaveDestination.forCurrentPlatform(),
          cache: isolatedCache,
          saveLocation: saveLocation,
        ).runAutomatic([automaticFile, automaticFolderItem]);
        expect(automaticOutcomes, hasLength(2));
        generatedDownloadPaths.addAll([
          for (final outcome in automaticOutcomes)
            if (outcome.item.savedPath != null) outcome.item.savedPath!,
        ]);
        for (final outcome in automaticOutcomes) {
          expect(outcome.failed, isFalse,
              reason: 'automatic save must succeed for ${outcome.item.name}: '
                  '${outcome.error}');
          expect(outcome.item.savedPath, isNotNull);
          final configuredRoot = configuredSaveDirectory;
          final landsInExpectedTarget = configuredRoot == null
              ? p.isWithin(defaultOutputRoot.path, outcome.item.savedPath!)
              : p.isWithin(configuredRoot.path, outcome.item.savedPath!) ||
                  p.isWithin(defaultOutputRoot.path, outcome.item.savedPath!);
          expect(landsInExpectedTarget, isTrue,
              reason: 'automatic output must land in the saved folder or the '
                  'platform Downloads fallback');
        }
        final automaticImage = File(automaticOutcomes[0].item.savedPath!);
        expect(await _sha256File(automaticImage), _sha256Bytes(pngBytes));
        final automaticFolderPath = automaticOutcomes[1].item.savedPath!;
        expect(
          await _sha256File(File(p.join(automaticFolderPath, 'payload.txt'))),
          _sha256Bytes(automaticFolderBytes),
        );
        final target = configuredSaveDirectory ?? defaultOutputRoot;
        print('STORAGE_CHECK PASS runAutomatic image+folder verified in '
            '${configuredSaveDirectory == null ? 'default save location' : 'saved folder'}; '
            'target=${target.path}');
      }
    } finally {
      // These paths are generated uniquely for this run. The Photos copy is
      // intentionally excluded; only its app-cache source is removed here.
      if (generatedDownloadPaths.isNotEmpty) {
        Directory? cleanupRoot;
        var saveLocationResolved = false;
        try {
          if (Platform.isMacOS && generatedDownloadPaths.isNotEmpty) {
            cleanupRoot = await saveLocation.resolveForWriting();
            saveLocationResolved = cleanupRoot != null;
          }
          await _deleteGeneratedDownloads(
            cleanupRoot ?? downloadsDirectory ?? documentsDirectory,
            generatedDownloadPaths,
            outputPrefix,
            additionalAllowedRoot: downloadsDirectory ?? documentsDirectory,
          );
        } finally {
          if (saveLocationResolved) await saveLocation.release();
        }
      }
      if (await chosenDirectory.exists()) {
        await chosenDirectory.delete(recursive: true);
      }
      if (await cacheRoot.exists()) await cacheRoot.delete(recursive: true);
      print('STORAGE_CHECK CLEANUP temporary cache and chosen-save outputs '
          'removed; Photos copy retained for manual cleanup');
    }
  });
}

Future<Uint8List> _makeValidPng() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder, const ui.Rect.fromLTWH(0, 0, 32, 32));
  canvas.drawColor(const ui.Color(0xff1d4ed8), ui.BlendMode.src);
  final paint = ui.Paint()..color = const ui.Color(0xfffacc15);
  canvas.drawCircle(const ui.Offset(16, 16), 9, paint);
  final picture = recorder.endRecording();
  final image = await picture.toImage(32, 32);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('Flutter could not encode the PNG');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
  }
}

Future<bool> _isPng(File file) async {
  final header = await file.openRead(0, 8).fold<List<int>>(
    <int>[],
    (bytes, chunk) => bytes..addAll(chunk),
  );
  return header.length == 8 &&
      header[0] == 0x89 &&
      header[1] == 0x50 &&
      header[2] == 0x4e &&
      header[3] == 0x47 &&
      header[4] == 0x0d &&
      header[5] == 0x0a &&
      header[6] == 0x1a &&
      header[7] == 0x0a;
}

String _sha256Bytes(List<int> bytes) => sha256.convert(bytes).toString();

Future<String> _sha256File(File file) async =>
    sha256.convert(await file.readAsBytes()).toString();

Future<Map<String, String>> _treeHashes(Directory directory) async {
  final hashes = <String, String>{};
  await for (final entity
      in directory.list(recursive: true, followLinks: false)) {
    if (entity is File) {
      hashes[p.relative(entity.path, from: directory.path)] =
          await _sha256File(entity);
    }
  }
  return hashes;
}

Future<void> _deleteGeneratedDownloads(
  Directory downloads,
  Iterable<String> generatedPaths,
  String outputPrefix, {
  Directory? additionalAllowedRoot,
}) async {
  for (final path in generatedPaths) {
    final insideChosenRoot = p.isWithin(downloads.path, path);
    final insideAdditionalRoot = additionalAllowedRoot != null &&
        p.isWithin(additionalAllowedRoot.path, path);
    if ((!insideChosenRoot && !insideAdditionalRoot) ||
        !p.basename(path).startsWith(outputPrefix)) {
      continue;
    }
    final file = File(path);
    final directory = Directory(path);
    if (await file.exists()) {
      await file.delete();
    } else if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}
