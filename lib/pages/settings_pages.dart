import '../models/media_item.dart';
import '../widgets/media_image.dart';
import 'package:flutter/material.dart';
import '../models/camera_storage.dart';
import '../state/app_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/shared.dart';
import 'nikon_editor_page.dart';
import 'lut_manager_page.dart';

Future<void> showCameraSettings(BuildContext context, AppController c) =>
    Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => CameraSettingsPage(c: c)),
    );

class CameraSettingsPage extends StatelessWidget {
  const CameraSettingsPage({super.key, required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _title(Icons.link, '连接与同步'),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.photo_camera_outlined),
                  title: const Text('相机连接'),
                  subtitle: Text(c.connected ? c.connectionLabel : '尚未连接'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (c.connected)
                        Text(
                          c.cameraModel,
                          style: const TextStyle(color: brandGreen),
                        ),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    c.navigate(1);
                  },
                ),
                const Divider(height: 1),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.sync),
                  title: const Text('自动同步'),
                  subtitle: const Text('将相机中新拍摄的照片自动传输到手机'),
                  value: c.live,
                  onChanged: c.setLive,
                ),
              ],
            ),
          ),
          gap(14),
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _title(Icons.calendar_month_outlined, '日期筛选'),
                const Text('选择要查看或同步的拍摄时间范围'),
                gap(12),
                ListTile(
                  tileColor: const Color(0xfff4f6f8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  leading: const Icon(Icons.date_range_outlined),
                  title: Text(
                    c.dateStart == null
                        ? '全部日期'
                        : '${_date(c.dateStart!)} 至 ${_date(c.dateEnd ?? c.dateStart!)}',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => showDateOptions(context, c),
                ),
              ],
            ),
          ),
          gap(14),
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _title(Icons.palette_outlined, '色彩管理'),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.asset(
                      'assets/demo.png',
                      width: 92,
                      height: 58,
                      fit: BoxFit.cover,
                    ),
                  ),
                  title: Text(c.lut.isEmpty ? '默认 LUT' : c.lut.split('/').last),
                  subtitle: Text('强度 ${(c.intensity * 100).round()}%'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(builder: (_) => ColorPage(c: c)),
                  ),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.tune),
                  title: const Text('LUT 管理'),
                  subtitle: const Text('删除、重命名和调整手动导入的 LUT'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => LutManagerPage(c: c),
                    ),
                  ),
                ),
              ],
            ),
          ),
          gap(14),
          Panel(
            child: Column(
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.info_outline),
                  title: const Text('EXIF 显示'),
                  subtitle: const Text('在照片详情中显示拍摄信息'),
                  value: c.showExif,
                  onChanged: (value) {
                    c.showExif = value;
                    c.save();
                    c.changed();
                  },
                ),
                const Divider(height: 1),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.branding_watermark_outlined),
                  title: const Text('默认启用水印'),
                  subtitle: const Text('进入创意编辑时使用当前水印方案'),
                  value: c.watermark,
                  onChanged: (value) {
                    c.watermark = value;
                    c.save();
                    c.changed();
                  },
                ),
              ],
            ),
          ),
          gap(14),
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _title(Icons.storage_outlined, '存储管理'),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${formatStorageBytes(c.syncedStorageBytes)} 已由镜桥管理',
                      ),
                    ),
                    Text(
                      c.phoneFreeBytes == null
                          ? '空间未知'
                          : '剩余 ${formatStorageBytes(c.phoneFreeBytes!)}',
                    ),
                  ],
                ),
                gap(10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    minHeight: 9,
                    value: c.phoneTotalBytes == null || c.phoneTotalBytes == 0
                        ? 0
                        : ((c.phoneTotalBytes! - (c.phoneFreeBytes ?? 0)) /
                                  c.phoneTotalBytes!)
                              .clamp(0, 1),
                    color: brandGreen,
                    backgroundColor: const Color(0xffe5e9ef),
                  ),
                ),
              ],
            ),
          ),
          gap(14),
          Panel(
            padding: 8,
            child: ListTile(
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.asset(
                  'assets/brand/app_icon.png',
                  width: 48,
                  height: 48,
                ),
              ),
              title: const Text('关于镜桥'),
              subtitle: const Text('许可证、版本与第三方声明'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showLicensePage(
                context: context,
                applicationName: '镜桥',
                applicationLegalese: '相机品牌与商标归各自权利人所有。本应用不代表相机厂商。',
              ),
            ),
          ),
        ],
      ),
    ),
  );

  static String _date(DateTime value) =>
      '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

  Widget _title(IconData icon, String label) => Row(
    children: [
      Container(
        width: 38,
        height: 38,
        decoration: const BoxDecoration(
          color: paleGreen,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: brandGreen, size: 21),
      ),
      const SizedBox(width: 10),
      heading(label),
    ],
  );
}

