import 'dart:typed_data';

/// Standard Nikon live-view header: JPEG size, whole area, displayed crop,
/// displayed centre (big-endian uint16 pairs). Extended/unknown headers are
/// ignored; the caller must also match the decoded JPEG dimensions.
class NikonLiveGeometry {
  NikonLiveGeometry(
    this.jpegWidth,
    this.jpegHeight,
    this.wholeWidth,
    this.wholeHeight,
    this.width,
    this.height,
    this.centerX,
    this.centerY,
  );
  final int jpegWidth, jpegHeight, wholeWidth, wholeHeight;
  final int width, height, centerX, centerY;

  static NikonLiveGeometry? parse(Uint8List bytes) {
    if (bytes.length < 64 || bytes[0] == 0xff && bytes[1] == 0xd8) return null;
    final b = ByteData.sublistView(bytes);
    // Nikon extended live-view header layout used by supported responses.
    // Version and header-length fields identify the extended layout; unknown
    // layouts are rejected rather than guessed.
    final extended =
        bytes.length >= 1024 &&
        b.getUint32(0) == 0x00020001 &&
        b.getUint32(8) == 1024;
    final v = extended
        ? [
            b.getUint16(28),
            b.getUint16(30),
            for (var i = 16; i < 28; i += 2) b.getUint16(i),
          ]
        : List.generate(8, (i) => b.getUint16(i * 2));
    if (v.take(6).any((n) => n <= 0 || n > 16384) ||
        v[4] > v[2] ||
        v[5] > v[3] ||
        v[6] * 2 < v[4] ||
        v[7] * 2 < v[5] ||
        v[6] * 2 + v[4] > v[2] * 2 ||
        v[7] * 2 + v[5] > v[3] * 2) {
      return null;
    }
    return NikonLiveGeometry(v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7]);
  }

  (int, int) point(double x, double y) => (
    (centerX - width / 2 + x.clamp(0.0, 1.0) * (width - 1)).round().clamp(
      0,
      wholeWidth - 1,
    ),
    (centerY - height / 2 + y.clamp(0.0, 1.0) * (height - 1)).round().clamp(
      0,
      wholeHeight - 1,
    ),
  );
}
