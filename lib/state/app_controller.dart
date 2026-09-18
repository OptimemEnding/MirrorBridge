import '../models/user_message.dart';
import 'dart:convert';
import 'package:flutter/painting.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/media_item.dart';
import '../models/media_sync_state.dart';
import '../models/camera_storage.dart';
import '../repositories/camera_repository.dart';
import '../repositories/nikon_repository.dart';
import '../repositories/phone_media_library.dart';
import '../protocol/ptp.dart';

const _templateIds = {
  'clean_white',
  'night_frame',
  'gallery_label',
  'soft_shadow',
  'film_contact',
  'minimal_line',
  'studio_card',
  'focus_grid',
  'wide_caption',
  'compact_caption',
};

const _builtInLuts = {
  'Warm Tone',
  'Cool Tone',
  'Vivid Color',
  'Soft Light',
  'Matte Film',
  'Monochrome',
  'High Contrast',
  'Sepia Print',
};

String _currentLut(String value, Iterable<String> importedLuts) {
  if (value.isEmpty ||
      _builtInLuts.contains(value) ||
      importedLuts.contains(value)) {
    return value;
  }
  return '';
}

class AppController extends ChangeNotifier {
  AppController(this.repository) {
    nikon?.onChanged = () {
      media = nikon!.media;
      changed();
    };
    nikon?.onConnectionStage = (stage) {
      if (connection != ConnectionPhase.connecting || _disposed) return;
      message = stage;
      changed();
    };
    nikon?.onProgress = (bytes, total) {
      if (!_disposed && busy) {
        task!.currentBytes = bytes;
        if (DateTime.now().difference(_lastPhoneStorageRead).inSeconds >= 1) {
          unawaited(refreshPhoneStorage());
        }
        transferProgress.value++;
      }
    };
    nikon?.onDisconnected = (reason) {
      connection = ConnectionPhase.failed;
      message = reason;
      changed();
    };
    nikon?.onNewMedia = (items) {
      if (!live || !connected || _disposed) return;
      _automatic.addAll(items.where((item) => !_isRecordSynced(item)));
      _drainAutomatic();
    };
    nikon?.onPushMedia = (items) {
      if (!receivePush || !connected || _disposed) return;
      _automatic.addAll(items.where((item) => !_isRecordSynced(item)));
      _drainAutomatic();
    };
  }
  final CameraRepository repository;
  NikonRepository? get nikon =>
      repository is NikonRepository ? repository as NikonRepository : null;
  final List<MediaItem> _automatic = [];
  bool _transferRunning = false;
  final transferProgress = ValueNotifier<int>(0);
  final Set<String> _pendingSyncIds = {};
  bool get syncInProgress => busy || _transferRunning;
  bool isSyncPending(MediaItem item) => _pendingSyncIds.contains(item.id);
  String get cameraModel => isDemo ? 'Nikon Z 8' : nikon?.device?.model ?? '未知';
  String get connectionLabel => mode == 'USB'
      ? 'USB / PTP'
      : mode == 'STA'
      ? 'STA / PTP-IP'
      : 'Wi-Fi / PTP-IP';
  double get byteProgress => task == null || task!.totalBytes == 0
      ? 0
      : ((task!.doneBytes + (busy ? task!.currentBytes : 0)) / task!.totalBytes)
            .clamp(0, 1);
  void _drainAutomatic() {
    if (_transferRunning ||
        !(live || receivePush) ||
        !connected ||
        _automatic.isEmpty) {
      return;
    }
    final batch = {
      for (final item in _automatic) item.id: item,
    }.values.toList();
    _automatic.clear();
    unawaited(startSync(items: batch));
  }

  static const platform = MethodChannel('mirrorbridge.ui/storage');
  int tab = 0;
  ConnectionPhase connection = ConnectionPhase.disconnected;
  String brand = 'Nikon', mode = 'Wi-Fi', address = '';
  String _message = '';
  String get message => _message;
  set message(String value) {
    _message = userMessage(value);
  }

  List<MediaItem> media = [], local = [];
  final Set<String> selection = {}, localSelection = {};
  final Set<String> favorites = {};
  final Set<String> hiddenSyncTaskIds = {};
  List<SyncTask> get visibleSyncTasks =>
      allSyncTasks.where((t) => !hiddenSyncTaskIds.contains(t.id)).toList();
  bool get hasClearableCompletedOrMissingRecords => allSyncTasks.any(
    (record) =>
        record.missing.isNotEmpty ||
        record.items.any((item) => !item.referenceAvailable) ||
        record.phase == SyncPhase.completed &&
            !hiddenSyncTaskIds.contains(record.id),
  );
  Future<void> hideCompletedTasks({SyncTask? record}) async {
    for (final t in record == null ? allSyncTasks : [record]) {
      if (t.phase == SyncPhase.completed) hiddenSyncTaskIds.add(t.id);
    }
    notifyListeners();
    await save();
  }

  Future<void> clearCompletedAndMissingRecords() async {
    final unavailableIds = <String>{
      for (final item in local)
        if (!item.referenceAvailable) item.id,
      for (final record in allSyncTasks)
        if (record.phase != SyncPhase.transferring)
          for (final item in record.items)
            if (!item.referenceAvailable || record.missing.contains(item.id))
              item.id,
    };
    _pruneRecords(unavailableIds, preserveTransferring: true);
    local.removeWhere((item) => unavailableIds.contains(item.id));
    localSelection.removeAll(unavailableIds);
    selection.removeAll(unavailableIds);
    _automatic.removeWhere((item) => unavailableIds.contains(item.id));
    favorites.removeAll(unavailableIds);
    syncCompletedIds.removeAll(unavailableIds);
    syncFailedIds.removeAll(unavailableIds);
    for (final record in allSyncTasks) {
      if (record.phase == SyncPhase.completed) {
        hiddenSyncTaskIds.add(record.id);
      }
    }
    hiddenSyncTaskIds.removeWhere(
      (id) => !allSyncTasks.any((record) => record.id == id),
    );
    _mediaSyncIndex = null;
    reconcileSelection();
    await save();
  }

