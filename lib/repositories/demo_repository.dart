import '../models/media_item.dart';
import 'camera_repository.dart';

class DemoRepository extends CameraRepository {
  DemoRepository({this.delay = const Duration(milliseconds: 700)});
  final Duration delay;
  @override
  bool get isDemo => true;
  static final media = List.generate(
    24,
    (i) => MediaItem(
      id: 'demo-$i',
      name:
          'DSC_${20079 - i}.${i % 12 == 7
              ? 'NEF'
              : i % 12 == 10
              ? 'MP4'
              : 'JPG'}',
      kind: i % 12 == 7
          ? MediaKind.raw
          : i % 12 == 10
          ? MediaKind.video
          : MediaKind.jpg,
      date: DateTime(2026, 9, 9 - i ~/ 12, 18),
      bytes: i % 12 == 7 ? 20148224 : 640,
      card: i < 12 ? 2 : 1,
      folder: ['100NIKON', 'EVENT_A', 'SELECTS'][i % 3],
      asset: i % 12 == 7 ? 'assets/demo_raw.png' : ['assets/demo.png', 'assets/demo_media/cat.png', 'assets/demo_media/coast.png', 'assets/demo_media/forest.png', 'assets/demo_media/flowers.png'][i % 5],
    ),
  );
  @override
  Future<List<MediaItem>> connect(String address) async {
    if (delay != Duration.zero) {
      await Future<void>.delayed(delay);
    }
    return media;
  }

  @override
  Future<void> transfer(MediaItem item, {bool fail = false}) async {
    if (delay != Duration.zero) {
      await Future<void>.delayed(delay);
    }
    if (fail) {
      throw StateError('演示：连接中断');
    }
  }
}
