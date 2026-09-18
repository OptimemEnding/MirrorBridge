import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirrorbridge/models/media_item.dart';
import 'package:mirrorbridge/pages/nikon_editor_page.dart';
import 'package:mirrorbridge/pages/nikon_media_detail_page.dart';
import 'package:mirrorbridge/protocol/ptp.dart';
import 'package:mirrorbridge/repositories/demo_repository.dart';
import 'package:mirrorbridge/state/app_controller.dart';
import 'package:mirrorbridge/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (!File('C:/Windows/Fonts/msyh.ttc').existsSync()) return;
    for (final family in ['Roboto', 'Microsoft YaHei']) {
      final loader = FontLoader(family);
      for (final font in ['msyh.ttc', 'msyhbd.ttc']) {
        loader.addFont(
          File(
            'C:/Windows/Fonts/$font',
          ).readAsBytes().then((b) => ByteData.sublistView(b)),
        );
      }
      await loader.load();
    }
    final icons = FontLoader('MaterialIcons')
      ..addFont(
        File(
          'tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ).readAsBytes().then((b) => ByteData.sublistView(b)),
      );
    await icons.load();
  });
  setUp(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppController.platform, (_) async => null),
  );
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppController.platform, null),
  );

  MediaItem sample() => MediaItem(
    id: 'reference',
    name: 'DSC_7281.NEF',
    kind: MediaKind.raw,
    date: DateTime(2024, 10, 27, 18, 24, 36),
    bytes: 45200000,
    exif: {
      'ImageWidth': '8256',
      'ImageLength': '5504',
      'Model': 'Nikon Z8',
      'LensModel': 'NIKKOR Z 24-70mm f/2.8 S',
      'FocalLength': '35',
      'FNumber': '8',
      'ExposureTime': '0.003125',
      'PhotographicSensitivity': '100',
      'DateTimeOriginal': '2024-10-27 18:24:36',
    },
  );

  Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
    for (var frame = 0; frame < 3; frame++) {
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();
    }
    await tester.runAsync(() async {
      final image =
          await (key.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/detail-editor/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final width in [393.0, 360.0]) {
    testWidgets('editor reference layout and interactions $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 851);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = AppController(DemoRepository(delay: Duration.zero));
      addTearDown(c.dispose);
      final item = sample();
      c.local = [item];
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: appTheme(),
            home: NikonEditorPage(c: c, item: item),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('边框样式'), findsOneWidget);
      expect(find.text('显示 EXIF 水印'), findsNothing);
      expect(find.text('导出海报'), findsOneWidget);
      expect(find.text('LUT'), findsNothing);
      expect(tester.takeException(), isNull);
      await capture(tester, key, 'editor-${width.toInt()}');

      await tester.tap(find.text('对比'));
      await tester.pumpAndSettle();
      expect(find.text('效果'), findsOneWidget);
      await tester.tap(find.text('效果'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全屏预览'));
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(NavigationDestination, '文字'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑标题与副标题'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, '主标题'),
        'MY MOUNTAIN',
      );
      await tester.tap(find.text('应用文字'));
      await tester.pumpAndSettle();
      expect(find.text('MY MOUNTAIN'), findsWidgets);
      await tester.tap(find.text('重置'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '重置').last);
      await tester.pumpAndSettle();
      expect(find.text('A BIGGER\nWORLD'), findsNothing);
      expect(find.text('MY MOUNTAIN'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('photo detail actions metadata and computed insights', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 851);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = AppController(DemoRepository(delay: Duration.zero));
    addTearDown(c.dispose);
    final item = sample();
    c.local = [item];
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: appTheme(),
          home: NikonMediaDetailPage(c: c, item: item, local: true),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
    expect(find.text('分享'), findsOneWidget);
    expect(find.text('直方图'), findsOneWidget);
    expect(find.text('主要色彩'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await capture(tester, key, 'detail');
    await tester.tap(find.byTooltip('收藏照片'));
    await tester.pumpAndSettle();
    expect(c.favorites, contains(item.id));
    await tester.tap(find.text('直方图'));
    await tester.pumpAndSettle();
    expect(find.text('RGB 直方图'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(c.local, hasLength(1));
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(find.text('创意编辑'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('local photo reads EXIF without a Nikon repository', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 851);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = AppController(DemoRepository(delay: Duration.zero));
    addTearDown(c.dispose);
    expect(c.nikon, isNull);
    final item = MediaItem(
      id: 'local-exif',
      name: 'DSC_0001.JPG',
      kind: MediaKind.jpg,
      date: DateTime(2026, 9, 17),
      bytes: 1234,
      asset: '',
      sourceUri: 'content://mirrorbridge/photo/1',
      origin: MediaOrigin.manualImport,
    );
    c.local = [item];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(nativeCamera, (call) async {
      if (call.method == 'exif') {
        return <String, String>{
          'ImageWidth': '8256',
          'ImageLength': '5504',
          'Model': 'NIKON Z 8',
          'LensModel': 'NIKKOR Z 24-120mm f/4 S',
          'ExposureTime': '1/500',
          'FNumber': '4/1',
          'PhotographicSensitivity': '64',
          'FocalLength': '120/1',
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(nativeCamera, null));

    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        home: NikonMediaDetailPage(c: c, item: item, local: true),
      ),
    );
    await tester.pumpAndSettle();

    expect(item.exif['Model'], 'NIKON Z 8');
    expect(item.exif['LensModel'], 'NIKKOR Z 24-120mm f/4 S');
    expect(find.text('8256 × 5504'), findsOneWidget);
    expect(find.text('NIKKOR Z 24-120mm f/4 S'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
