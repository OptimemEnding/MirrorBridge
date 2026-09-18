import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirrorbridge/models/media_item.dart';
import 'package:mirrorbridge/pages/media_page.dart';
import 'package:mirrorbridge/pages/nikon_media_detail_page.dart';
import 'package:mirrorbridge/pages/home_page.dart';
import 'package:mirrorbridge/repositories/demo_repository.dart';
import 'package:mirrorbridge/repositories/nikon_repository.dart';
import 'package:mirrorbridge/state/app_controller.dart';
import 'package:mirrorbridge/widgets/shared.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const native = MethodChannel('mirrorbridge/native');
  setUp(() {
    messenger.setMockMethodCallHandler(
      AppController.platform,
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(native, (_) async => null);
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(AppController.platform, null);
    messenger.setMockMethodCallHandler(native, null);
  });
  AppController demo() => AppController(DemoRepository(delay: Duration.zero))
    ..connection = ConnectionPhase.connected
    ..media = DemoRepository.media
    ..tab = 2;
  for (final local in [false, true]) {
    testWidgets(
      'enter selection retains long pressed ${local ? 'local' : 'camera'} tile',
      (tester) async {
        final c = demo();
        addTearDown(c.dispose);
        if (local) c.local.addAll(c.media);
        final ids = local ? c.localSelection : c.selection;
        ids.add(c.media.first.id);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MediaPage(c: c, isLocal: local, onConnect: () {}),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final gesture = await tester.startGesture(
          tester.getCenter(find.byType(MediaTile).first),
        );
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 30));
        expect(
          tester.state<MediaPageState>(find.byType(MediaPage)).selecting,
          true,
        );
        expect(ids, contains(c.media.first.id));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(ids, contains(c.media.first.id));
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets('filter badge appears and clears with actual filter state', (
    tester,
  ) async {
    final c = demo();
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: c,
            builder: (_, _) => MediaPage(c: c, onConnect: () {}),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('active-filter-dot')), findsNothing);
    c.setFilter('RAW');
    await tester.pump();
    expect(find.byKey(const ValueKey('active-filter-dot')), findsOneWidget);
    c.setFilter('全部');
    await tester.pump();
    expect(find.byKey(const ValueKey('active-filter-dot')), findsNothing);
    c.selectedStorageIds.add(1);
    c.changed();
    await tester.pump();
    expect(find.byKey(const ValueKey('active-filter-dot')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  for (final throws in [false, true]) {
    testWidgets('manual import without EXIF hides camera hints error=$throws', (
      tester,
    ) async {
      final c = AppController(NikonRepository());
      addTearDown(c.dispose);
      final item = MediaItem(
        id: 'local-manual',
        name: 'phone.png',
        kind: MediaKind.jpg,
        date: DateTime(2026),
        bytes: 123,
        origin: MediaOrigin.manualImport,
        sourceUri: 'content://fixture/phone',
      );
      messenger.setMockMethodCallHandler(native, (call) async {
        if (call.method == 'referencePath') {
          return '/storage/emulated/0/Pictures/phone.png';
        }
        if (call.method == 'exif') {
          if (throws) throw PlatformException(code: 'UNSUPPORTED');
          return <String, String>{};
        }
        return null;
      });
      await tester.pumpWidget(
        MaterialApp(
          home: NikonMediaDetailPage(c: c, item: item, local: true),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('拍摄参数'), findsNothing);
      expect(find.textContaining('下载相机文件后读取'), findsNothing);
      expect(find.textContaining('存储卡'), findsNothing);
      expect(find.textContaining('部分参数暂时无法读取'), findsNothing);
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      expect(
        find.text('文件路径：/storage/emulated/0/Pictures/phone.png'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets(
    'dashboard keeps camera status after manual import and counts import once',
    (tester) async {
      final c = demo()..tab = 0;
      addTearDown(c.dispose);
      final camera = c.media.first;
      final imported = MediaItem(
        id: 'local-manual',
        name: 'phone.png',
        kind: MediaKind.jpg,
        date: DateTime(2026),
        bytes: 123,
        origin: MediaOrigin.manualImport,
      );
      final sync = SyncTask([camera])
        ..phase = SyncPhase.completed
        ..completed.add(camera.id);
      final manual = SyncTask([imported], type: SyncTaskType.manualImport)
        ..phase = SyncPhase.completed
        ..completed.add(imported.id);
      c.local.addAll([camera, imported]);
      c.syncTasks.addAll([manual, sync]);
      c.task = manual;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomePage(c: c, onConnect: () {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('手工导入'), findsOneWidget);
      expect(find.textContaining('相机同步 1 个、手工导入 1 个'), findsOneWidget);
      final chip = tester.widget<StatusChip>(find.byType(StatusChip).first);
      expect(chip.label, '已完成');
      expect(find.text('100%'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
