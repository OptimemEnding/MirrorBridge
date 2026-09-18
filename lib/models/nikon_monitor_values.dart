import 'dart:math' as math;

String exposureNumber(num n) =>
    n.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
const thirdStopShutter = <double>[
  1,
  1.3,
  1.6,
  2,
  2.5,
  3,
  4,
  5,
  6,
  8,
  10,
  13,
  15,
  20,
  25,
  30,
  40,
  50,
  60,
  80,
  100,
  125,
  160,
  200,
  250,
  320,
  400,
  500,
  640,
  800,
  1000,
  1250,
  1600,
  2000,
  2500,
  3200,
  4000,
  5000,
  6400,
  8000,
  10000,
  12800,
  16000,
  20000,
  25600,
  32000,
];
const thirdStopAperture = <double>[
  .7,
  .8,
  .9,
  1,
  1.1,
  1.2,
  1.4,
  1.6,
  1.8,
  2,
  2.2,
  2.5,
  2.8,
  3.2,
  3.5,
  4,
  4.5,
  5,
  5.6,
  6.3,
  7.1,
  8,
  9,
  10,
  11,
  13,
  14,
  16,
  18,
  20,
  22,
  25,
  29,
  32,
  36,
  40,
  45,
  51,
  57,
  64,
];
const thirdStopIso = <double>[
  6,
  8,
  10,
  12,
  16,
  20,
  25,
  32,
  40,
  50,
  64,
  80,
  100,
  125,
  160,
  200,
  250,
  320,
  400,
  500,
  640,
  800,
  1000,
  1250,
  1600,
  2000,
  2500,
  3200,
  4000,
  5000,
  6400,
  8000,
  10000,
  12800,
  16000,
  20000,
  25600,
  32000,
  40000,
  51200,
  64000,
  80000,
  102400,
  128000,
  160000,
  204800,
  256000,
  320000,
  409600,
  512000,
  640000,
  819200,
  1024000,
  1280000,
  1638400,
  2048000,
  2560000,
  3276800,
];
double nominalExposure(double value, List<double> stops) => stops.reduce(
  (a, b) => math.log(a / value).abs() <= math.log(b / value).abs() ? a : b,
);
String shutterLabel(double seconds) {
  if (seconds <= 0 || !seconds.isFinite) return '未提供快门';
  return seconds < 1
      ? '1/${exposureNumber(nominalExposure(1 / seconds, thirdStopShutter))}s'
      : '${exposureNumber(nominalExposure(seconds, thirdStopShutter))}s';
}

String isoLabel(int value) =>
    nominalExposure(value.toDouble(), thirdStopIso).round().toString();

/// B/T precede timed exposures; rational packed values must not be sorted as integers.
int compareShutterLongestFirst(int a, int b, {int? propertyCode}) {
  double seconds(int value) {
    if (value == 0xffffffff) return double.infinity;
    if (value == 0xfffffffe) return double.maxFinite;
    if (propertyCode == 0xd100 || propertyCode == 0xd1a8) {
      final denominator = value & 0xffff;
      return denominator == 0 ? 0 : (value >> 16) / denominator;
    }
    return value / 10000;
  }

  return seconds(b).compareTo(seconds(a));
}

