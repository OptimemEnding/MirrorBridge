import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/services.dart';

const nativeCamera = MethodChannel('mirrorbridge/native');

class PtpException implements Exception {
  PtpException(this.operation, this.response);
  final int operation, response;
  bool get unsupported => response == 0x2005 || response == 0x2006;
  @override
  String toString() {
    final reason =
        const {
          0x2005: '当前连接模式不支持此操作',
          0x2006: '当前模式不支持此参数',
          0x200c: '相机存储卡已满',
          0x200f: '相机拒绝遥控操作，请检查机身模式与控制权限',
          0x2019: '相机忙碌，请稍后重试',
          0x201a: '相机参数格式不匹配',
          0x201b: '此参数值在当前模式不可用',
          0xa001: '镜头或机身处于手动对焦，请切换到 AF',
          0xa002: '未能合焦，请选择有反差的区域并检查镜头 AF 开关',
          0xa004: '相机禁止此操作，请检查视频模式、存储卡和机身提示',
          0xa00b: '相机不在实时取景状态',
        }[response] ??
        '相机未完成此操作';
    return '$reason（相机响应 0x${response.toRadixString(16)}，操作 0x${operation.toRadixString(16)}）';
  }
}

class PtpReader {
  PtpReader(List<int> bytes) : data = Uint8List.fromList(bytes);
  final Uint8List data;
  int offset = 0;
  void need(int count) {
    if (count < 0 || offset + count > data.length) {
      throw FormatException(
        '相机数据不完整：offset=$offset need=$count available=${data.length - offset} total=${data.length}',
      );
    }
  }

  int u8() {
    need(1);
    return data[offset++];
  }

  int u16() {
    need(2);
    final v = ByteData.sublistView(data).getUint16(offset, Endian.little);
    offset += 2;
    return v;
  }

  int u32() {
    need(4);
    final v = ByteData.sublistView(data).getUint32(offset, Endian.little);
    offset += 4;
    return v;
  }

  int u64() {
    need(8);
    final v = ByteData.sublistView(data).getUint64(offset, Endian.little);
    offset += 8;
    return v;
  }

  String string() {
    final n = u8();
    if (n == 0) return '';
    need(n * 2);
    final codes = List.generate(n, (_) => u16());
    if (codes.last == 0) codes.removeLast();
    return String.fromCharCodes(codes);
  }

  List<int> array16() {
    final n = u32();
    need(n * 2);
    return List.generate(n, (_) => u16());
  }

  List<int> array32() {
    final n = u32();
    need(n * 4);
    return List.generate(n, (_) => u32());
  }
}

Uint8List ptpWords(List<int> values) {
  final b = ByteData(values.length * 4);
  for (var i = 0; i < values.length; i++) {
    b.setUint32(i * 4, values[i] & 0xffffffff, Endian.little);
  }
  return b.buffer.asUint8List();
}

Uint8List ptpU16(int value) =>
    (ByteData(2)..setUint16(0, value, Endian.little)).buffer.asUint8List();

class PtpDeviceInfo {
  PtpDeviceInfo(
    this.make,
    this.model,
    this.serial,
    this.operations,
    this.properties,
  );
  final String make, model, serial;
  final Set<int> operations, properties;
  factory PtpDeviceInfo.parse(Uint8List data) {
    final r = PtpReader(data);
    r.u16();
    r.u32();
    r.u16();
    r.string();
    r.u16();
    final ops = r.array16().toSet();
    r.array16();
    final props = r.array16().toSet();
    r.array16();
    r.array16();
    // PIMA 15740 identity strings trail the mandatory capability arrays and
    // some cameras omit them. Array bounds remain strict.
    String identity() => r.offset < r.data.length ? r.string() : '';
    final make = identity(), model = identity();
    identity();
    final serial = identity();
    return PtpDeviceInfo(make, model, serial, ops, props);
  }
}

