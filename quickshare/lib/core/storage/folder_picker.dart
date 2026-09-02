import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:quickshare/core/utils/app_logger.dart';

/// Choosing folders to send — as many as the user wants.
///
/// `file_picker` can only ever answer with one: `getDirectoryPath()` returns
/// a single path, and on iOS it opens the system picker in a mode that draws
/// no checkboxes at all, so a folder cannot even be ticked — only entered and
/// confirmed from the inside, one per trip through the dialog. Sending three
/// folders was not slow, it was unsayable.
///
/// Both native pickers already support the selection this needs; only the
/// plugin's API had no room for the answer. Where a platform channel is not
/// there to ask — Windows and Linux, for now — this falls back to the
/// plugin's single-folder dialog, so the button keeps working and simply
/// returns a list of one.
class FolderPicker {
  static const MethodChannel _defaultChannel =
      MethodChannel('quickshare/folder_picker');

  final MethodChannel _channel;

  const FolderPicker({MethodChannel? channel})
      : _channel = channel ?? _defaultChannel;

  /// Whether this platform can return more than one folder.
  static bool get supportsMultiple =>
      !kIsWeb && (Platform.isIOS || Platform.isMacOS);

  /// The folders the user picked, or an empty list if they cancelled.
  ///
  /// [dialogTitle] is shown by the platforms that have somewhere to put it.
  Future<List<String>> pick({String? dialogTitle}) async {
    if (supportsMultiple) {
      try {
        final picked = await _channel.invokeListMethod<String>(
          'pickFolders',
          {if (dialogTitle != null) 'title': dialogTitle},
        );
        return picked ?? const [];
      } on MissingPluginException {
        // An older build of the shell without the channel. The single-folder
        // dialog below still sends something, which beats a dead button.
        AppLogger.warning(
            'No native folder picker in this build; falling back to one folder',
            tag: 'PICKER');
      } on PlatformException catch (e) {
        AppLogger.warning('Folder picker failed: ${e.message}', tag: 'PICKER');
        return const [];
      }
    }

    final single =
        await FilePicker.platform.getDirectoryPath(dialogTitle: dialogTitle);
    return single == null ? const [] : [single];
  }

  /// Drops the access this app was granted to the last selection.
  ///
  /// iOS hands back security-scoped URLs that stay unreadable unless the
  /// scope is held open, so the picker keeps them open until told otherwise.
  /// Everywhere else this does nothing. Only call it once the files are
  /// certainly finished with — a transfer still reading them would stop
  /// mid-file.
  Future<void> release() async {
    if (!supportsMultiple) return;
    try {
      await _channel.invokeMethod<void>('releaseFolders');
    } on MissingPluginException {
      // Nothing was ever held.
    } on PlatformException catch (e) {
      AppLogger.warning('Could not release picked folders: ${e.message}',
          tag: 'PICKER');
    }
  }
}
