import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirrorbridge/app.dart';
import 'package:mirrorbridge/models/media_item.dart';
import 'package:mirrorbridge/models/media_sync_state.dart';
import 'package:mirrorbridge/models/exif_labels.dart';
import 'package:mirrorbridge/pages/media_page.dart';
import 'package:mirrorbridge/protocol/ptp.dart';
import 'package:mirrorbridge/repositories/demo_repository.dart';
import 'package:mirrorbridge/repositories/nikon_repository.dart';
import 'package:mirrorbridge/state/app_controller.dart';
import 'package:mirrorbridge/widgets/shared.dart';
import 'storage_filter_test.dart' show settleIndex;

MediaItem photo(int n) => MediaItem(
  id: '$n',
  name: '$n.jpg',
  kind: MediaKind.jpg,
  date: DateTime(2026),
  bytes: 1000000,
  asset: 'assets/demo.png',
);

class PagingRepository extends NikonRepository {
  int pages = 0;
  @override
  bool get hasMore => pages < 3;
  @override
  Future<void> loadMore() async {
    pages++;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    media.addAll(List.generate(20, (i) => photo((pages - 1) * 20 + i)));
    onChanged?.call();
  }
}

class FakePtp implements PtpTransport {
  final commands = <(int, List<int>)>[];
  final Map<int, Uint8List> replies = {};
  Uint8List? written;
  int readyTries = 0;
  @override
  Future<void> command(int code, [List<int> params = const []]) async {
    commands.add((code, params));
    if (code == 0x90c8 && readyTries++ == 0) throw PtpException(code, 0x2019);
  }

  @override
  Future<Uint8List> data(int code, [List<int> params = const []]) async =>
      replies[code]!;
  @override
  Future<void> writeProperty(int code, Uint8List bytes) async {
    written = bytes;
  }

  @override
  Future<void> close() async {}
}

