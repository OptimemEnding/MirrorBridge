// ignore_for_file: avoid_print
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirrorbridge/models/media_item.dart';
import 'package:mirrorbridge/models/nikon_monitor_values.dart';
import 'package:mirrorbridge/pages/full_image_page.dart';
import 'package:mirrorbridge/repositories/nikon_repository.dart';
import 'package:mirrorbridge/state/app_controller.dart';

class SourceProbe extends NikonRepository {
  MediaItem? requested;
  @override
  Future<String> prepareViewingSource(
    MediaItem item, {
    void Function(int, int)? progress,
    bool Function()? cancelled,
  }) async {
    requested = item;
    return File('assets/demo.png').absolute.path;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('shutter display probe', () {
    for (final entry in [
      (0x500d, 12345),
      (0xd100, (7 << 16) | 3),
      (0xd1a8, (1 << 16) | 125),
    ]) {
      print(
        'SHUTTER ${entry.$1.toRadixString(16)} ${nikonMonitorValue(0x500d, entry.$2, propertyCode: entry.$1)}',
      );
    }
  });
  testWidgets('synced camera preview source probe', (tester) async {
    final repo = SourceProbe();
    final c = AppController(repo);
    final ms =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    ms.setMockMethodCallHandler(AppController.platform, (_) async => null);
    final camera = MediaItem(
      id: 'same',
      name: 'camera.jpg',
      kind: MediaKind.jpg,
      date: DateTime(2026),
      bytes: 4,
    );
    c.local = [
      MediaItem(
        id: 'same',
        name: 'camera.jpg',
        kind: MediaKind.jpg,
        date: DateTime(2026),
        bytes: 4,
        sourceUri: 'content://media/external/images/media/42',
        albumUri: 'content://media/external/images/media/42',
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: FullImagePage(c: c, item: camera),
      ),
    );
    await tester.pumpAndSettle();
    print(
      'VIEW request=${repo.requested != null} localSource=${repo.requested?.sourceUri ?? "none"}',
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    c.dispose();
  });
}
