import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirrorbridge/models/media_item.dart';
import 'package:mirrorbridge/pages/media_detail_page.dart';
import 'package:mirrorbridge/repositories/nikon_repository.dart';
import 'package:mirrorbridge/state/app_controller.dart';

MediaItem media({
  required String id,
  String hash = '',
  bool verified = false,
  MediaOrigin origin = MediaOrigin.cameraSync,
}) => MediaItem(
  id: id,
  name: '$id.jpg',
  kind: MediaKind.jpg,
  date: DateTime(2026),
  bytes: 1024,
  asset: '',
  contentHash: hash,
  hashVerified: verified,
  origin: origin,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const native = MethodChannel('mirrorbridge/native');
  const storage = MethodChannel('mirrorbridge.ui/storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    messenger.setMockMethodCallHandler(storage, (call) async => null);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(native, null);
    messenger.setMockMethodCallHandler(storage, null);
  });

  test('origin and task type survive persistence', () {
    final item = media(
      id: 'manual',
      hash: 'abc',
      verified: true,
      origin: MediaOrigin.manualImport,
    )..sourceUri = 'content://phone/manual';
    final restored = MediaItem.fromJson(item.toJson());
    expect(restored.origin, MediaOrigin.manualImport);
    expect(restored.sourceUri, item.sourceUri);
    expect(restored.referenceAvailable, true);
    expect(restored.hashVerified, false);
    final task = SyncTask([item], type: SyncTaskType.manualImport)
      ..phase = SyncPhase.completed;
    task.completed.add(item.id);
    expect(SyncTask.fromJson(task.toJson()).type, SyncTaskType.manualImport);
  });

  test(
    'multi-select imports RAW and video as references and records a task',
    () async {
      messenger.setMockMethodCallHandler(native, (call) async {
        if (call.method != 'pick') return null;
        expect(call.arguments, containsPair('multiple', true));
        return [
          {
            'mediaId': 'local-nef',
            'uri': 'content://phone/1',
            'name': 'DSC_0001.NEF',
            'kind': 'raw',
            'bytes': 42000000,
            'dateMs': 1,
            'thumbnail': '/cache/raw-preview.jpg',
            'hash': 'raw-hash',
            'exif': <String, String>{'Model': 'Nikon Z 8'},
          },
          {
            'mediaId': 'local-video',
            'uri': 'content://phone/2',
            'name': 'clip.MOV',
            'kind': 'video',
            'bytes': 84000000,
            'dateMs': 2,
            'thumbnail': '/cache/video-preview.jpg',
            'hash': 'video-hash',
            'exif': <String, String>{},
          },
        ];
      });
      final controller = AppController(NikonRepository());
      addTearDown(controller.dispose);
      final imported = await controller.importMedia();
      expect(imported.map((item) => item.kind), [
        MediaKind.raw,
        MediaKind.video,
      ]);
      expect(imported.every((item) => item.localPath.isEmpty), true);
      expect(imported.map((item) => item.sourceUri), [
        'content://phone/1',
        'content://phone/2',
      ]);
      expect(controller.totalSyncCompleted, 2);
      expect(controller.task!.type, SyncTaskType.manualImport);
      expect(controller.task!.completed, {'local-nef', 'local-video'});
    },
  );

  test(
    'deleting a referenced item sends its phone URI before pruning state',
    () async {
      Map<dynamic, dynamic>? arguments;
      messenger.setMockMethodCallHandler(native, (call) async {
        if (call.method == 'deleteLocal') arguments = call.arguments as Map;
        return true;
      });
      final controller = AppController(NikonRepository());
      addTearDown(controller.dispose);
      final item = media(id: 'manual', origin: MediaOrigin.manualImport)
        ..sourceUri = 'content://phone/source';
      controller.local.add(item);
      await controller.deleteLocal({item.id}, deleteSource: true);
      expect(arguments?['sourceUri'], 'content://phone/source');
      expect(controller.local, isEmpty);
    },
  );

  testWidgets('EXIF hides XMP and does not truncate long values', (
    tester,
  ) async {
    final controller = AppController(NikonRepository());
    addTearDown(controller.dispose);
    final longValue = List.filled(30, '完整字段').join();
    final item = media(id: 'manual', origin: MediaOrigin.manualImport)
      ..sourceUri = 'content://phone/source'
      ..exif = {
        'Xmp': '<x:xmpmeta>ignored</x:xmpmeta>',
        'UserComment': longValue,
        'LensModel': 'Fixture lens',
      };
    await tester.pumpWidget(
      MaterialApp(
        home: MediaDetailPage(c: controller, item: item, isLocal: true),
      ),
    );
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.textContaining('xmpmeta'), findsNothing);
    expect(find.textContaining(longValue), findsOneWidget);
  });
}