  String cameraQuery = '', localQuery = '';
  String cameraSort = '默认', localSort = '默认';
  bool isFavorite(MediaItem item) => favorites.contains(item.id);
  void toggleFavorite(MediaItem item) {
    if (!favorites.add(item.id)) favorites.remove(item.id);
    unawaited(save());
  }

  void setMediaQuery(String value, {bool isLocal = false}) {
    if (isLocal) {
      localQuery = value;
    } else {
      cameraQuery = value;
    }
    if (isLocal) localSelection.retainAll(visibleLocal.map((m) => m.id));
    reconcileSelection();
  }

  void setMediaSort(String value, {bool isLocal = false}) {
    if (isLocal) {
      localSort = value;
    } else {
      cameraSort = value;
    }
    changed();
  }

  List<MediaItem> _arrange(
    Iterable<MediaItem> source,
    String query,
    String sort,
  ) {
    final result = source
        .where((m) => m.name.toLowerCase().contains(query.trim().toLowerCase()))
        .toList();
    if (sort != '默认') {
      result.sort(
        (a, b) => switch (sort) {
          '最早拍摄' => a.date.compareTo(b.date),
          '文件名称' => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          '文件大小' => b.bytes.compareTo(a.bytes),
          _ => b.date.compareTo(a.date),
        },
      );
    }
    return result;
  }

  String filter = '全部', localFilter = '全部', folder = '全部文件夹';
  int card = 0;
  int? storageId, folderStorageId, folderHandle;
  final Set<int> selectedStorageIds = {};
  final Map<(int, int, String), CameraFolder> selectedFolders = {};
  final Set<String> syncCompletedIds = {}, syncFailedIds = {};
  int get totalSyncCompleted => local.where((m) => m.referenceAvailable).length;
  int get manualImportCompleted => local
      .where(
        (item) =>
            item.origin == MediaOrigin.manualImport && item.referenceAvailable,
      )
      .length;
  int get cameraSyncCompleted => local
      .where(
        (item) =>
            item.origin == MediaOrigin.cameraSync && item.referenceAvailable,
      )
      .length;
  int get totalSyncFailed => {
    for (final record in allSyncTasks)
      for (final item in record.items)
        if (mediaSyncState(item) == MediaSyncState.failed) item.id,
  }.length;
  MediaSyncIndex? _mediaSyncIndex;
  MediaSyncState mediaSyncState(MediaItem item) {
    if (isSyncing(item)) return MediaSyncState.syncing;
    if (isSyncPending(item)) return MediaSyncState.queued;
    final index = _mediaSyncIndex ??= MediaSyncIndex(
      local: local,
      tasks: allSyncTasks,
    );
    return index.stateFor(item);
  }

  String _activeTransferId = '';
  bool isSyncing(MediaItem item) =>
      _transferRunning && _activeTransferId == item.id;
  DateTime? dateStart, dateEnd;
  bool live = false, watermark = true, showExif = true, failNext = false;
  bool receivePush = false;
  Map<String, dynamic> monitorPreferences = {};
  String lut = '', template = 'clean_white';
  List<String> importedLuts = [];
  double intensity = .5, border = .1;
  double captionX = .5, captionY = 1, captionScale = 1;
  String captionAlignment = 'center';
  Map<String, Map<String, dynamic>> captionStyles = {};
  double? freeGb;
  int? phoneTotalBytes, phoneFreeBytes;
  bool _readingPhoneStorage = false;
  DateTime _lastPhoneStorageRead = DateTime.fromMillisecondsSinceEpoch(0);
  List<String> recent = [];
  SyncTask? task;
  final List<SyncTask> syncTasks = [];
  List<SyncTask> get allSyncTasks => [
    if (task != null && !syncTasks.contains(task) && task!.items.isNotEmpty)
      task!,
    ...syncTasks.where((record) => record.items.isNotEmpty),
  ];
  List<SyncTask> get syncHistory => allSyncTasks
      .where((record) => record.phase != SyncPhase.transferring)
      .toList();
  bool containsSyncTask(SyncTask record) =>
      identical(task, record) || syncTasks.contains(record);
  bool canRemoveSyncItem(SyncTask record, String id) =>
      containsSyncTask(record) &&
      (!record.completed.contains(id) || record.missing.contains(id)) &&
      record.items.any((m) => m.id == id);
  bool canRemoveSyncTask(SyncTask record) =>
      containsSyncTask(record) &&
      record.items.any(
        (m) =>
            !record.completed.contains(m.id) || record.missing.contains(m.id),
      );

  void _retainTask(SyncTask? record) {
    if (record != null &&
        record.items.isNotEmpty &&
        !syncTasks.contains(record)) {
      syncTasks.insert(0, record);
      _mediaSyncIndex = null;
    }
  }

  void _removeEmptyTask(SyncTask record) {
    _mediaSyncIndex = null;
    if (record.items.isNotEmpty) return;
    syncTasks.remove(record);
    if (identical(task, record)) task = null;
  }

  int _generation = 0;
  bool _disposed = false;
  bool get isDemo => repository.isDemo;
  bool get connected => connection == ConnectionPhase.connected;
  bool get busy => task?.phase == SyncPhase.transferring;
  int get completedCount => totalSyncCompleted;
  int get transferredBytes =>
      (task?.doneBytes ?? 0) + (busy ? task!.currentBytes : 0);
  int? get cachedCameraTotal => connected ? nikon?.cachedMediaCount : null;
  int? get cameraTotal => connected
      ? (nikon?.totalMediaCount ?? (isDemo ? media.length : null))
      : 0;
  int get syncedStorageBytes {
    final saved = {for (final item in local) item.id: item};
    final bytes = saved.values
        .where(
          (m) => m.origin == MediaOrigin.cameraSync && m.referenceAvailable,
        )
        .fold<int>(0, (sum, m) => sum + m.bytes);
    final current = task;
    if (!busy || current == null || saved.containsKey(current.currentId)) {
      return bytes;
    }
    final item = current.items
        .where((m) => m.id == current.currentId)
        .firstOrNull;
    return bytes +
        (item == null ? 0 : current.currentBytes.clamp(0, item.bytes));
  }