class PtpObjectInfo {
  PtpObjectInfo(
    this.storage,
    this.format,
    this.bytes,
    this.parent,
    this.name,
    this.date,
    this.width,
    this.height,
  );
  final int storage, format, bytes, parent, width, height;
  final String name;
  final DateTime? date;
  factory PtpObjectInfo.parse(Uint8List bytes) {
    final r = PtpReader(bytes);
    r.need(53);
    final storage = r.u32(), format = r.u16();
    r.u16();
    final size = r.u32();
    r.u16();
    r.u32();
    r.u32();
    r.u32();
    final width = r.u32(), height = r.u32();
    r.u32();
    final parent = r.u32();
    r.u16();
    r.u32();
    r.u32();
    final name = r.string();
    final rawDate = r.offset < r.data.length ? r.string() : '';
    DateTime? date;
    final match = RegExp(
      r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})',
    ).firstMatch(rawDate);
    if (match != null) {
      date = DateTime(
        int.parse(match[1]!),
        int.parse(match[2]!),
        int.parse(match[3]!),
        int.parse(match[4]!),
        int.parse(match[5]!),
        int.parse(match[6]!),
      );
    }
    return PtpObjectInfo(
      storage,
      format,
      size,
      parent,
      name,
      date,
      width,
      height,
    );
  }
}

abstract class PtpTransport {
  Future<Uint8List> data(int code, [List<int> params = const []]);
  Future<void> command(int code, [List<int> params = const []]);
  Future<void> writeProperty(int property, Uint8List bytes);
  Future<void> close();
}

class UsbPtpTransport implements PtpTransport {
  @override
  Future<Uint8List> data(int code, [List<int> params = const []]) async {
    try {
      final bytes = await nativeCamera.invokeMethod<Uint8List>('usbData', {
        'code': code,
        'params': params,
      });
      if (bytes == null) {
        throw FormatException('USB 数据为空：操作 0x${code.toRadixString(16)}');
      }
      return bytes;
    } on PlatformException catch (e) {
      if (e.code == 'PTP_RESPONSE' && e.details is Map) {
        final info = e.details as Map;
        throw PtpException(
          (info['operation'] as num).toInt(),
          (info['response'] as num).toInt(),
        );
      }
      rethrow;
    }
  }

  @override
  Future<void> command(int code, [List<int> params = const []]) async {
    final rc = await nativeCamera.invokeMethod<int>('usbCommand', {
      'code': code,
      'params': params,
    });
    if (rc != 0x2001) throw PtpException(code, rc ?? 0);
  }

  @override
  Future<void> writeProperty(int property, Uint8List bytes) => nativeCamera
      .invokeMethod('usbWriteProperty', {'code': property, 'data': bytes});
  @override
  Future<void> close() => nativeCamera.invokeMethod('usbClose');
}

class PtpInitRejected implements Exception {
  PtpInitRejected(this.reason);
  final int reason;
  @override
  String toString() => reason == 1
      ? '相机拒绝新的设备握手（InitFail reason=1）。请在相机上忘记此连接，再重新创建连接，然后重试。'
      : '相机拒绝 PTP/IP 初始化（InitFail reason=$reason），请检查相机连接模式并确认配对。';
}

class PtpConnectionException implements Exception {
  PtpConnectionException(this.stage, this.endpoint, this.cause);
  final String stage, endpoint;
  final Object cause;
  @override
  String toString() => '连接失败（$stage，$endpoint）：$cause';
}

class _SocketReader {
  _SocketReader(Socket socket) : iterator = StreamIterator<Uint8List>(socket);
  final StreamIterator<Uint8List> iterator;
  Uint8List chunk = Uint8List(0);
  int position = 0;
  Future<Uint8List> read(
    int size, {
    Duration? timeout = const Duration(seconds: 20),
  }) async {
    if (size < 0 || size > 64 * 1024 * 1024) {
      throw const FormatException('PTP 读取长度无效');
    }
    final output = Uint8List(size);
    await readInto(output, 0, size, timeout: timeout);
    return output;
  }

  Future<void> readInto(
    Uint8List output,
    int offset,
    int size, {
    Duration? timeout = const Duration(seconds: 20),
  }) async {
    RangeError.checkValidRange(offset, offset + size, output.length);
    var remaining = size;
    while (remaining > 0) {
      if (position == chunk.length) {
        final next = iterator.moveNext();
        if (!(await (timeout == null ? next : next.timeout(timeout)))) {
          throw const SocketException('相机已断开连接');
        }
        chunk = iterator.current;
        position = 0;
      }
      final n = min(remaining, chunk.length - position);
      output.setRange(offset, offset + n, chunk, position);
      position += n;
      offset += n;
      remaining -= n;
    }
  }

