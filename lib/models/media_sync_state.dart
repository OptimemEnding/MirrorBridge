import 'media_item.dart';

enum MediaSyncState {
  unverified('待校验'),
  verifying('正在校验'),
  unsynced('未同步'),
  queued('等待同步'),
  syncing('正在同步'),
  synced('已同步'),
  missing('本地文件失效'),
  failed('同步失败'),
  cancelled('已取消');

  const MediaSyncState(this.label);
  final String label;
}

/// A transfer is complete when the task is completed and the corresponding
/// local media record is still available.
/// Camera identity includes camera source, storage, folder, name, size and date.
/// Manual imports and editor exports never mark a camera file as synchronized.
class MediaSyncIndex {
  MediaSyncIndex({
    required Iterable<MediaItem> local,
    required Iterable<SyncTask> tasks,
  }) {
    final records = {for (final m in local) m.id: m};
    final history = tasks.toList();
    final exported = <String>{for (final task in history) ...task.completed};
    for (final item in records.values) {
      if (item.referenceAvailable &&
          (item.asset.isNotEmpty || exported.contains(item.id))) {
        _states[item.id] = MediaSyncState.synced;
        _identities[item.id] = item;
      }
    }
    for (final task in history) {
      for (final item in task.items) {
        if (_states.containsKey(item.id)) continue;
        final saved = records[item.id];
        if (task.completed.contains(item.id)) {
          _states[item.id] =
              saved != null &&
                  saved.referenceAvailable &&
                  (task.type != SyncTaskType.cameraSync ||
                      saved.origin == MediaOrigin.cameraSync &&
                          sameCameraRecord(saved, item))
              ? MediaSyncState.synced
              : MediaSyncState.missing;
        } else {
          _states[item.id] = task.failed.contains(item.id)
              ? MediaSyncState.failed
              : task.phase == SyncPhase.cancelled
              ? MediaSyncState.cancelled
              : MediaSyncState.unsynced;
        }
        _identities[item.id] = item;
      }
    }
    for (final item in records.values.where((m) => m.asset.isNotEmpty)) {
      _states.putIfAbsent(item.id, () => MediaSyncState.synced);
      _identities.putIfAbsent(item.id, () => item);
    }
  }
  final _states = <String, MediaSyncState>{};
  final _identities = <String, MediaItem>{};
  static bool sameCameraRecord(MediaItem a, MediaItem b) =>
      a.id == b.id &&
      a.source == b.source &&
      a.storageId == b.storageId &&
      a.folder == b.folder &&
      a.name == b.name &&
      a.bytes == b.bytes &&
      a.date == b.date &&
      a.origin == b.origin;
  MediaSyncState stateFor(MediaItem item) {
    final saved = _identities[item.id];
    if (saved == null || !sameCameraRecord(saved, item)) {
      return MediaSyncState.unsynced;
    }
    return _states[item.id] ?? MediaSyncState.unsynced;
  }

  void recordResult(String id, MediaSyncState state) => _states[id] = state;
  void recordLocal(MediaItem item) {
    _identities[item.id] = item;
  }
}
