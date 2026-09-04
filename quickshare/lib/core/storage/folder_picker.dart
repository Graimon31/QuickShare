import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:quickshare/core/utils/app_logger.dart';

/// The system file browser, asked for what this app actually wants.
///
/// `file_picker` opens the same native dialog underneath but exposes it
/// through calls that each drop something: `pickFiles()` cannot return a
/// folder, `getDirectoryPath()` returns exactly one and nothing else, and
/// neither can open the dialog in *save* mode. Those three gaps are why this
/// app had two selection buttons instead of one, why several folders could
/// not be sent in a single trip, and why saving a download on iOS offered a
/// button labelled "Открыть" and then failed.
///
/// Every native dialog here can already do all of it — `NSOpenPanel` returns
/// a mixed selection of files and folders, and
/// `UIDocumentPickerViewController` browses both and has an export mode. Only
/// the plugin's API had no room for the answer, so this asks the platform
/// directly where a channel exists and falls back to the plugin where one
/// does not.
class FolderPicker {
  static const MethodChannel _defaultChannel =
      MethodChannel('quickshare/folder_picker');

  final MethodChannel _channel;

  const FolderPicker({MethodChannel? channel})
      : _channel = channel ?? _defaultChannel;

  /// Whether this platform has the native dialog behind [pickItems] — one
  /// browse that returns files and folders together, however many.
  ///
  /// False on Windows and Linux, whose common dialogs genuinely cannot do it:
  /// `IFileOpenDialog` picks files or folders per invocation, never both, and
  /// GTK's chooser is the same. There the two entry points stay separate
  /// because the platform has no single act of browsing to unify them into.
  static bool get supportsUnifiedPick =>
      !kIsWeb && (Platform.isIOS || Platform.isMacOS);

  /// Whether this platform can return more than one folder.
  static bool get supportsMultiple => supportsUnifiedPick;

  /// Whether saving is handed to the system rather than done by this app.
  ///
  /// Only iOS. A destination the user picks there is outside the sandbox and
  /// stays unwritable, so the copy has to be the system's own — which is also
  /// what puts "Сохранить" on the button instead of "Открыть".
  static bool get exportsThroughSystem => !kIsWeb && Platform.isIOS;

  /// Files and folders, mixed, as many as the user wants.
  ///
  /// The one selection call worth having: a manifest of relative paths is
  /// what every transport here carries, so a folder and a loose file cost the
  /// same to express and there was never a reason to ask which one the user
  /// meant before opening the dialog.
  ///
  /// Falls back to files-only where [supportsUnifiedPick] is false.
  Future<List<String>> pickItems({String? dialogTitle}) async {
    if (supportsUnifiedPick) {
      final picked = await _invokePaths(
          'pickItems', {if (dialogTitle != null) 'title': dialogTitle});
      if (picked != null) return picked;
    }

    final result = await FilePicker.platform
        .pickFiles(allowMultiple: true, dialogTitle: dialogTitle);
    return result?.files
            .map((f) => f.path)
            .whereType<String>()
            .toList(growable: false) ??
        const [];
  }

  /// Folders and nothing else, for the callers that mean it — choosing where
  /// downloads are kept, most of all.
  Future<List<String>> pick({String? dialogTitle}) async {
    if (supportsMultiple) {
      final picked = await _invokePaths(
          'pickFolders', {if (dialogTitle != null) 'title': dialogTitle});
      if (picked != null) return picked;
    }

    final single =
        await FilePicker.platform.getDirectoryPath(dialogTitle: dialogTitle);
    return single == null ? const [] : [single];
  }

  /// Asks the system to save [paths] somewhere the user chooses.
  ///
  /// Returns where they landed, or an empty list if the user backed out.
  ///
  /// Only meaningful where [exportsThroughSystem] is true; everywhere else
  /// the caller picks a directory with [pick] and copies into it, which is
  /// allowed there.
  Future<List<String>> exportItems(List<String> paths,
      {String? dialogTitle}) async {
    if (paths.isEmpty) return const [];
    final picked = await _invokePaths('exportItems', {
      'paths': paths,
      if (dialogTitle != null) 'title': dialogTitle,
    });
    return picked ?? const [];
  }

  /// Runs one channel call, or returns null when this build has no shell to
  /// answer it and the caller should fall back.
  Future<List<String>?> _invokePaths(
      String method, Map<String, Object?> arguments) async {
    try {
      return await _channel.invokeListMethod<String>(method, arguments) ??
          const [];
    } on MissingPluginException {
      // An older build of the shell without the channel. Falling back beats a
      // dead button.
      AppLogger.warning('No native $method in this build; falling back',
          tag: 'PICKER');
      return null;
    } on PlatformException catch (e) {
      AppLogger.warning('Picker call $method failed: ${e.message}',
          tag: 'PICKER');
      return const [];
    }
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
