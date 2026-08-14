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
    this.trackCount = 1,
  });

  final String title;
  final String providerName;
  final bool audioAvailable;
  final List<WindowsResolution> resolutions;
  final int availableBytes;
  final int? audioEstimatedBytes;

  /// 1 for a single video/track. Higher when the link is a playlist or
  /// album: every entry will be downloaded, and estimates above are the
  /// total across all of them.
  final int trackCount;
}

class WindowsDownloadProgress {
  const WindowsDownloadProgress({required this.percent, required this.stage});

  final double percent;
  final String stage;
}

class WindowsDownloadResult {
  const WindowsDownloadResult({required this.filePath, this.fileCount = 1});

  /// First (or only) file written. When [fileCount] is greater than 1 the
  /// rest live alongside it in the same output directory.
  final String filePath;
  final int fileCount;
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

  Future<void> copyFileToClipboard(String filePath);

  Future<void> openLoginPage(String url, WindowsBrowserSession browserSession);
}