/// Nikon/PTP values shared by the monitor panel and every parameter picker.
/// Vendor enums are property-specific; never interpret an unknown value as a mode.
String nikonMonitorValue(int code, int value, {int? propertyCode}) {
  final actual = propertyCode ?? code;
  String unknown() => '未知选项（0x${value.toRadixString(16).toUpperCase()}）';
  if (code == 0x500a && (actual == 0xd061 || actual == 0xd1fa)) {
    return const {
          0: '单次 AF-S',
          1: '连续 AF-C',
          2: '全时 AF-F',
          3: '手动 MF（固定）',
          4: '手动 MF',
        }[value] ??
        unknown();
  }
  const enums = <int, Map<int, String>>{
    0xd1a6: {0: '照片取景', 1: '视频取景'},
    0x500a: {
      0: '未定义',
      1: '手动 MF',
      2: '自动对焦',
      3: '微距自动对焦',
      0x8010: '单次 AF-S',
      0x8011: '连续 AF-C',
      0x8012: '自动 AF-A',
      0x8013: '全时 AF-F',
    },
    0x500b: {1: '平均测光', 2: '中央重点', 3: '矩阵测光', 4: '点测光', 0x8010: '亮部重点'},
    0x5005: {
      1: '手动',
      2: '自动',
      3: '单次自动',
      4: '日光',
      5: '荧光灯',
      6: '白炽灯',
      7: '闪光灯',
      0x8010: '阴天',
      0x8011: '阴影',
      0x8012: '色温',
      0x8013: '预设手动',
      0x8014: '关闭',
      0x8015: '闪光灯',
      0x8016: '自然光自动',
    },
    0x500e: {
      1: '手动 M',
      2: '程序自动 P',
      3: '光圈优先 A',
      4: '快门优先 S',
      0x8010: '自动',
      0x8011: '人像',
      0x8012: '风景',
      0x8013: '微距',
      0x8014: '运动',
      0x8015: '夜间人像',
      0x8016: '夜景',
    },
  };
  if (enums.containsKey(code)) return enums[code]![value] ?? unknown();
  if (code == 0x5010) return '${(value / 1000).toStringAsFixed(1)} EV';
  if (code == 0x5007) {
    return value == 0
        ? '未提供光圈'
        : 'f/${exposureNumber(nominalExposure(value / 100, thirdStopAperture))}';
  }
  if (code == 0x500f) {
    return value == 0 || value == 0xffff || value == 0xffffffff
        ? '自动 ISO'
        : isoLabel(value);
  }
  if (code == 0x500d) {
    if (value == 0xffffffff) return 'B 门';
    if (value == 0xfffffffe) return 'T 门';
    if (actual == 0xd100 || actual == 0xd1a8) {
      final numerator = value >> 16, denominator = value & 0xffff;
      if (numerator == 0 || denominator == 0) return '未提供快门';
      return shutterLabel(numerator / denominator);
    }
    if (value <= 0) return '未提供快门';
    return shutterLabel(value / 10000);
  }
  return unknown();
}

List<int> nikonMonitorProperties(int code, {required bool movie}) {
  const video = {
    0x500f: 0xd1aa,
    0x5007: 0xd1a9,
    0x500d: 0xd1a8,
    0x5010: 0xd1ab,
    0x5005: 0xd23a,
    0x500a: 0xd1fa,
    0x500b: 0xd1af,
  };
  return [
    if (movie && video.containsKey(code)) video[code]!,
    if (code == 0x500f) 0xd0b4,
    if (code == 0x500d) 0xd100,
    if (code == 0x500a && !movie) 0xd061,
    code,
  ];
}

/// Exposure-program ownership is independent from camera descriptor writability.
bool nikonExposureControls(int code, int? mode) {
  if (code == 0x500f) return true;
  if (code == 0x500d) return mode != 2 && mode != 3 && mode != 0x8010;
  if (code == 0x5007) return mode != 2 && mode != 4 && mode != 0x8010;
  return true;
}

/// Filter half-stop descriptor entries, while accepting nominal and rational encodings.
bool isThirdStopChoice(int code, int value, {int? propertyCode}) {
  if (value <= 0 ||
      value >= 0xfffffffe ||
      !{0x500d, 0x5007, 0x500f}.contains(code)) {
    return true;
  }
  double actual;
  double power = 1;
  List<double> stops;
  if (code == 0x5007) {
    if (value < 70) return true;
    actual = value / 100;
    power = 2;
    stops = thirdStopAperture;
  } else if (code == 0x500f) {
    actual = value.toDouble();
    stops = thirdStopIso;
  } else {
    if (propertyCode == 0xd100 || propertyCode == 0xd1a8) {
      final numerator = value >> 16, denominator = value & 0xffff;
      if (numerator == 0 || denominator == 0) return false;
      actual = numerator / denominator;
    } else {
      actual = value / 10000;
    }
    if (actual < 1) actual = 1 / actual;
    stops = thirdStopShutter;
  }
  if ((nominalExposure(actual, stops) / actual - 1).abs() < .001) return true;
  final ev =
      math.log(code == 0x500f ? actual / 100 : actual) / math.ln2 * power;
  return (ev - (ev * 3).round() / 3).abs() < .075;
}
