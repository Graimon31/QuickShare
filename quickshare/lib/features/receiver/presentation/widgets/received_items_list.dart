import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'package:quickshare/core/storage/received_item.dart';
import 'package:quickshare/core/storage/transfer_cache.dart';
import 'package:quickshare/core/theme/app_colors.dart';

/// Everything a transfer delivered, in full and openable.
///
/// The completion screen used to print the first four names and then "and 6
/// more" as dead text: a session of ten files could not be inspected at all,
/// and a folder — which arrives as a single item — showed only its own name,
/// never what was inside it. Both are the question the user actually has after
/// a transfer: *what did I just get?*
///
/// So: every item, scrolled rather than truncated, and folders expand to their
/// contents. Children are read from disk only when a folder is opened — a
/// received tree can hold thousands of files, and walking it up front would
/// stall the screen for a list nobody may look at.
class ReceivedItemsList extends StatelessWidget {
  const ReceivedItemsList({
    super.key,
    required this.items,
    this.maxHeight = 260,
  });

  final List<ReceivedItem> items;

  /// Past this the list scrolls inside the card instead of pushing the buttons
  /// off the screen.
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    // A flat list of files needs no room for a disclosure arrow; only reserve
    // that column when something here can actually be opened.
    final anyExpandable = items.any((i) => i.isDirectory);

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Scrollbar(
        thumbVisibility: true,
        child: ListView.builder(
          shrinkWrap: true,
          // Right inset is the scrollbar's lane, so the size column never sits
          // under the thumb.
          padding: const EdgeInsets.only(right: 14),
          itemCount: items.length,
          itemBuilder: (context, i) => _EntryRow(
            path: items[i].currentPath,
            name: items[i].name,
            isDirectory: items[i].isDirectory,
            sizeLabel: TransferCache.formatBytes(items[i].size),
            showDisclosureColumn: anyExpandable,
          ),
        ),
      ),
    );
  }
}

/// One line: a file, or a folder that opens.
class _EntryRow extends StatefulWidget {
  const _EntryRow({
    required this.path,
    required this.name,
    required this.isDirectory,
    required this.showDisclosureColumn,
    this.sizeLabel,
    this.depth = 0,
  });

  final String path;
  final String name;
  final bool isDirectory;

  /// Whether to leave space for a disclosure arrow even on file rows, so a
  /// mixed list stays aligned. False for a folder-free list.
  final bool showDisclosureColumn;

  final String? sizeLabel;
  final int depth;

  @override
  State<_EntryRow> createState() => _EntryRowState();
}

class _EntryRowState extends State<_EntryRow> {
  bool _open = false;
  List<FileSystemEntity>? _children;

  void _toggle() {
    setState(() {
      _open = !_open;
      // Listed once and kept: reopening a folder should not re-walk the disk.
      if (_open && _children == null) {
        try {
          _children = Directory(widget.path).listSync(followLinks: false)
            ..sort((a, b) {
              final aDir = a is Directory;
              final bDir = b is Directory;
              // Folders first, then names — the order a file manager uses, and
              // the one that makes a deep tree readable.
              if (aDir != bDir) return aDir ? -1 : 1;
              return p
                  .basename(a.path)
                  .toLowerCase()
                  .compareTo(p.basename(b.path).toLowerCase());
            });
        } on FileSystemException {
          _children = const [];
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final indent = widget.depth * 16.0;
    final childrenAreExpandable =
        (_children ?? const []).any((e) => e is Directory);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: widget.isDirectory ? _toggle : null,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: EdgeInsets.only(left: indent, top: 5, bottom: 5),
            child: Row(
              children: [
                if (widget.isDirectory)
                  Icon(
                    _open
                        ? Icons.keyboard_arrow_down_rounded
                        : Icons.keyboard_arrow_right_rounded,
                    color: AppColors.textSecondary,
                    size: 18,
                  )
                else if (widget.showDisclosureColumn)
                  const SizedBox(width: 18),
                if (widget.isDirectory || widget.showDisclosureColumn)
                  const SizedBox(width: 6),
                Icon(
                  widget.isDirectory
                      ? Icons.folder_rounded
                      : Icons.insert_drive_file_outlined,
                  color: AppColors.primary,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.textPrimary),
                  ),
                ),
                if (widget.sizeLabel != null) ...[
                  const SizedBox(width: 10),
                  Text(
                    widget.sizeLabel!,
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (_open)
          for (final child in _children ?? const <FileSystemEntity>[])
            _EntryRow(
              path: child.path,
              name: p.basename(child.path),
              isDirectory: child is Directory,
              sizeLabel: child is File ? _fileSize(child) : null,
              showDisclosureColumn: childrenAreExpandable,
              depth: widget.depth + 1,
            ),
      ],
    );
  }

  static String? _fileSize(File file) {
    try {
      return TransferCache.formatBytes(file.lengthSync());
    } on FileSystemException {
      return null;
    }
  }
}
