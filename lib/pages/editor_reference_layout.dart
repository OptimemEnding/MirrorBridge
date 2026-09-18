part of 'nikon_editor_page.dart';

String _lutName(String value) => switch (value) {
  'Warm Tone' => 'Warm Tone · 暖调金色',
  'Cool Tone' => 'Cool Tone · 城市电影',
  'Vivid Color' => 'Vivid Color · 鲜艳通透',
  'Soft Light' => 'Soft Light · 柔光人像',
  'Matte Film' => 'Matte Film · 哑光胶片',
  'Monochrome' => 'Monochrome · 黑白影调',
  'High Contrast' => 'High Contrast · 高反差戏剧',
  'Sepia Print' => 'Sepia Print · 棕褐复古',
  _ => value,
};

extension _ReferenceEditor on _NikonEditorPageState {
  void _change(VoidCallback action) {
    updateUi(action);
    schedule();
  }

  Future<void> _importLut() async {
    if (importingLut || exporting) return;
    updateUi(() => importingLut = true);
    try {
      final selected = await nativeCamera.invokeMethod<String>('pick', {
        'kind': 'cube',
      });
      if (selected != null && mounted) {
        _change(() {
          if (!luts.contains(selected)) {
            luts.add(selected);
            importedLuts.add(selected);
          }
          lut = selected;
        });
      }
    } catch (e) {
      if (mounted) notice(context, 'LUT 文件无效，请选择符合 3D Cube 格式的 .cube 文件。');
    } finally {
      if (mounted) updateUi(() => importingLut = false);
    }
  }

