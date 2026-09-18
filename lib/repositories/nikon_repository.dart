import '../models/nikon_live_geometry.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import '../models/media_item.dart';
import '../models/camera_storage.dart';
import '../protocol/ptp.dart';
import 'camera_repository.dart';

class NikonRepository extends CameraRepository {
  NikonRepository({
    this.connectionTimeout = const Duration(seconds: 45),
    this.discoveryConnector,
  });
  final Duration connectionTimeout;
  final Future<Socket> Function(String address)? discoveryConnector;
  Future<List<MediaItem>>? _connecting;
  Object? _connectToken;
  int _discoveryEpoch = 0;
  String connectionStage = '';
  bool awaitingCameraConfirmation = false;
  bool pairingInProgress = false;
  void Function(String stage)? onConnectionStage;
  void _stage(String value) {
    connectionStage = value;
    log('connection progress=$value');
    onConnectionStage?.call(value);
  }

  @override
  bool get isDemo => false;
  PtpTransport? transport;
  PtpDeviceInfo? device;
  String mode = 'Wi-Fi',
      endpoint = '',
      sourceIdentity = '',
      directory = '',
      cache = '';
  List<MediaItem> media = [];
  List<Map<String, dynamic>> storages = [];
  final List<String> logs = [];
  final Map<int, PtpObjectInfo> _objects = {};
  final Map<String, Future<String?>> _thumbnails = {};
  List<int> _handles = [];
  static const pageSize = 20;
  final Map<String, Socket> _discoveredSockets = {};
  final Map<String, String> deviceNames = {};
  void clearDiscovery() {
    _discoveryEpoch++;
    for (final socket in _discoveredSockets.values) {
      socket.destroy();
    }
    _discoveredSockets.clear();
  }

  int? totalMediaCount;
  int? cachedMediaCount;
  String get _countCachePath =>
      '$cache/camera-count-${stableMediaKey(sourceIdentity)}.json';
  Future<void> _readCountCache() async {
    cachedMediaCount = null;
    if (cache.isEmpty) return;
    try {
      final saved =
          jsonDecode(await File(_countCachePath).readAsString()) as Map;
      if (saved['source'] == sourceIdentity) {
        cachedMediaCount = saved['count'] as int?;
      }
    } on FileSystemException {
      /* first connection */
    } on FormatException {
      /* rebuild damaged cache */
    }
  }

  Future<void> _countWrite = Future.value();
  Future<void> _saveCountCache() {
    _countWrite = _countWrite.then((_) => _writeCountCache());
    return _countWrite;
  }

  Future<void> _writeCountCache() async {
    final count = totalMediaCount;
    if (cache.isEmpty || count == null) return;
    cachedMediaCount = count;
    try {
      final file = File('$_countCachePath.tmp');
      await file.writeAsString(
        jsonEncode({'source': sourceIdentity, 'count': count}),
      );
      await file.rename(_countCachePath);
    } on FileSystemException catch (e) {
      log('count cache: $e');
    }
  }

