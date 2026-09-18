import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirrorbridge/app.dart';
import 'package:mirrorbridge/repositories/demo_repository.dart';
import 'package:mirrorbridge/state/app_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'green functional shell, reordered navigation, and settings fit',
    (tester) async {
      tester.view.physicalSize = const Size(393, 851);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AppController.platform, (_) async => null);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(AppController.platform, null),
      );

      final controller = AppController(DemoRepository(delay: Duration.zero));
      addTearDown(controller.dispose);
      await controller.connect('10.0.2.2');
      controller.navigate(0);
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: MirrorBridgeApp(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('首页'), findsWidgets);
      expect(find.text('Nikon Z 8'), findsOneWidget);
      expect(find.text('查看相机照片'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('我的相机'),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.tab, 1);
      expect(find.text('设备信息'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      expect(find.text('连接与同步'), findsOneWidget);
      expect(find.text('色彩管理'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('存储管理'),
        300,
        scrollable: find.byType(Scrollable).last,
        maxScrolls: 4,
      );
      expect(find.text('存储管理'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('首页'),
        ),
      );
      await tester.pumpAndSettle();

      final boundary =
          boundaryKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/ui-redesign/home.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    },
  );
}
