import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import 'package:quickshare/core/media/media_library.dart';
import 'package:quickshare/core/theme/app_colors.dart';

/// Grid of the device photo library, multi-select.
///
/// Hand-built rather than delegating to `image_picker` because the whole
/// point is to send the *original* file: image_picker returns a transcoded
/// copy on iOS, and there is no way to map its result back to the asset it
/// came from. photo_manager gives the asset, so the grid has to be ours.
///
/// Pops a `List<MediaEntry>` — already resolved to real files — or null if
/// the user backed out.
class MediaPickerPage extends StatefulWidget {
  final MediaLibrary library;

  const MediaPickerPage({super.key, this.library = const MediaLibrary()});

  @override
  State<MediaPickerPage> createState() => _MediaPickerPageState();
}

class _MediaPickerPageState extends State<MediaPickerPage> {
  static const _pageSize = 90;

  final _assets = <AssetEntity>[];
  final _selected = <String, AssetEntity>{};
  final _scroll = ScrollController();

  MediaAccess? _access;
  bool _loading = true;
  bool _loadingMore = false;
  bool _exhausted = false;
  bool _resolving = false;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
    _start();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final access = await widget.library.requestAccess();
    if (!mounted) return;
    setState(() => _access = access);
    if (access == MediaAccess.denied) {
      setState(() => _loading = false);
      return;
    }
    await _loadMore();
    if (mounted) setState(() => _loading = false);
  }

  void _maybeLoadMore() {
    if (_loadingMore || _exhausted) return;
    if (_scroll.position.pixels >
        _scroll.position.maxScrollExtent - 600) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _exhausted) return;
    _loadingMore = true;
    final batch = await widget.library.loadPage(page: _page, pageSize: _pageSize);
    if (!mounted) return;
    setState(() {
      _assets.addAll(batch);
      _page++;
      _exhausted = batch.length < _pageSize;
      _loadingMore = false;
    });
  }

  void _toggle(AssetEntity asset) {
    setState(() {
      if (_selected.containsKey(asset.id)) {
        _selected.remove(asset.id);
      } else {
        _selected[asset.id] = asset;
      }
    });
  }

  Future<void> _confirm() async {
    if (_selected.isEmpty || _resolving) return;
    setState(() => _resolving = true);

    final result = await widget.library.resolveAll(_selected.values);
    if (!mounted) return;

    if (result.entries.isEmpty) {
      setState(() => _resolving = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'These items are not stored on this device — open them in Photos '
            'once so they download, then try again.'),
      ));
      return;
    }

    if (result.unavailable > 0) {
      // Sending nine of ten beats sending none, but say so rather than
      // quietly dropping items the user picked.
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${result.unavailable} item(s) are only in iCloud and '
            'were skipped.'),
      ));
    }
    Navigator.of(context).pop(result.entries);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.voidBg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(_selected.isEmpty
            ? 'Photos & Videos'
            : '${_selected.length} selected'),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          if (_selected.isNotEmpty)
            TextButton(
              onPressed: _resolving ? null : _confirm,
              child: _resolving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Send'),
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_access == MediaAccess.denied) {
      return _message(
        Icons.no_photography_rounded,
        'DirectDrop has no access to your photos',
        'Grant access in Settings to send photos and videos.',
        action: const TextButton(
          onPressed: PhotoManager.openSetting,
          child: Text('Open Settings'),
        ),
      );
    }
    if (_assets.isEmpty) {
      return _message(
        Icons.photo_library_outlined,
        'Nothing here yet',
        _access == MediaAccess.limited
            ? 'Only some photos are shared with DirectDrop.'
            : 'This device has no photos or videos.',
        action: _access == MediaAccess.limited
            ? const TextButton(
                onPressed: PhotoManager.openSetting,
                child: Text('Choose more'),
              )
            : null,
      );
    }

    return Column(
      children: [
        if (_access == MediaAccess.limited)
          // Easy to mistake a partial library for an empty one.
          Container(
            width: double.infinity,
            color: AppColors.glassFill,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: const Row(
              children: [
                Expanded(
                  child: Text('You have shared only some photos.',
                      style: TextStyle(color: AppColors.textSecondary)),
                ),
                TextButton(
                  onPressed: PhotoManager.openSetting,
                  child: Text('Manage'),
                ),
              ],
            ),
          ),
        Expanded(
          child: GridView.builder(
            controller: _scroll,
            padding: const EdgeInsets.all(2),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 2,
              crossAxisSpacing: 2,
            ),
            itemCount: _assets.length,
            itemBuilder: (context, index) => _tile(_assets[index]),
          ),
        ),
      ],
    );
  }

  Widget _tile(AssetEntity asset) {
    final isSelected = _selected.containsKey(asset.id);
    return GestureDetector(
      onTap: () => _toggle(asset),
      child: Stack(
        fit: StackFit.expand,
        children: [
          AssetEntityImage(
            asset,
            isOriginal: false, // a thumbnail is all a grid cell needs
            thumbnailSize: const ThumbnailSize.square(300),
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
              color: AppColors.glassFill,
              child: const Icon(Icons.broken_image_outlined,
                  color: AppColors.textSecondary),
            ),
          ),
          if (asset.type == AssetType.video)
            Positioned(
              left: 4,
              bottom: 4,
              child: Row(
                children: [
                  const Icon(Icons.play_circle_fill_rounded,
                      color: Colors.white, size: 16),
                  const SizedBox(width: 4),
                  Text(
                    _duration(asset.duration),
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ],
              ),
            ),
          if (isSelected)
            Container(
              color: AppColors.primary.withValues(alpha: 0.35),
              child: const Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.check_circle_rounded,
                      color: Colors.white, size: 22),
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _duration(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  Widget _message(IconData icon, String title, String detail,
      {Widget? action}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: AppColors.textSecondary),
            const SizedBox(height: 16),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(detail,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textSecondary)),
            if (action != null) ...[const SizedBox(height: 16), action],
          ],
        ),
      ),
    );
  }
}
