import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mirrorbridge/pages/nikon_monitor_page.dart';
import 'package:mirrorbridge/protocol/ptp.dart';
import 'package:mirrorbridge/repositories/nikon_repository.dart';
import 'package:mirrorbridge/state/app_controller.dart';
import 'package:mirrorbridge/models/media_item.dart';

class MonitorImageFixture extends NikonRepository {
  MonitorImageFixture(this.jpeg) {
    device = PtpDeviceInfo(
      'Nikon',
      'Z 8 · 测试画面',
      'fixture',
      {0x9201, 0x9205, 0x9424, 0x90c1, 0x9207, 0x920a, 0x920b},
      {0x500f, 0x5007, 0x500d, 0x5010, 0x5005},
    );
  }
  final Uint8List jpeg;
  @override
  Future<void> startMonitor() async {
    monitoring = true;
  }

  @override
  Future<void> stopMonitor() async {
    monitoring = false;
  }

  @override
  Future<Uint8List?> liveFrame() async {
    await Future<void>.delayed(const Duration(milliseconds: 35));
    return jpeg;
  }

  @override
  Future<Map<String, dynamic>> property(int code) async => {
    'code': code,
    'type': 4,
    'writable': true,
    'current': switch (code) {
      0x5007 => 280,
      0x500d => 40,
      0x5010 => 0,
      0x5005 => 2,
      _ => 400,
    },
    'values': switch (code) {
      0x5007 => [180, 280, 400, 560],
      0x500d => [20, 40, 80],
      0x5010 => [-1000, 0, 1000],
      0x5005 => [2, 4, 5],
      _ => [100, 200, 400, 800],
    },
  };
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'GPU submits acknowledge display; scopes and texture ownership are verified',
    (tester) async {
      final data = (await rootBundle.load(
        'assets/demo.png',
      )).buffer.asUint8List();
      final events = <Map>[];
      final sub = const EventChannel('mirrorbridge/native_events')
          .receiveBroadcastStream()
          .listen((e) {
            if (e is Map) events.add(e);
          });
      final first = await nativeCamera.invokeMethod<int>('gpuStart');
      await tester.pumpWidget(MaterialApp(home: Texture(textureId: first!)));
      await nativeCamera.invokeMethod('gpuOptions', {
        'histogram': true,
        'waveform': true,
      });
      expect(
        await nativeCamera.invokeMethod<bool>('gpuSubmit', {'jpeg': data}),
        true,
      );
      await tester.pump();
      final frame = events.lastWhere((e) => e['type'] == 'gpuFrame');
      expect(frame['textureId'], first);
      expect(frame['histogram'], hasLength(64));
      expect(frame['waveform'], hasLength(160 * 64));
      expect(
        (frame['histogram'] as List).cast<int>().reduce((a, b) => a + b),
        greaterThan(0),
      );
      final second = await nativeCamera.invokeMethod<int>('gpuStart');
      await tester.pumpWidget(MaterialApp(home: Texture(textureId: second!)));
      await nativeCamera.invokeMethod('gpuStop', {'textureId': first});
      expect(
        await nativeCamera.invokeMethod<bool>('gpuSubmit', {'jpeg': data}),
        true,
      );
      await expectLater(
        nativeCamera.invokeMethod('gpuSubmit', {
          'jpeg': Uint8List.fromList([0, 1, 2]),
        }),
        throwsA(isA<PlatformException>()),
      );
      // Decode failure releases the busy flag and the next valid frame displays.
      expect(
        await nativeCamera.invokeMethod<bool>('gpuSubmit', {'jpeg': data}),
        true,
      );
      await nativeCamera.invokeMethod('gpuStop', {'textureId': second});
      await sub.cancel();
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'real Android monitor layout renders portrait and landscape fixture screenshots',
    (tester) async {
      final data = (await rootBundle.load(
        'assets/demo.png',
      )).buffer.asUint8List();
      final repo = MonitorImageFixture(data);
      await repo.initialize();
      final c = AppController(repo)..connection = ConnectionPhase.connected;
      c.monitorPreferences = {
        'grid': true,
        'histogram': true,
        'safeArea': true,
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => NikonMonitorPage(c: c),
                  ),
                ),
                child: const Text('打开监看'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开监看'));
      await tester.pump();
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(Texture), findsOneWidget);
      expect(tester.takeException(), isNull);
      await binding.convertFlutterSurfaceToImage();
      final dirs = (await nativeCamera.invokeMapMethod<String, dynamic>(
        'directories',
      ))!;
      await tester.pump(const Duration(milliseconds: 100));
      final portrait = await binding.takeScreenshot('monitor-portrait');
      await File(
        '${dirs['cache']}/monitor-portrait.png',
      ).writeAsBytes(portrait);
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
      ]);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 100));
      final landscape = await binding.takeScreenshot('monitor-landscape');
      await File(
        '${dirs['cache']}/monitor-landscape.png',
      ).writeAsBytes(landscape);
      debugPrint('MONITOR_SCREENSHOTS=${dirs['cache']}');
      await tester.tap(find.byTooltip('退出监看'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(repo.monitoring, false);
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      await repo.dispose();
    },
  );
}
