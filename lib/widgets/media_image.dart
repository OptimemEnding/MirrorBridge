import 'dart:io';
import 'package:flutter/material.dart';
import '../models/media_item.dart';
import '../state/app_controller.dart';

class MediaImage extends StatelessWidget {
  const MediaImage({
    super.key,
    required this.item,
    this.controller,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.thumbnailOnly = false,
  });
  final MediaItem item;
  final bool thumbnailOnly;
  final AppController? controller;
  final BoxFit fit;
  final double? width, height;
  Widget _placeholder() => SizedBox(
    width: width,
    height: height,
    child: ColoredBox(
      color: const Color(0xffe9edf3),
      child: Center(
        child: Icon(
          item.kind == MediaKind.video
              ? Icons.videocam_outlined
              : item.kind == MediaKind.raw
              ? Icons.raw_on
              : Icons.photo_outlined,
          color: Colors.blueGrey,
        ),
      ),
    ),
  );
  int? _cacheWidth(BuildContext context) => fit == BoxFit.cover
      ? width == null
            ? 640
            : (width! * MediaQuery.devicePixelRatioOf(context)).ceil().clamp(
                1,
                640,
              )
      : null;

  Widget _image(BuildContext context, String? path) {
    if (path == null || path.isEmpty) return _placeholder();
    return Image.file(
      File(path),
      width: width,
      height: height,
      fit: fit,
      cacheWidth: _cacheWidth(context),
      errorBuilder: (_, e, stack) =>
          !thumbnailOnly &&
              path == item.thumbnailPath &&
              item.kind == MediaKind.jpg &&
              item.localPath.isNotEmpty &&
              item.localPath != path
          ? _image(context, item.localPath)
          : _placeholder(),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (item.asset.isNotEmpty) {
      return Image.asset(
        item.asset,
        width: width,
        height: height,
        fit: fit,
        cacheWidth: _cacheWidth(context),
      );
    }
    final path = thumbnailOnly
        ? item.thumbnailPath
        : fit == BoxFit.cover && item.thumbnailPath.isNotEmpty
        ? item.thumbnailPath
        : item.kind == MediaKind.jpg && item.localPath.isNotEmpty
        ? item.localPath
        : item.thumbnailPath;
    if (path.isNotEmpty && File(path).existsSync()) {
      return _image(context, path);
    }
    if (controller?.nikon == null) return _placeholder();
    return FutureBuilder<String?>(
      future: controller!.thumbnailFor(item),
      builder: (context, snapshot) => _image(context, snapshot.data),
    );
  }
}
