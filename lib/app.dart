import 'dart:async';
import 'package:flutter/material.dart';
import 'state/app_controller.dart';
import 'theme/app_theme.dart';
import 'pages/home_page.dart';
import 'pages/activity_page.dart';
import 'pages/camera_page.dart';
import 'pages/media_page.dart';
import 'pages/sync_page.dart';
import 'pages/connection_page.dart';
import 'pages/settings_pages.dart';
import 'widgets/shared.dart';

class MirrorBridgeApp extends StatelessWidget {
  const MirrorBridgeApp({super.key, required this.controller});
  final AppController controller;
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: '镜桥',
    theme: appTheme(),
    home: AppShell(c: controller),
  );
}

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.c});
  final AppController c;
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late final AnimationController _pageFade;
  int _lastTab = 0;
  @override
  void initState() {
    super.initState();
    _lastTab = widget.c.tab;
    _pageFade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 160),
      value: 1,
    );
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pageFade.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(widget.c.refreshLocal(force: false));
      if (widget.c.connected) unawaited(widget.c.nikon?.checkNewPhotos());
    }
  }

  final localMediaKey = GlobalKey<MediaPageState>();
  static const labels = ['我的相机', '相机照片', '首页', '同步任务', '本地媒体'];
  static const titles = ['首页', '我的相机', '相机照片', '同步任务', '本地媒体'];
  static const subtitles = [
    '连接相机 · 整理照片 · 让精彩随时可见',
    '连接相机 · 管理设备 · 高效创作',
    '浏览相机中的照片与视频',
    '查看与管理照片同步进度',
    '管理已导入到手机的照片和视频',
  ];
  static const tabOrder = [1, 2, 0, 3, 4];
  static const icons = [
    Icons.photo_camera_outlined,
    Icons.photo_library_outlined,
    Icons.home_outlined,
    Icons.sync,
    Icons.folder_outlined,
  ];
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.c,
    builder: (context, _) {
      final c = widget.c;
      if (_lastTab != c.tab) {
        _lastTab = c.tab;
        if (MediaQuery.disableAnimationsOf(context)) {
          _pageFade.value = 1;
        } else {
          _pageFade.forward(from: .35);
        }
      }
      void connect() => Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => ConnectionPage(c: c)),
      );
      return Scaffold(
        appBar: AppBar(
          toolbarHeight: 88,
          titleSpacing: 20,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                titles[c.tab],
                style: const TextStyle(
                  color: ink,
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitles[c.tab],
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
          actions: [
            if (c.tab != 4)
              IconButton(
                tooltip: '通知',
                icon: const Icon(Icons.notifications_none_rounded),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(builder: (_) => ActivityPage(c: c)),
                ),
              ),
            if (c.tab != 4)
              IconButton(
                tooltip: '设置',
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => showCameraSettings(context, c),
              ),
            if (c.tab == 4 && c.nikon != null)
              IconButton(
                tooltip: '手工导入照片、RAW 或视频',
                onPressed: c.importingMedia ? null : () => c.importMedia(),
                icon: c.importingMedia
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add_photo_alternate_outlined),
              ),
            if (c.tab == 4)
              IconButton(
                tooltip: '多选',
                onPressed: () => localMediaKey.currentState?.toggleSelecting(),
                icon: const Icon(Icons.checklist, color: muted),
              ),
          ],
        ),
        body: Column(
          children: [
            if (c.message.isNotEmpty)
              TimedNotice(
                key: ValueKey(c.message),
                message: c.message,
                onExpired: () {
                  c.message = '';
                  c.changed();
                },
              ),
            Expanded(
              child: FadeTransition(
                opacity: _pageFade,
                child: IndexedStack(
                  index: c.tab,
                  children: [
                    HomePage(c: c, onConnect: connect),
                    CameraPage(c: c, onConnect: connect),
                    MediaPage(c: c, onConnect: connect),
                    SyncPage(c: c),
                    MediaPage(
                      key: localMediaKey,
                      c: c,
                      isLocal: true,
                      onConnect: connect,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          height: 72,
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          indicatorColor: Colors.transparent,
          selectedIndex: tabOrder.indexOf(c.tab),
          onDestinationSelected: (index) => c.navigate(tabOrder[index]),
          labelTextStyle: WidgetStateProperty.resolveWith(
            (states) => TextStyle(
              fontSize: 11,
              color: states.contains(WidgetState.selected) ? brandGreen : muted,
              fontWeight: states.contains(WidgetState.selected)
                  ? FontWeight.w700
                  : FontWeight.w500,
            ),
          ),
          destinations: List.generate(
            5,
            (i) => NavigationDestination(
              icon: Icon(icons[i], color: muted),
              selectedIcon: Icon(
                i == 0
                    ? Icons.photo_camera
                    : i == 1
                    ? Icons.photo_library
                    : i == 2
                    ? Icons.home
                    : i == 4
                    ? Icons.folder
                    : icons[i],
                color: brandGreen,
              ),
              label: labels[i],
            ),
          ),
        ),
      );
    },
  );
}
