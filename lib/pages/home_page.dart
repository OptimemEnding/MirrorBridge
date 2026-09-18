import 'package:flutter/material.dart';
import '../models/camera_storage.dart';
import '../models/media_item.dart';
import '../state/app_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/media_image.dart';
import '../widgets/shared.dart';
import 'media_detail_page.dart';
import 'settings_pages.dart';
import 'nikon_monitor_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.c, required this.onConnect});
  final AppController c;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) => c.tab == 0
      ? ListenableBuilder(
          listenable: c.transferProgress,
          builder: (context, _) => _content(context),
        )
      : _content(context);

  Widget _content(BuildContext context) {
    final task = c.allSyncTasks
        .where((record) => record.type == SyncTaskType.cameraSync)
        .firstOrNull;
    final progress = task == null
        ? 0.0
        : c.isDemo
        ? task.progress
        : task.totalBytes == 0
        ? (task.phase == SyncPhase.completed ? 1.0 : 0.0)
        : ((task.doneBytes +
                      (task.phase == SyncPhase.transferring
                          ? task.currentBytes
                          : 0)) /
                  task.totalBytes)
              .clamp(0.0, 1.0);
    final status = task == null
        ? '未开始'
        : task.missing.isNotEmpty
        ? '本地文件失效'
        : switch (task.phase) {
            SyncPhase.transferring => '同步中',
            SyncPhase.completed => '已完成',
            SyncPhase.partialFailure => '部分失败',
            SyncPhase.cancelled => '已取消',
            _ => '待同步',
          };
    final statusColor = task?.phase == SyncPhase.completed
        ? brandGreen
        : task?.phase == SyncPhase.partialFailure
        ? const Color(0xffdc2626)
        : const Color(0xffd97706);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Panel(
          child: Column(
            children: [
              Row(
                children: [
                  const _FeatureIcon(
                    icon: Icons.photo_camera_outlined,
                    size: 64,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          c.connected ? c.cameraModel : '尚未连接相机',
                          style: const TextStyle(
                            color: ink,
                            fontSize: 21,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          c.connected
                              ? '已通过 ${c.connectionLabel} 连接'
                              : '支持 Nikon Z 系列与部分 DSLR',
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: c.connected
                                    ? brandGreen
                                    : const Color(0xffa0a8b4),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 7),
                            Text(
                              c.connected ? '已连接' : '等待连接',
                              style: TextStyle(
                                color: c.connected ? brandGreen : muted,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: Pill(
                      c.connected ? '查看相机照片' : '连接相机',
                      onPressed: c.connected ? () => c.navigate(2) : onConnect,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Pill(
                      '相机设置',
                      light: true,
                      onPressed: () => c.navigate(1),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        gap(14),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const _FeatureIcon(icon: Icons.sync, size: 52),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        heading('同步任务', size: 19),
                        const SizedBox(height: 3),
                        Text(
                          task?.phase == SyncPhase.transferring
                              ? '正在将相机中的照片传输到手机'
                              : task == null
                              ? '选择相机照片后开始同步'
                              : '最近一次相机同步：$status',
                        ),
                      ],
                    ),
                  ),
                  StatusChip(status, color: statusColor),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Text(
                    '${(progress * 100).round()}%',
                    style: const TextStyle(
                      color: brandGreen,
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 10,
                        color: brandGreen,
                        backgroundColor: const Color(0xffe6eaef),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '本地媒体 ${c.completedCount} 个，其中相机同步 ${c.cameraSyncCompleted} 个、手工导入 ${c.manualImportCompleted} 个，失败 ${c.totalSyncFailed} 个',
                style: const TextStyle(fontSize: 12),
              ),
              TextButton.icon(
                onPressed: () => c.navigate(3),
                icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                label: const Text('查看同步任务'),
              ),
              if (c.connected && c.nikon != null) ...[
                const SizedBox(height: 16),
                Pill(
                  '进入实时监看',
                  icon: Icons.videocam_outlined,
                  onPressed: c.busy
                      ? null
                      : () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => NikonMonitorPage(c: c),
                          ),
                        ),
                ),
              ],
            ],
          ),
        ),
        gap(14),
        Row(
          children: [
            _stat(
              Icons.photo_library_outlined,
              '${c.completedCount}',
              '本地媒体',
              () => c.navigate(4),
            ),
            const SizedBox(width: 10),
            _stat(
              Icons.photo_camera_outlined,
              c.cameraTotal?.toString() ?? '已载入 ${c.media.length}',
              '相机媒体',
              () => c.navigate(2),
            ),
            const SizedBox(width: 10),
            _stat(
              Icons.data_usage_outlined,
              c.phoneFreeBytes == null
                  ? '—'
                  : formatStorageBytes(c.phoneFreeBytes!),
              '手机剩余',
              () => showCameraSettings(context, c),
            ),
          ],
        ),
        gap(10),
        Row(
          children: [
            const Expanded(
              child: Text('同步占用 / 手机可用', style: TextStyle(fontSize: 11)),
            ),
            Text(
              '${formatStorageBytes(c.syncedStorageBytes)} / ${c.phoneFreeBytes == null ? "未知" : formatStorageBytes(c.phoneFreeBytes!)}',
              style: const TextStyle(fontSize: 11),
            ),
          ],
        ),
        gap(14),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: heading('最近导入的本地媒体')),
                  TextButton(
                    onPressed: () => c.navigate(4),
                    child: const Text('查看全部'),
                  ),
                ],
              ),
              if (c.completedCount == 0)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: Text('暂无本地媒体')),
                )
              else
                ...c.local
                    .where((m) => m.referenceAvailable)
                    .take(3)
                    .map((m) => _RecentMedia(c: c, item: m)),
            ],
          ),
        ),
        if (c.isDemo) ...[
          gap(10),
          TextButton.icon(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('独立演示模式'),
                content: const Text('当前照片、连接和传输均为本地演示数据；未验证真实相机。可在此模拟一次任务失败。'),
                actions: [
                  TextButton(
                    onPressed: () {
                      c.failNext = true;
                      Navigator.pop(ctx);
                    },
                    child: const Text('下次任务模拟失败'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            ),
            icon: const Icon(Icons.science_outlined),
            label: const Text('演示模式 · 本地数据'),
          ),
        ],
      ],
    );
  }

  Widget _stat(IconData icon, String value, String label, VoidCallback onTap) =>
      Expanded(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Panel(
            padding: 14,
            child: SizedBox(
              height: 76,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(icon, size: 18, color: muted),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      value,
                      style: const TextStyle(
                        color: ink,
                        fontWeight: FontWeight.w800,
                        fontSize: 22,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}

class _FeatureIcon extends StatelessWidget {
  const _FeatureIcon({required this.icon, this.size = 56});
  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: const BoxDecoration(color: paleGreen, shape: BoxShape.circle),
    child: Icon(icon, color: brandGreen, size: size * .48),
  );
}

class _RecentMedia extends StatelessWidget {
  const _RecentMedia({required this.c, required this.item});
  final AppController c;
  final MediaItem item;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: MediaImage(
        item: item,
        controller: c,
        width: 64,
        height: 48,
        fit: BoxFit.cover,
      ),
    ),
    title: Text(
      item.name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontWeight: FontWeight.w700),
    ),
    subtitle: Text('${item.label} · ${item.size}'),
    trailing: const Icon(Icons.chevron_right, color: muted),
    onTap: () => Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => MediaDetailPage(c: c, item: item, isLocal: true),
      ),
    ),
  );
}
