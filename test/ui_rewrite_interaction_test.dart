import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirrorbridge/app.dart';
import 'package:mirrorbridge/models/media_item.dart';
import 'package:mirrorbridge/repositories/demo_repository.dart';
import 'package:mirrorbridge/state/app_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  String? saved;
  setUp(() {
    saved = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppController.platform, (call) async {
          if (call.method == 'save') {
            saved = (call.arguments as Map)['value'] as String;
          }
          if (call.method == 'load') return saved;
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppController.platform, null),
  );

  test(
    'favorites persist and search/sort keep selection inside visible results',
    () async {
      final c = AppController(DemoRepository(delay: Duration.zero));
      addTearDown(c.dispose);
      await c.connect('10.0.2.2');
      c.local = c.media.take(4).toList();
      final item = c.local.first;
      c.toggleFavorite(item);
      await c.save();
      expect(jsonDecode(saved!)['favorites'], contains(item.id));
      c.localFilter = '收藏';
      expect(c.visibleLocal.map((m) => m.id), [item.id]);
      c.localFilter = '全部';
      c.localSelection.addAll(c.local.map((m) => m.id));
      c.setMediaQuery(item.name.toLowerCase(), isLocal: true);
      expect(c.visibleLocal.map((m) => m.id), [item.id]);
      expect(c.localSelection, {item.id});
      c.setMediaQuery('', isLocal: true);
      c.setMediaSort('文件大小', isLocal: true);
      final sizes = c.visibleLocal.map((m) => m.bytes).toList();
      expect(sizes, [...sizes]..sort((a, b) => b.compareTo(a)));
      final restored = AppController(DemoRepository(delay: Duration.zero));
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.favorites, contains(item.id));
    },
  );

  testWidgets(
    'search, clear, favorites, sort and notification navigation at phone width',
    (tester) async {
      tester.view.physicalSize = const Size(393, 851);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = AppController(DemoRepository(delay: Duration.zero));
      addTearDown(c.dispose);
      await c.connect('10.0.2.2');
      c.local = c.media.take(6).toList();
      c.navigate(4);
      await tester.pumpWidget(MirrorBridgeApp(controller: c));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('local-search')),
        'not-a-file',
      );
      await tester.pumpAndSettle();
      expect(c.visibleLocal, isEmpty);
      tester.view.physicalSize = const Size(360, 640);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      tester.view.physicalSize = const Size(393, 851);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('清除搜索'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('收藏照片').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilterChip, '收藏'));
      await tester.pumpAndSettle();
      expect(c.visibleLocal, hasLength(1));
      await tester.tap(find.byTooltip('排序'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(CheckedPopupMenuItem<String>, '最新拍摄'),
      );
      await tester.pumpAndSettle();
      expect(c.localSort, '最新拍摄');
      c.navigate(0);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('通知'));
      await tester.pumpAndSettle();
      expect(find.text('通知与动态'), findsOneWidget);
      await tester.tap(find.text('${c.cameraModel} 已连接'));
      await tester.pumpAndSettle();
      expect(c.tab, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('render reference screens with real fonts', (tester) async {
    // Local-only visual QA; fonts are never bundled into the application.
    if (!File('C:/Windows/Fonts/msyh.ttc').existsSync()) return;
    await tester.runAsync(() async {
      for (final pair in [
        ('Microsoft YaHei', 'C:/Windows/Fonts/msyh.ttc'),
        ('Ahem', 'C:/Windows/Fonts/msyh.ttc'),
        (
          'MaterialIcons',
          'tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ),
        ('Roboto', 'C:/Windows/Fonts/msyh.ttc'),
      ]) {
        final loader = FontLoader(pair.$1);
        loader.addFont(
          File(
            pair.$2,
          ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
        );
        if (pair.$1 != 'MaterialIcons') {
          loader.addFont(
            File(
              'C:/Windows/Fonts/msyhbd.ttc',
            ).readAsBytes().then((b) => ByteData.sublistView(b)),
          );
        }
        await loader.load();
      }
    });
    tester.view.physicalSize = const Size(393, 851);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = AppController(DemoRepository(delay: Duration.zero));
    addTearDown(c.dispose);
    await c.connect('10.0.2.2');
    c.local = List.generate(
      6,
      (i) => MediaItem(
        id: 'local-$i',
        name: 'DSC_${7281 - i}.JPG',
        asset: [
          'assets/demo.png',
          'assets/demo_media/cat.png',
          'assets/demo_media/coast.png',
          'assets/demo_media/forest.png',
          'assets/demo_media/flowers.png',
        ][i % 5],
        kind: MediaKind.jpg,
        date: DateTime(2026, 9, 15, 16, i),
        bytes: 5200000,
      ),
    );
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MirrorBridgeApp(controller: c),
      ),
    );
    for (final tab in [0, 1, 2, 3, 4]) {
      c.navigate(tab);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final image =
            await (key.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/ui-rewrite/screen-$tab.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}
