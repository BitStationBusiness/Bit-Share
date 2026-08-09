import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../features/gallery/gallery_screen.dart';
import '../features/share_receiver/share_receiver_screen.dart';
import '../features/update/update_gate.dart';
import '../features/windows_download/windows_download_screen.dart';
import 'app_strings.dart';

class BitShareApp extends StatelessWidget {
  const BitShareApp({required this.openedFromShare, super.key});

  final bool openedFromShare;

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF9B7BFF);
    final isWindows =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
    final colorScheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.dark,
      surface: const Color(0xFF15121D),
    );

    // Windows gets a denser, mouse-scaled control size instead of the
    // touch-sized defaults Android needs — a 52px-tall button reads as
    // oversized and unpolished next to native desktop chrome.
    final buttonHeight = isWindows ? 40.0 : 52.0;
    final buttonRadius = isWindows ? 10.0 : 16.0;

    return MaterialApp(
      title: AppStrings.appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: const Color(0xFF0E0C13),
        useMaterial3: true,
        visualDensity: isWindows
            ? VisualDensity.compact
            : VisualDensity.standard,
        cardTheme: CardThemeData(
          color: const Color(0xFF1B1724),
          margin: EdgeInsets.zero,
          elevation: isWindows ? 0 : null,
          shape: isWindows
              ? RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: Color(0xFF2A2536)),
                )
              : null,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: Size.fromHeight(buttonHeight),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(buttonRadius),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            minimumSize: Size.fromHeight(buttonHeight),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(buttonRadius),
            ),
          ),
        ),
      ),
      home: openedFromShare
          ? const UpdateGate(child: ShareReceiverScreen())
          : UpdateGate(
              child: isWindows
                  ? WindowsDownloadScreen()
                  : const GalleryScreen(),
            ),
    );
  }
}
