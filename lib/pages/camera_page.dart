import 'package:flutter/material.dart';
import '../state/app_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/shared.dart';
import 'nikon_camera_page.dart';

class CameraPage extends StatelessWidget {
  const CameraPage({super.key, required this.c, required this.onConnect});
  final AppController c;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    if (c.nikon != null) return NikonCameraPage(c: c, onConnect: onConnect);
    return ListView(
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
                        Text(
                          c.connected
                              ? '${c.connectionLabel} · ${c.isDemo ? '演示数据' : c.address}'
                              : '通过 Wi-Fi 或 USB 建立连接',
                        ),
                        const SizedBox(height: 5),
                        Text(
                          c.connected ? '● 已连接' : '支持 Nikon 与 Canon 相机',
                          style: TextStyle(
                            color: c.connected ? brandGreen : muted,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              gap(18),
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
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.list_alt_outlined, color: ink),
                  const SizedBox(width: 10),
                  heading('设备信息'),
                ],
              ),
              gap(10),
              _info('品牌', c.connected ? (c.isDemo ? 'Nikon' : c.brand) : '—'),
              _info('型号', c.connected ? c.cameraModel : '—'),
              _info('连接协议', c.connected ? c.connectionLabel : '—'),
              _info('已读取文件', '${c.media.length} 个文件', last: true),
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
                  const Icon(Icons.sd_card_outlined, color: ink),
                  const SizedBox(width: 10),
                  heading('相机存储'),
                ],
              ),
              gap(12),
              if (!c.connected)
                const Text('连接相机后会显示存储卡和剩余容量。')
              else if (c.cameraStorages.isEmpty)
                const Text('相机暂未返回存储卡容量信息。')
              else
                for (final storage in c.cameraStorages)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const CircleAvatar(
                      backgroundColor: paleGreen,
                      child: Icon(Icons.sd_card_outlined, color: brandGreen),
                    ),
                    title: Text(storage.title),
                    subtitle: Text(storage.details),
                  ),
            ],
          ),
        ),
        gap(14),
        Panel(
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.sync),
            title: const Text('边拍边传'),
            subtitle: const Text('拍摄的新照片会自动加入同步任务'),
            value: c.live,
            onChanged: c.connected ? c.setLive : null,
          ),
        ),
      ],
    );
  }

  Widget _info(String label, String value, {bool last = false}) => Container(
    padding: const EdgeInsets.symmetric(vertical: 10),
    decoration: BoxDecoration(
      border: last
          ? null
          : const Border(bottom: BorderSide(color: Color(0xffedf0f3))),
    ),
    child: Row(
      children: [
        Expanded(child: Text(label)),
        Text(value, style: const TextStyle(color: ink)),
      ],
    ),
  );
}
