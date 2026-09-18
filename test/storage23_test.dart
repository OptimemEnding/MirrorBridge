import 'dart:async';
import 'dart:convert';

import 'package:mirrorbridge/pages/full_image_page.dart';
import 'package:mirrorbridge/pages/nikon_editor_page.dart';
import 'full_image_page_test.dart' show ViewingRepository;
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirrorbridge/models/media_item.dart';
import 'package:mirrorbridge/pages/nikon_media_detail_page.dart';
import 'package:mirrorbridge/protocol/ptp.dart';
import 'package:mirrorbridge/repositories/nikon_repository.dart';
import 'package:mirrorbridge/state/app_controller.dart';

class CompletedDownload extends NikonRepository {
  @override
  Future<void> transfer(MediaItem item, {bool fail = false}) async {
    item.sourceUri = 'content://fixture/${item.id}';
    item.albumUri = item.sourceUri;
    onProgress?.call(item.bytes, item.bytes);
  }
}

MediaItem sample(String id) => MediaItem(
  id: id,
  name: '$id.JPG',
  kind: MediaKind.jpg,
  date: DateTime(2026),
  bytes: 100,
  source: 'camera',
  folder: '100NCZ_8',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    // Use the host's CJK font for readable local QA captures, when available.
    final windows = Platform.environment['WINDIR'];
    if (windows != null) {
      final font = File('$windows/Fonts/msyh.ttc');
      if (await font.exists()) {
        final loader = FontLoader('LayoutPreview')
          ..addFont(
            Future.value(ByteData.sublistView(await font.readAsBytes())),
          );
        await loader.load();
      }
    }
  });
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(nativeCamera, null));

  test(
    'progress stays at file boundary while gallery validation is pending',
    () async {
      final repo = CompletedDownload();
      final c = AppController(repo)..connection = ConnectionPhase.connected;
      final checking = Completer<void>();
      final validated = Completer<void>();
      messenger.setMockMethodCallHandler(nativeCamera, (call) async {
        if (call.method == 'referenceState') {
          if (!checking.isCompleted) {
            checking.complete();
            await validated.future;
          }
          return {'available': true, 'bytes': 100, 'location': ''};
        }
        return null;
      });
      final job = c.startSync(items: [sample('one'), sample('two')]);
      await checking.future;
      expect(c.byteProgress, .5);
      expect(c.task!.doneBytes + c.task!.currentBytes, 100);
      validated.complete();
      await job;
      expect(c.byteProgress, 1);
      expect(c.task!.completed.length, 2);
      c.dispose();
    },
  );

  for (final failureStage in [
    'usbDownload',
    'publish',
    'releasePublishedCopy',
  ]) {
    test('failed $failureStage removes its entire download session', () async {
      final root = await Directory.systemTemp.createTemp('download23');
      final media = await Directory('${root.path}/media').create();
      final cache = await Directory('${root.path}/cache').create();
      final repo = NikonRepository()
        ..transport = UsbPtpTransport()
        ..sourceIdentity = 'camera'
        ..directory = media.path
        ..device = PtpDeviceInfo('Nikon', 'Z8', 'fixture', {0x101b}, {});
      messenger.setMockMethodCallHandler(nativeCamera, (call) async {
        if (call.method == 'directories') {
          return {
            'cache': cache.path,
            'media': media.path,
            'freeBytes': 100000000,
          };
        }
        if (call.method == 'usbDownload') {
          await File(
            call.arguments['path'] as String,
          ).writeAsBytes(List.filled(100, 1));
        }
        if (call.method == failureStage) {
          throw PlatformException(code: 'FAILURE');
        }
        if (call.method == 'publish') return 'content://fixture/published';
        return null;
      });
      final item = sample('one');
      try {
        await expectLater(
          repo.transfer(item),
          throwsA(isA<PlatformException>()),
        );
        expect(await cache.list().length, 0);
        expect(await media.list().length, 0);
        expect(item.localPath, isEmpty);
      } finally {
        await root.delete(recursive: true);
      }
    });
  }

  test('cancel stops download and removes partial session', () async {
    final root = await Directory.systemTemp.createTemp('cancel23');
    final started = Completer<void>();
    final stopped = Completer<void>();
    String? disconnectReason;
    final repo = NikonRepository()
      ..transport = UsbPtpTransport()
      ..sourceIdentity = 'camera'
      ..directory = root.path
      ..device = PtpDeviceInfo('Nikon', 'Z8', 'fixture', {0x101b}, {});
    repo.onDisconnected = (reason) => disconnectReason = reason;
    messenger.setMockMethodCallHandler(nativeCamera, (call) async {
      if (call.method == 'directories') {
        return {'cache': root.path, 'media': root.path, 'freeBytes': 100000000};
      }
      if (call.method == 'usbDownload') {
        await File(call.arguments['path'] as String).writeAsBytes([1, 2]);
        started.complete();
        await stopped.future;
      }
      if (call.method == 'usbCancel') stopped.complete();
      return null;
    });
    final job = expectLater(repo.transfer(sample('one')), throwsStateError);
    await started.future;
    await repo.cancel();
    await job;
    expect(repo.transport, isNull);
    expect(disconnectReason, contains('重新连接'));
    expect(await root.list().length, 0);
    await root.delete(recursive: true);
  });

  testWidgets('gallery preview decodes URI bytes in memory', (tester) async {
    final repo = ViewingRepository();
    final c = AppController(repo);
    final item = sample('one')..sourceUri = 'content://fixture/one';
    final bytes = File('assets/demo.png').readAsBytesSync();
    messenger.setMockMethodCallHandler(nativeCamera, (call) async {
      if (call.method == 'readImageBytes') return bytes;
      return null;
    });
    await tester.pumpWidget(
      MaterialApp(
        home: FullImagePage(c: c, item: item, local: true),
      ),
    );
    repo.result.complete(item.sourceUri);
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<Image>(find.byType(Image))
          .any((v) => v.image is MemoryImage),
      isTrue,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    c.dispose();
  });

  testWidgets('caption controls reach renderer and saved recipe', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 2600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final c = AppController(NikonRepository());
    final item = sample('one')
      ..localPath = File('assets/demo.png').absolute.path;
    Map<dynamic, dynamic>? rendered;
    Map<String, dynamic>? saved;
    messenger.setMockMethodCallHandler(nativeCamera, (call) async {
      if (call.method == 'effect') {
        rendered = call.arguments as Map;
        return item.localPath;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(AppController.platform, (call) async {
      if (call.arguments is Map && call.arguments['value'] is String) {
        saved =
            jsonDecode(call.arguments['value'] as String)
                as Map<String, dynamic>;
      }
      return null;
    });
    await tester.pumpWidget(
      MaterialApp(
        home: NikonEditorPage(c: c, item: item),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.tap(find.widgetWithText(NavigationDestination, '文字'));
    await tester.pump();
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.tap(find.text('高级 EXIF 排版'));
    await tester.pump();
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.pump(const Duration(milliseconds: 350));
    tester
        .widget<Slider>(
          find.byKey(const ValueKey('caption-scale'), skipOffstage: false),
        )
        .onChanged!(1.5);
    tester
        .widget<Slider>(
          find.byKey(const ValueKey('caption-x'), skipOffstage: false),
        )
        .onChanged!(.2);
    tester
        .widget<Slider>(
          find.byKey(const ValueKey('caption-y'), skipOffstage: false),
        )
        .onChanged!(.3);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump(const Duration(milliseconds: 350));
    for (
      var i = 0;
      i < 10 && rendered!['captionStyles']['model']['scale'] != 1.5;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(rendered!['captionStyles']['model']['scale'], 1.5);
    expect(rendered!['captionStyles']['model']['x'], .2);
    expect(rendered!['captionStyles']['model']['y'], .3);
    await tester.tap(find.text('保存配方'));
    await tester.pump();
    expect(saved!['captionStyles']['model']['scale'], 1.5);
    expect(saved!['captionStyles']['model']['x'], .2);
    expect(saved!['captionStyles']['model']['y'], .3);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    messenger.setMockMethodCallHandler(AppController.platform, null);
  });

  for (final size in [
    const Size(360, 800),
    const Size(844, 390),
    const Size(600, 320),
  ]) {
    testWidgets('EXIF settings fit $size with large text', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final c = AppController(NikonRepository());
      messenger.setMockMethodCallHandler(nativeCamera, (call) async {
        if (call.method == 'effect') {
          return File('assets/demo.png').absolute.path;
        }
        return null;
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: 'LayoutPreview'),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: NikonEditorPage(c: c),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(NavigationDestination, '文字'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('高级 EXIF 排版'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('高级 EXIF 排版'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('重置此项排版'),
        250,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('editor-controls')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('重置此项排版'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重置此项排版'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('重置此项排版'),
        150,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('editor-controls')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(find.byKey(const ValueKey('editor-preview'))).top,
        greaterThanOrEqualTo(0),
      );
      if (size.width >= 680) {
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('editor-preview'))).dx,
          lessThan(
            tester.getTopLeft(find.byKey(const ValueKey('editor-controls'))).dx,
          ),
        );
      }
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  }

  testWidgets(
    'synced phone photo displays resolved gallery path instead of camera folder',
    (tester) async {
      final c = AppController(NikonRepository());
      final item = sample('one')..sourceUri = 'content://fixture/one';
      messenger.setMockMethodCallHandler(nativeCamera, (call) async {
        if (call.method == 'referencePath') {
          return '/storage/emulated/0/DCIM/MirrorBridge/one.JPG';
        }
        return null;
      });
      await tester.pumpWidget(
        MaterialApp(
          home: NikonMediaDetailPage(c: c, item: item, local: true),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      expect(
        find.text('文件路径：/storage/emulated/0/DCIM/MirrorBridge/one.JPG'),
        findsOneWidget,
      );
      expect(find.textContaining('100NCZ_8'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      c.dispose();
    },
  );
}
