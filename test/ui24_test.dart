import 'package:flutter_test/flutter_test.dart';
import 'package:mirrorbridge/models/nikon_monitor_values.dart';
import 'package:mirrorbridge/models/exif_labels.dart';
import 'package:mirrorbridge/repositories/nikon_repository.dart';

class BatteryFixture extends NikonRepository {
  int value = 68;
  @override
  Future<Map<String, dynamic>> property(int code) async => {
    'code': code,
    'type': 2,
    'current': value,
    'values': [0, 100],
    'writable': false,
  };
}

void main() {
  test(
    'shutter wheel orders B T then timed exposures from longest to shortest',
    () {
      final rational = [
        65537,
        (1 << 16) | 125,
        (30 << 16) | 1,
        (13 << 16) | 10,
        0xffffffff,
        0xfffffffe,
        (1 << 16) | 2,
      ];
      rational.sort(
        (a, b) => compareShutterLongestFirst(a, b, propertyCode: 0xd100),
      );
      expect(
        rational.map((v) => nikonMonitorValue(0x500d, v, propertyCode: 0xd100)),
        ['B 门', 'T 门', '30s', '1.3s', '1s', '1/2s', '1/125s'],
      );
      final standard = [10000, 80, 300000, 5000, 0xffffffff];
      standard.sort(compareShutterLongestFirst);
      expect(standard, [0xffffffff, 300000, 10000, 5000, 80]);
    },
  );
  test('nominal exposure labels match across monitor and EXIF', () {
    expect(nikonMonitorValue(0x500d, 78), '1/125s');
    expect(
      nikonMonitorValue(0x500d, (1 << 16) | 128, propertyCode: 0xd1a8),
      '1/125s',
    );
    expect(nikonMonitorValue(0x5007, 356), 'f/3.5');
    expect(nikonMonitorValue(0x500f, 397), '400');
    for (final value in [1250, 2500, 5000, 10000, 12800, 25600, 51200]) {
      expect(nikonMonitorValue(0x500f, value), '$value');
    }
    expect(nikonMonitorValue(0x500f, 1280), '1250');
    expect(exifValue('ExposureTime', '1/128'), '1/125s');
    expect(exifValue('FNumber', '356/100'), 'f/3.5');
    expect(exifValue('PhotographicSensitivity', '397'), '400');
    expect(nikonMonitorValue(0x500d, 0xfffffffe), 'T 门');
  });
  test(
    'half-stop ISO and aperture choices are filtered without changing payload',
    () {
      expect(isThirdStopChoice(0x500f, 140), false);
      expect(isThirdStopChoice(0x500f, 125), true);
      expect(isThirdStopChoice(0x500f, 128), true);
      expect(isThirdStopChoice(0x5007, 240), false);
      expect(isThirdStopChoice(0x5007, 250), true);
      for (final value in [125, 160, 200, 250, 320, 400, 500, 640, 800, 1000]) {
        expect(
          isThirdStopChoice(0x500d, (1 << 16) | value, propertyCode: 0xd1a8),
          true,
        );
      }
    },
  );
  test(
    'camera battery rejects missing sentinels instead of displaying 255 percent',
    () async {
      final camera = BatteryFixture();
      expect(await camera.readBatteryLevel(), 68);
      camera.value = 0;
      expect(await camera.readBatteryLevel(), 0);
      camera.value = 255;
      expect(await camera.readBatteryLevel(), isNull);
    },
  );
}
