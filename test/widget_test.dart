import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirrorbridge/app.dart';
import 'package:mirrorbridge/pages/connection_page.dart';
import 'package:mirrorbridge/pages/media_page.dart';
import 'package:mirrorbridge/models/media_item.dart';
import 'package:mirrorbridge/repositories/camera_repository.dart';
import 'package:mirrorbridge/repositories/demo_repository.dart';
import 'package:mirrorbridge/state/app_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppController.platform, (call) async => null);
  });
  Future<void> mount(
    WidgetTester t,
    AppController c, {
    Size size = const Size(393, 851),
    double scale = 1,
  }) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    t.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(MirrorBridgeApp(controller: c));
    await t.pumpAndSettle();
  }

  testWidgets('large font five pages and settings remain usable', (t) async {
    final c = AppController(DemoRepository(delay: Duration.zero));
    await c.connect('10.0.2.2');
    await mount(t, c, size: const Size(360, 851), scale: 1.3);
    for (final label in ['首页', '我的相机', '相机照片', '同步任务', '本地媒体']) {
      await t.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text(label),
        ),
      );
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    }
  });
  testWidgets(
    'five tabs and brand dialog cancellation, Canon supported modes',
    (t) async {
      final c = AppController(UnavailableCameraRepository());
      await mount(t, c);
      for (final label in ['我的相机', '相机照片', '同步任务', '本地媒体', '首页']) {
        await t.tap(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text(label),
          ),
        );
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
      }
      await t.tap(find.text('连接相机').first);
      await t.pumpAndSettle();
      expect(find.text('选择相机品牌'), findsOneWidget);
      await t.tap(find.text('Canon'));
      await t.pumpAndSettle();
      expect(find.text('连接 Canon 相机'), findsOneWidget);
      expect(find.text('STA'), findsNothing);
      await t.pageBack();
      await t.pumpAndSettle();
      expect(find.byType(ConnectionPage), findsNothing);
    },
  );
  testWidgets('demo selection sync detail delete cancel and confirm', (
    t,
  ) async {
    final c = AppController(DemoRepository(delay: Duration.zero));
    await c.connect('10.0.2.2');
    await mount(t, c);
    final tiles = find.byType(MediaTile);
    for (var i = 0; i < 2; i++) {
      await t.tap(
        find
            .descendant(of: tiles.at(i), matching: find.byType(GestureDetector))
            .last,
      );
      await t.pump();
    }
    expect(c.selection.length, 2);
    await t.tap(find.text('同步到手机'));
    await t.pumpAndSettle();
    expect(c.task!.phase, SyncPhase.completed);
    expect(c.local.length, 2);
    await t.tap(find.text('查看照片'));
    await t.pumpAndSettle();
    await t.tap(find.byType(MediaTile).first);
    await t.pumpAndSettle();
    expect(find.text('照片详情'), findsOneWidget);
    await t.pageBack();
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('多选'));
    await t.pumpAndSettle();
    await t.tap(find.byType(MediaTile).first);
    await t.pump();
    await t.tap(find.text('删除'));
    await t.pumpAndSettle();
    await t.tap(find.text('取消'));
    await t.pumpAndSettle();
    expect(c.local.length, 2);
    await t.tap(find.text('删除'));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(TextButton, '删除'));
    await t.pumpAndSettle();
    expect(c.local.length, 1);
    expect(t.takeException(), isNull);
  });
  for (final width in [360.0, 430.0]) {
    testWidgets('layout at width $width and keyboard connection validation', (
      t,
    ) async {
      final c = AppController(UnavailableCameraRepository());
      await mount(t, c, size: Size(width, 851));
      await t.tap(find.text('连接相机').first);
      await t.pumpAndSettle();
      await t.tap(find.text('Nikon'));
      await t.pumpAndSettle();
      await t.tap(find.text('STA'));
      await t.pumpAndSettle();
      await t.scrollUntilVisible(
        find.text('手动输入 IP'),
        350,
        scrollable: find.byType(Scrollable).last,
      );
      await t.tap(find.text('手动输入 IP'));
      await t.pumpAndSettle();
      await t.ensureVisible(find.byType(TextFormField));
      await t.enterText(find.byType(TextFormField), '999.1.1.1');
      await t.ensureVisible(find.text('选择方式连接'));
      await t.tap(find.text('选择方式连接'));
      await t.pumpAndSettle();
      expect(find.text('请输入有效的 IPv4 地址'), findsOneWidget);
      expect(c.connection, ConnectionPhase.disconnected);
      expect(t.takeException(), isNull);
    });
  }
}
