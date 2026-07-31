import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../features/home/home_screen.dart';
import '../features/share_receiver/share_receiver_screen.dart';
import '../features/windows_download/windows_download_screen.dart';
import 'app_strings.dart';

class BitShareApp extends StatelessWidget {
  const BitShareApp({required this.openedFromShare, super.key});

  final bool openedFromShare;

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF9B7BFF);
    final colorScheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.dark,
      surface: const Color(0xFF15121D),
    );

    return MaterialApp(
      title: AppStrings.appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: const Color(0xFF0E0C13),
        useMaterial3: true,
        cardTheme: const CardThemeData(
          color: Color(0xFF1B1724),
          margin: EdgeInsets.zero,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
      ),
      home: openedFromShare
          ? const ShareReceiverScreen()
          : !kIsWeb && defaultTargetPlatform == TargetPlatform.windows
          ? WindowsDownloadScreen()
          : const HomeScreen(),
    );
  }
}