  Future<(int, int)> header({
    Duration? timeout = const Duration(seconds: 20),
  }) async {
    final r = PtpReader(await read(8, timeout: timeout));
    final length = r.u32(), type = r.u32();
    if (length < 8 || length > 0xffffffff) {
      throw const FormatException('PTP/IP 包长度无效');
    }
    return (type, length - 8);
  }
}

/// Nikon PTP/IP: separate command/event sockets, little-endian packets,
/// transaction checks and streamed data.
class PtpIpTransport implements PtpTransport {
  PtpIpTransport({
    this.onEvent,
    this.log,
    this.onClosed,
    this.eventPingInterval = const Duration(seconds: 12),
  });
  final void Function(String reason)? onClosed;
  final Duration eventPingInterval;
  DateTime _lastEventAt = DateTime.now();
  final void Function(int code, List<int> params)? onEvent;
  final void Function(String message)? log;
  Socket? _socket, _eventSocket;
  _SocketReader? _reader;
  // Transfer sessions start at 1. Nikon STA pairing starts at 0; callers
  // select the required first transaction when opening.
  int _transaction = 1;
  Future<void> _tail = Future.value();
  bool _closed = false;
  int _openEpoch = 0;
  Duration operationTimeout = const Duration(seconds: 20);
  bool get isOpen => !_closed && _socket != null;
  Timer? _ping;
  static Uint8List packet(int type, List<int> payload) => Uint8List.fromList([
    ...ptpWords([8 + payload.length, type]),
    ...payload,
  ]);
  Future<T> _serial<T>(Future<T> Function() run) {
    final result = _tail.then((_) => run());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> open(
    String host,
    List<int> guid, {
    int port = 15740,
    String name = 'MirrorBridge',
    Socket? commandSocket,
    int firstTransaction = 1,
    bool openSession = true,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    await close();
    final epoch = _openEpoch;
    var timedOut = false;
    final deadline = Timer(timeout, () {
      if (epoch != _openEpoch) return;
      timedOut = true;
      unawaited(close());
    });
    void checkOpen() {
      if (timedOut) throw TimeoutException('PTP/IP 握手超时', timeout);
      if (epoch != _openEpoch) throw const SocketException('PTP/IP 连接已取消');
    }

    var stage = '命令 TCP 连接';
    final endpoint = '$host:$port';
    void enter(String value) {
      stage = value;
      log?.call('connect stage=$stage endpoint=$endpoint');
    }

    try {
      if (guid.length != 16) {
        throw const FormatException('PTP/IP GUID 必须为 16 字节');
      }
      _closed = false;
      _transaction = firstTransaction;
      enter(stage);
      final command =
          commandSocket ??
          await Socket.connect(
            host,
            port,
            timeout: timeout < const Duration(seconds: 8)
                ? timeout
                : const Duration(seconds: 8),
          );
      if (epoch != _openEpoch) {
        command.destroy();
        checkOpen();
      }
      _socket = command;
      _socket!.setOption(SocketOption.tcpNoDelay, true);
      _socket!.done.ignore();
      _reader = _SocketReader(_socket!);
      final utf16 = [
        for (final unit in name.codeUnits) ...[unit & 255, unit >> 8],
        0,
        0,
      ];
      enter('InitCommandRequest / 等待相机确认');
      log?.call(
        'init clientName=$name clientGuid=${guid.map((b) => b.toRadixString(16).padLeft(2, '0')).join()} version=0x10000',
      );
      _socket!.add(
        packet(1, [
          ...guid,
          ...utf16,
          ...ptpWords([0x10000]),
        ]),
      );
      await _socket!.flush();
      final (type, len) = await _reader!.header();
      final ack = await _reader!.read(len);
      log?.call('InitCommandAck type=$type payloadBytes=$len');
      if (type == 5) {
        final reason = ack.length >= 4 ? PtpReader(ack).u32() : -1;
        throw PtpInitRejected(reason);
      }
      if (type != 2 || ack.length < 4) {
        throw const FormatException('PTP/IP 初始化响应无效');
      }
      final connection = PtpReader(ack).u32();
      log?.call('InitCommandAck connectionNumber=$connection');
      enter('事件 TCP 连接');
      final events = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 8),
      );
      if (epoch != _openEpoch) {
        events.destroy();
        checkOpen();
      }
      _eventSocket = events;
      _eventSocket!.done.ignore();
      final eventReader = _SocketReader(_eventSocket!);
      _eventSocket!.setOption(SocketOption.tcpNoDelay, true);
      enter('InitEventRequest / 等待事件确认');
      _eventSocket!.add(packet(3, ptpWords([connection])));
      await _eventSocket!.flush();
      final (eventType, eventLen) = await eventReader.header();
      await eventReader.read(eventLen);
      log?.call('InitEventAck type=$eventType payloadBytes=$eventLen');
      if (eventType != 4) throw const FormatException('相机事件通道初始化失败');
      _lastEventAt = DateTime.now();
      final eventSocket = _eventSocket!;
      unawaited(_events(eventReader, eventSocket));
      _ping = Timer.periodic(eventPingInterval, (_) {
        if (!_closed &&
            DateTime.now().difference(_lastEventAt) >= eventPingInterval) {
          log?.call('event idle; send ping');
          eventSocket.add(packet(13, []));
        }
      });
      if (openSession) {
        enter('OpenSession');
        await beginSession(firstTransaction: firstTransaction);
      }
      checkOpen();
      log?.call('PTP/IP command/event session ready $host:$port');
    } catch (e) {
      log?.call('connect failed stage=$stage endpoint=$endpoint cause=$e');
      if (epoch == _openEpoch) await close();
      throw PtpConnectionException(
        stage,
        endpoint,
        timedOut ? TimeoutException('握手超时', timeout) : e,
      );
    } finally {
      deadline.cancel();
    }
  }

