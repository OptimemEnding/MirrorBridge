import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirrorbridge/models/media_item.dart';
import 'package:mirrorbridge/pages/nikon_monitor_page.dart';
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
  Completer<void>? focusGate;
  bool failFocus = false;
  bool isoAutomatic = true;
  int exposureMode = 3, isoValue = 400, manualMoves = 0, viewMode = 0;
  final writes = <(int, int)>[];
  Completer<void>? gate;
  int starts = 0, stops = 0, frames = 0;
  final focusCalls = <(int, int)>[];
  @override
  Future<double?> readLightMeter() async => -0.5;
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
      (await property(code))['current'] as int;
  @override
  Future<Map<String, dynamic>> property(int code) async {
    final iso = {0x500f, 0xd0b4, 0xd1aa}.contains(code);
    final auto = {0xd054, 0xd0ad}.contains(code);
    return {
      'code': code,
      'type': 4,
      'writable': iso ? !isoAutomatic : true,
      'current': auto
          ? (isoAutomatic ? 1 : 0)
          : iso
          ? isoValue
          : code == 0xd0b5
          ? 800
          : code == 0x500e
          ? exposureMode
          : code == 0xd1a6
          ? viewMode
          : 1,
      'values': auto
          ? [0, 1]
          : iso
          ? [100, 200, 400, 800]
          : code == 0x500e
          ? [1, 2, 3, 4]
          : [0, 1, 2, 3, 4],
    };
  }

  @override
  Future<void> setProperty(int code, int type, int value) async {
    writes.add((code, value));
    if ({0xd054, 0xd0ad}.contains(code)) isoAutomatic = value == 1;
    if ({0x500f, 0xd0b4, 0xd1aa}.contains(code)) isoValue = value;
  }

  @override
  Future<bool> focusAt(int x, int y, {bool tracking = false}) async {
    focusCalls.add((x, y));
    await focusGate?.future;
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
  final orientationCalls = <MethodCall>[];
  bool nativeRenderFailure = false;
  setUp(() async {
    await rootBundle.loadString('assets/luts.json');
    nativeCalls.clear();
    orientationCalls.clear();
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      orientationCalls.add(call);
      return null;
    });
    nativeRenderFailure = false;
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
        if (nativeRenderFailure) {
          throw PlatformException(
            code: 'CAMERA_NATIVE',
            message: 'fixture GPU error',
          );
        }
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
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
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
    for (var i = 0; i < 8; i++) {
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

  for (final mode in [0, 1]) {
    testWidgets('capture button is centered and exclusive for mode $mode', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      repo.viewMode = mode;
      await open(tester);
      final own = mode == 0 ? '拍摄到存储卡' : '开始录像';
      expect(find.byTooltip(own), findsOneWidget);
      expect(find.byTooltip(mode == 0 ? '开始录像' : '拍摄到存储卡'), findsNothing);
      expect(tester.getCenter(find.byTooltip(own)).dx, closeTo(195, .1));
      final resolution = tester.getRect(
        find.byKey(const ValueKey('monitor-resolution')),
      );
      if (mode == 0) {
        final meter = tester.getRect(
          find.byKey(const ValueKey('monitor-meter')),
        );
        expect(resolution.overlaps(meter), false);
      } else {
        expect(find.byKey(const ValueKey('monitor-meter')), findsNothing);
      }
      final battery = tester.getRect(
        find.byKey(const ValueKey('monitor-battery')),
      );
      expect(battery.right, lessThanOrEqualTo(366));
      expect(find.text('实时画面'), findsNothing);
      await close(tester);
    });
  }
  testWidgets('only monitor enables landscape and leaving restores portrait', (
    tester,
  ) async {
    await open(tester);
    expect(
      find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == '相机测光标尺',
      ),
      findsOneWidget,
    );
    expect(
      orientationCalls
          .where((c) => c.method == 'SystemChrome.setPreferredOrientations')
          .last
          .arguments,
      contains('DeviceOrientation.landscapeLeft'),
    );
    await close(tester);
    expect(
      orientationCalls
          .where((c) => c.method == 'SystemChrome.setPreferredOrientations')
          .last
          .arguments,
      ['DeviceOrientation.portraitUp'],
    );
  });
  testWidgets(
    'landscape tools expansion keeps shutter and parameters fixed and visible',
    (tester) async {
      tester.view.physicalSize = const Size(844, 390);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await open(tester);
      final shutter = tester.getRect(find.byTooltip('拍摄到存储卡'));
      final iso = tester.getRect(find.text('ISO').first);
      expect(
        orientationCalls
            .where((c) => c.method == 'SystemChrome.setEnabledSystemUIMode')
            .last
            .arguments,
        'SystemUiMode.immersiveSticky',
      );
      await tester.tap(find.text('展开'));
      await tester.pump();
      expect(tester.getRect(find.byTooltip('拍摄到存储卡')), shutter);
      expect(tester.getRect(find.text('ISO').first), iso);
      expect(shutter.bottom, lessThanOrEqualTo(390));
      expect(tester.takeException(), isNull);
      await close(tester);
      expect(
        orientationCalls
            .where((c) => c.method == 'SystemChrome.setEnabledSystemUIMode')
            .last
            .arguments,
        'SystemUiMode.edgeToEdge',
      );
    },
  );
  testWidgets('page preview while focus command is pending', (tester) async {
    await open(tester);
    repo.focusGate = Completer<void>();
    await tester.tap(find.byKey(const ValueKey('monitor-picture')));
    await tester.pump();
    final before = nativeCalls.where((c) => c.method == 'gpuSubmit').length;
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final during =
        nativeCalls.where((c) => c.method == 'gpuSubmit').length - before;
    expect(
      during,
      greaterThan(20),
      reason:
          'The page, not only repository, must keep displaying frames while busy focusing',
    );
    repo.focusGate!.complete();
    await tester.pump();
    await close(tester);
  });
  testWidgets(
    'terminal render failure is handled once without an unhandled Future',
    (tester) async {
      await open(tester);
      nativeRenderFailure = true;
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.textContaining('监看画面已中断'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(repo.stops, 1);
      await close(tester);
    },
  );
  for (final mode in [1, 2, 3, 4]) {
    testWidgets(
      'Auto ISO offers fixed values and writes Auto off before the value in exposure mode $mode',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        repo.exposureMode = mode;
        await open(tester);
        for (
          var i = 0;
          i < 30 && find.text('AUTO 800').evaluate().isEmpty;
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 70)),
          );
          await tester.pump(const Duration(milliseconds: 110));
        }
        expect(find.text('AUTO 800'), findsOneWidget);
        await tester.tap(find.text('ISO').first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('自动 ISO'), findsOneWidget);
        expect(find.byType(ListWheelScrollView), findsOneWidget);
        await tester.ensureVisible(find.text('200').last);
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.text('200').last);
        await tester.pump(const Duration(milliseconds: 400));
        expect(repo.isoValue, 200);
        expect(repo.isoAutomatic, false);
        expect(repo.writes.first, (0xd054, 0));
        await close(tester);
      },
    );
  }
  testWidgets('manual focus and removed tools have no entry', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await open(tester);
    await tester.tap(find.text('展开'));
    await tester.pump();
    expect(find.text('手动对焦'), findsNothing);
    expect(find.byType(Slider), findsNothing);
    expect(find.text('假色'), findsNothing);
    expect(find.textContaining('跟踪对焦'), findsNothing);
    await close(tester);
  });
}
