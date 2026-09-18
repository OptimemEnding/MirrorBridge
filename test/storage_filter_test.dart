import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirrorbridge/models/camera_storage.dart';
import 'package:mirrorbridge/models/media_item.dart';
import 'package:mirrorbridge/pages/home_page.dart';
import 'package:mirrorbridge/pages/media_page.dart';
import 'package:mirrorbridge/pages/settings_pages.dart';
import 'package:mirrorbridge/protocol/ptp.dart';
import 'package:mirrorbridge/repositories/demo_repository.dart';
import 'package:mirrorbridge/repositories/nikon_repository.dart';
import 'package:mirrorbridge/state/app_controller.dart';
import 'package:mirrorbridge/theme/app_theme.dart';

const firstCard = 0x10001, secondCard = 0x20001;

class StoragePtp implements PtpTransport {
  List<int> cards = [firstCard, secondCard];
  bool emptyFirstSlot = false;
  int objectReads = 0, directoryQueries = 0;
  bool rejectDirectoryQuery = false;
  final objects = <int, (int, int, String)>{
    100: (firstCard, 0, '100NIKON'),
    101: (firstCard, 0, 'EMPTY'),
    102: (firstCard, 0, '100NIKON'),
    200: (secondCard, 0, '100NIKON'),
    for (var i = 1; i <= 25; i++) i: (firstCard, 100, 'A_$i.JPG'),
    26: (firstCard, 102, 'ANOTHER.JPG'),
    for (var i = 30; i < 70; i++) i: (secondCard, 200, 'B_$i.JPG'),
  };
  static List<int> str(String s) => [
    s.length + 1,
    for (final code in s.codeUnits) ...ptpU16(code),
    0,
    0,
  ];

  @override
  Future<Uint8List> data(int code, [List<int> params = const []]) async {
    if (code == 0x1004) {
      final ids = [if (emptyFirstSlot) 0x10000, ...cards];
      return ptpWords([ids.length, ...ids]);
    }
    if (code == 0x1005) {
      if (params.first == 0x10000) throw PtpException(code, 0x2013);
      final bytes = ByteData(26)
        ..setUint16(0, 4, Endian.little)
        ..setUint16(2, 2, Endian.little)
        ..setUint64(6, 128 * 1073741824, Endian.little)
        ..setUint64(14, 80 * 1073741824, Endian.little);
      return Uint8List.fromList([
        ...bytes.buffer.asUint8List(),
        ...str(
          params.first == firstCard
              ? 'CFexpress Type B Model-123'
              : 'SDXC Model-456',
        ),
        ...str('NIKON'),
      ]);
    }
    if (code == 0x1007) {
      if (params[1] == 0x3001) {
        directoryQueries++;
        if (rejectDirectoryQuery) throw PtpException(code, 0x2014);
      }
      final handles = objects.entries
          .where(
            (e) =>
                e.value.$1 == params.first &&
                (params[1] != 0x3001 || !e.value.$3.contains('.')),
          )
          .map((e) => e.key)
          .toList();
      return ptpWords([handles.length, ...handles]);
    }
    if (code == 0x1008) {
      objectReads++;
      final (storage, parent, name) = objects[params.first]!;
      final header = ByteData(52)
        ..setUint32(0, storage, Endian.little)
        ..setUint16(4, name.contains('.') ? 0x3801 : 0x3001, Endian.little)
        ..setUint32(8, 1048576, Endian.little)
        ..setUint32(38, parent, Endian.little);
      return Uint8List.fromList([
        ...header.buffer.asUint8List(),
        ...str(name),
        ...str('20260911T120000'),
      ]);
    }
    throw StateError('Unexpected PTP operation: $code');
  }

  @override
  Future<void> command(int code, [List<int> params = const []]) async {}
  @override
  Future<void> writeProperty(int property, Uint8List bytes) async {}
  @override
  Future<void> close() async {}
}