  List<CameraStorage> get cameraStorages => !connected
      ? []
      : nikon != null
      ? nikon!.storages.map(CameraStorage.new).toList()
      : (media.map((m) => m.card).toSet().toList()..sort())
            .map(
              (slot) => CameraStorage({
                'id': slot,
                'slot': slot,
                'description': '演示存储卡',
              }),
            )
            .toList();

  List<CameraFolder> get cameraFolders {
    final folders = <(int, int, String), CameraFolder>{};
    for (final entry in nikon?.folders ?? <CameraFolder>[]) {
      folders[(entry.storageId, entry.handle, entry.name)] = entry;
    }
    for (final item in media) {
      final id = isDemo ? item.card : item.storageId;
      final entry = CameraFolder(id, item.parentHandle, item.folder);
      folders.putIfAbsent((id, entry.handle, entry.name), () => entry);
    }
    return folders.values
        .where(
          (f) =>
              selectedStorageIds.isEmpty ||
              selectedStorageIds.contains(f.storageId),
        )
        .toList()
      ..sort(
        (a, b) => a.storageId != b.storageId
            ? a.storageId.compareTo(b.storageId)
            : a.name.compareTo(b.name),
      );
  }

  void setStorage(CameraStorage? value) {
    selectedStorageIds.clear();
    if (value != null) selectedStorageIds.add(value.id);
    selectedFolders.clear();
    _updateStorageFilter();
  }

  void toggleStorage(CameraStorage value) {
    if (!selectedStorageIds.add(value.id)) selectedStorageIds.remove(value.id);
    selectedFolders.removeWhere(
      (_, f) =>
          selectedStorageIds.isNotEmpty &&
          !selectedStorageIds.contains(f.storageId),
    );
    _updateStorageFilter();
  }

  bool folderSelected(CameraFolder value) =>
      selectedFolders.containsKey((value.storageId, value.handle, value.name));

  void setFolder(CameraFolder? value) {
    selectedFolders.clear();
    if (value != null) {
      selectedFolders[(value.storageId, value.handle, value.name)] = value;
    }
    _updateStorageFilter();
  }

  void toggleFolder(CameraFolder value) {
    final key = (value.storageId, value.handle, value.name);
    if (selectedFolders.containsKey(key)) {
      selectedFolders.remove(key);
    } else {
      selectedFolders[key] = value;
    }
    _updateStorageFilter();
  }

  void _updateStorageFilter() {
    card = 0;
    storageId = selectedStorageIds.length == 1
        ? selectedStorageIds.single
        : null;
    final single = selectedFolders.length == 1
        ? selectedFolders.values.single
        : null;
    folder = single?.name ?? '全部文件夹';
    folderStorageId = single?.storageId;
    folderHandle = single?.handle;
    reconcileSelection();
  }

  bool get hasMediaFilter =>
      filter != '全部' ||
      card != 0 ||
      selectedStorageIds.isNotEmpty ||
      selectedFolders.isNotEmpty ||
      folder != '全部文件夹' ||
      dateStart != null ||
      dateEnd != null;
  int? get visibleTotal {
    if (!hasMediaFilter) return cameraTotal;
    if (isDemo || nikon?.hasMore != true) return visible.length;
    final indexed = nikon?.indexedMedia;
    return indexed?.where(_matchesMedia).length;
  }

  bool get hasMoreVisible {
    if (!connected || nikon?.hasMore != true) return false;
    final total = visibleTotal;
    return total == null || visible.length < total;
  }

  Future<void> refreshPhoneStorage() async {
    if (_readingPhoneStorage) return;
    _readingPhoneStorage = true;
    _lastPhoneStorageRead = DateTime.now();
    try {
      final stats = await platform.invokeMapMethod<String, dynamic>(
        'storageInfo',
      );
      final free = (stats?['freeBytes'] as num?)?.toInt();
      final total = (stats?['totalBytes'] as num?)?.toInt();
      phoneFreeBytes = free == null || free < 0 ? null : free;
      freeGb = free == null || free < 0 ? null : free / 1073741824;
      phoneTotalBytes = total == null || total <= 0 ? null : total;
    } on MissingPluginException {
      // The platform bridge is absent in widget tests.
    } on PlatformException {
      freeGb = null;
      phoneFreeBytes = null;
      phoneTotalBytes = null;
    } finally {
      _readingPhoneStorage = false;
    }
    changed();
  }

  bool loadingFolders = false;
  Future<void> refreshFolders() async {
    if (!connected || loadingFolders || nikon == null) return;
    loadingFolders = true;
    changed();
    try {
      await nikon!.readFolders();
    } catch (e) {
      message = '文件夹暂时无法访问，请重新授权或选择其他文件夹。';
    } finally {
      loadingFolders = false;
      changed();
    }
  }

  bool loadingMedia = false, _reconcilingLocal = false;
  bool importingMedia = false;
  bool _refreshAgain = false;
  void selectAllLoaded({bool isLocal = false}) {
    final items = (isLocal ? visibleLocal : visible)
        .where((m) => !isSyncPending(m))
        .toList();
    final ids = isLocal ? localSelection : selection;
    if (items.every((m) => ids.contains(m.id))) {
      ids.removeAll(items.map((m) => m.id));
    } else {
      ids.addAll(items.map((m) => m.id));
    }
    changed();
  }

