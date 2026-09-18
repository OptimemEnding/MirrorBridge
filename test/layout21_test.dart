// ignore_for_file: avoid_print
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirrorbridge/pages/nikon_monitor_page.dart';
import 'package:mirrorbridge/state/app_controller.dart';
import 'package:mirrorbridge/protocol/ptp.dart';
import 'package:mirrorbridge/models/media_item.dart';
import 'monitor_quality_test.dart' show MonitorFixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    await rootBundle.loadString('assets/luts.json');
  });
  for (final size in [
    const Size(390, 844),
    const Size(844, 390),
    const Size(568, 320),
    const Size(320, 568),
  ]) {
    testWidgets('layout and all pickers $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = MonitorFixture()..exposureMode = 1;
      final c = AppController(repo)..connection = ConnectionPhase.connected;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final orientations = <List<dynamic>>[];
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'SystemChrome.setPreferredOrientations') {
          orientations.add(List<dynamic>.from(call.arguments as List));
        }
        return null;
      });
      messenger.setMockMethodCallHandler(
        AppController.platform,
        (_) async => null,
      );
      messenger.setMockMethodCallHandler(nativeCamera, (call) async {
        if (call.method == 'gpuStart') return 17;
        if (call.method == 'gpuSubmit') {
          repo.onGpuEvent?.call({
            'type': 'gpuFrame',
            'textureId': 17,
            'width': 600,
            'height': 400,
            'frames': repo.frames,
          });
          return true;
        }
        return null;
      });
      await tester.pumpWidget(MaterialApp(home: NikonMonitorPage(c: c)));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 80));
      });
      await tester.pump();
      final dynamic state = tester.state(find.byType(NikonMonitorPage));
      final picture = tester.getRect(
        find.byKey(const ValueKey('monitor-picture')),
      );
      final shutter = tester.getRect(find.byTooltip('拍摄到存储卡'));
      print(
        'LAYOUT $size picture=$picture shutter=$shutter overlap=${picture.overlaps(shutter)}',
      );
      expect(picture.center, Offset(size.width / 2, size.height / 2));
      await tester.ensureVisible(find.text('展开'));
      await tester.pump();
      await tester.tap(find.text('展开'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        tester.getRect(find.byKey(const ValueKey('monitor-picture'))),
        picture,
      );
      await tester.ensureVisible(find.text('收起'));
      await tester.tap(find.text('收起'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      for (final code in [
        0xd1a6,
        0x500d,
        0x5007,
        0x500f,
        0x5005,
        0x5010,
        0x500e,
        0x500a,
        0x500b,
      ]) {
        unawaited(state.editProperty(code) as Future<void>);
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.byKey(const ValueKey('monitor-popover')), findsOneWidget);
        final rect = tester.getRect(
          find.byKey(const ValueKey('monitor-popover')),
        );
        print('PICKER $size ${code.toRadixString(16)} height=${rect.height}');
        expect(rect.height, lessThanOrEqualTo(256));
        expect(find.byType(ListWheelScrollView), findsOneWidget);
        expect(
          tester.getRect(find.byKey(const ValueKey('monitor-picture'))),
          picture,
        );
        expect(rect.bottom, lessThanOrEqualTo(size.height));
        await tester.tap(find.byTooltip('关闭设置'));
        await tester.pump(const Duration(milliseconds: 400));
      }
      for (final title in ['监看设置', '监看 LUT', '监看辅助', '相机参数']) {
        unawaited(
          state.settings(
                title,
                (StateSetter refresh) => title == '监看设置'
                    ? state.monitorSettings(refresh) as Widget
                    : title == '监看 LUT'
                    ? state.lutSettings(refresh) as Widget
                    : title == '监看辅助'
                    ? state.assistSettings(refresh) as Widget
                    : state.cameraSettings(refresh) as Widget,
              )
              as Future<void>,
        );
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        print('SETTINGS $title');
        expect(find.byTooltip('关闭设置'), findsOneWidget);
        tester.view.physicalSize = Size(size.height, size.width);
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('关闭设置'));
        await tester.pump(const Duration(milliseconds: 400));
        tester.view.physicalSize = size;
        await tester.pump();
      }
      expect(find.byKey(const ValueKey('monitor-rotate')), findsOneWidget);
      expect(find.byIcon(Icons.screen_rotation), findsNothing);
      tester.view.physicalSize = const Size(390, 844);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('monitor-rotate')));
      expect(orientations.last, ['DeviceOrientation.landscapeLeft']);
      tester.view.physicalSize = const Size(844, 390);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('monitor-rotate')));
      expect(orientations.last, ['DeviceOrientation.portraitUp']);
      await tester.longPress(find.byKey(const ValueKey('monitor-rotate')));
      expect(orientations.last.length, 3);
      tester.view.physicalSize = size;
      tester.view.viewPadding = size.width > size.height
          ? const FakeViewPadding(left: 36, bottom: 12)
          : const FakeViewPadding(top: 36, bottom: 12);
      addTearDown(tester.view.resetViewPadding);
      state.setState(() {
        state.focusFailed = true;
      });
      await tester.pump();
      final message = tester.getRect(
        find.byKey(const ValueKey('monitor-message')),
      );
      final config = tester.getRect(find.byTooltip('监看设置'));
      expect(message.overlaps(config), false);
      expect(message.overlaps(tester.getRect(find.byTooltip('拍摄到存储卡'))), false);
      expect(
        tester.getRect(find.byKey(const ValueKey('monitor-picture'))).center,
        Offset(size.width / 2, size.height / 2),
      );
      state.setState(() {
        state.properties[0xd1a6] = {'current': 1};
        state.meteringEv = null;
      });
      await tester.pump();
      expect(find.byKey(const ValueKey('monitor-meter')), findsNothing);
      state.setState(() {
        state.meteringEv = 1.0;
      });
      await tester.pump();
      expect(find.byKey(const ValueKey('monitor-meter')), findsNothing);
      state.setState(() {
        state.properties[0xd1a6] = {'current': 0};
      });
      await tester.pump();
      expect(find.byKey(const ValueKey('monitor-meter')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      c.dispose();
      messenger.setMockMethodCallHandler(nativeCamera, null);
    });
  }
}
