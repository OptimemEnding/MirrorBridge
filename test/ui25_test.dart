import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirrorbridge/models/media_item.dart';
import 'package:mirrorbridge/pages/nikon_media_detail_page.dart';
import 'package:mirrorbridge/pages/full_image_page.dart';
import 'package:mirrorbridge/pages/nikon_monitor_page.dart';
import 'package:mirrorbridge/pages/nikon_camera_page.dart';
import 'package:mirrorbridge/protocol/ptp.dart';
import 'package:mirrorbridge/state/app_controller.dart';
import 'package:mirrorbridge/widgets/media_image.dart';
import 'monitor_quality_test.dart' show MonitorFixture;
import 'view21_test.dart' show PendingView;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() {
    messenger.setMockMethodCallHandler(
      AppController.platform,
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (_) async => null,
    );
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(AppController.platform, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    messenger.setMockMethodCallHandler(nativeCamera, null);
  });
  testWidgets('camera connected indicator only appears after connection', (
    tester,
  ) async {
    final c = AppController(MonitorFixture());
    Future<void> show() => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NikonCameraPage(c: c, onConnect: () {}),
        ),
      ),
    );
    await show();
    expect(
      find.byKey(const ValueKey('camera-connected-indicator')),
      findsNothing,
    );
    c.connection = ConnectionPhase.connected;
    await show();
    expect(
      find.byKey(const ValueKey('camera-connected-indicator')),
      findsOneWidget,
    );
    c.connection = ConnectionPhase.disconnected;
    await show();
    expect(
      find.byKey(const ValueKey('camera-connected-indicator')),
      findsNothing,
    );
    c.dispose();
  });
  testWidgets(
    'return from local detail and full image preserves every thumbnail',
    (tester) async {
      final source = File('assets/demo.png').absolute.path;
      final repo = PendingView()..result.complete(source);
      final c = AppController(repo);
      final items = List.generate(
        3,
        (i) => MediaItem(
          id: 'photo-$i',
          name: 'photo-$i.jpg',
          kind: MediaKind.jpg,
          date: DateTime(2026),
          bytes: 12,
          asset: '',
          localPath: source,
          thumbnailPath: source,
          exif: {'Model': 'Z 8'},
        ),
      );
      c.local.addAll(items);
      var clears = 0;
      messenger.setMockMethodCallHandler(nativeCamera, (call) async {
        if (call.method == 'clearCaches') clears++;
        return null;
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Column(
                children: [
                  Row(
                    children: [
                      for (final item in items)
                        MediaImage(
                          item: item,
                          controller: c,
                          width: 80,
                          height: 80,
                        ),
                    ],
                  ),
                  TextButton(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => NikonMediaDetailPage(
                          c: c,
                          item: items.first,
                          local: true,
                        ),
                      ),
                    ),
                    child: const Text('open detail'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      final thumbnail = tester.widget<Image>(
        find.descendant(
          of: find.byType(MediaImage).first,
          matching: find.byType(Image),
        ),
      );
      final thumbnailKey = await tester.runAsync(
        () => thumbnail.image.obtainKey(ImageConfiguration.empty),
      );
      expect(
        PaintingBinding.instance.imageCache.containsKey(thumbnailKey!),
        true,
      );
      await tester.tap(find.text('open detail'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(MediaImage).last);
      await tester.pumpAndSettle();
      expect(find.byType(FullImagePage), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(clears, 0);
      expect(items.map((e) => e.thumbnailPath), everyElement(source));
      expect(
        PaintingBinding.instance.imageCache.containsKey(thumbnailKey),
        true,
      );
      expect(repo.released, [source]);
      expect(File(source).existsSync(), true);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );

  testWidgets(
    'scopes drag independently, persist by orientation, and remain reachable',
    (tester) async {
      tester.view.physicalSize = const Size(844, 390);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = MonitorFixture();
      final c = AppController(repo)..connection = ConnectionPhase.connected;
      c.monitorPreferences = {'histogram': true};
      final saves = <String>[];
      messenger.setMockMethodCallHandler(AppController.platform, (call) async {
        if (call.method == 'save') saves.add(call.arguments.toString());
        return null;
      });
      messenger.setMockMethodCallHandler(nativeCamera, (call) async {
        if (call.method == 'gpuStart') return 17;
        if (call.method == 'gpuSubmit') {
          repo.onGpuEvent?.call({
            'type': 'gpuFrame',
            'textureId': 17,
            'width': 600,
            'height': 400,
            'frames': repo.frames,
          });
          return true;
        }
        return null;
      });
      Future<void> open() async {
        await tester.pumpWidget(MaterialApp(home: NikonMonitorPage(c: c)));
        for (var i = 0; i < 15; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await open();
      expect(find.text('自动对焦'), findsNothing);
      final scope = find.byKey(const ValueKey('monitor-histogram'));
      final headerBefore = tester.widget(
        find.byKey(const ValueKey('monitor-rotate')),
      );
      repo.onGpuEvent?.call({
        'type': 'gpuFrame',
        'textureId': 17,
        'width': 600,
        'height': 400,
        'histogramRgb': List.generate(3, (_) => List.filled(256, 1)),
      });
      await tester.pump();
      expect(
        identical(
          tester.widget(find.byKey(const ValueKey('monitor-rotate'))),
          headerBefore,
        ),
        true,
        reason: 'scope updates must not rebuild the monitor header',
      );
      final dynamic meterState = tester.state(find.byType(NikonMonitorPage));
      meterState.setState(() {
        meterState.meteringEv = null;
      });
      await tester.pump();
      final meterPaint = tester
          .widgetList<CustomPaint>(
            find.descendant(
              of: find.byKey(const ValueKey('monitor-meter')),
              matching: find.byType(CustomPaint),
            ),
          )
          .firstWhere(
            (widget) => widget.painter.runtimeType.toString() == '_MeterScale',
          );
      expect((meterPaint.painter as dynamic).ev, 0);
      expect(find.text('暂无测光读数'), findsNothing);
      final initialRect = tester.getRect(scope);
      await tester.drag(scope, const Offset(-170, 85));
      await tester.pump();
      final moved = tester.getRect(scope);
      expect(moved.left, lessThan(initialRect.left));
      expect(moved.top, greaterThan(initialRect.top));
      expect(repo.focusCalls, isEmpty);
      expect(
        c.monitorPreferences['scopePositions'],
        contains('histogram-landscape'),
      );
      expect(saves.any((s) => s.contains('scopePositions')), true);
      final savedLandscape =
          c.monitorPreferences['scopePositions']['histogram-landscape'];
      final dynamic state = tester.state(find.byType(NikonMonitorPage));
      state.setState(() {
        state.histogram = false;
        state.waveform = true;
      });
      await tester.pump();
      await tester.drag(
        find.byKey(const ValueKey('monitor-waveform')),
        const Offset(-80, 45),
      );
      await tester.pump();
      expect(
        c.monitorPreferences['scopePositions'],
        contains('waveform-landscape'),
      );
      expect(
        c.monitorPreferences['scopePositions']['histogram-landscape'],
        savedLandscape,
      );
      state.setState(() {
        state.histogram = true;
        state.waveform = false;
      });
      await tester.pump();
      expect(tester.getRect(scope), moved);
      tester.view.physicalSize = const Size(390, 844);
      await tester.pump();
      await tester.drag(scope, const Offset(-90, 180));
      await tester.pump();
      final portrait = tester.getRect(scope);
      expect(
        c.monitorPreferences['scopePositions'],
        contains('histogram-portrait'),
      );
      await tester.drag(scope, const Offset(-2000, -2000));
      await tester.pump();
      expect(tester.getRect(scope).left, greaterThanOrEqualTo(12));
      expect(tester.getRect(scope).top, greaterThanOrEqualTo(112));
      expect(portrait.bottom, lessThan(844));
      tester.view.physicalSize = const Size(844, 390);
      await tester.pump();
      expect(tester.getRect(scope), moved);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      await open();
      expect(tester.getRect(scope), moved);
      final dynamic reopened = tester.state(find.byType(NikonMonitorPage));
      for (final size in [
        const Size(844, 390),
        const Size(568, 320),
        const Size(390, 844),
        const Size(320, 568),
      ]) {
        tester.view.physicalSize = size;
        for (final side in [false, true]) {
          reopened.setState(() {
            reopened.meterOnRight = side;
            reopened.focusFailed = true;
            reopened.toolsExpanded = true;
          });
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 220));
          await tester.drag(scope, const Offset(-2000, -2000));
          await tester.pump();
          final chart = tester.getRect(scope);
          final meter = tester.getRect(
            find.byKey(const ValueKey('monitor-meter')),
          );
          final notice = tester.getRect(
            find.byKey(const ValueKey('monitor-message')),
          );
          expect(
            chart.overlaps(meter),
            false,
            reason: 'chart / meter $size side=$side',
          );
          expect(
            chart.overlaps(notice),
            false,
            reason: 'chart / notice $size side=$side',
          );
          expect(
            meter.overlaps(notice),
            false,
            reason: 'meter / notice $size side=$side',
          );
          expect(
            chart.overlaps(tester.getRect(find.byTooltip('拍摄到存储卡'))),
            false,
          );
          expect(chart.bottom, lessThanOrEqualTo(size.height));
        }
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      c.dispose();
    },
  );
}
