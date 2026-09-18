import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../state/app_controller.dart';
import '../widgets/shared.dart';
import '../protocol/ptp.dart';

class LutManagerPage extends StatefulWidget {
  const LutManagerPage({super.key, required this.c});
  final AppController c;

  @override
  State<LutManagerPage> createState() => _LutManagerPageState();
}

class _LutManagerPageState extends State<LutManagerPage> {
  static const builtIn = [
    'Warm Tone',
    'Cool Tone',
    'Vivid Color',
    'Soft Light',
    'Matte Film',
    'Monochrome',
    'High Contrast',
    'Sepia Print',
  ];

  AppController get c => widget.c;
  bool importing = false;

  Future<void> rename(int index) async {
    final old = c.importedLuts[index];
    final controller = TextEditingController(text: old);
    final value = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('重命名 LUT'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (value == null || value.isEmpty || value == old) return;
    if (builtIn.contains(value) || c.importedLuts.contains(value)) {
      if (!mounted) return;
      notice(context, 'LUT 名称已存在');
      return;
    }
    if (!mounted) return;
    setState(() => c.importedLuts[index] = value);
    await c.save();
  }

  Future<void> remove(int index) async {
    setState(() => c.importedLuts.removeAt(index));
    await c.save();
  }

  Future<void> importLut() async {
    if (importing) return;
    setState(() => importing = true);
    try {
      final selected = await nativeCamera.invokeMethod<String>('pick', {
        'kind': 'cube',
      });
      if (selected == null || selected.isEmpty) return;
      if (c.importedLuts.contains(selected)) {
        if (!mounted) return;
        notice(context, 'LUT 已导入');
        return;
      }
      if (!mounted) return;
      setState(() => c.importedLuts.add(selected));
      await c.save();
    } on PlatformException catch (error) {
      if (mounted) {
        final message = error.message ?? '';
        notice(
          context,
          message.contains('Cube') || message.contains('LUT')
              ? 'LUT 文件无效，请选择符合 3D Cube 格式的 .cube 文件。'
              : '无法导入 LUT，请重试。',
        );
      }
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  String displayName(String path) => path.split('/').last;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('LUT 管理')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '系统自带 LUT',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              for (final item in builtIn) ListTile(title: Text(item)),
              const Divider(),
              const Text(
                '手动导入 LUT',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              FilledButton.icon(
                onPressed: importing ? null : importLut,
                icon: importing
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add),
                label: Text(importing ? '正在校验…' : '导入 LUT'),
              ),
              ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: c.importedLuts.length,
                onReorderItem: (oldIndex, newIndex) async {
                  setState(() {
                    final item = c.importedLuts.removeAt(oldIndex);
                    c.importedLuts.insert(newIndex, item);
                  });
                  await c.save();
                },
                itemBuilder: (_, i) => ListTile(
                  key: ValueKey(c.importedLuts[i]),
                  title: Text(displayName(c.importedLuts[i])),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) => v == 'rename' ? rename(i) : remove(i),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'rename', child: Text('重命名')),
                      PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
