import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mirrorbridge/protocol/ptp.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real NEF embedded JPEG survives cache clearing and native export',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('正在验证 RAW 图像处理'))),
      );
      Future<(int, int)> dimensions(String path) async {
        final codec = await ui.instantiateImageCodec(
          await File(path).readAsBytes(),
        );
        final frame = await codec.getNextFrame();
        final size = (frame.image.width, frame.image.height);
        frame.image.dispose();
        codec.dispose();
        return size;
      }

      for (final name in ['Z81_2457.NEF', 'Z81_2458.NEF']) {
        final source = '/sdcard/DCIM/MirrorBridge/$name';
        final jpeg = (await nativeCamera.invokeMethod<String>('editSource', {
          'source': source,
        }))!;
        final size = await dimensions(jpeg);
        expect(size.$1, greaterThan(1000));
        await nativeCamera.invokeMethod('clearCaches');
        expect(await File(jpeg).exists(), true);
        for (final full in [false, true]) {
          final watch = Stopwatch()..start();
          final output = (await nativeCamera.invokeMethod<String>('effect', {
            'path': jpeg,
            'exifPath': source,
            'template': 'clean_white',
            'border': .5,
            'details': true,
            'lut': full ? '' : 'Warm Tone',
            'intensity': .5,
            if (!full) 'maxDimension': 2560,
            'captionStyles': {
              'model': {
                'font': 'cursive',
                'bold': true,
                'edge': 'top',
                'scale': 2.0,
              },
              'exposure': {'font': 'serif', 'italic': true, 'y': .5},
              'time': {'font': 'monospace', 'y': .82},
            },
          }))!;
          final rendered = await dimensions(output);
          if (full) {
            final edge = ((size.$1 < size.$2 ? size.$1 : size.$2) * .105)
                .round();
            expect(rendered.$1, size.$1 + edge * 2);
            expect(rendered.$2, size.$2 + edge + (size.$1 * .15).round());
          }
          debugPrint(
            'RAW_DEVICE $name sourceJpeg=$size full=$full output=$rendered elapsedMs=${watch.elapsedMilliseconds} bytes=${await File(output).length()}',
          );
          expect(output.contains('editor_render'), true);
          await File(output).delete();
        }
        await File(jpeg).delete();
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
