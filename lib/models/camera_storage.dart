class CameraStorage {
  CameraStorage(Map<String, dynamic> data)
    : id = data['id'] as int,
      slot = data['slot'] as int? ?? ((data['id'] as int) >> 16),
      description = (data['description'] ?? data['name'] ?? '') as String,
      volumeLabel = data['volumeLabel'] as String? ?? '',
      capacity = (data['capacity'] as num?)?.toInt(),
      free = (data['free'] as num?)?.toInt();

  final int id, slot;
  final String description, volumeLabel;
  final int? capacity, free;

  String get title => slot > 0 ? '卡槽 $slot' : '存储卡';
  String get details => [
    if (volumeLabel.isNotEmpty) '卷标：$volumeLabel',
    capacity != null && capacity! > 0
        ? '剩余 ${free != null && free! >= 0 && free! <= capacity! ? formatStorageBytes(free!) : '未知'} / ${formatStorageBytes(capacity!)}'
        : '容量未知',
  ].join('\n');
}

class CameraFolder {
  const CameraFolder(this.storageId, this.handle, this.name, {this.path});
  final int storageId, handle;
  final String name;
  final String? path;
  String get displayName => path ?? name;
}

String formatStorageBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${unit == 0 ? bytes : value.toStringAsFixed(1)} ${units[unit]}';
}
