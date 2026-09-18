import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirrorbridge/models/media_item.dart';
import 'package:mirrorbridge/repositories/demo_repository.dart';
import 'package:mirrorbridge/state/app_controller.dart';
import 'package:mirrorbridge/pages/settings_pages.dart';

MediaItem photo(String id, {bool available = true}) => MediaItem(
  id: id,
  name: '$id.jpg',
  kind: MediaKind.jpg,
  date: DateTime(2026, 1, 1),
  bytes: 1024,
  referenceAvailable: available,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'clearing completed and missing records removes unavailable media everywhere',
    () async {
      final controller = AppController(DemoRepository(delay: Duration.zero));
      addTearDown(controller.dispose);
      final valid = photo('valid');
      final missing = photo('missing', available: false);
      final record = SyncTask([valid, missing])..phase = SyncPhase.completed;
      record.completed.addAll({valid.id, missing.id});
      record.missing.add(missing.id);
      controller
        ..local = [valid, missing]
        ..syncTasks.add(record)
        ..favorites.add(missing.id)
        ..syncCompletedIds.add(missing.id)
        ..syncFailedIds.add(missing.id);

      expect(controller.hasClearableCompletedOrMissingRecords, isTrue);
      await controller.clearCompletedAndMissingRecords();

      expect(controller.local.map((item) => item.id), [valid.id]);
      expect(record.items.map((item) => item.id), [valid.id]);
      expect(record.missing, isEmpty);
      expect(controller.visibleLocal.map((item) => item.id), [valid.id]);
      expect(controller.visibleSyncTasks, isEmpty);
      expect(controller.favorites, isEmpty);
      expect(controller.syncCompletedIds, isEmpty);
      expect(controller.syncFailedIds, isEmpty);
      expect(controller.hasClearableCompletedOrMissingRecords, isFalse);
    },
  );

  testWidgets('color management never offers an unavailable local photo', (
    tester,
  ) async {
    final controller = AppController(DemoRepository(delay: Duration.zero));
    addTearDown(controller.dispose);
    controller.local = [
      photo('available'),
      photo('unavailable', available: false),
    ];

    await tester.pumpWidget(MaterialApp(home: ColorPage(c: controller)));

    expect(find.text('available.jpg'), findsOneWidget);
    expect(find.text('unavailable.jpg'), findsNothing);
    expect(find.text('LUT 管理'), findsOneWidget);
  });
}
