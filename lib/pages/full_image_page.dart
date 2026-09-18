import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import '../protocol/ptp.dart';
import 'package:flutter/material.dart';
import '../models/media_item.dart';
import '../state/app_controller.dart';
import '../widgets/media_image.dart';

class FullImagePage extends StatefulWidget {
  const FullImagePage({
    super.key,
    required this.c,
    required this.item,
    this.local = false,
    this.loadHighResolution = false,
  });
  final AppController c;
  final MediaItem item;
  final bool local;
  final bool loadHighResolution;
  @override
  State<FullImagePage> createState() => _FullImagePageState();
}

class _FullImagePageState extends State<FullImagePage>
    with SingleTickerProviderStateMixin {
  String path = '', error = '';
  Uint8List? imageBytes;
  ImageProvider get fullImage =>
      imageBytes != null ? MemoryImage(imageBytes!) : FileImage(File(path));
  int quarterTurns = 0;
  double? progress;
  bool loading = false;
  bool disposed = false;
  Offset doubleTapPosition = Offset.zero;
  late final repository = widget.c.nikon!;
  late final viewItem = widget.c.viewingItem(widget.item);
  bool get hasLocalSource =>
      viewItem.sourceUri.isNotEmpty ||
      viewItem.albumUri.isNotEmpty ||
      viewItem.localPath.isNotEmpty;
  final transform = TransformationController();
  late final AnimationController zoomAnimation;
  Matrix4Tween? _zoomTween;

  void animateZoom(Matrix4 target) {
    zoomAnimation.stop();
    _zoomTween = Matrix4Tween(begin: transform.value.clone(), end: target);
    zoomAnimation.forward(from: 0);
  }

  void resetTransform() {
    zoomAnimation.stop();
    transform.value = Matrix4.identity();
  }

  @override
  void initState() {
    super.initState();
    zoomAnimation =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 200),
        )..addListener(() {
          final tween = _zoomTween;
          if (tween != null) {
            transform.value = tween.transform(
              Curves.easeOutCubic.transform(zoomAnimation.value),
            );
          }
        });
    if (widget.local || widget.loadHighResolution || hasLocalSource) load();
  }

  Future<void> load() async {
    if (loading || disposed) return;
    setState(() {
      loading = true;
      progress = null;
      error = '';
    });
    try {
      final source = await repository.prepareViewingSource(
        viewItem,
        cancelled: () => disposed,
        progress: (n, total) {
          if (mounted) setState(() => progress = total > 0 ? n / total : null);
        },
      );
      final bytes = !disposed && source.startsWith('content://')
          ? await nativeCamera.invokeMethod<Uint8List>('readImageBytes', {
              'source': source,
            })
          : null;
      if (!disposed && source.startsWith('content://') && bytes == null) {
        throw StateError('无法读取本地图片');
      }
      if (disposed) {
        await repository.releaseViewingSource(source);
      } else {
        setState(() {
          path = source;
          imageBytes = bytes;
          resetTransform();
        });
      }
    } catch (e) {
      debugPrint('Full image: $e');
      if (mounted) {
        setState(
          () => error = '暂时无法打开原图。照片可能已移动、删除或访问权限已失效，请重新选择照片；相机照片请检查连接后重试。',
        );
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    disposed = true;
    if (path.isNotEmpty) unawaited(fullImage.evict());
    if (path.isNotEmpty) unawaited(repository.releaseViewingSource(path));
    zoomAnimation.dispose();
    transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      title: Text(
        path.isEmpty && !widget.local
            ? '相机照片预览'
            : widget.item.kind == MediaKind.raw
            ? 'RAW 内嵌大图'
            : '全尺寸照片',
      ),
      actions: [
        IconButton(
          tooltip: '顺时针旋转 90°',
          onPressed: path.isEmpty
              ? null
              : () => setState(() {
                  quarterTurns = (quarterTurns + 1) % 4;
                  resetTransform();
                }),
          icon: const Icon(Icons.rotate_right),
        ),
        IconButton(
          tooltip: '还原缩放',
          onPressed: () => animateZoom(Matrix4.identity()),
          icon: const Icon(Icons.fit_screen),
        ),
      ],
    ),
    body: Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          onDoubleTapDown: (details) =>
              doubleTapPosition = details.localPosition,
          onDoubleTap: () {
            if (transform.value.getMaxScaleOnAxis() > 1.01) {
              animateZoom(Matrix4.identity());
            } else {
              animateZoom(
                Matrix4.identity()
                  ..translateByDouble(
                    -doubleTapPosition.dx * 2,
                    -doubleTapPosition.dy * 2,
                    0,
                    1,
                  )
                  ..scaleByDouble(3, 3, 1, 1),
              );
            }
          },
          child: InteractiveViewer(
            onInteractionStart: (_) => zoomAnimation.stop(),
            transformationController: transform,
            minScale: 1,
            maxScale: 12,
            child: RotatedBox(
              quarterTurns: quarterTurns,
              child: Center(
                child: path.isEmpty
                    ? MediaImage(
                        item: viewItem,
                        controller: widget.c,
                        fit: BoxFit.contain,
                        thumbnailOnly: !widget.local,
                      )
                    : Image(
                        image: fullImage,
                        fit: BoxFit.contain,
                        errorBuilder: (_, e, stack) => const Text(
                          '无法解码此图片',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
              ),
            ),
          ),
        ),
        if (!widget.local &&
            !hasLocalSource &&
            path.isEmpty &&
            !loading &&
            error.isEmpty)
          Positioned(
            left: 16,
            right: 16,
            bottom: 64,
            child: Center(
              child: FilledButton.icon(
                onPressed: load,
                icon: const Icon(Icons.hd_outlined),
                label: const Text('加载高清图'),
              ),
            ),
          ),
        if (loading)
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(value: progress),
                const SizedBox(height: 16),
                Text(
                  progress == null
                      ? '正在读取相机文件…'
                      : '正在读取相机文件 ${(progress! * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(color: Colors.white),
                ),
              ],
            ),
          ),
        if (error.isNotEmpty)
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(error, style: const TextStyle(color: Colors.white)),
                TextButton(onPressed: load, child: const Text('重试')),
              ],
            ),
          ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 20,
          child: IgnorePointer(
            child: Text(
              widget.item.kind == MediaKind.raw
                  ? '双击或双指缩放 · 显示 RAW 内嵌 JPEG，不是 RAW 显影'
                  : '双击或双指缩放',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
          ),
        ),
      ],
    ),
  );
}
