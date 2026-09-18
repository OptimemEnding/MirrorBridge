import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirrorbridge/protocol/ptp.dart';
import 'package:mirrorbridge/repositories/nikon_repository.dart';
import 'ptp_test.dart' show CameraPeer;
import 'nikon_pairing_test.dart' show PairingPeer;
import 'support/ptp_fixtures.dart';

class MonitorPtp implements PtpTransport {
  final calls = <(int, List<int>)>[];
  final reads = <int>[];
  bool failStart = false, failEnd = false, failControlRestore = false;
  int readyTries = 0;
  @override
  Future<void> command(int code, [List<int> params = const []]) async {
    calls.add((code, params));
    if (code == 0x90c8 && readyTries++ == 0) throw PtpException(code, 0x2019);
    if (code == 0x9201 && failStart ||
        code == 0x9202 && failEnd ||
        code == 0x90c2 && params.first == 0 && failControlRestore) {
      throw PtpException(code, 0xa004);
    }
  }

  @override
  Future<Uint8List> data(int code, [List<int> params = const []]) async {
    reads.add(code);
    if (code == 0x9428) throw PtpException(code, 0x2005);
    return Uint8List.fromList([0, 0, 255, 216, 1, 2, 255, 217]);
  }

  @override
  Future<void> writeProperty(int property, Uint8List bytes) async {}
  @override
  Future<void> close() async {}
}

class TransitionPeer extends PairingPeer {
  int pendingTransfers = 1;
  bool stallConfirmation = false, expireFirstSocket = false;
  @override
  void receive(Socket socket, int type, Uint8List payload) {
    if (type == 1 && expireFirstSocket && sockets.length == 1) {
      socket.destroy();
      return;
    }
    if (type == 6) {
      final r = PtpReader(payload)..u32();
      final op = r.u16();
      if (op == 0x935a && stallConfirmation) return;
      if (op == 0x1001 && confirmed && pendingTransfers-- > 0) {
        final saved = transferInfo;
        transferInfo = pairingInfo;
        super.receive(socket, type, payload);
        transferInfo = saved;
        return;
      }
    }
    super.receive(socket, type, payload);
  }
}

class LargeCardPeer extends CameraPeer {
  int objectReads = 0;
  Uint8List object(int n) {
    List<int> str(String text) => [
      text.length + 1,
      for (final c in text.codeUnits) ...ptpU16(c),
      0,
      0,
    ];
    final header = ByteData(52)
      ..setUint32(0, 1, Endian.little)
      ..setUint16(4, 0x3801, Endian.little)
      ..setUint32(8, 1000000, Endian.little);
    return Uint8List.fromList([
      ...header.buffer.asUint8List(),
      ...str('DSC_$n.JPG'),
      ...str('20260911T120000'),
    ]);
  }

