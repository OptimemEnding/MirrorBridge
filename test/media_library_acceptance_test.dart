import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirrorbridge/models/media_item.dart';
import 'package:mirrorbridge/models/media_sync_state.dart';
import 'package:mirrorbridge/repositories/nikon_repository.dart';
import 'package:mirrorbridge/state/app_controller.dart';

MediaItem photo(String id, {MediaOrigin origin = MediaOrigin.cameraSync}) =>
    MediaItem(
      id: id,
      name: '$id.NEF',
      kind: MediaKind.raw,
      date: DateTime(2026),
      bytes: 1024,
      asset: '',
      source: 'Nikon:Z8:serial-A',
      sourceUri: 'content://fixture/$id',
      origin: origin,
      referenceLocation: 'DCIM/MirrorBridge/',
    );
SyncTask completed(MediaItem item) => SyncTask([item])
  ..phase = SyncPhase.completed
  ..completed.add(item.id);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const native = MethodChannel('mirrorbridge/native');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <String>[];
  var available = true;
  var location = 'DCIM/MirrorBridge/';
  setUp(() {
    calls.clear();
    available = true;
    location = 'DCIM/MirrorBridge/';
    messenger.setMockMethodCallHandler(
      AppController.platform,
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(native, (call) async {
      calls.add(call.method);
      if (call.method == 'referenceStates') {
        return [
          for (final _ in (call.arguments as Map)['uris'] as List)
            {'available': available, 'bytes': 1024, 'location': location},
        ];
      }
      if (call.method == 'referenceState') {
        return {'available': available, 'bytes': 1024, 'location': location};
      }
      return null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(native, null);
    messenger.setMockMethodCallHandler(AppController.platform, null);
  });
  test(
    'record identity matches without reading content',
    () {
      final saved = photo('one');
      final c = AppController(NikonRepository())
        ..local.add(saved)
        ..syncTasks.add(completed(saved));
      addTearDown(c.dispose);
      expect(
        c.mediaSyncState(MediaItem.fromJson(saved.toJson())),
        MediaSyncState.synced,
      );
      final wrongCamera = MediaItem.fromJson({
        ...saved.toJson(),
        'source': 'Nikon:Z8:serial-B',
      });
      expect(c.mediaSyncState(wrongCamera), MediaSyncState.unsynced);
      final wrongSize = MediaItem.fromJson({...saved.toJson(), 'bytes': 999});
      expect(c.mediaSyncState(wrongSize), MediaSyncState.unsynced);
      expect(calls, isEmpty);
    },
  );
  test(
    'missing moved and recovered references retain task and update all counts',
    () async {
      final saved = photo('one');
      final c = AppController(NikonRepository())
        ..local.add(saved)
        ..syncTasks.add(completed(saved));
      addTearDown(c.dispose);
      await c.refreshLocal();
      expect(c.completedCount, 1);
      available = false;
      await c.refreshLocal();
      expect(c.completedCount, 0);
      expect(c.cameraSyncCompleted, 0);
      expect(c.visibleLocal, isEmpty);
      expect(c.syncTasks.single.missing, {'one'});
      expect(c.mediaSyncState(saved), MediaSyncState.missing);
      expect(SyncTask.fromJson(c.syncTasks.single.toJson()).missing, {'one'});
      available = true;
      location = 'DCIM/Elsewhere/';
      await c.refreshLocal();
      expect(c.mediaSyncState(saved), MediaSyncState.missing);
      location = 'DCIM/MirrorBridge/';
      await c.refreshLocal();
      expect(c.completedCount, 1);
      expect(c.mediaSyncState(saved), MediaSyncState.synced);
      expect(c.syncTasks.single.missing, isEmpty);
    },
  );
  test(
    'external additions are ignored and gallery/hash calls never run',
    () async {
      final c = AppController(NikonRepository());
      addTearDown(c.dispose);
      await c.refreshLocal();
      await c.refreshLocal();
      expect(c.local, isEmpty);
      expect(c.allSyncTasks, isEmpty);
      expect(calls, isNot(contains('listAlbum')));
      expect(calls, isNot(contains('sha256')));
    },
  );
  test(
    'default deletion removes records without asking provider to delete source media',
    () async {
      final saved = photo('one');
      final c = AppController(NikonRepository())
        ..local.add(saved)
        ..syncTasks.add(completed(saved));
      addTearDown(c.dispose);
      await c.deleteLocal({'one'});
      expect(c.local, isEmpty);
      expect(c.allSyncTasks, isEmpty);
      expect(calls, isNot(contains('deleteLocal')));
      await c.refreshLocal();
      expect(c.local, isEmpty);
    },
  );
  test(
    'source deletion cancellation retains file record and completed task',
    () async {
      final saved = photo('one');
      final c = AppController(NikonRepository())
        ..local.add(saved)
        ..syncTasks.add(completed(saved));
      addTearDown(c.dispose);
      messenger.setMockMethodCallHandler(native, (call) async {
        if (call.method == 'deleteLocal') {
          throw PlatformException(code: 'CANCELLED', message: 'User cancelled');
        }
        return null;
      });
      await c.deleteLocal({'one'}, deleteSource: true);
      expect(c.completedCount, 1);
      expect(c.allSyncTasks, hasLength(1));
      expect(c.message, contains('已取消操作'));
    },
  );
  test(
    '3000 known references use one bridge call; ordinary tab changes do not scan',
    () async {
      final c = AppController(NikonRepository());
      addTearDown(c.dispose);
      c.local.addAll(List.generate(3000, (i) => photo('$i')));
      await c.refreshLocal();
      expect(calls.where((m) => m == 'referenceStates'), hasLength(1));
      c.navigate(0);
      c.navigate(3);
      c.navigate(4);
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((m) => m == 'referenceStates'), hasLength(1));
      expect(c.completedCount, 3000);
    },
  );
  test(
    'manual import during transfer preserves the active camera task',
    () async {
      final c = AppController(NikonRepository());
      addTearDown(c.dispose);
      final active = SyncTask([photo('camera')])
        ..phase = SyncPhase.transferring;
      c.task = active;
      messenger.setMockMethodCallHandler(
        native,
        (call) async => call.method == 'pick'
            ? [
                {
                  'mediaId': 'manual',
                  'uri': 'content://fixture/manual',
                  'name': 'a.png',
                  'kind': 'jpg',
                  'bytes': 1024,
                  'dateMs': 1,
                },
              ]
            : null,
      );
      await c.importMedia();
      expect(c.task, same(active));
      expect(c.busy, true);
      expect(c.local.single.origin, MediaOrigin.manualImport);
      expect(c.syncHistory.single.type, SyncTaskType.manualImport);
    },
  );
}