  Widget _referencePage(BuildContext context) => Scaffold(
    appBar: AppBar(
      centerTitle: true,
      toolbarHeight: 52,
      leading: IconButton(
        tooltip: '返回',
        icon: const Icon(Icons.arrow_back_ios_new, size: 23),
        onPressed: exporting
            ? null
            : () {
                if (advanced) {
                  updateUi(() => advanced = false);
                } else {
                  Navigator.maybePop(context);
                }
              },
      ),
      title: Text(
        advanced ? '高级 EXIF 排版' : '创意编辑',
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
      ),
      actions: [
        if (advanced)
          TextButton(
            onPressed: exporting
                ? null
                : () async {
                    await saveSettings();
                    if (context.mounted) notice(context, '处理配方已保存');
                  },
            child: const Text('保存配方'),
          ),

        TextButton(
          onPressed: exporting ? null : _resetPoster,
          child: const Text('重置'),
        ),
      ],
    ),
    body: SafeArea(
      top: false,
      bottom: false,
      child: LayoutBuilder(
        builder: (context, box) {
          final wide = box.maxWidth >= 560 && box.maxWidth > box.maxHeight;
          final controls = <Widget>[
            if (advanced)
              _exifSettings()
            else ...[
              if (editorTab == 0) _borderSettings(),
              if (editorTab == 1) _colorSettings(),
              if (editorTab == 2) _textSettings(),
              if (editorTab == 3) _exportSettings(),
            ],
            if (error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(error, style: const TextStyle(color: Colors.red)),
              ),
            const SizedBox(height: 10),
            Pill(
              exporting ? '正在导出…' : '导出海报',
              onPressed: exporting || item == null
                  ? null
                  : () {
                      if (source.isEmpty) {
                        notice(context, '演示照片可用于预览，请选择手机照片后导出。');
                        return;
                      }
                      export();
                    },
            ),
            const SizedBox(height: 12),
          ];
          final panel = ListView(
            key: const ValueKey('editor-controls'),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: controls,
          );
          if (wide) {
            return Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: _posterPicture(),
                  ),
                ),
                SizedBox(width: box.maxWidth * .45, child: panel),
              ],
            );
          }
          return Column(
            children: [
              const Text(
                '让每一张照片，讲述更大的世界',
                style: TextStyle(fontSize: 13, color: muted),
              ),
              SizedBox(
                height: (box.maxHeight * .44).clamp(100.0, 310.0),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: _posterPicture(),
                ),
              ),
              if (item != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                  child: _previewTools(),
                ),
              Expanded(child: panel),
            ],
          );
        },
      ),
    ),
    bottomNavigationBar: NavigationBar(
      height: 66,
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      indicatorColor: Colors.transparent,
      selectedIndex: editorTab,
      onDestinationSelected: exporting
          ? null
          : (index) => updateUi(() {
              advanced = false;
              editorTab = index;
            }),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 11,
          color: states.contains(WidgetState.selected) ? brandGreen : muted,
        ),
      ),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.image_outlined, color: muted),
          selectedIcon: Icon(Icons.image, color: brandGreen),
          label: '边框',
        ),
        NavigationDestination(
          icon: Icon(Icons.palette_outlined, color: muted),
          selectedIcon: Icon(Icons.palette, color: brandGreen),
          label: '色彩',
        ),
        NavigationDestination(
          icon: Icon(Icons.text_fields, color: muted),
          selectedIcon: Icon(Icons.text_fields, color: brandGreen),
          label: '文字',
        ),
        NavigationDestination(
          icon: Icon(Icons.ios_share, color: muted),
          selectedIcon: Icon(Icons.ios_share, color: brandGreen),
          label: '导出',
        ),
      ],
    ),
  );

  Widget _posterPicture({bool tools = true}) => SizedBox(
    height: tools ? 310 : MediaQuery.sizeOf(context).height * .75,
    width: double.infinity,
    child: ClipRRect(
      key: tools ? const ValueKey('editor-preview') : null,
      borderRadius: BorderRadius.circular(12),
      child: ColoredBox(
        color: const Color(0xffe9eef1),
        child: Center(
          child: AspectRatio(
            aspectRatio: previewAspect,
            child: LayoutBuilder(
              builder: (context, box) => Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(
                    color: const Color(0xffe9eef1),
                    child: comparing && comparisonBytes != null
                        ? RotatedBox(
                            quarterTurns: source.isEmpty ? rotation : 0,
                            child: Image.memory(
                              comparisonBytes!,
                              fit: BoxFit.contain,
                              gaplessPlayback: true,
                            ),
                          )
                        : previewBytes != null
                        ? RotatedBox(
                            quarterTurns: source.isEmpty ? rotation : 0,
                            child: Image.memory(
                              previewBytes!,
                              fit: BoxFit.contain,
                              gaplessPlayback: true,
                            ),
                          )
                        : item != null
                        ? const Center(child: Text('正在准备照片…'))
                        : Center(
                            child: TextButton.icon(
                              onPressed: choose,
                              icon: const Icon(
                                Icons.add_photo_alternate_outlined,
                              ),
                              label: const Text('选择照片开始创作'),
                            ),
                          ),
                  ),
                  if (!comparing &&
                      posterEnabled &&
                      (posterTitle.isNotEmpty || posterSubtitle.isNotEmpty) &&
                      editorTab == 2 &&
                      !advanced)
                    Positioned.fill(
                      child: GestureDetector(
                        key: const ValueKey('poster-drag'),
                        behavior: HitTestBehavior.translucent,
                        onPanStart: exporting
                            ? null
                            : (_) => updateUi(() => draggingPoster = true),
                        onPanUpdate: exporting
                            ? null
                            : (d) => updateUi(() {
                                posterX = (posterX + d.delta.dx / box.maxWidth)
                                    .clamp(0.0, 1.0);
                                posterY = (posterY + d.delta.dy / box.maxHeight)
                                    .clamp(0.0, 1.0);
                              }),
                        onPanEnd: exporting
                            ? null
                            : (_) {
                                updateUi(() => draggingPoster = false);
                                schedule();
                              },
                        child: Stack(
                          children: [
                            Align(
                              alignment: Alignment(
                                posterX * 2 - 1,
                                posterY * 2 - 1,
                              ),
                              child: Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  border: Border.all(color: Colors.white70),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Icon(
                                  Icons.open_with,
                                  color: Colors.white,
                                  size: 22,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (!comparing && posterEnabled && source.isEmpty)
                    Align(
                      alignment: Alignment(posterX * 2 - 1, posterY * 2 - 1),
                      child: IgnorePointer(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: box.maxWidth * .82,
                                ),
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    posterTitle,
                                    maxLines: 1,
                                    softWrap: false,
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize:
                                          box.maxWidth * .087 * posterScale,
                                      fontFamily: posterFont,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: box.maxWidth * .82,
                                ),
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    posterSubtitle,
                                    maxLines: 1,
                                    softWrap: false,
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize:
                                          box.maxWidth * .026 * subtitleScale,
                                      fontFamily: posterFont,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (rendering || comparisonRendering)
                    const Positioned(
                      top: 10,
                      right: 10,
                      child: SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _previewTools() => FittedBox(
    fit: BoxFit.scaleDown,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _glassButton(Icons.rotate_right, '旋转', () {
          if (exporting) return;
          _change(() {
            rotation = (rotation + 1) % 4;
            comparing = false;
            if (source.isEmpty) previewAspect = 1 / previewAspect;
          });
        }),
        const SizedBox(width: 6),
        _glassButton(
          Icons.compare,
          comparing ? '效果' : '对比',
          () => unawaited(toggleComparison()),
        ),
        const SizedBox(width: 8),
        _glassButton(
          Icons.fullscreen,
          '全屏预览',
          () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => Scaffold(
                backgroundColor: Colors.black,
                appBar: AppBar(
                  title: const Text('全屏预览'),
                  backgroundColor: Colors.black,
                  foregroundColor: Colors.white,
                ),
                body: Center(
                  child: InteractiveViewer(
                    minScale: .5,
                    maxScale: 5,
                    child: _posterPicture(tools: false),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _glassButton(IconData icon, String text, VoidCallback action) =>
      TextButton.icon(
        onPressed: action,
        icon: Icon(icon, size: 16),
        label: Text(text),
        style: TextButton.styleFrom(
          foregroundColor: Colors.white.withValues(alpha: .94),
          backgroundColor: const Color(0x6610181c),
          minimumSize: const Size(0, 32),
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          textStyle: const TextStyle(
            fontFamily: 'Roboto',
            fontFamilyFallback: ['Microsoft YaHei'],
            fontSize: 11.5,
            fontWeight: FontWeight.w500,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: Color(0x55ffffff), width: .8),
          ),
        ).copyWith(animationDuration: fastMotion),
      );

  Widget _borderSettings() => ReferenceCard(
    padding: 16,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        heading('边框样式'),
        gap(12),
        SizedBox(
          height: 112,
          child: ListView.separated(
            key: const ValueKey('border-strip'),
            scrollDirection: Axis.horizontal,
            itemCount: nikonTemplates.length + 2,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (_, index) {
              final choices = {'': '无边框', ...nikonTemplates, 'rounded': '圆角相纸'};
              final e = choices.entries.elementAt(index);
              return InkWell(
                onTap: exporting ? null : () => _change(() => template = e.key),
                child: SizedBox(
                  width: 90,
                  child: Column(
                    children: [
                      Container(
                        height: 78,
                        width: 90,
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: template == e.key
                                ? brandGreen
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                        child: e.key.isEmpty || e.key == 'rounded'
                            ? Icon(
                                e.key.isEmpty
                                    ? Icons.crop_original
                                    : Icons.rounded_corner,
                                size: 36,
                                color: muted,
                              )
                            : Image.asset(
                                'assets/watermark_templates/${e.key}.png',
                                fit: BoxFit.contain,
                              ),
                      ),
                      Text(
                        e.value,
                        style: TextStyle(
                          fontSize: 12,
                          color: template == e.key ? brandGreen : muted,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const Text(
          '左右滑动选择边框，保留照片原始方向与比例。',
          style: TextStyle(fontSize: 12, color: muted),
        ),
        if (template.isNotEmpty) ...[
          gap(12),
          Text('边距 ${(border * 100).round()}%'),
          Slider(
            key: const ValueKey('border-width'),
            value: border,
            onChanged: exporting ? null : (v) => _change(() => border = v),
          ),
        ],
      ],
    ),
  );

  Widget _colorSettings() => ReferenceCard(
    padding: 16,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        heading('色彩调整'),
        gap(12),
        DropdownButtonFormField<String>(
          key: ValueKey('reference-lut-$lut'),
          initialValue: luts.contains(lut) ? lut : '',
          decoration: const InputDecoration(labelText: '影调风格 LUT'),
          isExpanded: true,
          items: [
            const DropdownMenuItem(value: '', child: Text('原色')),
            const DropdownMenuItem(
              enabled: false,
              value: '__builtin_header__',
              child: Text('—— 自带 LUT ——'),
            ),
            ...luts
                .where(_NikonEditorPageState._builtInLuts.contains)
                .map(
                  (l) => DropdownMenuItem(value: l, child: Text(_lutName(l))),
                ),
            if (importedLuts.isNotEmpty)
              const DropdownMenuItem(
                enabled: false,
                value: '__imported_header__',
                child: Text('—— 导入 LUT ——'),
              ),
            ...importedLuts.map(
              (l) => DropdownMenuItem(value: l, child: Text(_lutName(l))),
            ),
          ],
          onChanged: exporting ? null : (v) => _change(() => lut = v ?? ''),
        ),
        gap(8),
        Align(
          alignment: Alignment.centerLeft,
          child: ChoiceChip(
            label: const Text('城市电影'),
            selected: lut == 'Cool Tone',
            onSelected: exporting
                ? null
                : (_) => _change(() => lut = 'Cool Tone'),
          ),
        ),
        gap(8),
        Text('LUT 强度 ${(intensity * 100).round()}%'),
        Slider(
          value: intensity,
          onChanged: exporting ? null : (v) => _change(() => intensity = v),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: exporting || importingLut ? null : _importLut,
              icon: importingLut
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.file_upload_outlined),
              label: Text(importingLut ? '正在校验…' : '导入 Cube 文件'),
            ),
            OutlinedButton.icon(
              onPressed: exporting
                  ? null
                  : () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => LutManagerPage(c: c),
                      ),
                    ),
              icon: const Icon(Icons.tune),
              label: const Text('LUT 管理'),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _textSettings() => ReferenceCard(
    padding: 16,
    child: Column(
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('显示海报文字'),
          value: posterEnabled,
          onChanged: exporting ? null : (v) => _change(() => posterEnabled = v),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('编辑标题与副标题'),
          subtitle: Text(posterTitle.replaceAll('\n', ' ')),
          trailing: const Icon(Icons.chevron_right),
          onTap: exporting ? null : _editText,
        ),
        const SizedBox(height: 12),
        const Text('在预览图上拖动文字调整位置，默认选中海报文字。', softWrap: true),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: ValueKey('poster-font-$posterFont'),
          initialValue: posterFont,
          decoration: const InputDecoration(
            labelText: '海报字体',
            contentPadding: EdgeInsets.fromLTRB(12, 16, 12, 16),
          ),
          items: const [
            DropdownMenuItem(value: 'sans-serif', child: Text('现代黑体')),
            DropdownMenuItem(value: 'serif', child: Text('经典衬线')),
            DropdownMenuItem(value: 'monospace', child: Text('等宽字体')),
            DropdownMenuItem(value: 'cursive', child: Text('手写字体')),
          ],
          onChanged: exporting ? null : (v) => _change(() => posterFont = v!),
        ),
        Text('主标题字号 ${(posterScale * 100).round()}%'),
        Slider(
          key: const ValueKey('poster-scale'),
          min: .3,
          max: 2,
          value: posterScale,
          onChanged: exporting ? null : (v) => _change(() => posterScale = v),
        ),
        Text('副标题字号 ${(subtitleScale * 100).round()}%'),
        Slider(
          key: const ValueKey('poster-subtitle-scale'),
          min: .3,
          max: 2,
          value: subtitleScale,
          onChanged: exporting ? null : (v) => _change(() => subtitleScale = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('显示 EXIF 水印'),
          value: details,
          onChanged: exporting ? null : (v) => _change(() => details = v),
        ),
        gap(12),
        OutlinedButton.icon(
          onPressed: exporting ? null : () => updateUi(() => advanced = true),
          icon: const Icon(Icons.tune),
          label: const Text('高级 EXIF 排版'),
        ),
      ],
    ),
  );

  Widget _exportSettings() => ReferenceCard(
    padding: 16,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        heading('导出设置'),
        gap(12),
        const Text('JPEG · 原始比例 · 最高质量 · 保存至镜桥相册'),
        gap(8),
        Text(item?.name ?? '尚未选择照片'),
        gap(12),
        const Text('原图保持不变，预览叠加编辑参数；导出时一次合成副本，JPEG 会重新编码。'),
        TextButton(
          onPressed: exporting
              ? null
              : () async {
                  await saveSettings();
                  if (mounted) notice(context, '处理配方已保存');
                },
          child: const Text('保存配方'),
        ),
      ],
    ),
  );

  Future<void> _editText() async {
    final result = await showModalBottomSheet<(String, String)>(
      context: context,
      isScrollControlled: true,
      builder: (_) =>
          _PosterTextSheet(title: posterTitle, subtitle: posterSubtitle),
    );
    if (result != null && mounted) {
      _change(() {
        posterTitle = result.$1;
        posterSubtitle = result.$2;
        posterEnabled = true;
      });
    }
  }

  Future<void> _resetPoster() async {
    if (!await confirm(context, '重置编辑', '恢复默认模板、文字和色彩设置。', action: '重置') ||
        !mounted) {
      return;
    }
    _change(() {
      lut = '';
      intensity = .7;
      template = '';
      border = .1;
      posterTitle = '';
      posterSubtitle = '';
      posterPosition = '左上';
      posterX = .06;
      posterY = .07;
      posterScale = 1;
      subtitleScale = 1;
      posterFont = 'sans-serif';
      rotation = 0;
      posterEnabled = true;
      details = true;
      comparing = false;
    });
  }
}

class _PosterTextSheet extends StatefulWidget {
  const _PosterTextSheet({required this.title, required this.subtitle});
  final String title, subtitle;
  @override
  State<_PosterTextSheet> createState() => _PosterTextSheetState();
}

class _PosterTextSheetState extends State<_PosterTextSheet> {
  late final title = TextEditingController(text: widget.title);
  late final subtitle = TextEditingController(text: widget.subtitle);
  @override
  void dispose() {
    title.dispose();
    subtitle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      20,
      8,
      20,
      MediaQuery.viewInsetsOf(context).bottom + 24,
    ),
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          heading('文字样式', size: 20),
          gap(16),
          TextField(
            controller: title,
            minLines: 1,
            maxLines: 3,
            maxLength: 70,
            decoration: const InputDecoration(labelText: '主标题'),
          ),
          gap(8),
          TextField(
            controller: subtitle,
            maxLength: 80,
            decoration: const InputDecoration(labelText: '副标题'),
          ),
          gap(12),
          Pill(
            '应用文字',
            onPressed: () =>
                Navigator.pop(context, (title.text, subtitle.text)),
          ),
        ],
      ),
    ),
  );
}
