import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mirrorbridge/models/media_item.dart';
import 'package:mirrorbridge/pages/nikon_editor_page.dart';
import 'package:mirrorbridge/protocol/ptp.dart';
import 'package:mirrorbridge/repositories/nikon_repository.dart';
import 'package:mirrorbridge/state/app_controller.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'image editor exports all ten templates at source resolution',
    (tester) async {
      final dirs = (await nativeCamera.invokeMapMethod<String, dynamic>(
        'directories',
      ))!;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 3600, 2400),
        Paint()..color = const Color(0xff165571),
      );
      for (var i = 0; i < 36; i++) {
        canvas.drawLine(
          Offset(i * 100.0, 0),
          Offset(i * 100.0, 2400),
          Paint()
            ..color = Colors.white
            ..strokeWidth = 2,
        );
      }
      final label = TextPainter(
        textDirection: TextDirection.ltr,
        text: const TextSpan(
          text: 'MirrorBridge 3600 × 2400\nFull-resolution border check',
          style: TextStyle(fontSize: 96, color: Colors.white),
        ),
      )..layout();
      label.paint(canvas, const Offset(200, 600));
      final picture = recorder.endRecording();
      final image = await picture.toImage(3600, 2400);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      label.dispose();
      final source = File('${dirs['media']}/border-quality-source.png');
      final sourceBytes = data!.buffer.asUint8List();
      await source.writeAsBytes(sourceBytes);
      for (final template in nikonTemplates.keys) {
        final path = (await nativeCamera.invokeMethod<String>('effect', {
          'path': source.path,
          'template': template,
          'border': .5,
          'details': true,
        }))!;
        final codec = await ui.instantiateImageCodec(
          await File(path).readAsBytes(),
        );
        final exported = (await codec.getNextFrame()).image;
        expect(exported.width, greaterThanOrEqualTo(3600));
        expect(exported.height, greaterThanOrEqualTo(2400));
        debugPrint(
          'BORDER $template ${exported.width}x${exported.height} bytes=${await File(path).length()}',
        );
        if (template == 'clean_white') {
          final copy = await File(
            path,
          ).copy('${dirs['media']}/border-quality-classic.jpg');
          debugPrint('BORDER_REVIEW=${copy.path}');
          debugPrint(
            'BORDER_REVIEW_BASE64=${base64Encode(await copy.readAsBytes())}',
          );
        }
        exported.dispose();
        codec.dispose();
      }
      expect(await source.readAsBytes(), sourceBytes);
      await source.delete();
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  testWidgets(
    'MediaStore deletion cleans local index, bytes and persisted sync history',
    (tester) async {
      final dirs = (await nativeCamera.invokeMapMethod<String, dynamic>(
        'directories',
      ))!;
      final source = File('${dirs['media']}/border-quality-classic.jpg');
      final item = MediaItem(
        id: 'album-delete-regression',
        name: 'album-delete-regression.jpg',
        kind: MediaKind.jpg,
        date: DateTime.now(),
        bytes: await source.length(),
        asset: '',
        localPath: (await source.copy(
          '${dirs['media']}/album-delete-regression.jpg',
        )).path,
      );
      item.albumUri = (await nativeCamera.invokeMethod<String>('publish', {
        'path': item.localPath,
        'name': item.name,
      }))!;
      final c = AppController(NikonRepository());
      c.local.add(item);
      c.task = SyncTask([item])..phase = SyncPhase.completed;
      c.task!.completed.add(item.id);
      await c.save();
      expect(
        await nativeCamera.invokeMethod<bool>('localMissing', {
          'uri': item.albumUri,
        }),
        false,
      );
      // Delete only the system album entry, as a separate gallery application does.
      await nativeCamera.invokeMethod('deleteLocal', {'uri': item.albumUri});
      expect(await File(item.localPath).exists(), true);
      await c.refreshLocal();
      expect(c.local, isEmpty);
      expect(c.task, isNull);
      expect(await File(item.localPath).exists(), false);
      final restored = AppController(NikonRepository());
      await restored.load();
      expect(restored.local, isEmpty);
      expect(restored.task, isNull);
      debugPrint(
        'MEDIastore deleted -> private file removed -> count=0 -> persisted task=null',
      );
      c.dispose();
      restored.dispose();
    },
  );
}
