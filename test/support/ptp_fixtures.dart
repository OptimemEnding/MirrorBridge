import 'dart:typed_data';

import 'package:mirrorbridge/protocol/ptp.dart';

/// Builds a minimal, valid PTP DeviceInfo data set for Nikon connection tests.
Uint8List syntheticDeviceInfo({required bool transferReady}) {
  final operations = <int>[
    0x1001, // GetDeviceInfo
    0x1002, // OpenSession
    0x1003, // CloseSession
    if (!transferReady) ...[
      0x935a, // Nikon ConfirmPairing
      0x952b, // Nikon GetPairingStatus
    ],
    if (transferReady) ...[
      0x1004, // GetStorageIDs
      0x1005, // GetStorageInfo
      0x1007, // GetObjectHandles
      0x1008, // GetObjectInfo
      0x1009, // GetObject
      0x101b, // GetPartialObject
      0x90c2, // Nikon media control mode
      0x941c, // Nikon GetEventEx
      0x9435, // Nikon application mode
    ],
  ];

  return Uint8List.fromList([
    ...ptpU16(100), // StandardVersion 1.00
    ...ptpWords([10]), // Nikon VendorExtensionID
    ...ptpU16(100), // VendorExtensionVersion 1.00
    ..._ptpString('Nikon'),
    ...ptpU16(0), // FunctionalMode
    ..._array16(operations),
    ..._array16(const []), // EventsSupported
    ..._array16(const []), // DevicePropertiesSupported
    ..._array16(const []), // CaptureFormats
    ..._array16(const []), // ImageFormats
    ..._ptpString('Nikon'),
    ..._ptpString('Z 8'),
    ..._ptpString('1.0'),
    ..._ptpString('fixture'),
  ]);
}

List<int> _array16(List<int> values) => [
  ...ptpWords([values.length]),
  for (final value in values) ...ptpU16(value),
];

List<int> _ptpString(String value) => [
  value.length + 1,
  for (final codeUnit in value.codeUnits) ...ptpU16(codeUnit),
  ...ptpU16(0),
];
