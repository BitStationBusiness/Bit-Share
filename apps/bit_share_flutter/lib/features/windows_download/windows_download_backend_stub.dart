import 'windows_download_models.dart';

WindowsDownloadBackend createWindowsDownloadBackend() {
  return const _UnsupportedWindowsDownloadBackend();
}

class _UnsupportedWindowsDownloadBackend implements WindowsDownloadBackend {
  const _UnsupportedWindowsDownloadBackend();

  Never _unsupported() {
    throw const WindowsDownloadException(
      'El motor de escritorio solo está disponible en Windows.',
    );
  }

  @override
  String get outputDirectory => '';

  @override
  Future<void> cancel() async => _unsupported();

  @override
  Future<WindowsDownloadResult> download(
    String url, {
    required WindowsDownloadMode mode,
    required void Function(WindowsDownloadProgress progress) onProgress,
    int? height,
    int? estimatedBytes,
    WindowsBrowserSession? browserSession,
  }) async => _unsupported();

  @override
  Future<WindowsMediaInspection> inspect(
    String url, {
    WindowsBrowserSession? browserSession,
  }) async => _unsupported();

  @override
  Future<void> openLoginPage(
    String url,
    WindowsBrowserSession browserSession,
  ) async => _unsupported();

  @override
  Future<void> openOutputDirectory() async => _unsupported();
}
