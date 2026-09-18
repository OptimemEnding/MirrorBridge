import 'package:flutter/services.dart';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter/material.dart';
import 'package:mirrorbridge/app.dart';
import 'package:mirrorbridge/models/media_item.dart';
import 'package:mirrorbridge/repositories/nikon_repository.dart';
import 'package:mirrorbridge/state/app_controller.dart';
import 'package:mirrorbridge/pages/nikon_editor_page.dart';
import 'package:mirrorbridge/protocol/ptp.dart';
import '../test/ptp_test.dart' show CameraPeer;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'project components export all 8 LUT and 10 watermark variants',
    (tester) async {
      const channel = MethodChannel('mirrorbridge/native');
      final result = await channel.invokeMapMethod<String, dynamic>(
        'nativeSelfTest',
      );
      expect(result?['success'], true);
      expect(result?['lutCount'], 8);
      expect(result?['watermarks'], hasLength(10));
      final protocol = Map<String, dynamic>.from(result!['protocol'] as Map);
      expect(protocol['openSession'], '10000000010002100100000001000000');
      expect(protocol['getStorageIds'], '0c0000000100041002000000');
      debugPrint('USB_PTP_PROTOCOL=$protocol');
      final devices = await channel.invokeListMethod<dynamic>('usbList');
      expect(devices, isA<List<dynamic>>());
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
  testWidgets('GPU monitor submits real frames with LUT and overlays', (
    tester,
  ) async {
    const channel = MethodChannel('mirrorbridge/native');
    final dirs = (await channel.invokeMapMethod<String, dynamic>(
      'directories',
    ))!;
    final bytes = await File(
      '${dirs['cache']}/native-test-source.jpg',
    ).readAsBytes();
    final seen = <Map<dynamic, dynamic>>[];
    final stream = const EventChannel('mirrorbridge/native_events')
        .receiveBroadcastStream()
        .listen((e) {
          if (e is Map) seen.add(e);
        });
    final id = await channel.invokeMethod<int>('gpuStart');
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(width: 96, height: 64, child: Texture(textureId: id!)),
      ),
    );
    for (final options in [
      <String, dynamic>{},
      {'falseColor': true, 'zebra': true, 'peaking': true, 'mirror': true},
      {'lut': true, 'intensity': .5},
    ]) {
      if (options['lut'] == true) {
        await channel.invokeMethod('gpuLut', {'name': 'Warm Tone'});
      }
      await channel.invokeMethod('gpuOptions', options);
      final before = seen.where((e) => e['type'] == 'gpuFrame').length;
      await channel.invokeMethod('gpuSubmit', {'jpeg': bytes});
      for (
        var i = 0;
        i < 50 &&
            seen.where((e) => e['type'] == 'gpuFrame').length == before &&
            !seen.any((e) => e['type'] == 'gpuError');
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
      expect(seen.where((e) => e['type'] == 'gpuError'), isEmpty);
      expect(seen.where((e) => e['type'] == 'gpuFrame').length, before + 1);
    }
    expect(seen.last['width'], 96);
    expect(seen.last['height'], 64);
    await channel.invokeMethod('gpuStop');
    await stream.cancel();
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'production Nikon routes and idempotent real MediaStore publication',
    (tester) async {
      const channel = MethodChannel('mirrorbridge/native');
      final directories = (await channel.invokeMapMethod<String, dynamic>(
        'directories',
      ))!;
      final source = File('${directories['cache']}/native-test-source.jpg');
      final copied = await source.copy(
        '${directories['media']}/integration-source.jpg',
      );
      final imported = {'path': copied.path, 'bytes': await copied.length()};
      final path = copied.path;
      final first = await channel.invokeMethod<String>('publish', {
        'path': path,
        'name': 'MirrorBridge-integration.jpg',
      });
      final second = await channel.invokeMethod<String>('publish', {
        'path': path,
        'name': 'MirrorBridge-integration.jpg',
      });
      expect(second, first);
      expect(
        await channel.invokeMethod<int>('mediaExists', {'uri': first}),
        imported['bytes'],
      );
      final controller = AppController(NikonRepository());
      await controller.load();
      await tester.pumpWidget(MirrorBridgeApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.text('我的相机'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('连接相机').first);
      await tester.pumpAndSettle();
      expect(find.text('连接 Nikon 相机'), findsOneWidget);
      expect(find.text('Canon'), findsNothing);
      expect(find.text('激活'), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      final item = MediaItem(
        id: 'integration',
        name: 'test.jpg',
        kind: MediaKind.jpg,
        date: DateTime.now(),
        bytes: imported['bytes'] as int,
        asset: '',
        localPath: path,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: NikonEditorPage(c: controller, item: item),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 2)),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('导出效果副本到系统相册'), 250);
      expect(find.text('导出效果副本到系统相册'), findsOneWidget);
      await tester.tap(find.text('导出效果副本到系统相册'));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 3)),
      );
      await tester.pumpAndSettle();
      expect(controller.local, hasLength(1));
      expect(
        await channel.invokeMethod<int>('mediaExists', {
          'uri': controller.local.single.albumUri,
        }),
        controller.local.single.bytes,
      );
      expect(tester.takeException(), isNull);
      for (final exported in controller.local) {
        await channel.invokeMethod('deleteLocal', {
          'path': exported.localPath,
          'uri': exported.albumUri,
        });
      }
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await channel.invokeMethod('deleteLocal', {'path': path, 'uri': first});
    },
  );
  testWidgets(
    'Nikon repository downloads from a real socket and persists a published camera file',
    (tester) async {
      const channel = MethodChannel('mirrorbridge/native');
      final dirs = (await channel.invokeMapMethod<String, dynamic>(
        'directories',
      ))!;
      final image = await File(
        '${dirs['cache']}/native-test-source.jpg',
      ).readAsBytes();
      List<int> str(String s) => [
        s.length + 1,
        for (final c in s.codeUnits) ...[c & 255, c >> 8],
        0,
        0,
      ];
      List<int> array16(List<int> values) => [
        ...ptpWords([values.length]),
        for (final v in values) ...ptpU16(v),
      ];
      final peer = CameraPeer()..allowZeroTransaction = true;
      peer.reject = 0x952b;
      await peer.start(port: 15740);
      peer.payloads[0x1001] = Uint8List.fromList([
        ...ptpU16(100),
        ...ptpWords([10]),
        ...ptpU16(100),
        ...str('Nikon'),
        ...ptpU16(0),
        ...array16([
          0x1001,
          0x1002,
          0x1004,
          0x1005,
          0x1007,
          0x1008,
          0x1009,
          0x100a,
        ]),
        ...array16([]),
        ...array16([]),
        ...array16([]),
        ...array16([]),
        ...str('Nikon'),
        ...str('Socket Test'),
        ...str('1.0'),
        ...str('TEST-001'),
      ]);
      peer.payloads[0x1004] = ptpWords([2, 0x10000, 0x10001]);
      peer.unavailableStorages.add(0x10000);
      peer.payloads[0x1005] = Uint8List.fromList([
        ...ptpU16(3),
        ...ptpU16(2),
        ...ptpU16(0),
        ...ptpWords([0, 16, 0, 8, 100]),
        ...str('Test Card'),
        ...str('TEST'),
      ]);
      peer.payloads[0x1007] = ptpWords([1, 7]);
      final info = ByteData(52)
        ..setUint32(0, 0x10001, Endian.little)
        ..setUint16(4, 0x3801, Endian.little)
        ..setUint32(8, image.length, Endian.little)
        ..setUint32(26, 96, Endian.little)
        ..setUint32(30, 64, Endian.little);
      peer.payloads[0x1008] = Uint8List.fromList([
        ...info.buffer.asUint8List(),
        ...str('DSC_9000.JPG'),
        ...str('20260910T120000'),
      ]);
      peer.payloads[0x1009] = image;
      peer.payloads[0x100a] = image;
      final controller = AppController(NikonRepository());
      controller.mode = 'STA';
      controller.live = false;
      controller.receivePush = false;
      try {
        await tester.pumpWidget(MirrorBridgeApp(controller: controller));
        await tester.pumpAndSettle();
        await controller.connect('127.0.0.1');
        final discovered = await controller.nikon!.discover('STA', [
          '127.0.0.1',
        ]);
        expect(discovered.single['deviceId'], '127.0.0.1');
        final session = controller.nikon!.transport;
        expect(peer.sockets, hasLength(2));
        expect(
          await controller.connect('127.0.0.1'),
          true,
          reason: controller.message,
        );
        expect(identical(controller.nikon!.transport, session), true);
        expect(peer.calls.where((op) => op == 0x1002), hasLength(1));
        expect(peer.sockets, hasLength(2));
        expect(controller.media, hasLength(1));
        expect(controller.cameraModel, 'Socket Test');
        expect(controller.nikon!.storages, hasLength(1));
        expect(
          controller.nikon!.logs.any(
            (line) => line.contains('skip unavailable storage'),
          ),
          true,
        );
        final item = controller.media.single;
        await controller.startSync(items: [item]);
        expect(
          controller.task!.completed,
          contains(item.id),
          reason: controller.task!.errors.toString(),
        );
        expect(await File(item.localPath).readAsBytes(), image);
        expect(
          await channel.invokeMethod<int>('mediaExists', {
            'uri': item.albumUri,
          }),
          image.length,
        );
        final restored = AppController(NikonRepository());
        await restored.load();
        expect(
          restored.local.any(
            (m) => m.id == item.id && m.localPath == item.localPath,
          ),
          true,
        );
        expect(restored.connected, false);
        restored.dispose();
        await channel.invokeMethod('deleteLocal', {
          'path': item.localPath,
          'uri': item.albumUri,
        });
        controller.local.clear();
        controller.task = null;
        await controller.save();
      } finally {
        await tester.pumpWidget(const SizedBox());
        await controller.nikon!.dispose();
        controller.dispose();
        await peer.close();
      }
    },
  );
}
