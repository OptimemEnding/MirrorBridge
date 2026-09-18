import 'dart:io';
import 'package:flutter/services.dart';
import '../models/media_item.dart';
import '../protocol/ptp.dart';

/// Phone library I/O and reconciliation. The app controller owns task history;
/// this service never changes the active camera transfer.
class PhoneMediaLibrary {
  MediaItem fromRecord(Map<String, dynamic> record, MediaOrigin fallback) {
    final uri = record['uri'] as String? ?? '';
    final key = record['mediaId'] as String? ?? 'local-$uri';
    final origin =
        fallback != MediaOrigin.manualImport &&
            record['origin'] == 'editorExport'
        ? MediaOrigin.editorExport
        : fallback;
    return MediaItem(
      id: key,
      libraryKey: key,
      name: record['name'] as String? ?? '未命名媒体',
      kind: switch (record['kind']) {
        'raw' => MediaKind.raw,
        'video' => MediaKind.video,
        _ => MediaKind.jpg,
      },
      date: DateTime.fromMillisecondsSinceEpoch(
        (record['dateMs'] as num?)?.toInt() ?? 0,
      ),
      bytes: (record['bytes'] as num?)?.toInt() ?? 0,
      asset: '',
      sourceUri: uri,
      albumUri: fallback == MediaOrigin.albumDiscovery ? uri : '',
      thumbnailPath: record['thumbnail'] as String? ?? '',
      referenceLocation: record['location'] as String? ?? '',
      referencePath: record['referencePath'] as String? ?? '',
      origin: origin,
      exif: Map<String, String>.from(record['exif'] as Map? ?? {})
        ..removeWhere((key, _) => key.toLowerCase().contains('xmp')),
    );
  }

  bool sameAsset(MediaItem a, MediaItem b) =>
      a.libraryKey.isNotEmpty && a.libraryKey == b.libraryKey ||
      a.id == b.id ||
      {a.sourceUri, a.albumUri}
          .where((s) => s.isNotEmpty)
          .any((uri) => uri == b.sourceUri || uri == b.albumUri);

  final _thumbnails = <String, Future<String?>>{};
  Future<String?> thumbnail(MediaItem item) {
    final source = item.sourceUri.isNotEmpty
        ? item.sourceUri
        : item.albumUri.isNotEmpty
        ? item.albumUri
        : item.localPath;
    final key = source;
    return _thumbnails.putIfAbsent(key, () async {
      try {
        final path = await nativeCamera.invokeMethod<String>('thumbnail', {
          'source': source,
        });
        if (path != null) item.thumbnailPath = path;
        return path;
      } finally {
        _thumbnails.remove(key);
      }
    });
  }

  Future<void> refreshItems(List<MediaItem> items) async {
    final referenced = items
        .where((m) => m.albumUri.isNotEmpty || m.sourceUri.isNotEmpty)
        .toList();
    final states = referenced.isEmpty
        ? <dynamic>[]
        : await nativeCamera.invokeListMethod<dynamic>('referenceStates', {
            'uris': referenced
                .map((m) => m.albumUri.isNotEmpty ? m.albumUri : m.sourceUri)
                .toList(),
          });
    for (var i = 0; i < referenced.length; i++) {
      if (states != null && i < states.length) {
        await refreshItem(
          referenced[i],
          state: Map<String, dynamic>.from(states[i] as Map),
        );
      }
    }
    for (final item in items.where(
      (m) => m.albumUri.isEmpty && m.sourceUri.isEmpty,
    )) {
      await refreshItem(item);
    }
  }

  /// Check only a recorded reference. Never enumerate or hash the album.
  Future<bool> refreshItem(
    MediaItem item, {
    Map<String, dynamic>? state,
  }) async {
    final uri = item.albumUri.isNotEmpty ? item.albumUri : item.sourceUri;
    try {
      if (uri.isNotEmpty) {
        state ??= await nativeCamera.invokeMapMethod<String, dynamic>(
          'referenceState',
          {'uri': uri},
        );
        if (state == null) return item.referenceAvailable;
        final location = state['location'] as String? ?? '';
        final bytes = (state['bytes'] as num?)?.toInt() ?? -1;
        item.referenceAvailable =
            state['available'] == true &&
            (bytes < 0 || item.bytes <= 0 || bytes == item.bytes) &&
            (item.referenceLocation.isEmpty ||
                location.isEmpty ||
                item.referenceLocation == location);
        if (item.referenceLocation.isEmpty && location.isNotEmpty) {
          item.referenceLocation = location;
        }
      } else {
        item.referenceAvailable =
            item.localPath.isNotEmpty && await File(item.localPath).exists();
      }
    } on PlatformException {
      item.referenceAvailable = false;
    } on FileSystemException {
      item.referenceAvailable = false;
    }
    return item.referenceAvailable;
  }

  Future<void> delete(MediaItem item) async {
    if (item.origin == MediaOrigin.manualImport &&
        item.sourceUri.isEmpty &&
        item.albumUri.isEmpty) {
      throw StateError('旧版导入未保存原件引用，请重新选择手机原照片建立引用后再删除。');
    }
    final deleted = await nativeCamera.invokeMethod<bool>('deleteLocal', {
      'path': item.localPath,
      'uri': item.albumUri,
      'sourceUri': item.sourceUri,
      'thumbnail': item.thumbnailPath,
    });
    if (deleted != true) throw StateError('手机原媒体未被删除');
  }
}
