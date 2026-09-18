import 'package:flutter/material.dart';
import '../models/media_item.dart';
import '../state/app_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/shared.dart';

class ActivityPage extends StatelessWidget {
  const ActivityPage({super.key, required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('通知与动态')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Panel(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(
                backgroundColor: paleGreen,
                child: Icon(
                  c.connected ? Icons.link : Icons.link_off,
                  color: brandGreen,
                ),
              ),
              title: Text(c.connected ? '${c.cameraModel} 已连接' : '尚未连接相机'),
              subtitle: Text(
                c.connected ? c.connectionLabel : '连接设备后即可浏览照片与开始同步',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.pop(context);
                c.navigate(1);
              },
            ),
          ),
          if (c.message.isNotEmpty) ...[gap(), Panel(child: Text(c.message))],
          gap(24),
          ExpansionTile(
            title: Text('最近动态 (${c.visibleSyncTasks.length})'),
            subtitle: const Text('点击展开查看传输记录'),
            children: [
              if (c.hasClearableCompletedOrMissingRecords)
                TextButton(
                  onPressed: () => c.clearCompletedAndMissingRecords(),
                  child: const Text('清除已完成及失效记录'),
                ),
              gap(12),
              if (c.visibleSyncTasks.isEmpty)
                const Panel(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 28),
                    child: Column(
                      children: [
                        Icon(
                          Icons.notifications_none_rounded,
                          size: 40,
                          color: muted,
                        ),
                        SizedBox(height: 12),
                        Text('暂时没有传输动态'),
                        SizedBox(height: 6),
                        Text('同步、导入和导出的结果会显示在这里。', textAlign: TextAlign.center),
                      ],
                    ),
                  ),
                ),
              for (final task in c.visibleSyncTasks.take(30)) ...[
                Panel(
                  padding: 8,
                  child: ListTile(
                    leading: Icon(
                      task.phase == SyncPhase.partialFailure
                          ? Icons.error_outline
                          : Icons.sync,
                      color: task.phase == SyncPhase.partialFailure
                          ? Colors.red
                          : brandGreen,
                    ),
                    title: Text(switch (task.type) {
                      SyncTaskType.cameraSync => '相机同步',
                      SyncTaskType.manualImport => '手工导入',
                      SyncTaskType.editorExport => '编辑导出',
                    }),
                    subtitle: Text(
                      '${task.createdAt.toLocal().toString().substring(0, 16)}\n完成 ${task.completed.length} 个 · 失败 ${task.failed.length} 个',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.pop(context);
                      c.navigate(3);
                    },
                  ),
                ),
                gap(10),
              ],
            ],
          ),
        ],
      ),
    ),
  );
}
