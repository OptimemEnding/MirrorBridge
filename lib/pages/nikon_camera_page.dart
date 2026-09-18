import '../models/user_message.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import '../models/camera_storage.dart';
import '../protocol/ptp.dart';
import '../state/app_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/shared.dart';
import 'nikon_monitor_page.dart';

class NikonCameraPage extends StatelessWidget {
  const NikonCameraPage({super.key, required this.c, required this.onConnect});
  final AppController c;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
    children: [
      Panel(
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  width: 66,
                  height: 66,
                  decoration: const BoxDecoration(
                    color: Color(0xfff1f4f7),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.photo_camera_outlined,
                    color: ink,
                    size: 32,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        c.connected ? c.cameraModel : '还没有连接相机',
                        style: const TextStyle(
                          color: ink,
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 5),
                      if (c.connected)
                        Row(
                          children: [
                            Semantics(
                              label: '相机已连接',
                              child: Container(
                                key: const ValueKey(
                                  'camera-connected-indicator',
                                ),
                                width: 9,
                                height: 9,
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: brandGreen,
                                ),
                              ),
                            ),
                            const SizedBox(width: 7),
                            const Text(
                              '已连接',
                              style: TextStyle(
                                color: brandGreen,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        )
                      else
                        const Text('通过 Wi-Fi、STA 或 USB 连接 Nikon 相机。'),
                      if (c.connected) ...[
                        const SizedBox(height: 3),
                        Text(c.connectionLabel),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  flex: 4,
                  child: Pill(
                    c.connected ? '进入实时监看' : '连接相机',
                    icon: c.connected ? Icons.videocam_outlined : Icons.link,
                    onPressed: c.connected
                        ? c.busy
                              ? null
                              : () => Navigator.push(
                                  context,
                                  MaterialPageRoute<void>(
                                    builder: (_) => NikonMonitorPage(c: c),
                                  ),
                                )
                        : onConnect,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 3,
                  child: Pill(
                    c.connected ? '断开连接' : '重新检测',
                    light: true,
                    onPressed: c.connected ? c.disconnect : onConnect,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      gap(14),
      if (c.connected) ...[
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionTitle(Icons.list_alt_outlined, '设备信息'),
              gap(10),
              _infoRow('品牌', c.nikon?.device?.make ?? '未知'),
              _infoRow('型号', c.cameraModel),
              _infoRow('序列号', c.nikon?.device?.serial ?? '未知'),
              _infoRow(
                '已拍摄文件',
                '${c.cameraTotal ?? c.media.length} 个文件',
                last: true,
              ),
            ],
          ),
        ),
        gap(14),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionTitle(Icons.sd_card_outlined, '相机存储'),
              gap(12),
              if (c.cameraStorages.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 14),
                  child: Text('相机暂未返回存储卡容量信息。'),
                )
              else
                for (var i = 0; i < c.cameraStorages.length; i++)
                  _storage(
                    c.cameraStorages[i],
                    i == c.cameraStorages.length - 1,
                  ),
            ],
          ),
        ),
        gap(14),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionTitle(Icons.sync, '传输与同步'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('边拍边传'),
                subtitle: const Text('拍摄的新照片会自动传输到手机'),
                value: c.live,
                onChanged: c.setLive,
              ),
              const Divider(height: 1),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('接收相机主动发送'),
                subtitle: const Text('允许相机主动发送照片和视频到手机'),
                value: c.receivePush,
                onChanged: (value) async {
                  c.receivePush = value;
                  await c.setLive(c.live);
                },
              ),
            ],
          ),
        ),
        gap(14),
      ],
      Panel(
        padding: 16,
        child: Row(
          children: [
            const Icon(Icons.monitor_heart_outlined, color: ink),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '设备诊断',
                    style: TextStyle(color: ink, fontWeight: FontWeight.w700),
                  ),
                  Text('检测连接状态并导出诊断日志'),
                ],
              ),
            ),
            OutlinedButton.icon(
              onPressed: c.nikon == null
                  ? null
                  : () => _exportDiagnostics(context),
              icon: const Icon(Icons.ios_share, size: 18),
              label: const Text('导出日志'),
            ),
          ],
        ),
      ),
    ],
  );

  Future<void> _exportDiagnostics(BuildContext context) async {
    try {
      final path = await nativeCamera.invokeMethod<String>('diagnostics');
      if (path == null) return;
      await File(path).writeAsString(
        '\nDart / PTP-IP\n${c.nikon!.logs.join('\n')}',
        mode: FileMode.append,
      );
      await nativeCamera.invokeMethod('share', {
        'paths': [path],
      });
    } catch (e) {
      if (context.mounted) notice(context, userMessage(e));
    }
  }

  Widget _sectionTitle(IconData icon, String title) => Row(
    children: [
      Icon(icon, color: ink, size: 23),
      const SizedBox(width: 10),
      heading(title),
    ],
  );

  Widget _infoRow(String label, String value, {bool last = false}) => Container(
    padding: const EdgeInsets.symmetric(vertical: 10),
    decoration: BoxDecoration(
      border: last
          ? null
          : const Border(bottom: BorderSide(color: Color(0xffedf0f3))),
    ),
    child: Row(
      children: [
        Expanded(child: Text(label)),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: const TextStyle(color: ink),
          ),
        ),
      ],
    ),
  );

  Widget _storage(CameraStorage card, bool last) {
    final used = card.capacity != null && card.free != null
        ? (card.capacity! - card.free!).clamp(0, card.capacity!)
        : 0;
    final progress = card.capacity == null || card.capacity == 0
        ? 0.0
        : used / card.capacity!;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: last
            ? null
            : const Border(bottom: BorderSide(color: Color(0xffedf0f3))),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: const Color(0xfff1f4f7),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.sd_card_outlined, color: muted),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  card.description.isEmpty
                      ? card.title
                      : '${card.description} / ${card.title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 7),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 7,
                    backgroundColor: const Color(0xffe5e9ef),
                    color: brandGreen,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 105,
            child: Text(
              card.details,
              textAlign: TextAlign.right,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