  @override
  void receive(Socket socket, int type, Uint8List payload) {
    if (type == 6) {
      final r = PtpReader(payload)..u32();
      final op = r.u16();
      final tx = r.u32();
      if (op == 0x1008) {
        objectReads++;
        // The background index stalls, but the first page must still return.
        if (objectReads > 20) return;
        payloads[op] = object(r.u32());
      }
      if (op == 0x952b) {
        response(socket, tx, 0x2005);
        return;
      }
    }
    super.receive(socket, type, payload);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory dir;
  bool serviceActive = false;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('nikon-optimization-');
    messenger.setMockMethodCallHandler(
      const MethodChannel('mirrorbridge/native_events'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(nativeCamera, (call) async {
      if (call.method == 'directories') {
        return {'media': dir.path, 'cache': dir.path};
      }
      if (call.method == 'network') return {'clientName': 'MacTest'};
      if (call.method == 'service') {
        serviceActive = (call.arguments as Map)['active'] == true;
      }
      return null;
    });
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(nativeCamera, null);
    messenger.setMockMethodCallHandler(
      const MethodChannel('mirrorbridge/native_events'),
      null,
    );
    await dir.delete(recursive: true);
  });
  test(
    'discovery emits before slow probe and DNS; cancellation discards late sockets',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = <Socket>[];
      server.listen((s) {
        accepted.add(s);
        s.done.ignore();
      });
      final late = Completer<Socket>(), dns = Completer<Map<String, String>>();
      messenger.setMockMethodCallHandler(nativeCamera, (call) async {
        if (call.method == 'network') {
          return {
            'interfaces': [
              {'address': '127.0.1.2', 'prefix': 29},
            ],
          };
        }
        if (call.method == 'discoverNames') return dns.future;
        return null;
      });
      final repo = NikonRepository(
        discoveryConnector: (address) {
          if (address == '127.0.1.1') {
            return Socket.connect(InternetAddress.loopbackIPv4, server.port);
          }
          if (address == '127.0.1.3') return late.future;
          throw const SocketException('No service');
        },
      );
      final first = Completer<void>();
      final devices = <Map<String, dynamic>>[];
      var finished = false;
      final scan = repo.discover(
        'STA',
        [],
        onDevice: (device) {
          devices.add(device);
          if (!first.isCompleted) first.complete();
        },
      );
      scan.then((_) => finished = true);
      await first.future.timeout(const Duration(seconds: 2));
      expect(finished, false);
      expect(devices.single['deviceId'], '127.0.1.1');
      repo.clearDiscovery();
      late.complete(
        await Socket.connect(InternetAddress.loopbackIPv4, server.port),
      );
      dns.complete({'127.0.1.1': 'Late name'});
      await scan;
      expect(devices, hasLength(1));
      for (final socket in accepted) {
        socket.destroy();
      }
      await server.close();
    },
  );
  Future<TransitionPeer> pairingPeer() async {
    final peer = TransitionPeer()
      ..allowZeroTransaction = true
      ..pairingInfo = syntheticDeviceInfo(transferReady: false)
      ..transferInfo = syntheticDeviceInfo(transferReady: true);
    peer.payloads[0x952b] = Uint8List.fromList([4, 0, 0, 0, 1, 9, 7, 1]);
    peer.payloads[0x941c] = ptpWords([0]);
    peer.payloads[0x1004] = ptpWords([0]);
    await peer.start(port: 15740);
    return peer;
  }

