import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:mirrorbridge/protocol/ptp.dart';
import 'package:mirrorbridge/repositories/nikon_repository.dart';

class CameraPeer {
  late ServerSocket server;
  final sockets = <Socket>[];
  final calls = <int>[];
  final requests = <({int phase, int op, int tx})>[];
  final rejectedWire = <String>[];
  bool strict = true;
  bool allowZeroTransaction = false;
  String? disconnectStage;
  final wireRequests = <Uint8List>[];
  bool sendInitialEvent = true;
  bool answerPings = true;
  Socket? eventSocket;
  int pingCount = 0;
  final payloads = <int, Uint8List>{};
  int? reject, badTransaction;
  final unavailableStorages = <int>{};
  bool wrongLength = false;
  int? outgoingTx;
  Uint8List? uploaded;
  Future<void> start({int port = 0}) async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    server.listen((socket) {
      socket.done.ignore();
      sockets.add(socket);
      var bytes = <int>[];
      socket.listen((chunk) {
        bytes.addAll(chunk);
        while (bytes.length >= 8) {
          final header = PtpReader(bytes.sublist(0, 8));
          final length = header.u32(), type = header.u32();
          if (bytes.length < length) return;
          final payload = Uint8List.fromList(bytes.sublist(8, length));
          bytes = bytes.sublist(length);
          receive(socket, type, payload);
        }
      }, onError: (_) {});
    });
  }

  void send(
    Socket socket,
    int type,
    List<int> data, {
    bool fragmented = false,
  }) {
    final packet = PtpIpTransport.packet(type, data);
    if (!fragmented) {
      socket.add(packet);
      return;
    }
    socket.add(packet.sublist(0, 3));
    socket.add(packet.sublist(3, 9));
    socket.add(packet.sublist(9));
  }

  void response(Socket s, int tx, int rc) => send(s, 7, [
    ...ptpU16(rc),
    ...ptpWords([tx]),
  ], fragmented: true);
  void receive(Socket socket, int type, Uint8List payload) {
    if (type == 1) {
      if (disconnectStage == 'init') {
        socket.destroy();
        return;
      }
      send(socket, 2, ptpWords([77]), fragmented: true);
      return;
    }
    if (type == 3) {
      if (disconnectStage == 'event') {
        socket.destroy();
        return;
      }
      eventSocket = socket;
      send(socket, 4, []);
      if (sendInitialEvent) {
        send(socket, 8, [
          ...ptpU16(0x4002),
          ...ptpWords([0, 42]),
        ]);
      }
      return;
    }
    if (type == 13) {
      pingCount++;
      if (answerPings) send(socket, 14, []);
      return;
    }
    if (type == 12 && outgoingTx != null) {
      uploaded = payload.sublist(4);
      response(socket, outgoingTx!, 0x2001);
      outgoingTx = null;
      return;
    }
    if (type != 6) return;
    final r = PtpReader(payload);
    final phase = r.u32(), op = r.u16(), tx = r.u32();
    calls.add(op);
    wireRequests.add(PtpIpTransport.packet(type, payload));
    if (op == 0x1002 && disconnectStage == 'session') {
      socket.destroy();
      return;
    }
    requests.add((phase: phase, op: op, tx: tx));
    if (op == 0x1005 && unavailableStorages.contains(r.u32())) {
      response(socket, tx, 0x2013);
      return;
    }
    // Protocol fixture derived from PIMA 15740: pre-increment tx (first 1),
    // DataPhaseInfo=1 for commands AND reads; only outgoing data uses 2.
    if (strict &&
        ((tx == 0 && !allowZeroTransaction) || (phase != 1 && phase != 2))) {
      rejectedWire.add('op=0x${op.toRadixString(16)} tx=$tx phase=$phase');
      socket.destroy();
      return;
    }
    if (op == reject) {
      response(socket, tx, 0x2005);
      return;
    }
    if (phase == 2) {
      outgoingTx = tx;
      return;
    }
    final content = payloads[op];
    if (content != null) {
      send(
        socket,
        9,
        ptpWords([tx, content.length + (wrongLength ? 1 : 0), 0]),
      );
      var offset = 0;
      while (offset < content.length) {
        final end = (offset + 32000).clamp(0, content.length);
        send(socket, end == content.length ? 12 : 10, [
          ...ptpWords([tx]),
          ...content.sublist(offset, end),
        ], fragmented: true);
        offset = end;
      }
    }
    response(socket, op == badTransaction ? tx + 1 : tx, 0x2001);
  }

  Future<void> close() async {
    for (final s in sockets) {
      s.destroy();
    }
    await server.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'USB preserves DeviceBusy response instead of parsing fake empty data',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var attempts = 0;
      messenger.setMockMethodCallHandler(nativeCamera, (call) async {
        if (call.method == 'usbData') {
          attempts++;
          if (attempts == 1) {
            throw PlatformException(
              code: 'PTP_RESPONSE',
              details: {'operation': 0x1001, 'response': 0x2019},
            );
          }
          return Uint8List.fromList([1, 2]);
        }
        return null;
      });
      try {
        final usb = UsbPtpTransport();
        await expectLater(
          usb.data(0x1001),
          throwsA(
            isA<PtpException>().having((e) => e.response, 'response', 0x2019),
          ),
        );
        expect(await usb.data(0x1001), [1, 2]);
      } finally {
        messenger.setMockMethodCallHandler(nativeCamera, null);
      }
    },
  );
  test(
    'DeviceInfo permits missing trailing serial but rejects truncated capabilities',
    () {
      List<int> str(String s) => [
        s.length + 1,
        for (final c in s.codeUnits) ...ptpU16(c),
        0,
        0,
      ];
      final bytes = Uint8List.fromList([
        ...ptpU16(100),
        ...ptpWords([10]),
        ...ptpU16(100),
        0,
        ...ptpU16(0),
        for (var i = 0; i < 5; i++) ...ptpWords([0]),
        ...str('Nikon'),
        ...str('Z 8'),
        ...str('1.0'),
      ]);
      final info = PtpDeviceInfo.parse(bytes);
      expect(info.model, 'Z 8');
      expect(info.serial, '');
      expect(
        () => PtpDeviceInfo.parse(Uint8List.sublistView(bytes, 0, 16)),
        throwsFormatException,
      );
    },
  );
  test('PTP reader rejects truncated arrays and strings', () {
    expect(() => PtpReader([2, 65]).string(), throwsFormatException);
    expect(() => PtpReader(ptpWords([1000])).array32(), throwsFormatException);
    expect(() => PtpReader([1, 2, 3]).u64(), throwsFormatException);
  });
  test(
    'ObjectInfo preserves unsigned size, storage, folder, dimensions and date',
    () {
      final header = ByteData(52)
        ..setUint32(0, 0x10001, Endian.little)
        ..setUint16(4, 0x3801, Endian.little)
        ..setUint32(8, 0xfffffffe, Endian.little)
        ..setUint32(26, 8256, Endian.little)
        ..setUint32(30, 5504, Endian.little)
        ..setUint32(38, 5, Endian.little);
      List<int> str(String s) => [
        s.length + 1,
        for (final c in s.codeUnits) ...[c, 0],
        0,
        0,
      ];
      final info = PtpObjectInfo.parse(
        Uint8List.fromList([
          ...header.buffer.asUint8List(),
          ...str('DSC_1234.JPG'),
          ...str('20260910T183015'),
        ]),
      );
      expect(info.bytes, 4294967294);
      expect(info.width, 8256);
      expect(info.height, 5504);
      expect(info.parent, 5);
      expect(info.name, 'DSC_1234.JPG');
      expect(info.date, DateTime(2026, 9, 10, 18, 30, 15));
    },
  );
  test('RAW/live-view JPEG extraction requires a complete image boundary', () {
    expect(
      extractJpeg(Uint8List.fromList([0, 1, 255, 216, 1, 2, 255, 217, 0])),
      [255, 216, 1, 2, 255, 217],
    );
    expect(extractJpeg(Uint8List.fromList([255, 216, 1])), isNull);
  });
  test('media keys separate devices and same-name files', () {
    expect(
      stableMediaKey('Nikon:A:DSC.JPG'),
      stableMediaKey('Nikon:A:DSC.JPG'),
    );
    expect(
      stableMediaKey('Nikon:A:DSC.JPG'),
      isNot(stableMediaKey('Nikon:B:DSC.JPG')),
    );
  });
  test(
    'handshake failures identify the actual stage and close both sockets',
    () async {
      for (final entry in {
        'init': 'InitCommandRequest / 等待相机确认',
        'event': 'InitEventRequest / 等待事件确认',
        'session': 'OpenSession',
      }.entries) {
        final camera = CameraPeer()..disconnectStage = entry.key;
        await camera.start();
        final messages = <String>[];
        final client = PtpIpTransport(log: messages.add);
        try {
          await expectLater(
            client.open(
              '127.0.0.1',
              List.filled(16, 1),
              port: camera.server.port,
            ),
            throwsA(
              isA<PtpConnectionException>().having(
                (e) => e.stage,
                'stage',
                entry.value,
              ),
            ),
          );
          expect(client.isOpen, false);
          expect(
            messages.any(
              (line) => line.contains('connect failed stage=${entry.value}'),
            ),
            true,
          );
        } finally {
          await client.close();
          await camera.close();
        }
      }
    },
  );
  test(
    'silent event socket still delivers events after the former 20-second cutoff',
    () async {
      final camera = CameraPeer()
        ..sendInitialEvent = false
        ..answerPings = false;
      await camera.start();
      final received = Completer<int>();
      final client = PtpIpTransport(
        onEvent: (code, _) {
          if (!received.isCompleted) received.complete(code);
        },
      );
      try {
        await client.open(
          '127.0.0.1',
          List.filled(16, 1),
          port: camera.server.port,
        );
        await Future<void>.delayed(const Duration(seconds: 21));
        camera.send(camera.eventSocket!, 8, [
          ...ptpU16(0x4009),
          ...ptpWords([0, 7]),
        ]);
        expect(
          await received.future.timeout(const Duration(seconds: 2)),
          0x4009,
        );
        expect(client.isOpen, true);
        expect(camera.pingCount, greaterThanOrEqualTo(1));
      } finally {
        await client.close();
        await camera.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
  test(
    'event EOF notifies disconnect and invalidates command transport',
    () async {
      final camera = CameraPeer();
      await camera.start();
      final ended = Completer<String>();
      final client = PtpIpTransport(onClosed: ended.complete);
      try {
        await client.open(
          '127.0.0.1',
          List.filled(16, 1),
          port: camera.server.port,
        );
        camera.eventSocket!.destroy();
        expect(
          await ended.future.timeout(const Duration(seconds: 2)),
          contains('事件通道'),
        );
        expect(client.isOpen, false);
      } finally {
        await client.close();
        await camera.close();
      }
    },
  );
  group('PTP/IP real socket peer', () {
    late CameraPeer peer;
    late PtpIpTransport ptp;
    final events = <int>[];
    setUp(() async {
      peer = CameraPeer();
      await peer.start();
      events.clear();
      ptp = PtpIpTransport(onEvent: (code, _) => events.add(code));
      await ptp.open('127.0.0.1', List.filled(16, 1), port: peer.server.port);
    });
    tearDown(() async {
      await ptp.close();
      await peer.close();
    });
    test(
      'command and event initialization, fragmented data and serial transactions',
      () async {
        final content = Uint8List.fromList(
          List.generate(200000, (i) => i % 251),
        );
        peer.payloads[0x1001] = content;
        final results = await Future.wait([ptp.data(0x1001), ptp.data(0x1001)]);
        expect(results[0], content);
        expect(results[1], content);
        expect(peer.calls, [0x1002, 0x1001, 0x1001]);
        expect(events, contains(0x4002));
      },
    );
    test(
      'wire bytes follow PIMA 15740 for OpenSession and GetStorageIDs',
      () async {
        await ptp.data(0x1004);
        final hex = peer.wireRequests
            .expand((b) => b)
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        expect(
          hex,
          '16000000060000000100000002100100000001000000'
          '120000000600000001000000041002000000',
        );
        expect(peer.rejectedWire, isEmpty);
      },
    );
    test('unsupported operation keeps the session usable', () async {
      peer.reject = 0x9431;
      await expectLater(
        ptp.data(0x9431),
        throwsA(
          isA<PtpException>().having((e) => e.unsupported, 'unsupported', true),
        ),
      );
      await ptp.command(0x90c2, [0]);
      expect(peer.calls.last, 0x90c2);
    });
    test('response transaction mismatch invalidates the connection', () async {
      peer.badTransaction = 0x1004;
      await expectLater(ptp.data(0x1004), throwsFormatException);
      await expectLater(ptp.data(0x1004), throwsA(isA<SocketException>()));
    });
    test('declared data length mismatch cannot report success', () async {
      peer.payloads[0x100a] = Uint8List.fromList([1, 2, 3]);
      peer.wrongLength = true;
      await expectLater(ptp.data(0x100a), throwsFormatException);
    });
    test(
      'SetDevicePropValue sends a data-out phase with exact bytes',
      () async {
        await ptp.writeProperty(0x500f, Uint8List.fromList([0x20, 0x03]));
        expect(peer.uploaded, [0x20, 0x03]);
      },
    );
    test(
      'streamed camera file matches every byte and reports final progress',
      () async {
        final dir = await Directory.systemTemp.createTemp(
          'mirrorbridge-ptp-test-',
        );
        try {
          final content = Uint8List.fromList(
            List.generate(1024 * 1024 + 13, (i) => i % 253),
          );
          peer.payloads[0x1009] = content;
          final file = File('${dir.path}/download.part');
          final sink = file.openWrite();
          var done = 0;
          await ptp.download(0x1009, [1], sink, (n) => done = n, () => false);
          await sink.close();
          expect(await file.readAsBytes(), content);
          expect(done, content.length);
        } finally {
          await dir.delete(recursive: true);
        }
      },
    );
    test(
      'cancellation interrupts the data stream rather than marking completion',
      () async {
        final dir = await Directory.systemTemp.createTemp(
          'mirrorbridge-ptp-cancel-',
        );
        try {
          peer.payloads[0x1009] = Uint8List(1024 * 1024);
          final file = File('${dir.path}/cancel.part');
          final sink = file.openWrite();
          var cancelled = false;
          await expectLater(
            ptp.download(0x1009, [1], sink, (n) {
              if (n > 64000) cancelled = true;
            }, () => cancelled),
            throwsStateError,
          );
          await sink.close();
          expect(await file.length(), lessThan(1024 * 1024));
        } finally {
          await dir.delete(recursive: true);
        }
      },
    );
  });
}
