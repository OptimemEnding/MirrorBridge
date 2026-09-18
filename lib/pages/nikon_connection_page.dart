import '../models/user_message.dart';
import 'package:flutter/material.dart';
import '../state/app_controller.dart';
import '../widgets/shared.dart';
import '../theme/app_theme.dart';

class NikonConnectionPage extends StatefulWidget {
  const NikonConnectionPage({super.key, required this.c});
  final AppController c;
  @override
  State<NikonConnectionPage> createState() => _NikonConnectionPageState();
}

class _NikonConnectionPageState extends State<NikonConnectionPage> {
  final address = TextEditingController();
  List<Map<String, dynamic>> devices = [];
  bool scanning = false;
  String error = '', scanProgress = '';
  bool disposed = false;
  int scanEpoch = 0;
  AppController get c => widget.c;
  @override
  void initState() {
    super.initState();
    address.text =
        c.recent.where(AppController.validIp).firstOrNull ?? '192.168.1.1';
  }

  @override
  void dispose() {
    disposed = true;
    scanEpoch++;
    c.nikon?.clearDiscovery();
    address.dispose();
    super.dispose();
  }

  Future<void> scan() async {
    if (scanning) return;
    final epoch = ++scanEpoch;
    setState(() {
      scanProgress = '';
      scanning = true;
      error = '';
      devices = [];
    });
    try {
      final result = await c.nikon!.discover(
        c.mode,
        [
          if (AppController.validIp(address.text.trim())) address.text.trim(),
          ...c.recent,
        ],
        onDevice: (device) {
          if (!mounted || epoch != scanEpoch) return;
          setState(() {
            final index = devices.indexWhere(
              (d) => d['deviceId'] == device['deviceId'],
            );
            if (index < 0) {
              devices.add(device);
            } else {
              devices[index] = device;
            }
          });
        },
        onProgress: (done, total, host) {
          if (mounted && epoch == scanEpoch) {
            setState(() => scanProgress = '正在检测 $done / $total · $host');
          }
        },
        cancelled: () =>
            disposed || epoch != scanEpoch || c.connection.name == 'connecting',
      );
      if (mounted && epoch == scanEpoch) {
        setState(() {
          devices = result;
          if (result.isEmpty) {
            error = c.mode == 'USB'
                ? '未发现 Nikon USB 相机，请检查数据线、OTG 和相机 USB 模式。'
                : '未发现开放 PTP/IP 的设备。请连接相机 Wi-Fi，或输入相机屏幕上的 IP。';
          }
        });
      }
    } catch (e) {
      if (mounted && epoch == scanEpoch) setState(() => error = userMessage(e));
    } finally {
      if (mounted && epoch == scanEpoch) setState(() => scanning = false);
    }
  }

  bool get waitingForCamera =>
      c.connection.name == 'connecting' &&
      c.nikon?.awaitingCameraConfirmation == true;

  bool get pairingDialogVisible =>
      c.connection.name == 'connecting' && c.nikon?.pairingInProgress == true;

  void cancelConnection() {
    c.disconnect();
    setState(() => error = '连接已取消');
  }