class IndexedPtp extends FakePtp {
  List<int> str(String s) => [
    s.length + 1,
    for (final unit in s.codeUnits) ...ptpU16(unit),
    0,
    0,
  ];
  @override
  Future<Uint8List> data(int code, [List<int> params = const []]) async {
    if (code == 0x1004) return ptpWords([1, 1]);
    if (code == 0x1005) return Uint8List(28);
    if (code == 0x1007) {
      return ptpWords([44, ...List.generate(44, (i) => i + 1)]);
    }
    if (code == 0x1008) {
      final n = params.first;
      final header = ByteData(52)
        ..setUint32(0, 1, Endian.little)
        ..setUint16(4, n == 44 ? 0x3001 : 0x3801, Endian.little)
        ..setUint32(8, 1000000, Endian.little)
        ..setUint32(26, 6000, Endian.little)
        ..setUint32(30, 4000, Endian.little);
      return Uint8List.fromList([
        ...header.buffer.asUint8List(),
        ...str(
          n == 44
              ? '100NIKON'
              : n == 43
              ? 'INDEX.DAT'
              : 'DSC_$n.JPG',
        ),
        ...str('20260910T120000'),
      ]);
    }
    throw StateError('Unexpected image download $code');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() {
    messenger.setMockMethodCallHandler(
      AppController.platform,
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(nativeCamera, (_) async => null);
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(AppController.platform, null);
    messenger.setMockMethodCallHandler(nativeCamera, null);
  });

  test(
    'camera index counts all 42 photos, excluding directory and sidecar, before paging 20/20/2',
    () async {
      final r = NikonRepository()
        ..transport = IndexedPtp()
        ..device = PtpDeviceInfo('Nikon', 'Z 8', 'fixture', {}, {})
        ..storages = [
          {'id': 1},
        ]
        ..sourceIdentity = 'fixture';
      await r.refresh();
      await settleIndex(r);
      expect(r.totalMediaCount, 42);
      expect(r.media.length, 20);
      expect(r.hasMore, true);
      await r.loadMore();
      expect(r.media.length, 40);
      await r.loadMore();
      expect(r.media.length, 42);
      expect(r.hasMore, false);
      expect(r.media.map((m) => m.id).toSet(), hasLength(42));
      debugPrint(
        'INDEX total=42; loaded=20 -> 40 -> 42; no image payload requested',
      );
    },
  );

  test(
    'LAN scan lists two named cameras without sending a PTP command or opening a session',
    () async {
      final servers = <ServerSocket>[], sockets = <Socket>[];
      final received = <int>[];
      final ports = <String, int>{};
      for (final ip in ['127.0.1.1', '127.0.1.3']) {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        ports[ip] = server.port;
        servers.add(server);
        server.listen((socket) {
          sockets.add(socket);
          socket.done.ignore();
          socket.listen(received.addAll, onError: (_) {});
        });
      }
      messenger.setMockMethodCallHandler(
        nativeCamera,
        (call) async => switch (call.method) {
          'network' => {
            'interfaces': [
              {'address': '127.0.1.2', 'prefix': 29},
            ],
          },
          'discoverNames' => {
            '127.0.1.1': 'Nikon Z 8',
            '127.0.1.3': 'Nikon Z 6III',
          },
          _ => null,
        },
      );
      final repository = NikonRepository(
        discoveryConnector: (address) {
          final port = ports[address];
          if (port == null) throw const SocketException('No fixture endpoint');
          return Socket.connect(InternetAddress.loopbackIPv4, port);
        },
      );
      try {
        final found = await repository.discover('STA', []);
        expect(found, hasLength(2));
        expect(
          found.map((d) => d['name']),
          containsAll(['Nikon Z 8', 'Nikon Z 6III']),
        );
        expect(received, isEmpty);
        expect(repository.transport, isNull);
        expect(repository.device, isNull);
        expect(repository.media, isEmpty);
        debugPrint(
          'DISCOVERY two named candidates; PTP bytes=0; connection remains unselected',
        );
      } finally {
        repository.clearDiscovery();
        for (final socket in sockets) {
          socket.destroy();
        }
        for (final server in servers) {
          await server.close();
        }
      }
    },
  );

  test(
    'select all affects loaded filter matches only; deleting local files also prunes sync records',
    () async {
      final c = AppController(DemoRepository(delay: Duration.zero));
      c.connection = ConnectionPhase.connected;
      c.media = [photo(1), photo(2), photo(3)];
      c.selectAllLoaded();
      expect(c.selection, {'1', '2', '3'});
      c.media.add(photo(4));
      expect(c.selection, isNot(contains('4')));
      c.selectAllLoaded();
      expect(c.selection.length, 4);
      await c.startSync();
      expect(c.completedCount, 4);
      await c.deleteLocal({'1', '2'});
      expect(c.completedCount, 2);
      expect(c.task!.items.map((e) => e.id), ['3', '4']);
      expect(c.task!.completed, {'3', '4'});
      await c.deleteLocal({'3', '4'});
      expect(c.task, isNull);
      debugPrint(
        'DELETE local count 4 -> 2 -> 0; sync records 4 -> 2 -> absent',
      );
      c.dispose();
    },
  );

  test('in-flight bytes update before a photograph completes', () {
    final repo = NikonRepository();
    final c = AppController(repo);
    c.task = SyncTask([photo(1), photo(2)])..phase = SyncPhase.transferring;
    repo.onProgress!(262144, 1000000);
    expect(c.transferredBytes, 262144);
    expect(c.task!.completed, isEmpty);
    expect(c.byteProgress, closeTo(.131072, .000001));
    repo.onProgress!(524288, 1000000);
    expect(c.transferredBytes, 524288);
    debugPrint('STREAM completed=0; bytes=262144 -> 524288');
    c.dispose();
  });

  test(
    'external deletion or access loss keeps history with missing status and preserves private copies',
    () async {
      final dir = await Directory.systemTemp.createTemp('mirrorbridge-local-');
      final c = AppController(NikonRepository());
      final a = MediaItem.fromJson({...photo(1).toJson(), 'asset': ''})
        ..contentHash = 'hash-a'
        ..hashVerified = true
        ..localPath = '${dir.path}/1.jpg'
        ..albumUri = 'content://photos/1';
      final b = MediaItem.fromJson({...photo(2).toJson(), 'asset': ''})
        ..contentHash = 'hash-b'
        ..hashVerified = true
        ..localPath = '${dir.path}/2.jpg'
        ..albumUri = 'content://photos/2';
      await File(a.localPath).writeAsBytes([1]);
      await File(b.localPath).writeAsBytes([2]);
      c.local = [a, b];
      c.syncCompletedIds.addAll({'1', '2', 'previously-deleted'});
      expect(c.totalSyncCompleted, 2);
      c.task = SyncTask([a, b])..phase = SyncPhase.completed;
      c.task!.completed.addAll({'1', '2'});
      final older = SyncTask([a])..phase = SyncPhase.completed;
      older.completed.add(a.id);
      c.syncTasks.add(older);
      messenger.setMockMethodCallHandler(nativeCamera, (call) async {
        if (call.method == 'referenceStates') {
          return [
            {'available': false},
            {'available': false},
          ];
        }
        return null;
      });
      expect(c.mediaSyncState(a), MediaSyncState.synced);
      await c.refreshLocal();
      expect(c.local, hasLength(2));
      expect(c.visibleLocal, isEmpty);
      expect(c.mediaSyncState(a), MediaSyncState.missing);
      expect(c.mediaSyncState(b), MediaSyncState.missing);
      expect(c.totalSyncCompleted, 0);
      expect(c.task!.completed, {'1', '2'});
      expect(c.task!.missing, {'1', '2'});
      expect(c.containsSyncTask(older), true);
      expect(await File(a.localPath).exists(), true);
      expect(await File(b.localPath).exists(), true);
      c.dispose();
      await dir.delete(recursive: true);
    },
  );

  test('signed exposure compensation and verified capture sequence', () async {
    final ptp = FakePtp();
    ptp.replies[0x1014] = Uint8List.fromList([
      ...ptpU16(0x5010),
      ...ptpU16(3),
      1,
      ...ptpU16(0),
      ...ptpU16(0xfc18),
      1,
      ...ptpU16(0xec78),
      ...ptpU16(5000),
      ...ptpU16(1000),
    ]);
    final r = NikonRepository()
      ..transport = ptp
      ..monitoring = true;
    final p = await r.property(0x5010);
    expect(p['current'], -1000);
    expect((p['values'] as List).first, -5000);
    await r.setProperty(0x5010, 3, -1000);
    expect(ptp.written, [0x18, 0xfc]);
    await r.captureToCard();
    expect(ptp.commands.map((e) => e.$1), [
      0x9202,
      0x9207,
      0x90c8,
      0x90c8,
      0x9201,
    ]);
    expect(ptp.commands[1].$2, [0xffffffff, 0]);
    ptp.replies[0x1015] = Uint8List.fromList([0]);
    ptp.replies[0x9203] = Uint8List.fromList([255, 216, 255, 217]);
    await r.focusAt(160, 120);
    expect(ptp.commands[5].$1, 0x9205);
    expect(ptp.commands[5].$2, [160, 120]);
    expect(ptp.commands.last.$1, 0x90c1);
    debugPrint(
      'CAPTURE StopLiveView -> CaptureToCard(-1,0) -> DeviceReady busy/ready -> StartLiveView',
    );
  });

  test(
    'known EXIF labels and enum values are translated without hiding raw values',
    () {
      expect(exifLabels.length, greaterThan(90));
      expect(exifValue('ExposureProgram', '3'), '光圈优先 A（3）');
      expect(exifValue('WhiteBalance', '1'), '手动白平衡（1）');
      expect(exifValue('UnknownField', '123'), '123');
    },
  );

  testWidgets(
    'scroll loads one additional page of 20; selection does not include subsequent pages',
    (tester) async {
      final r = PagingRepository()..totalMediaCount = 60;
      final c = AppController(r)
        ..connection = ConnectionPhase.connected
        ..tab = 2;
      r.pages = 1;
      r.media = List.generate(20, photo);
      c.media = r.media;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: c,
              builder: (_, child) => MediaPage(c: c, onConnect: () {}),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      c.selectAllLoaded();
      expect(c.selection, hasLength(20));
      for (var i = 0; i < 5 && c.media.length == 20; i++) {
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -700));
        await tester.pumpAndSettle();
      }
      expect(c.media, hasLength(40));
      expect(c.selection, hasLength(20));
      expect(find.text('加载更多'), findsNothing);
      expect(find.text('刷新'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );

  testWidgets(
    'notifications count down and expire after three seconds; replacement gets its own timer',
    (tester) async {
      final c = AppController(DemoRepository())..message = '第一条通知';
      await tester.pumpWidget(MirrorBridgeApp(controller: c));
      await tester.pump(const Duration(milliseconds: 1500));
      final bars = tester.widgetList<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(
        bars.any(
          (bar) => bar.value != null && bar.value! > .4 && bar.value! < .6,
        ),
        true,
      );
      c.message = '第二条通知';
      c.changed();
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('第二条通知'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.byType(TimedNotice), findsNothing);
      expect(c.message, isEmpty);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
}
