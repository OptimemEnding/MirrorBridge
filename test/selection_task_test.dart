import 'dart:async';
import 'dart:convert';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirrorbridge/models/camera_storage.dart';
import 'package:mirrorbridge/models/media_item.dart';
import 'package:mirrorbridge/pages/home_page.dart';
import 'package:mirrorbridge/pages/media_page.dart';
import 'package:mirrorbridge/pages/sync_page.dart';
import 'package:mirrorbridge/repositories/demo_repository.dart';
import 'package:mirrorbridge/repositories/nikon_repository.dart';
import 'package:mirrorbridge/state/app_controller.dart';
import 'storage_filter_test.dart'
    show fixture, StoragePtp, firstCard, secondCard, settleLoading;

class ControlledTransfer extends DemoRepository {
  ControlledTransfer() : super(delay: Duration.zero);
  final started = <String>[];
  Completer<void>? pending;
  @override
  Future<void> transfer(MediaItem item, {bool fail = false}) async {
    started.add(item.id);
    pending = Completer<void>();
    await pending!.future;
  }

  @override
  Future<void> cancel() async {
    if (pending?.isCompleted == false) {
      pending!.completeError(StateError('cancelled'));
    }
  }
}

Future<AppController> demo([DemoRepository? repository]) async {
  final c = AppController(repository ?? DemoRepository(delay: Duration.zero));
  await c.connect('10.0.2.2');
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Map<String, String> saved;
  late List<String> haptics;
  setUp(() {
    saved = {};
    haptics = [];
    messenger.setMockMethodCallHandler(AppController.platform, (call) async {
      if (call.method == 'save') {
        final args = call.arguments as Map;
        saved[args['key'] as String] = args['value'] as String;
      }
      if (call.method == 'load') return saved[call.arguments];
      if (call.method == 'storageInfo') {
        return {'freeBytes': 512 * 1048576, 'totalBytes': 128 * 1073741824};
      }
      return null;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        haptics.add(call.arguments as String);
      }
      return null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(AppController.platform, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('byte units advance at 1024 through TB', () {
    expect(formatStorageBytes(0), '0 B');
    expect(formatStorageBytes(1023), '1023 B');
    expect(formatStorageBytes(1024), '1.0 KB');
    expect(formatStorageBytes(1048576), '1.0 MB');
    expect(formatStorageBytes(1073741824), '1.0 GB');
    expect(formatStorageBytes(1099511627776), '1.0 TB');
  });

  test(
    'multiple cards and multiple folders form a union within the selected cards',
    () async {
      final c = await fixture(StoragePtp());
      addTearDown(c.dispose);
      c.toggleStorage(c.cameraStorages.first);
      await settleLoading(c);
      c.toggleStorage(c.cameraStorages.last);
      expect(c.selectedStorageIds, {firstCard, secondCard});
      final a = c.cameraFolders.singleWhere((f) => f.handle == 100);
      final b = c.cameraFolders.singleWhere((f) => f.handle == 200);
      c.toggleFolder(a);
      c.toggleFolder(b);
      await settleLoading(c);
      await c.refreshMedia(more: true);
      expect(c.visibleTotal, 65);
      expect(c.visible, hasLength(65));
      c.toggleStorage(c.cameraStorages.last);
      expect(c.selectedStorageIds, {firstCard});
      expect(c.selectedFolders.values, [a]);
      expect(c.visible, hasLength(25));
      c.toggleFolder(a);
      expect(c.visibleTotal, 26);
    },
  );

  test(
    'completed count follows remaining synced media across tasks and restart',
    () async {
      final c = await demo();
      addTearDown(c.dispose);
      await c.startSync(items: c.media.take(2).toList());
      c.failNext = true;
      await c.startSync(items: c.media.skip(2).take(2).toList());
      expect(c.totalSyncCompleted, 3);
      expect(c.totalSyncFailed, 1);
      await c.retryFailed();
      expect(c.totalSyncCompleted, 4);
      expect(c.totalSyncFailed, 0);
      await c.removeSyncTask();
      expect(c.totalSyncCompleted, 4);
      await c.deleteLocal({c.local.first.id});
      expect(c.totalSyncCompleted, 3);
      await c.save();
      final restored = AppController(DemoRepository(delay: Duration.zero));
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.totalSyncCompleted, 3);
      expect(restored.totalSyncFailed, 0);
      expect(restored.local, hasLength(3));
    },
  );

  test('dashboard count includes imports and current local records', () async {
    final c = await demo();
    addTearDown(c.dispose);
    await c.startSync(items: c.media.take(1).toList());
    c.local.add(c.local.first);
    c.local.add(
      MediaItem(
        id: 'local-imported',
        name: 'imported.jpg',
        kind: MediaKind.jpg,
        date: DateTime(2026),
        bytes: 1024,
      ),
    );
    expect(c.totalSyncCompleted, 3);
    await c.deleteLocal({c.media.first.id});
    expect(c.totalSyncCompleted, 1);
  });

  test(
    'deleting active and queued file tasks continues remaining transfers',
    () async {
      final repo = ControlledTransfer();
      final c = await demo(repo);
      addTearDown(c.dispose);
      final items = c.media.take(3).toList();
      final job = c.startSync(items: items);
      await Future<void>.delayed(Duration.zero);
      expect(c.isSyncing(items.first), true);
      c.toggle(items.first);
      expect(c.selection, isEmpty);
      c.selectAllLoaded();
      expect(c.selection.contains(items.first.id), false);
      await c.removeSyncItem(items[1].id);
      await c.removeSyncItem(items.first.id);
      await Future<void>.delayed(Duration.zero);
      expect(repo.started, [items.first.id, items.last.id]);
      expect(c.isSyncing(items.last), true);
      repo.pending!.complete();
      await job;
      expect(c.local.map((m) => m.id), [items.last.id]);
      expect(c.task!.items, [items.last]);
      expect(c.totalSyncCompleted, 1);
      expect(c.totalSyncFailed, 0);
    },
  );

  test(
    'deleting an entire running task cancels it and keeps earlier completed media',
    () async {
      final repo = ControlledTransfer();
      final c = await demo(repo);
      addTearDown(c.dispose);
      final items = c.media.take(2).toList();
      final job = c.startSync(items: items);
      await Future<void>.delayed(Duration.zero);
      repo.pending!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(c.local, hasLength(1));
      await c.removeSyncTask();
      await job;
      expect(c.task!.phase, SyncPhase.completed);
      expect(c.task!.items, [items.first]);
      expect(c.syncHistory, contains(c.task));
      expect(c.local, hasLength(1));
      expect(c.totalSyncCompleted, 1);
      expect(c.totalSyncFailed, 0);
      expect(c.isSyncing(items.last), false);
    },
  );

  test(
    'all batches persist and retrying old failures preserves history',
    () async {
      final c = await demo();
      addTearDown(c.dispose);
      c.failNext = true;
      await c.startSync(items: c.media.take(2).toList());
      final failed = c.task!;
      await c.startSync(items: [c.media[2]]);
      final completed = c.task!;
      await c.removeSyncItem(completed.items.single.id, record: completed);
      await c.removeSyncTask(record: completed);
      expect(completed.items, hasLength(1));
      await c.retryFailed(record: failed);
      expect(c.task!.items.map((m) => m.id), [c.media[1].id]);
      expect(failed.failed, {c.media[1].id});
      expect(c.syncHistory, hasLength(3));
      final snapshots = c.allSyncTasks.map((t) => t.toJson()).toList();
      await c.save();
      final restored = AppController(DemoRepository(delay: Duration.zero));
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.allSyncTasks.map((t) => t.toJson()).toList(), snapshots);
      expect(restored.task!.id, c.task!.id);
      await c.deleteLocal({c.media[1].id});
      expect(c.allSyncTasks, hasLength(2));
      expect(
        c.allSyncTasks.every((t) => !t.items.any((m) => m.id == c.media[1].id)),
        true,
      );
      expect(failed.items.map((m) => m.id), [c.media[0].id]);
      await c.removeSyncTask(record: failed);
      expect(failed.items, hasLength(1));
    },
  );

  test(
    'removing failed entries preserves the completed portion of history',
    () async {
      final c = await demo();
      addTearDown(c.dispose);
      c.failNext = true;
      await c.startSync(items: c.media.take(2).toList());
      final old = c.task!;
      await c.startSync(items: [c.media[2]]);
      await c.removeSyncItem(c.media[1].id, record: old);
      expect(old.phase, SyncPhase.completed);
      expect(old.items.map((m) => m.id), [c.media[0].id]);
      expect(c.canRemoveSyncTask(old), false);
      await c.deleteLocal({c.media[0].id});
      expect(c.containsSyncTask(old), false);
      expect(c.syncHistory, [c.task]);
    },
  );

  test(
    'saved task migrates and recovers earlier surviving synchronized files',
    () async {
      final c = await demo();
      addTearDown(c.dispose);
      final items = c.media.take(3).toList();
      saved['demo'] = jsonEncode({
        'local': items.map((m) => m.toJson()).toList(),
        'task': {
          'items': [items.last.toJson()],
          'completed': [items.last.id],
          'failed': <String>[],
        },
      });
      final restored = AppController(DemoRepository(delay: Duration.zero));
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.syncHistory, hasLength(2));
      expect(
        restored.syncHistory.expand((t) => t.completed).toSet(),
        items.map((m) => m.id).toSet(),
      );
      await restored.save();
      expect(jsonDecode(saved['demo']!)['syncTasks'], hasLength(2));
    },
  );

  test(
    'interrupted tasks restore as failed history and missing completed files retain history',
    () async {
      final c = await demo();
      addTearDown(c.dispose);
      final items = c.media.take(3).toList();
      final interrupted = SyncTask(items)..phase = SyncPhase.transferring;
      interrupted.completed.add(items.first.id);
      final deleted = SyncTask([items.last])..phase = SyncPhase.completed;
      deleted.completed.add(items.last.id);
      saved['demo'] = jsonEncode({
        'local': [items.first.toJson()],
        'syncTasks': [interrupted.toJson(), deleted.toJson()],
        'lastTaskId': interrupted.id,
      });
      final restored = AppController(DemoRepository(delay: Duration.zero));
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.syncHistory, hasLength(2));
      expect(restored.syncHistory.last.missing, {items.last.id});
      expect(restored.task!.phase, SyncPhase.partialFailure);
      expect(restored.task!.completed, {items.first.id});
      expect(restored.task!.failed, {items[1].id, items[2].id});
      expect(restored.busy, false);
    },
  );

  test(
    'submission clears selection immediately, locks queued media and retains new selections',
    () async {
      final repo = ControlledTransfer();
      final c = await demo(repo);
      addTearDown(c.dispose);
      final items = c.media.take(3).toList();
      c.selection.addAll(items.take(2).map((m) => m.id));
      final job = c.startSync();
      expect(c.selection, isEmpty);
      expect(c.isSyncPending(items[0]), true);
      expect(c.isSyncPending(items[1]), true);
      c.toggle(items[1]);
      expect(c.selection, isEmpty);
      c.selectAllLoaded();
      expect(
        c.selection.intersection(items.take(2).map((m) => m.id).toSet()),
        isEmpty,
      );
      c.selection.clear();
      c.toggle(items[2]);
      await Future<void>.delayed(Duration.zero);
      await c.startSync();
      expect(c.allSyncTasks, hasLength(1));
      expect(c.selection, {items[2].id});
      await c.removeSyncItem(items[1].id);
      expect(c.isSyncPending(items[1]), false);
      repo.pending!.complete();
      await job;
      expect(c.isSyncPending(items[0]), false);
      expect(c.selection, {items[2].id});
      final next = c.startSync();
      expect(c.selection, isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(c.task!.items, [items[2]]);
      repo.pending!.complete();
      await next;
    },
  );

  testWidgets(
    'queued circles are grey and busy sync button explains the wait without losing selection',
    (tester) async {
      final repo = ControlledTransfer();
      final c = await demo(repo);
      addTearDown(c.dispose);
      c.selection.addAll(c.media.take(2).map((m) => m.id));
      final job = c.startSync();
      await tester.pump();
      c.navigate(2);
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
      await tester.pumpAndSettle();
      final queued = find.byWidgetPredicate(
        (w) => w is MediaTile && w.item.id == c.media[1].id,
      );
      expect(tester.widget<MediaTile>(queued).disabled, true);
      expect(tester.widget<MediaTile>(queued).waiting, true);
      expect(find.text('等待同步'), findsOneWidget);
      final circle = find.byKey(ValueKey('media-select-${c.media[1].id}'));
      final decoration =
          tester
                  .widgetList<Container>(
                    find.descendant(
                      of: circle,
                      matching: find.byType(Container),
                    ),
                  )
                  .single
                  .decoration!
              as BoxDecoration;
      expect(decoration.color, const Color(0xff9ca3af));
      await tester.tap(circle);
      await tester.longPress(queued);
      await tester.pump();
      expect(c.selection, isEmpty);
      await tester.tap(find.byKey(ValueKey('media-select-${c.media[2].id}')));
      await tester.pump();
      final button = find.widgetWithText(FilledButton, '同步到手机');
      final style = tester.widget<FilledButton>(button).style!;
      expect(style.backgroundColor!.resolve({}), const Color(0xffe7e7eb));
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('当前有同步任务进行中'), findsOneWidget);
      expect(find.text('请等待当前任务完成后，再同步新选中的照片。本次选择会为你保留。'), findsOneWidget);
      expect(c.selection, {c.media[2].id});
      expect(c.allSyncTasks, hasLength(1));
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      repo.pending!.complete();
      await tester.pump();
      repo.pending!.complete();
      await tester.pumpAndSettle();
      await job;
      expect(c.selection, {c.media[2].id});
      expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'byte progress refreshes the progress bar without rebuilding the task list',
    (tester) async {
      final repo = NikonRepository();
      final c = AppController(repo);
      addTearDown(c.dispose);
      await c.refreshPhoneStorage();
      final item = MediaItem(
        id: 'progress',
        name: 'progress.jpg',
        kind: MediaKind.jpg,
        date: DateTime(2026),
        bytes: 1048576,
      );
      c.task = SyncTask([item])..phase = SyncPhase.transferring;
      var builds = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: c,
              builder: (_, _) {
                builds++;
                return SyncPage(c: c);
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final initialBuilds = builds;
      final summary = tester.widget<ListTile>(
        find.byKey(ValueKey('sync-task-${c.task!.id}')),
      );
      repo.onProgress!(524288, item.bytes);
      await tester.pump();
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        .5,
      );
      expect(builds, initialBuilds);
      expect(
        identical(
          tester.widget<ListTile>(
            find.byKey(ValueKey('sync-task-${c.task!.id}')),
          ),
          summary,
        ),
        true,
      );
      expect(find.text('512.0 KB / 1.0 MB'), findsOneWidget);
      c.navigate(0);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomePage(c: c, onConnect: () {}),
          ),
        ),
      );
      await tester.pump();
      repo.onProgress!(786432, item.bytes);
      await tester.pump();
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        .75,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'large history stays scrollable and keeps its position after updates',
    (tester) async {
      final c = await demo();
      addTearDown(c.dispose);
      for (var i = 0; i < 1000; i++) {
        final record = SyncTask([c.media.first])..phase = SyncPhase.completed;
        record.completed.add(c.media.first.id);
        c.syncTasks.add(record);
      }
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: c,
              builder: (_, _) => SyncPage(c: c),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ListTile).evaluate().length, lessThan(12));
      await tester.tap(find.textContaining('历史任务 ('));
      await tester.pumpAndSettle();
      final target = find.byKey(ValueKey('sync-task-${c.syncTasks[15].id}'));
      await tester.scrollUntilVisible(target, 400);
      await tester.pumpAndSettle();
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position
          .pixels;
      c.changed();
      await tester.pump();
      expect(
        tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels,
        position,
      );
      expect(target, findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'long press vibrates once, selects a range and reverses the range',
    (tester) async {
      final c = await demo();
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
      await tester.pumpAndSettle();
      final tiles = find.byType(MediaTile);
      final gesture = await tester.startGesture(tester.getCenter(tiles.at(0)));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 30));
      expect(haptics, ['HapticFeedbackType.lightImpact']);
      expect(c.selection, {c.media.first.id});
      await gesture.moveTo(tester.getCenter(tiles.at(2)));
      await tester.pump();
      expect(c.selection, c.media.take(3).map((m) => m.id).toSet());
      await gesture.moveTo(tester.getCenter(tiles.at(1)));
      await tester.pump();
      expect(c.selection, c.media.take(2).map((m) => m.id).toSet());
      await gesture.up();
      await tester.pumpAndSettle();
      expect(haptics, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'drag selection scrolls each display frame without rebuilding controller listeners',
    (tester) async {
      final c = await demo();
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
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(MediaTile).first),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 30));
      final viewport = tester.getRect(find.byType(CustomScrollView));
      await gesture.moveTo(Offset(viewport.center.dx, viewport.bottom - 90));
      var notifications = 0;
      c.addListener(() => notifications++);
      final state = tester.state<MediaPageState>(find.byType(MediaPage));
      await tester.pump();
      for (var i = 0; i < 8; i++) {
        final before = state.scroll.offset;
        await tester.pump(const Duration(milliseconds: 8));
        expect(state.scroll.offset - before, closeTo(440 * .008, .001));
      }
      expect(notifications, 0);
      expect(state.scroll.offset, greaterThan(0));
      await gesture.up();
      await tester.pumpAndSettle();
      final offset = state.scroll.offset;
      await tester.pump(const Duration(milliseconds: 200));
      expect(state.scroll.offset, offset);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final cancel in [false, true]) {
    testWidgets(
      'drag stops on ${cancel ? 'pointer cancellation' : 'release'} after the starting tile is recycled',
      (tester) async {
        final c = await demo();
        addTearDown(c.dispose);
        c.media = List.generate(
          200,
          (i) => MediaItem(
            id: 'drag-$i',
            name: '$i.jpg',
            kind: MediaKind.jpg,
            date: DateTime(2026),
            bytes: 1024,
          ),
        );
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
        await tester.pumpAndSettle();
        final first = find.byWidgetPredicate(
          (w) => w is MediaTile && w.item.id == 'drag-0',
        );
        final gesture = await tester.startGesture(tester.getCenter(first));
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 30));
        final viewport = tester.getRect(find.byType(CustomScrollView));
        await gesture.moveTo(Offset(viewport.center.dx, viewport.bottom - 90));
        for (var i = 0; i < 100; i++) {
          await tester.pump(const Duration(milliseconds: 32));
        }
        expect(first, findsNothing);
        if (cancel) {
          await gesture.cancel();
        } else {
          await gesture.up();
        }
        final state = tester.state<MediaPageState>(find.byType(MediaPage));
        final offset = state.scroll.offset;
        final selection = Set<String>.of(c.selection);
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 32));
        }
        expect(state.scroll.offset, offset);
        expect(c.selection, selection);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'selection circle accepts taps in its 48 pixel padding without opening details',
    (tester) async {
      final c = await demo();
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
      await tester.pumpAndSettle();
      final target = find.byKey(ValueKey('media-select-${c.media.first.id}'));
      expect(tester.getSize(target), const Size(48, 48));
      final hit = tester.getTopLeft(target) + const Offset(2, 2);
      await tester.tapAt(hit);
      await tester.pumpAndSettle();
      expect(c.selection, {c.media.first.id});
      expect(find.byType(MediaPage), findsOneWidget);
      await tester.tapAt(hit);
      await tester.pumpAndSettle();
      expect(c.selection, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'active media tile ignores taps and long press while showing grey treatment',
    (tester) async {
      final repo = ControlledTransfer();
      final c = await demo(repo);
      addTearDown(c.dispose);
      final item = c.media.first;
      final job = c.startSync(items: [item]);
      await tester.pump();
      c.navigate(2);
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
      await tester.pumpAndSettle();
      final tile = find.byType(MediaTile).first;
      expect(tester.widget<MediaTile>(tile).disabled, true);
      final circle = tester
          .widgetList<Container>(
            find.descendant(
              of: find.byKey(ValueKey('media-select-${item.id}')),
              matching: find.byType(Container),
            ),
          )
          .single;
      expect(
        (circle.decoration! as BoxDecoration).color,
        const Color(0xff9ca3af),
      );
      expect(find.text('正在同步'), findsOneWidget);
      await tester.tap(tile);
      await tester.longPress(tile);
      await tester.pump();
      expect(c.selection, isEmpty);
      expect(haptics, isEmpty);
      expect(find.byType(MediaPage), findsOneWidget);
      expect(tester.takeException(), isNull);
      repo.pending!.complete();
      await tester.pumpAndSettle();
      await job;
      expect(tester.widget<MediaTile>(tile).disabled, false);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'local long press enters multi selection and slides across photos',
    (tester) async {
      final c = await demo();
      addTearDown(c.dispose);
      await c.startSync(items: c.media.take(4).toList());
      c.navigate(4);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: c,
              builder: (_, _) =>
                  MediaPage(c: c, isLocal: true, onConnect: () {}),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final tiles = find.byType(MediaTile);
      final gesture = await tester.startGesture(tester.getCenter(tiles.first));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 30));
      await gesture.moveTo(tester.getCenter(tiles.at(2)));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(c.localSelection, c.visibleLocal.take(3).map((m) => m.id).toSet());
      expect(haptics, ['HapticFeedbackType.lightImpact']);
      expect(find.text('删除'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'completed history stays behind a summary and exposes no deletion action',
    (tester) async {
      final c = await demo();
      addTearDown(c.dispose);
      await c.startSync(items: c.media.take(3).toList());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: c,
              builder: (_, _) => SyncPage(c: c),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(c.media.first.name), findsNothing);
      await tester.tap(find.textContaining('历史任务 ('));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(ValueKey('sync-task-${c.task!.id}')),
      );
      await tester.tap(find.byKey(ValueKey('sync-task-${c.task!.id}')));
      await tester.pumpAndSettle();
      expect(find.byType(SyncTaskDetailPage), findsOneWidget);
      expect(find.text(c.media.first.name), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsNothing);
      expect(find.text('移除未完成'), findsNothing);
      await c.removeSyncItem(c.media.first.id);
      await c.removeSyncTask();
      expect(c.task!.items, hasLength(3));
      expect(c.local, hasLength(3));
      expect(c.totalSyncCompleted, 3);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'active and historical batches stay separate and old details stay available',
    (tester) async {
      final repo = ControlledTransfer();
      final c = await demo(repo);
      addTearDown(c.dispose);
      final old = SyncTask([c.media.first])..phase = SyncPhase.completed;
      old.completed.add(c.media.first.id);
      c.local.add(c.media.first);
      c.task = old;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: c,
              builder: (_, _) => SyncPage(c: c),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('历史任务 ('));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('sync-task-${old.id}')));
      await tester.pumpAndSettle();
      final job = c.startSync(items: [c.media[1]]);
      await tester.pump();
      expect(find.text(c.media.first.name), findsOneWidget);
      expect(find.text('任务已移除'), findsNothing);
      expect(find.byIcon(Icons.delete_outline), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.textContaining('历史任务 ('), findsOneWidget);
      expect(find.byKey(ValueKey('sync-task-${old.id}')), findsOneWidget);
      expect(find.byKey(ValueKey('sync-task-${c.task!.id}')), findsOneWidget);
      expect(c.syncHistory, [old]);
      repo.pending!.complete();
      await tester.pumpAndSettle();
      await job;
      expect(c.syncHistory, hasLength(2));
      expect(find.text('当前没有正在同步的任务'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'home updates remaining synced count after deletion and keeps three recent files',
    (tester) async {
      final c = await demo();
      addTearDown(c.dispose);
      await c.startSync(items: c.media.take(2).toList());
      await c.startSync(items: c.media.skip(2).take(2).toList());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: c,
              builder: (_, _) => HomePage(c: c, onConnect: () {}),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('本地媒体 4 个，其中相机同步 4 个、手工导入 0 个，失败 0 个'), findsOneWidget);
      await c.deleteLocal({c.local.last.id});
      await tester.pumpAndSettle();
      expect(find.text('本地媒体 3 个，其中相机同步 3 个、手工导入 0 个，失败 0 个'), findsOneWidget);
      expect(
        find.text('${formatStorageBytes(c.syncedStorageBytes)} / 512.0 MB'),
        findsOneWidget,
      );
      await tester.drag(find.byType(ListView).first, const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(find.byType(ListTile), findsNWidgets(3));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