class SlowThumbnailPtp extends StoragePtp {
  final thumbnailEntered = Completer<void>();
  final releaseThumbnail = Completer<void>();
  int thumbnails = 0;
  @override
  Future<Uint8List> data(int code, [List<int> params = const []]) async {
    if (code == 0x100a) {
      thumbnails++;
      if (!thumbnailEntered.isCompleted) thumbnailEntered.complete();
      await releaseThumbnail.future;
      return Uint8List.fromList([255, 216, 1, 2, 255, 217]);
    }
    return super.data(code, params);
  }
}

class SlowIndexPtp extends StoragePtp {
  final releaseIndex = Completer<void>();
  int reads = 0;
  @override
  Future<Uint8List> data(int code, [List<int> params = const []]) async {
    if (code == 0x1008 && ++reads > 20) await releaseIndex.future;
    return super.data(code, params);
  }
}

Future<AppController> fixture(StoragePtp ptp) async {
  final repo = NikonRepository()
    ..transport = ptp
    ..device = PtpDeviceInfo('Nikon', 'Z 8', 'fixture', {}, {})
    ..sourceIdentity = 'fixture';
  final c = AppController(repo)
    ..connection = ConnectionPhase.connected
    ..tab = 2;
  await c.refreshMedia();
  await settleIndex(repo);
  return c;
}

