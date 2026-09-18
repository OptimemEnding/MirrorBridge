/// Presentation boundary: diagnostics belong in logs, not photo and task cards.
String userMessage(Object error) {
  final text = error.toString();
  if (RegExp(
    r'User cancel|CANCELLED|CANCELED',
    caseSensitive: false,
  ).hasMatch(text)) {
    return '已取消操作。';
  }
  if (RegExp(
    r'ENOENT|FileSystemException|FileNotFound|No such file|not found',
    caseSensitive: false,
  ).hasMatch(text)) {
    return '找不到照片或资源，可能已被移动或删除。请重新选择照片后重试。';
  }
  if (RegExp(
    r'SecurityException|Permission|EACCES|access denied',
    caseSensitive: false,
  ).hasMatch(text)) {
    return '暂时没有访问权限，请在系统设置中授权照片访问后重试。';
  }
  if (RegExp(
    r'SocketException|TimeoutException|Connection refused|Network is unreachable',
    caseSensitive: false,
  ).hasMatch(text)) {
    return '连接暂时不可用，请检查相机电源与网络连接后重试。';
  }
  if (RegExp(
    r'Exception|Error:|Bad state:|java\.|StackTrace|#\d+\s+|PlatformException',
    caseSensitive: false,
  ).hasMatch(text)) {
    return '操作暂时未完成，请检查照片是否可访问、设备是否连接后重试。';
  }
  return text;
}
