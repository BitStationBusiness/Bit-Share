import 'package:bit_share/features/windows_download/windows_download_backend.dart';
import 'package:bit_share/features/windows_download/windows_download_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Ctrl+V analiza, organiza resoluciones y descarga en Windows', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') {
          return <String, dynamic>{
            'text': 'https://www.youtube.com/watch?v=example',
          };
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final backend = _FakeWindowsBackend();

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: WindowsDownloadScreen(backend: backend),
      ),
    );

    expect(find.byKey(const Key('windows-paste-button')), findsNothing);
    expect(find.byKey(const Key('windows-inspect-button')), findsNothing);

    await tester.tap(find.byKey(const Key('windows-url-field')));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(find.text('Vídeo de prueba'), findsOneWidget);
    expect(find.text('1080p'), findsOneWidget);
    expect(find.text('720p'), findsOneWidget);

    await tester.tap(find.byKey(const Key('windows-resolution-720')));
    await tester.tap(find.byKey(const Key('windows-download-button')));
    await tester.pumpAndSettle();

    expect(backend.downloadedHeight, 720);
    expect(find.text('Descarga completada'), findsOneWidget);
    expect(find.text('VÃ­deo de prueba'), findsNothing);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('windows-url-field')))
          .controller
          ?.text,
      isEmpty,
    );

    await tester.tap(find.byKey(const Key('windows-copy-file-button')));
    await tester.pump();
    expect(
      backend.copiedFilePath,
      r'C:\Users\Test\Downloads\Bit-Share\video.mp4',
    );
  });

  testWidgets('solo muestra autenticación cuando el motor la solicita', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final backend = _FakeWindowsBackend(authenticationRequired: true);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: WindowsDownloadScreen(backend: backend),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('windows-url-field')),
      'https://example.com/private',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('windows-auth-retry-button')), findsOneWidget);
    expect(find.textContaining('no recibe tu contraseña'), findsOneWidget);
  });

  testWidgets('un fallo de descarga ofrece reintentar sin re-pegar el enlace', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final backend = _FakeWindowsBackend(failDownloadsUntil: 1);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: WindowsDownloadScreen(backend: backend),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('windows-url-field')),
      'https://www.youtube.com/watch?v=example',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('windows-download-button')));
    await tester.pumpAndSettle();

    expect(find.text('No se pudo conectar con el sitio.'), findsOneWidget);
    expect(find.byKey(const Key('windows-retry-button')), findsOneWidget);
    // The failed attempt doesn't discard the already-known link info.
    expect(find.text('Vídeo de prueba'), findsOneWidget);

    await tester.tap(find.byKey(const Key('windows-retry-button')));
    await tester.pumpAndSettle();

    expect(find.text('Descarga completada'), findsOneWidget);
    expect(backend.downloadAttempts, 2);
  });
}

class _FakeWindowsBackend implements WindowsDownloadBackend {
  _FakeWindowsBackend({
    this.authenticationRequired = false,
    this.failDownloadsUntil = 0,
  });

  final bool authenticationRequired;

  /// Download attempts at or below this count fail with a network-style
  /// error; later attempts succeed. 0 means every attempt succeeds.
  final int failDownloadsUntil;
  int downloadAttempts = 0;
  int? downloadedHeight;
  String? copiedFilePath;

  @override
  String get outputDirectory => r'C:\Users\Test\Downloads\Bit-Share';

  @override
  Future<void> cancel() async {}

  @override
  Future<WindowsDownloadResult> download(
    String url, {
    required WindowsDownloadMode mode,
    required void Function(WindowsDownloadProgress progress) onProgress,
    int? height,
    int? estimatedBytes,
    WindowsBrowserSession? browserSession,
  }) async {
    downloadAttempts += 1;
    if (downloadAttempts <= failDownloadsUntil) {
      throw const WindowsDownloadException('No se pudo conectar con el sitio.');
    }
    downloadedHeight = height;
    onProgress(const WindowsDownloadProgress(percent: 100, stage: 'completed'));
    return const WindowsDownloadResult(
      filePath: r'C:\Users\Test\Downloads\Bit-Share\video.mp4',
    );
  }

  @override
  Future<WindowsMediaInspection> inspect(
    String url, {
    WindowsBrowserSession? browserSession,
  }) async {
    if (authenticationRequired && browserSession == null) {
      throw const WindowsDownloadException(
        'Debes iniciar sesión.',
        authenticationRequired: true,
      );
    }
    return const WindowsMediaInspection(
      title: 'Vídeo de prueba',
      providerName: 'YouTube',
      audioAvailable: true,
      availableBytes: 10 * 1024 * 1024 * 1024,
      audioEstimatedBytes: 4 * 1024 * 1024,
      resolutions: [
        WindowsResolution(
          height: 1080,
          label: '1080p',
          estimatedBytes: 12 * 1024 * 1024,
        ),
        WindowsResolution(
          height: 720,
          label: '720p',
          estimatedBytes: 8 * 1024 * 1024,
        ),
      ],
    );
  }

  @override
  Future<void> openLoginPage(
    String url,
    WindowsBrowserSession browserSession,
  ) async {}

  @override
  Future<void> openOutputDirectory() async {}

  @override
  Future<void> copyFileToClipboard(String filePath) async {
    copiedFilePath = filePath;
  }
}
