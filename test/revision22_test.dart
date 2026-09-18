import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirrorbridge/models/media_item.dart';
import 'package:mirrorbridge/models/nikon_monitor_values.dart';
import 'package:mirrorbridge/protocol/ptp.dart';
import 'package:mirrorbridge/repositories/nikon_repository.dart';
import 'package:mirrorbridge/state/app_controller.dart';
import 'ptp_test.dart' show CameraPeer;
import 'optimization_test.dart' show LargeCardPeer;
import 'support/ptp_fixtures.dart';

class UpdatingPeer extends CameraPeer {
  int count = 1;
  @override
  void receive(Socket socket, int type, Uint8List payload) {
    if (type == 6) {
      final r = PtpReader(payload)..u32();
      final op = r.u16();
      r.u32();
      if (op == 0x1007) {
        payloads[op] = ptpWords([count, ...List.generate(count, (i) => i + 1)]);
      }
      if (op == 0x1008) payloads[op] = LargeCardPeer().object(r.u32());
    }
    super.receive(socket, type, payload);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  test(
    'shutter labels use nominal third stops preserving reciprocal and B/T',
    () {
      expect(nikonMonitorValue(0x500d, 12345), '1.3s');
      expect(
        nikonMonitorValue(0x500d, (7 << 16) | 3, propertyCode: 0xd100),
        '2.5s',
      );
      expect(
        nikonMonitorValue(0x500d, (1 << 16) | 125, propertyCode: 0xd1a8),
        '1/125s',
      );
      expect(nikonMonitorValue(0x500d, 100000), '10s');
      expect(nikonMonitorValue(0x500d, 0xffffffff), 'B 门');
    },
  );
  test(
    'new camera photos update without refresh and independently of auto download',
    () async {
      final dir = await Directory.systemTemp.createTemp('auto_update');
      messenger.setMockMethodCallHandler(
        const MethodChannel('mirrorbridge/native_events'),
        (_) async => null,
      );
      messenger.setMockMethodCallHandler(nativeCamera, (call) async {
        if (call.method == 'directories') {
          return {'cache': dir.path, 'media': dir.path, 'freeBytes': 100000000};
        }
        return null;
      });
      final peer = UpdatingPeer()
        ..allowZeroTransaction = true
        ..sendInitialEvent = false;
      peer.payloads[0x1001] = syntheticDeviceInfo(transferReady: true);
      peer.payloads[0x1004] = ptpWords([1, 1]);
      peer.payloads[0x1005] = Uint8List(32);
      await peer.start(port: 15740);
      final repo = NikonRepository()..mode = 'Wi-Fi';
      final c = AppController(repo);
      try {
        await repo.connect('127.0.0.1');
        c.connection = ConnectionPhase.connected;
        expect(repo.media.length, 1);
        expect(c.live, false);
        peer.count = 2;
        final deadline = Stopwatch()..start();
        while (repo.media.length < 2 && deadline.elapsedMilliseconds < 3500) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(repo.media.length, 2);
        expect(c.media.length, 2);
        expect(c.task, isNull);
        peer.count = 3;
        peer.send(peer.eventSocket!, 8, [
          ...ptpU16(0x4002),
          ...ptpWords([0, 3]),
        ]);
        final eventClock = Stopwatch()..start();
        while (repo.media.length < 3 && eventClock.elapsedMilliseconds < 1500) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(repo.media.length, 3);
      } finally {
        await repo.dispose();
        c.dispose();
        await peer.close();
        await dir.delete(recursive: true);
        messenger.setMockMethodCallHandler(nativeCamera, null);
      }
    },
  );
  test('transfer retains only published URI after verification', () async {
    final dir = await Directory.systemTemp.createTemp('publish_once');
    final repo = NikonRepository()
      ..transport = UsbPtpTransport()
      ..sourceIdentity = 'camera'
      ..directory = dir.path
      ..device = PtpDeviceInfo('Nikon', 'Z8', 'fixture', {0x101b}, {});
    final order = <String>[];
    messenger.setMockMethodCallHandler(nativeCamera, (call) async {
      order.add(call.method);
      if (call.method == 'directories') {
        return {'cache': dir.path, 'media': dir.path, 'freeBytes': 100000000};
      }
      if (call.method == 'usbDownload') {
        await File(call.arguments['path'] as String).writeAsBytes([1, 2, 3, 4]);
      }
      if (call.method == 'publish') {
        return 'content://media/external/images/media/22';
      }
      if (call.method == 'releasePublishedCopy') {
        await File(call.arguments['path'] as String).delete();
        return true;
      }
      return null;
    });
    final item = MediaItem(
      id: 'one',
      name: 'a.JPG',
      kind: MediaKind.jpg,
      date: DateTime(2026),
      bytes: 4,
      source: 'camera',
    );
    await repo.transfer(item);
    expect(item.localPath, isEmpty);
    expect(item.sourceUri, item.albumUri);
    expect(item.sourceUri, contains('content://'));
    expect(await dir.list().length, 0);
    expect(
      order.indexOf('publish'),
      lessThan(order.indexOf('releasePublishedCopy')),
    );
    await dir.delete(recursive: true);
    messenger.setMockMethodCallHandler(nativeCamera, null);
  });
}
