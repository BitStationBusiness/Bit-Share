import 'windows_download_backend_stub.dart'
    if (dart.library.io) 'windows_download_backend_io.dart'
    as implementation;
import 'windows_download_models.dart';

export 'windows_download_models.dart';

WindowsDownloadBackend createWindowsDownloadBackend() {
  return implementation.createWindowsDownloadBackend();
}
