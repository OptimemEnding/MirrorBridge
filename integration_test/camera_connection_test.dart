// Opt-in physical-camera connection diagnostic. Does not capture/delete/download media.
// flutter test integration_test/camera_connection_test.dart -d DEVICE --dart-define=CAMERA_IP=IP
// USB: add --dart-define=CAMERA_MODE=USB, CAMERA_IP is not needed.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mirrorbridge/app.dart';
import 'package:mirrorbridge/protocol/ptp.dart';
import 'package:mirrorbridge/repositories/nikon_repository.dart';
import 'package:mirrorbridge/state/app_controller.dart';

class DiagnosticNikonRepository extends NikonRepository {
  @override
  void log(String text) {
    super.log(text);
    debugPrint('CAMERA_TRACE $text');
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'physical camera discovery and retained session',
    (tester) async {
      const mode = String.fromEnvironment('CAMERA_MODE', defaultValue: 'STA');
      var endpoint = const String.fromEnvironment('CAMERA_IP');
      if (mode == 'USB') {
        final devices = await nativeCamera.invokeListMethod<dynamic>('usbList');
        expect(devices, isNotEmpty, reason: 'No Nikon USB device attached');
        endpoint = (devices!.first as Map)['deviceId'] as String;
      }
      expect(
        endpoint,
        isNotEmpty,
        reason: 'Pass the physical camera IP explicitly',
      );
      final repo = DiagnosticNikonRepository();
      final controller = AppController(repo)
        ..mode = mode
        ..live = false
        ..receivePush = false;
      try {
        await tester.pumpWidget(MirrorBridgeApp(controller: controller));
        await tester.pumpAndSettle();
        if (const bool.fromEnvironment('CAMERA_DISCOVER')) {
          final found = await repo.discover(
            mode,
            const bool.fromEnvironment('CAMERA_NO_HINT') ? [] : [endpoint],
          );
          expect(found, isNotEmpty);
          expect(found.first['deviceId'], endpoint);
          debugPrint('CAMERA_DISCOVERY_RETAINED_SESSION_OK');
        }
        final retained = repo.transport;
        final ok = await controller.connect(endpoint);
        if (const bool.fromEnvironment('CAMERA_DISCOVER')) {
          expect(identical(retained, repo.transport), true);
        }
        debugPrint('CAMERA_CONNECT_RESULT=$ok message=${controller.message}');
        expect(ok, true, reason: controller.message);
        debugPrint(
          'CAMERA_MODEL=${repo.device?.model} MEDIA=${repo.media.length} STORAGE=${repo.storages.length}',
        );
        debugPrint('CAMERA_BACKGROUND_READY');
        await tester.runAsync(
          () => Future<void>.delayed(
            Duration(
              seconds: const bool.fromEnvironment('CAMERA_BACKGROUND')
                  ? 65
                  : 25,
            ),
          ),
        );
        debugPrint('CAMERA_BACKGROUND_WAIT_COMPLETE');
        expect(controller.connected, true, reason: controller.message);
        await repo.refresh();
        debugPrint('CAMERA_RETAINED_SESSION_OK');
      } finally {
        await tester.pumpWidget(const SizedBox());
        await repo.dispose();
        controller.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
