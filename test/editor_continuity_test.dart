import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirrorbridge/models/media_item.dart';
import 'package:mirrorbridge/pages/nikon_editor_page.dart';
import 'package:mirrorbridge/pages/settings_pages.dart';
import 'package:mirrorbridge/protocol/ptp.dart';
import 'package:mirrorbridge/repositories/nikon_repository.dart';
import 'package:mirrorbridge/state/app_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'one source and recipe survive menu changes, dragging, rotation and export',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = AppController(NikonRepository());
      addTearDown(c.dispose);
      final item = MediaItem(
        id: 'source',
        name: 'portrait.jpg',
        kind: MediaKind.jpg,
        date: DateTime(2026),
        bytes: 100,
        localPath: File('assets/demo.png').absolute.path,
      );
      final calls = <Map<String, dynamic>>[];
      final temp = Directory.systemTemp.createTempSync('mirrorbridge-export-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        AppController.platform,
        (_) async => null,
      );
      messenger.setMockMethodCallHandler(nativeCamera, (call) async {
        if (call.method == 'effect') {
          calls.add(
            Map<String, dynamic>.from(
              jsonDecode(jsonEncode(call.arguments)) as Map,
            ),
          );
          return item.localPath;
        }
        if (call.method == 'directories') {
          return {'media': temp.path, 'cache': temp.path};
        }
        if (call.method == 'publish') return 'content://mirrorbridge/export';
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(nativeCamera, null);
        messenger.setMockMethodCallHandler(AppController.platform, null);
      });
      Future<void> settle() async {
        await tester.pump(const Duration(milliseconds: 350));
        for (var attempt = 0; attempt < 12; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 60)),
          );
          await tester.pump(const Duration(milliseconds: 100));
          if (attempt > 2 &&
              find.byType(CircularProgressIndicator).evaluate().isEmpty &&
              find.text('正在导出…').evaluate().isEmpty) {
            break;
          }
        }
      }

      await tester.pumpWidget(
        MaterialApp(
          home: NikonEditorPage(c: c, item: item),
        ),
      );
      await settle();
      expect(
        calls.length,
        1,
        reason: 'Normal preview rendering must not eagerly render comparison',
      );
      expect(calls.first['captionStyles']['poster']['title'], '');
      expect(calls.first['captionStyles']['poster']['subtitle'], '');
      await tester.tap(find.text('净白留边'));
      await settle();
      await tester.tap(find.widgetWithText(NavigationDestination, '色彩'));
      await settle();
      await tester.tap(find.text('城市电影'));
      await settle();
      await tester.tap(find.widgetWithText(NavigationDestination, '文字'));
      await settle();
      await tester.tap(find.text('编辑标题与副标题'));
      await settle();
      await tester.enterText(find.widgetWithText(TextField, '主标题'), 'MY PHOTO');
      await tester.enterText(
        find.widgetWithText(TextField, '副标题'),
        'MY SUBTITLE',
      );
      tester.testTextInput.hide();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.ensureVisible(find.text('应用文字'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text('应用文字'));
      await settle();
      await settle();
      tester
          .widget<Slider>(find.byKey(const ValueKey('poster-scale')))
          .onChanged!(1.4);
      await settle();
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('poster-drag'))),
      );
      await gesture.moveBy(const Offset(25, 20));
      await tester.pump();
      await gesture.moveBy(const Offset(60, 40));
      await tester.pump();
      await gesture.up();
      await settle();
      await tester.tap(find.text('旋转'));
      await settle();
      final edited = calls.lastWhere((m) => m['lut'] == 'Cool Tone');
      final poster = edited['captionStyles']['poster'];
      expect(edited['template'], 'clean_white');
      expect(poster['title'], 'MY PHOTO');
      expect(poster['scale'], 1.4);
      expect(poster['x'], greaterThan(.06));
      expect(poster['y'], greaterThan(.07));
      expect(poster['rotation'], 1);
      final count = calls.length;
      await tester.tap(find.text('高级 EXIF 排版'));
      await settle();
      expect(
        calls.length,
        count,
        reason: 'Menu changes must not rerender or discard edits',
      );
      expect(find.byKey(const ValueKey('border-strip')), findsNothing);
      expect(find.text('LUT'), findsNothing);
      final size = tester.getSize(find.byKey(const ValueKey('editor-preview')));
      await tester.tap(find.text('对比'));
      await settle();
      expect(calls.length, count + 1);
      final comparison = calls.last;
      expect(comparison['lut'], '');
      expect(comparison['template'], '');
      expect(comparison['details'], false);
      expect(comparison['captionStyles']['poster']['enabled'], false);
      expect(comparison['captionStyles']['poster']['rotation'], 0);
      expect(
        tester.getSize(find.byKey(const ValueKey('editor-preview'))),
        size,
      );
      await tester.tap(find.text('效果'));
      await tester.pump();
      expect(calls.length, count + 1);
      await tester.ensureVisible(find.text('导出海报'));
      await tester.tap(find.text('导出海报'));
      await settle();
      final exported = calls.lastWhere((m) => !m.containsKey('maxDimension'));
      expect(exported['captionStyles']['poster'], poster);
      expect(exported['lut'], 'Cool Tone');
      expect(exported['template'], 'clean_white');
      expect(calls.every((m) => m['path'] == item.localPath), isTrue);
      expect(c.local.any((m) => m.origin == MediaOrigin.editorExport), isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('color management asks for a photograph before opening editor', (
    tester,
  ) async {
    final c = AppController(NikonRepository());
    addTearDown(c.dispose);
    await tester.pumpWidget(MaterialApp(home: ColorPage(c: c)));
    expect(find.text('选择要编辑的照片'), findsOneWidget);
    expect(find.byType(NikonEditorPage), findsNothing);
    expect(find.text('从系统相册选择'), findsOneWidget);
  });
}
