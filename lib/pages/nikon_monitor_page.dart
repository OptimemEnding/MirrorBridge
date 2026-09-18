import '../models/user_message.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import '../state/app_controller.dart';
import '../models/nikon_monitor_values.dart';
import '../protocol/ptp.dart';
import '../repositories/nikon_repository.dart';

class NikonMonitorPage extends StatefulWidget {
  const NikonMonitorPage({super.key, required this.c});
  final AppController c;
  @override
  State<NikonMonitorPage> createState() => _NikonMonitorPageState();
}

class _NikonMonitorPageState extends State<NikonMonitorPage>
    with WidgetsBindingObserver {
  NikonRepository get repo => widget.c.nikon!;
  int? textureId;
  int frameWidth = 0, frameHeight = 0;
  bool hasFrame = false,
      running = false,
      busy = false,
      stopping = false,
      leaving = false;
  bool recording = false, suspended = false, fullscreen = false;
  bool grid = false, mirror = false, zebra = false;
  bool peaking = false, histogram = false, waveform = false, safeArea = false;
  bool monitorLut = false;
  double zebraThreshold = .9, peakingThreshold = .14, lutIntensity = .5;
  double guideAspect = 0;
  String lut = '', error = '', status = '正在启动监看…';
  int _propertyCursor = 0,
      _propertyRevision = 0,
      _hotPropertyCursor = 0,
      _slowPropertyCursor = 0;
  final _urgentProperties = <int>{};
  bool _usedUrgentProperty = false;
  int fps = 0, _epoch = 0, _measuredFrames = 0;
  double actualFps = 0;
  int displayedFrames = 0;
  DateTime _lastPerfLog = DateTime.fromMillisecondsSinceEpoch(0);
  final _fpsClock = Stopwatch();
  final _recordClock = Stopwatch();
  List<List<int>> rgbBins = List.generate(3, (_) => List.filled(256, 0));
  List<int> wave = [];
  final scopeRevision = ValueNotifier<int>(0);
  bool get hasNotice =>
      error.isNotEmpty || (focusFailed && hasFrame && !focusing);
  List<String> luts = [];
  Offset? focusPoint;
  bool focusFailed = false, focusSucceeded = false, focusing = false;
  bool? autoIso;
  int? actualAutoIso;
  double? meteringEv;
  int? cameraBattery;
  DateTime _lastBatteryRead = DateTime.fromMillisecondsSinceEpoch(0);
  bool _meterSupported = true;
  DateTime _lastMeterRead = DateTime.fromMillisecondsSinceEpoch(0);
  Map<String, dynamic>? _isoReadingDescriptor;
  bool toolsExpanded = false;
  bool meterOnRight = false;
  final scopePositions = <String, Offset>{};
  @override
  void didChangeMetrics() {
    nativeCamera
        .invokeMethod<int>('screenRotation')
        .then((rotation) {
          if (mounted) setState(() => meterOnRight = rotation == 3);
        })
        .catchError((Object _) {});
  }

  Future<void>? _startup, _frameLoop, _shutdown, _operation;
  late final Future<void> _lutLoad;
  DateTime _lastPropertyRead = DateTime.fromMillisecondsSinceEpoch(0);
  final properties = <int, Map<String, dynamic>>{};
  final propertyErrors = <int, String>{};
  final _dirtyProperties = <int>{};
  final names = const {
    0xd1a6: '取景模式',
    0x500f: 'ISO',
    0x5007: '光圈',
    0x500d: '快门',
    0x5010: '曝光补偿',
    0x5005: '白平衡',
    0x500e: '曝光模式',
    0x500a: '对焦模式',
    0x500b: '测光模式',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    didChangeMetrics();
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
    );
    unawaited(
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]),
    );
    final p = widget.c.monitorPreferences;
    final savedPositions = p['scopePositions'];
    if (savedPositions is Map) {
      for (final entry in savedPositions.entries) {
        final value = entry.value;
        if (entry.key is! String || value is! Map) continue;
        final x = value['x'], y = value['y'];
        if (x is num && y is num && x.isFinite && y.isFinite) {
          scopePositions[entry.key as String] = Offset(
            x.toDouble().clamp(0, 1),
            y.toDouble().clamp(0, 1),
          );
        }
      }
    }
    repo.liveImageSize = p['imageSize'] == 2 ? 2 : 3;
    grid = p['grid'] == true;
    mirror = p['mirror'] == true;
    zebra = p['zebra'] == true;
    peaking = p['peaking'] == true;
    histogram = p['histogram'] == true;
    waveform = p['waveform'] == true;
    safeArea = p['safeArea'] == true;
    monitorLut = p['lutEnabled'] == true;
    lut = p['lut'] as String? ?? '';
    lutIntensity = (p['intensity'] as num?)?.toDouble().clamp(0, 1) ?? .5;
    zebraThreshold =
        (p['zebraThreshold'] as num?)?.toDouble().clamp(.5, 1) ?? .9;
    peakingThreshold =
        (p['peakingThreshold'] as num?)?.toDouble().clamp(.03, .3) ?? .14;
    guideAspect = (p['aspect'] as num?)?.toDouble() ?? 0;
    fps = [0, 24, 30, 60].contains(p['fps']) ? p['fps'] as int : 0;
    repo.onGpuEvent = gpuEvent;
    _lutLoad = rootBundle
        .loadString('assets/luts.json')
        .then((value) {
          if (mounted) {
            setState(
              () => luts = {
                ...List<String>.from(jsonDecode(value)),
                if (lut.isNotEmpty) lut,
                if (widget.c.lut.isNotEmpty) widget.c.lut,
              }.toList(),
            );
          }
        })
        .catchError((Object e) {
          if (mounted) setState(() => error = '无法读取色彩预设，请稍后重试。');
        });
    _startup = start();
  }

  void saveOptions() {
    widget.c.monitorPreferences = {
      'grid': grid,
      'mirror': mirror,
      'zebra': zebra,
      'peaking': peaking,
      'histogram': histogram,
      'waveform': waveform,
      'scopePositions': {
        for (final e in scopePositions.entries)
          e.key: {'x': e.value.dx, 'y': e.value.dy},
      },
      'safeArea': safeArea,
      'lutEnabled': monitorLut,
      'lut': lut,
      'intensity': lutIntensity,
      'zebraThreshold': zebraThreshold,
      'peakingThreshold': peakingThreshold,
      'aspect': guideAspect,
      'fps': fps,
      'imageSize': repo.liveImageSize,
    };
    unawaited(widget.c.save());
  }

  void gpuEvent(Map<dynamic, dynamic> e) {
    if (!mounted || stopping || e['textureId'] != textureId) return;
    if (e['type'] == 'gpuFrame') {
      _measuredFrames++;
      displayedFrames++;
      final w = (e['width'] as num).toInt(), h = (e['height'] as num).toInt();
      if (w <= 0 || h <= 0) return;
      final dimensionsChanged = w != frameWidth || h != frameHeight;
      frameWidth = w;
      frameHeight = h;
      if (e['histogramRgb'] is List) {
        rgbBins = (e['histogramRgb'] as List)
            .map((v) => List<int>.from(v))
            .toList();
      }
      if (e['waveform'] is List) wave = List<int>.from(e['waveform']);
      if (e['histogramRgb'] is List || e['waveform'] is List) {
        scopeRevision.value++;
      }
      if (dimensionsChanged) setState(() {});
    }
  }

  Future<void> gpuOptions() async {
    if (textureId == null) return;
    await nativeCamera.invokeMethod('gpuOptions', {
      'zebra': zebra,
      'peaking': peaking,
      'mirror': mirror,
      'lut': monitorLut,
      'intensity': lutIntensity,
      'zebraThreshold': zebraThreshold,
      'peakingThreshold': peakingThreshold,
      'histogram': histogram,
      'waveform': waveform,
    });
  }

  Future<void> start() async {
    if (busy || running || stopping || suspended) return;
    final token = ++_epoch;
    setState(() {
      busy = true;
      error = '';
      status = '正在切换相机取景模式…';
      hasFrame = false;
    });
    try {
      await nativeCamera.invokeMethod('monitorAwake', {'active': true});
      final id = await nativeCamera.invokeMethod<int>('gpuStart');
      textureId = id;
      if (!mounted || token != _epoch) return;
      if (id == null) throw StateError('监看画面初始化失败');
      if (lut.isNotEmpty) {
        await nativeCamera.invokeMethod('gpuLut', {'name': lut});
      }
      await gpuOptions();
      if (!mounted || token != _epoch) return;
      await repo.ensureThirdStopExposure();
      await repo.startMonitor();
      if (!mounted || token != _epoch) return;
      _fpsClock
        ..reset()
        ..start();
      _measuredFrames = 0;
      setState(() {
        running = true;
        busy = false;
        status = '正在等待首帧（最多 5 秒）…';
      });
      _frameLoop = loop(token);
    } catch (e) {
      if (mounted && token == _epoch) {
        setState(() {
          error = '暂时无法启动监看，请检查相机连接与拍摄模式。';
          repo.log('monitor startup error: $e');
          running = false;
        });
        await releaseGpu();
      }
    } finally {
      if (mounted && token == _epoch) setState(() => busy = false);
    }
  }

  Future<void> loop(int token) async {
    var failures = 0;
    final sinceFrame = Stopwatch()..start();
    Future<void>? rendering;
    var lastPresented = displayedFrames;
    while (mounted && running && token == _epoch && !suspended) {
      final tick = Stopwatch()..start();
      try {
        final data = await repo.liveFrame();
        final fetchMicros = tick.elapsedMicroseconds;
        if (!mounted || !running || token != _epoch) break;
        if (data == null || data.isEmpty) {
          if (sinceFrame.elapsed >= const Duration(seconds: 5)) {
            throw TimeoutException('5 秒内未收到有效画面，请检查相机取景模式');
          }
          await Future<void>.delayed(const Duration(milliseconds: 40));
          continue;
        }
        final previousRendering = rendering;
        rendering = null;
        await previousRendering;
        final renderWaitMicros = tick.elapsedMicroseconds - fetchMicros;
        rendering = nativeCamera.invokeMethod<void>('gpuSubmit', {
          'jpeg': data,
        });
        // Observe errors immediately; await propagates them on the next loop.
        rendering.ignore();
        if (!mounted || token != _epoch) break;
        if (displayedFrames != lastPresented) {
          lastPresented = displayedFrames;
          sinceFrame.reset();
          failures = 0;
        } else if (sinceFrame.elapsed >= const Duration(seconds: 5)) {
          throw TimeoutException('5 秒内没有成功显示新画面，请检查相机连接');
        }

        if (!hasFrame || _fpsClock.elapsedMilliseconds >= 500) {
          setState(() {
            hasFrame = true;
            if (_fpsClock.elapsedMilliseconds >= 500) {
              actualFps =
                  _measuredFrames * 1000 / _fpsClock.elapsedMilliseconds;
              _fpsClock.reset();
              _measuredFrames = 0;
            }
            if (recording && !repo.movieRecording) {
              recording = false;
              _recordClock.stop();
              status = '相机已结束录像，请在存储卡中确认文件';
            } else {
              status = recording ? '正在录制到相机存储卡' : '实时画面';
            }
          });
        }
        if (DateTime.now().difference(_lastPerfLog).inSeconds >= 2) {
          _lastPerfLog = DateTime.now();
          repo.log(
            'monitor perf displayFps=${actualFps.toStringAsFixed(1)} image=${frameWidth}x$frameHeight busy=$busy focusing=$focusing frameLoopMs=${tick.elapsedMilliseconds} fetchMs=${(fetchMicros / 1000).toStringAsFixed(2)} renderWaitMs=${(renderWaitMicros / 1000).toStringAsFixed(2)} jpegKB=${(data.length / 1024).toStringAsFixed(1)}',
          );
        }
        // One descriptor per interval, after a displayed frame; never queue a
        // full property sweep in front of live view or a shutter command.
        if (DateTime.now().difference(_lastPropertyRead).inMilliseconds >
                (properties.length + propertyErrors.length < names.length ||
                        _dirtyProperties.isNotEmpty ||
                        _urgentProperties.isNotEmpty
                    ? 60
                    : 350) &&
            !busy) {
          _lastPropertyRead = DateTime.now();
          if (_propertyRevision != repo.monitorPropertiesRevision) {
            _propertyRevision = repo.monitorPropertiesRevision;
            propertyErrors.clear();
            for (final changed in repo.monitorChangedProperties) {
              for (final code in names.keys) {
                if (properties[code]?['code'] == changed ||
                    code == changed ||
                    (code == 0x500f &&
                        {0xd054, 0xd0ad, 0xd0b5}.contains(changed))) {
                  _urgentProperties.add(code);
                }
              }
            }
            repo.monitorChangedProperties.clear();
          }
          final missing = names.keys
              .where(
                (c) =>
                    !properties.containsKey(c) &&
                    !propertyErrors.containsKey(c),
              )
              .firstOrNull;
          final next =
              missing ??
              (_dirtyProperties.isNotEmpty
                  ? _dirtyProperties.first
                  : _urgentProperties.isNotEmpty && !_usedUrgentProperty
                  ? _urgentProperties.first
                  : _propertyCursor++ % 4 == 3
                  ? names.keys
                        .where((c) => !{0x500d, 0x5007, 0x500f}.contains(c))
                        .elementAt(_slowPropertyCursor++ % 6)
                  : [0x500d, 0x5007, 0x500f][_hotPropertyCursor++ % 3]);
          _usedUrgentProperty =
              _urgentProperties.contains(next) && !_usedUrgentProperty;
          _urgentProperties.remove(next);
          if (!stopping) await readProperty(next, token);
        } else if (!busy &&
            !stopping &&
            DateTime.now().difference(_lastBatteryRead).inSeconds >= 30) {
          _lastBatteryRead = DateTime.now();
          final value = await repo.readBatteryLevel();
          if (mounted && token == _epoch) setState(() => cameraBattery = value);
        } else if (!busy &&
            !stopping &&
            _meterSupported &&
            properties[0xd1a6]?['current'] != 1 &&
            DateTime.now().difference(_lastMeterRead).inMilliseconds >= 500) {
          _lastMeterRead = DateTime.now();
          try {
            repo.setMeterMode(properties[0xd1a6]?['current'] == 1);
            final value = await repo.readLightMeter();
            if (mounted && token == _epoch) setState(() => meteringEv = value);
          } on PtpException catch (e) {
            if (e.unsupported) _meterSupported = false;
            if (mounted) setState(() => meteringEv = null);
            repo.log('monitor light meter: $e');
          }
        }
      } catch (e) {
        if (!mounted || token != _epoch) break;
        final retryable =
            e is PtpException &&
            (e.response == 0x2019 || (busy && e.response == 0xa00b));
        if (retryable &&
            sinceFrame.elapsed < const Duration(seconds: 5) &&
            ++failures < 300) {
          await Future<void>.delayed(const Duration(milliseconds: 16));
          continue;
        }
        setState(() {
          error = '监看画面已中断，请检查相机连接后重试。';
          running = false;
          hasFrame = false;
          actualFps = 0;
        });
        try {
          await repo.stopMonitor();
        } catch (cleanup) {
          repo.log('frame failure cleanup: $cleanup');
          widget.c.disconnect();
        }
        await releaseGpu();
        break;
      }
      final remaining =
          (fps == 0 ? 0 : 1000000 ~/ fps) - tick.elapsedMicroseconds;
      await Future<void>.delayed(
        Duration(microseconds: math.max(1000, remaining)),
      );
    }
    try {
      await rendering;
    } catch (e) {
      repo.log('final render completion: $e');
    }
  }

  Future<void> readProperty(int code, int token) async {
    Object? lastError;
    final candidates = nikonMonitorProperties(
      code,
      movie: properties[0xd1a6]?['current'] == 1,
    );
    for (final candidate in candidates) {
      if (!mounted || token != _epoch || stopping) return;

      try {
        final cached = properties[code];
        final value =
            cached != null &&
                !_dirtyProperties.contains(code) &&
                cached['code'] == candidate
            ? <String, dynamic>{
                ...cached,
                'current': await repo.currentProperty(
                  candidate,
                  cached['type'] as int,
                ),
              }
            : await repo.property(candidate);
        if (code == 0x500f) {
          try {
            autoIso =
                await repo.currentProperty(
                  properties[0xd1a6]?['current'] == 1 ? 0xd0ad : 0xd054,
                  2,
                ) ==
                1;
          } on PtpException catch (e) {
            if (!e.unsupported) {
              repo.log('Auto ISO read: $e');
            }
            autoIso = null;
          }
        }
        if (code == 0x500f && autoIso == true) {
          try {
            final d = _isoReadingDescriptor;
            if (d == null) {
              _isoReadingDescriptor = await repo.property(0xd0b5);
              actualAutoIso = _isoReadingDescriptor!['current'] as int;
            } else {
              actualAutoIso = await repo.currentProperty(
                0xd0b5,
                d['type'] as int,
              );
            }
          } on PtpException catch (e) {
            if (!e.unsupported) repo.log('monitor actual ISO read: $e');
            actualAutoIso = null;
          }
        }
        if (mounted && token == _epoch) {
          setState(() {
            if (code == 0xd1a6 &&
                properties[code]?['current'] != value['current']) {
              propertyErrors.clear();
              _dirtyProperties.addAll(names.keys);
              repo.resetLightMeter();
              _meterSupported = true;
              meteringEv = null;
              _lastMeterRead = DateTime.fromMillisecondsSinceEpoch(0);
              actualAutoIso = null;
              _isoReadingDescriptor = null;
              focusPoint = null;
              focusSucceeded = false;
              focusFailed = false;
            }
            properties[code] = value;
            propertyErrors.remove(code);
            _dirtyProperties.remove(code);
          });
        }
        return;
      } catch (e) {
        lastError = e;
      }
    }
    if (mounted && token == _epoch) {
      setState(() {
        propertyErrors[code] = '${lastError ?? '当前模式未提供'}';
        properties.remove(code);
        _dirtyProperties.remove(code);
      });
    }
  }

  Future<void> perform(Future<void> Function() work) async {
    if (busy || !running || stopping) return;
    setState(() {
      busy = true;
      error = '';
    });
    final token = _epoch;
    final operation = work();
    _operation = operation;
    try {
      await operation;
    } catch (e) {
      repo.log('monitor control error: $e');
      if (mounted && token == _epoch) setState(() => error = userMessage(e));
    } finally {
      if (identical(_operation, operation)) _operation = null;
      if (mounted && token == _epoch) setState(() => busy = false);
    }
  }

  Future<void> action(int code) => perform(() async {
    if (code == 0x9207) {
      await repo.captureToCard();
      if (mounted) setState(() => status = '拍摄指令已完成，照片保存在相机存储卡');
    } else {
      await repo.remoteAction(code);
      if (code == 0x920a || code == 0x920b) {
        _dirtyProperties.addAll(names.keys);
        propertyErrors.clear();
      }
      if (code == 0x920a || code == 0x920b) {
        recording = code == 0x920a;
        if (recording) {
          _recordClock
            ..reset()
            ..start();
        } else {
          _recordClock.stop();
        }
      }
    }
  });

  Future<void> touchFocus(Offset position, Size size) => perform(() async {
    if (!hasFrame || frameWidth <= 0 || frameHeight <= 0) return;
    final x = (position.dx / size.width).clamp(0.0, 1.0),
        y = (position.dy / size.height).clamp(0.0, 1.0);
    setState(() {
      focusPoint = Offset(x, y);
      focusFailed = false;
      focusSucceeded = false;
      focusing = true;
    });
    try {
      final normalizedX = mirror ? 1 - x : x;
      final geometry = repo.liveGeometry;
      final point =
          geometry != null &&
              geometry.jpegWidth == frameWidth &&
              geometry.jpegHeight == frameHeight
          ? geometry.point(normalizedX, y)
          : (
              (normalizedX * (frameWidth - 1)).round(),
              (y * (frameHeight - 1)).round(),
            );
      final focusClock = Stopwatch()..start();
      final framesBeforeFocus = displayedFrames;
      final confirmed = await repo.focusAt(point.$1, point.$2);
      repo.log(
        'monitor focus display elapsedMs=${focusClock.elapsedMilliseconds} displayedFrames=${displayedFrames - framesBeforeFocus}',
      );
      if (mounted) setState(() => focusSucceeded = confirmed);
    } on PtpException catch (e) {
      if (mounted) setState(() => focusFailed = true);
      if (e.response != 0xa002) rethrow;
    } on TimeoutException {
      if (mounted) setState(() => focusFailed = true);
    } on StateError catch (e) {
      if (e.message.contains('MF')) {
        if (mounted) setState(() => focusFailed = true);
      } else {
        rethrow;
      }
    } finally {
      if (mounted) setState(() => focusing = false);
    }
  });

  Future<void> releaseGpu() async {
    final id = textureId;
    textureId = null;
    try {
      if (id != null) {
        await nativeCamera.invokeMethod('gpuStop', {'textureId': id});
      }
    } finally {
      await nativeCamera.invokeMethod('monitorAwake', {'active': false});
    }
  }

  Future<void> shutdown() {
    if (_shutdown != null) return _shutdown!;
    final task = _shutdownSession();
    _shutdown = task;
    task.whenComplete(() {
      _shutdown = null;
    }).ignore();
    return task;
  }

  Future<void> _shutdownSession() async {
    ++_epoch;
    setState(() {
      stopping = true;
      running = false;
      actualFps = 0;
    });
    try {
      await _startup;
      try {
        await _operation;
      } catch (_) {
        /* Reported by perform. */
      }
      await _frameLoop;
      if (recording) {
        await repo.remoteAction(0x920b);
        recording = false;
        _recordClock.stop();
      }
    } catch (e) {
      error = '无法停止取景，请检查相机当前状态。';
    }
    try {
      await repo.stopMonitor();
    } catch (e) {
      error = '无法恢复传输模式，请重新连接相机。';
      widget.c.disconnect();
    } finally {
      try {
        await releaseGpu();
      } catch (e) {
        repo.log('gpu cleanup: $e');
      }
      if (mounted) {
        setState(() {
          stopping = false;
          busy = false;
          hasFrame = false;
        });
      }
    }
  }

  Future<void> leave() async {
    if (leaving) return;
    await shutdown();
    if (!mounted) return;
    saveOptions();
    if (error.isNotEmpty) {
      widget.c.message = error;
      widget.c.changed();
    }
    setState(() => leaving = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      suspended = true;
      unawaited(shutdown());
    } else if (state == AppLifecycleState.resumed) {
      suspended = false;
      unawaited(() async {
        await _shutdown;
        if (mounted && !leaving && widget.c.connected) {
          _startup = start();
          await _startup;
        }
      }());
    }
  }

  @override
  void dispose() {
    _epoch++;
    running = false;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    unawaited(
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]),
    );
    repo.onGpuEvent = null;
    scopeRevision.dispose();
    // Route removal outside PopScope still queues cleanup behind an in-flight start.
    if (!leaving) {
      unawaited(() async {
        try {
          await _startup;
          try {
            await _operation;
          } catch (_) {
            /* Already reported. */
          }
          await _frameLoop;
          if (recording) await repo.remoteAction(0x920b);
          await repo.stopMonitor();
        } catch (e) {
          repo.log('monitor disposal: $e');
        } finally {
          await releaseGpu();
        }
      }());
    }
    super.dispose();
  }

  String label(int code, int value) => nikonMonitorValue(
    code,
    value,
    propertyCode: properties[code]?['code'] as int?,
  );

  bool canEditExposure(int code) =>
      nikonExposureControls(code, properties[0x500e]?['current'] as int?);

  String compactLabel(int code, int value) {
    final text = label(code, value);
    if (code == 0xd1a6) {
      return value == 0
          ? '照片'
          : value == 1
          ? '视频'
          : '—';
    }
    if (code == 0x500e) {
      return const {1: 'M', 2: 'P', 3: 'A', 4: 'S', 0x8010: 'AUTO'}[value] ??
          text;
    }
    if (code == 0x500a) {
      return RegExp(r'AF-[SCFA]|MF').firstMatch(text)?.group(0) ?? text;
    }
    if (code == 0x500f && (text == '自动 ISO' || autoIso == true)) {
      return 'AUTO ${actualAutoIso == null ? '—' : isoLabel(actualAutoIso!)}';
    }
    if ({0x500d, 0x5007}.contains(code) && !canEditExposure(code)) {
      return 'A · $text';
    }
    return text;
  }

  String get recordingTime {
    final seconds = _recordClock.elapsed.inSeconds;
    return '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final dark = ThemeData.dark(useMaterial3: true).copyWith(
      scaffoldBackgroundColor: const Color(0xff090b0e),
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xfff4c45a),
        brightness: Brightness.dark,
      ),
      visualDensity: VisualDensity.compact,
    );
    return Theme(
      data: dark,
      child: PopScope(
        canPop: leaving,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) unawaited(leave());
        },
        child: Scaffold(
          body: LayoutBuilder(
            builder: (context, box) {
              final landscape = box.maxWidth > box.maxHeight;
              final insets = MediaQuery.viewPaddingOf(context);
              return Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fill(child: viewport()),
                  if (hasFrame && (histogram || waveform))
                    scopeOverlay(box, insets, landscape),
                  Positioned(
                    top: insets.top + 8,
                    left: math.max(
                      20,
                      MediaQuery.viewPaddingOf(context).left + 8,
                    ),
                    right: math.max(
                      24,
                      MediaQuery.viewPaddingOf(context).right + 12,
                    ),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: .32),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: MediaQuery.withClampedTextScaling(
                        maxScaleFactor: 1.15,
                        child: SizedBox(
                          height: 48,
                          child: Row(
                            children: [
                              IconButton(
                                tooltip: '退出监看',
                                onPressed: stopping ? null : leave,
                                icon: const Icon(Icons.arrow_back),
                              ),
                              if (!fullscreen)
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${widget.c.cameraModel} · 监看',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      if (hasFrame)
                                        Text(
                                          '$frameWidth × $frameHeight',
                                          key: const ValueKey(
                                            'monitor-resolution',
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 10,
                                            color: Colors.white70,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              if (fullscreen) const Spacer(),
                              Tooltip(
                                message: landscape
                                    ? '恢复竖屏（长按自动旋转）'
                                    : '向右旋转90°（长按自动旋转）',
                                triggerMode: TooltipTriggerMode.manual,
                                child: GestureDetector(
                                  onLongPress: () =>
                                      SystemChrome.setPreferredOrientations([
                                        DeviceOrientation.portraitUp,
                                        DeviceOrientation.landscapeLeft,
                                        DeviceOrientation.landscapeRight,
                                      ]),
                                  child: IconButton(
                                    key: const ValueKey('monitor-rotate'),
                                    onPressed: () =>
                                        SystemChrome.setPreferredOrientations(
                                          landscape
                                              ? [DeviceOrientation.portraitUp]
                                              : [
                                                  DeviceOrientation
                                                      .landscapeLeft,
                                                ],
                                        ),
                                    icon: Icon(
                                      landscape
                                          ? Icons.rotate_left
                                          : Icons.rotate_right,
                                    ),
                                  ),
                                ),
                              ),
                              if (recording)
                                Text(
                                  '● $recordingTime',
                                  style: const TextStyle(
                                    color: Colors.redAccent,
                                    fontSize: 12,
                                  ),
                                ),
                              IconButton(
                                tooltip: fullscreen ? '显示控制栏' : '隐藏控制栏',
                                onPressed: () =>
                                    setState(() => fullscreen = !fullscreen),
                                icon: Icon(
                                  fullscreen
                                      ? Icons.fullscreen_exit
                                      : Icons.fullscreen,
                                ),
                              ),
                              const SizedBox(width: 8),
                              if (!fullscreen) batteryIndicator(),
                              if (!fullscreen && box.maxWidth >= 440)
                                Text(
                                  '${actualFps.toStringAsFixed(1)} fps',
                                  key: const ValueKey('monitor-fps'),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.white70,
                                    fontFeatures: [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (hasNotice)
                    Positioned(
                      top: insets.top + (landscape ? 66 : 136),
                      left: insets.left + (landscape ? 68 : 12),
                      right: insets.right + (landscape ? 156 : 12),
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 400),
                          child: Material(
                            key: const ValueKey('monitor-message'),
                            color: const Color(0xcc302524),
                            borderRadius: BorderRadius.circular(12),
                            child: Padding(
                              padding: const EdgeInsets.only(left: 12),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Flexible(
                                    child: Text(
                                      error.isNotEmpty
                                          ? error
                                          : '未合焦，请调整对焦位置或检查镜头对焦模式。',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: '关闭提示',
                                    onPressed: () => setState(() {
                                      error = '';
                                      focusFailed = false;
                                    }),
                                    icon: const Icon(Icons.close, size: 16),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (!fullscreen && properties[0xd1a6]?['current'] != 1)
                    Positioned(
                      key: const ValueKey('monitor-meter'),
                      top: insets.top + (landscape ? 70 : 64),
                      left: landscape && meterOnRight ? null : insets.left + 12,
                      right: landscape
                          ? (meterOnRight ? insets.right + 100 : null)
                          : insets.right + 12,
                      bottom: landscape
                          ? insets.bottom +
                                76 +
                                (toolsExpanded
                                    ? math.max(48, box.maxHeight * .25)
                                    : 0)
                          : null,
                      child: IgnorePointer(
                        child: Center(
                          child: meteringOverlay(
                            vertical: landscape,
                            availableHeight:
                                box.maxHeight -
                                insets.top -
                                insets.bottom -
                                146 -
                                (toolsExpanded
                                    ? math.max(48, box.maxHeight * .25)
                                    : 0),
                          ),
                        ),
                      ),
                    ),
                  if (!fullscreen)
                    Positioned(
                      left: insets.left,
                      right: insets.right + (landscape ? 96 : 0),
                      bottom: insets.bottom,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AnimatedSize(
                            duration: const Duration(milliseconds: 180),
                            curve: Curves.easeOutCubic,
                            child: toolsExpanded
                                ? ConstrainedBox(
                                    constraints: BoxConstraints(
                                      maxHeight: math.max(
                                        48,
                                        box.maxHeight * .25,
                                      ),
                                    ),
                                    child: SingleChildScrollView(
                                      child: monitorTools(
                                        columns: landscape ? 10 : 5,
                                      ),
                                    ),
                                  )
                                : const SizedBox.shrink(),
                          ),
                          propertyPanel(columns: landscape ? 10 : 5),
                          if (!landscape)
                            ColoredBox(
                              color: Colors.black.withValues(alpha: .38),
                              child: captureControls(),
                            ),
                        ],
                      ),
                    ),
                  if (fullscreen && !landscape)
                    Positioned(
                      bottom: insets.bottom,
                      left: insets.left,
                      right: insets.right,
                      child: captureControls(),
                    ),
                  if (landscape)
                    Positioned(
                      top: insets.top + 60,
                      right: insets.right,
                      bottom: insets.bottom,
                      width: 96,
                      child: Center(child: captureControls(vertical: true)),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget batteryIndicator() => Tooltip(
    message: cameraBattery == null ? '相机电池：未提供电量' : '相机电池 $cameraBattery%',
    child: Semantics(
      label: cameraBattery == null ? '相机电量未知' : '相机电量百分之$cameraBattery',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            cameraBattery == null
                ? Icons.battery_unknown
                : cameraBattery! <= 10
                ? Icons.battery_alert
                : cameraBattery! <= 25
                ? Icons.battery_1_bar
                : cameraBattery! <= 50
                ? Icons.battery_3_bar
                : cameraBattery! <= 75
                ? Icons.battery_5_bar
                : Icons.battery_full,
            size: 18,
            color: cameraBattery != null && cameraBattery! <= 15
                ? Colors.redAccent
                : Colors.white70,
          ),
          Text(
            cameraBattery == null ? '—' : '$cameraBattery%',
            key: const ValueKey('monitor-battery'),
            style: const TextStyle(fontSize: 10),
          ),
          const SizedBox(width: 6),
        ],
      ),
    ),
  );

  Widget meteringOverlay({
    bool vertical = false,
    double availableHeight = 182,
  }) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: .42),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Semantics(
      label: meteringEv == null ? '相机测光标尺，未取得读数时显示零' : '相机测光标尺',
      child: vertical
          ? SizedBox(
              width: 28,
              height: math.min(170, math.max(32, availableHeight - 12)),
              child: Row(
                children: [
                  const Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [Text('+'), Text('0'), Text('−')],
                  ),
                  const SizedBox(width: 3),
                  Expanded(
                    child: RotatedBox(
                      quarterTurns: 3,
                      child: CustomPaint(
                        size: const Size(170, 18),
                        painter: _MeterScale(meteringEv ?? 0),
                      ),
                    ),
                  ),
                ],
              ),
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 160,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [Text('−'), Text('0'), Text('+')],
                  ),
                ),
                SizedBox(
                  width: 160,
                  height: 18,
                  child: CustomPaint(painter: _MeterScale(meteringEv ?? 0)),
                ),
              ],
            ),
    ),
  );

  Widget viewport() => Container(
    color: Colors.black,
    child: LayoutBuilder(
      builder: (context, box) {
        final aspect = frameWidth > 0 && frameHeight > 0
            ? frameWidth / frameHeight
            : 1.5;
        final width = math.min(box.maxWidth, box.maxHeight * aspect),
            height = width / aspect;
        return Stack(
          children: [
            Center(
              child: SizedBox(
                width: width,
                height: height,
                child: GestureDetector(
                  key: const ValueKey('monitor-picture'),
                  onTapUp: repo.supportsOperation(0x9205) && hasFrame
                      ? (d) => touchFocus(d.localPosition, Size(width, height))
                      : null,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (textureId != null && hasFrame)
                        Texture(textureId: textureId!),
                      if (hasFrame && (grid || safeArea || guideAspect > 0))
                        IgnorePointer(
                          child: CustomPaint(
                            painter: _Guides(grid, safeArea, guideAspect),
                          ),
                        ),
                      if (focusPoint != null && hasFrame)
                        Positioned(
                          left: (focusPoint!.dx * width - 18).clamp(
                            0.0,
                            math.max(0, width - 36),
                          ),
                          top: (focusPoint!.dy * height - 18).clamp(
                            0.0,
                            math.max(0, height - 36),
                          ),
                          child: IgnorePointer(
                            child: Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: focusFailed
                                      ? Colors.redAccent
                                      : focusing
                                      ? Colors.amber
                                      : focusSucceeded
                                      ? Colors.greenAccent
                                      : Colors.white,
                                  width: 2,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (!hasFrame)
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if ((busy || running) && !stopping)
                      const SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    const SizedBox(height: 12),
                    Text(
                      stopping
                          ? '正在结束监看…'
                          : suspended
                          ? '监看已暂停'
                          : error.isEmpty
                          ? status
                          : '监看已停止',
                      textAlign: TextAlign.center,
                    ),
                    if (!busy && !running && !stopping && !suspended)
                      TextButton(
                        onPressed: () {
                          _startup = start();
                        },
                        child: const Text('启动监看'),
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    ),
  );

  Widget scopeOverlay(BoxConstraints box, EdgeInsets insets, bool landscape) {
    final kind = waveform ? 'waveform' : 'histogram';
    final positionKey = '$kind-${landscape ? 'landscape' : 'portrait'}';
    final photoMeter = !fullscreen && properties[0xd1a6]?['current'] != 1;
    final left =
        insets.left + (landscape && photoMeter && !meterOnRight ? 68 : 12);
    final top = insets.top + (landscape ? 66 : 136) + (hasNotice ? 64 : 0);
    final right = math.max(
      left,
      box.maxWidth -
          insets.right -
          (landscape ? (photoMeter && meterOnRight ? 156 : 108) : 12),
    );
    final bottom = math.max(
      top,
      box.maxHeight -
          insets.bottom -
          (landscape ? 72 : (fullscreen ? 84 : 196)) -
          (!fullscreen && toolsExpanded
              ? math.max(48, box.maxHeight * .25)
              : 0),
    );
    final width = math.min(180.0, math.max(0.0, right - left));
    final height = math.min(94.0, math.max(0.0, bottom - top));
    final travel = Offset(
      math.max(0.0, right - left - width),
      math.max(0.0, bottom - top - height),
    );
    final position = scopePositions[positionKey] ?? const Offset(1, 0);
    return Positioned(
      left: left + travel.dx * position.dx,
      top: top + travel.dy * position.dy,
      width: width,
      height: height,
      child: GestureDetector(
        key: ValueKey('monitor-$kind'),
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (details) => setState(() {
          final current = scopePositions[positionKey] ?? const Offset(1, 0);
          scopePositions[positionKey] = Offset(
            travel.dx == 0
                ? current.dx
                : (current.dx + details.delta.dx / travel.dx).clamp(0, 1),
            travel.dy == 0
                ? current.dy
                : (current.dy + details.delta.dy / travel.dy).clamp(0, 1),
          );
        }),
        onPanEnd: (_) => saveOptions(),
        onPanCancel: saveOptions,
        child: Semantics(
          label: waveform ? '可拖动波形图' : '可拖动直方图',
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: .6),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white24),
            ),
            child: Column(
              children: [
                SizedBox(
                  height: math.min(20, height),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.drag_indicator,
                        size: 12,
                        color: Colors.white54,
                      ),
                      Text(
                        waveform ? '波形图' : '直方图',
                        style: const TextStyle(
                          fontSize: 10,
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(6, 0, 6, 5),
                    child: RepaintBoundary(
                      child: ValueListenableBuilder<int>(
                        valueListenable: scopeRevision,
                        builder: (_, value, child) => CustomPaint(
                          size: Size.infinite,
                          painter: waveform
                              ? _Waveform(wave)
                              : _Histogram(rgbBins),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget propertyBar() => Container(
    height: 54,
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(color: Colors.white12)),
    ),
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      children: [
        for (final code in [0x500d, 0x5007, 0x500f, 0x5010, 0x5005])
          TextButton(
            onPressed: busy || !running || stopping || !canEditExposure(code)
                ? null
                : () => editProperty(code),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  names[code]!,
                  style: const TextStyle(color: Colors.white54, fontSize: 10),
                ),
                Text(
                  properties[code] != null
                      ? compactLabel(code, properties[code]!['current'] as int)
                      : propertyErrors.containsKey(code)
                      ? '不支持'
                      : '读取中',
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        IconButton(
          tooltip: '更多相机参数',
          onPressed: () => settings('相机参数', cameraSettings),
          icon: const Icon(Icons.tune),
        ),
      ],
    ),
  );

  Widget toolBar() => SizedBox(
    height: 44,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      children: [
        tool(
          'LUT',
          Icons.filter,
          monitorLut,
          () => settings('监看 LUT', lutSettings),
        ),
        tool(
          '峰值',
          Icons.filter_center_focus,
          peaking,
          () => toggle(() => peaking = !peaking),
        ),
        tool('斑马纹', Icons.texture, zebra, () => toggle(() => zebra = !zebra)),
        tool(
          '直方图',
          Icons.bar_chart,
          histogram,
          () => toggle(() {
            histogram = !histogram;
            if (histogram) waveform = false;
          }),
        ),
        tool(
          '波形',
          Icons.stacked_line_chart,
          waveform,
          () => toggle(() {
            waveform = !waveform;
            if (waveform) histogram = false;
          }),
        ),
        tool('网格', Icons.grid_3x3, grid, () => toggle(() => grid = !grid)),
        tool(
          '辅助设置',
          Icons.settings_outlined,
          safeArea || guideAspect > 0,
          () => settings('监看辅助', assistSettings),
        ),
      ],
    ),
  );

  Widget tool(String text, IconData icon, bool selected, VoidCallback action) =>
      Padding(
        padding: const EdgeInsets.only(right: 4),
        child: TextButton.icon(
          onPressed: stopping ? null : action,
          icon: Icon(icon, size: 17),
          label: Text(text, style: const TextStyle(fontSize: 11)),
          style: TextButton.styleFrom(
            foregroundColor: selected
                ? const Color(0xfff4c45a)
                : Colors.white60,
            backgroundColor: selected ? Colors.white10 : Colors.transparent,
          ),
        ),
      );

  Widget controlPanel(
    List<Widget> cells, {
    int columns = 5,
    double height = 56,
  }) => LayoutBuilder(
    builder: (context, constraints) {
      final singleRow = columns == 10;
      final panelWidth = singleRow
          ? math.max(constraints.maxWidth, cells.length * 64.0 + 16)
          : constraints.maxWidth;
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: panelWidth,
          child: Container(
            margin: const EdgeInsets.fromLTRB(8, 3, 8, 3),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: .42),
              border: Border.all(color: Colors.white24),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              children: [
                for (var i = 0; i < cells.length; i += columns)
                  SizedBox(
                    height: height,
                    child: Row(
                      children: [
                        for (var j = 0; j < columns; j++)
                          Expanded(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                border: Border(
                                  right: BorderSide(
                                    color: j < columns - 1
                                        ? Colors.white12
                                        : Colors.transparent,
                                  ),
                                  bottom: BorderSide(
                                    color: i + columns < cells.length
                                        ? Colors.white12
                                        : Colors.transparent,
                                  ),
                                ),
                              ),
                              child: i + j < cells.length
                                  ? cells[i + j]
                                  : const SizedBox.expand(),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget panelCell(
    String title,
    String value,
    VoidCallback? action, {
    IconData? icon,
    bool active = false,
  }) => InkWell(
    onTap: stopping ? null : action,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 5),
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.2,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null)
              Icon(
                icon,
                size: 20,
                color: active ? Colors.amber : Colors.white70,
              )
            else
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  value,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: action == null ? Colors.white38 : Colors.white,
                  ),
                ),
              ),
            const SizedBox(height: 4),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                color: active ? Colors.amber : Colors.white54,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget propertyPanel({int columns = 5}) => controlPanel([
    for (final code in [
      0xd1a6,
      0x500d,
      0x5007,
      0x500f,
      0x5005,
      0x5010,
      0x500e,
      0x500a,
      0x500b,
    ])
      panelCell(
        names[code]!,
        properties[code] != null
            ? compactLabel(code, properties[code]!['current'] as int)
            : propertyErrors.containsKey(code)
            ? '—'
            : '…',
        busy ||
                !running ||
                !canEditExposure(code) ||
                (properties[code]?['writable'] == false &&
                    !{0x500d, 0x5007, 0x500f}.contains(code))
            ? null
            : () => editProperty(code),
      ),
    panelCell(
      '辅助工具',
      toolsExpanded ? '收起' : '展开',
      () => setState(() => toolsExpanded = !toolsExpanded),
    ),
  ], columns: columns);

  Widget monitorTools({int columns = 5}) => controlPanel(
    [
      panelCell(
        '直方图',
        '',
        () => toggle(() {
          histogram = !histogram;
          if (histogram) waveform = false;
        }),
        icon: Icons.bar_chart,
        active: histogram,
      ),
      panelCell(
        '波形',
        '',
        () => toggle(() {
          waveform = !waveform;
          if (waveform) histogram = false;
        }),
        icon: Icons.stacked_line_chart,
        active: waveform,
      ),
      panelCell(
        '网格',
        '',
        () => toggle(() => grid = !grid),
        icon: Icons.grid_3x3,
        active: grid,
      ),
      panelCell(
        'LUT',
        '',
        () => settings('监看 LUT', lutSettings),
        icon: Icons.palette_outlined,
        active: monitorLut,
      ),
      panelCell(
        '峰值',
        '',
        () => toggle(() => peaking = !peaking),
        icon: Icons.filter_center_focus,
        active: peaking,
      ),
      panelCell(
        '镜像',
        '',
        () => toggle(() => mirror = !mirror),
        icon: Icons.flip,
        active: mirror,
      ),
      panelCell(
        '安全区',
        '',
        () => toggle(() => safeArea = !safeArea),
        icon: Icons.crop_free,
        active: safeArea,
      ),
    ],
    columns: columns,
    height: 58,
  );

  Widget captureControls({bool vertical = false}) {
    final movie = recording || properties[0xd1a6]?['current'] == 1;
    final operation = movie ? (recording ? 0x920b : 0x920a) : 0x9207;
    final enabled =
        running &&
        !busy &&
        !stopping &&
        properties[0xd1a6] != null &&
        repo.supportsOperation(operation);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: vertical ? 4 : 16, vertical: 8),
      child: Flex(
        direction: vertical ? Axis.vertical : Axis.horizontal,
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            tooltip: '图库',
            onPressed: stopping
                ? null
                : () async {
                    await leave();
                    widget.c.navigate(2);
                  },
            icon: const Icon(Icons.photo_library_outlined),
          ),
          SizedBox(width: vertical ? 0 : 32, height: vertical ? 12 : 0),
          SizedBox(
            width: 68,
            height: 68,
            child: Tooltip(
              message: movie ? (recording ? '停止录像' : '开始录像') : '拍摄到存储卡',
              child: OutlinedButton(
                onPressed: enabled ? () => action(operation) : null,
                style: OutlinedButton.styleFrom(
                  shape: const CircleBorder(),
                  padding: const EdgeInsets.all(6),
                  side: BorderSide(
                    color: enabled ? Colors.white : Colors.white38,
                    width: 2,
                  ),
                ),
                child: Center(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: recording ? 28 : 52,
                    height: recording ? 28 : 52,
                    decoration: BoxDecoration(
                      color: movie
                          ? (enabled
                                ? const Color(0xffff414d)
                                : const Color(0xff7d3036))
                          : (enabled ? Colors.white : Colors.white38),
                      borderRadius: BorderRadius.circular(recording ? 7 : 26),
                      boxShadow: movie && enabled
                          ? [
                              BoxShadow(
                                color: Colors.redAccent.withValues(alpha: .23),
                                blurRadius: 10,
                              ),
                            ]
                          : null,
                    ),
                  ),
                ),
              ),
            ),
          ),
          SizedBox(width: vertical ? 0 : 32, height: vertical ? 12 : 0),
          IconButton(
            tooltip: '监看设置',
            onPressed: () => settings('监看设置', monitorSettings),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
    );
  }

  Widget monitorSettings(StateSetter refresh) => Column(
    children: [
      ListTile(
        title: const Text('相机参数'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          Navigator.pop(context);
          settings('相机参数', cameraSettings);
        },
      ),
      ListTile(
        title: const Text('监看 LUT'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          Navigator.pop(context);
          settings('监看 LUT', lutSettings);
        },
      ),
      DropdownButtonFormField<int>(
        isExpanded: true,
        menuMaxHeight: math.max(96, MediaQuery.sizeOf(context).height * .6),
        initialValue: repo.liveImageSize,
        decoration: const InputDecoration(labelText: '监看画质'),
        items: const [
          DropdownMenuItem(value: 3, child: Text('清晰 · XGA')),
          DropdownMenuItem(value: 2, child: Text('流畅 · VGA')),
        ],
        onChanged: !running || busy
            ? null
            : (value) async {
                if (value == null) return;
                await perform(() async {
                  await repo.setLiveImageSize(value);
                  saveOptions();
                });
                if (mounted) refresh(() {});
              },
      ),
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text(
          '清晰模式保留更多细节；流畅模式减少传输量。实际分辨率和帧率显示在画面上。',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
      ),
      DropdownButtonFormField<int>(
        isExpanded: true,
        menuMaxHeight: math.max(96, MediaQuery.sizeOf(context).height * .6),
        initialValue: fps,
        decoration: const InputDecoration(labelText: '帧率上限'),
        items: [
          for (final value in [0, 24, 30, 60])
            DropdownMenuItem(
              value: value,
              child: Text(value == 0 ? '相机原速' : '$value fps'),
            ),
        ],
        onChanged: (value) {
          setState(() => fps = value!);
          saveOptions();
          refresh(() {});
        },
      ),
      SwitchListTile(
        title: const Text('斑马纹'),
        value: zebra,
        onChanged: (value) {
          toggle(() => zebra = value);
          refresh(() {});
        },
      ),
      assistSettings(refresh),
    ],
  );

  void toggle(VoidCallback change) {
    setState(change);
    saveOptions();
    unawaited(
      gpuOptions().catchError((Object e) {
        if (mounted) setState(() => error = userMessage(e));
      }),
    );
  }

  Future<void> settings(
    String title,
    Widget Function(StateSetter) content,
  ) async {
    if (title == '监看 LUT') await _lutLoad;
    if (!mounted) return;
    await monitorSheet<void>(
      title,
      (context) => StatefulBuilder(
        builder: (context, refresh) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: content((work) {
            if (context.mounted) refresh(work);
          }),
        ),
      ),
    );
  }

  Future<T?> monitorSheet<T>(
    String title,
    WidgetBuilder content,
  ) => showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭设置',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 180),
    transitionBuilder: (_, animation, secondary, child) => FadeTransition(
      opacity: animation,
      child: ScaleTransition(
        scale: Tween<double>(begin: .96, end: 1).animate(
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
        ),
        child: child,
      ),
    ),
    pageBuilder: (context, animation, secondary) => SafeArea(
      child: Align(
        alignment: MediaQuery.orientationOf(context) == Orientation.landscape
            ? Alignment.centerRight
            : Alignment.bottomCenter,
        child: Padding(
          padding: EdgeInsets.only(
            left: 12,
            right: MediaQuery.orientationOf(context) == Orientation.landscape
                ? 100
                : 12,
            bottom: MediaQuery.orientationOf(context) == Orientation.landscape
                ? 72
                : 196,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Material(
                color: const Color(0x9920252b),
                child: Theme(
                  data: ThemeData.dark(useMaterial3: true),
                  child: SizedBox(
                    key: const ValueKey('monitor-popover'),
                    width: 276,
                    height: math.min(
                      256,
                      MediaQuery.sizeOf(context).height * .58,
                    ),
                    child: Column(
                      children: [
                        SizedBox(
                          height: 42,
                          child: Row(
                            children: [
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                              IconButton(
                                tooltip: '关闭设置',
                                onPressed: () => Navigator.pop(context),
                                icon: const Icon(Icons.close, size: 18),
                              ),
                            ],
                          ),
                        ),
                        Expanded(child: content(context)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget assistSettings(StateSetter refresh) {
    void change(VoidCallback work) {
      toggle(work);
      refresh(() {});
    }

    return Column(
      children: [
        SwitchListTile(
          title: const Text('水平镜像'),
          value: mirror,
          onChanged: (v) => change(() => mirror = v),
        ),
        SwitchListTile(
          title: const Text('90% 安全框'),
          value: safeArea,
          onChanged: (v) => change(() => safeArea = v),
        ),
        DropdownButtonFormField<double>(
          isExpanded: true,
          menuMaxHeight: math.max(96, MediaQuery.sizeOf(context).height * .6),
          initialValue: [0.0, 1.0, 1.5, 16 / 9, 2.35].contains(guideAspect)
              ? guideAspect
              : 0,
          decoration: const InputDecoration(labelText: '画幅辅助线（保留完整取景）'),
          items: [
            for (final e in <double, String>{
              0: '关闭',
              1: '1:1',
              1.5: '3:2',
              16 / 9: '16:9',
              2.35: '2.35:1',
            }.entries)
              DropdownMenuItem(value: e.key, child: Text(e.value)),
          ],
          onChanged: (v) => change(() => guideAspect = v!),
        ),
        const SizedBox(height: 16),
        Text('斑马纹阈值 ${(zebraThreshold * 100).round()}%'),
        Slider(
          value: zebraThreshold,
          min: .5,
          max: 1,
          divisions: 50,
          onChanged: (v) {
            setState(() => zebraThreshold = v);
            refresh(() {});
          },
          onChangeEnd: (_) => toggle(() {}),
        ),
        Text('峰值灵敏度 ${((.33 - peakingThreshold) / .3 * 100).round()}%'),
        Slider(
          value: peakingThreshold,
          min: .03,
          max: .3,
          onChanged: (v) {
            setState(() => peakingThreshold = v);
            refresh(() {});
          },
          onChangeEnd: (_) => toggle(() {}),
        ),
        const Text(
          '直方图和波形读取 LUT 与辅助色叠加前的取景亮度。辅助显示不会写入相机照片。',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
      ],
    );
  }

  Widget lutSettings(StateSetter refresh) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SwitchListTile(
        title: const Text('启用监看 LUT'),
        value: monitorLut,
        onChanged: lut.isEmpty
            ? null
            : (v) {
                toggle(() => monitorLut = v);
                refresh(() {});
              },
      ),
      DropdownButtonFormField<String>(
        menuMaxHeight: math.max(96, MediaQuery.sizeOf(context).height * .6),
        initialValue: luts.contains(lut) ? lut : null,
        isExpanded: true,
        decoration: const InputDecoration(labelText: '选择 LUT'),
        items: [
          for (final name in luts)
            DropdownMenuItem(
              value: name,
              child: Text(
                name.split('/').last,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: (name) async {
          if (name == null) return;
          try {
            await nativeCamera.invokeMethod('gpuLut', {'name': name});
            if (!mounted) return;
            toggle(() {
              lut = name;
              monitorLut = true;
            });
            if (context.mounted) refresh(() {});
          } catch (e) {
            if (mounted) setState(() => error = userMessage(e));
          }
        },
      ),
      const SizedBox(height: 16),
      Text('强度 ${(lutIntensity * 100).round()}%'),
      Slider(
        value: lutIntensity,
        onChanged: (v) {
          setState(() => lutIntensity = v);
          refresh(() {});
        },
        onChangeEnd: (_) => toggle(() {}),
      ),
      const Text(
        '监看 LUT 独立保存，不改变照片编辑中的 LUT 设置。',
        style: TextStyle(color: Colors.white54, fontSize: 12),
      ),
    ],
  );

  Widget cameraSettings(StateSetter refresh) => Column(
    children: [
      for (final code in names.keys)
        ListTile(
          title: Text(names[code]!),
          subtitle: Text(
            properties[code] != null
                ? compactLabel(code, properties[code]!['current'] as int)
                : propertyErrors[code] ?? '尚未读取',
          ),
          trailing: properties[code]?['writable'] == true
              ? const Icon(Icons.chevron_right)
              : const Icon(Icons.lock_outline, size: 16),
          onTap: !running || busy || !canEditExposure(code)
              ? null
              : () async {
                  Navigator.pop(context);
                  await editProperty(code);
                },
        ),
    ],
  );

  Future<void> editProperty(int code) async {
    if (!canEditExposure(code)) return;
    if (recording) {
      setState(() => error = '请先停止录像，再调整相机参数');
      return;
    }
    _dirtyProperties.add(code);
    await readProperty(code, _epoch);
    if (!mounted) return;
    final p = properties[code];
    if (p == null) {
      setState(() => error = '${names[code]}：${propertyErrors[code]}');
      return;
    }
    Map<String, dynamic>? automatic;
    int? automaticValue;
    if (code == 0x500f) {
      try {
        automatic = await repo.property(
          code == 0x500f
              ? (properties[0xd1a6]?['current'] == 1 ? 0xd0ad : 0xd054)
              : 0x500e,
        );
        automaticValue = code == 0x500f
            ? 1
            : code == 0x500d
            ? 3
            : 4;
        if (automatic['writable'] != true ||
            !(automatic['values'] as List).contains(automaticValue)) {
          automatic = null;
        }
      } on PtpException catch (e) {
        if (!e.unsupported) rethrow;
      }
    }
    if (!mounted) return;
    final values =
        (p['writable'] == true || (code == 0x500f && automatic != null))
        ? List<int>.from(p['values'] as List)
        : <int>[];
    if (automatic == null && values.isEmpty) {
      setState(() => error = '${names[code]}在相机当前模式下为只读');
      return;
    }
    if (code == 0x500d) {
      values.sort(
        (a, b) =>
            compareShutterLongestFirst(a, b, propertyCode: p['code'] as int?),
      );
    }
    // Deduplicate nominal labels but retain the exact writable camera payload.
    final nominalValues = <String, int>{};
    for (final value in values) {
      if (!isThirdStopChoice(code, value, propertyCode: p['code'] as int?)) {
        continue;
      }
      nominalValues.putIfAbsent(label(code, value), () => value);
    }
    if (nominalValues.isEmpty && automatic == null) {
      setState(() => error = '相机当前未提供可设置的 1/3 档参数');
      return;
    }
    final choices = <int>[
      if (automatic != null) -2147483648,
      ...nominalValues.values,
    ];
    final initial = choices
        .indexOf(p['current'] as int)
        .clamp(0, math.max(0, choices.length - 1));
    final wheel = FixedExtentScrollController(initialItem: initial.toInt());
    final selected = await monitorSheet<int>(
      names[code]!,
      (context) => ListWheelScrollView.useDelegate(
        controller: wheel,
        itemExtent: 40,
        diameterRatio: 1.7,
        perspective: .002,
        physics: const FixedExtentScrollPhysics(),
        overAndUnderCenterOpacity: .45,
        childDelegate: ListWheelChildBuilderDelegate(
          childCount: choices.length,
          builder: (context, index) {
            final v = choices[index];
            return InkWell(
              onTap: () => Navigator.pop(context, v),
              child: Center(
                child: Text(
                  v == -2147483648 ? '自动 ISO' : label(code, v),
                  style: TextStyle(
                    fontSize: 17,
                    color: v == p['current'] ? Colors.amber : Colors.white,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
    // Route transition retains the wheel briefly; dispose after it has detached.
    Future<void>.delayed(const Duration(milliseconds: 220), wheel.dispose);
    if (selected == null || !mounted) return;
    _lastMeterRead = DateTime.fromMillisecondsSinceEpoch(0);
    await perform(() async {
      if (selected == -2147483648 && automatic != null) {
        await repo.setProperty(
          automatic['code'] as int,
          automatic['type'] as int,
          automaticValue!,
        );
      } else {
        if (code == 0x500f &&
            automatic != null &&
            (automatic['values'] as List).contains(0)) {
          await repo.setProperty(
            automatic['code'] as int,
            automatic['type'] as int,
            0,
          );
        }
        var target = p;
        if (code == 0x500f && p['writable'] != true) {
          _dirtyProperties.add(code);
          await readProperty(code, _epoch);
          target = properties[code]!;
          if (target['writable'] != true ||
              !(target['values'] as List).contains(selected)) {
            throw StateError('相机尚未提供该 ISO 数值，请重新选择');
          }
        }
        await repo.setProperty(
          target['code'] as int,
          target['type'] as int,
          selected,
        );
      }
      // Camera modes affect other descriptors; read them again between frames.
      _dirtyProperties.addAll(names.keys);
      propertyErrors.clear();
      await readProperty(code, _epoch);
    });
  }
}

class _Guides extends CustomPainter {
  const _Guides(this.grid, this.safe, this.aspect);
  final bool grid, safe;
  final double aspect;
  @override
  void paint(Canvas c, Size s) {
    final p = Paint()
      ..color = Colors.white.withValues(alpha: .6)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    if (grid) {
      for (var i = 1; i < 3; i++) {
        c.drawLine(
          Offset(s.width * i / 3, 0),
          Offset(s.width * i / 3, s.height),
          p,
        );
        c.drawLine(
          Offset(0, s.height * i / 3),
          Offset(s.width, s.height * i / 3),
          p,
        );
      }
    }
    if (safe) {
      c.drawRect(
        Rect.fromLTWH(
          s.width * .05,
          s.height * .05,
          s.width * .9,
          s.height * .9,
        ),
        p..color = Colors.amber.withValues(alpha: .7),
      );
    }
    if (aspect > 0) {
      final w = math.min(s.width, s.height * aspect), h = w / aspect;
      c.drawRect(
        Rect.fromCenter(center: s.center(Offset.zero), width: w, height: h),
        p..color = Colors.white,
      );
    }
  }

  @override
  bool shouldRepaint(_Guides old) =>
      old.grid != grid || old.safe != safe || old.aspect != aspect;
}

class _Histogram extends CustomPainter {
  const _Histogram(this.channels);
  final List<List<int>> channels;
  @override
  void paint(Canvas canvas, Size size) {
    if (channels.length != 3 || channels.any((c) => c.length != 256)) return;
    final peak = channels.expand((c) => c).fold<int>(0, math.max);
    if (peak == 0) return;
    final chartHeight = size.height - 13;
    const colors = [
      Colors.redAccent,
      Colors.greenAccent,
      Colors.lightBlueAccent,
    ];
    for (var ch = 0; ch < 3; ch++) {
      // Connect 256 real bins; square-root vertical scaling preserves small peaks.
      final path = Path();
      for (var i = 0; i < 256; i++) {
        final x = i / 255 * size.width;
        final y = chartHeight * (1 - math.sqrt(channels[ch][i] / peak));
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      final fill = Path.from(path)
        ..lineTo(size.width, chartHeight)
        ..lineTo(0, chartHeight)
        ..close();
      canvas.drawPath(fill, Paint()..color = colors[ch].withValues(alpha: .16));
      canvas.drawPath(
        path,
        Paint()
          ..color = colors[ch].withValues(alpha: .9)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.1
          ..strokeJoin = StrokeJoin.round,
      );
    }
    for (final entry in [('阴影', 0.0), ('高光', size.width - 24)]) {
      final text = TextPainter(
        text: TextSpan(
          text: entry.$1,
          style: const TextStyle(color: Colors.white70, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      text.paint(canvas, Offset(entry.$2, chartHeight + 1));
    }
  }

  @override
  bool shouldRepaint(_Histogram old) => old.channels != channels;
}

class _Waveform extends CustomPainter {
  const _Waveform(this.bins);
  final List<int> bins;
  @override
  void paint(Canvas c, Size s) {
    if (bins.length != 160 * 64) return;
    final p = Paint();
    for (var i = 0; i < bins.length; i++) {
      if (bins[i] == 0) continue;
      p.color = Colors.greenAccent.withValues(
        alpha: (.15 + math.sqrt(bins[i]) / 5).clamp(0.0, 1.0),
      );
      c.drawRect(
        Rect.fromLTWH(
          i % 160 * s.width / 160,
          i ~/ 160 * s.height / 64,
          s.width / 160,
          s.height / 64,
        ),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(_Waveform old) => old.bins != bins;
}

class _MeterScale extends CustomPainter {
  _MeterScale(this.ev);
  final double? ev;
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white70
      ..strokeWidth = 1;
    for (var i = 0; i <= 18; i++) {
      final x = i * size.width / 18;
      canvas.drawLine(Offset(x, 0), Offset(x, i % 3 == 0 ? 8 : 4), p);
    }
    if (ev == null) return;
    final value = ev!;
    final x = (value.clamp(-3, 3) + 3) / 6 * size.width;
    p
      ..color = value.abs() < .2 ? Colors.greenAccent : Colors.amber
      ..strokeWidth = 3;
    canvas.drawLine(Offset(x, 9), Offset(x, 18), p);
  }

  @override
  bool shouldRepaint(covariant _MeterScale oldDelegate) => oldDelegate.ev != ev;
}