Future<void> showDateOptions(BuildContext context, AppController c) =>
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              heading('日期筛选', size: 22),
              gap(8),
              const Text('选择本次要同步的照片范围。'),
              gap(14),
              ListTile(
                title: const Text('同步全部未同步'),
                subtitle: const Text('保持原有同步逻辑，自动跳过已同步文件'),
                onTap: () {
                  c.dateStart = null;
                  c.dateEnd = null;
                  c.setFilter('未同步');
                  Navigator.pop(ctx);
                },
              ),
              ListTile(
                title: const Text('按日期同步'),
                subtitle: const Text('选择某一天或一段时间，只同步匹配的图片'),
                onTap: () {
                  Navigator.pop(ctx);
                  showDateRangeOptions(context, c);
                },
              ),
            ],
          ),
        ),
      ),
    );
Future<void> showDateRangeOptions(BuildContext context, AppController c) =>
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              heading('按日期同步', size: 22),
              gap(8),
              const Text('只读取相机文件元数据，不会下载全尺寸照片。'),
              gap(14),
              for (final range in [false, true])
                ListTile(
                  title: Text(range ? '选择日期范围' : '选择单日'),
                  subtitle: Text(range ? '范围内没有图片的日期会自动跳过' : '同步某一天拍摄的图片'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    final initial = c.media.isNotEmpty
                        ? c.media.first.date
                        : DateTime.now();
                    if (range) {
                      final result = await showDateRangePicker(
                        context: context,
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                        initialDateRange: DateTimeRange(
                          start: initial,
                          end: initial,
                        ),
                        helpText: '选择日期范围',
                        saveText: '确定',
                      );
                      if (result != null) {
                        c.dateStart = result.start;
                        c.dateEnd = result.end;
                        c.reconcileSelection();
                      }
                    } else {
                      final result = await showDatePicker(
                        context: context,
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                        initialDate: initial,
                        helpText: '选择单日',
                        confirmText: '确定',
                        cancelText: '取消',
                      );
                      if (result != null) {
                        c.dateStart = result;
                        c.dateEnd = result;
                        c.reconcileSelection();
                      }
                    }
                  },
                ),
            ],
          ),
        ),
      ),
    );

