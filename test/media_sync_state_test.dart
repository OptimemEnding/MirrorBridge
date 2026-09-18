import 'dart:collection';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirrorbridge/models/media_item.dart';
import 'package:mirrorbridge/models/media_sync_state.dart';
import 'package:mirrorbridge/pages/media_page.dart';
import 'package:mirrorbridge/repositories/demo_repository.dart';
import 'package:mirrorbridge/state/app_controller.dart';
import 'selection_task_test.dart' show ControlledTransfer, demo;

class CountingList<T> extends ListBase<T> {
  CountingList(this.values);
  final List<T> values;
  int reads = 0;
  @override
  int get length => values.length;
  @override
  set length(int value) => values.length = value;
  @override
  T operator [](int index) {
    reads++;
    return values[index];
  }

  @override
  void operator []=(int index, T value) => values[index] = value;
}

MediaItem photo(String id) => MediaItem(
  id: id,
  name: 'DSC_0001.JPG',
  kind: MediaKind.jpg,
  date: DateTime(2026),
  bytes: 1024,
  contentHash: 'sha256-$id',
  hashVerified: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Map<String, String> saved;
  setUp(() {
    saved = {};
    messenger.setMockMethodCallHandler(AppController.platform, (call) async {
      if (call.method == 'save') {
        final args = call.arguments as Map;
        saved[args['key'] as String] = args['value'] as String;
      }
      if (call.method == 'load') return saved[call.arguments];
      return null;
    });
  });
  tearDown(
    () => messenger.setMockMethodCallHandler(AppController.platform, null),
  );

  test(
    'local files take precedence, latest task wins, and names do not identify media',
    () {
      final a = photo('camera-a:1');
      final b = photo('camera-b:1');
      final failed = SyncTask([a, b])..phase = SyncPhase.partialFailure;
      failed.failed.addAll([a.id, b.id]);
      final cancelled = SyncTask([b])..phase = SyncPhase.cancelled;
      final index = MediaSyncIndex(local: [a], tasks: [cancelled, failed]);
      expect(index.stateFor(a), MediaSyncState.synced);
      expect(index.stateFor(b), MediaSyncState.cancelled);
      final completed = SyncTask([b])..phase = SyncPhase.completed;
      completed.completed.add(b.id);
      expect(
        MediaSyncIndex(local: [], tasks: [completed, failed]).stateFor(b),
        MediaSyncState.missing,
      );
      expect(
        MediaSyncIndex(local: [], tasks: [failed]).stateFor(b),
        MediaSyncState.failed,
      );
    },
  );

  test(
    'failure survives restart, retry turns green, deletion removes stale success and failure',
    () async {
      final c = await demo();
      addTearDown(c.dispose);
      final item = c.media.first;
      expect(c.mediaSyncState(item), MediaSyncState.unsynced);
      c.failNext = true;
      await c.startSync(items: [item]);
      expect(c.mediaSyncState(item), MediaSyncState.failed);
      await c.save();
      final restored = AppController(DemoRepository(delay: Duration.zero));
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.mediaSyncState(item), MediaSyncState.failed);
      await c.retryFailed();
      expect(c.mediaSyncState(item), MediaSyncState.synced);
      c.failNext = true;
      await c.startSync(items: [item]);
      expect(c.task!.failed, {item.id});
      expect(c.mediaSyncState(item), MediaSyncState.synced);
      await c.deleteLocal({item.id});
      expect(c.mediaSyncState(item), MediaSyncState.unsynced);
      expect(c.syncHistory, isEmpty);
      // A cumulative failure counter does not mark the current task as failed.
      expect(c.syncFailedIds, isEmpty);
    },
  );

  test(
    'queue, active transfer, cancellation and task removal replace old failure correctly',
    () async {
      final repo = ControlledTransfer();
      final c = await demo(repo);
      addTearDown(c.dispose);
      final items = c.media.take(2).toList();
      final failed = SyncTask(List.of(items))..phase = SyncPhase.partialFailure;
      failed.failed.addAll(items.map((m) => m.id));
      c.task = failed;
      expect(c.mediaSyncState(items[0]), MediaSyncState.failed);
      final job = c.startSync(items: items);
      expect(c.mediaSyncState(items[1]), MediaSyncState.queued);
      await Future<void>.delayed(Duration.zero);
      expect(c.mediaSyncState(items[0]), MediaSyncState.syncing);
      c.mediaSyncState(c.media[2]); // Warm the index while the new batch runs.
      c.cancelSync();
      await job;
      expect(c.mediaSyncState(items[0]), MediaSyncState.cancelled);
      expect(c.mediaSyncState(items[1]), MediaSyncState.cancelled);
      await c.removeSyncTask();
      expect(c.mediaSyncState(items[0]), MediaSyncState.failed);
      await c.removeSyncTask(record: failed);
      expect(c.mediaSyncState(items[0]), MediaSyncState.unsynced);
    },
  );

  test(
    'scroll and selection lookups do not rescan large local or historical collections',
    () {
      final items = List.generate(10000, (i) => photo('camera:$i'));
      final local = CountingList(items.take(5000).toList());
      final historyItems = CountingList(items);
      final history = SyncTask(historyItems)..phase = SyncPhase.partialFailure;
      history.failed.addAll(items.skip(5000).map((m) => m.id));
      final c = AppController(DemoRepository(delay: Duration.zero));
      addTearDown(c.dispose);
      c.local = local;
      c.task = history;
      expect(c.mediaSyncState(items.first), MediaSyncState.synced);
      final localReads = local.reads;
      final historyReads = historyItems.reads;
      for (var i = 0; i < 3; i++) {
        c.selection.add(items[i].id);
        c.changed();
        for (final item in items) {
          expect(
            c.mediaSyncState(item),
            int.parse(item.id.split(':').last) < 5000
                ? MediaSyncState.synced
                : MediaSyncState.failed,
          );
        }
      }
      expect(local.reads, localReads);
      expect(historyItems.reads, historyReads);
    },
  );

  testWidgets(
    'camera badges show green success and red failure and update after retry and deletion',
    (tester) async {
      final c = await demo();
      addTearDown(c.dispose);
      c.failNext = true;
      await c.startSync(items: c.media.take(2).toList());
      final failed = c.task!;
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
      Finder badge(String label) => find.descendant(
        of: find.byType(MediaTile),
        matching: find.text(label),
      );
      expect(
        tester.widget<Text>(badge('已同步')).style!.color,
        const Color(0xff86efac),
      );
      expect(
        tester.widget<Text>(badge('同步失败')).style!.color,
        const Color(0xfffca5a5),
      );
      await c.retryFailed(record: failed);
      c.navigate(2);
      await tester.pumpAndSettle();
      expect(find.text('同步失败'), findsNothing);
      expect(badge('已同步'), findsNWidgets(2));
      await c.deleteLocal({c.media.first.id});
      await tester.pumpAndSettle();
      expect(badge('已同步'), findsOneWidget);
      final first = find.byWidgetPredicate(
        (w) => w is MediaTile && w.item.id == c.media.first.id,
      );
      expect(
        tester.widget<MediaTile>(first).syncState,
        MediaSyncState.unsynced,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
