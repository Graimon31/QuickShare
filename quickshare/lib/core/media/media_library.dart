import 'dart:io';

import 'package:photo_manager/photo_manager.dart';

import 'package:quickshare/core/utils/app_logger.dart';

/// Why the photo library could not be read.
enum MediaAccess { granted, limited, denied }

/// One item in the device photo library, plus the original file behind it.
class MediaEntry {
  final AssetEntity asset;
  final File file;
  final String name;
  final int size;
  final String mimeType;

  const MediaEntry({
    required this.asset,
    required this.file,
    required this.name,
    required this.size,
    required this.mimeType,
  });
}

/// Reads the device photo library, returning the *original* files.
///
/// `image_picker` is not usable for this: on iOS it hands back a transcoded
/// copy — a HEIC photo arrives as JPEG and a video may be re-encoded — which
/// is exactly the compression this app promises not to do. photo_manager can
/// resolve an asset to the file the camera actually wrote, so what leaves the
/// device is what was on it.
class MediaLibrary {
  const MediaLibrary();

  Future<MediaAccess> requestAccess() async {
    final state = await PhotoManager.requestPermissionExtend();
    if (state.isAuth) return MediaAccess.granted;
    // iOS "selected photos" — the user granted access to some assets only.
    // Usable, and worth distinguishing so the UI can offer to widen it.
    if (state == PermissionState.limited) return MediaAccess.limited;
    return MediaAccess.denied;
  }

  /// Everything in the library, newest first.
  ///
  /// Loaded a page at a time: a phone with 40 000 photos would otherwise
  /// block on the first frame.
  Future<List<AssetEntity>> loadPage({int page = 0, int pageSize = 90}) async {
    final albums = await PhotoManager.getAssetPathList(
      onlyAll: true,
      type: RequestType.common, // images and videos, nothing else
    );
    if (albums.isEmpty) return const [];
    return albums.first.getAssetListPaged(page: page, size: pageSize);
  }

  /// Resolves an asset to the untouched file on disk.
  ///
  /// Returns null when the original is not available locally — an iCloud
  /// photo that was never downloaded has no file to send, and saying so is
  /// better than shipping a thumbnail.
  Future<MediaEntry?> resolveOriginal(AssetEntity asset) async {
    try {
      // `isOrigin: true` is the whole point: without it photo_manager also
      // hands back a converted derivative.
      final file = await asset.originFile;
      if (file == null || !await file.exists()) {
        AppLogger.warning(
            'No local original for asset ${asset.id} '
            '(likely still in iCloud)',
            tag: 'MEDIA');
        return null;
      }
      return MediaEntry(
        asset: asset,
        file: file,
        name: await asset.titleAsync,
        size: await file.length(),
        mimeType: await asset.mimeTypeAsync ??
            (asset.type == AssetType.video ? 'video/mp4' : 'image/jpeg'),
      );
    } catch (e) {
      AppLogger.warning('Could not resolve asset ${asset.id}: $e',
          tag: 'MEDIA');
      return null;
    }
  }

  /// Resolves many, dropping the ones with no local original.
  ///
  /// Returns what it could get rather than failing the whole selection: nine
  /// of ten photos is a better outcome than none.
  Future<({List<MediaEntry> entries, int unavailable})> resolveAll(
      Iterable<AssetEntity> assets) async {
    final entries = <MediaEntry>[];
    var unavailable = 0;
    for (final asset in assets) {
      final entry = await resolveOriginal(asset);
      if (entry == null) {
        unavailable++;
      } else {
        entries.add(entry);
      }
    }
    return (entries: entries, unavailable: unavailable);
  }
}
