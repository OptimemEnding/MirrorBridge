import 'package:flutter/material.dart';
import '../models/media_item.dart';
import '../models/camera_storage.dart';
import '../state/app_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/shared.dart';
import '../widgets/media_image.dart';

String _taskStatus(SyncTask record) => record.missing.isNotEmpty
    ? '本地文件失效'
    : switch (record.phase) {
        SyncPhase.transferring => '正在同步',
        SyncPhase.completed => switch (record.type) {
          SyncTaskType.cameraSync => '已同步完成',
          SyncTaskType.manualImport => '手工导入',
          SyncTaskType.editorExport => '编辑导出',
        },
        SyncPhase.partialFailure => '同步失败',
        SyncPhase.cancelled => '已取消',
        _ => '等待同步',
      };

String _taskDate(SyncTask record) {
  final d = record.createdAt;
  String two(int value) => value.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
}

class SyncPage extends StatefulWidget {
  const SyncPage({super.key, required this.c});
  final AppController c;

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  AppController get c => widget.c;
  bool expanded = false;
  @override
  Widget build(BuildContext context) {
    final active = c.allSyncTasks
        .where((t) => t.phase == SyncPhase.transferring)
        .toList();
    final history = c.visibleSyncTasks
        .where((t) => t.phase != SyncPhase.transferring)
        .toList();
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          sliver: SliverList.list(
            children: [
              if (active.isEmpty)
                const Panel(
                  child: Row(
                    children: [
                      Icon(Icons.check_circle_outline, color: brandGreen),
                      SizedBox(width: 12),
                      Expanded(child: Text('当前没有正在同步的任务')),
                    ],
                  ),
                ),
              for (final record in active) ...[
                _TaskSummary(c: c, record: record),
                gap(12),
              ],
              gap(20),
              heading('同步统计'),
              gap(10),
              Row(
                children: [
                  _SyncStat(
                    icon: Icons.description_outlined,
                    label: '已完成文件',
                    value: '${c.totalSyncCompleted}',
                    color: brandGreen,
                  ),
                  const SizedBox(width: 8),
                  _SyncStat(
                    icon: Icons.error_outline,
                    label: '失败文件',
                    value: '${c.totalSyncFailed}',
                    color: const Color(0xffdc2626),
                  ),
                  const SizedBox(width: 8),
                  _SyncStat(
                    icon: Icons.storage_outlined,
                    label: '占用空间',
                    value: formatStorageBytes(c.syncedStorageBytes),
                    color: muted,
                  ),
                ],
              ),
              gap(20),
              Row(
                children: [
                  Expanded(
                    child: TextButton.icon(
                      onPressed: () => setState(() => expanded = !expanded),
                      icon: Icon(
                        expanded ? Icons.expand_less : Icons.expand_more,
                      ),
                      label: Text('历史任务 (${history.length})'),
                    ),
                  ),
                  if (c.hasClearableCompletedOrMissingRecords)
                    TextButton(
                      onPressed: () => c.clearCompletedAndMissingRecords(),
                      child: const Text('清除已完成及失效记录'),
                    ),
                  if (c.visibleLocal.isNotEmpty)
                    TextButton.icon(
                      onPressed: () => c.navigate(4),
                      icon: const Icon(Icons.photo_library_outlined, size: 18),
                      label: const Text('查看照片'),
                    ),
                ],
              ),
              gap(6),
              const Text('展开查看历史；清除已完成及失效记录不会删除相机原片。'),
              gap(12),
              if (history.isEmpty) const Panel(child: Text('暂无历史任务')),
            ],
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          sliver: SliverList.builder(
            itemCount: expanded ? history.length : 0,
            itemBuilder: (context, index) => Padding(
              key: ValueKey(history[index].id),
              padding: const EdgeInsets.only(bottom: 12),
              child: _TaskSummary(c: c, record: history[index]),
            ),
          ),
        ),
      ],
    );
  }
}

class _TaskSummary extends StatelessWidget {
  const _TaskSummary({required this.c, required this.record});
  final AppController c;
  final SyncTask record;

  @override
  Widget build(BuildContext context) {
    final active = record.phase == SyncPhase.transferring;
    final totalBytes = active ? record.totalBytes : 0;
    final doneBytes = active ? record.doneBytes : 0;
    return Panel(
      padding: 12,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            key: ValueKey('sync-task-${record.id}'),
            contentPadding: EdgeInsets.zero,
            leading: record.items.isEmpty
                ? const Icon(Icons.sync)
                : ClipRRect(
                    borderRadius: BorderRadius.circular(7),
                    child: MediaImage(
                      item: record.items.first,
                      controller: c,
                      width: 60,
                      height: 60,
                      fit: BoxFit.cover,
                    ),
                  ),
            title: Text(
              record.type == SyncTaskType.cameraSync
                  ? '相机同步'
                  : record.type == SyncTaskType.manualImport
                  ? '手工导入'
                  : '编辑导出',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(
              '${_taskDate(record)}\n${record.items.length} 个文件 · 完成 ${record.completed.length - record.missing.length} 个 · 失效 ${record.missing.length} 个 · 失败 ${record.failed.length} 个',
            ),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                StatusChip(
                  _taskStatus(record),
                  color: active
                      ? brandGreen
                      : record.failed.isNotEmpty
                      ? const Color(0xffdc2626)
                      : record.phase == SyncPhase.cancelled
                      ? muted
                      : brandGreen,
                ),
                const SizedBox(height: 2),
                const Icon(Icons.chevron_right, size: 18, color: muted),
              ],
            ),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => SyncTaskDetailPage(c: c, record: record),
              ),
            ),
          ),
          if (active)
            ListenableBuilder(
              listenable: c.transferProgress,
              builder: (context, _) {
                final bytes = doneBytes + record.currentBytes;
                final progress = totalBytes == 0
                    ? 0.0
                    : (bytes / totalBytes).clamp(0.0, 1.0);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        minHeight: 9,
                        value: c.isDemo ? record.progress : progress,
                        color: brandGreen,
                        backgroundColor: const Color(0xffe5e9ef),
                      ),
                    ),
                    gap(8),
                    Text(
                      '${formatStorageBytes(bytes)} / ${formatStorageBytes(totalBytes)}',
                    ),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }
}

