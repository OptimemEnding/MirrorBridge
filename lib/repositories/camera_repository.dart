import '../models/media_item.dart';

abstract class CameraRepository {
  bool get isDemo;
  Future<List<MediaItem>> connect(String address);
  Future<void> transfer(MediaItem item, {bool fail = false});
  Future<void> disconnect() async {}
  Future<void> cancel() async {}
}

class UnavailableCameraRepository extends CameraRepository {
  @override
  bool get isDemo => false;
  @override
  Future<List<MediaItem>> connect(String address) async =>
      throw StateError('未检测到相机服务。真实相机协议尚未集成。');
  @override
  Future<void> transfer(MediaItem item, {bool fail = false}) async =>
      throw StateError('未连接真实相机');
}
