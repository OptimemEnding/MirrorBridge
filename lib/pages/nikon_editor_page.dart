import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/media_item.dart';
import '../protocol/ptp.dart';
import '../state/app_controller.dart';
import '../widgets/shared.dart';
import '../theme/app_theme.dart';
import 'lut_manager_page.dart';
part 'editor_reference_layout.dart';

const nikonTemplates = {
  'clean_white': '净白留边',
  'night_frame': '夜色画框',
  'gallery_label': '画廊题签',
  'soft_shadow': '柔影相纸',
  'film_contact': '胶片样张',
  'minimal_line': '极简线框',
  'studio_card': '工作室卡片',
  'focus_grid': '对焦网格',
  'wide_caption': '宽幅说明',
  'compact_caption': '紧凑说明',
};

class NikonEditorPage extends StatefulWidget {
  const NikonEditorPage({super.key, required this.c, this.item});
  final AppController c;
  final MediaItem? item;
  @override
  State<NikonEditorPage> createState() => _NikonEditorPageState();
}

class _NikonEditorPageState extends State<NikonEditorPage> {
  void updateUi(VoidCallback fn) => setState(fn);
  int editorTab = 0;
  bool advanced = false;
  String posterTitle = '';
  String posterSubtitle = '';
  String posterPosition = '左上';
  bool posterEnabled = false;
  double posterX = .06, posterY = .07, posterScale = 1, subtitleScale = 1;
  String posterFont = 'sans-serif';
  int rotation = 0;
  Uint8List? comparisonBytes;
  bool draggingPoster = false;
  bool comparisonRendering = false;
  String _comparisonSource = '';
  MediaItem? item;
  List<String> luts = [];
  List<String> importedLuts = [];
  static const _builtInLuts = <String>{
    'Warm Tone',
    'Cool Tone',
    'Vivid Color',
    'Soft Light',
    'Matte Film',
    'Monochrome',
    'High Contrast',
    'Sepia Print',
  };
  String preview = '', error = '', lut = '', template = '';
  double intensity = .5, border = .5;
  double captionX = .5, captionY = 1, captionScale = 1;
  String captionAlignment = 'center';
  bool comparing = false;
  int resetVersion = 0;
  bool details = true, rendering = false, exporting = false;
  bool importingLut = false;
  int generation = 0;
  Timer? debounce;
  Uint8List? previewBytes;
  Uint8List? originalPreviewBytes;
  String rawEditSource = '', demoEditSource = '';
  final _rawSources = <String>{};
  bool _disposed = false;
  double previewAspect = 1.5;
  bool _renderActive = false;
  String selectedCaption = 'model';
  late Map<String, Map<String, dynamic>> captionStyles;
  Map<String, dynamic> get selectedStyle => captionStyles[selectedCaption]!;
  String readableError(Object e) {
    debugPrint('Editor: $e');
    if (e is PlatformException && '${e.message}'.contains('ENOENT')) {
      return '预览文件已失效，请重新选择照片。';
    }
    return '照片处理失败，请重试或重新选择照片。';
  }