class _SyncStat extends StatelessWidget {
  const _SyncStat({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });
  final IconData icon;
  final String label, value;
  final Color color;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Panel(
      padding: 12,
      child: SizedBox(
        height: 70,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 17, color: color),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10),
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
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class SyncTaskDetailPage extends StatelessWidget {
  const SyncTaskDetailPage({super.key, required this.c, required this.record});
  final AppController c;
  final SyncTask record;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) {
      final available = c.containsSyncTask(record) && record.items.isNotEmpty;
      return Scaffold(
        appBar: AppBar(
          title: const Text('文件任务'),
          actions: [
            if (available &&
                (record.phase == SyncPhase.completed ||
                    record.missing.isNotEmpty ||
                    record.items.any((item) => !item.referenceAvailable)))
              TextButton(
                onPressed: () async {
                  await c.clearCompletedAndMissingRecords();
                  if (context.mounted) Navigator.pop(context);
                },
                child: const Text('清除已完成及失效记录'),
              ),
            if (available && c.canRemoveSyncTask(record))
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: Colors.red.shade700,
                ),
                onPressed: () async {
                  if (await confirm(
                    context,
                    '移除未完成任务',
                    '移除本批次尚未完成的任务，并停止相关下载。已完成记录随本地文件保留。',
                  )) {
                    await c.removeSyncTask(record: record);
                  }
                },
                child: const Text('移除未完成'),
              ),
          ],
        ),
        body: !available
            ? const Center(child: Text('任务已移除'))
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${_taskStatus(record)} · ${_taskDate(record)}'),
                        gap(8),
                        const Text('文件移走、删除或引用失效时保留任务并标记失效；在应用内删除记录会同步移除任务。'),
                        if (record.phase == SyncPhase.transferring)
                          TextButton.icon(
                            onPressed: () async {
                              if (await confirm(
                                context,
                                '取消同步',
                                '停止本批次下载，保留已完成文件和任务记录。',
                                action: '取消同步',
                              )) {
                                c.cancelSync();
                              }
                            },
                            icon: const Icon(Icons.stop_circle_outlined),
                            label: const Text('取消同步'),
                          ),
                        if (record.phase != SyncPhase.transferring &&
                            record.items.any(
                              (m) =>
                                  !record.completed.contains(m.id) ||
                                  record.missing.contains(m.id),
                            ))
                          TextButton.icon(
                            onPressed: c.busy
                                ? null
                                : () => c.retryFailed(record: record),
                            icon: const Icon(Icons.refresh),
                            label: const Text('重试未完成项'),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                      itemCount: record.items.length,
                      separatorBuilder: (_, _) => gap(10),
                      itemBuilder: (context, index) {
                        final item = record.items[index];
                        final active =
                            identical(c.task, record) && c.isSyncing(item);
                        final completed =
                            record.completed.contains(item.id) &&
                            !record.missing.contains(item.id);
                        final status = active
                            ? '正在同步'
                            : record.missing.contains(item.id)
                            ? '本地文件失效'
                            : completed
                            ? switch (record.type) {
                                SyncTaskType.cameraSync => '已完成',
                                SyncTaskType.manualImport => '手工导入',
                                SyncTaskType.editorExport => '编辑导出',
                              }
                            : record.failed.contains(item.id)
                            ? '失败'
                            : record.phase == SyncPhase.cancelled
                            ? '已取消'
                            : '等待同步';
                        return Panel(
                          padding: 12,
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Opacity(
                              opacity: active ? .45 : 1,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: MediaImage(
                                  item: item,
                                  controller: c,
                                  width: 48,
                                  height: 48,
                                  fit: BoxFit.cover,
                                ),
                              ),
                            ),
                            title: Text(item.name),
                            subtitle: Text(
                              '${item.size} · $status${record.errors[item.id] == null ? '' : '\n请检查设备连接和照片访问权限后重试。'}',
                            ),
                            trailing: completed
                                ? const Icon(
                                    Icons.check_circle_outline,
                                    color: Colors.green,
                                  )
                                : IconButton(
                                    tooltip: '删除 ${item.name} 的任务',
                                    color: Colors.red.shade700,
                                    icon: const Icon(Icons.delete_outline),
                                    onPressed: () async {
                                      if (await confirm(
                                        context,
                                        '删除文件任务',
                                        '移除 ${item.name} 的未完成同步任务。',
                                      )) {
                                        await c.removeSyncItem(
                                          item.id,
                                          record: record,
                                        );
                                      }
                                    },
                                  ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
      );
    },
  );
}
