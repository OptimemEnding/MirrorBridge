import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mirrorbridge/protocol/ptp.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native continuous frames and scope modes have bounded work',
    (tester) async {
      final asset = await rootBundle.load('assets/demo.png');
      final codec = await ui.instantiateImageCodec(
        asset.buffer.asUint8List(),
        targetWidth: 1024,
        targetHeight: 680,
      );
      final frame = await codec.getNextFrame();
      final bytes = (await frame.image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
      frame.image.dispose();
      codec.dispose();
      final events = <Map<dynamic, dynamic>>[];
      final subscription = const EventChannel('mirrorbridge/native_events')
          .receiveBroadcastStream()
          .listen((event) {
            if (event is Map) events.add(event);
          });
      final id = (await nativeCamera.invokeMethod<int>('gpuStart'))!;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: Texture(textureId: id)),
        ),
      );
      try {
        for (final mode in ['none', 'histogram', 'waveform']) {
          await nativeCamera.invokeMethod('gpuOptions', {
            'histogram': mode == 'histogram',
            'waveform': mode == 'waveform',
          });
          events.clear();
          final latencies = <int>[];
          final total = Stopwatch()..start();
          for (var i = 0; i < 120; i++) {
            final tick = Stopwatch()..start();
            expect(
              await nativeCamera.invokeMethod<bool>('gpuSubmit', {
                'jpeg': bytes,
              }),
              true,
            );
            latencies.add(tick.elapsedMicroseconds);
            await tester.pump(const Duration(milliseconds: 1));
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          await Future<void>.delayed(const Duration(milliseconds: 200));
          final elapsed = total.elapsedMilliseconds;
          final rendered = events
              .where((e) => e['type'] == 'gpuFrame')
              .toList();
          expect(events.where((e) => e['type'] == 'gpuError'), isEmpty);
          expect(rendered.length, 120);
          final samples = rendered
              .where(
                (e) =>
                    e.containsKey('histogramRgb') || e.containsKey('waveform'),
              )
              .toList();
          if (mode == 'none') {
            expect(samples, isEmpty);
          } else {
            expect(samples, isNotEmpty);
          }
          if (mode == 'histogram') {
            expect(samples.every((e) => !e.containsKey('waveform')), true);
            expect((samples.first['histogramRgb'] as List).length, 3);
          }
          if (mode == 'waveform') {
            expect(samples.every((e) => !e.containsKey('histogramRgb')), true);
            expect((samples.first['waveform'] as List).length, 160 * 64);
          }
          expect(samples.length, lessThanOrEqualTo(elapsed ~/ 200 + 2));
          latencies.sort();
          debugPrint(
            'UI25_PERF mode=$mode frames=${rendered.length} elapsedMs=$elapsed submitMedianUs=${latencies[60]} submitP95Us=${latencies[114]} scopeSamples=${samples.length}',
          );
        }
      } finally {
        await nativeCamera.invokeMethod('gpuStop');
        await subscription.cancel();
        await tester.pumpWidget(const SizedBox());
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
