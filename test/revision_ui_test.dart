import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirrorbridge/pages/media_page.dart';
import 'package:mirrorbridge/models/media_sync_state.dart';
import 'package:mirrorbridge/widgets/shared.dart';
import 'package:mirrorbridge/models/media_item.dart';
import 'package:mirrorbridge/repositories/demo_repository.dart';
import 'package:mirrorbridge/state/app_controller.dart';

void main() {
  testWidgets(
    'delete dialog defaults to records only and opts into red checked source deletion',
    (tester) async {
      bool? choice;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  choice = await confirmLocalDeletion(context, 2);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('照片和视频文件将保留。'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsNothing);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(choice, false);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('同步删除照片文件'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(find.text('照片或视频文件也将被删除，无法撤销。'), findsOneWidget);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(choice, true);
    },
  );
  testWidgets('scrolling hides selection overlay and stopping restores it', (
    tester,
  ) async {
    final c = AppController(DemoRepository(delay: Duration.zero))
      ..connection = ConnectionPhase.connected
      ..media = DemoRepository.media
      ..tab = 2;
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaPage(c: c, onConnect: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Finder overlay() => find.ancestor(
      of: find.text('同步到手机'),
      matching: find.byType(AnimatedOpacity),
    );
    expect(tester.widget<AnimatedOpacity>(overlay()).opacity, 1);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(CustomScrollView)),
    );
    await gesture.moveBy(const Offset(0, -70));
    await tester.pump(const Duration(milliseconds: 20));
    expect(tester.widget<AnimatedOpacity>(overlay()).opacity, 0);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(overlay()).opacity, 1);
    await tester.pumpWidget(const SizedBox());
  });
  test(
    'sync reveal fills downward while retaining the source image geometry',
    () {
      const clip = SyncRevealClipper(.4);
      expect(
        clip.getClip(const Size(100, 200)),
        const Rect.fromLTWH(0, 0, 100, 80),
      );
    },
  );
  testWidgets('capture media styling and source-deletion dialog', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = AppController(DemoRepository(delay: Duration.zero))
      ..connection = ConnectionPhase.connected
      ..media = DemoRepository.media
      ..tab = 2;
    addTearDown(c.dispose);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          home: Scaffold(
            appBar: AppBar(title: const Text('相机照片')),
            body: Column(
              children: [
                Expanded(
                  child: MediaPage(c: c, onConnect: () {}),
                ),
                SizedBox(
                  height: 100,
                  child: Row(
                    children: [
                      Expanded(
                        child: MediaTile(
                          item: c.media.first,
                          selected: false,
                          syncState: MediaSyncState.synced,
                          showSelection: true,
                          local: false,
                          onTap: () {},
                          onSelect: () {},
                        ),
                      ),
                      const Expanded(
                        child: Center(child: Text('同步进度自上而下恢复彩色')),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/revision-ui/media.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    await tester.pumpWidget(const SizedBox());
  });
}
