import 'dart:async';
import 'full_image_page.dart';
import '../models/exif_labels.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/media_item.dart';
import '../protocol/ptp.dart';
import '../state/app_controller.dart';
import '../widgets/media_image.dart';
import '../widgets/shared.dart';
import '../theme/app_theme.dart';
import 'nikon_editor_page.dart';
import '../widgets/photo_insights.dart';

class NikonMediaDetailPage extends StatefulWidget {
  const NikonMediaDetailPage({
    super.key,
    required this.c,
    required this.item,
    required this.local,
  });
  final AppController c;
  final MediaItem item;
  final bool local;
  @override
  State<NikonMediaDetailPage> createState() => _NikonMediaDetailPageState();
}

class _NikonMediaDetailPageState extends State<NikonMediaDetailPage> {
  AppController get c => widget.c;
  MediaItem get item => c.viewingItem(widget.item);
  bool get localSource =>
      item.sourceUri.isNotEmpty ||
      item.albumUri.isNotEmpty ||
      item.localPath.isNotEmpty;
  bool get local => widget.local;
  bool get manual => local && item.origin == MediaOrigin.manualImport;
  Iterable<MapEntry<String, String>> get visibleExif => item.exif.entries.where(
    (entry) =>
        !entry.key.toLowerCase().contains('xmp') &&
        entry.value.trim().isNotEmpty,
  );
  String get referenceLocation => item.referencePath.isNotEmpty
      ? item.referencePath
      : item.referenceLocation.isNotEmpty
      ? '${item.referenceLocation.replaceFirst(RegExp(r"/$"), "")}/${item.name}'
      : item.sourceUri.isNotEmpty
      ? item.sourceUri
      : item.albumUri.isNotEmpty
      ? item.albumUri
      : item.localPath;
  bool reading = false;
  String metadataError = '';
  @override
  void initState() {
    super.initState();
    unawaited(readMetadata());
    if (local || localSource) unawaited(readReferencePath());
  }

  Future<void> readReferencePath() async {
    final uri = item.sourceUri.isNotEmpty ? item.sourceUri : item.albumUri;
    if (uri.isEmpty) return;
    try {
      final path = await nativeCamera.invokeMethod<String>('referencePath', {
        'uri': uri,
      });
      if (mounted && path != null && path.isNotEmpty) {
        setState(() => item.referencePath = path);
      }
    } on PlatformException {
      /* Keep the granted source URI as a truthful fallback. */
    } on MissingPluginException {
      /* No platform in widget tests. */
    }
  }

  Future<void> readMetadata() async {
    if (item.kind == MediaKind.video) return;
    if (local && !localSource) return;
    if (!local && !localSource && c.nikon == null) return;
    setState(() => reading = true);
    try {
      if (local || localSource) {
        final metadata = await nativeCamera
            .invokeMapMethod<String, String>('exif', {
              'source': item.sourceUri.isNotEmpty
                  ? item.sourceUri
                  : item.albumUri.isNotEmpty
                  ? item.albumUri
                  : item.localPath,
            })
            .timeout(const Duration(seconds: 8));
        item.exif = {...item.exif, ...?metadata}
          ..removeWhere((key, _) => key.toLowerCase().contains('xmp'));
        c.changed();
        unawaited(c.save());
      } else {
        await c.nikon!.readMetadata(item);
      }
    } catch (e) {
      if (mounted && !manual) {
        setState(() => metadataError = '暂时无法读取拍摄信息，请确认照片仍可访问。');
      }
    } finally {
      if (mounted) setState(() => reading = false);
    }
  }

