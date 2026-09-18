import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/media_item.dart';
import '../state/app_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/shared.dart';
import 'nikon_connection_page.dart';

class ConnectionPage extends StatefulWidget {
  const ConnectionPage({super.key, required this.c});
  final AppController c;
  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends State<ConnectionPage> {
  final ip = TextEditingController();
  final form = GlobalKey<FormState>();
  bool scanning = false;
  bool brandSelected = false;
  String scanMessage = '';
  AppController get c => widget.c;
  @override
  void initState() {
    super.initState();
    if (c.nikon != null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        chooseBrand();
      }
    });
  }

  @override
  void dispose() {
    ip.dispose();
    super.dispose();
  }

  Future<void> chooseBrand() async {
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 18),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              heading('选择相机品牌', size: 22),
              gap(8),
              const Text(
                '不同品牌支持的连接方式不同，请先选择你的相机。',
                style: TextStyle(fontSize: 14),
              ),
              gap(18),
              for (final brand in ['Nikon', 'Canon']) ...[
                InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => Navigator.pop(ctx, brand),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xffe3e4e9)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: Colors.black,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Icon(
                            brand == 'Nikon'
                                ? Icons.photo_camera_outlined
                                : Icons.camera_outlined,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              heading(brand, size: 18),
                              gap(6),
                              Text(
                                brand == 'Nikon'
                                    ? '支持相机 Wi-Fi、STA 局域网和 USB 有线连接。'
                                    : '通过相机 Wi-Fi 连接，检测后会填写 CCAPI 信息。',
                                style: const TextStyle(fontSize: 13),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (brand == 'Nikon') gap(10),
              ],
            ],
          ),
        ),
      ),
    );
    if (selected != null && mounted) {
      setState(() {
        c.brand = selected;
        brandSelected = true;
        c.mode = 'Wi-Fi';
        scanMessage = '';
      });
    }
  }

  Future<void> scan() async {
    setState(() {
      scanning = true;
      scanMessage = '正在扫描附近相机…';
    });
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (!mounted) {
      return;
    }
    setState(() {
      scanning = false;
      scanMessage = c.mode == 'USB' ? '未发现 USB 相机' : '未发现相机，请检查连接后重试。';
    });
  }

  Future<void> connect() async {
    if (!(form.currentState?.validate() ?? false)) {
      return;
    }
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: heading('请选择相机当前连接模式', size: 22),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('根据相机屏幕上的模式选择，避免进入无法读取相册的状态。'),
            gap(),
            ListTile(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
                side: const BorderSide(color: Color(0xffb8cef8)),
              ),
              tileColor: blue.withValues(alpha: .06),
              leading: const Icon(Icons.photo_library_outlined, color: blue),
              title: const Text('STA 传输连接'),
              subtitle: const Text(
                '推荐打开相册\n支持Z9、Z8、Z7Ⅱ、Z6Ⅱ、Z6Ⅲ、Z5、Z5Ⅱ、Zf、Z50Ⅱ、Z30、Zfc',
              ),
              onTap: () => Navigator.pop(ctx, true),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) {
      return;
    }
    final success = await c.connect(ip.text.trim());
    if (!mounted) {
      return;
    }
    if (success) {
      Navigator.pop(context);
    } else {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) => c.nikon != null
      ? NikonConnectionPage(c: c)
      : ListenableBuilder(
          listenable: c,
          builder: (context, _) {
            final sta = c.mode == 'STA',
                usb = c.mode == 'USB',
                busy = c.connection == ConnectionPhase.connecting;
            return Scaffold(
              appBar: AppBar(
                title: Text(brandSelected ? '连接 ${c.brand} 相机' : '连接相机'),
                actions: [
                  TextButton(
                    onPressed: chooseBrand,
                    child: const Text(
                      '切换品牌',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
              body: ListView(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 30),
                children: [
                  if (brandSelected && c.brand == 'Nikon') ...[
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: cardColor,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Row(
                        children: ['Wi-Fi', 'STA', 'USB']
                            .map(
                              (mode) => Expanded(
                                child: InkWell(
                                  onTap: () {
                                    setState(() {
                                      c.mode = mode;
                                      scanMessage = '';
                                    });
                                  },
                                  borderRadius: BorderRadius.circular(20),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                    decoration: BoxDecoration(
                                      color: c.mode == mode
                                          ? blue.withValues(alpha: .10)
                                          : Colors.transparent,
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(
                                        color: c.mode == mode
                                            ? blue.withValues(alpha: .35)
                                            : Colors.transparent,
                                        width: 1.5,
                                      ),
                                    ),
                                    child: Column(
                                      children: [
                                        Container(
                                          width: 34,
                                          height: 34,
                                          decoration: BoxDecoration(
                                            color: c.mode == mode
                                                ? blue.withValues(alpha: .1)
                                                : const Color(0xffededed),
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                          ),
                                          child: Icon(
                                            mode == 'USB'
                                                ? Icons.usb
                                                : mode == 'STA'
                                                ? Icons.router_outlined
                                                : Icons.wifi,
                                            color: c.mode == mode
                                                ? blue
                                                : muted,
                                          ),
                                        ),
                                        gap(8),
                                        Text(
                                          mode,
                                          style: TextStyle(
                                            color: c.mode == mode
                                                ? blue
                                                : Colors.black,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    ),
                    gap(16),
                  ],
                  Panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (usb) ...[
                          Row(
                            children: [
                              const Icon(Icons.usb, color: blue, size: 26),
                              const SizedBox(width: 12),
                              heading('USB 有线连接', size: 20),
                            ],
                          ),
                          gap(14),
                          const Text(
                            '通过 USB 线缆连接相机。首次连接需要同意系统 USB 授权弹窗，并在相机上选择文件传输模式。',
                          ),
                          gap(18),
                          Row(
                            children: [
                              Expanded(
                                child: Pill(
                                  '检测 USB 相机',
                                  onPressed: scanning ? null : scan,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Pill(
                                  '重新检测',
                                  light: true,
                                  onPressed: scanning ? null : scan,
                                ),
                              ),
                            ],
                          ),
                          if (scanMessage.isNotEmpty) ...[
                            gap(12),
                            Text(scanMessage),
                          ],
                        ] else ...[
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              border: Border.all(
                                color: const Color(0xffe7e7eb),
                              ),
                              borderRadius: BorderRadius.circular(28),
                            ),
                            child: Column(
                              children: [
                                if (sta)
                                  CircleAvatar(
                                    radius: 38,
                                    backgroundColor: blue.withValues(
                                      alpha: .10,
                                    ),
                                    child: const Icon(
                                      Icons.router_outlined,
                                      color: blue,
                                      size: 34,
                                    ),
                                  )
                                else
                                  Container(
                                    width: 154,
                                    height: 154,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: blue.withValues(alpha: .06),
                                    ),
                                    child: Center(
                                      child: Container(
                                        width: 112,
                                        height: 112,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: blue.withValues(alpha: .12),
                                        ),
                                        child: const Center(
                                          child: CircleAvatar(
                                            radius: 37,
                                            backgroundColor: blue,
                                            child: Icon(
                                              Icons.wifi,
                                              color: Colors.white,
                                              size: 36,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                gap(18),
                                heading(
                                  sta ? '局域网 / 手机热点连接' : '准备连接热点',
                                  size: 24,
                                ),
                                gap(12),
                                Text(
                                  sta
                                      ? '先扫描发现相机，或在下方输入相机屏幕显示的 IP 手动连接。'
                                      : '连接相机发出的 Wi-Fi 热点后，返回这里开始检测。',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ],
                            ),
                          ),
                          gap(20),
                        ],
                        if (!sta && !usb) ...[
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xfffff8e8),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: const Text(
                              '⚠  连接相机热点后，如果手机提示无法访问互联网，请选择保持连接或不切换网络。',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                          gap(16),
                        ],
                        if (!usb)
                          Row(
                            children: [
                              Expanded(
                                child: heading(
                                  usb
                                      ? '检测 USB 相机'
                                      : sta
                                      ? 'STA 相机扫描'
                                      : '相机 Wi-Fi 热点',
                                ),
                              ),
                              TextButton.icon(
                                onPressed: scanning ? null : scan,
                                icon: const Icon(Icons.refresh, size: 18),
                                label: Text(usb ? '重新检测' : '扫描'),
                              ),
                            ],
                          ),
                        if (!usb) ...[
                          Text(
                            sta
                                ? '扫描同一局域网或手机热点里的 Nikon STA 相机。点击发现的设备后，再选择相机当前连接模式。'
                                : '扫描附近相机热点，点击后会进入系统 Wi-Fi 连接该网络。',
                            style: const TextStyle(fontSize: 13),
                          ),
                          gap(12),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: const Color(0xffe4e4e7),
                              ),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              scanMessage.isNotEmpty
                                  ? scanMessage
                                  : sta
                                  ? '点击扫描，通过热点客户端和局域网探测发现 Nikon STA 相机。'
                                  : '点击扫描，发现附近可用的相机 Wi-Fi 热点。',
                            ),
                          ),
                        ] else if (scanMessage.isNotEmpty)
                          Text(scanMessage),
                        if (sta) ...[
                          gap(18),
                          ExpansionTile(
                            tilePadding: EdgeInsets.zero,
                            title: const Text('手动输入 IP'),
                            subtitle: const Text(
                              '点击展开后输入相机屏幕显示的 IP。',
                              style: TextStyle(fontSize: 12),
                            ),
                            children: [
                              Form(
                                key: form,
                                child: TextFormField(
                                  controller: ip,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                    labelText: '相机 IP 地址',
                                    hintText: '例如 192.168.1.100',
                                    border: OutlineInputBorder(),
                                  ),
                                  validator: (value) =>
                                      AppController.validIp(value ?? '')
                                      ? null
                                      : '请输入有效的 IPv4 地址',
                                ),
                              ),
                              gap(12),
                              Pill(
                                busy ? '正在连接…' : '选择方式连接',
                                onPressed: busy ? null : connect,
                              ),
                              gap(12),
                            ],
                          ),
                          gap(18),
                          heading('最近连接设备'),
                          gap(12),
                          if (c.recent.isEmpty)
                            const Text('连接成功后自动保存设备，可在此重新连接。')
                          else
                            ...c.recent.map(
                              (value) => ListTile(
                                title: Text(value),
                                leading: const Icon(Icons.history),
                                onTap: () async {
                                  ip.text = value;
                                  final ok = await c.connect(value);
                                  if (ok && context.mounted) {
                                    Navigator.pop(context);
                                  }
                                },
                              ),
                            ),
                        ],
                        if (!sta && !usb) ...[
                          gap(16),
                          Row(
                            children: [
                              Expanded(
                                child: Pill(
                                  '打开 Wi-Fi 设置',
                                  onPressed: () async {
                                    try {
                                      await AppController.platform.invokeMethod(
                                        'wifi',
                                      );
                                    } on MissingPluginException {
                                      if (context.mounted) {
                                        notice(context, '当前平台无法打开 Wi-Fi 设置');
                                      }
                                    }
                                  },
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Pill('我已连接，开始检测', onPressed: scan),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  gap(16),
                  if (c.brand == 'Canon') ...[
                    Panel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          heading('Canon 使用 Wi-Fi / CCAPI'),
                          gap(),
                          const Text(
                            '请先连接 Canon 相机 Wi-Fi，然后点击“我已连接，开始检测”。检测到 Canon 后会弹出 CCAPI 地址和账号信息输入框。',
                          ),
                        ],
                      ),
                    ),
                    gap(16),
                  ],
                  Panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(child: heading('相机服务检测')),
                            const StatusChip('未连接'),
                          ],
                        ),
                        gap(20),
                        Text(
                          c.message.isNotEmpty
                              ? c.message
                              : '已连接 Wi-Fi，但无权限读取网络名称，正在通过相机服务验证。',
                        ),
                        ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          title: const Text('高级信息'),
                          children: [
                            ListTile(
                              title: const Text('协议'),
                              subtitle: Text(c.connected ? 'PTP/IP' : '未知'),
                            ),
                            ListTile(
                              title: const Text('相机地址'),
                              subtitle: Text(
                                c.address.isEmpty ? '未知' : c.address,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  gap(16),
                  Panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        heading('连接帮助'),
                        gap(),
                        const Text(
                          '请优先通过系统 Wi-Fi 设置连接相机热点。若系统提示该 Wi-Fi 无互联网，请选择保持连接；若相机屏幕弹出授权提示，请允许手机连接。',
                        ),
                      ],
                    ),
                  ),
                  if (c.isDemo) ...[
                    gap(),
                    Pill(
                      '连接演示相机（本地数据）',
                      icon: Icons.science_outlined,
                      onPressed: busy
                          ? null
                          : () async {
                              c.mode = 'STA';
                              final ok = await c.connect('10.0.2.2');
                              if (ok && context.mounted) {
                                Navigator.pop(context);
                              }
                            },
                    ),
                  ],
                ],
              ),
            );
          },
        );
}
