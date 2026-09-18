import 'package:flutter_test/flutter_test.dart';
import 'package:mirrorbridge/repositories/nikon_repository.dart';

void main() {
  test(
    'fresh LAN discovery covers unknown camera and excludes IPv6, self and stale subnets',
    () {
      final candidates = nikonDiscoveryCandidates({
        'interfaces': [
          {'address': '192.168.2.43', 'prefix': 24},
        ],
        'candidates': ['::', 'fe80::1', '192.168.2.1', '192.168.1.1'],
      }, []);
      expect(candidates, contains('192.168.2.45'));
      expect(candidates, hasLength(253));
      expect(candidates, isNot(contains('192.168.2.43')));
      expect(candidates.where((a) => !a.startsWith('192.168.2.')), isEmpty);
      expect(candidates.take(8).toList().indexOf('192.168.2.45'), lessThan(8));
    },
  );
  test('prefix boundaries and leading-zero IP are normalized', () {
    final c = nikonDiscoveryCandidates(
      {
        'interfaces': [
          {'address': '192.168.2.5', 'prefix': 29},
        ],
        'candidates': [],
      },
      ['192.168.002.006', '192.168.2.99'],
    );
    expect(c.first, '192.168.2.6');
    expect(c, hasLength(5));
    expect(c, isNot(contains('192.168.2.0')));
    expect(c, isNot(contains('192.168.2.7')));
  });
  test(
    'Wi-Fi hotspot and third private interface all probe in first batch',
    () {
      final c = nikonDiscoveryCandidates({
        'interfaces': [
          {'address': '192.168.0.9', 'prefix': 23},
          {'address': '192.168.43.1', 'prefix': 24},
          {'address': '172.20.1.1', 'prefix': 30},
        ],
      }, []);
      expect(c, contains('192.168.1.254'));
      expect(c, contains('192.168.43.254'));
      expect(c, contains('172.20.1.2'));
      expect(c.take(8).any((ip) => ip.startsWith('192.168.43.')), true);
      expect(c.take(8), contains('172.20.1.2'));
      expect(c.length, c.toSet().length);
    },
  );
  test(
    'wide network remains lazy and overlapping interfaces do not duplicate',
    () {
      final c = nikonDiscoveryCandidates({
        'interfaces': [
          {'address': '10.0.0.1', 'prefix': 8},
          {'address': '192.168.43.1', 'prefix': 24},
        ],
      }, []);
      expect(c.length, 16777213 + 253);
      expect(c.take(4), contains('192.168.43.2'));
      final overlap = nikonDiscoveryCandidates({
        'interfaces': [
          {'address': '192.168.1.2', 'prefix': 29},
          {'address': '192.168.1.3', 'prefix': 30},
        ],
      }, []);
      expect(overlap.toSet().length, overlap.length);
    },
  );
}