  AppController get c => widget.c;
  String get source => demoEditSource.isNotEmpty
      ? demoEditSource
      : item == null
      ? ''
      : item!.kind == MediaKind.raw
      ? rawEditSource
      : item!.sourceUri.isNotEmpty
      ? item!.sourceUri
      : item!.localPath;
  @override
  void initState() {
    super.initState();
    item =
        widget.item ??
        c.visibleLocal.where((m) => m.kind != MediaKind.video).firstOrNull;
    lut = c.lut;
    template = c.watermark ? c.template : '';
    intensity = c.intensity;
    border = c.border;
    details = c.showExif;
    captionX = c.captionX;
    captionY = c.captionY;
    captionScale = c.captionScale;
    captionAlignment = c.captionAlignment;
    captionStyles = {
      for (final entry in {'model': .18, 'exposure': .5, 'time': .82}.entries)
        entry.key: {
          'x': .5,
          'y': entry.value,
          'scale': 1.0,
          'font': 'sans-serif',
          'bold': false,
          'italic': false,
          'edge': 'bottom',
          'enabled': true,
          ...?c.captionStyles[entry.key],
        },
    };
    rootBundle.loadString('assets/luts.json').then((s) {
      if (mounted) {
        setState(() {
          luts = List<String>.from(jsonDecode(s));
          importedLuts = [];
          importedLuts.addAll(c.importedLuts);
          if (lut.isNotEmpty && !_builtInLuts.contains(lut)) {
            luts.add(lut);
            importedLuts.add(lut);
          }
          for (final l in importedLuts) {
            if (!luts.contains(l)) luts.add(l);
          }
        });
      }
    });
    final poster = c.captionStyles['poster'];
    if (poster != null) {
      // Each new photograph starts with empty captions; style preferences persist.
      posterX = (poster['x'] as num?)?.toDouble() ?? .06;
      posterY = (poster['y'] as num?)?.toDouble() ?? .07;
      posterScale = (poster['scale'] as num?)?.toDouble() ?? 1;
      subtitleScale = (poster['subtitleScale'] as num?)?.toDouble() ?? 1;
      posterFont = poster['font'] as String? ?? 'sans-serif';
      posterPosition = poster['position'] as String? ?? '左上';
      posterEnabled = poster['enabled'] != false;
    } else {
      template = '';
      intensity = .7;
    }
    prepareSource();
  }

