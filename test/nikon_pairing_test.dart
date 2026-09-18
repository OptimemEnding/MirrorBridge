import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirrorbridge/protocol/ptp.dart';
import 'package:mirrorbridge/repositories/nikon_repository.dart';
import 'ptp_test.dart' show CameraPeer;
import 'support/ptp_fixtures.dart';

class PairingPeer extends CameraPeer {
  bool confirmed = false;
  bool rejectConfirmation = false;
  int deferredTransfers = 0;
  int busyStorageReads = 0;
  late Uint8List pairingInfo, transferInfo;
  @override
  void receive(Socket socket, int type, Uint8List payload) {
    // Model a camera that saves pairing but does not accept transfer sessions
    // until the user has dismissed its pairing-complete screen.
    if (type == 1 && confirmed && deferredTransfers-- > 0) {
      socket.destroy();
      return;
    }
    if (type == 6) {
      final r = PtpReader(payload);
      r.u32();
      final op = r.u16();
      final tx = r.u32();
      if (op == 0x1004 && busyStorageReads-- > 0) {
        response(socket, tx, 0x2019);
        return;
      }
      if (op == 0x1001) payloads[op] = confirmed ? transferInfo : pairingInfo;
      if (op == 0x935a) {
        expect(r.u32(), 0x2001);
        if (rejectConfirmation) {
          reject = op;
        } else {
          confirmed = true;
        }
      }
    }
    super.receive(socket, type, payload);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('InitFail reason 1 retains actionable re-pairing guidance', () {
    final message = PtpConnectionException(
      'InitCommandRequest',
      '192.168.2.45:15740',
      PtpInitRejected(1),
    ).toString();
    expect(message, contains('InitFail reason=1'));
    expect(message, contains('在相机上忘记此连接，再重新创建连接'));
  });
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final scenario in [
    'ready',
    'rejected',
    'camera-confirmation',
    'storage-retry',
  ]) {
    final reject = scenario == 'rejected';
    final deferred = scenario == 'camera-confirmation';
    final storageRetry = scenario == 'storage-retry';
    test(
      'STA pairing $scenario ${reject ? "rejection never reports connection" : "reopens transfer with verified sequence"}',
      () async {
        final dir = await Directory.systemTemp.createTemp('nikon-pairing-');
        final peer = PairingPeer()
          ..allowZeroTransaction = true
          ..rejectConfirmation = reject
          ..deferredTransfers = deferred ? 2 : 0
          ..busyStorageReads = storageRetry ? 1 : 0
          ..pairingInfo = syntheticDeviceInfo(transferReady: false)
          ..transferInfo = syntheticDeviceInfo(transferReady: true);
        peer.payloads[0x952b] = Uint8List.fromList([4, 0, 0, 0, 1, 9, 7, 1]);
        peer.payloads[0x941c] = ptpWords([0]);
        peer.payloads[0x1004] = ptpWords([0]);
        await peer.start(port: 15740);
        var active = false;
        messenger.setMockMethodCallHandler(
          const MethodChannel('mirrorbridge/native_events'),
          (_) async => null,
        );
        messenger.setMockMethodCallHandler(nativeCamera, (call) async {
          if (call.method == 'directories') {
            return {'media': dir.path, 'cache': dir.path};
          }
          if (call.method == 'network') {
            return {'clientName': 'REDMI'};
          }
          if (call.method == 'service') {
            active = (call.arguments as Map)['active'] == true;
          }
          return null;
        });
        final repo = NikonRepository()..mode = 'STA';
        final confirmationStates = <bool>[];
        repo.onConnectionStage = (_) {
          if (repo.pairingInProgress) {
            confirmationStates.add(repo.awaitingCameraConfirmation);
          }
        };
        try {
          if (reject) {
            await expectLater(
              repo.connect('127.0.0.1'),
              throwsA(isA<PtpException>()),
            );
            expect(repo.device, isNull);
            expect(active, false);
            expect(peer.calls, [0x1002, 0x1001, 0x952b, 0x935a]);
          } else {
            await repo.connect('127.0.0.1');
            expect(repo.device!.model, 'Z 8');
            expect(peer.calls.take(7), [
              0x1002,
              0x1001,
              0x952b,
              0x935a,
              0x1001,
              0x1002,
              0x941c,
            ]);
            expect(peer.requests.take(7).map((r) => r.tx), [
              0,
              1,
              2,
              3,
              0,
              0,
              1,
            ]);
            expect(peer.sockets, hasLength(deferred || storageRetry ? 6 : 4));
            expect(peer.calls.where((op) => op == 0x935a), hasLength(1));
            if (deferred) {
              expect(
                repo.logs.where((s) => s.contains('post-pairing reconnect')),
                hasLength(2),
              );
              expect(repo.logs.any((s) => s.contains('按 OK／确认键')), true);
            }
            expect(active, true);
            expect(repo.pairingInProgress, false);
            expect(repo.awaitingCameraConfirmation, false);
            if (storageRetry) {
              expect(confirmationStates, contains(true));
              final readyIndex = confirmationStates.indexOf(false);
              expect(readyIndex, greaterThan(0));
              expect(confirmationStates.skip(readyIndex), everyElement(false));
              expect(
                repo.logs.where((s) => s.contains('post-pairing reconnect')),
                hasLength(1),
              );
            }
            expect(
              repo.logs.any(
                (s) => s.contains('pairing confirmed; transfer session ready'),
              ),
              true,
            );
          }
        } finally {
          await repo.dispose();
          await peer.close();
          expect(active, false);
          messenger.setMockMethodCallHandler(nativeCamera, null);
          messenger.setMockMethodCallHandler(
            const MethodChannel('mirrorbridge/native_events'),
            null,
          );
          await dir.delete(recursive: true);
        }
      },
    );
  }
  test('truncated pairing status cannot advance to confirmation', () {
    expect(
      () => validateNikonPairingStatus(Uint8List.fromList([4, 0, 0, 0, 1])),
      throwsFormatException,
    );
    expect(
      () => validateNikonPairingStatus(
        Uint8List.fromList([4, 0, 0, 0, 1, 9, 7, 1]),
      ),
      returnsNormally,
    );
  });
}
