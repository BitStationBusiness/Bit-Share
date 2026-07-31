enum WindowsDownloadMode { audio, video }

enum WindowsBrowserSession {
  edge('Edge', 'edge'),
  chrome('Chrome', 'chrome'),
  firefox('Firefox', 'firefox');

  const WindowsBrowserSession(this.label, this.ytDlpName);

  final String label;
  final String ytDlpName;
}

class WindowsResolution {
  const WindowsResolution({
    required this.height,
    required this.label,
    this.estimatedBytes,
  });

  final int height;
  final String label;
  final int? estimatedBytes;
}

class WindowsMediaInspection {
  const WindowsMediaInspection({
    required this.title,
    required this.providerName,
    required this.audioAvailable,
    required this.resolutions,
    required this.availableBytes,
    this.audioEstimatedBytes,
  });

  final String title;
  final String providerName;
  final bool audioAvailable;
  final List<WindowsResolution> resolutions;
  final int availableBytes;
  final int? audioEstimatedBytes;
}

class WindowsDownloadProgress {
  const WindowsDownloadProgress({required this.percent, required this.stage});

  final double percent;
  final String stage;
}

class WindowsDownloadResult {
  const WindowsDownloadResult({required this.filePath});

  final String filePath;
}

class WindowsDownloadException implements Exception {
  const WindowsDownloadException(
    this.message, {
    this.authenticationRequired = false,
  });

  final String message;
  final bool authenticationRequired;

  @override
  String toString() => message;
}

abstract interface class WindowsDownloadBackend {
  String get outputDirectory;

  Future<WindowsMediaInspection> inspect(
    String url, {
    WindowsBrowserSession? browserSession,
  });

  Future<WindowsDownloadResult> download(
    String url, {
    required WindowsDownloadMode mode,
    required void Function(WindowsDownloadProgress progress) onProgress,
    int? height,
    int? estimatedBytes,
    WindowsBrowserSession? browserSession,
  });

  Future<void> cancel();

  Future<void> openOutputDirectory();

  Future<void> openLoginPage(String url, WindowsBrowserSession browserSession);
}
