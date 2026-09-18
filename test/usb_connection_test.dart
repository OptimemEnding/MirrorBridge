import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirrorbridge/protocol/ptp.dart';
import 'package:mirrorbridge/repositories/nikon_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final scenario in ['busy_then_valid', 'unsupported', 'truncated']) {
    test(
      'USB production connection handles DeviceInfo $scenario using real descriptor identity',
      () async {
        var attempts = 0;
        var serviceActive = false;
        var storageCalls = 0;
        messenger.setMockMethodCallHandler(
          const MethodChannel('mirrorbridge/native_events'),
          (_) async => null,
        );
        messenger.setMockMethodCallHandler(nativeCamera, (call) async {
          switch (call.method) {
            case 'directories':
              return {
                'media': '/fixture',
                'cache': '/fixture',
                'freeBytes': 100000000,
              };
            case 'usbPermission':
              return true;
            case 'service':
              serviceActive = (call.arguments as Map)['active'] == true;
              return null;
            case 'usbOpen':
              expect(
                serviceActive,
                true,
                reason:
                    'Browsing keeps the connection service active before opening the camera',
              );
              return {
                'make': 'Nikon',
                'model': 'Z 8',
                'serial': 'USB-Z8-FIXTURE',
                'vendorId': 1200,
              };
            case 'usbData':
              final code = (call.arguments as Map)['code'];
              if (code == 0x1004) {
                storageCalls++;
                return ptpWords([0]);
              }
              if (code == 0x1001) {
                attempts++;
                if (scenario == 'unsupported' ||
                    (scenario == 'busy_then_valid' && attempts == 1)) {
                  throw PlatformException(
                    code: 'PTP_RESPONSE',
                    details: {
                      'operation': 0x1001,
                      'response': scenario == 'unsupported' ? 0x2005 : 0x2019,
                    },
                  );
                }
                if (scenario == 'truncated') {
                  return Uint8List.fromList([100, 0]);
                }
                List<int> str(String s) => [
                  s.length + 1,
                  for (final c in s.codeUnits) ...ptpU16(c),
                  0,
                  0,
                ];
                return Uint8List.fromList([
                  ...ptpU16(100),
                  ...ptpWords([10]),
                  ...ptpU16(100),
                  0,
                  ...ptpU16(0),
                  for (var i = 0; i < 5; i++) ...ptpWords([0]),
                  ...str('Nikon'),
                  ...str('Z 8'),
                  ...str('1.0'),
                  ...str('USB-Z8-FIXTURE'),
                ]);
              }
              throw StateError('Unexpected operation $code');
            default:
              return null;
          }
        });
        final repo = NikonRepository()..mode = 'USB';
        try {
          expect(await repo.connect('/dev/bus/usb/fixture'), isEmpty);
          expect(repo.device!.model, 'Z 8');
          expect(serviceActive, true);
          expect(repo.device!.serial, 'USB-Z8-FIXTURE');
          expect(repo.device!.operations, isEmpty);
          expect(storageCalls, 1);
          expect(attempts, scenario == 'busy_then_valid' ? 2 : 1);
        } finally {
          await repo.dispose();
          expect(serviceActive, false);
          messenger.setMockMethodCallHandler(nativeCamera, null);
          messenger.setMockMethodCallHandler(
            const MethodChannel('mirrorbridge/native_events'),
            null,
          );
        }
      },
    );
  }
}
