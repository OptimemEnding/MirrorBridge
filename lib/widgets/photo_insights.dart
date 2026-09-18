import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/media_item.dart';
import '../state/app_controller.dart';
import '../theme/app_theme.dart';
import 'shared.dart';
import 'media_image.dart';

class PhotoInsights extends StatefulWidget {
  const PhotoInsights({super.key, required this.c, required this.item});
  final AppController c;
  final MediaItem item;
  @override
  State<PhotoInsights> createState() => _PhotoInsightsState();
}

class _PhotoInsightsState extends State<PhotoInsights> {
  List<List<int>>? bins;
  List<Color> colors = [];
  String? error;
  @override
  void initState() {
    super.initState();
    analyze();
  }

  Future<void> analyze() async {
    try {
      final item = widget.item;
      final bytes = item.asset.isNotEmpty
          ? (await rootBundle.load(item.asset)).buffer.asUint8List()
          : await File(
              await widget.c.thumbnailFor(item) ?? item.thumbnailPath,
            ).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 128);
      final frame = await codec.getNextFrame();
      final pixels = await frame.image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      frame.image.dispose();
      codec.dispose();
      if (pixels == null) throw StateError('无法分析图片');
      final channels = List.generate(3, (_) => List.filled(64, 0));
      final palette = <int, int>{};
      for (var i = 0; i < pixels.lengthInBytes; i += 4) {
        if (pixels.getUint8(i + 3) < 128) continue;
        final r = pixels.getUint8(i),
            g = pixels.getUint8(i + 1),
            b = pixels.getUint8(i + 2);
        channels[0][r ~/ 4]++;
        channels[1][g ~/ 4]++;
        channels[2][b ~/ 4]++;
        final key = ((r ~/ 32) << 6) | ((g ~/ 32) << 3) | (b ~/ 32);
        palette[key] = (palette[key] ?? 0) + 1;
      }
      final ranked = palette.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      if (mounted) {
        setState(() {
          bins = channels;
          colors = ranked
              .take(5)
              .map(
                (e) => Color.fromARGB(
                  255,
                  ((e.key >> 6) & 7) * 32 + 16,
                  ((e.key >> 3) & 7) * 32 + 16,
                  (e.key & 7) * 32 + 16,
                ),
              )
              .toList();
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = '预览载入后可分析');
    }
  }

  Widget chart() => bins == null
      ? Center(
          child: Text(error ?? '正在分析…', style: const TextStyle(fontSize: 11)),
        )
      : CustomPaint(painter: RgbPhotoHistogram(bins!), size: Size.infinite);

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: InkWell(
          onTap: () => showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('RGB 直方图'),
              content: SizedBox(width: 500, height: 200, child: chart()),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('关闭'),
                ),
              ],
            ),
          ),
          child: ReferenceCard(
            padding: 12,
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(child: heading('直方图', size: 15)),
                    const Icon(Icons.chevron_right, size: 18, color: muted),
                  ],
                ),
                const SizedBox(height: 10),
                SizedBox(height: 62, child: chart()),
              ],
            ),
          ),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: InkWell(
          onTap: () => showModalBottomSheet<void>(
            context: context,
            builder: (ctx) => SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    heading('主要色彩', size: 20),
                    gap(12),
                    const Text('根据照片预览像素统计，点击复制色值'),
                    gap(12),
                    for (final color in colors)
                      ListTile(
                        leading: CircleAvatar(backgroundColor: color),
                        title: Text(
                          '#${color.toARGB32().toRadixString(16).substring(2).toUpperCase()}',
                        ),
                        trailing: const Icon(Icons.copy, size: 18),
                        onTap: () async {
                          await Clipboard.setData(
                            ClipboardData(
                              text:
                                  '#${color.toARGB32().toRadixString(16).substring(2).toUpperCase()}',
                            ),
                          );
                          if (ctx.mounted) notice(ctx, '色值已复制');
                        },
                      ),
                    if (colors.isEmpty) Text(error ?? '正在分析…'),
                  ],
                ),
              ),
            ),
          ),
          child: ReferenceCard(
            padding: 12,
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(child: heading('主要色彩', size: 15)),
                    const Icon(Icons.chevron_right, size: 18, color: muted),
                  ],
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 62,
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: MediaImage(
                          item: widget.item,
                          controller: widget.c,
                          width: 44,
                          height: 58,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Wrap(
                          spacing: 3,
                          runSpacing: 3,
                          children: colors
                              .map(
                                (c) => Container(
                                  width: 13,
                                  height: 13,
                                  decoration: BoxDecoration(
                                    color: c,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              )
                              .toList(),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}

class RgbPhotoHistogram extends CustomPainter {
  RgbPhotoHistogram(this.bins);
  final List<List<int>> bins;
  @override
  void paint(Canvas canvas, Size size) {
    final peak = bins.expand((e) => e).fold<int>(1, math.max);
    for (final channel in [2, 1, 0]) {
      final path = Path()..moveTo(0, size.height);
      for (var x = 0; x < 64; x++) {
        path.lineTo(
          x / 63 * size.width,
          size.height * (1 - math.sqrt(bins[channel][x] / peak) * .96),
        );
      }
      path.lineTo(size.width, size.height);
      path.close();
      canvas.drawPath(
        path,
        Paint()
          ..color = [
            const Color(0x99ef5350),
            const Color(0x996acb78),
            const Color(0x995b8df6),
          ][channel],
      );
    }
  }

  @override
  bool shouldRepaint(RgbPhotoHistogram oldDelegate) => oldDelegate.bins != bins;
}
