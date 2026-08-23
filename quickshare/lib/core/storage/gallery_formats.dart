import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/storage/received_item.dart';

/// Which photo library is on the other side of a save, since the two
/// disagree about what they will store.
enum GalleryPlatform {
  ios,
  android,

  /// Desktop, or anywhere else without a photo library worth the name. Nothing
  /// is ever handed to a gallery here; files go to Downloads instead.
  none,
}

/// Whether the device photo library will actually accept a given file.
///
/// Deliberately not "is this a photo or a video". That question has a much
/// wider answer than either gallery cares about, and answering *it* was the
/// bug: an .avi is a video by any reasonable definition and iOS Photos refuses
/// it outright, so classifying it as media meant an automatic gallery write
/// that could only throw — after which the file was neither in the gallery nor
/// offered to the user, and its cache copy was dropped on the way out of the
/// screen. Same for .mkv, .webm, .wmv, .flv, .webp and .bmp on iOS, and for
/// .avi, .wmv, .flv and .tiff on Android.
///
/// The rule is therefore stated per platform, from what Apple and Google
/// document their libraries as storing rather than from what the formats are:
///   - Apple: HEIF, JPEG, RAW, PNG, GIF, TIFF, HEVC, MP4
///     (support.apple.com/en-us/108782)
///   - Android: JPEG, PNG, GIF, BMP, WebP, HEIF, AVIF, DNG, and MP4 / 3GP /
///     WebM / Matroska containers
///
/// Anything outside its platform's list is a file: the user is asked where it
/// should go, and it lands there intact. Being asked about a .avi is a minor
/// annoyance; losing it is not.
class GalleryFormats {
  final GalleryPlatform platform;

  const GalleryFormats(this.platform);

  factory GalleryFormats.forCurrentPlatform() {
    if (kIsWeb) return const GalleryFormats(GalleryPlatform.none);
    if (Platform.isIOS) return const GalleryFormats(GalleryPlatform.ios);
    if (Platform.isAndroid) return const GalleryFormats(GalleryPlatform.android);
    return const GalleryFormats(GalleryPlatform.none);
  }

  bool accepts(ReceivedItem item) {
    final extensions = _extensions;
    if (extensions.isEmpty) return false;

    final extension = p.extension(item.name).toLowerCase();
    if (extension.length > 1) return extensions.contains(extension.substring(1));

    // Nothing to go on but the MIME type — a name the sender stripped, or one
    // that never had an extension. Camera RAW cannot be recognised this way at
    // all: none of those formats have a registered MIME type, and the `mime`
    // package resolves .cr2/.nef/.arw/.dng to nothing, so a RAW file with no
    // extension reads as a plain file and gets asked about.
    return _mimeTypes.contains(item.mimeType.toLowerCase());
  }

  Set<String> get _extensions => switch (platform) {
        GalleryPlatform.ios => _iosExtensions,
        GalleryPlatform.android => _androidExtensions,
        GalleryPlatform.none => const {},
      };

  Set<String> get _mimeTypes => switch (platform) {
        GalleryPlatform.ios => _iosMimeTypes,
        GalleryPlatform.android => _androidMimeTypes,
        GalleryPlatform.none => const {},
      };

  /// ProRes needs no entry of its own: it is carried in .mov.
  static const _iosExtensions = {
    'heic', 'heif', 'jpg', 'jpeg', 'png', 'gif', 'tiff', 'tif',
    // "RAW" in Apple's list, spelled out. Photos stores these as assets;
    // Files is where they would otherwise end up, away from the user's
    // camera roll.
    'dng', 'cr2', 'cr3', 'nef', 'arw', 'orf', 'raf', 'rw2', 'mrw', 'srf',
    'mov', 'mp4', 'm4v', '3gp', //
  };

  /// .mov and .m4v are here although Google's format documentation lists only
  /// MP4/3GP/WebM/Matroska — that document is about which containers the
  /// *codecs* are guaranteed to decode, while MediaStore indexes
  /// `video/quicktime` and every Android gallery shows it. It also happens to
  /// be the single most common thing this app will ever carry: a video from an
  /// iPhone is a .mov, and making the most ordinary cross-platform transfer
  /// stop to ask a question would be a poor trade for a format that works.
  ///
  /// Matroska is admitted on Google's word but is the shakiest entry here —
  /// whether it plays depends on the codecs inside it. If it is refused, the
  /// refusal is survivable: [SaveCoordinator] turns a rejected gallery write
  /// back into a question rather than a dead end.
  static const _androidExtensions = {
    'jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'heic', 'heif', 'avif', 'dng',
    'mp4', '3gp', 'webm', 'mkv', 'mov', 'm4v', //
  };

  static const _iosMimeTypes = {
    'image/heic', 'image/heif', 'image/jpeg', 'image/jpg', 'image/png',
    'image/gif', 'image/tiff',
    'video/quicktime', 'video/mp4', 'video/x-m4v', 'video/3gpp', //
  };

  static const _androidMimeTypes = {
    'image/jpeg', 'image/jpg', 'image/png', 'image/gif', 'image/bmp',
    'image/webp', 'image/heic', 'image/heif', 'image/avif',
    'video/mp4', 'video/3gpp', 'video/webm', 'video/x-matroska',
    'video/quicktime', 'video/x-m4v', //
  };
}
