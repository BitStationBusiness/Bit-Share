import 'package:bit_share/features/windows_download/windows_download_backend.dart';
import 'package:bit_share/features/windows_download/windows_download_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('analiza, organiza resoluciones y descarga en Windows', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final backend = _FakeWindowsBackend();

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
    await tester.tap(find.byKey(const Key('windows-inspect-button')));
    await tester.pumpAndSettle();

    expect(find.text('Vídeo de prueba'), findsOneWidget);
    expect(find.text('1080p'), findsOneWidget);
    expect(find.text('720p'), findsOneWidget);

    await tester.tap(find.byKey(const Key('windows-resolution-720')));
    await tester.tap(find.byKey(const Key('windows-download-button')));
    await tester.pumpAndSettle();

    expect(backend.downloadedHeight, 720);
    expect(find.text('Descarga completada'), findsOneWidget);
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
    await tester.tap(find.byKey(const Key('windows-inspect-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('windows-auth-retry-button')), findsOneWidget);
    expect(find.textContaining('no recibe tu contraseña'), findsOneWidget);
  });
}

class _FakeWindowsBackend implements WindowsDownloadBackend {
  _FakeWindowsBackend({this.authenticationRequired = false});

  final bool authenticationRequired;
  int? downloadedHeight;

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
}
