import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirrorbridge/models/media_item.dart';
import 'package:mirrorbridge/pages/nikon_media_detail_page.dart';
import 'package:mirrorbridge/repositories/nikon_repository.dart';
import 'package:mirrorbridge/state/app_controller.dart';

class ViewingRepository extends NikonRepository {
  int requests = 0;
  final result = Completer<String>();
  @override
  Future<String> prepareViewingSource(
    MediaItem item, {
    void Function(int, int)? progress,
    bool Function()? cancelled,
  }) {
    requests++;
    progress?.call(50, 100);
    return result.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final kind in [MediaKind.jpg, MediaKind.raw]) {
    testWidgets('preview tap opens full image route for $kind', (tester) async {
      final repo = ViewingRepository();
      final c = AppController(repo);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        AppController.platform,
        (_) async => null,
      );
      final item = MediaItem(
        id: 'fixture',
        name: 'image.jpg',
        kind: kind,
        date: DateTime(2026),
        bytes: 100,
        exif: {'Model': 'Z8'},
      );
      await tester.pumpWidget(
        MaterialApp(
          home: NikonMediaDetailPage(c: c, item: item, local: true),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('点击查看大图'));
      await tester.pumpAndSettle();
      expect(repo.requests, 1);
      expect(find.text('正在读取相机文件 50%'), findsOneWidget);
      repo.result.complete(File('assets/demo.png').absolute.path);
      await tester.pumpAndSettle();
      expect(
        find.text(kind == MediaKind.raw ? 'RAW 内嵌大图' : '全尺寸照片'),
        findsOneWidget,
      );
      for (var turn = 1; turn <= 4; turn++) {
        await tester.tap(find.byTooltip('顺时针旋转 90°'));
        await tester.pump();
        expect(
          tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns,
          turn % 4,
        );
      }
      expect(
        repo.requests,
        1,
        reason: 'Rotation must not download or modify the source again',
      );
      final viewer = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      expect(viewer.maxScale, 12);
      final images = tester.widgetList<Image>(find.byType(Image));
      expect(images.any((image) => image.image is FileImage), true);
      expect(
        item.localPath,
        isEmpty,
        reason: 'Viewing must not claim the file was synchronized',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      messenger.setMockMethodCallHandler(AppController.platform, null);
    });
  }
}
