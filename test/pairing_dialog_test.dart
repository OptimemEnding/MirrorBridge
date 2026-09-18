import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirrorbridge/models/media_item.dart';
import 'package:mirrorbridge/protocol/ptp.dart';
import 'package:mirrorbridge/pages/nikon_connection_page.dart';
import 'package:mirrorbridge/repositories/nikon_repository.dart';
import 'package:mirrorbridge/state/app_controller.dart';
import 'package:mirrorbridge/theme/app_theme.dart';

class PairingUiFixture extends NikonRepository {
  int cancellations = 0;
  @override
  Future<void> disconnect() async {
    cancellations++;
    awaitingCameraConfirmation = false;
    pairingInProgress = false;
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  late PairingUiFixture repo;
  late AppController controller;
  final boundaryKey = GlobalKey();
  final modal = find.byKey(const ValueKey('camera-confirmation-dialog'));

  setUpAll(() async {
    final font = Platform.environment['PAIRING_FONT'];
    if (font != null) {
      final loader = FontLoader(
        'PairingPreview',
      )..addFont(File(font).readAsBytes().then((b) => ByteData.sublistView(b)));
      await loader.load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });

  setUp(() {
    repo = PairingUiFixture();
    controller = AppController(repo)..mode = 'STA';
    messenger.setMockMethodCallHandler(nativeCamera, (_) async => null);
    messenger.setMockMethodCallHandler(
      AppController.platform,
      (_) async => null,
    );
  });
  tearDown(() => controller.dispose());

  Future<void> mount(WidgetTester tester, Size size, double scale) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: Platform.environment['PAIRING_FONT'] == null
              ? appTheme()
              : appTheme().copyWith(
                  appBarTheme: appTheme().appBarTheme.copyWith(
                    titleTextStyle: appTheme().appBarTheme.titleTextStyle
                        ?.copyWith(fontFamily: 'PairingPreview'),
                  ),
                  textTheme: appTheme().textTheme.apply(
                    fontFamily: 'PairingPreview',
                  ),
                ),
          home: NikonConnectionPage(c: controller),
        ),
      ),
    );
    await tester.pump();
  }

  void waiting() {
    controller.connection = ConnectionPhase.connecting;
    repo.awaitingCameraConfirmation = true;
    repo.pairingInProgress = true;
    repo.onConnectionStage?.call('等待传输');
  }

  testWidgets('pairing modal follows readiness, retries and timeout', (
    tester,
  ) async {
    await mount(tester, const Size(393, 851), 1);
    controller.connection = ConnectionPhase.connecting;
    repo.onConnectionStage?.call('正在握手');
    await tester.pump();
    expect(modal, findsNothing);
    waiting();
    await tester.pump();
    expect(modal, findsOneWidget);
    final spinner = find.descendant(
      of: modal,
      matching: find.byType(CircularProgressIndicator),
    );
    expect(tester.widget<CircularProgressIndicator>(spinner).value, isNull);
    for (var n = 0; n < 3; n++) {
      repo.onConnectionStage?.call('重试 $n');
      await tester.pump(const Duration(milliseconds: 300));
      expect(modal, findsOneWidget);
    }
    await tester.tapAt(const Offset(10, 100));
    await tester.pump();
    expect(modal, findsOneWidget);
    repo.awaitingCameraConfirmation = false;
    repo.onConnectionStage?.call('正在读取存储卡');
    await tester.pump();
    expect(modal, findsOneWidget);
    expect(find.text('请在相机上按 OK／确认键'), findsNothing);
    expect(find.text('正在连接相机'), findsOneWidget);
    repo.onConnectionStage?.call('传输重试');
    await tester.pump();
    expect(find.text('请在相机上按 OK／确认键'), findsNothing);
    controller.connection = ConnectionPhase.connected;
    controller.changed();
    await tester.pump();
    expect(modal, findsNothing);
    waiting();
    await tester.pump();
    controller.connection = ConnectionPhase.failed;
    controller.message = '连接超时';
    controller.changed();
    await tester.pump();
    expect(modal, findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final back in [false, true]) {
    testWidgets(
      'pairing ${back ? 'system back' : 'cancel button'} cancels connection',
      (tester) async {
        waiting();
        await mount(tester, const Size(393, 851), 1);
        if (back) {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(
            find.descendant(of: modal, matching: find.text('取消连接')),
          );
        }
        await tester.pump();
        expect(modal, findsNothing);
        expect(repo.cancellations, 1);
        expect(controller.connection, ConnectionPhase.disconnected);
        expect(find.byType(NikonConnectionPage), findsOneWidget);
      },
    );
  }

  for (final size in [const Size(393, 851), const Size(568, 320)]) {
    testWidgets('pairing dialog fits $size and large text', (tester) async {
      waiting();
      await mount(tester, size, size.width < 500 ? 1 : 1.4);
      await tester.pump(const Duration(milliseconds: 250));
      expect(modal, findsOneWidget);
      expect(find.text('请在相机上按 OK／确认键'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final output = Platform.environment['PAIRING_SCREENSHOT'];
      if (output != null && size.width == 393) {
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(output).writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }
}