  void _pruneRecords(Set<String> ids, {bool preserveTransferring = false}) {
    if (ids.isEmpty) return;
    _mediaSyncIndex = null;
    for (final record in allSyncTasks) {
      if (preserveTransferring && record.phase == SyncPhase.transferring) {
        continue;
      }
      record.items.removeWhere((m) => ids.contains(m.id));
      record.completed.removeAll(ids);
      record.failed.removeAll(ids);
      record.missing.removeAll(ids);
      record.errors.removeWhere((key, _) => ids.contains(key));
      if (record.phase != SyncPhase.transferring &&
          record.items.every((m) => record.completed.contains(m.id))) {
        record.phase = SyncPhase.completed;
      }
      _removeEmptyTask(record);
    }
  }

  final _phoneLibrary = PhoneMediaLibrary();
  MediaItem viewingItem(MediaItem item) =>
      local
          .where(
            (m) =>
                m.id == item.id &&
                m.referenceAvailable &&
                (m.sourceUri.isNotEmpty ||
                    m.albumUri.isNotEmpty ||
                    m.localPath.isNotEmpty),
          )
          .firstOrNull ??
      item;

  Future<String?> thumbnailFor(MediaItem item) {
    final source = viewingItem(item);
    return source.sourceUri.isNotEmpty ||
            source.albumUri.isNotEmpty ||
            source.localPath.isNotEmpty
        ? _phoneLibrary.thumbnail(source)
        : nikon?.thumbnail(item) ?? Future.value(null);
  }

  Future<void> clearCaches() async {
    if (isDemo) return;
    try {
      await nikon?.clearCaches();
      for (final item in [
        ...media,
        ...local,
        for (final t in allSyncTasks) ...t.items,
      ]) {
        item.thumbnailPath = '';
      }
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      changed();
    } on MissingPluginException {
      /* Test hosts. */
    } catch (e) {
      message = '暂时无法清理缓存，请稍后重试。';
      changed();
    }
  }

  Future<void> _migratePublishedCopies() async {
    for (final item in local.where(
      (m) =>
          m.albumUri.isNotEmpty &&
          m.localPath.isNotEmpty &&
          m.origin != MediaOrigin.manualImport,
    )) {
      try {
        final released = await nativeCamera.invokeMethod<bool>(
          'releasePublishedCopy',
          {'path': item.localPath, 'uri': item.albumUri},
        );
        if (released == true) {
          item.sourceUri = item.albumUri;
          item.localPath = '';
          item.thumbnailPath = '';
          for (final record in allSyncTasks) {
            for (final alias in record.items.where((m) => m.id == item.id)) {
              alias.sourceUri = item.sourceUri;
              alias.albumUri = item.albumUri;
              alias.localPath = '';
              alias.thumbnailPath = '';
            }
          }
        }
      } catch (e) {
        nikon?.log('published copy retained: $e');
      }
    }
  }

