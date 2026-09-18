import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirrorbridge/pages/lut_manager_page.dart';
import 'package:mirrorbridge/protocol/ptp.dart';
import 'package:mirrorbridge/repositories/demo_repository.dart';
import 'package:mirrorbridge/state/app_controller.dart';
import 'package:mirrorbridge/pages/settings_pages.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('LUT manager remains reachable and imports a Cube path', (
    tester,
  ) async {
    final controller = AppController(DemoRepository(delay: Duration.zero));
    addTearDown(controller.dispose);
    const selected =
        '/data/user/0/io.github.dearzl.mirrorbridge/files/custom-luts/film.cube';

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeCamera, (call) async {
          if (call.method == 'pick') return selected;
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativeCamera, null),
    );

    await tester.pumpWidget(MaterialApp(home: LutManagerPage(c: controller)));
    expect(find.text('LUT 管理'), findsOneWidget);
    expect(find.text('系统自带 LUT'), findsOneWidget);
    expect(find.text('Warm Tone'), findsOneWidget);

    await tester.drag(find.byType(Scrollable).first, const Offset(0, -220));
    await tester.pump();
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));

    expect(controller.importedLuts, contains(selected));
    expect(find.text('film.cube'), findsOneWidget);
  });

  testWidgets('settings opens the LUT manager page', (tester) async {
    final controller = AppController(DemoRepository(delay: Duration.zero));
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: CameraSettingsPage(c: controller)),
    );
    await tester.scrollUntilVisible(
      find.text('LUT 管理'),
      260,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -180));
    await tester.pumpAndSettle();
    final lutTile = find.ancestor(
      of: find.text('LUT 管理'),
      matching: find.byType(ListTile),
    );
    await tester.tap(lutTile);
    await tester.pumpAndSettle();

    expect(find.text('系统自带 LUT'), findsOneWidget);
    expect(find.text('导入 LUT'), findsOneWidget);
  });

  testWidgets('invalid native LUT import is rejected without saving a path', (
    tester,
  ) async {
    final controller = AppController(DemoRepository(delay: Duration.zero));
    addTearDown(controller.dispose);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeCamera, (call) async {
          throw PlatformException(
            code: 'CAMERA_NATIVE',
            message: 'Cube data must be between 0 and 1',
          );
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativeCamera, null),
    );

    await tester.pumpWidget(MaterialApp(home: LutManagerPage(c: controller)));
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -220));
    await tester.pump();
    await tester.ensureVisible(find.byType(FilledButton));
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));

    expect(controller.importedLuts, isEmpty);
    expect(find.textContaining('LUT 文件无效'), findsOneWidget);
  });
}