Future<void> settleIndex(NikonRepository repo) async {
  for (var i = 0; repo.indexing && i < 2000; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(repo.indexing, false);
}

Future<void> settleLoading(AppController c) async {
  for (var i = 0; c.loadingMedia && i < 100; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(c.loadingMedia, false);
}

Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
  if (!const bool.fromEnvironment('CAPTURE_STORAGE_UI')) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory('dist/storage-screenshots').create(recursive: true);
    await File(
      'dist/storage-screenshots/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUpAll(() async {
    if (const bool.fromEnvironment('CAPTURE_STORAGE_UI')) {
      final font = FontLoader('StorageUi')
        ..addFont(
          File(
            const String.fromEnvironment('UI_FONT_PATH'),
          ).readAsBytes().then(ByteData.sublistView),
        );
      await font.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          File(
            const String.fromEnvironment('UI_ICON_FONT_PATH'),
          ).readAsBytes().then(ByteData.sublistView),
        );
      await icons.load();
    }
  });
  setUp(() {
    messenger.setMockMethodCallHandler(
      AppController.platform,
      (call) async => call.method == 'storageInfo'
          ? {'freeBytes': 80 * 1073741824, 'totalBytes': 256 * 1073741824}
          : null,
    );
    messenger.setMockMethodCallHandler(nativeCamera, (_) async => null);
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(AppController.platform, null);
    messenger.setMockMethodCallHandler(nativeCamera, null);
  });

  test(
    'refresh returns first 20 files without waiting for a 2000 file index',
    () async {
      final ptp = SlowIndexPtp()..cards = [firstCard];
      ptp.objects.clear();
      for (var i = 1; i <= 2000; i++) {
        ptp.objects[i] = (firstCard, 0, 'DSC_$i.JPG');
      }
      final repo = NikonRepository()
        ..transport = ptp
        ..device = PtpDeviceInfo('Nikon', 'Z 8', 'fixture', {}, {})
        ..sourceIdentity = 'fixture';
      try {
        await repo.refresh().timeout(const Duration(seconds: 2));
        expect(repo.media, hasLength(20));
        expect(repo.hasMore, true);
        expect(repo.totalMediaCount, isNull);
        expect(ptp.reads, lessThanOrEqualTo(21));
      } finally {
        await repo.dispose();
        ptp.releaseIndex.complete();
      }
    },
  );

  test(
    'refresh rereads visible metadata but keeps unchanged thumbnails',
    () async {
      final ptp = StoragePtp();
      final c = await fixture(ptp);
      addTearDown(c.dispose);
      final first = c.media.first
        ..thumbnailPath = '/cached/preview.jpg'
        ..contentHash = 'old-camera-contents'
        ..hashVerified = true;
      final before = ptp.objectReads;
      await c.refreshMedia();
      expect(ptp.objectReads, greaterThan(before));
      expect(identical(c.media.first, first), false);
      expect(c.media.first.thumbnailPath, '/cached/preview.jpg');
      expect(c.media.first.contentHash, isEmpty);
      expect(c.media.first.hashVerified, false);
      ptp.objects[999] = (secondCard, 200, 'NEW.JPG');
      await c.refreshMedia();
      await settleIndex(c.nikon!);
      expect(ptp.objectReads, greaterThan(before + 1));
      expect(c.media.first.name, 'NEW.JPG');
      expect(c.cameraTotal, 67);
    },
  );

  test(
    'filtered refresh reuses nonmatching metadata and only rereads twenty matches',
    () async {
      final ptp = StoragePtp();
      final c = await fixture(ptp);
      addTearDown(c.dispose);
      c.selectedStorageIds.add(firstCard);
      await c.refreshMedia(more: true);
      await settleIndex(c.nikon!);
      final first = c.visible.first..thumbnailPath = '/cached/filtered.jpg';
      final before = ptp.objectReads;
      await c.refreshMedia();
      await settleIndex(c.nikon!);
      final reads = ptp.objectReads - before;
      debugPrint(
        'FILTERED_REFRESH matching=${c.visible.length} objectReads=$reads',
      );
      expect(c.visible, hasLength(20));
      expect(reads, 20);
      expect(c.visible.first.id, first.id);
      expect(c.visible.first.thumbnailPath, '/cached/filtered.jpg');
      ptp.objects[999] = (firstCard, 100, 'NEW_FILTERED.JPG');
      await c.refreshMedia();
      expect(c.visible.any((m) => m.name == 'NEW_FILTERED.JPG'), true);
    },
  );

  test(
    'refresh skips queued thumbnail downloads instead of waiting for the entire grid',
    () async {
      final ptp = SlowThumbnailPtp();
      final c = await fixture(ptp);
      final directory = await Directory.systemTemp.createTemp(
        'refresh-priority-',
      );
      final repo = c.nikon!..cache = directory.path;
      try {
        final first = repo.thumbnail(c.media[0]);
        await ptp.thumbnailEntered.future;
        final second = repo.thumbnail(c.media[1]);
        final refreshing = repo.refresh();
        ptp.releaseThumbnail.complete();
        expect(await first, isNotNull);
        expect(await second, isNull);
        await refreshing;
        expect(ptp.thumbnails, 1);
        expect(repo.media, hasLength(20));
      } finally {
        await repo.dispose();
        c.dispose();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'only the inserted second slot is listed with real capacity and descriptor',
    () async {
      final c = await fixture(
        StoragePtp()
          ..cards = [secondCard]
          ..emptyFirstSlot = true,
      );
      addTearDown(c.dispose);
      final storage = c.cameraStorages.single;
      expect(storage.id, secondCard);
      expect(storage.slot, 2);
      expect(storage.title, '卡槽 2');
      expect(storage.description, 'SDXC Model-456');
      expect(storage.volumeLabel, 'NIKON');
      expect(storage.capacity, 128 * 1073741824);
      expect(storage.details, contains('剩余 80.0 GB / 128.0 GB'));
      expect(c.media.every((m) => m.card == 2), true);
      c.setStorage(storage);
      expect(c.visible.length, 20);
      expect(c.visibleTotal, 40);
    },
  );

  test(
    'card display keeps volume and capacity without type or model labels',
    () {
      final storage = CameraStorage({
        'id': firstCard,
        'description': 'CFexpress Type B',
        'volumeLabel': 'NIKON',
        'capacity': -1,
        'free': -1,
      });
      expect(storage.title, '卡槽 1');
      expect(storage.details, '卷标：NIKON\n容量未知');
    },
  );

  test(
    'card filter finds later pages and folders include unloaded and empty directories',
    () async {
      final c = await fixture(StoragePtp());
      addTearDown(c.dispose);
      expect(c.media.every((m) => m.storageId == secondCard), true);
      expect(c.cameraFolders.where((f) => f.name == '100NIKON'), hasLength(3));
      expect(c.cameraFolders.any((f) => f.name == 'EMPTY'), true);
      c.selectAllLoaded();
      c.setStorage(c.cameraStorages.first);
      await settleLoading(c);
      expect(c.selection, isEmpty);
      expect(c.visible.every((m) => m.storageId == firstCard), true);
      expect(c.visible.length, greaterThanOrEqualTo(20));
      expect(c.visibleTotal, 26);
      expect(c.cameraFolders.every((f) => f.storageId == firstCard), true);
      await c.refreshMedia(more: true);
      expect(c.visible.length, 26);
      expect(c.hasMoreVisible, false);
    },
  );

  test(
    'directory query discovers every folder without scanning media metadata',
    () async {
      final ptp = StoragePtp();
      final repo = NikonRepository()
        ..transport = ptp
        ..storages = [
          {'id': firstCard},
          {'id': secondCard},
        ];
      await repo.readFolders();
      expect(repo.folders, hasLength(4));
      expect(repo.foldersIndexed, true);
      expect(ptp.objectReads, 4);
      expect(ptp.directoryQueries, 2);
      expect(repo.media, isEmpty);
      await repo.dispose();
    },
  );

  test(
    'unsupported directory query stays incomplete until metadata indexing finishes',
    () async {
      final ptp = StoragePtp()..rejectDirectoryQuery = true;
      final repo = NikonRepository()
        ..transport = ptp
        ..device = PtpDeviceInfo('Nikon', 'Z 8', 'fixture', {}, {})
        ..storages = [
          {'id': firstCard},
          {'id': secondCard},
        ];
      await repo.readFolders();
      expect(repo.foldersIndexed, false);
      await repo.refresh();
      await settleIndex(repo);
      expect(repo.foldersIndexed, true);
      expect(repo.folders, hasLength(4));
      await repo.dispose();
    },
  );

  test(
    'parent folder includes nested media and displays full directory paths',
    () async {
      final ptp = StoragePtp();
      ptp.objects[99] = (firstCard, 0, 'DCIM');
      ptp.objects[100] = (firstCard, 99, '100NIKON');
      final c = await fixture(ptp);
      addTearDown(c.dispose);
      expect(
        c.cameraFolders.singleWhere((f) => f.handle == 100).displayName,
        'DCIM/100NIKON',
      );
      c.setFolder(c.cameraFolders.singleWhere((f) => f.handle == 99));
      await settleLoading(c);
      await c.refreshMedia(more: true);
      expect(c.visible, hasLength(25));
      expect(c.visibleTotal, 25);
    },
  );

  test('same named folders use both storage and directory identity', () async {
    final c = await fixture(StoragePtp());
    addTearDown(c.dispose);
    c.setFolder(c.cameraFolders.singleWhere((f) => f.handle == 100));
    await settleLoading(c);
    await c.refreshMedia(more: true);
    expect(c.visible, hasLength(25));
    expect(
      c.visible.every((m) => m.parentHandle == 100 && m.storageId == firstCard),
      true,
    );
    c.setFolder(c.cameraFolders.singleWhere((f) => f.handle == 102));
    await settleLoading(c);
    expect(c.visible.single.name, 'ANOTHER.JPG');
    c.setStorage(c.cameraStorages.last);
    expect(c.folder, '全部文件夹');
    expect(c.folderStorageId, isNull);
    expect(c.visible.every((m) => m.storageId == secondCard), true);
  });

  test(
    'empty filter stays at zero and does not fetch unrelated pages',
    () async {
      final ptp = StoragePtp();
      final c = await fixture(ptp);
      addTearDown(c.dispose);
      final reads = ptp.objectReads;
      c.setFolder(c.cameraFolders.singleWhere((f) => f.name == 'EMPTY'));
      await c.refreshMedia(more: true);
      expect(c.visible, isEmpty);
      expect(c.visibleTotal, 0);
      expect(c.hasMoreVisible, false);
      expect(c.media, hasLength(20));
      expect(ptp.objectReads, reads);
      c.setFolder(null);
      c.setFilter('RAW');
      await c.refreshMedia(more: true);
      expect(c.visibleTotal, 0);
      expect(c.media, hasLength(20));
    },
  );

  test('refresh removes an ejected card and its stale folders', () async {
    final ptp = StoragePtp();
    final c = await fixture(ptp);
    addTearDown(c.dispose);
    ptp.cards = [secondCard];
    await c.refreshMedia();
    expect(c.cameraStorages.single.id, secondCard);
    expect(c.cameraFolders.every((f) => f.storageId == secondCard), true);
  });

  test(
    'dashboard accumulates earlier syncs and current progress without counting a retry twice',
    () async {
      final c = AppController(DemoRepository(delay: Duration.zero));
      addTearDown(c.dispose);
      await c.connect('10.0.2.2');
      await c.startSync(items: c.media.take(1).toList());
      final savedBytes = c.syncedStorageBytes;
      final next = c.media[1];
      c.task = SyncTask([next])
        ..phase = SyncPhase.transferring
        ..currentId = next.id
        ..currentBytes = 100;
      expect(c.syncedStorageBytes, savedBytes + 100);
      c.local.add(next);
      expect(c.syncedStorageBytes, savedBytes + next.bytes);
      c.task = SyncTask([next]);
      expect(c.syncedStorageBytes, savedBytes + next.bytes);
      await c.deleteLocal({next.id});
      expect(c.syncedStorageBytes, savedBytes);
      await c.refreshPhoneStorage();
      expect(c.phoneTotalBytes, 256 * 1073741824);
      expect(c.freeGb, 80);
    },
  );

  testWidgets('empty view count remains zero after scrolling', (tester) async {
    final c = (await tester.runAsync(() => fixture(StoragePtp())))!;
    addTearDown(c.dispose);
    c.setFolder(c.cameraFolders.singleWhere((f) => f.name == 'EMPTY'));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: c,
            builder: (_, _) => MediaPage(c: c, onConnect: () {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('已加载 0 / 0 个媒体'), findsOneWidget);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -700));
    await tester.pumpAndSettle();
    expect(find.text('已加载 0 / 0 个媒体'), findsOneWidget);
    expect(c.media, hasLength(20));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'picker shows real card and distinct section headers at phone width',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = (await tester.runAsync(
        () => fixture(
          StoragePtp()
            ..cards = [secondCard]
            ..emptyFirstSlot = true,
        ),
      ))!;
      addTearDown(c.dispose);
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: appTheme().copyWith(
              textTheme: appTheme().textTheme.apply(fontFamily: 'StorageUi'),
            ),
            home: Scaffold(
              body: Builder(
                builder: (ctx) => TextButton(
                  onPressed: () => showFolderPicker(ctx, c),
                  child: const Text('打开筛选'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开筛选'));
      await tester.pumpAndSettle();
      expect(find.text('卡槽 2'), findsNWidgets(2));
      expect(find.textContaining('卡槽 1'), findsNothing);
      expect(find.textContaining('29.8'), findsNothing);
      final header = tester.widget<Text>(find.text('存储卡'));
      expect(header.style?.fontWeight, FontWeight.w800);
      await capture(tester, key, 'filter');
      await tester.tap(find.text('卡槽 2').first);
      await tester.pumpAndSettle();
      expect(c.storageId, secondCard);
      await tester.ensureVisible(find.text('100NIKON'));
      await tester.tap(find.text('100NIKON'));
      await tester.pumpAndSettle();
      expect(c.folderHandle, 200);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'dashboard displays cumulative media size over available phone storage',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = AppController(DemoRepository(delay: Duration.zero));
      addTearDown(c.dispose);
      await c.connect('10.0.2.2');
      await c.startSync(items: c.media.take(8).toList());
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: appTheme().copyWith(
              textTheme: appTheme().textTheme.apply(fontFamily: 'StorageUi'),
            ),
            home: Scaffold(
              body: HomePage(c: c, onConnect: () {}),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('${formatStorageBytes(c.syncedStorageBytes)} / 80.0 GB'),
        findsOneWidget,
      );
      expect(find.text('同步占用 / 手机可用'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await capture(tester, key, 'dashboard');
      await tester.pumpWidget(const SizedBox());
    },
  );
}