  Future<void> _libraryQueue = Future.value();
  Future<T> _withLibrary<T>(Future<T> Function() action) {
    final result = _libraryQueue.then((_) => action());
    _libraryQueue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  SyncTask _addCompletedTask(
    Iterable<MediaItem> values,
    SyncTaskType type, {
    bool makeCurrent = true,
  }) {
    final record = SyncTask(List<MediaItem>.of(values), type: type)
      ..phase = SyncPhase.completed;
    record.completed.addAll(record.items.map((item) => item.id));
    record.missing.addAll(
      record.items.where((m) => !m.referenceAvailable).map((m) => m.id),
    );
    _retainTask(record);
    if (makeCurrent && !syncInProgress) task = record;
    return record;
  }

  bool _recoverLocalTasks() {
    for (final record in List<SyncTask>.of(allSyncTasks)) {
      if (record.type != SyncTaskType.cameraSync ||
          record.phase == SyncPhase.transferring) {
        continue;
      }
      final wrongOrigin = record.items
          .where((m) => m.origin != MediaOrigin.cameraSync)
          .map((m) => m.id)
          .toSet();
      record.items.removeWhere((m) => wrongOrigin.contains(m.id));
      record.completed.removeAll(wrongOrigin);
      record.failed.removeAll(wrongOrigin);
      record.errors.removeWhere((id, _) => wrongOrigin.contains(id));
      _removeEmptyTask(record);
    }
    final recorded = {
      for (final record in allSyncTasks) ...record.items.map((item) => item.id),
    };
    final missing = local.where((item) => !recorded.contains(item.id)).toList();
    if (missing.isEmpty) return false;
    final exports = missing
        .where((item) => item.origin == MediaOrigin.editorExport)
        .toList();
    final manual = missing
        .where((item) => item.origin == MediaOrigin.manualImport)
        .toList();
    final camera = missing
        .where((item) => item.origin == MediaOrigin.cameraSync)
        .toList();
    if (camera.isNotEmpty) {
      _addCompletedTask(
        camera,
        SyncTaskType.cameraSync,
        makeCurrent: task == null,
      );
    }
    if (exports.isNotEmpty) {
      _addCompletedTask(
        exports,
        SyncTaskType.editorExport,
        makeCurrent: task == null,
      );
    }
    if (manual.isNotEmpty) {
      _addCompletedTask(
        manual,
        SyncTaskType.manualImport,
        makeCurrent: task == null,
      );
    }
    return true;
  }

  DateTime? _lastLocalCheck;
  Future<void> refreshLocal({bool force = true}) async {
    if (!force &&
        _lastLocalCheck != null &&
        DateTime.now().difference(_lastLocalCheck!) <
            const Duration(seconds: 10)) {
      return;
    }
    if (isDemo || _disposed) return;
    if (_reconcilingLocal) {
      _refreshAgain = true;
      return;
    }
    _reconcilingLocal = true;
    try {
      await _withLibrary(() async {
        await refreshPhoneStorage();
        await _phoneLibrary.refreshItems(local);
        final available = local
            .where((m) => m.referenceAvailable)
            .map((m) => m.id)
            .toSet();
        for (final record in allSyncTasks) {
          record.missing
            ..clear()
            ..addAll(record.completed.where((id) => !available.contains(id)));
        }
        localSelection.retainAll(available);
        _mediaSyncIndex = null;
        await save();
      });
    } on MissingPluginException {
      // Tests and unsupported hosts have no phone library.
    } catch (e) {
      message = '暂时无法读取本地照片，请检查照片访问权限后重试。';
    } finally {
      _lastLocalCheck = DateTime.now();
      _reconcilingLocal = false;
      changed();
      if (_refreshAgain) {
        _refreshAgain = false;
        unawaited(refreshLocal());
      }
    }
  }

  void changed() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  void navigate(int value) {
    tab = value;
    if (value == 4) unawaited(refreshLocal(force: false));
    if (value == 2 && connected) unawaited(nikon?.checkNewPhotos());
    changed();
  }

  static bool validIp(String value) {
    final parts = value.trim().split('.');
    return parts.length == 4 &&
        parts.every(
          (p) => RegExp(r'^\d{1,3}$').hasMatch(p) && int.parse(p) <= 255,
        );
  }

  Future<void> load() async {
    _mediaSyncIndex = null;
    var settingsMigrated = false;
    try {
      await refreshPhoneStorage();
      final raw = await platform.invokeMethod<String>(
        'load',
        isDemo ? 'demo' : 'normal',
      );
      if (raw != null && raw.isNotEmpty) {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        monitorPreferences = Map<String, dynamic>.from(
          data['monitorPreferences'] ?? {},
        );
        favorites.addAll(List<String>.from(data['favorites'] ?? []));
        hiddenSyncTaskIds.addAll(
          List<String>.from(data['hiddenSyncTaskIds'] ?? []),
        );
        live = data['live'] == true;
        receivePush = data['receivePush'] == true;
        watermark = data['watermark'] != false;
        showExif = data['showExif'] != false;
        captionX = ((data['captionX'] as num?)?.toDouble() ?? .5).clamp(0, 1);
        captionY = ((data['captionY'] as num?)?.toDouble() ?? 1).clamp(0, 1);
        captionScale = ((data['captionScale'] as num?)?.toDouble() ?? 1).clamp(
          .5,
          2,
        );
        captionStyles =
            (data['captionStyles'] as Map?)?.map(
              (key, value) => MapEntry(
                key.toString(),
                Map<String, dynamic>.from(value as Map),
              ),
            ) ??
            {};
        captionAlignment = data['captionAlignment'] as String? ?? 'center';
        if (!['left', 'center', 'right'].contains(captionAlignment)) {
          captionAlignment = 'center';
        }
        importedLuts = List<String>.from(data['importedLuts'] ?? []);
        final savedLut = data['lut'] as String? ?? '';
        lut = _currentLut(savedLut, importedLuts);
        if (lut != savedLut) settingsMigrated = true;
        final savedMonitorLut = monitorPreferences['lut'];
        if (savedMonitorLut is String) {
          final currentMonitorLut = _currentLut(
            savedMonitorLut,
            importedLuts,
          );
          if (currentMonitorLut != savedMonitorLut) {
            monitorPreferences['lut'] = currentMonitorLut;
            monitorPreferences['lutEnabled'] = false;
            settingsMigrated = true;
          }
        }
        final savedTemplate = data['template'] as String? ?? 'clean_white';
        template = _templateIds.contains(savedTemplate)
            ? savedTemplate
            : 'clean_white';
        if (template != savedTemplate) settingsMigrated = true;
        recent = List<String>.from(data['recent'] ?? []);
        nikon?.deviceNames.addAll(
          Map<String, String>.from(data['deviceNames'] ?? {}),
        );
        border = (data['border'] as num?)?.toDouble() ?? .1;
        intensity = (data['intensity'] as num?)?.toDouble() ?? .5;
        {
          local = (data['local'] as List? ?? [])
              .map(
                (m) => MediaItem.fromJson(Map<String, dynamic>.from(m as Map)),
              )
              .toList();
        }
        task = null;
        syncTasks.clear();
        if (data['syncTasks'] is List) {
          syncTasks.addAll(
            (data['syncTasks'] as List)
                .map(
                  (record) => SyncTask.fromJson(
                    Map<String, dynamic>.from(record as Map),
                  ),
                )
                .where((record) => record.items.isNotEmpty),
          );
          task =
              syncTasks
                  .where((record) => record.id == data['lastTaskId'])
                  .firstOrNull ??
              syncTasks.firstOrNull;
        } else if (data['task'] is Map) {
          task = SyncTask.fromJson(
            Map<String, dynamic>.from(data['task'] as Map),
          );
          _retainTask(task);
        }
        syncCompletedIds.addAll(
          List<String>.from(
            data['syncCompletedIds'] ??
                {
                  ...local
                      .where((m) => m.origin == MediaOrigin.cameraSync)
                      .map((m) => m.id),
                  ...List<String>.from(
                    (data['task'] as Map?)?['completed'] ?? [],
                  ),
                },
          ),
        );
        syncFailedIds.addAll(
          List<String>.from(
            data['syncFailedIds'] ?? task?.failed.toList() ?? [],
          ),
        );
      }
    } on MissingPluginException {
      /* Widget tests and unsupported platforms. */
    } on PlatformException {
      message = '无法读取本地设置';
    } on FormatException {
      message = '本地设置已损坏，使用默认值';
    }
    final discoveredIds = local
        .where((m) => m.origin == MediaOrigin.albumDiscovery)
        .map((m) => m.id)
        .toSet();
    local.removeWhere((m) => discoveredIds.contains(m.id));
    _pruneRecords(discoveredIds);
    _mediaSyncIndex = null;
    await _migratePublishedCopies();
    await clearCaches();
    await refreshLocal();
    final recovered = _recoverLocalTasks();
    final availableIds = local
        .where((m) => m.referenceAvailable)
        .map((m) => m.id)
        .toSet();
    for (final record in allSyncTasks) {
      record.missing
        ..clear()
        ..addAll(record.completed.where((id) => !availableIds.contains(id)));
    }
    if (settingsMigrated) message = '部分滤镜或水印设置已恢复为当前默认值';
    if (recovered || settingsMigrated) await save();
    changed();
  }

  Future<void> save() async {
    changed();
    try {
      await platform.invokeMethod('save', {
        'key': isDemo ? 'demo' : 'normal',
        'value': jsonEncode({
          'favorites': favorites.toList(),
          'hiddenSyncTaskIds': hiddenSyncTaskIds.toList(),
          'monitorPreferences': monitorPreferences,
          'live': live,
          'receivePush': receivePush,
          'watermark': watermark,
          'showExif': showExif,
          'captionX': captionX,
          'captionY': captionY,
          'captionScale': captionScale,
          'captionAlignment': captionAlignment,
          'captionStyles': captionStyles,
          'lut': lut,
          'importedLuts': importedLuts,
          'template': template,
          'recent': recent,
          'deviceNames': nikon?.deviceNames ?? {},
          'border': border,
          'intensity': intensity,
          'local': local.map((m) => m.toJson()).toList(),
          'schemaVersion': 7,
          'syncTasks': allSyncTasks.map((record) => record.toJson()).toList(),
          'lastTaskId': task?.id,
          'syncCompletedIds': syncCompletedIds.toList(),
          'syncFailedIds': syncFailedIds.toList(),
        }),
      });
    } on MissingPluginException {
      /* No host in unit tests. */
    } on PlatformException {
      message = '设置保存失败';
      changed();
    }
  }

  Future<bool> connect(String ip) async {
    if (connection == ConnectionPhase.connecting || _transferRunning) {
      return false;
    }
    if (!(nikon != null && mode == 'USB') && !validIp(ip)) {
      message = '请输入有效的 IPv4 地址';
      changed();
      return false;
    }
    final generation = ++_generation;
    connection = ConnectionPhase.connecting;
    storageId = folderStorageId = folderHandle = null;
    selectedStorageIds.clear();
    selectedFolders.clear();
    card = 0;
    folder = '全部文件夹';
    selection.clear();
    message = '正在检测相机服务';
    changed();
    try {
      nikon?.mode = mode;
      final result = await repository.connect(ip);
      if (_disposed || generation != _generation) {
        return false;
      }
      media = result;
      address = ip;
      connection = ConnectionPhase.connected;
      recent = {ip, ...recent}.take(5).toList();
      message = '';
      await save();
      navigate(2);
      if (nikon != null) {
        await nativeCamera.invokeMethod('service', {'active': true});
      }
      return true;
    } catch (e) {
      if (_disposed || generation != _generation) {
        return false;
      }
      connection = ConnectionPhase.failed;
      message = e.toString().replaceFirst('Bad state: ', '');
      changed();
      return false;
    }
  }

  void disconnect() {
    _generation++;
    connection = ConnectionPhase.disconnected;
    selection.clear();
    media = [];
    cancelSync();
    _automatic.clear();
    unawaited(repository.disconnect());
    changed();
  }

  List<MediaItem> get visible =>
      _arrange(media.where(_matchesMedia), cameraQuery, cameraSort);

  bool _isRecordSynced(MediaItem item) =>
      mediaSyncState(item) == MediaSyncState.synced;

  bool _matchesMedia(MediaItem m) {
    final synced = _isRecordSynced(m);
    return (filter == '全部' ||
            filter == m.label ||
            filter == '已同步' && synced ||
            filter == '未同步' && !synced) &&
        (card == 0 || m.card == card) &&
        (selectedStorageIds.isEmpty ||
            selectedStorageIds.contains(isDemo ? m.card : m.storageId)) &&
        (selectedFolders.isNotEmpty
            ? selectedFolders.values.any(
                (f) =>
                    f.storageId == (isDemo ? m.card : m.storageId) &&
                    (nikon?.isInFolder(m.storageId, m.parentHandle, f.handle) ??
                        (m.parentHandle == f.handle && m.folder == f.name)),
              )
            : (folder == '全部文件夹' || folder == m.folder)) &&
        (dateStart == null || !m.date.isBefore(dateStart!)) &&
        (dateEnd == null ||
            m.date.isBefore(dateEnd!.add(const Duration(days: 1))));
  }

  List<MediaItem> get visibleLocal => _arrange(
    local
        .where((m) => m.referenceAvailable)
        .where(
          (m) =>
              localFilter == '全部' ||
              m.label == localFilter ||
              localFilter == '收藏' && isFavorite(m),
        ),
    localQuery,
    localSort,
  );
  void setFilter(String value) {
    filter = value;
    reconcileSelection();
  }

  void reconcileSelection() {
    selection.retainAll(
      visible.where((m) => !isSyncPending(m)).map((m) => m.id),
    );
    changed();
    if (hasMediaFilter && visible.isEmpty && hasMoreVisible) {
      unawaited(refreshMedia(more: true));
    }
  }

  void toggle(MediaItem item, {bool isLocal = false}) {
    if (isSyncPending(item)) return;
    final ids = isLocal ? localSelection : selection;
    if (!(isLocal ? visibleLocal : visible).any((m) => m.id == item.id)) {
      return;
    }
    if (!ids.add(item.id)) {
      ids.remove(item.id);
    }
    changed();
  }

  Future<void> startSync({List<MediaItem>? items}) async {
    if (busy || _transferRunning) {
      return;
    }
    final chosen =
        items ?? visible.where((m) => selection.contains(m.id)).toList();
    if (chosen.isEmpty || !connected) {
      return;
    }
    final current = SyncTask(List.of(chosen));
    _retainTask(task);
    _retainTask(current);
    _transferRunning = true;
    task = current;
    current.phase = SyncPhase.transferring;
    _pendingSyncIds.addAll(chosen.map((m) => m.id));
    selection.removeAll(_pendingSyncIds);
    localSelection.removeAll(_pendingSyncIds);
    navigate(3);
    final failure = failNext;
    failNext = false;
    try {
      if (nikon != null) {
        await nativeCamera.invokeMethod('service', {'active': true});
      }
      await save();
      for (final item in chosen) {
        try {
          if (current.phase != SyncPhase.transferring) {
            break;
          }
          if (current.removed.contains(item.id)) continue;
          current.currentId = item.id;
          _activeTransferId = item.id;
          selection.remove(item.id);
          localSelection.remove(item.id);
          current.currentBytes = 0;
          changed();
          await repository.transfer(
            item,
            fail: failure && item.id == chosen.last.id,
          );
          if (_disposed || current.phase != SyncPhase.transferring) {
            return;
          }
          if (current.removed.contains(item.id)) continue;
          // Keep the completed download visible while checking the gallery.
          item.referenceAvailable = true;
          if (!isDemo) await _phoneLibrary.refreshItem(item);
          if (!item.referenceAvailable) throw StateError('导出后的本地文件不可访问');
          current.completed.add(item.id);
          current.currentBytes = 0;
          _mediaSyncIndex?.recordLocal(item);
          _mediaSyncIndex?.recordResult(item.id, MediaSyncState.synced);
          syncCompletedIds.add(item.id);
          syncFailedIds.remove(item.id);
          await _withLibrary(() async {
            final aliases = local
                .where(
                  (m) => m.id != item.id && _phoneLibrary.sameAsset(m, item),
                )
                .map((m) => m.id)
                .toSet();
            local.removeWhere((m) => m.id == item.id || aliases.contains(m.id));
            _pruneRecords(aliases);
            // Keep availability independent from fresh camera listing objects.
            local.insert(0, MediaItem.fromJson(item.toJson()));
            _mediaSyncIndex = null;
          });
        } catch (e) {
          if (_disposed || current.phase != SyncPhase.transferring) {
            return;
          }
          if (current.removed.contains(item.id)) continue;
          current.failed.add(item.id);
          _mediaSyncIndex?.recordResult(item.id, MediaSyncState.failed);
          syncFailedIds.add(item.id);
          current.errors[item.id] = e.toString();
        } finally {
          _pendingSyncIds.remove(item.id);
          _activeTransferId = '';
          current.currentId = '';
          current.currentBytes = 0;
        }
        current.currentBytes = 0;
        await save();
        changed();
      }
      if (current.phase == SyncPhase.transferring) {
        current.phase = current.failed.isEmpty
            ? SyncPhase.completed
            : SyncPhase.partialFailure;
      }
      await save();
    } catch (e) {
      message = e.toString();
      current.phase = SyncPhase.partialFailure;
      current.failed.addAll(
        current.items
            .where((m) => !current.completed.contains(m.id))
            .map((m) => m.id),
      );
      syncFailedIds.addAll(current.failed);
      for (final id in current.failed) {
        _mediaSyncIndex?.recordResult(id, MediaSyncState.failed);
      }
      await save();
    } finally {
      _transferRunning = false;
      _pendingSyncIds.clear();
      _activeTransferId = '';
      await refreshPhoneStorage();
      if (nikon != null && !connected) {
        try {
          await nativeCamera.invokeMethod('service', {'active': false});
        } catch (e) {
          message = e.toString();
        }
      }
      changed();
      _drainAutomatic();
    }
  }

  Future<void> retryFailed({SyncTask? record}) async {
    if (_transferRunning) return;
    final previous = record ?? task;
    if (previous != null && previous.type != SyncTaskType.cameraSync) {
      message = '请重新手工导入输入照片，或重新执行编辑导出';
      changed();
      return;
    }
    if (previous == null) {
      return;
    }
    final retry = previous.items
        .where(
          (m) =>
              !previous.completed.contains(m.id) ||
              previous.missing.contains(m.id),
        )
        .toList();
    if (nikon != null) {
      if (!connected) {
        message = '请先重新连接同一台相机，再重试任务';
        changed();
        return;
      }
      while (nikon!.hasMore &&
          retry.any((r) => !media.any((m) => m.id == r.id))) {
        await nikon!.loadMore();
        media = nikon!.media;
      }
      if (retry.any((r) => !media.any((m) => m.id == r.id))) {
        message = '部分待恢复文件未在当前相机中找到，请刷新相册确认';
        changed();
        return;
      }
    }
    await startSync(
      items: retry
          .map((r) => media.where((m) => m.id == r.id).firstOrNull ?? r)
          .toList(),
    );
  }

  void cancelSync() {
    if (busy) {
      task!.phase = SyncPhase.cancelled;
      for (final item in task!.items) {
        if (!task!.completed.contains(item.id) &&
            !task!.failed.contains(item.id)) {
          _mediaSyncIndex?.recordResult(item.id, MediaSyncState.cancelled);
        }
      }
      _automatic.clear();
      unawaited(repository.cancel());
      unawaited(save());
      changed();
    }
  }

  Future<void> removeSyncItem(String id, {SyncTask? record}) async {
    record ??= task;
    if (record == null || !canRemoveSyncItem(record, id)) return;
    record.removed.add(id);
    if (identical(task, record)) _pendingSyncIds.remove(id);
    final active = identical(task, record) && record.currentId == id && busy;
    record.items.removeWhere((m) => m.id == id);
    record.failed.remove(id);
    record.completed.remove(id);
    record.missing.remove(id);
    local.removeWhere((m) => m.id == id && !m.referenceAvailable);
    record.errors.remove(id);
    _automatic.removeWhere((m) => m.id == id);
    if (record.items.isEmpty) {
      record.phase = SyncPhase.cancelled;
    } else if (record.phase != SyncPhase.transferring &&
        record.items.every((m) => record!.completed.contains(m.id))) {
      record.phase = SyncPhase.completed;
    }
    _removeEmptyTask(record);
    changed();
    if (active) await repository.cancel();
    await save();
  }

  Future<void> removeSyncTask({SyncTask? record}) async {
    record ??= task;
    if (record == null || !canRemoveSyncTask(record)) return;
    final active = identical(task, record) && busy;
    final removing = record.items
        .where(
          (m) =>
              !record!.completed.contains(m.id) ||
              record.missing.contains(m.id),
        )
        .map((m) => m.id)
        .toSet();
    record.removed.addAll(removing);
    if (identical(task, record)) _pendingSyncIds.removeAll(removing);
    record.items.removeWhere((m) => removing.contains(m.id));
    record.failed.removeAll(removing);
    record.completed.removeAll(removing);
    record.missing.removeAll(removing);
    local.removeWhere((m) => removing.contains(m.id) && !m.referenceAvailable);
    record.errors.removeWhere((id, _) => removing.contains(id));
    record.phase = record.items.isEmpty
        ? SyncPhase.cancelled
        : SyncPhase.completed;
    _automatic.removeWhere((m) => removing.contains(m.id));
    _removeEmptyTask(record);
    changed();
    if (active) await repository.cancel();
    await save();
  }

  Future<void> deleteLocal(Set<String> ids, {bool deleteSource = false}) =>
      _withLibrary(() async {
        for (final item in local.where((m) => ids.contains(m.id)).toList()) {
          try {
            if (deleteSource && !isDemo) await _phoneLibrary.delete(item);
            local.removeWhere((m) => m.id == item.id);
            localSelection.remove(item.id);
            syncCompletedIds.remove(item.id);
            syncFailedIds.remove(item.id);
            _pruneRecords({item.id});
            for (final cameraItem in media.where((m) => m.id == item.id)) {
              cameraItem.localPath = '';
              cameraItem.albumUri = '';
              cameraItem.sourceUri = '';
            }
          } catch (e) {
            message = '删除 ${item.name} 失败：$e';
          }
        }
        _mediaSyncIndex = null;
        await save();
        changed();
      });

  Future<void> refreshMedia({bool more = false}) async {
    if (!connected ||
        loadingMedia ||
        busy ||
        nikon?.monitoring == true ||
        (more && !hasMoreVisible)) {
      return;
    }
    loadingMedia = true;
    changed();
    try {
      if (nikon != null) {
        final target = more
            ? visible.length + NikonRepository.pageSize
            : NikonRepository.pageSize;
        if (!more) {
          if (hasMediaFilter) {
            await nikon!.refreshFiltered(_matchesMedia);
          } else {
            await nikon!.refresh();
          }
          media = nikon!.media;
        }
        // A filtered page may be far beyond the first unfiltered page.
        // Keep reading until this view has a page or its matches are exhausted.
        while (connected &&
            !_disposed &&
            !busy &&
            nikon?.monitoring != true &&
            hasMoreVisible &&
            (more || hasMediaFilter) &&
            visible.length < target) {
          final before = media.length;
          await nikon!.loadMore();
          media = nikon!.media;
          if (media.length == before) break;
          if (!hasMediaFilter) break;
        }
        reconcileSelection();
      }
    } catch (e) {
      message = e.toString();
      changed();
    } finally {
      loadingMedia = false;
      changed();
    }
  }

  Future<void> setLive(bool value) async {
    live = value;
    await save();
    if (nikon != null) {
      try {
        await nativeCamera.invokeMethod('service', {'active': connected});
      } catch (e) {
        message = e.toString();
        changed();
      }
    }
  }

  Future<void> shareItems(Iterable<MediaItem> items) async {
    try {
      await nativeCamera.invokeMethod('share', {
        'sources': items
            .map((m) => m.sourceUri.isNotEmpty ? m.sourceUri : m.localPath)
            .where((source) => source.isNotEmpty)
            .toList(),
      });
    } catch (e) {
      message = e.toString();
      changed();
    }
  }

  Future<void> addEditorExport(MediaItem item) => _withLibrary(() async {
    if (!isDemo) await _phoneLibrary.refreshItem(item);
    final duplicates = local
        .where((m) => _phoneLibrary.sameAsset(m, item))
        .map((m) => m.id)
        .toSet();
    local.removeWhere((m) => duplicates.contains(m.id));
    _pruneRecords(duplicates);
    local.insert(0, item);
    _addCompletedTask([item], SyncTaskType.editorExport);
    _mediaSyncIndex = null;
    await save();
  });

  Future<void> deleteCameraItems(List<MediaItem> items) async {
    try {
      await nikon?.deleteRemote(items);
      media = nikon?.media ?? media;
      reconcileSelection();
    } catch (e) {
      message = e.toString();
      changed();
    }
  }

  Future<List<MediaItem>> importMedia({
    bool multiple = true,
    bool imagesOnly = false,
  }) async {
    if (importingMedia) return [];
    importingMedia = true;
    changed();
    try {
      final picked = await nativeCamera.invokeListMethod<dynamic>('pick', {
        'kind': imagesOnly ? 'image' : 'media',
        'multiple': multiple,
      });
      if (picked == null || picked.isEmpty) return [];
      return await _withLibrary(() async {
        final imported = <MediaItem>[];
        for (final value in picked) {
          final record = Map<String, dynamic>.from(value as Map);
          final item = _phoneLibrary.fromRecord(
            record,
            MediaOrigin.manualImport,
          );
          final existing = local
              .where((known) => _phoneLibrary.sameAsset(known, item))
              .firstOrNull;
          if (existing != null && existing.referenceAvailable) continue;
          if (existing != null) {
            local.remove(existing);
            _pruneRecords({existing.id});
          }
          local.insert(0, item);
          imported.add(item);
        }
        if (imported.isEmpty) return [];
        _addCompletedTask(imported, SyncTaskType.manualImport);
        _mediaSyncIndex = null;
        await save();
        message = '已手工导入 ${imported.length} 个媒体';
        changed();
        return imported;
      });
    } catch (e) {
      message = e.toString();
      changed();
      return [];
    } finally {
      importingMedia = false;
      changed();
    }
  }

  Future<MediaItem?> chooseImageReference() async =>
      (await importMedia(multiple: false, imagesOnly: true)).firstOrNull;

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    transferProgress.dispose();
    if (nikon != null) unawaited(nikon!.dispose());
    super.dispose();
  }
}
