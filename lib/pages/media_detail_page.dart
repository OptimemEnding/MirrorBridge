import 'package:flutter/material.dart';
import '../models/media_item.dart';
import '../state/app_controller.dart';
import 'nikon_media_detail_page.dart';

class MediaDetailPage extends StatelessWidget {
  const MediaDetailPage({
    super.key,
    required this.c,
    required this.item,
    this.isLocal = false,
  });
  final AppController c;
  final MediaItem item;
  final bool isLocal;
  @override
  Widget build(BuildContext context) =>
      NikonMediaDetailPage(c: c, item: item, local: isLocal);
}
