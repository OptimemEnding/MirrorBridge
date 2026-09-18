import 'camera_storage.dart';

enum MediaKind { jpg, raw, video }

enum MediaOrigin { cameraSync, manualImport, albumDiscovery, editorExport }

enum SyncTaskType { cameraSync, manualImport, editorExport }

class MediaItem {
  MediaItem({
    required this.id,
    required this.name,
    required this.kind,
    required this.date,
    required this.bytes,
    this.card = 1,
    this.folder = '100NIKON',
    this.asset = 'assets/demo.png',
    this.handle = 0,
    this.storageId = 0,
    this.parentHandle = 0,
    this.source = '',
    this.localPath = '',
    this.thumbnailPath = '',
    this.albumUri = '',
    this.sourceUri = '',
    this.libraryKey = '',
    this.contentHash = '',
    this.hashVerified = false,
    this.referenceAvailable = true,
    this.referenceLocation = '',
    this.referencePath = '',
    MediaOrigin? origin,
    Map<String, String>? exif,
  }) : origin =
           origin ??
           (id.startsWith('edit-')
               ? MediaOrigin.editorExport
               : id.startsWith('local-')
               ? MediaOrigin.manualImport
               : MediaOrigin.cameraSync),
       exif = exif ?? {};
  final int handle, storageId, parentHandle;
  final String source;
  String localPath, thumbnailPath, albumUri, sourceUri, contentHash, libraryKey;
  bool hashVerified;
  bool referenceAvailable;
  String referenceLocation, referencePath;
  MediaOrigin origin;
  Map<String, String> exif;
  final String id, folder, asset;
  String name;
  MediaKind kind;
  final DateTime date;
  int bytes;
  final int card;
  String get label => switch (kind) {
    MediaKind.jpg => 'JPG',
    MediaKind.raw => 'RAW',
    MediaKind.video => '视频',
  };
  String get size => formatStorageBytes(bytes);
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.index,
    'date': date.toIso8601String(),
    'bytes': bytes,
    'card': card,
    'folder': folder,
    'asset': asset,
    'handle': handle,
    'storageId': storageId,
    'parentHandle': parentHandle,
    'source': source,
    'localPath': localPath,
    'thumbnailPath': thumbnailPath,
    'albumUri': albumUri,
    'sourceUri': sourceUri,
    'libraryKey': libraryKey,
    'referenceAvailable': referenceAvailable,
    'referenceLocation': referenceLocation,
    'referencePath': referencePath,
    'origin': origin.name,
    'exif': exif,
  };
  factory MediaItem.fromJson(Map<String, dynamic> value) => MediaItem(
    id: value['id'] as String,
    name: value['name'] as String,
    kind: MediaKind.values[value['kind'] as int],
    date: DateTime.parse(value['date'] as String),
    bytes: value['bytes'] as int,
    card: value['card'] as int,
    folder: value['folder'] as String,
    asset: value['asset'] as String,
    handle: (value['handle'] as num?)?.toInt() ?? 0,
    storageId: (value['storageId'] as num?)?.toInt() ?? 0,
    parentHandle: (value['parentHandle'] as num?)?.toInt() ?? 0,
    source: value['source'] as String? ?? '',
    localPath: value['localPath'] as String? ?? '',
    thumbnailPath: value['thumbnailPath'] as String? ?? '',
    albumUri: value['albumUri'] as String? ?? '',
    sourceUri: value['sourceUri'] as String? ?? '',
    libraryKey: value['libraryKey'] as String? ?? '',
    contentHash: value['contentHash'] as String? ?? '',
    referenceAvailable: value['referenceAvailable'] != false,
    referenceLocation: value['referenceLocation'] as String? ?? '',
    referencePath: value['referencePath'] as String? ?? '',
    origin: MediaOrigin.values
        .where((origin) => origin.name == value['origin'])
        .firstOrNull,
    exif: Map<String, String>.from(value['exif'] as Map? ?? {}),
  );
}

enum ConnectionPhase { disconnected, scanning, connecting, connected, failed }

enum SyncPhase { idle, transferring, completed, partialFailure, cancelled }

class SyncTask {
  SyncTask(
    this.items, {
    String? id,
    DateTime? createdAt,
    this.type = SyncTaskType.cameraSync,
  }) : id = id ?? '${DateTime.now().microsecondsSinceEpoch}-${_nextId++}',
       createdAt = createdAt ?? DateTime.now();
  static int _nextId = 0;
  final String id;
  final DateTime createdAt;
  final SyncTaskType type;

  Map<String, dynamic> toJson() => {
    'id': id,
    'createdAt': createdAt.toIso8601String(),
    'type': type.name,
    'phase': phase.name,
    'items': items.map((m) => m.toJson()).toList(),
    'completed': completed.toList(),
    'failed': failed.toList(),
    'errors': errors,
    'missing': missing.toList(),
  };

  factory SyncTask.fromJson(Map<String, dynamic> value) {
    final items = (value['items'] as List? ?? [])
        .map((m) => MediaItem.fromJson(Map<String, dynamic>.from(m as Map)))
        .toList();
    final explicitType = SyncTaskType.values
        .where((type) => type.name == value['type'])
        .firstOrNull;
    final inferredType =
        items.isNotEmpty &&
            items.every((item) => item.origin == MediaOrigin.editorExport)
        ? SyncTaskType.editorExport
        : items.isNotEmpty &&
              items.every(
                (item) =>
                    item.origin == MediaOrigin.manualImport ||
                    item.origin == MediaOrigin.albumDiscovery,
              )
        ? SyncTaskType.manualImport
        : SyncTaskType.cameraSync;
    final task = SyncTask(
      items,
      id: value['id'] as String?,
      createdAt: DateTime.tryParse(value['createdAt'] as String? ?? ''),
      type: explicitType ?? inferredType,
    );
    final ids = task.items.map((m) => m.id).toSet();
    task.completed.addAll(
      List<String>.from(value['completed'] ?? []).where(ids.contains),
    );
    task.failed.addAll(
      List<String>.from(value['failed'] ?? []).where(ids.contains),
    );
    task.missing.addAll(
      List<String>.from(value['missing'] ?? []).where(ids.contains),
    );
    task.errors.addAll(Map<String, String>.from(value['errors'] ?? {}));
    task.phase =
        SyncPhase.values.where((p) => p.name == value['phase']).firstOrNull ??
        SyncPhase.partialFailure;
    // A process restart ends the previous transfer; unfinished files can be retried.
    if (task.phase == SyncPhase.transferring ||
        task.phase == SyncPhase.idle ||
        value['phase'] == null) {
      task.failed.addAll(ids.difference(task.completed));
      task.phase = task.failed.isEmpty
          ? SyncPhase.completed
          : SyncPhase.partialFailure;
    }
    return task;
  }
  final List<MediaItem> items;
  final Set<String> completed = {}, failed = {}, removed = {}, missing = {};
  SyncPhase phase = SyncPhase.idle;
  String currentId = '';
  int currentBytes = 0;
  final Map<String, String> errors = {};
  double get progress => items.isEmpty
      ? 0
      : (completed.length - missing.length + failed.length) / items.length;
  int get totalBytes => items.fold(0, (sum, m) => sum + m.bytes);
  int get doneBytes => items
      .where((m) => completed.contains(m.id) && !missing.contains(m.id))
      .fold(0, (sum, m) => sum + m.bytes);
}
