import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirrorbridge/models/media_item.dart';
import 'package:mirrorbridge/repositories/camera_repository.dart';
import 'package:mirrorbridge/repositories/demo_repository.dart';
import 'package:mirrorbridge/state/app_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'clearing successful task presentation preserves synchronization across restart',
    () async {
      final stored = <String, String>{};
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(AppController.platform, (call) async {
        if (call.method == 'save') {
          stored[call.arguments['key']] = call.arguments['value'];
        }
        if (call.method == 'load') return stored[call.arguments];
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(AppController.platform, null),
      );
      final c = AppController(DemoRepository(delay: Duration.zero));
      addTearDown(c.dispose);
      await c.connect('10.0.2.2');
      await c.startSync(items: c.media.take(2).toList());
      final count = c.totalSyncCompleted;
      final task = c.allSyncTasks.first;
      final completed = Set<String>.from(task.completed);
      await c.hideCompletedTasks();
      expect(c.visibleSyncTasks, isEmpty);
      expect(c.allSyncTasks, contains(task));
      expect(task.completed, completed);
      expect(c.totalSyncCompleted, count);
      expect(c.local, hasLength(2));
      final d = AppController(DemoRepository(delay: Duration.zero));
      addTearDown(d.dispose);
      await d.load();
      expect(d.visibleSyncTasks, isEmpty);
      expect(d.allSyncTasks, isNotEmpty);
      expect(d.totalSyncCompleted, count);
      expect(d.local, hasLength(2));
    },
  );
  test(
    'settings and demo local media survive restart but connection does not',
    () async {
      final stored = <String, String>{};
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AppController.platform, (call) async {
            if (call.method == 'freeBytes') {
              return 1073741824;
            }
            if (call.method == 'save') {
              final args = Map<String, dynamic>.from(call.arguments as Map);
              stored[args['key'] as String] = args['value'] as String;
              return null;
            }
            if (call.method == 'load') {
              return stored[call.arguments];
            }
            return null;
          });
      final c = AppController(DemoRepository(delay: Duration.zero));
      await c.connect('10.0.2.2');
      c.lut = 'Warm Tone';
      c.border = .4;
      await c.startSync(items: c.media.take(2).toList());
      await c.save();
      final d = AppController(DemoRepository(delay: Duration.zero));
      await d.load();
      expect(d.local.length, 2);
      expect(d.lut, 'Warm Tone');
      expect(d.border, .4);
      expect(d.recent, ['10.0.2.2']);
      expect(d.connected, false);
      final normal = AppController(UnavailableCameraRepository());
      await normal.load();
      expect(normal.local, isEmpty);
      expect(normal.lut, isEmpty);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AppController.platform, null);
    },
  );
  test(
    'unknown saved effect ids fall back to current defaults',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final saved = <String, String>{
        'demo': '''
        {
          "schemaVersion": 6,
          "lut": "unknown-lut",
          "template": "unknown-template",
          "monitorPreferences": {"lut": "unknown-lut", "lutEnabled": true}
        }
      ''',
        'normal': '''
        {
          "schemaVersion": 6,
          "lut": "/storage/emulated/0/Download/user-look.cube",
          "importedLuts": [
            "/storage/emulated/0/Download/user-look.cube",
            "/storage/emulated/0/Download/monitor.cube"
          ],
          "template": "unknown-template",
          "monitorPreferences": {"lut": "/storage/emulated/0/Download/monitor.cube", "lutEnabled": true}
        }
      ''',
      };
      messenger.setMockMethodCallHandler(AppController.platform, (call) async {
        if (call.method == 'freeBytes') return 1073741824;
        if (call.method == 'load') return saved[call.arguments];
        if (call.method == 'save') {
          final args = Map<String, dynamic>.from(call.arguments as Map);
          saved[args['key'] as String] = args['value'] as String;
        }
        return null;
      });

      final demo = AppController(DemoRepository(delay: Duration.zero));
      await demo.load();
      expect(demo.lut, isEmpty);
      expect(demo.template, 'clean_white');
      expect(demo.monitorPreferences['lut'], isEmpty);
      expect(demo.monitorPreferences['lutEnabled'], false);
      expect(demo.message, contains('当前默认值'));
      final migrated = jsonDecode(saved['demo']!) as Map<String, dynamic>;
      expect(migrated['schemaVersion'], 7);

      final normal = AppController(UnavailableCameraRepository());
      await normal.load();
      expect(normal.lut, '/storage/emulated/0/Download/user-look.cube');
      expect(normal.template, 'clean_white');
      expect(
        normal.monitorPreferences['lut'],
        '/storage/emulated/0/Download/monitor.cube',
      );
      expect(normal.monitorPreferences['lutEnabled'], true);
      messenger.setMockMethodCallHandler(AppController.platform, null);
    },
  );
  test(
    'normal repository cannot report simulated connection or transfer success',
    () async {
      final c = AppController(UnavailableCameraRepository());
      expect(await c.connect(''), false);
      expect(await c.connect('256.2.2.2'), false);
      expect(await c.connect('10.0.2.2'), false);
      expect(c.connection, ConnectionPhase.failed);
      expect(c.media, isEmpty);
    },
  );
  test(
    'filter removes hidden selections, empty selection cannot create task',
    () async {
      final c = AppController(DemoRepository(delay: Duration.zero));
      await c.connect('10.0.2.2');
      c.toggle(c.visible.first);
      c.setFilter('RAW');
      expect(c.selection, isEmpty);
      c.toggle(c.media.first);
      expect(c.selection, isEmpty);
      await c.startSync();
      expect(c.task, isNull);
      c.card = 1;
      c.folder = 'SELECTS';
      c.reconcileSelection();
      expect(
        c.visible.every((m) => m.card == 1 && m.folder == 'SELECTS'),
        true,
      );
    },
  );
  test(
    'partial failure, retry, duplicate submission, cancel and dashboard consistency',
    () async {
      final c = AppController(
        DemoRepository(delay: const Duration(milliseconds: 2)),
      );
      await c.connect('10.0.2.2');
      c.toggle(c.visible[0]);
      c.toggle(c.visible[1]);
      c.failNext = true;
      final running = c.startSync();
      await c.startSync();
      await running;
      expect(c.task!.items.length, 2);
      expect(c.task!.phase, SyncPhase.partialFailure);
      expect(c.local.length, 1);
      expect(c.task!.failed.length, 1);
      await c.retryFailed();
      expect(c.local.length, 2);
      expect(c.task!.phase, SyncPhase.completed);
      await c.deleteLocal({c.local.first.id});
      expect(c.local.length, 1);
      final cancelled = c.startSync(items: c.media.take(3).toList());
      c.cancelSync();
      await cancelled;
      expect(c.task!.phase, SyncPhase.cancelled);
      expect(c.local.length, 1);
    },
  );
  test(
    'connection and transfer completion after disposal are ignored',
    () async {
      final c = AppController(
        DemoRepository(delay: const Duration(milliseconds: 2)),
      );
      final connecting = c.connect('10.0.2.2');
      c.dispose();
      expect(await connecting, false);
      final d = AppController(
        DemoRepository(delay: const Duration(milliseconds: 2)),
      );
      await d.connect('10.0.2.2');
      final job = d.startSync(items: d.media.take(2).toList());
      d.dispose();
      await job;
      expect(d.local, isEmpty);
    },
  );
}