  test(
    'same click waits for transfer capability after pairing confirmation',
    () async {
      final peer = await pairingPeer();
      final repo = NikonRepository()..mode = 'STA';
      final stages = <String>[];
      repo.onConnectionStage = stages.add;
      try {
        await repo.connect('127.0.0.1');
        expect(repo.device!.model, 'Z 8');
        expect(serviceActive, true);
        expect(peer.calls.where((c) => c == 0x935a), hasLength(1));
        expect(peer.sockets, hasLength(6));
        expect(stages.any((s) => s.contains('OK／确认键')), true);
        expect(
          repo.logs.any((s) => s.contains('transfer session ready attempt=2')),
          true,
        );
      } finally {
        await repo.dispose();
        await peer.close();
      }
    },
  );
  test(
    'expired discovery socket recovers inside one connect invocation',
    () async {
      final peer = await pairingPeer();
      peer.expireFirstSocket = true;
      final repo = NikonRepository()..mode = 'STA';
      try {
        final socket = await Socket.connect('127.0.0.1', 15740);
        await repo.connect('127.0.0.1', commandSocket: socket);
        expect(repo.device!.model, 'Z 8');
        expect(repo.logs.any((l) => l.contains('retry fresh handshake')), true);
      } finally {
        await repo.dispose();
        await peer.close();
      }
    },
  );
  test(
    'connection deadline closes both channels and never reports ready',
    () async {
      final peer = await pairingPeer();
      peer.stallConfirmation = true;
      final repo = NikonRepository(
        connectionTimeout: const Duration(milliseconds: 180),
      )..mode = 'STA';
      final clock = Stopwatch()..start();
      try {
        await expectLater(
          repo.connect('127.0.0.1'),
          throwsA(isA<TimeoutException>()),
        );
        expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(repo.device, isNull);
        expect(repo.transport, isNull);
        expect(serviceActive, false);
      } finally {
        await repo.dispose();
        await peer.close();
      }
    },
  );
  test(
    'large card connects after first 20 objects while metadata index is stalled',
    () async {
      final peer = LargeCardPeer()..allowZeroTransaction = true;
      peer.payloads[0x1001] = syntheticDeviceInfo(transferReady: true);
      peer.payloads[0x1004] = ptpWords([1, 1]);
      peer.payloads[0x1005] = Uint8List(32);
      peer.payloads[0x1007] = ptpWords([
        2000,
        ...List.generate(2000, (i) => i + 1),
      ]);
      await peer.start(port: 15740);
      final repo = NikonRepository()..mode = 'Wi-Fi';
      try {
        final media = await repo
            .connect('127.0.0.1')
            .timeout(const Duration(seconds: 2));
        expect(media, hasLength(20));
        expect(repo.totalMediaCount, isNull);
        expect(peer.objectReads, lessThanOrEqualTo(21));
        expect(repo.hasMore, true);
      } finally {
        await repo.dispose();
        await peer.close();
      }
    },
  );
  for (final fail in [false, true]) {
    test(
      'monitor ${fail ? 'startup failure restores every mode' : 'readiness and cached frame fallback'}',
      () async {
        final ptp = MonitorPtp()..failStart = fail;
        final repo = NikonRepository()
          ..transport = ptp
          ..device = PtpDeviceInfo('Nikon', 'Z 8', 'fixture', {
            0x9435,
            0x90c2,
            0x90c8,
            0x9201,
            0x9428,
          }, {});
        if (fail) {
          await expectLater(repo.startMonitor(), throwsA(isA<PtpException>()));
          expect(repo.monitoring, false);
          expect(
            ptp.calls.map((c) => '${c.$1}:${c.$2.join(',')}'),
            containsAllInOrder(['37378:', '37058:0', '37941:0']),
          );
        } else {
          await repo.startMonitor();
          expect(repo.monitoring, true);
          expect(await repo.liveFrame(), [255, 216, 1, 2, 255, 217]);
          await repo.liveFrame();
          expect(ptp.reads, [0x9428, 0x9203, 0x9203]);
          await repo.stopMonitor();
          expect(repo.monitoring, false);
        }
        await repo.dispose();
      },
    );
  }
  test(
    'cleanup restores application mode even after other cleanup failures',
    () async {
      final ptp = MonitorPtp()
        ..failEnd = true
        ..failControlRestore = true;
      final repo = NikonRepository()
        ..transport = ptp
        ..monitoring = true
        ..device = PtpDeviceInfo('Nikon', 'Z 8', 'fixture', {
          0x9435,
          0x90c2,
        }, {});
      await expectLater(repo.stopMonitor(), throwsStateError);
      expect(ptp.calls.map((c) => '${c.$1}:${c.$2.join(',')}'), [
        '37378:',
        '37058:0',
        '37941:0',
      ]);
      expect(repo.monitoring, false);
      await repo.dispose();
    },
  );
  test(
    'cancelled setup cannot resume after its platform callback returns',
    () async {
      final setup = Completer<Map<String, String>>();
      final entered = Completer<void>();
      messenger.setMockMethodCallHandler(nativeCamera, (call) async {
        if (call.method == 'directories') {
          if (!entered.isCompleted) entered.complete();
          return setup.future;
        }
        return null;
      });
      final repo = NikonRepository();
      final result = repo.connect('127.0.0.1');
      final failure = expectLater(result, throwsStateError);
      await entered.future;
      await repo.disconnect();
      setup.complete({'media': dir.path, 'cache': dir.path});
      await failure;
      expect(repo.transport, isNull);
      expect(repo.device, isNull);
      await repo.dispose();
    },
  );

  test('two taps while connecting share one handshake future', () async {
    final peer = await pairingPeer();
    peer.pendingTransfers = 0;
    final repo = NikonRepository()..mode = 'STA';
    try {
      final first = repo.connect('127.0.0.1');
      final second = repo.connect('127.0.0.1');
      expect(identical(first, second), true);
      await first;
      expect(peer.calls.where((op) => op == 0x935a), hasLength(1));
    } finally {
      await repo.dispose();
      await peer.close();
    }
  });

  test('PTP open deadline closes a silent handshake', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    server.listen((s) {
      sockets.add(s);
      s.done.ignore();
      s.listen((_) {}, onError: (_) {});
    });
    final ptp = PtpIpTransport();
    await expectLater(
      ptp.open(
        '127.0.0.1',
        List.filled(16, 1),
        port: server.port,
        timeout: const Duration(milliseconds: 120),
      ),
      throwsA(isA<PtpConnectionException>()),
    );
    expect(ptp.isOpen, false);
    await ptp.close();
    for (final s in sockets) {
      s.destroy();
    }
    await server.close();
  });
}
