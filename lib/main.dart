import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app.dart';
import 'repositories/nikon_repository.dart';
import 'repositories/demo_repository.dart';
import 'state/app_controller.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  const demo = bool.fromEnvironment('DEMO_MODE');
  final controller = AppController(demo ? DemoRepository() : NikonRepository());
  await controller.load();
  runApp(MirrorBridgeApp(controller: controller));
}