Future<void> showFolderPicker(BuildContext context, AppController c) {
  final sheet = showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => ListenableBuilder(
      listenable: c,
      builder: (context, _) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * .72,
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 20),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    heading('存储卡与文件夹', size: 22),
                    gap(8),
                    const Text('可多选存储卡和文件夹，未指定时显示全部。'),
                    gap(14),
                  ],
                ),
              ),
              _filterSection('存储卡', Icons.sd_storage_outlined),
              CheckboxListTile(
                title: const Text('全部卡'),
                value: c.selectedStorageIds.isEmpty,
                activeColor: blue,
                onChanged: (_) => c.setStorage(null),
              ),
              for (final storage in c.cameraStorages)
                CheckboxListTile(
                  title: Text(storage.title),
                  subtitle: Text(storage.details),
                  value: c.selectedStorageIds.contains(storage.id),
                  activeColor: blue,
                  onChanged: (_) => c.toggleStorage(storage),
                ),
              if (c.cameraStorages.isEmpty)
                const ListTile(title: Text('当前没有可用存储卡')),
              _filterSection('文件夹', Icons.folder_outlined),
              CheckboxListTile(
                title: const Text('全部文件夹'),
                value: c.selectedFolders.isEmpty,
                activeColor: blue,
                onChanged: (_) => c.setFolder(null),
              ),
              for (final entry in c.cameraFolders)
                CheckboxListTile(
                  title: Text(entry.displayName),
                  subtitle: Text(
                    c.cameraStorages
                            .where((s) => s.id == entry.storageId)
                            .firstOrNull
                            ?.title ??
                        '存储卡',
                  ),
                  value: c.folderSelected(entry),
                  activeColor: blue,
                  onChanged: (_) => c.toggleFolder(entry),
                ),
              if (c.loadingFolders ||
                  c.nikon?.indexing == true && c.nikon?.foldersIndexed != true)
                const ListTile(title: Text('正在读取文件夹…'))
              else if (c.nikon != null && !c.nikon!.foldersIndexed)
                ListTile(
                  title: const Text('文件夹列表尚未完整，点击重试'),
                  onTap: c.refreshFolders,
                )
              else if (c.cameraFolders.isEmpty)
                const ListTile(title: Text('当前存储卡没有文件夹')),
              Padding(
                padding: const EdgeInsets.all(20),
                child: FilledButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('完成'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  c.refreshFolders();
  return sheet;
}

Widget _filterSection(String title, IconData icon) => Container(
  margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
  decoration: BoxDecoration(
    color: const Color(0xffe8edf5),
    borderRadius: BorderRadius.circular(10),
  ),
  child: Row(
    children: [
      Icon(icon, size: 18, color: const Color(0xff475569)),
      const SizedBox(width: 8),
      Text(
        title,
        style: const TextStyle(
          color: Color(0xff475569),
          fontSize: 13,
          fontWeight: FontWeight.w800,
        ),
      ),
    ],
  ),
);

class ColorPage extends StatelessWidget {
  const ColorPage({super.key, required this.c});
  final AppController c;
  @override
  Widget build(BuildContext context) => EditorPhotoPicker(c: c);
}

class EditorPhotoPicker extends StatelessWidget {
  const EditorPhotoPicker({super.key, required this.c});
  final AppController c;
  void open(BuildContext context, MediaItem item) => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => NikonEditorPage(c: c, item: item),
    ),
  );
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) {
      final photos = c.visibleLocal
          .where((m) => m.kind != MediaKind.video)
          .toList();
      return Scaffold(
        appBar: AppBar(title: const Text('选择要编辑的照片')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('先选择照片，再调整边框、色彩与文字。原图不会被覆盖。'),
            gap(16),
            OutlinedButton.icon(
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('从系统相册选择'),
              onPressed: () async {
                final item = await c.chooseImageReference();
                if (!context.mounted) return;
                if (item != null) {
                  open(context, item);
                } else if (c.message.isNotEmpty) {
                  notice(context, '无法访问所选照片，请重新选择或授予照片权限。');
                }
              },
            ),
            gap(8),
            OutlinedButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(builder: (_) => LutManagerPage(c: c)),
              ),
              icon: const Icon(Icons.tune),
              label: const Text('LUT 管理'),
            ),
            gap(16),
            if (photos.isEmpty) const Center(child: Text('暂无本地照片，请从系统相册选择。')),
            for (final item in photos)
              ListTile(
                leading: SizedBox(
                  width: 60,
                  height: 60,
                  child: MediaImage(
                    item: item,
                    controller: c,
                    fit: BoxFit.cover,
                  ),
                ),
                title: Text(item.name),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => open(context, item),
              ),
          ],
        ),
      );
    },
  );
}

class EffectEditor extends StatelessWidget {
  const EffectEditor({super.key, required this.c});
  final AppController c;
  @override
  Widget build(BuildContext context) => EditorPhotoPicker(c: c);
}
