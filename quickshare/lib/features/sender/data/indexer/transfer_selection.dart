import 'package:path/path.dart' as p;

import 'package:quickshare/features/sender/data/indexer/file_indexer.dart';
import 'package:quickshare/features/sender/domain/entities/file_metadata.dart';

/// Turns whatever the user picked into the flat list of files a transport has
/// to move, each one remembering where it belongs.
///
/// A folder is not a thing that can be sent; the files under it are, and the
/// relative path of each is what lets the far side put the folder back
/// together. Every channel in the app now carries that list — which is why a
/// folder no longer has to be flattened into a zip to travel over the ones
/// that used to insist on a single file.
///
/// The walk is [FileIndexer]'s, the same one the Wi-Fi manifest is built from,
/// so a selection sent over Bluetooth or the internet contains exactly the
/// files it would contain over Wi-Fi: hidden entries, `.git` and
/// `node_modules` skipped, symlinks not followed, the same depth and size
/// ceilings, the same deterministic order.
Future<List<FileMetadata>> expandSelection(List<String> paths) async {
  final indexed = await FileIndexer().buildResult(
    sessionId: 'inline',
    paths: paths,
    // Nothing here verifies checksums, and hashing reads every byte a second
    // time before the first one has left.
    includeChecksums: false,
  );

  return [
    for (final item in indexed.manifest.items)
      FileMetadata(
        name: p.posix.basename(item.path),
        path: indexed.itemIdToAbsPathMap[item.id]!,
        size: item.size,
        mimeType: item.mime ?? 'application/octet-stream',
        // A selection of plain files has nothing to rebuild, and saying so
        // keeps it off the wire entirely.
        relativePath: item.path.contains('/') ? item.path : null,
      ),
  ];
}

/// The single folder every file in [files] sits under, if there is one.
///
/// Null for a flat selection or a mix of folders — both of which a count
/// describes better than a name. What it is for is the sender's own screens:
/// a folder should be announced as the folder it is, not as the 412 files
/// inside it, and certainly not as whichever photo happened to sort first.
String? commonRootFolder(List<FileMetadata> files) {
  String? root;
  for (final file in files) {
    final relative = file.relativePath;
    if (relative == null) return null;
    final first = p.posix.split(relative).first;
    if (root == null) {
      root = first;
    } else if (root != first) {
      return null;
    }
  }
  return root;
}
