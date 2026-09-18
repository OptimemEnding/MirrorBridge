import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirrorbridge/models/media_item.dart';
import 'package:mirrorbridge/pages/nikon_monitor_page.dart';
import 'package:mirrorbridge/pages/nikon_connection_page.dart';
import 'package:mirrorbridge/protocol/ptp.dart';
import 'package:mirrorbridge/repositories/nikon_repository.dart';
import 'package:mirrorbridge/state/app_controller.dart';

class MonitorFixture extends NikonRepository {
  MonitorFixture() {
    device = PtpDeviceInfo(
      'Nikon',
      'Z 8',
      'fixture',
      {0x9201, 0x9205, 0x9424, 0x90c1, 0x9207, 0x920a, 0x920b},
      {0x500f, 0x5007, 0x500d},
    );
  }
  bool failFocus = false;
  Completer<void>? gate;
  int starts = 0, stops = 0, frames = 0;
  final focusCalls = <(int, int)>[];
  @override
  Future<void> startMonitor() async {
    starts++;
    await gate?.future;
    monitoring = true;
  }

  @override
  Future<void> stopMonitor() async {
    stops++;
    monitoring = false;
  }

  @override
  Future<Uint8List?> liveFrame() async {
    frames++;
    return Uint8List.fromList([255, 216, 255, 217]);
  }

  @override
  Future<int> currentProperty(int code, int type) async =>
      code == 0xd054 || code == 0xd0ad ? 0 : 400;

  @override
  Future<Map<String, dynamic>> property(int code) async => {
    'code': code,
    'type': 4,
    'writable': true,
    'current': 400,
    'values': [100, 200, 400, 800],
  };
  @override
  Future<bool> focusAt(int x, int y, {bool tracking = false}) async {
    focusCalls.add((x, y));
    if (failFocus) throw PtpException(0x90c8, 0xa002);
    return true;
  }
}

class DiscoveryFixture extends NikonRepository {
  final finish = Completer<void>();
  int connects = 0;
  @override
  Future<List<Map<String, dynamic>>> discover(
    String mode,
    List<String> recent, {
    void Function(int, int, String)? onProgress,
    void Function(Map<String, dynamic>)? onDevice,
    bool Function()? cancelled,
  }) async {
    final device = {'deviceId': '192.168.1.2', 'name': 'Nikon Z 8'};
    onDevice?.call(device);
    await finish.future;
    return [device];
  }

  @override
  Future<List<MediaItem>> connect(
    String address, {
    dynamic commandSocket,
  }) async {
    connects++;
    return [];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late MonitorFixture repo;
  late AppController controller;
  final nativeCalls = <MethodCall>[];
  setUp(() async {
    await rootBundle.loadString('assets/luts.json');
    nativeCalls.clear();
    repo = MonitorFixture();
    controller = AppController(repo)..connection = ConnectionPhase.connected;
    messenger.setMockMethodCallHandler(
      AppController.platform,
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(nativeCamera, (call) async {
      nativeCalls.add(call);
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
  });
  tearDown(() {
    controller.dispose();
    messenger.setMockMethodCallHandler(AppController.platform, null);
    messenger.setMockMethodCallHandler(nativeCamera, null);
  });
  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => NikonMonitorPage(c: controller),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> close(WidgetTester tester) async {
    await tester.tap(find.byTooltip('退出监看'));
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  for (final size in [
    const Size(390, 844),
    const Size(844, 390),
    const Size(320, 568),
  ]) {
    testWidgets(
      'monitor viewport and capture controls fit $size with large text',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 1.6;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await open(tester);
        expect(find.byType(Texture), findsOneWidget);
        expect(find.byTooltip('拍摄到存储卡'), findsOneWidget);
        final picture = tester.getSize(
          find.byKey(const ValueKey('monitor-picture')),
        );
        expect(picture.width / picture.height, closeTo(1.5, .001));
        final expectedWidth = size.width < size.height * 1.5
            ? size.width
            : size.height * 1.5;
        expect(picture.width, lessThanOrEqualTo(expectedWidth));
        final imageRect = tester.getRect(
          find.byKey(const ValueKey('monitor-picture')),
        );
        expect(
          imageRect.overlaps(tester.getRect(find.byTooltip('拍摄到存储卡'))),
          false,
        );
        await tester.tap(find.byTooltip('隐藏控制栏'));
        await tester.pump();
        final fullscreenPicture = tester.getSize(
          find.byKey(const ValueKey('monitor-picture')),
        );
        expect(fullscreenPicture.width, closeTo(expectedWidth, .01));
        expect(fullscreenPicture.width, greaterThanOrEqualTo(picture.width));

        expect(tester.takeException(), isNull);
        await close(tester);
        expect(repo.monitoring, false);
        expect(nativeCalls.where((c) => c.method == 'gpuStop'), hasLength(1));
      },
    );
  }
  testWidgets(
    'exit during startup waits then releases camera and texture once',
    (tester) async {
      repo.gate = Completer<void>();
      await open(tester);
      expect(repo.starts, 1);
      await tester.tap(find.byTooltip('退出监看'));
      await tester.pump();
      repo.gate!.complete();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('open'), findsOneWidget);
      expect(repo.monitoring, false);
      expect(repo.frames, 0);
      expect(nativeCalls.where((c) => c.method == 'gpuStop'), hasLength(1));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
  testWidgets(
    'touch focus maps only displayed image and mirrors horizontal coordinate',
    (tester) async {
      controller.monitorPreferences = {'mirror': true};
      await open(tester);
      final picture = find.byKey(const ValueKey('monitor-picture'));
      final rect = tester.getRect(picture);
      await tester.tapAt(
        rect.topLeft + Offset(rect.width * .25, rect.height * .75),
      );
      await tester.pump();
      expect(repo.focusCalls, [(449, 299)]);
      await close(tester);
    },
  );
  testWidgets('out of focus shows a red frame without an error banner', (
    tester,
  ) async {
    repo.failFocus = true;
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('monitor-picture')));
    await tester.pump();
    expect(find.textContaining('0xa002'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            ((w.decoration as BoxDecoration).border is Border) &&
            ((w.decoration as BoxDecoration).border as Border).top.color ==
                Colors.redAccent,
      ),
      findsOneWidget,
    );
    await close(tester);
  });
  testWidgets(
    'monitor LUT selection is independent from photo editor settings',
    (tester) async {
      controller.lut = 'Warm Tone';
      controller.intensity = .8;
      await open(tester);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      await tester.tap(find.text('展开'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.text('LUT'));
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      await tester.tap(find.text('Cool Tone').last);
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      expect(controller.lut, 'Warm Tone');
      expect(controller.intensity, .8);
      expect(controller.monitorPreferences['lut'], 'Cool Tone');
      expect(nativeCalls.where((c) => c.method == 'gpuLut').last.arguments, {
        'name': 'Cool Tone',
      });
      await tester.tap(find.byTooltip('关闭设置'));
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      await close(tester);
    },
  );
  testWidgets('discovered camera can be tapped before scan future completes', (
    tester,
  ) async {
    final discovered = DiscoveryFixture();
    final c = AppController(discovered);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => NikonConnectionPage(c: c),
                ),
              ),
              child: const Text('connect'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('connect'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('扫描相机，选择后连接'));
    await tester.pump();
    expect(discovered.finish.isCompleted, false);
    expect(find.text('Nikon Z 8'), findsOneWidget);
    await tester.tap(find.text('Nikon Z 8'));
    await tester.pumpAndSettle();
    expect(discovered.connects, 1);
    discovered.finish.complete();
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await tester.pump();
  });
}