  Future<void> beginSession({int firstTransaction = 0}) async {
    _transaction = firstTransaction;
    try {
      await command(0x1002, [1]);
    } on PtpException catch (e) {
      if (e.response != 0x201e) rethrow;
      await command(0x1003);
      _transaction = firstTransaction;
      await command(0x1002, [1]);
    }
  }

  Future<void> _events(_SocketReader reader, Socket eventSocket) async {
    try {
      while (!_closed && identical(_eventSocket, eventSocket)) {
        // An idle event stream is normal. Keep its pending read alive and use
        // the protocol ping only when the channel has been quiet.
        final (type, len) = await reader.header(timeout: null);
        final payload = await reader.read(len);
        _lastEventAt = DateTime.now();
        if (type == 14) {
          log?.call('event pong received');
          continue;
        }
        if (type == 13) {
          _eventSocket?.add(packet(14, []));
          continue;
        }
        if (type != 8 || payload.length < 6) continue;
        final r = PtpReader(payload);
        final code = r.u16();
        r.u32();
        final params = <int>[];
        while (r.offset + 4 <= payload.length) {
          params.add(r.u32());
        }
        onEvent?.call(code, params);
      }
    } catch (e) {
      if (!_closed && identical(_eventSocket, eventSocket)) {
        final reason = '相机事件通道已断开：$e';
        log?.call(reason);
        await close();
        onClosed?.call(reason);
      }
    }
  }

