import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirrorbridge/models/media_item.dart';
import 'package:mirrorbridge/models/nikon_monitor_values.dart';
import 'package:mirrorbridge/models/nikon_live_geometry.dart';
import 'package:mirrorbridge/pages/home_page.dart';
import 'package:mirrorbridge/pages/nikon_camera_page.dart';
import 'package:mirrorbridge/protocol/ptp.dart';
import 'package:mirrorbridge/repositories/nikon_repository.dart';
import 'package:mirrorbridge/state/app_controller.dart';

class RemotePeer implements PtpTransport {
  final calls = <(int, List<int>)>[];
  final values = <int, int>{0x500a: 0x8010, 0xd0a4: 0, 0xd1a6: 1};
  final failures = <int, Object>{};
  bool requireFrame = false, frame = false;
  @override
  Future<void> command(int op, [List<int> params = const []]) async {
    calls.add((op, params));
    if (failures.containsKey(op)) throw failures.remove(op)!;
    if (op == 0x90c1 && requireFrame && !frame) throw PtpException(op, 0xa002);
  }

  @override
  Future<Uint8List> data(int op, [List<int> params = const []]) async {
    calls.add((op, params));
    if (failures.containsKey(op)) throw failures.remove(op)!;
    if (op == 0x1015 || op == 0x943b) {
      if (!values.containsKey(params.single)) throw PtpException(op, 0x2006);
      return ptpWords([values[params.single]!]);
    }
    frame = true;
    return Uint8List.fromList([255, 216, 255, 217]);
  }

  @override
  Future<void> writeProperty(int code, Uint8List value) async {
    calls.add((0x1016, [code, ...value]));
    if (value.isNotEmpty) values[code] = value.first;
    if (failures.containsKey(0x1016)) throw failures.remove(0x1016)!;
  }