  Future<void> prepareSource() async {
    final preparingItem = item;
    if (c.isDemo && item != null && source.isEmpty && item!.asset.isNotEmpty) {
      final data = await rootBundle.load(item!.asset);
      final bytes = data.buffer.asUint8List();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final aspect = frame.image.width / frame.image.height;
      frame.image.dispose();
      codec.dispose();
      if (!mounted || item != preparingItem) return;
      setState(() {
        previewBytes = bytes;
        originalPreviewBytes = bytes;
        previewAspect = aspect;
      });
      try {
        final dirs = await nativeCamera.invokeMapMethod<String, dynamic>(
          'directories',
        );
        if (dirs?['cache'] != null && mounted) {
          final dir = Directory('${dirs!['cache']}/editor_render');
          await dir.create(recursive: true);
          final file = File(
            '${dir.path}/demo-${DateTime.now().microsecondsSinceEpoch}.png',
          );
          await file.writeAsBytes(bytes);
          if (!mounted) {
            await file.delete();
            return;
          }
          demoEditSource = file.path;
          _rawSources.add(file.path);
          schedule();
        }
      } on MissingPluginException {
        /* Widget previews have no native image bridge. */
      } on PlatformException {
        /* The demo still displays its unedited asset. */
      }

      return;
    }
    if (item?.kind == MediaKind.raw &&
        (item!.localPath.isNotEmpty || item!.sourceUri.isNotEmpty)) {
      try {
        final path = await nativeCamera.invokeMethod<String>('editSource', {
          'source': item!.sourceUri.isNotEmpty
              ? item!.sourceUri
              : item!.localPath,
        });
        if (!mounted || item != preparingItem) {
          if (path != null && path.contains('editor_render')) {
            try {
              await File(path).delete();
            } catch (_) {}
          }
          return;
        }
        if (path != null) {
          rawEditSource = path;
          _rawSources.add(path);
        }
      } catch (e) {
        if (mounted) setState(() => error = readableError(e));
      }
    }
    if (mounted && item == preparingItem && source.isNotEmpty) {
      schedule();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    generation++;
    debounce?.cancel();
    super.dispose();
    releaseRawSources();
  }

  void releaseRawSources() {
    if (!_disposed || _renderActive || exporting) return;
    for (final path in _rawSources.where((p) => p.contains('editor_render'))) {
      unawaited(File(path).delete().catchError((Object _) => File(path)));
    }
    _rawSources.clear();
  }

  void schedule() {
    final token = ++generation;
    if (mounted && source.isNotEmpty) {
      setState(() {
        rendering = true;
        // Any real edit should immediately return to the edited preview. Keeping
        // comparison mode active makes newly-applied settings look as if they
        // disappeared when the user changes menus.
        comparing = false;
        comparisonBytes = null;
        _comparisonSource = '';
      });
    }
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 300), () => render(token));
  }

  Map<String, dynamic> args({bool full = false}) => {
    'path': source,
    'exifPath': item?.sourceUri.isNotEmpty == true
        ? item!.sourceUri
        : item?.localPath,
    'lut': lut,
    'intensity': intensity,
    'template': template,
    'border': border,
    'details': details,
    'captionX': captionX,
    'captionY': captionY,
    'captionScale': captionScale,
    'captionAlignment': captionAlignment,
    'captionStyles': {
      ...captionStyles,
      'poster': {
        'title': posterTitle,
        'subtitle': posterSubtitle,
        'position': posterPosition,
        'enabled': posterEnabled,
        'layout': 'photo',
        'x': posterX,
        'y': posterY,
        'font': posterFont,
        'scale': posterScale,
        'subtitleScale': subtitleScale,
        'rotation': rotation,
      },
    },
    if (!full) 'maxDimension': 1600,
  };
  Future<void> render(int token) async {
    if (!mounted || source.isEmpty || _renderActive || token != generation) {
      return;
    }
    _renderActive = true;
    setState(() {
      rendering = true;
      error = '';
    });
    String? result;
    try {
      final renderArgs = args();
      result = await nativeCamera.invokeMethod<String>('effect', renderArgs);
      if (result == null) throw StateError('未返回预览');
      final bytes = await File(result).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final aspect = frame.image.width / frame.image.height;
      frame.image.dispose();
      codec.dispose();
      if (mounted && token == generation) {
        setState(() {
          preview = result!;
          previewBytes = bytes;
          previewAspect = aspect;
        });
      }
    } catch (e) {
      if (mounted && token == generation) {
        setState(() => error = readableError(e));
      }
    } finally {
      if (result != null &&
          result != source &&
          result.contains('editor_render')) {
        try {
          await File(result).delete();
        } catch (_) {}
      }
      _renderActive = false;
      releaseRawSources();
      if (mounted) {
        if (token != generation) {
          unawaited(render(generation));
        } else {
          setState(() => rendering = false);
        }
      }
    }
  }

  Future<void> toggleComparison() async {
    if (!mounted || comparisonRendering) return;
    if (comparing) {
      setState(() => comparing = false);
      return;
    }
    final compareSource = source;
    if (comparisonBytes != null &&
        (_comparisonSource == compareSource || compareSource.isEmpty)) {
      setState(() => comparing = true);
      return;
    }
    if (compareSource.isEmpty) {
      setState(() {
        comparisonBytes = originalPreviewBytes ?? previewBytes;
        _comparisonSource = '';
        comparing = true;
      });
      return;
    }
    if (rendering) return;

    final comparisonArgs =
        jsonDecode(jsonEncode(args())) as Map<String, dynamic>;
    comparisonArgs['lut'] = '';
    comparisonArgs['template'] = '';
    comparisonArgs['border'] = 0.0;
    comparisonArgs['details'] = false;
    comparisonArgs['maxDimension'] = 1600;
    final styles = comparisonArgs['captionStyles'] as Map;
    (styles['poster'] as Map)
      ..['enabled'] = false
      ..['rotation'] = 0;

    setState(() => comparisonRendering = true);
    String? result;
    try {
      result = await nativeCamera.invokeMethod<String>(
        'effect',
        comparisonArgs,
      );
      if (result == null) throw StateError('未返回对比预览');
      final bytes = await File(result).readAsBytes();
      if (mounted && source == compareSource) {
        setState(() {
          comparisonBytes = bytes;
          _comparisonSource = compareSource;
          comparing = true;
        });
      }
    } catch (e) {
      if (mounted && source == compareSource) {
        setState(() => error = readableError(e));
      }
    } finally {
      if (result != null &&
          result != compareSource &&
          result.contains('editor_render')) {
        try {
          await File(result).delete();
        } catch (_) {}
      }
      if (mounted) setState(() => comparisonRendering = false);
    }
  }

  Future<void> choose() async {
    final imported = await c.chooseImageReference();
    if (!mounted) return;
    if (imported != null) {
      generation++;
      debounce?.cancel();
      setState(() {
        item = imported;
        rawEditSource = '';
        demoEditSource = '';
        preview = '';
        previewBytes = null;
        comparisonBytes = null;
        originalPreviewBytes = null;
        _comparisonSource = '';
        comparing = false;
        rendering = false;
        comparisonRendering = false;
      });
      await prepareSource();
    } else if (c.message.isNotEmpty) {
      setState(() => error = c.message);
    }
  }

  Future<void> saveSettings() async {
    c.lut = lut;
    c.importedLuts = importedLuts;
    c.intensity = intensity;
    c.watermark = template.isNotEmpty;
    if (template.isNotEmpty) c.template = template;
    c.border = border;
    c.showExif = details;
    c.captionX = captionX;
    c.captionY = captionY;
    c.captionScale = captionScale;
    c.captionAlignment = captionAlignment;
    captionStyles['poster'] = {
      'title': posterTitle,
      'subtitle': posterSubtitle,
      'position': posterPosition,
      'enabled': posterEnabled,
      'layout': 'photo',
      'x': posterX,
      'y': posterY,
      'font': posterFont,
      'scale': posterScale,
      'subtitleScale': subtitleScale,
    };
    c.captionStyles = captionStyles.map(
      (key, value) => MapEntry(key, Map<String, dynamic>.from(value)),
    );
    await c.save();
  }

  Future<void> export() async {
    if (source.isEmpty || exporting) return;
    setState(() {
      exporting = true;
      error = '';
    });
    String? generatedOutput;
    try {
      await saveSettings();
      final output = await nativeCamera.invokeMethod<String>(
        'effect',
        args(full: true),
      );
      generatedOutput = output;
      if (output == null) throw StateError('处理未返回图片');
      final dirs = await nativeCamera.invokeMapMethod<String, dynamic>(
        'directories',
      );
      final id = 'edit-${DateTime.now().microsecondsSinceEpoch}';
      final name =
          '${item!.name.replaceFirst(RegExp(r'\.[^.]+$'), '')}_edited.jpg';
      final file = await File(output).copy('${dirs!['media']}/$id.jpg');
      final uri =
          await nativeCamera.invokeMethod<String>('publish', {
            'path': file.path,
            'name': name,
            'origin': 'editorExport',
          }) ??
          '';
      if (uri.isEmpty) throw StateError('系统相册发布失败');
      final bytes = await file.length();
      await nativeCamera.invokeMethod('releasePublishedCopy', {
        'path': file.path,
        'uri': uri,
      });
      final exported = MediaItem(
        id: id,
        name: name,
        kind: MediaKind.jpg,
        date: item!.date,
        bytes: bytes,
        asset: '',
        sourceUri: uri,
        albumUri: uri,
        origin: MediaOrigin.editorExport,
        exif: Map.of(item!.exif),
      );
      await c.addEditorExport(exported);
      if (mounted) notice(context, '效果副本已保存到镜桥相册。');
    } catch (e) {
      if (mounted) setState(() => error = readableError(e));
    } finally {
      if (generatedOutput != null &&
          generatedOutput.contains('editor_render')) {
        try {
          await File(generatedOutput).delete();
        } catch (_) {}
      }
      exporting = false;
      releaseRawSources();
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) => _referencePage(context);

  Widget _exifSettings() => ReferenceCard(
    key: const ValueKey('exif-settings'),
    padding: 16,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('EXIF 拍摄信息'),
          subtitle: template.isEmpty ? const Text('未添加边框时，信息显示在照片内') : null,
          value: details,
          onChanged: exporting
              ? null
              : (v) {
                  setState(() => details = v);
                  schedule();
                },
        ),
        if (details) ...[
          Wrap(
            spacing: 8,
            children: [
              for (final e in const {
                'model': '机型',
                'exposure': '曝光三要素',
                'time': '拍摄时间',
              }.entries)
                ChoiceChip(
                  label: Text(e.value),
                  selected: selectedCaption == e.key,
                  onSelected: (_) => setState(() => selectedCaption = e.key),
                ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('显示此项'),
            value: selectedStyle['enabled'] != false,
            onChanged: exporting
                ? null
                : (v) {
                    setState(() => selectedStyle['enabled'] = v);
                    schedule();
                  },
          ),
          DropdownButtonFormField<String>(
            key: ValueKey('font-$selectedCaption-${selectedStyle['font']}'),
            initialValue: selectedStyle['font'] as String,
            decoration: const InputDecoration(labelText: '字体'),
            isExpanded: true,
            items: [
              for (final e in const {
                'sans-serif': '现代黑体',
                'sans-serif-light': '轻盈细体',
                'sans-serif-condensed': '紧凑黑体',
                'serif': '经典衬线',
                'monospace': '等宽字体',
                'cursive': '手写花体',
                'casual': '艺术手写',
              }.entries)
                DropdownMenuItem(value: e.key, child: Text(e.value)),
            ],
            onChanged: exporting
                ? null
                : (v) {
                    setState(() => selectedStyle['font'] = v!);
                    schedule();
                  },
          ),
          Wrap(
            spacing: 8,
            children: [
              for (final e in const {'bold': '加粗', 'italic': '斜体'}.entries)
                FilterChip(
                  label: Text(e.value),
                  selected: selectedStyle[e.key] == true,
                  onSelected: exporting
                      ? null
                      : (v) {
                          setState(() => selectedStyle[e.key] = v);
                          schedule();
                        },
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final e in const {'top': '顶部边缘', 'bottom': '底部边缘'}.entries)
                ChoiceChip(
                  label: Text(e.value),
                  selected: selectedStyle['edge'] == e.key,
                  onSelected: exporting
                      ? null
                      : (_) {
                          setState(() => selectedStyle['edge'] = e.key);
                          schedule();
                        },
                ),
            ],
          ),
          for (final e in const {
            'scale': '字号',
            'x': '水平位置',
            'y': '边缘内垂直位置',
          }.entries) ...[
            Text(
              '${e.value} ${((selectedStyle[e.key] as num) * 100).round()}%',
            ),
            Slider(
              key: ValueKey('caption-${e.key}'),
              value: (selectedStyle[e.key] as num).toDouble(),
              min: e.key == 'scale' ? .5 : 0,
              max: e.key == 'scale' ? 2 : 1,
              onChanged: exporting
                  ? null
                  : (v) {
                      setState(() => selectedStyle[e.key] = v);
                      schedule();
                    },
            ),
          ],
          TextButton(
            onPressed: exporting
                ? null
                : () {
                    setState(
                      () => captionStyles[selectedCaption] = {
                        'x': .5,
                        'y': {
                          'model': .18,
                          'exposure': .5,
                          'time': .82,
                        }[selectedCaption]!,
                        'scale': 1.0,
                        'font': 'sans-serif',
                        'bold': false,
                        'italic': false,
                        'edge': 'bottom',
                        'enabled': true,
                      },
                    );
                    schedule();
                  },
            child: const Text('重置此项排版'),
          ),
        ],
      ],
    ),
  );
}
