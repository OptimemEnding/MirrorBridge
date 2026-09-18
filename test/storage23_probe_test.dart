// ignore_for_file: avoid_print
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirrorbridge/models/media_item.dart';
import 'package:mirrorbridge/protocol/ptp.dart';
import 'package:mirrorbridge/repositories/nikon_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('failed download storage probe', () async {
    final dir = await Directory.systemTemp.createTemp('storage23');
    final repo = NikonRepository()
      ..transport = UsbPtpTransport()
      ..sourceIdentity = 'camera'
      ..directory = dir.path
      ..device = PtpDeviceInfo('Nikon', 'Z8', 'fixture', {0x101b}, {});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(nativeCamera, (call) async {
      if (call.method == 'directories') {
        return {'cache': dir.path, 'media': dir.path, 'freeBytes': 100000000};
      }
      if (call.method == 'usbDownload') {
        await File(call.arguments['path'] as String).writeAsBytes([1, 2]);
        throw PlatformException(
          code: 'CANCELLED',
          message: 'fixture interrupted',
        );
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
    try {
      await expectLater(repo.transfer(item), throwsA(isA<PlatformException>()));
      final remaining = await dir
          .list(recursive: true)
          .where((f) => f is File)
          .length;
      print('FAILED_DOWNLOAD remainingFiles=$remaining');
    } finally {
      messenger.setMockMethodCallHandler(nativeCamera, null);
      await dir.delete(recursive: true);
    }
  });
}