  @override
  Future<void> close() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late RemotePeer peer;
  late NikonRepository repo;
  setUp(() {
    peer = RemotePeer();
    repo = NikonRepository()
      ..transport = peer
      ..monitoring = true
      ..device = PtpDeviceInfo(
        'Nikon',
        'Z 8',
        'fixture',
        {
          0x90c1,
          0x90c8,
          0x9201,
          0x9202,
          0x9203,
          0x9205,
          0x920a,
          0x920b,
          0x9424,
          0x9425,
          0x9435,
        },
        {0x500a, 0xd1a6, 0xd0a4},
      );
  });
  test(
    'meter reads changing signed camera values and retries after mode changes',
    () async {
      expect(await repo.readLightMeter(), isNull);
      peer.values[0xd1b1] = 6;
      expect(await repo.readLightMeter(), isNull);
      await repo.setProperty(0xd1a6, 2, 1);
      expect(await repo.readLightMeter(), 1);
      peer.values[0xd1b1] = 250;
      expect(await repo.readLightMeter(), -1);
      peer.values[0xd1b1] = 0;
      expect(await repo.readLightMeter(), 0);
    },
  );
  test(
    'video exposure indicator gates live signed values and recovers when enabled',
    () async {
      repo.setMeterMode(true);
      peer.values[0xd1b1] = 0;
      peer.values[0xd1b3] = 1;
      expect(await repo.readLightMeter(), isNull);
      peer.values[0xd1b3] = 0;
      peer.values[0xd1b1] = 12;
      expect(await repo.readLightMeter(), 2);
      peer.values[0xd1b1] = 244;
      expect(await repo.readLightMeter(), -2);
      peer.values[0xd1b1] = 0;
      expect(await repo.readLightMeter(), 0);
      peer.values[0xd1b3] = 1;
      expect(await repo.readLightMeter(), isNull);
    },
  );
  test(
    'video never presents the observed frozen D1B1 zero as a valid meter',
    () async {
      peer.values[0xd1b1] = 0;
      expect(await repo.readLightMeter(), 0);
      repo.setMeterMode(true);
      expect(await repo.readLightMeter(), isNull);
      repo.setMeterMode(false);
      peer.values[0xd1b1] = 244;
      expect(await repo.readLightMeter(), -2);
    },
  );
  for (final entry in <int, List<int>>{
    0x500a: [0, 1, 2, 3, 0x8010, 0x8011, 0x8012, 0x8013],
    0x500b: [1, 2, 3, 4, 0x8010],
    0x5005: [
      1,
      2,
      3,
      4,
      5,
      6,
      7,
      0x8010,
      0x8011,
      0x8012,
      0x8013,
      0x8014,
      0x8015,
      0x8016,
    ],
    0x500e: [
      1,
      2,
      3,
      4,
      0x8010,
      0x8011,
      0x8012,
      0x8013,
      0x8014,
      0x8015,
      0x8016,
    ],
    0xd1a6: [0, 1],
  }.entries) {
    test('all supported enum choices have names for ${entry.key}', () {
      for (final value in entry.value) {
        final label = nikonMonitorValue(entry.key, value);
        expect(label, isNot('$value'));
        expect(label, isNot(contains('未知')));
      }
      expect(nikonMonitorValue(entry.key, 0x8888), '未知选项（0x8888）');
    });
  }
  test('photo and movie properties retain their distinct enum domains', () {
    expect(nikonMonitorValue(0x500a, 1), '手动 MF');
    expect(nikonMonitorValue(0x500a, 1, propertyCode: 0xd1fa), '连续 AF-C');
    expect(nikonMonitorValue(0x500a, 2, propertyCode: 0xd061), '全时 AF-F');
    for (final code in [
      0x500f,
      0x5007,
      0x500d,
      0x5010,
      0x5005,
      0x500a,
      0x500b,
    ]) {
      expect(nikonMonitorProperties(code, movie: true).first, isNot(code));
      expect(nikonMonitorProperties(code, movie: true).last, code);
    }
  });
  test(
    'shutter sentinels and packed fractions never become enormous seconds',
    () {
      expect(nikonMonitorValue(0x500d, 0xffffffff), 'B 门');
      expect(nikonMonitorValue(0x500d, 0xfffffffe), 'T 门');
      expect(
        nikonMonitorValue(0x500d, (1 << 16) | 125, propertyCode: 0xd1a8),
        '1/125s',
      );
      expect(nikonMonitorValue(0x500d, 1 << 16, propertyCode: 0xd100), '未提供快门');
      expect(nikonMonitorValue(0x500f, 0xffff), '自动 ISO');
      expect(nikonMonitorValue(0x5010, -1000), '-1.0 EV');
    },
  );
  test(
    'crop coordinates are transformed to camera area; invalid headers ignored',
    () {
      final b = ByteData(64);
      final values = [1024, 680, 6000, 4000, 3000, 2000, 3000, 2000];
      for (var i = 0; i < values.length; i++) {
        b.setUint16(i * 2, values[i]);
      }
      final geometry = NikonLiveGeometry.parse(b.buffer.asUint8List())!;
      expect(geometry.point(0, 0), (1500, 1000));
      expect(geometry.point(1, 1), (4499, 2999));
      expect(NikonLiveGeometry.parse(Uint8List(64)), isNull);
      expect(NikonLiveGeometry.parse(Uint8List.fromList([255, 216])), isNull);
    },
  );
  test('touch AF consumes a frame before driving lens', () async {
    peer.requireFrame = true;
    await repo.focusAt(256, 170);
    final codes = peer.calls.map((c) => c.$1).toList();
    expect(codes.indexOf(0x9205), lessThan(codes.indexOf(0x9203)));
    expect(codes.indexOf(0x9203), lessThan(codes.indexOf(0x90c1)));
  });
  test('MF explains rejection and full-time AF only moves point', () async {
    peer.values[0x500a] = 1;
    await expectLater(repo.focusAt(1, 1), throwsStateError);
    expect(peer.calls.where((c) => c.$1 == 0x9205), isEmpty);
    peer.values[0x500a] = 0x8013;
    await repo.focusAt(1, 1);
    expect(peer.calls.where((c) => c.$1 == 0x90c1), isEmpty);
    expect(peer.calls.where((c) => c.$1 == 0x9205), hasLength(1));
  });
  test(
    'recording checks prohibition and changes application only when needed',
    () async {
      await repo.remoteAction(0x920a);
      expect(repo.movieRecording, true);
      expect(peer.calls.where((c) => c.$1 == 0x9435), isEmpty);
      await repo.remoteAction(0x920b);
      peer.values[0xd0a4] = 1;
      await repo.remoteAction(0x920a);
      expect(
        peer.calls.where((c) => c.$1 == 0x9435 && c.$2.single == 1),
        hasLength(1),
      );
    },
  );
  test('unsupported application opcode uses the property fallback', () async {
    peer.values[0xd0a4] = 1;
    peer.failures[0x9435] = PtpException(0x9435, 0x2005);
    await repo.remoteAction(0x920a);
    expect(peer.calls.singleWhere((c) => c.$1 == 0x1016).$2, [0xd1f0, 1]);
  });
  test(
    'Wi-Fi selector write keeps live view and confirms current mode',
    () async {
      peer.values[0xd1a6] = 0;
      await repo.remoteAction(0x920a);
      final codes = peer.calls.map((c) => c.$1).toList();
      expect(codes, isNot(contains(0x9202)));
      expect(codes, isNot(contains(0x9201)));
      expect(codes.last, 0x920a);
    },
  );
  for (final error in [
    TimeoutException('fixture timeout'),
    PtpException(0x920a, 0x2019),
    PtpException(0x920a, 0xa004),
  ]) {
    test('record rejection never blindly replays $error', () async {
      peer.failures[0x920a] = error;
      await expectLater(repo.remoteAction(0x920a), throwsA(anything));
      expect(repo.movieRecording, false);
      expect(peer.calls.where((c) => c.$1 == 0x920a), hasLength(1));
    });
  }
  test('explicit NotLiveView gets exactly one restart and retry', () async {
    peer.failures[0x920a] = PtpException(0x920a, 0xa00b);
    await repo.remoteAction(0x920a);
    expect(peer.calls.where((c) => c.$1 == 0x920a), hasLength(2));
    expect(repo.movieRecording, true);
  });
  test(
    'recording blocks parameter and shutter operations; shutdown stops first',
    () async {
      await repo.remoteAction(0x920a);
      await expectLater(repo.setProperty(0x500a, 4, 1), throwsStateError);
      await expectLater(repo.captureToCard(), throwsStateError);
      peer.calls.clear();
      await repo.stopMonitor();
      expect(peer.calls.first.$1, 0x920b);
      expect(repo.movieRecording, false);
    },
  );
  test(
    'failed stop preserves recording state and does not end live view',
    () async {
      await repo.remoteAction(0x920a);
      peer.calls.clear();
      peer.failures[0x920b] = TimeoutException('stop uncertain');
      await expectLater(repo.stopMonitor(), throwsA(isA<TimeoutException>()));
      expect(repo.movieRecording, true);
      expect(peer.calls.where((c) => c.$1 == 0x9202), isEmpty);
    },
  );
  test('Wi-Fi focus mode rejection does not interrupt live view', () async {
    peer.failures[0x1016] = PtpException(0x1016, 0x201b);
    await expectLater(
      repo.setProperty(0xd061, 2, 0),
      throwsA(isA<PtpException>()),
    );
    expect(peer.calls.first.$1, 0x1016);
    expect(peer.calls.map((c) => c.$1), isNot(contains(0x9201)));
    expect(peer.calls.map((c) => c.$1), isNot(contains(0x9202)));
  });
  testWidgets('connected home and camera show monitor entry above the fold', (
    tester,
  ) async {
    final c = AppController(repo)..connection = ConnectionPhase.connected;
    addTearDown(c.dispose);
    for (final widget in [
      HomePage(c: c, onConnect: () {}),
      NikonCameraPage(c: c, onConnect: () {}),
    ]) {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: widget)));
      final entry = find.text('进入实时监看');
      expect(entry, findsOneWidget);
      expect(tester.getRect(entry).bottom, lessThan(600));
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
  });
}