  Future<Uint8List> _execute(
    int code,
    List<int> params, {
    bool receiving = false,
    Uint8List? outgoing,
    IOSink? sink,
    void Function(int)? progress,
    bool Function()? cancelled,
  }) async {
    final socket = _socket, reader = _reader;
    if (socket == null || reader == null || _closed) {
      throw const SocketException('相机未连接');
    }
    final epoch = _openEpoch;
    final deadline = sink == null
        ? Timer(operationTimeout, () {
            if (epoch == _openEpoch) unawaited(close());
          })
        : null;
    final tx = _transaction++;
    try {
      log?.call(
        'send op=0x${code.toRadixString(16)} tx=$tx phase=${outgoing == null ? 1 : 2} params=$params',
      );
      socket.add(
        packet(6, [
          ...ptpWords([outgoing != null ? 2 : 1]),
          ...ptpU16(code),
          ...ptpWords([tx, ...params]),
        ]),
      );
      if (outgoing != null) {
        socket.add(
          packet(9, [
            ...ptpWords([tx, outgoing.length, 0]),
          ]),
        );
        socket.add(
          packet(12, [
            ...ptpWords([tx]),
            ...outgoing,
          ]),
        );
      }
      await socket.flush();
      final collected = BytesBuilder(copy: false);
      Uint8List? direct;
      var received = 0;
      int? expected;
      try {
        while (true) {
          if (cancelled?.call() == true) {
            await close();
            throw StateError('传输已取消，请重新连接相机');
          }
          final (type, length) = await reader.header();
          if (type == 13) {
            await reader.read(length);
            socket.add(packet(14, []));
            continue;
          }
          if (type == 9) {
            final r = PtpReader(await reader.read(length));
            if (r.u32() != tx) throw const FormatException('PTP 数据事务不匹配');
            if (expected != null || received != 0) {
              throw const FormatException('重复的 PTP 数据起始包');
            }
            expected = r.u64();
            if (sink == null) {
              if (expected > 32 * 1024 * 1024) {
                throw const FormatException('相机元数据超过限制');
              }
              direct = Uint8List(expected);
            }
            continue;
          }
          if (type == 10 || type == 12) {
            if (length < 4 || PtpReader(await reader.read(4)).u32() != tx) {
              throw const FormatException('PTP 数据事务不匹配');
            }
            var remaining = length - 4;
            while (remaining > 0) {
              if (cancelled?.call() == true) {
                await close();
                throw StateError('传输已取消，请重新连接相机');
              }
              if (direct != null) {
                final count = min(remaining, 65536);
                if (received + count > direct.length) {
                  throw const FormatException('相机传输长度超出声明');
                }
                await reader.readInto(direct, received, count);
                received += count;
                remaining -= count;
                progress?.call(received);
                continue;
              }
              final bytes = await reader.read(min(remaining, 65536));
              remaining -= bytes.length;
              received += bytes.length;
              if (sink != null) {
                sink.add(bytes);
                if (received % (1024 * 1024) < bytes.length) await sink.flush();
              } else {
                if (received > 32 * 1024 * 1024) {
                  throw const FormatException('相机元数据超过限制');
                }
                collected.add(bytes);
              }
              progress?.call(received);
            }
            continue;
          }
          if (type != 7) throw FormatException('PTP/IP 非预期响应类型 $type');
          final r = PtpReader(await reader.read(length));
          final rc = r.u16(), responseTx = r.u32();
          log?.call(
            'response op=0x${code.toRadixString(16)} tx=$responseTx rc=0x${rc.toRadixString(16)} bytes=$received',
          );
          if (responseTx != tx) throw const FormatException('PTP 响应事务不匹配');
          if (rc != 0x2001) throw PtpException(code, rc);
          if (expected != null && received != expected) {
            throw const FormatException('相机传输长度不一致');
          }
          return direct ?? collected.takeBytes();
        }
      } on PtpException {
        rethrow;
      } catch (e) {
        log?.call('operation failed op=0x${code.toRadixString(16)} tx=$tx: $e');
        if (epoch == _openEpoch) await close();
        rethrow;
      }
    } finally {
      deadline?.cancel();
    }
  }

  @override
  Future<Uint8List> data(int code, [List<int> params = const []]) =>
      _serial(() => _execute(code, params, receiving: true));
  @override
  Future<void> command(int code, [List<int> params = const []]) =>
      _serial(() async {
        await _execute(code, params);
      });
  @override
  Future<void> writeProperty(int property, Uint8List bytes) =>
      _serial(() async {
        await _execute(0x1016, [property], outgoing: bytes);
      });
  Future<void> download(
    int code,
    List<int> params,
    IOSink sink,
    void Function(int) progress,
    bool Function() cancelled,
  ) => _serial(() async {
    await _execute(
      code,
      params,
      receiving: true,
      sink: sink,
      progress: progress,
      cancelled: cancelled,
    );
  });
  @override
  Future<void> close() async {
    _openEpoch++;
    _closed = true;
    _ping?.cancel();
    _socket?.destroy();
    _eventSocket?.destroy();
    _socket = null;
    _eventSocket = null;
  }
}

String stableMediaKey(String input) {
  // Deterministic FNV-1a identifier; transfer completeness is checked by byte counts.
  var value = 0xcbf29ce484222325;
  for (final byte in utf8.encode(input)) {
    value = ((value ^ byte) * 0x100000001b) & 0x7fffffffffffffff;
  }
  return value.toRadixString(16);
}