  int _cursor = 0, _generation = 0;
  int _cancelEpoch = 0;
  String? _connectedMode;
  bool get hasMore => _cursor < _handles.length;
  bool downloading = false,
      monitoring = false,
      _cancelled = false,
      _polling = false;
  Timer? _poll;
  StreamSubscription<dynamic>? _nativeEvents;
  void Function()? onChanged;
  void Function(int bytes, int total)? onProgress;
  void Function(List<MediaItem>)? onNewMedia;
  void Function(List<MediaItem>)? onPushMedia;
  void Function(String message)? onDisconnected;
  void Function(Map<dynamic, dynamic> event)? onGpuEvent;
  Future<void> _tail = Future.value();
  Future<T> _serial<T>(Future<T> Function() work) {
    final result = _tail.then((_) => work());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  void log(String text) {
    logs.add('${DateTime.now().toIso8601String()} $text');
    if (logs.length > 500) logs.removeRange(0, logs.length - 500);
    if (_connecting != null ||
        text.startsWith('connection progress=') ||
        text.startsWith('monitor ') ||
        text.startsWith('Movie')) {
      // Keep recent connection diagnostics in the native log even when
      // live-view traffic rotates the in-memory protocol log.
      unawaited(
        nativeCamera
            .invokeMethod<void>('connectionTrace', {
              'message': text.replaceAll(
                RegExp(r'clientGuid=[0-9a-f]+'),
                'clientGuid=<redacted>',
              ),
            })
            .catchError((Object _) {}),
      );
    }
  }

  PtpTransport get _ptp => transport ?? (throw StateError('相机未连接'));
  Future<void> initialize() async {
    final paths =
        await nativeCamera.invokeMapMethod<String, dynamic>('directories') ??
        {};
    directory = paths['media'] as String;
    cache = paths['cache'] as String;
    _nativeEvents ??= const EventChannel('mirrorbridge/native_events')
        .receiveBroadcastStream()
        .listen(
          (event) {
            if (event is Map && event['type'].toString().startsWith('gpu')) {
              onGpuEvent?.call(event);
            }
            if (event is Map && event['type'] == 'cameraEvent') {
              _cameraEvent(
                (event['code'] as num).toInt(),
                List<int>.from(event['params'] as List),
              );
            }
            if (event is Map && event['type'] == 'progress') {
              onProgress?.call(
                (event['done'] as num).toInt(),
                (event['total'] as num).toInt(),
              );
            }
          },
          onError: (Object e) {
            log('native event error $e');
          },
        );
  }

  Future<List<Map<String, dynamic>>> discover(
    String connectionMode,
    List<String> recent, {
    void Function(int done, int total, String address)? onProgress,
    void Function(Map<String, dynamic> device)? onDevice,
    bool Function()? cancelled,
  }) async {
    clearDiscovery();
    final epoch = _discoveryEpoch;
    bool stopped() => epoch != _discoveryEpoch || cancelled?.call() == true;
    if (connectionMode == 'USB') {
      final found =
          (await nativeCamera.invokeListMethod<dynamic>('usbList') ?? [])
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
      if (stopped()) return [];
      for (final device in found) {
        onDevice?.call(device);
      }
      return found;
    }
    if (device != null &&
        transport is PtpIpTransport &&
        (transport as PtpIpTransport).isOpen) {
      final found = {'deviceId': endpoint, 'name': device!.model};
      onDevice?.call(found);
      return [found];
    }
    final network =
        await nativeCamera.invokeMapMethod<String, dynamic>('network', {
          'bind': false,
        }) ??
        {};
    if (stopped()) return [];
    final candidates = nikonDiscoveryCandidates(network, recent);
    log(
      'discovery interfaces=${network['interfaces']} candidates=${candidates.length}',
    );
    mode = connectionMode;
    var done = 0;
    final found = <String, Map<String, dynamic>>{};
    // DNS-SD resolves alongside TCP probing. Names never delay the first result.
    unawaited(() async {
      try {
        final names = await nativeCamera
            .invokeMapMethod<String, String>('discoverNames')
            .timeout(const Duration(seconds: 4));
        if (stopped() || names == null) return;
        deviceNames.addAll(names);
        for (final entry in names.entries) {
          final device = found[entry.key];
          if (device != null) {
            device['name'] = entry.value;
            onDevice?.call(Map<String, dynamic>.from(device));
          }
        }
      } catch (e) {
        log('device names: $e');
      }
    }());
    // Retain accepted sockets until selection; selection removes its socket
    // before invalidating this epoch, so late probes cannot close that session.
    final candidateIterator = candidates.iterator;
    while (!stopped()) {
      final batch = <String>[];
      while (batch.length < 8 && candidateIterator.moveNext()) {
        batch.add(candidateIterator.current);
      }
      if (batch.isEmpty) break;
      await Future.wait(
        batch.map((address) async {
          try {
            final socket =
                await (discoveryConnector?.call(address) ??
                    Socket.connect(
                      address,
                      15740,
                      timeout: const Duration(milliseconds: 300),
                    ));
            socket.done.ignore();
            if (stopped()) {
              socket.destroy();
              return;
            }
            _discoveredSockets[address] = socket;
            final device = <String, dynamic>{
              'deviceId': address,
              'name': deviceNames[address] ?? '相机设备（未广播名称）',
            };
            found[address] = device;
            onDevice?.call(Map<String, dynamic>.from(device));
          } on SocketException {
            // No service at this address.
          } on TimeoutException {
            // Continue probing other addresses.
          } finally {
            if (!stopped()) {
              onProgress?.call(++done, candidates.length, address);
            }
          }
        }),
      );
    }
    if (epoch == _discoveryEpoch && cancelled?.call() == true) clearDiscovery();
    return found.values.toList();
  }

  @override
  Future<List<MediaItem>> connect(String address, {Socket? commandSocket}) {
    if (_connecting != null) return _connecting!;
    final token = Object();
    _connectToken = token;
    final result =
        _connect(
          address,
          requestToken: token,
          commandSocket: commandSocket,
        ).timeout(
          connectionTimeout,
          onTimeout: () {
            if (identical(_connectToken, token)) unawaited(disconnect());
            throw TimeoutException(
              '连接超过 ${connectionTimeout.inSeconds} 秒（$connectionStage），请重试',
            );
          },
        );
    _connecting = result;
    result.then<void>(
      (_) {
        if (identical(_connecting, result)) {
          _connecting = null;
          _connectToken = null;
        }
      },
      onError: (Object _) {
        if (identical(_connecting, result)) {
          _connecting = null;
          _connectToken = null;
        }
      },
    );
    return result;
  }

  Future<List<MediaItem>> _connect(
    String address, {
    required Object requestToken,
    Socket? commandSocket,
  }) async {
    if (mode == _connectedMode &&
        endpoint == address &&
        device != null &&
        transport is PtpIpTransport &&
        (transport as PtpIpTransport).isOpen) {
      log('connect reused verified session endpoint=$address');
      return media;
    }
    commandSocket ??= _discoveredSockets.remove(address);
    clearDiscovery();
    final cleanup = _disconnect(preserveConnect: true);
    final generation = _generation;
    await cleanup;
    if (!identical(requestToken, _connectToken) || generation != _generation) {
      commandSocket?.destroy();
      throw StateError('连接已取消');
    }
    endpoint = address;
    _cancelled = false;
    var pairingTransition = true;
    var expired = false;
    final timer = Timer(connectionTimeout, () {
      expired = true;
      if (generation == _generation) unawaited(disconnect());
    });
    void checkAttempt() {
      if (expired) {
        throw TimeoutException(
          '连接超过 ${connectionTimeout.inSeconds} 秒（$connectionStage），请重试',
        );
      }
      if (generation != _generation) throw StateError('连接已取消');
    }

    Future<T> step<T>(Future<T> work) async {
      final value = await work;
      checkAttempt();
      return value;
    }

    List<int>? wirelessGuid;
    String? wirelessName;
    Map<String, dynamic>? usbIdentity;
    try {
      _stage('正在建立相机连接（最多 ${connectionTimeout.inSeconds} 秒）');
      await step(initialize());
      log('connect start mode=$mode endpoint=$address');
      await step(nativeCamera.invokeMethod('permissions'));
      await step(nativeCamera.invokeMethod('service', {'active': true}));
      if (mode == 'USB') {
        final allowed = await nativeCamera.invokeMethod<bool>('usbPermission', {
          'deviceId': address,
        });
        if (allowed != true) throw StateError('USB 访问未获授权');
        usbIdentity = await nativeCamera.invokeMapMethod<String, dynamic>(
          'usbOpen',
          {'deviceId': address},
        );
        checkAttempt();
        transport = UsbPtpTransport();
      } else {
        final network = await nativeCamera.invokeMapMethod<String, dynamic>(
          'network',
          {'host': address, 'bind': true},
        );
        final profile = File('$directory/ptp-client-guid.json');
        List<int> guid;
        if (await profile.exists()) {
          guid = List<int>.from(
            jsonDecode(await profile.readAsString()) as List,
          );
        } else {
          guid = List.generate(16, (_) => Random.secure().nextInt(256));
          await profile.writeAsString(jsonEncode(guid), flush: true);
        }
        if (guid.length != 16) throw const FormatException('本地 PTP 设备身份损坏');
        wirelessGuid = guid;
        wirelessName = network?['clientName'] as String? ?? 'MirrorBridge';
        final ip = PtpIpTransport(
          log: log,
          onClosed: (reason) {
            if (generation == _generation && !pairingTransition) {
              onDisconnected?.call(reason);
              unawaited(disconnect());
            }
          },
          onEvent: (code, params) {
            log('event 0x${code.toRadixString(16)} $params');
            _cameraEvent(code, params);
          },
        );
        checkAttempt();
        transport = ip;
        log(
          'network bound=${network?['bound']} wifi=${network?['wifi']} addresses=${network?['addresses']}',
        );
        _stage('正在握手，请留意相机上的确认提示');
        try {
          await step(
            ip.open(
              address,
              guid,
              name: wirelessName,
              commandSocket: commandSocket,
              firstTransaction: 0,
              timeout: commandSocket == null
                  ? const Duration(seconds: 12)
                  : const Duration(seconds: 5),
            ),
          );
        } catch (e) {
          checkAttempt();
          if (commandSocket == null || _explicitRejection(e)) rethrow;
          // A retained discovery socket may have expired on the camera while
          // the user was selecting it. Retry a fresh handshake once, same GUID.
          log('discovery socket expired; retry fresh handshake: $e');
          _stage('正在恢复发现时的连接');
          await step(
            ip.open(
              address,
              guid,
              name: wirelessName,
              firstTransaction: 0,
              timeout: const Duration(seconds: 12),
            ),
          );
        }
      }
      log('connect stage=GetDeviceInfo');
      device = await step(_readDeviceInfo(usbIdentity));
      if (!'${device!.make} ${device!.model}'.toLowerCase().contains('nikon')) {
        throw StateError('当前版本仅接入 Nikon，相机返回 ${device!.make} ${device!.model}');
      }
      if (mode != 'USB' &&
          (mode == 'STA' || device!.operations.contains(0x935a))) {
        final ip = transport as PtpIpTransport;
        Uint8List? status;
        try {
          _stage('正在读取相机配对状态');
          status = await step(ip.data(0x952b));
        } on PtpException catch (e) {
          if (e.response != 0x2005 || !device!.operations.contains(0x1004)) {
            rethrow;
          }
          log('Nikon GetPairingStatus unsupported; normal media session');
        }
        if (status != null) {
          validateNikonPairingStatus(status);
          log(
            'Nikon GetPairingStatus raw=${status.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}',
          );
          pairingTransition = true;
          log('connect stage=Nikon ConfirmPairing 0x935a [0x2001]');
          await step(ip.command(0x935a, [0x2001]));
          pairingInProgress = true;
          awaitingCameraConfirmation = !device!.operations.contains(0x1004);
          log(
            'Nikon ConfirmPairing acknowledged; reopen transfer session with same GUID',
          );
          // Pairing confirmation closes the initialization sockets without a
          // PTP CloseSession, then reopens the transfer connection.
          await ip.close();
          Object? lastError;
          for (var attempt = 0; attempt < 20; attempt++) {
            checkAttempt();
            _stage(
              awaitingCameraConfirmation
                  ? '请在相机“配对完成”页面按 OK／确认键，手机会自动继续连接。'
                  : '相机已确认，正在建立传输连接…',
            );
            await Future<void>.delayed(
              Duration(milliseconds: attempt == 0 ? 500 : 1500),
            );
            try {
              await step(
                ip.open(
                  address,
                  wirelessGuid!,
                  name: wirelessName!,
                  firstTransaction: 0,
                  openSession: false,
                  timeout: const Duration(seconds: 4),
                ),
              );
              device = await step(_readDeviceInfo(null));
              // Once transfer capabilities are observed, subsequent retries
              // must not ask the user to confirm the same pairing again.
              if (device!.operations.contains(0x1004)) {
                awaitingCameraConfirmation = false;
                _stage('相机已确认，正在建立传输连接…');
              }
              await step(ip.beginSession());
              if (device!.operations.contains(0x941c)) {
                await step(ip.data(0x941c));
                log('Nikon GetEventEx drained after OpenSession');
              }
              if (!device!.operations.contains(0x1004)) {
                throw StateError('相机仍处于配对模式，尚未开放传输会话');
              }
              // Read-only readiness is the authority; camera confirmation alone
              // does not mean the transfer service has finished switching modes.
              awaitingCameraConfirmation = false;
              _stage('正在确认相机传输状态');
              await step(_readStorages());
              lastError = null;
              log(
                'Nikon STA pairing confirmed; transfer session ready attempt=${attempt + 1}',
              );
              break;
            } catch (e) {
              checkAttempt();
              if (_explicitRejection(e)) rethrow;
              lastError = e;
              log('Nikon post-pairing reconnect attempt=${attempt + 1}: $e');
              await ip.close();
            }
          }
          if (lastError != null) {
            if (!awaitingCameraConfirmation) {
              throw StateError('相机已确认，但传输连接等待超时，请重试。详情：$lastError');
            }
            throw StateError(
              '配对信息已保存，但传输连接等待超时。'
              '请在相机“配对完成”页面按 J／确定，退出后点击“连接此地址”；'
              '通常无需忘记连接或重新配对。详情：$lastError',
            );
          }
        }
      }
      sourceIdentity =
          '${device!.make}:${device!.model}:${device!.serial.isEmpty ? address : device!.serial}';
      if (mode != 'USB') {
        if (device!.operations.contains(0x9435)) {
          try {
            await _ptp.command(0x9435, [0]);
          } on PtpException catch (e) {
            log('media application mode: $e');
          }
        }
        if (device!.operations.contains(0x90c2)) {
          try {
            await _ptp.command(0x90c2, [0]);
          } on PtpException catch (e) {
            log('media control mode: $e');
          }
        }
      }
      _stage('传输会话已建立，正在读取存储卡');
      for (var attempt = 0; ; attempt++) {
        try {
          await step(_readStorages());
          break;
        } on PtpException catch (e) {
          if (attempt >= 4 || e.response != 0x2019) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      }
      deviceNames[address] = device!.model;
      _objects.clear();
      foldersIndexed = false;
      await _readCountCache();
      _stage('相机已就绪，正在读取首屏照片');
      _handles = await step(_rawHandles());
      _cursor = 0;
      media = [];
      _thumbnails.clear();
      await step(_loadPage(pageSize));
      if (generation != _generation) throw StateError('连接已取消');
      _poll = Timer.periodic(const Duration(seconds: 2), (_) {
        unawaited(_checkNew());
      });
      _connectedMode = mode;
      pairingTransition = false;
      pairingInProgress = false;
      _stage('连接成功');
      _startIndexing(generation);
      log('connected ${device!.model} mode=$mode objects=${_handles.length}');
      return media;
    } catch (e) {
      log('connect failed $e');
      commandSocket?.destroy();
      if (generation == _generation) await disconnect();
      if (expired) {
        throw TimeoutException(
          '连接超过 ${connectionTimeout.inSeconds} 秒（$connectionStage），请重试',
        );
      }
      rethrow;
    } finally {
      timer.cancel();
    }
  }

  bool _explicitRejection(Object e) =>
      e is PtpInitRejected ||
      e is PtpConnectionException && _explicitRejection(e.cause);

  Future<PtpDeviceInfo> _readDeviceInfo(
    Map<String, dynamic>? usbIdentity,
  ) async {
    final ptp = _ptp;
    for (var attempt = 0; ; attempt++) {
      try {
        final bytes = await ptp.data(0x1001);
        log('GetDeviceInfo bytes=${bytes.length} attempt=$attempt');
        if (bytes.isEmpty && attempt < 3) {
          await Future<void>.delayed(const Duration(milliseconds: 350));
          continue;
        }
        final parsed = PtpDeviceInfo.parse(bytes);
        if (usbIdentity == null) return parsed;
        return PtpDeviceInfo(
          parsed.make.isEmpty
              ? usbIdentity['make'] as String? ?? 'Nikon'
              : parsed.make,
          parsed.model.isEmpty
              ? usbIdentity['model'] as String? ?? 'Nikon USB'
              : parsed.model,
          parsed.serial.isEmpty
              ? usbIdentity['serial'] as String? ?? ''
              : parsed.serial,
          parsed.operations,
          parsed.properties,
        );
      } catch (e) {
        if (e is PtpException && e.response == 0x2019 && attempt < 3) {
          log('GetDeviceInfo busy; retry attempt=$attempt');
          await Future<void>.delayed(const Duration(milliseconds: 350));
          continue;
        }
        // USB descriptors provide fallback identity only. Never invent
        // capabilities when DeviceInfo cannot be parsed.
        if (usbIdentity != null &&
            usbIdentity['vendorId'] == 1200 &&
            (e is FormatException || (e is PtpException && e.unsupported))) {
          log(
            'USB DeviceInfo unavailable, using USB descriptors, no advertised extensions: $e',
          );
          return PtpDeviceInfo(
            usbIdentity['make'] as String? ?? 'Nikon',
            usbIdentity['model'] as String? ?? 'Nikon USB',
            usbIdentity['serial'] as String? ?? '',
            {},
            {},
          );
        }
        rethrow;
      }
    }
  }

  Future<void> _readStorages() async {
    final ptp = _ptp;
    final next = <Map<String, dynamic>>[];
    final ids = PtpReader(await ptp.data(0x1004)).array32();
    for (final id in ids) {
      Uint8List data;
      try {
        data = await ptp.data(0x1005, [id]);
      } on PtpException catch (e) {
        if (e.response == 0x2013 || e.response == 0x2008) {
          log(
            'skip unavailable storage id=0x${id.toRadixString(16)} response=0x${e.response.toRadixString(16)}',
          );
          continue;
        }
        rethrow;
      }
      final r = PtpReader(data);
      final storageType = r.u16();
      r.u16();
      r.u16();
      final capacity = r.u64(), free = r.u64();
      r.u32();
      final label = r.string();
      final volumeLabel = r.offset < r.data.length ? r.string() : '';
      if (id == 0 || (id & 0xffff) == 0) continue;
      final slot = id >> 16;
      next.add({
        'slot': slot,
        'storageType': storageType,
        'description': label,
        'volumeLabel': volumeLabel,
        'id': id,
        'capacity': capacity,
        'free': free,
        'name': label.isEmpty ? (slot > 0 ? '卡槽 $slot' : '存储卡') : label,
      });
    }
    if (!identical(ptp, transport)) throw StateError('连接已取消');
    storages = next;
  }

  Future<List<int>> _rawHandles() async {
    final ptp = _ptp;
    final all = <int>{};
    for (final s in storages) {
      all.addAll(
        PtpReader(await ptp.data(0x1007, [s['id'] as int, 0, 0])).array32(),
      );
    }
    return all.toList().reversed.toList();
  }

  bool indexing = false, foldersIndexed = false;
  int _indexEpoch = 0;
  void _startIndexing(int generation) {
    final epoch = ++_indexEpoch;
    if (_handles.every(_objects.containsKey)) {
      indexing = false;
      totalMediaCount = _handles.where((h) => _isMedia(_objects[h]!)).length;
      foldersIndexed = true;
      unawaited(_saveCountCache());
      return;
    }
    indexing = true;
    totalMediaCount = null;
    unawaited(() async {
      try {
        for (final h in List<int>.from(_handles)) {
          if (epoch != _indexEpoch || generation != _generation) return;
          if (_objects.containsKey(h)) continue;
          while (monitoring || _monitorRequested || downloading) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
            if (epoch != _indexEpoch || generation != _generation) return;
          }
          await _serial(() async {
            if (epoch != _indexEpoch ||
                generation != _generation ||
                monitoring ||
                _monitorRequested ||
                downloading) {
              return;
            }
            if (!_objects.containsKey(h)) {
              try {
                _objects[h] = PtpObjectInfo.parse(await _ptp.data(0x1008, [h]));
              } on PtpException catch (e) {
                if (e.response != 0x2009) rethrow;
              }
            }
          });
          // Give user commands a turn between individual metadata requests.
          await Future<void>.delayed(Duration.zero);
        }
        if (epoch == _indexEpoch && generation == _generation) {
          // Missing entries can occur when a monitor starts between the checks.
          // A later background poll completes the count without blocking entry.
          totalMediaCount = _handles.every(_objects.containsKey)
              ? _handles.where((h) => _isMedia(_objects[h]!)).length
              : null;
        }
      } catch (e) {
        log('background media index: $e');
      } finally {
        if (epoch == _indexEpoch && generation == _generation) {
          indexing = false;
          foldersIndexed = foldersIndexed || totalMediaCount != null;
          unawaited(_saveCountCache());
          onChanged?.call();
        }
      }
    }());
  }

  bool _isMedia(PtpObjectInfo o) =>
      o.format != 0x3001 &&
      RegExp(
        r'\.(jpe?g|nef|nrw|mp4|mov)$',
        caseSensitive: false,
      ).hasMatch(o.name);

  Future<MediaItem?> _item(int handle) async {
    final obj =
        _objects[handle] ??
        PtpObjectInfo.parse(await _ptp.data(0x1008, [handle]));
    _objects[handle] = obj;
    if (obj.format == 0x3001 || obj.name.isEmpty) return null;
    final extension = obj.name.split('.').last.toLowerCase();
    if (!['jpg', 'jpeg', 'nef', 'nrw', 'mp4', 'mov'].contains(extension)) {
      return null;
    }
    var bytes = obj.bytes;
    if (device!.operations.contains(0x9421) &&
        (bytes == 0xffffffff || bytes == 0)) {
      bytes = PtpReader(await _ptp.data(0x9421, [handle])).u64();
    }
    if (bytes == 0 || bytes == 0xffffffff) {
      log('file size unavailable ${obj.name}');
      return null;
    }
    var folder = _objects[obj.parent]?.name;
    if (folder == null && obj.parent != 0 && obj.parent != 0xffffffff) {
      try {
        final parent = PtpObjectInfo.parse(
          await _ptp.data(0x1008, [obj.parent]),
        );
        _objects[obj.parent] = parent;
        folder = parent.name;
      } on PtpException catch (e) {
        log('folder unavailable $e');
      }
    }
    return _mediaItem(handle, obj, bytes, folder);
  }

  MediaItem _mediaItem(
    int handle,
    PtpObjectInfo obj,
    int bytes,
    String? folder,
  ) {
    final extension = obj.name.split('.').last.toLowerCase();
    final key = stableMediaKey(
      '$sourceIdentity:${obj.storage}:$folder:${obj.name}:$bytes:${obj.date?.toIso8601String() ?? handle}',
    );
    return MediaItem(
      id: key,
      name: obj.name,
      kind: ['nef', 'nrw'].contains(extension)
          ? MediaKind.raw
          : ['mp4', 'mov'].contains(extension)
          ? MediaKind.video
          : MediaKind.jpg,
      date: obj.date ?? DateTime.fromMillisecondsSinceEpoch(0),
      bytes: bytes,
      card: obj.storage >> 16,
      folder: folder ?? '未知文件夹',
      asset: '',
      handle: handle,
      storageId: obj.storage,
      parentHandle: obj.parent,
      source: sourceIdentity,
      exif: {
        'Make': device!.make,
        'Model': device!.model,
        if (obj.width > 0) 'ImageWidth': '${obj.width}',
        if (obj.height > 0) 'ImageLength': '${obj.height}',
        if (obj.date != null) 'DateTimeOriginal': '${obj.date}',
      },
    );
  }

  // Metadata is indexed independently of thumbnail/media pagination.
  List<MediaItem>? get indexedMedia {
    if (totalMediaCount == null) return null;
    final loaded = {for (final item in media) item.handle: item};
    return [
      for (final h in _handles)
        if (_objects[h] case final obj? when _isMedia(obj))
          loaded[h] ??
              _mediaItem(h, obj, obj.bytes, _objects[obj.parent]?.name),
    ];
  }

  List<CameraFolder> get folders {
    final active = storages.map((s) => s['id']).toSet();
    return [
      for (final entry in _objects.entries)
        if (entry.value.format == 0x3001 &&
            active.contains(entry.value.storage))
          CameraFolder(
            entry.value.storage,
            entry.key,
            entry.value.name,
            path: _folderPath(entry.key),
          ),
    ]..sort((a, b) {
      final storage = a.storageId.compareTo(b.storageId);
      return storage != 0 ? storage : a.name.compareTo(b.name);
    });
  }

  String _folderPath(int handle) {
    final names = <String>[];
    final seen = <int>{};
    var current = handle;
    while (seen.add(current)) {
      final obj = _objects[current];
      if (obj == null || obj.format != 0x3001) break;
      names.insert(0, obj.name);
      current = obj.parent;
    }
    return names.join('/');
  }

  bool isInFolder(int storageId, int parent, int folder) {
    final seen = <int>{};
    var current = parent;
    while (seen.add(current)) {
      if (current == folder) return true;
      final obj = _objects[current];
      if (obj == null || obj.storage != storageId) break;
      current = obj.parent;
    }
    return false;
  }

  Future<void> readFolders() => _serial(() async {
    if (foldersIndexed || downloading || monitoring) return;
    final generation = _generation;
    final ptp = _ptp;
    for (final storage in storages) {
      List<int> handles;
      try {
        handles = PtpReader(
          await ptp.data(0x1007, [storage['id'] as int, 0x3001, 0]),
        ).array32();
      } on PtpException catch (e) {
        if (e.unsupported || e.response == 0x2014) {
          // Cameras without format filtering finish via the background index.
          log('directory query unsupported; using background index');
          return;
        }
        rethrow;
      }
      for (final handle in handles) {
        if (generation != _generation) return;
        try {
          _objects[handle] ??= PtpObjectInfo.parse(
            await ptp.data(0x1008, [handle]),
          );
        } on PtpException catch (e) {
          if (e.response != 0x2009) rethrow;
        }
      }
    }
    if (generation != _generation) return;
    foldersIndexed = true;
    onChanged?.call();
  });

  Future<void> _loadPage(
    int count, {
    bool Function(MediaItem)? matches,
    bool revalidate = false,
    Map<String, MediaItem> previous = const {},
  }) async {
    final generation = _generation;
    final existing = media.map((e) => e.id).toSet();
    var added = 0;
    while (_cursor < _handles.length && added < count) {
      final h = _handles[_cursor++];
      try {
        final cached = _objects.containsKey(h);
        var item = await _item(h);
        if (cached &&
            revalidate &&
            item != null &&
            (matches?.call(item) ?? true)) {
          // Only re-read candidate matches. Cached non-matches can be skipped
          // without a PTP request; changed identity invalidates its thumbnail.
          _objects.remove(h);
          item = await _item(h);
        }
        if (generation != _generation) throw StateError('连接已取消');
        if (item != null && existing.add(item.id)) {
          final old = previous[item.id];
          if (old != null) item.thumbnailPath = old.thumbnailPath;
          media.add(item);
          if (matches?.call(item) ?? true) added++;
        }
      } on PtpException catch (e) {
        if (e.response != 0x2009) rethrow;
        log('removed object $h');
      }
    }
    onChanged?.call();
  }

  final int _thumbnailVersion = 0;
  int _mediaReadRequests = 0;
  Future<void> _browse(Future<void> Function() work) async {
    _mediaReadRequests++;
    try {
      await _serial(work);
    } finally {
      _mediaReadRequests--;
    }
  }

  Future<void> loadMore() => _browse(() async {
    if (!downloading && !monitoring) await _loadPage(pageSize);
  });

  Future<void> refresh() => _refresh();

  Future<void> refreshFiltered(bool Function(MediaItem) matches) =>
      _refresh(matches: matches);

  Future<void> _refresh({bool Function(MediaItem)? matches}) {
    _indexEpoch++;
    indexing = false;
    return _browse(() async {
      if (downloading || monitoring) return;
      await _readStorages();
      final handles = await _rawHandles();
      final existing = handles.toSet();
      final previous = {for (final item in media) item.id: item};
      _objects.removeWhere((handle, _) => !existing.contains(handle));
      // Keep thumbnail keys and metadata for unchanged, off-screen objects.
      // The controller retains the previous list until this page is ready.
      _handles = handles;
      _cursor = 0;
      media = [];
      await _loadPage(
        pageSize,
        matches: matches,
        revalidate: true,
        previous: previous,
      );
      _startIndexing(_generation);
      onChanged?.call();
    });
  }

  Future<void> checkNewPhotos() => _checkNew();

  Future<void> _checkNew() async {
    if (_connectedMode == null ||
        transport == null ||
        downloading ||
        monitoring ||
        _monitorRequested ||
        _polling) {
      return;
    }
    final generation = _generation;
    _polling = true;
    try {
      await _serial(() async {
        if (generation != _generation ||
            transport == null ||
            downloading ||
            monitoring) {
          return;
        }
        final next = (await _rawHandles()).toSet();
        final old = _handles.toSet();
        if (next.length == old.length && next.containsAll(old)) return;
        _objects.removeWhere((h, _) => !next.contains(h));
        final fresh = next.where((h) => !old.contains(h)).toList();
        final added = <MediaItem>[];
        for (final h in fresh) {
          final item = await _item(h);
          if (item != null) added.add(item);
        }
        // Append discovery handles without moving the pagination cursor of already loaded items.
        _handles.addAll(fresh);
        final removedBeforeCursor = _handles
            .take(_cursor)
            .where((h) => !next.contains(h))
            .length;
        _handles.removeWhere((h) => !next.contains(h));
        _cursor -= removedBeforeCursor;
        totalMediaCount = _handles.every(_objects.containsKey)
            ? _handles.where((h) => _isMedia(_objects[h]!)).length
            : null;
        unawaited(_saveCountCache());
        media.insertAll(0, added.where((m) => !media.any((e) => e.id == m.id)));
        media.removeWhere((m) => !next.contains(m.handle));
        onChanged?.call();
        if (added.isNotEmpty) {
          onNewMedia?.call(added);
        }
      });
    } catch (e) {
      // A requested disconnect may close an in-flight poll. Its late failure
      // must not turn a clean disconnect into an error or close a new session.
      if (generation != _generation) return;
      log('auto discovery: $e');
      if (e is SocketException ||
          e is TimeoutException ||
          e is PlatformException) {
        onDisconnected?.call('相机连接已中断：$e');
        await disconnect();
      }
    } finally {
      _polling = false;
    }
  }

  void _cameraEvent(int code, List<int> params) {
    if (code == 0x4002 || code == 0x4003 || code == 0x400a) {
      unawaited(_checkNew());
    }
    // Nikon event codes observed for recording interrupted, complete and started.
    if (code == 0xc105 || code == 0xc108 || code == 0xc10a) {
      if (code == 0xc108) _movieComplete = true;
      movieRecording = code == 0xc10a;
      onChanged?.call();
    }
    if (code == 0x4006) {
      monitorPropertiesRevision++;
      if (params.isNotEmpty) monitorChangedProperties.add(params.first);
    }

    if (code != 0x4009 ||
        params.isEmpty ||
        params.first == 0 ||
        device == null) {
      return;
    }
    final generation = _generation;
    unawaited(
      _serial(() async {
        if (generation != _generation || transport == null || monitoring) {
          return;
        }
        try {
          final item = await _item(params.first);
          if (item == null) return;
          if (!media.any((m) => m.id == item.id)) media.insert(0, item);
          if (!_handles.contains(item.handle)) _handles.add(item.handle);
          onChanged?.call();
          onPushMedia?.call([item]);
          log('RequestObjectTransfer ${item.name}');
        } catch (e) {
          log('RequestObjectTransfer failed: $e');
        }
      }),
    );
  }

  Future<String?> thumbnail(MediaItem item) {
    if (item.thumbnailPath.isNotEmpty &&
        File(item.thumbnailPath).existsSync()) {
      return Future.value(item.thumbnailPath);
    }
    return _thumbnails.putIfAbsent(
      item.id,
      () => _serial(() async {
        if (_mediaReadRequests > 0 ||
            downloading ||
            monitoring ||
            transport == null ||
            item.source != sourceIdentity) {
          _thumbnails.remove(item.id);
          return null;
        }
        final file = File(
          '$cache/${item.id}_v${_generation}_${_thumbnailVersion}_thumb.jpg',
        );
        if (await file.exists()) {
          item.thumbnailPath = file.path;
          return file.path;
        }
        try {
          final bytes = await _ptp.data(0x100a, [item.handle]);
          final jpeg = extractJpeg(bytes);
          if (jpeg != null) {
            await file.writeAsBytes(jpeg);
            item.thumbnailPath = file.path;
            return file.path;
          }
        } catch (e) {
          log('thumbnail ${item.name}: $e');
        }
        _thumbnails.remove(item.id);
        return null;
      }),
    );
  }

  Future<void> clearCaches() => _serial(() async {
    await _countWrite;
    await nativeCamera.invokeMethod<void>('clearCaches');
    _thumbnails.clear();
    _viewDirectories.clear();
    for (final item in media) {
      item.thumbnailPath = '';
    }
  });

  final _viewDirectories = <String, Directory>{};

  Future<void> releaseViewingSource(String path) async {
    final owned = _viewDirectories.remove(path);
    if (owned != null && await owned.exists()) {
      await owned.delete(recursive: true);
    }
  }

  Future<String> prepareViewingSource(
    MediaItem item, {
    void Function(int, int)? progress,
    bool Function()? cancelled,
  }) => _serial(() async {
    if (cancelled?.call() == true) throw StateError('查看已关闭');
    var source = item.sourceUri.isNotEmpty
        ? item.sourceUri
        : item.albumUri.isNotEmpty
        ? item.albumUri
        : item.localPath;
    final remote = source.isEmpty;
    if (remote && (monitoring || downloading)) throw StateError('请先结束监看或同步');
    if (remote && item.source != sourceIdentity) {
      throw StateError('文件不属于当前连接的相机');
    }
    final paths = await nativeCamera.invokeMapMethod<String, dynamic>(
      'directories',
    );
    final cacheRoot = paths?['cache'] as String?;
    if (cacheRoot == null) throw StateError('无法读取查看缓存目录');
    final root = await Directory(
      '$cacheRoot/image_view_sessions',
    ).create(recursive: true);
    final session = await root.createTemp('view_');
    try {
      if (remote) {
        _cancelled = false;
        downloading = true;
        final extension = item.name
            .split('.')
            .last
            .replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
        final partial = File('${session.path}/source.$extension.part');
        await _readObject(
          item,
          partial,
          progress: progress,
          cancelled: cancelled,
        );
        source = (await partial.rename(
          '${session.path}/source.$extension',
        )).path;
      }
      if (cancelled?.call() == true) throw StateError('查看已关闭');
      final path = await nativeCamera.invokeMethod<String>('fullImageSource', {
        'source': source,
        'viewDirectory': session.path,
      });
      if (path == null || path.isEmpty) throw StateError('此文件没有可显示的大图');
      _viewDirectories[path] = session;
      return path;
    } catch (_) {
      if (await session.exists()) await session.delete(recursive: true);
      rethrow;
    } finally {
      if (remote) downloading = false;
    }
  });

  Future<void> _readObject(
    MediaItem item,
    File destination, {
    void Function(int, int)? progress,
    bool Function()? cancelled,
  }) async {
    var offset = 0;
    // Restart at byte zero: a persisted prefix cannot prove the camera object
    // was not replaced by a same-name/same-size file between sessions.
    await destination.writeAsBytes([]);
    if (transport is UsbPtpTransport) {
      await nativeCamera.invokeMethod('usbDownload', {
        'handle': item.handle,
        'path': destination.path,
        'bytes': item.bytes,
        'offset': offset,
        'quiet': progress == null,
        'partial64': device!.operations.contains(0x9431),
        'whole':
            !device!.operations.contains(0x9431) &&
            !device!.operations.contains(0x101b),
      });
    } else {
      final ip = transport! as PtpIpTransport;
      var opcode = device!.operations.contains(0x9431)
          ? 0x9431
          : device!.operations.contains(0x101b) && item.bytes <= 0xffffffff
          ? 0x101b
          : 0x1009;
      while (offset < item.bytes) {
        if (_cancelled || cancelled?.call() == true) throw StateError('传输已取消');
        if (opcode == 0x1009) offset = 0;
        final before = offset;
        final count = min(4 * 1024 * 1024, item.bytes - offset);
        final params = opcode == 0x9431
            ? [item.handle, offset & 0xffffffff, offset >> 32, count, 0]
            : opcode == 0x101b
            ? [item.handle, offset, count]
            : [item.handle];
        final sink = destination.openWrite(
          mode: offset == 0 ? FileMode.write : FileMode.append,
        );
        try {
          var received = 0;
          await ip.download(opcode, params, sink, (n) {
            received = n;
            progress?.call(before + n, item.bytes);
          }, () => _cancelled || cancelled?.call() == true);
          await sink.flush();
          if (received != (opcode == 0x1009 ? item.bytes : count)) {
            throw const FormatException('下载分块长度不一致');
          }
          offset += received;
        } on PtpException catch (e) {
          if (!e.unsupported || opcode == 0x1009) rethrow;
          await sink.close();
          final f = await destination.open(mode: FileMode.append);
          await f.truncate(before);
          await f.close();
          opcode = opcode == 0x9431 && item.bytes <= 0xffffffff
              ? 0x101b
              : 0x1009;
          continue;
        } finally {
          await sink.close();
        }
      }
    }
    if (_cancelled || cancelled?.call() == true) throw StateError('传输已取消');
    if (await destination.length() != item.bytes) {
      throw const FormatException('文件大小校验失败');
    }
  }

  @override
  Future<void> transfer(MediaItem item, {bool fail = false}) {
    final epoch = _cancelEpoch;
    return _serial(() async {
      if (epoch != _cancelEpoch) throw StateError('传输已取消');
      if (monitoring) throw StateError('请先退出远程监看再同步');
      if (item.source != sourceIdentity) throw StateError('文件不属于当前连接的相机');
      downloading = true;
      _cancelled = false;
      final safeName = item.name.replaceAll(
        RegExp(r'[^\w\u4e00-\u9fff. -]'),
        '_',
      );
      Directory? session;
      try {
        // Never reuse a file merely because its metadata ID and size match.
        {
          final paths =
              await nativeCamera.invokeMapMethod<String, dynamic>(
                'directories',
              ) ??
              {};
          if ((paths['freeBytes'] as num).toInt() <
              item.bytes * 2 + 16 * 1024 * 1024) {
            throw StateError('手机空间不足，需为下载和系统相册保留空间');
          }
          final cacheRoot = paths['cache'] as String;
          session = await Directory(cacheRoot).createTemp('sync_');
        }
        final finalFile = File('${session.path}/$safeName');
        final partial = File('${finalFile.path}.part');
        await _readObject(item, partial, progress: onProgress);
        await partial.rename(finalFile.path);
        item.localPath = finalFile.path;
        item.origin = MediaOrigin.cameraSync;
        item.exif = Map<String, String>.from(
          await nativeCamera.invokeMapMethod<String, String>('exif', {
                'path': finalFile.path,
              }) ??
              {},
        );
        item.thumbnailPath =
            await nativeCamera.invokeMethod<String>('thumbnail', {
              'path': finalFile.path,
            }) ??
            item.thumbnailPath;
        // Publish this completed transfer and retain its exact local URI.
        item.albumUri =
            await nativeCamera.invokeMethod<String>('publish', {
              'path': finalFile.path,
              'name': item.name,
            }) ??
            '';
        if (item.albumUri.isEmpty) throw StateError('系统相册发布失败');
        await nativeCamera.invokeMethod('releasePublishedCopy', {
          'path': finalFile.path,
          'uri': item.albumUri,
        });
        item.sourceUri = item.albumUri;
        item.localPath = '';
        onProgress?.call(item.bytes, item.bytes);
        log('download/publish complete ${item.name} ${item.bytes}');
      } finally {
        // Failed/cancelled downloads are disposable; the camera remains the source.
        try {
          if (session != null && await session.exists()) {
            await session.delete(recursive: true);
          }
        } finally {
          item.localPath = '';
          downloading = false;
        }
        if (transport is PtpIpTransport &&
            !(transport as PtpIpTransport).isOpen) {
          onDisconnected?.call('相机连接已关闭，请重新连接后重试任务');
        }
      }
    });
  }

  Future<void> deleteRemote(List<MediaItem> items) => _serial(() async {
    if (downloading || monitoring) throw StateError('请先结束同步或监看');
    for (final item in items) {
      if (item.source != sourceIdentity) throw StateError('相机身份已变化');
      await _ptp.command(0x100b, [item.handle, 0]);
      media.removeWhere((m) => m.id == item.id);
      final index = _handles.indexOf(item.handle);
      if (index >= 0 && index < _cursor) _cursor--;
      _handles.remove(item.handle);
      if (totalMediaCount != null) {
        totalMediaCount = max(0, totalMediaCount! - 1);
      }
    }
    onChanged?.call();
  });
  @override
  Future<void> cancel() async {
    _cancelEpoch++;
    _cancelled = true;
    if (transport is UsbPtpTransport) {
      await nativeCamera.invokeMethod('usbCancel');
      await disconnect();
      onDisconnected?.call('USB 传输已取消，连接已释放，请重新连接相机');
    }
  }

  @override
  Future<void> disconnect() => _disconnect();

  Future<void> _disconnect({bool preserveConnect = false}) async {
    awaitingCameraConfirmation = false;
    pairingInProgress = false;
    if (!preserveConnect) {
      _connecting = null;
      _connectToken = null;
    }
    clearDiscovery();
    _cancelEpoch++;
    _generation++;
    final generation = _generation;
    _indexEpoch++;
    indexing = false;
    _poll?.cancel();
    _cancelled = true;
    final t = transport;
    transport = null;
    monitoring = false;
    _monitorRequested = false;
    _remoteModeActive = false;
    if (t != null) {
      try {
        await t.close();
      } catch (e) {
        log('close $e');
      }
    }
    await _countWrite;
    if (generation != _generation) return;
    device = null;
    totalMediaCount = null;
    _connectedMode = null;
    try {
      await nativeCamera.invokeMethod('unbind');
      if (generation != _generation) return;
      await nativeCamera.invokeMethod('service', {'active': false});
    } on MissingPluginException {
      /* Unit-test host. */
    }
  }

  Future<void> dispose() async {
    await disconnect();
    await _nativeEvents?.cancel();
  }

  int liveImageSize = 3;
  bool _monitorRequested = false;
  bool _remoteModeActive = false;
  bool movieRecording = false;
  NikonLiveGeometry? liveGeometry;
  int monitorPropertiesRevision = 0;
  final monitorChangedProperties = <int>{};
  int _streamFrames = 0,
      _streamBytes = 0,
      _streamMicros = 0,
      _streamMaxMicros = 0;
  final _streamClock = Stopwatch();
  bool _applicationPropertyFallback = false;
  int? _liveOpcode;
  int _liveRecoveries = 0;
  bool _frameHeaderLogged = false;
  bool _movieComplete = false;
  DateTime _lastMonitorEvents = DateTime.fromMillisecondsSinceEpoch(0);
  bool supportsOperation(int code) => device?.operations.contains(code) == true;

  Future<void> _deviceReady({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (!supportsOperation(0x90c8)) return;
    final clock = Stopwatch()..start();
    while (true) {
      try {
        await _ptp.command(0x90c8);
        return;
      } on PtpException catch (e) {
        if (e.response != 0x2019) rethrow;
      }
      if (clock.elapsed >= timeout) throw TimeoutException('相机持续忙碌，请检查当前拍摄模式');
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  }

  // Cache OperationNotSupported so later mode changes use the property route.
  Future<void> _applicationMode(int mode) async {
    if (transport is UsbPtpTransport) {
      await nativeCamera.invokeMethod('usbApplicationMode', {'mode': mode});
      return;
    }
    if (!_applicationPropertyFallback && supportsOperation(0x9435)) {
      try {
        await _ptp.command(0x9435, [mode]);
        return;
      } on PtpException catch (e) {
        if (e.response != 0x2005) rethrow;
        _applicationPropertyFallback = true;
      }
    }
    if (_applicationPropertyFallback ||
        device?.properties.contains(0xd1f0) == true) {
      await _ptp.writeProperty(0xd1f0, Uint8List.fromList([mode]));
    }
  }

  Future<int?> _monitorValue(int code) async {
    try {
      final data = await _ptp.data(0x1015, [code]);
      final r = PtpReader(data);
      return data.length >= 4
          ? r.u32()
          : data.length >= 2
          ? r.u16()
          : r.u8();
    } on PtpException catch (e) {
      if (!e.unsupported && e.response != 0x2019) rethrow;
      log('monitor property 0x${code.toRadixString(16)}: $e');
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<void> setLiveImageSize(int value) => _serial(() async {
    if (value != 2 && value != 3) throw ArgumentError('取景尺寸仅支持 VGA 或 XGA');
    if (monitoring) {
      await _ptp.writeProperty(0xd1ac, Uint8List.fromList([value]));
      final actual = await _monitorValue(0xd1ac);
      if (actual != value) throw StateError('相机未确认取景尺寸');
    }
    liveImageSize = value;
    log('monitor live image profile confirmed d1ac=$value');
  });

  Future<void> startMonitor() {
    _monitorRequested = true;
    return _serial(() async {
      if (monitoring) return;
      if (downloading) {
        _monitorRequested = false;
        throw StateError('请先结束同步');
      }
      if (!supportsOperation(0x9201)) {
        _monitorRequested = false;
        throw StateError('当前连接模式未提供实时取景，请在相机上切换到遥控拍摄模式');
      }
      final ptp = _ptp;
      if (ptp is PtpIpTransport) {
        ptp.operationTimeout = const Duration(seconds: 5);
      }
      try {
        _remoteModeActive = true;
        _applicationPropertyFallback = false;
        if (supportsOperation(0x9206)) {
          try {
            await ptp.command(0x9206);
            log('monitor startup released previous focus drive');
          } on PtpException catch (e) {
            log('monitor startup focus release: $e');
          }
        }
        if (supportsOperation(0x90c2)) await ptp.command(0x90c2, [1]);
        try {
          await ptp.writeProperty(0xd1ac, Uint8List.fromList([liveImageSize]));
          log('monitor live image profile requested d1ac=$liveImageSize');
          await ptp.writeProperty(0xd1bc, Uint8List.fromList([3]));
        } on PtpException catch (e) {
          log('live image profile: $e');
        }
        await _applicationMode(1);
        log('monitor startup application mode ready');
        if (ptp is UsbPtpTransport) {
          await nativeCamera.invokeMethod('usbLiveStart');
        } else {
          await ptp.command(0x9201);
          log('monitor startup live view started');
          await _deviceReady();
        }
        monitoring = true;
        _focusModeCache.clear();
        resetLightMeter();
        liveGeometry = null;
        _frameHeaderLogged = false;
        _streamFrames = 0;
        _streamBytes = 0;
        _streamMicros = 0;
        _streamMaxMicros = 0;
        _streamClock
          ..reset()
          ..start();
        _liveRecoveries = 0;
        _liveOpcode = supportsOperation(0x9428) ? 0x9428 : 0x9203;
      } catch (e) {
        monitoring = false;
        try {
          await _restoreMediaMode(endLive: true);
        } catch (cleanup) {
          log('monitor startup cleanup: $cleanup');
        }
        rethrow;
      } finally {
        _monitorRequested = false;
      }
    });
  }

  Future<Uint8List?> liveFrame() => _serial(() async {
    if (movieRecording &&
        DateTime.now().difference(_lastMonitorEvents).inMilliseconds > 500) {
      _lastMonitorEvents = DateTime.now();
      await _pollMonitorEvents();
    }
    return _readLiveFrame();
  });

  Future<void> _pollMonitorEvents() async {
    if (!supportsOperation(0x941c)) return;
    final r = PtpReader(await _ptp.data(0x941c));
    final count = r.u32();
    if (count > (r.data.length - 4) ~/ 4) {
      throw const FormatException('相机事件数量无效');
    }
    for (var i = 0; i < count; i++) {
      final code = r.u16(), n = r.u16();
      r.need(n * 4);
      final params = List.generate(n, (_) => r.u32());
      log('monitor event 0x${code.toRadixString(16)} $params');
      _cameraEvent(code, params);
    }
    if (r.offset != r.data.length) throw const FormatException('相机事件含多余数据');
  }

  Future<void> _stopMovie() async {
    _movieComplete = false;
    await _ptp.command(0x920b);
    if (supportsOperation(0x941c)) {
      final timer = Stopwatch()..start();
      while (!_movieComplete && timer.elapsed < const Duration(seconds: 10)) {
        await _pollMonitorEvents();
        if (!_movieComplete) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      if (!_movieComplete) throw TimeoutException('已发送停止录像，尚未收到相机写入完成事件');
    }
    movieRecording = false;
    await _applicationMode(0);
    log('monitor movie stopped complete=$_movieComplete');
  }

  Future<Uint8List?> _readLiveFrame() async {
    if (!monitoring) return null;
    final requestClock = Stopwatch()..start();
    Uint8List bytes;
    if (transport is UsbPtpTransport) {
      bytes =
          await nativeCamera.invokeMethod<Uint8List>('usbLiveFrame') ??
          Uint8List(0);
    } else {
      try {
        bytes = await _ptp.data(_liveOpcode ?? 0x9203);
      } on PtpException catch (e) {
        if (e.response == 0xa00b && !movieRecording && _liveRecoveries++ < 1) {
          log('camera left live view; restart once before another frame');
          await _ptp.command(0x9201);
          await _deviceReady();
          bytes = await _ptp.data(_liveOpcode ?? 0x9203);
        } else if (e.unsupported && _liveOpcode == 0x9428) {
          _liveOpcode = 0x9203;
          log('monitor opcode fallback fixed for this session: 0x9203');
          bytes = await _ptp.data(0x9203);
        } else {
          rethrow;
        }
      }
    }
    _streamFrames++;
    _streamBytes += bytes.length;
    _streamMicros += requestClock.elapsedMicroseconds;
    if (requestClock.elapsedMicroseconds > _streamMaxMicros) {
      _streamMaxMicros = requestClock.elapsedMicroseconds;
    }
    if (_streamClock.elapsedMilliseconds >= 2000) {
      log(
        'monitor stream fps=${(_streamFrames * 1000 / _streamClock.elapsedMilliseconds).toStringAsFixed(1)} requestMs=${(_streamMicros / _streamFrames / 1000).toStringAsFixed(2)} maxRequestMs=${(_streamMaxMicros / 1000).toStringAsFixed(2)} meanFrameKB=${(_streamBytes / _streamFrames / 1024).toStringAsFixed(1)}',
      );
      _streamFrames = 0;
      _streamBytes = 0;
      _streamMicros = 0;
      _streamMaxMicros = 0;
      _streamClock.reset();
    }
    liveGeometry = NikonLiveGeometry.parse(bytes);
    if (!_frameHeaderLogged) {
      _frameHeaderLogged = true;
      log(
        'monitor frame header bytes=${bytes.length} hex=${bytes.take(64).map((v) => v.toRadixString(16).padLeft(2, "0")).join()}',
      );
    }
    final jpeg = extractJpeg(bytes);
    if (jpeg != null) {
      _liveRecoveries = 0;
      _liveFrameSequence++;
    }
    return jpeg;
  }

  Future<void> _restoreMediaMode({required bool endLive}) async {
    final failures = <Object>[];
    Future<void> attempt(Future<void> Function() work) async {
      try {
        await work();
      } on PtpException catch (e) {
        if (e.response != 0xa00b && !e.unsupported) failures.add(e);
      } catch (e) {
        failures.add(e);
      }
    }

    if (movieRecording) {
      // Do not end live view or release control until StopMovie is acknowledged.
      await _stopMovie();
    }
    if (endLive && supportsOperation(0x9206)) {
      await attempt(() => _ptp.command(0x9206));
    }
    if (endLive) await attempt(() => _ptp.command(0x9202));
    if (supportsOperation(0x90c2)) {
      await attempt(() => _ptp.command(0x90c2, [0]));
    }
    await attempt(() => _applicationMode(0));
    final ptp = transport;
    if (ptp is PtpIpTransport) {
      ptp.operationTimeout = const Duration(seconds: 20);
    }
    _remoteModeActive = failures.isNotEmpty;
    if (failures.isNotEmpty) {
      throw StateError('恢复照片传输模式失败：${failures.join('；')}');
    }
  }

  Future<void> stopMonitor() => _serial(() async {
    _monitorRequested = false;
    if (!monitoring && !_remoteModeActive && !movieRecording) return;
    monitoring = false;
    await _restoreMediaMode(endLive: true);
  });

  Future<void> readMetadata(MediaItem item) => _serial(() async {
    String path = item.localPath;
    File? temporaryHeader;
    try {
      if (path.isEmpty && (downloading || monitoring || transport == null)) {
        return;
      }
      if (path.isEmpty) {
        if (device?.operations.contains(0x101b) != true) return;
        final bytes = await _ptp.data(0x101b, [
          item.handle,
          0,
          min(item.bytes, 512 * 1024),
        ]);
        final header = File(
          '$cache/${item.id}_metadata.${item.name.split('.').last}',
        );
        temporaryHeader = header;
        await header.writeAsBytes(bytes);
        path = header.path;
      }
      final metadata = await nativeCamera.invokeMapMethod<String, String>(
        'exif',
        {'path': path},
      );
      item.exif = {...item.exif, ...?metadata};
      onChanged?.call();
    } finally {
      if (temporaryHeader != null && await temporaryHeader.exists()) {
        await temporaryHeader.delete();
      }
    }
  });
  // Pause live view, request CaptureToCard, poll DeviceReady, then restart.
  // A shutter command is never retried without observing camera state.
  Future<void> captureToCard({bool autofocus = false}) => _serial(() async {
    if (movieRecording) throw StateError('请先停止录像，再拍摄照片');
    final wasMonitoring = monitoring;
    if (wasMonitoring) await _ptp.command(0x9202);
    try {
      await _ptp.command(0x9207, [autofocus ? 0xfffffffe : 0xffffffff, 0]);
      for (var attempt = 0; attempt < 60; attempt++) {
        try {
          await _ptp.command(0x90c8);
          return;
        } on PtpException catch (e) {
          if (e.response != 0x2019) rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      throw TimeoutException('拍摄后相机仍忙碌，请在相机端确认照片');
    } finally {
      if (wasMonitoring) {
        await _ptp.command(0x9201);
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
    }
  });
  final _focusModeCache = <int, (int, DateTime)>{};
  int _liveFrameSequence = 0;
  Future<int?> _focusMode(int code) async {
    final cached = _focusModeCache[code];
    if (cached != null && DateTime.now().difference(cached.$2).inSeconds < 2) {
      return cached.$1;
    }
    return _serial(() => _monitorValue(code));
  }

  Future<bool> focusAt(int x, int y) async {
    if (x < 0 || y < 0) throw ArgumentError('对焦坐标不能为负数');
    final timer = Stopwatch()..start();
    final movie = await _focusMode(0xd1a6) == 1;
    var focusCode = movie ? 0xd1fa : 0xd061;
    var mode = await _focusMode(focusCode);
    if (mode == null) {
      focusCode = 0x500a;
      mode = await _focusMode(focusCode);
    }
    final manual = focusCode == 0x500a ? mode == 1 : mode == 3 || mode == 4;
    if (manual) throw StateError('相机当前为手动对焦 MF，请在对焦模式中选择 AF');
    if (supportsOperation(0x9425)) {
      try {
        await _serial(() => _ptp.command(0x9425));
      } on PtpException catch (e) {
        log('end tracking: $e');
      }
    }
    await _serial(() => _ptp.command(0x9205, [x, y]));
    final sequence = _liveFrameSequence;
    // The page supplies and displays the settling frame. Do not discard one
    // under a lock or hold the queue during the 40 ms lens settling delay.
    await Future<void>.delayed(const Duration(milliseconds: 40));
    if (monitoring && sequence == _liveFrameSequence) await liveFrame();
    final fullTime = focusCode == 0x500a ? mode == 0x8013 : mode == 2;
    if (!fullTime) {
      log(
        'monitor focus x=$x y=$y mode=$mode property=0x${focusCode.toRadixString(16)} prepareMs=${timer.elapsedMilliseconds}',
      );
      await _serial(() => _ptp.command(0x90c1));
      log('monitor focus driveAckMs=${timer.elapsedMilliseconds}');
      await _waitFocusReady();
    }
    log(
      'monitor focus complete x=$x y=$y driven=${!fullTime} elapsedMs=${timer.elapsedMilliseconds}',
    );
    return !fullTime;
  }

  Future<void> _waitFocusReady() async {
    if (!supportsOperation(0x90c8)) return;
    for (var attempt = 0; attempt < 25; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      try {
        await _serial(() => _ptp.command(0x90c8));
        return;
      } on PtpException catch (e) {
        if (e.response != 0x2019) rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw TimeoutException('相机对焦尚未完成，请检查对焦区域');
  }

  Future<int?> _movieProhibition() async {
    // Nikon's extended prohibition property is preferred before the standard value.
    try {
      final bytes = await _ptp.data(0x943b, [0xd0a4]);
      if (bytes.length >= 4) return PtpReader(bytes).u32();
    } on PtpException catch (e) {
      if (!e.unsupported) rethrow;
    }
    return _monitorValue(0xd0a4);
  }

  Future<void> _prepareMovie() async {
    final mode = await _monitorValue(0xd1a6);
    if (mode == 0) {
      // Nikon accepts the movie selector while live view remains active.
      await _ptp.writeProperty(0xd1a6, Uint8List.fromList([1]));
      final confirmed = await _monitorValue(0xd1a6);
      if (confirmed != 1) throw StateError('相机尚未确认视频取景模式，请重试');
    }
    final prohibition = await _movieProhibition();
    log('MovieRecProhibitionCondition=$prohibition');
    if (prohibition != 0) await _applicationMode(1);
    // StartMovie follows the confirmed selector directly; an earlier focus
    // completion does not gate the movie request.
  }

  Future<void> remoteAction(int opcode, [List<int> params = const []]) async {
    if (opcode == 0x90c1) {
      await _serial(() => _ptp.command(opcode));
      await _waitFocusReady();
      return;
    }
    await _remoteAction(opcode, params);
  }

  Future<void> _remoteAction(int opcode, List<int> params) => _serial(() async {
    if (opcode == 0x920b) {
      await _stopMovie();
      return;
    }
    if (opcode == 0x920a) {
      if (movieRecording) return;
      _movieComplete = false;
      await _prepareMovie();
    }
    try {
      log('monitor action start 0x${opcode.toRadixString(16)}');
      await _ptp.command(opcode, params);
      log('monitor action confirmed 0x${opcode.toRadixString(16)}');
    } on PtpException catch (e) {
      log('monitor action error $e');
      if (opcode == 0x920a && e.response == 0xa004) {
        try {
          log(
            'MovieRecProhibitionCondition after failure=${await _movieProhibition()}',
          );
        } catch (readError) {
          log('Movie prohibition read failed: $readError');
        }
      }
      // Only explicit NotLiveView permits retry. Never replay on timeout or busy.
      if (opcode != 0x920a || e.response != 0xa00b) rethrow;
      await _ptp.command(0x9201);
      await _deviceReady();
      await _ptp.command(opcode, params);
    }
    if (opcode == 0x920a) movieRecording = true;
    if (opcode == 0x920b) movieRecording = false;
  });
  void resetLightMeter() {
    _meterCode = null;
    _unsupportedMeterCodes.clear();
    _lastMeterRaw = null;
    _lastMeterLightup = null;
  }

  bool _movieMeter = false;
  int? _lastMeterLightup;
  void setMeterMode(bool movie) {
    if (_movieMeter != movie) {
      _movieMeter = movie;
      resetLightMeter();
    }
  }

  int? _lastMeterRaw;
  int? _meterCode;
  final _unsupportedMeterCodes = <int>{};
  Future<double?> readLightMeter() async {
    // D1B1 is shared by photo/video; its value is valid only while the
    // camera exposure indicator is active. Older models may expose D10A.
    for (final code in _meterCode == null ? [0xd1b1, 0xd10a] : [_meterCode!]) {
      if (_unsupportedMeterCodes.contains(code)) continue;
      try {
        if (code == 0xd1b1) {
          int? lightup;
          if (!_unsupportedMeterCodes.contains(0xd1b3)) {
            try {
              lightup = await currentProperty(0xd1b3, 2);
              if (_lastMeterLightup != lightup) {
                log('monitor meter indicator=$lightup movie=$_movieMeter');
                _lastMeterLightup = lightup;
              }
            } on PtpException catch (e) {
              if (!e.unsupported && e.response != 0x200a) rethrow;
              _unsupportedMeterCodes.add(0xd1b3);
            }
          }
          if (lightup != null && lightup != 0) return null;
          if (_movieMeter && lightup == null) {
            continue;
          }
        }
        final raw = await currentProperty(code, 1);
        if (_meterCode != code || _lastMeterRaw != raw) {
          log('monitor meter source=0x${code.toRadixString(16)} raw=$raw');
        }
        _meterCode = code;
        _lastMeterRaw = raw;
        if (raw == -128 || raw == 127 || (code == 0xd1b1 && raw.abs() > 60)) {
          return null;
        }
        return code == 0xd1b1 ? raw / 6.0 : raw / 12.0;
      } on PtpException catch (e) {
        if (!e.unsupported && e.response != 0x200a) rethrow;
        _unsupportedMeterCodes.add(code);
        _meterCode = null;
        log(
          'monitor meter unsupported source=0x${code.toRadixString(16)} response=0x${e.response.toRadixString(16)}',
        );
      }
    }
    return null;
  }

  Future<int> currentProperty(int code, int type) => _serial(() async {
    final r = PtpReader(await _ptp.data(0x1015, [code]));
    final value = switch (type) {
      1 => r.u8().toSigned(8),
      2 => r.u8(),
      3 => r.u16().toSigned(16),
      4 => r.u16(),
      5 => r.u32().toSigned(32),
      6 => r.u32(),
      7 => r.u64().toSigned(64),
      8 => r.u64(),
      _ => throw const FormatException('相机参数类型不支持'),
    };
    if ({0xd1a6, 0xd061, 0xd1fa, 0x500a}.contains(code)) {
      _focusModeCache[code] = (value, DateTime.now());
    }
    return value;
  });

  Future<Map<String, dynamic>> property(int code) => _serial(() async {
    final data = await _ptp.data(0x1014, [code]);
    final r = PtpReader(data);
    r.u16();
    final type = r.u16(), writable = r.u8() == 1;
    int read() => switch (type) {
      1 => r.u8().toSigned(8),
      2 => r.u8(),
      3 => r.u16().toSigned(16),
      4 => r.u16(),
      5 => r.u32().toSigned(32),
      6 => r.u32(),
      7 => r.u64().toSigned(64),
      8 => r.u64(),
      _ => throw const FormatException('相机参数类型不支持'),
    };
    read();
    final current = read();
    final form = r.u8();
    final values = <int>[];
    if (form == 2) {
      final count = r.u16();
      for (var i = 0; i < count; i++) {
        values.add(read());
      }
    }
    if (form == 1) {
      final min = read(), max = read(), step = read();
      if (step > 0 && (max - min) ~/ step < 200) {
        for (var value = min; value <= max; value += step) {
          values.add(value);
        }
      }
    }
    if ({0xd1a6, 0xd061, 0xd1fa, 0x500a}.contains(code)) {
      _focusModeCache[code] = (current, DateTime.now());
    }
    return {
      'code': code,
      'type': type,
      'writable': writable,
      'current': current,
      'values': values.toSet().toList()..sort(),
    };
  });
  Future<int?> readBatteryLevel() async {
    try {
      final p = await property(0x5001);
      final value = p['current'] as int;
      log('monitor battery raw=$value');
      return value >= 0 && value <= 100 ? value : null;
    } on PtpException catch (e) {
      log('monitor battery unavailable: $e');
      return null;
    } on FormatException catch (e) {
      log('monitor battery invalid: $e');
      return null;
    }
  }

  Future<void> ensureThirdStopExposure() async {
    for (final code in [0xd055, 0xd056, 0xd057]) {
      if (device?.properties.contains(code) != true) continue;
      try {
        final descriptor = await property(code);
        if (descriptor['current'] != 0 &&
            descriptor['writable'] == true &&
            (descriptor['values'] as List).contains(0)) {
          await setProperty(code, descriptor['type'] as int, 0);
          log(
            'monitor exposure step source=0x${code.toRadixString(16)} value=0 (1/3 EV)',
          );
        }
      } on PtpException catch (e) {
        log('monitor exposure step unavailable: $e');
      }
    }
  }

  Future<void> setProperty(int code, int type, int value) => _serial(() async {
    if ({0xd1a6, 0x500e, 0xd054, 0xd0ad}.contains(code)) resetLightMeter();
    if ({0xd1a6, 0xd061, 0xd1fa, 0x500a}.contains(code)) {
      _focusModeCache.clear();
    }
    if (movieRecording) throw StateError('请先停止录像，再调整相机参数');
    final size = switch (type) {
      1 || 2 => 1,
      3 || 4 => 2,
      5 || 6 => 4,
      7 || 8 => 8,
      _ => throw const FormatException('参数类型不支持'),
    };
    final data = ByteData(size);
    if (size == 1) data.setUint8(0, value);
    if (size == 2) data.setUint16(0, value, Endian.little);
    if (size == 4) data.setUint32(0, value, Endian.little);
    if (size == 8) data.setUint64(0, value, Endian.little);
    final payload = data.buffer.asUint8List();
    // USB cameras require live view to pause before changing these AF properties.
    if (monitoring &&
        transport is UsbPtpTransport &&
        {0xd061, 0xd1fa, 0x500a}.contains(code)) {
      await _ptp.command(0x9202);
      try {
        await _ptp.writeProperty(code, payload);
      } finally {
        await _ptp.command(0x9201);
        await _deviceReady();
      }
      return;
    }
    try {
      await _ptp.writeProperty(code, payload);
    } on PtpException catch (e) {
      if (!monitoring || (e.response != 0x2019 && e.response != 0xa004)) {
        rethrow;
      }
      log('property 0x${code.toRadixString(16)} requires paused live view');
      await _ptp.command(0x9202);
      try {
        await _ptp.writeProperty(code, payload);
      } finally {
        await _ptp.command(0x9201);
        await _deviceReady();
      }
    }
  });
}

Uint8List? extractJpeg(Uint8List bytes) {
  var start = -1;
  for (var i = 0; i + 1 < bytes.length; i++) {
    if (bytes[i] == 255 && bytes[i + 1] == 216) {
      start = i;
      break;
    }
  }
  if (start < 0) return null;
  for (var i = bytes.length - 2; i > start; i--) {
    if (bytes[i] == 255 && bytes[i + 1] == 217) {
      return Uint8List.sublistView(bytes, start, i + 2);
    }
  }
  return null;
}

/// Pairing status is a counted opaque byte sequence, not a PTP response code.
/// Do not infer "paired" from it; require ConfirmPairing's response and
/// the subsequent normal transfer session to both succeed.
void validateNikonPairingStatus(Uint8List bytes) {
  if (bytes.length < 4 || PtpReader(bytes).u32() != bytes.length - 4) {
    throw const FormatException('Nikon 配对状态数据不完整');
  }
}

/// Lazy, round-robin probing of every attached IPv4 prefix. Large subnets do
/// not allocate a host list or delay probing a hotspot behind the Wi-Fi subnet.
DiscoveryCandidates nikonDiscoveryCandidates(
  Map<String, dynamic> network,
  List<String> recent,
) => DiscoveryCandidates(network, recent);

class DiscoveryCandidates extends IterableBase<String> {
  DiscoveryCandidates(Map<String, dynamic> network, List<String> recent) {
    for (final item in (network['interfaces'] as List? ?? [])) {
      final ip = _parse(item['address'] as String? ?? '');
      final prefix = (item['prefix'] as num?)?.toInt() ?? 24;
      if (ip == null || prefix < 1 || prefix > 32) continue;
      _add(ip, prefix);
    }
    for (final text in List<String>.from(network['addresses'] ?? [])) {
      final ip = _parse(text);
      if (ip != null && !_self.contains(ip)) _add(ip, 24);
    }
    for (final text in [
      ...recent,
      ...List<String>.from(network['candidates'] ?? []),
    ]) {
      final ip = _parse(text);
      if (ip != null && _usable(ip) && !_priority.contains(ip)) {
        _priority.add(ip);
      }
    }
  }
  final _ranges = <({int first, int last, int self})>[];
  final _self = <int>{};
  final _priority = <int>[];
  void _add(int ip, int prefix) {
    _self.add(ip);
    final mask = (0xffffffff << (32 - prefix)) & 0xffffffff;
    final base = ip & mask;
    final last = base | (~mask & 0xffffffff);
    final firstHost = prefix >= 31 ? base : base + 1;
    final lastHost = prefix >= 31 ? last : last - 1;
    if (!_ranges.any((r) => r.first == firstHost && r.last == lastHost)) {
      _ranges.add((first: firstHost, last: lastHost, self: ip));
    }
  }

  static int? _parse(String value) {
    final parts = value.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((p) => p == null || p < 0 || p > 255)) {
      return null;
    }
    return parts.fold<int>(0, (n, p) => (n << 8) | p!);
  }

  static String _address(int n) =>
      [24, 16, 8, 0].map((s) => (n >> s) & 255).join('.');
  bool _usable(int ip) =>
      !_self.contains(ip) && _ranges.any((r) => ip >= r.first && ip <= r.last);
  @override
  int get length {
    final sorted = [..._ranges]..sort((a, b) => a.first.compareTo(b.first));
    var count = 0, end = -1;
    for (final range in sorted) {
      if (range.last > end) {
        count += range.last - max<int>(end + 1, range.first) + 1;
      }
      end = max(end, range.last);
    }
    return count -
        _self
            .where((ip) => _ranges.any((r) => ip >= r.first && ip <= r.last))
            .length;
  }

  Iterable<int> _hosts(int index) sync* {
    final range = _ranges[index];
    final distance = max(
      (range.self - range.first).abs(),
      (range.last - range.self).abs(),
    );
    for (var offset = 1; offset <= distance; offset++) {
      for (final ip in [range.self - offset, range.self + offset]) {
        if (ip < range.first ||
            ip > range.last ||
            !_usable(ip) ||
            _priority.contains(ip)) {
          continue;
        }
        if (_ranges.take(index).any((r) => ip >= r.first && ip <= r.last)) {
          continue;
        }
        yield ip;
      }
    }
  }

  Iterable<String> _values() sync* {
    yield* _priority.map(_address);
    final iterators = List.generate(_ranges.length, (i) => _hosts(i).iterator);
    while (iterators.isNotEmpty) {
      for (final iterator in [...iterators]) {
        if (iterator.moveNext()) {
          yield _address(iterator.current);
        } else {
          iterators.remove(iterator);
        }
      }
    }
  }

  @override
  Iterator<String> get iterator => _values().iterator;
}