  Future<void> connect(String endpoint) async {
    if (c.connection.name == 'connecting') return;
    scanEpoch++;
    setState(() {
      error = '';
      scanning = false;
    });
    final ok = await c.connect(endpoint.trim());
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context);
    } else {
      setState(() => error = c.message);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) => PopScope(
      canPop: !pairingDialogVisible,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && pairingDialogVisible) cancelConnection();
      },
      child: Stack(
        children: [
          ExcludeFocus(
            excluding: pairingDialogVisible,
            child: Scaffold(
              appBar: AppBar(title: const Text('连接 Nikon 相机')),
              body: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Panel(
                    padding: 16,
                    child: Row(
                      children: [
                        const CircleAvatar(
                          radius: 26,
                          backgroundColor: paleGreen,
                          child: Icon(
                            Icons.photo_camera_outlined,
                            color: brandGreen,
                            size: 28,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              heading('已支持 Nikon 相机'),
                              const SizedBox(height: 4),
                              const Text(
                                '选择连接方式，与相机建立连接',
                                style: TextStyle(fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  gap(16),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: 'Wi-Fi',
                        label: Text('Wi-Fi'),
                        icon: Icon(Icons.wifi),
                      ),
                      ButtonSegment(
                        value: 'STA',
                        label: Text('STA'),
                        icon: Icon(Icons.router),
                      ),
                      ButtonSegment(
                        value: 'USB',
                        label: Text('USB'),
                        icon: Icon(Icons.usb),
                      ),
                    ],
                    selected: {c.mode},
                    onSelectionChanged:
                        c.connection.name == 'connecting' || scanning
                        ? null
                        : (s) => setState(() {
                            c.mode = s.first;
                            devices = [];
                            error = '';
                          }),
                  ),
                  gap(20),
                  Panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        heading(
                          c.mode == 'USB'
                              ? 'USB 有线连接'
                              : c.mode == 'STA'
                              ? '局域网连接'
                              : '相机 Wi-Fi',
                        ),
                        gap(),
                        Text(
                          c.mode == 'USB'
                              ? '使用支持数据传输的 USB 线连接相机，选择文件传输/PTP 模式，并允许系统 USB 授权。'
                              : c.mode == 'STA'
                              ? '手机和相机加入同一网络。在相机中启用连接计算机 / 图片传输，然后输入相机 IP。'
                              : '手机连接相机 Wi-Fi 热点后，扫描设备或输入相机 IP。',
                        ),
                        TextButton.icon(
                          icon: const Icon(Icons.help_outline, size: 18),
                          label: const Text('查看连接教程'),
                          onPressed: () => showModalBottomSheet<void>(
                            context: context,
                            isScrollControlled: true,
                            builder: (ctx) => SafeArea(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    heading('${c.mode} 连接指南', size: 22),
                                    gap(20),
                                    for (final step
                                        in (c.mode == 'USB'
                                            ? [
                                                '1. 使用支持数据传输的线材连接手机和相机。',
                                                '2. 相机选择 USB 文件传输 / PTP 模式。',
                                                '3. 点击检测 USB 相机，并允许 Android 授权。',
                                              ]
                                            : c.mode == 'STA'
                                            ? [
                                                '1. 手机和相机加入同一网络，关闭路由器客户端隔离。',
                                                '2. 相机选择连接计算机 / 图片传输，查看相机 IP。',
                                                '3. 输入 IP 或扫描设备；相机配对完成后按确定退出。',
                                              ]
                                            : [
                                                '1. 在相机网络菜单中开启 Wi-Fi 热点。',
                                                '2. 手机连接该热点，无互联网提示请选择保持连接。',
                                                '3. 返回镜桥扫描相机，并在相机上确认配对。',
                                              ]))
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 16,
                                        ),
                                        child: Text(step),
                                      ),
                                    Pill(
                                      '知道了',
                                      onPressed: () => Navigator.pop(ctx),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        gap(),
                        if (c.connection.name == 'connecting') ...[
                          const LinearProgressIndicator(),
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Text(c.message),
                          ),
                          TextButton(
                            onPressed: cancelConnection,
                            child: const Text('取消连接'),
                          ),
                        ],
                        OutlinedButton.icon(
                          onPressed:
                              scanning || c.connection.name == 'connecting'
                              ? null
                              : scan,
                          icon: scanning
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  c.mode == 'USB' ? Icons.usb : Icons.search,
                                ),
                          label: Text(
                            scanning
                                ? (scanProgress.isEmpty
                                      ? '正在检测…'
                                      : scanProgress)
                                : c.mode == 'USB'
                                ? '检测 USB 相机'
                                : '扫描相机，选择后连接',
                          ),
                        ),
                        if (scanning)
                          TextButton(
                            onPressed: () {
                              scanEpoch++;
                              c.nikon?.clearDiscovery();
                              setState(() => scanning = false);
                            },
                            child: const Text('停止扫描'),
                          ),
                        if (devices.isNotEmpty && scanning)
                          const Text('已发现的设备可以立即连接'),
                        for (final d in devices)
                          ListTile(
                            leading: Icon(
                              c.mode == 'USB'
                                  ? Icons.usb
                                  : Icons.camera_alt_outlined,
                            ),
                            title: Text(d['name'] as String),
                            subtitle: Text(d['deviceId'] as String),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: c.connection.name == 'connecting'
                                ? null
                                : () => connect(d['deviceId'] as String),
                          ),
                        gap(),
                        if (c.mode != 'USB') ...[
                          OutlinedButton.icon(
                            onPressed: () =>
                                AppController.platform.invokeMethod('wifi'),
                            icon: const Icon(Icons.settings),
                            label: const Text('打开 Wi-Fi 设置'),
                          ),
                          gap(),
                          TextField(
                            controller: address,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            textInputAction: TextInputAction.go,
                            enabled: c.connection.name != 'connecting',
                            onSubmitted: (value) => connect(value.trim()),
                            decoration: InputDecoration(
                              suffixIcon: IconButton(
                                tooltip: '清除 IP 地址',
                                onPressed: () => address.clear(),
                                icon: const Icon(Icons.cancel_outlined),
                              ),
                              labelText: '相机 IP 地址',
                              hintText: '192.168.1.1',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          gap(),
                          Pill(
                            c.connection.name == 'connecting'
                                ? '正在连接…'
                                : '连接此地址',
                            onPressed: c.connection.name == 'connecting'
                                ? null
                                : () => connect(address.text),
                          ),
                          gap(),
                        ],
                        if (error.isNotEmpty) ...[
                          gap(),
                          Text(
                            error,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  gap(),
                  if (c.mode != 'USB' &&
                      c.recent.where(AppController.validIp).isNotEmpty)
                    Panel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          heading('最近连接'),
                          for (final ip in c.recent.where(
                            AppController.validIp,
                          ))
                            ListTile(
                              title: Text(c.nikon?.deviceNames[ip] ?? '相机设备'),
                              subtitle: Text(ip),
                              leading: const Icon(Icons.history),
                              onTap: c.connection.name == 'connecting'
                                  ? null
                                  : () => connect(ip),
                            ),
                        ],
                      ),
                    ),
                  gap(),
                  const Text(
                    '首次连接或更换模式时，请留意相机屏幕上的配对确认。传输模式和遥控模式切换期间，相机可能短暂忙碌。',
                  ),
                ],
              ),
            ),
          ),
          if (pairingDialogVisible)
            Positioned.fill(
              child: BlockSemantics(
                child: Stack(
                  children: [
                    const ModalBarrier(
                      dismissible: false,
                      color: Colors.black54,
                    ),
                    FocusScope(
                      autofocus: true,
                      child: AlertDialog(
                        key: const ValueKey('camera-confirmation-dialog'),
                        scrollable: true,
                        title: Text(
                          waitingForCamera ? '等待相机确认' : '正在连接相机',
                          textAlign: TextAlign.center,
                        ),
                        content: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(height: 8),
                            const SizedBox(
                              width: 48,
                              height: 48,
                              child: CircularProgressIndicator(
                                strokeWidth: 3,
                                semanticsLabel: '正在连接相机',
                              ),
                            ),
                            const SizedBox(height: 24),
                            Text(
                              waitingForCamera
                                  ? '请在相机上按 OK／确认键'
                                  : '相机已确认，正在准备相册',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 21,
                                fontWeight: FontWeight.w700,
                                color: Colors.black87,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              waitingForCamera
                                  ? '相机显示“配对完成”后，请按该键退出。\n手机会自动继续连接，无需再次点击。'
                                  : '请稍候，连接完成后会自动进入相册。',
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                        actionsAlignment: MainAxisAlignment.center,
                        actions: [
                          TextButton(
                            onPressed: cancelConnection,
                            child: const Text('取消连接'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
