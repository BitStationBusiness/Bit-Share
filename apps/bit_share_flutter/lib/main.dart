import 'dart:ui';

import 'package:flutter/widgets.dart';

import 'app/bit_share_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final initialRoute = PlatformDispatcher.instance.defaultRouteName;
  runApp(BitShareApp(openedFromShare: initialRoute == '/share'));
}
