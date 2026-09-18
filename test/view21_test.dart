import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirrorbridge/models/media_item.dart';
import 'package:mirrorbridge/pages/full_image_page.dart';
import 'package:mirrorbridge/protocol/ptp.dart';
import 'package:mirrorbridge/repositories/nikon_repository.dart';
import 'package:mirrorbridge/state/app_controller.dart';

class PendingView extends NikonRepository {
  int requests = 0;
  final result = Completer<String>();
  final released = <String>[];
  @override
  Future<String> prepareViewingSource(
    MediaItem item, {
    void Function(int, int)? progress,
    bool Function()? cancelled,
  }) {
    requests++;
    return result.future;
  }

  @override
  Future<void> releaseViewingSource(String path) async {
    released.add(path);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final ms = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(
    () =>
        ms.setMockMethodCallHandler(AppController.platform, (_) async => null),
  );
  for (final leaveEarly in [false, true]) {
    testWidgets('remote thumbnail, double tap and cleanup early=$leaveEarly', (
      tester,
    ) async {
      final repo = PendingView();
      final c = AppController(repo);
      final item = MediaItem(
        id: 'v',
        name: 'v.jpg',
        kind: MediaKind.jpg,
        date: DateTime(2026),
        bytes: 4,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: FullImagePage(c: c, item: item),
        ),
      );
      await tester.pumpAndSettle();
      expect(repo.requests, 0);
      expect(find.text('加载高清图'), findsOneWidget);
      final image = find.byType(InteractiveViewer);
      final center = tester.getCenter(image);
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 70));
      await tester.tapAt(center);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final intermediate = tester
          .widget<InteractiveViewer>(image)
          .transformationController!
          .value
          .getMaxScaleOnAxis();
      expect(intermediate, greaterThan(1));
      expect(intermediate, lessThan(3));
      await tester.pump(const Duration(milliseconds: 140));
      expect(
        tester
            .widget<InteractiveViewer>(image)
            .transformationController!
            .value
            .getMaxScaleOnAxis(),
        3,
      );
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 70));
      await tester.tapAt(center);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(
        tester
            .widget<InteractiveViewer>(image)
            .transformationController!
            .value
            .getMaxScaleOnAxis(),
        greaterThan(1),
      );
      await tester.pump(const Duration(milliseconds: 140));
      expect(
        tester
            .widget<InteractiveViewer>(image)
            .transformationController!
            .value
            .getMaxScaleOnAxis(),
        1,
      );
      await tester.tap(find.text('加载高清图'));
      await tester.pump();
      expect(repo.requests, 1);
      if (leaveEarly) {
        await tester.pumpWidget(const SizedBox());
      }
      repo.result.complete(File('assets/demo.png').absolute.path);
      await tester.pumpAndSettle();
      if (!leaveEarly) {
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }
      expect(repo.released, [File('assets/demo.png').absolute.path]);
      c.dispose();
    });
  }
  for (final failure in [false, true]) {
    test(
      'view session removes originals and partials, preserves local originals failure=$failure',
      () async {
        final cache = await Directory.systemTemp.createTemp('view_test_');
        final local = File('${cache.path}/local.jpg');
        await local.writeAsBytes([1, 2, 3, 4]);
        final repo = NikonRepository()
          ..transport = UsbPtpTransport()
          ..sourceIdentity = 'camera'
          ..device = PtpDeviceInfo('Nikon', 'Z8', 'fixture', {0x101b}, {});
        ms.setMockMethodCallHandler(nativeCamera, (call) async {
          if (call.method == 'directories') return {'cache': cache.path};
          if (call.method == 'usbDownload') {
            await File(
              call.arguments['path'] as String,
            ).writeAsBytes([1, 2, 3, 4]);
            if (failure) {
              throw PlatformException(code: 'TEST', message: 'interrupted');
            }
            return null;
          }
          if (call.method == 'fullImageSource') {
            final dir = call.arguments['viewDirectory'] as String;
            final file = File('$dir/preview.jpg');
            await file.writeAsBytes([4, 3, 2, 1]);
            return file.path;
          }
          return null;
        });
        final item = MediaItem(
          id: 'v',
          name: 'v.NEF',
          kind: MediaKind.raw,
          date: DateTime(2026),
          bytes: 4,
          source: 'camera',
        );
        if (failure) {
          await expectLater(
            repo.prepareViewingSource(item),
            throwsA(isA<PlatformException>()),
          );
        } else {
          final path = await repo.prepareViewingSource(item);
          expect(await File(path).exists(), true);
          await repo.releaseViewingSource(path);
          expect(await File(path).exists(), false);
        }
        expect(
          await Directory('${cache.path}/image_view_sessions').list().length,
          0,
        );
        item.localPath = local.path;
        final path = await repo.prepareViewingSource(item);
        await repo.releaseViewingSource(path);
        expect(await local.readAsBytes(), [1, 2, 3, 4]);
        await cache.delete(recursive: true);
        ms.setMockMethodCallHandler(nativeCamera, null);
      },
    );
  }
}