  void openImage({bool high = false}) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => c.nikon != null
            ? FullImagePage(
                c: c,
                item: item,
                local: local,
                loadHighResolution: high,
              )
            : Scaffold(
                backgroundColor: Colors.black,
                appBar: AppBar(
                  backgroundColor: Colors.black,
                  foregroundColor: Colors.white,
                ),
                body: Center(
                  child: InteractiveViewer(
                    minScale: .5,
                    maxScale: 5,
                    child: MediaImage(
                      item: item,
                      controller: c,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  Future<void> edit() async {
    if (!localSource && !c.isDemo) {
      if (!c.connected || c.busy) {
        notice(context, '请连接相机并等待当前同步完成');
        return;
      }
      await c.startSync(items: [item]);
      if (!mounted || !localSource) return;
    }
    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => NikonEditorPage(c: c, item: item),
        ),
      );
    }
  }

  Future<void> remove() async {
    if (c.busy) return;
    if (local) {
      final deleteSource = await confirmLocalDeletion(context, 1);
      if (deleteSource == null) return;
      await c.deleteLocal({item.id}, deleteSource: deleteSource);
      if (c.local.any((m) => m.id == item.id)) return;
    } else {
      if (!await confirm(
        context,
        '删除相机文件',
        '将删除相机内的 ${item.name}。请确认已保留需要的照片。',
      )) {
        return;
      }
      await c.deleteCameraItems([item]);
    }
    if (mounted) Navigator.pop(context);
  }

  String value(List<String> keys) {
    for (final key in keys) {
      final raw = item.exif[key];
      if (raw != null && raw.trim().isNotEmpty) return exifValue(key, raw);
    }
    return '—';
  }

  Widget infoRow(IconData icon, String title, String text) => Container(
    constraints: const BoxConstraints(minHeight: 24),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: Color(0xffeef1f5))),
    ),
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Icon(icon, size: 18, color: muted),
        const SizedBox(width: 10),
        SizedBox(
          width: 65,
          child: Text(
            title,
            style: const TextStyle(fontSize: 12, color: muted),
          ),
        ),
        Expanded(
          child: Text(
            text,
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 12, color: Color(0xff586479)),
          ),
        ),
      ],
    ),
  );

  Widget action(
    IconData icon,
    String title,
    VoidCallback? onTap, {
    bool danger = false,
  }) => Expanded(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              children: [
                Icon(icon, size: 23, color: danger ? Colors.red : ink),
                const SizedBox(height: 4),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 11,
                    color: danger ? Colors.red : muted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  void more() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            heading('文件信息', size: 20),
            gap(12),
            Text(item.name),
            gap(8),
            SelectableText('文件路径：$referenceLocation'),
            gap(12),
            if (item.kind == MediaKind.raw) const Text('RAW 保持不变，预览使用内嵌 JPEG。'),
            for (final e in visibleExif)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text(
                  '${exifLabels[e.key] ?? e.key}：${exifValue(e.key, e.value)}',
                ),
              ),
            if (!localSource && !local)
              TextButton.icon(
                onPressed: c.busy
                    ? null
                    : () {
                        Navigator.pop(ctx);
                        c.startSync(items: [item]);
                      },
                icon: const Icon(Icons.download),
                label: const Text('下载相机文件并保存到相册'),
              ),
            TextButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                unawaited(readMetadata());
              },
              icon: const Icon(Icons.refresh),
              label: const Text('刷新拍摄信息'),
            ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        centerTitle: true,
        toolbarHeight: 52,
        title: const Text('照片详情'),
        leading: BackButton(onPressed: () => Navigator.maybePop(context)),
        actions: [
          IconButton(
            tooltip: '更多',
            icon: const Icon(Icons.more_horiz),
            onPressed: more,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: AspectRatio(
              aspectRatio: 1.98,
              child: Semantics(
                label: '点击查看大图',
                button: item.kind != MediaKind.video,
                child: GestureDetector(
                  onTap: item.kind == MediaKind.video
                      ? null
                      : () => openImage(),
                  child: MediaImage(
                    item: item,
                    controller: c,
                    fit: BoxFit.contain,
                    thumbnailOnly: !local && !localSource,
                  ),
                ),
              ),
            ),
          ),
          gap(10),
          Row(
            children: [
              action(Icons.ios_share, '分享', () {
                if (!localSource && !c.isDemo) {
                  notice(context, '请先下载照片再分享');
                  return;
                }
                c.shareItems([item]);
              }),
              action(
                item.kind == MediaKind.video
                    ? Icons.play_arrow_outlined
                    : Icons.file_download_outlined,
                item.kind == MediaKind.video ? '播放' : '原图',
                () async {
                  if (item.kind != MediaKind.video) {
                    openImage(high: true);
                    return;
                  }
                  try {
                    await nativeCamera.invokeMethod('openVideo', {
                      'source': item.sourceUri.isNotEmpty
                          ? item.sourceUri
                          : item.localPath,
                    });
                  } catch (e) {
                    if (context.mounted) {
                      notice(context, '无法打开视频，请确认文件存在并安装可用的播放器。');
                    }
                  }
                },
              ),
              action(
                Icons.edit_outlined,
                '编辑',
                item.kind == MediaKind.video ? null : edit,
              ),
              action(
                Icons.delete_outline,
                '删除',
                c.busy ? null : remove,
                danger: true,
              ),
            ],
          ),
          gap(10),
          ReferenceCard(
            padding: 14,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: ink,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xffedf0f5),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        item.label,
                        style: const TextStyle(fontSize: 10),
                      ),
                    ),
                    IconButton(
                      constraints: const BoxConstraints(
                        minWidth: 40,
                        minHeight: 36,
                      ),
                      padding: EdgeInsets.zero,
                      tooltip: c.isFavorite(item) ? '取消收藏' : '收藏照片',
                      onPressed: () => c.toggleFavorite(item),
                      icon: Icon(
                        c.isFavorite(item)
                            ? Icons.favorite
                            : Icons.favorite_border,
                        color: c.isFavorite(item) ? brandGreen : ink,
                        size: 24,
                      ),
                    ),
                  ],
                ),
                if (reading) const LinearProgressIndicator(minHeight: 2),
                if (c.showExif) ...[
                  infoRow(
                    Icons.image_outlined,
                    '分辨率',
                    '${value(['ImageWidth', 'PixelXDimension'])} × ${value(['ImageLength', 'PixelYDimension'])}',
                  ),
                  infoRow(Icons.camera_outlined, '镜头', value(['LensModel'])),
                  infoRow(
                    Icons.architecture,
                    '焦距',
                    value(['FocalLength']) == '—'
                        ? '—'
                        : '${value(['FocalLength'])} mm',
                  ),
                  infoRow(
                    Icons.camera,
                    '光圈',
                    value(['FNumber', 'ApertureValue']),
                  ),
                  infoRow(
                    Icons.timer_outlined,
                    '快门速度',
                    value(['ExposureTime']),
                  ),
                  infoRow(
                    Icons.iso_outlined,
                    'ISO',
                    value(['PhotographicSensitivity', 'ISOSpeedRatings']),
                  ),
                  infoRow(
                    Icons.calendar_today_outlined,
                    '拍摄时间',
                    value(['DateTimeOriginal', 'DateTime']) == '—'
                        ? item.date.toString().split('.').first
                        : value(['DateTimeOriginal', 'DateTime']),
                  ),
                ],
                infoRow(Icons.insert_drive_file_outlined, '文件大小', item.size),
                infoRow(
                  Icons.photo_camera_outlined,
                  '同步来源',
                  item.origin == MediaOrigin.manualImport
                      ? '手机导入'
                      : item.origin == MediaOrigin.editorExport
                      ? '创意编辑'
                      : value(['Model']) == '—'
                      ? (c.connected ? c.cameraModel : '相机同步')
                      : value(['Model']),
                ),
                if (metadataError.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      metadataError,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
              ],
            ),
          ),
          gap(10),
          PhotoInsights(c: c, item: item),
          gap(10),
          ReferenceCard(
            padding: 12,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.location_on_outlined, color: muted),
              title: const Text(
                '拍摄位置',
                style: TextStyle(fontSize: 12, color: muted),
              ),
              subtitle: Text(
                item.exif['GPSLatitude'] == null
                    ? '未记录位置信息'
                    : '${item.exif['GPSLatitude']} ${item.exif['GPSLatitudeRef'] ?? ''} · ${item.exif['GPSLongitude'] ?? ''} ${item.exif['GPSLongitudeRef'] ?? ''}',
                style: const TextStyle(fontSize: 13),
              ),
              trailing: const Icon(Icons.chevron_right, color: muted),
              onTap: () => showDialog<void>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('拍摄位置'),
                  content: SelectableText(
                    item.exif['GPSLatitude'] == null
                        ? '这张照片没有 GPS 信息。'
                        : '${item.exif['GPSLatitude']} ${item.exif['GPSLatitudeRef'] ?? ''}\n${item.exif['GPSLongitude'] ?? ''} ${item.exif['GPSLongitudeRef'] ?? ''}',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('关闭'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
