import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import 'update_release.dart';

/// Split of responsibilities, mirroring BitMusic's updater: this class owns
/// the download, the on-disk verification and handing the installer to the
/// OS. Only two things are genuinely platform-specific — where the update
/// file may be written, and how it is finally launched — everything else
/// (streaming, hashing, size and signature checks) is shared.
class UpdateInstaller {
  const UpdateInstaller();

  static const _methods = MethodChannel('bitshare/methods');
  static const _maxBytes = 900 * 1024 * 1024;
  static const _minBytes = 256 * 1024;

  Future<File> download(
    UpdateRelease release, {
    required void Function(int received, int total) onProgress,
  }) async {
    final dir = await _updateDirectory();
    final fileName = Platform.isWindows
        ? 'Bit-Share-Setup.exe'
        : 'Bit-Share.apk';
    final partFile = File('${dir.path}${Platform.pathSeparator}$fileName.part');
    final finalFile = File('${dir.path}${Platform.pathSeparator}$fileName');
    if (await partFile.exists()) await partFile.delete();

    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(release.downloadUrl));
      request.headers.set(HttpHeaders.userAgentHeader, 'Bit-Share-Updater/1.0');
      final response = await request.close();
      if (response.statusCode != 200) {
        await response.drain<void>();
        throw UpdateException(
          'El servidor respondió con un error (${response.statusCode}).',
        );
      }

      final total = release.assetSizeBytes > 0
          ? release.assetSizeBytes
          : (response.contentLength > 0 ? response.contentLength : 0);
      final digestSink = _DigestSink();
      final hashSink = sha256.startChunkedConversion(digestSink);
      final sink = partFile.openWrite();
      var received = 0;
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          hashSink.add(chunk);
          received += chunk.length;
          if (received > _maxBytes) {
            throw const UpdateException(
              'La actualización es demasiado grande.',
            );
          }
          onProgress(received, total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      hashSink.close();

      if (received < _minBytes) {
        throw const UpdateException('El archivo descargado no es válido.');
      }
      await _verifySignature(partFile);
      if (release.sha256 != null) {
        final digest = digestSink.digest.toString();
        if (digest != release.sha256) {
          await partFile.delete();
          throw const UpdateException(
            'La verificación de integridad del archivo falló.',
          );
        }
      }

      if (await finalFile.exists()) await finalFile.delete();
      await partFile.rename(finalFile.path);
      return finalFile;
    } on UpdateException {
      await _deleteQuietly(partFile);
      rethrow;
    } on Object {
      await _deleteQuietly(partFile);
      throw const UpdateException('No se pudo descargar la actualización.');
    } finally {
      client.close(force: true);
    }
  }

  /// Launches the installer/APK. On Windows this never returns on the happy
  /// path: the caller is expected to close the app right after.
  Future<void> apply(File installerFile) async {
    if (Platform.isWindows) {
      await Process.start(installerFile.path, const [
        '/SILENT',
        '/SP-',
        '/NOCANCEL',
        '/NORESTART',
        '/CLOSEAPPLICATIONS',
        '/FORCECLOSEAPPLICATIONS',
      ], mode: ProcessStartMode.detached);
      return;
    }
    if (Platform.isAndroid) {
      try {
        final started = await _methods.invokeMethod<bool>('installApk', {
          'path': installerFile.path,
        });
        if (started != true) {
          throw const UpdateException('No se pudo iniciar la instalación.');
        }
      } on PlatformException catch (error) {
        if (error.code == 'install_permission_required') {
          throw const UpdateException(
            'Activa "Instalar apps desconocidas" para Bit-Share en Ajustes '
            'y vuelve a intentarlo.',
          );
        }
        throw UpdateException(
          error.message ?? 'No se pudo iniciar la instalación.',
        );
      }
      return;
    }
    throw const UpdateException(
      'La actualización no está disponible en esta plataforma.',
    );
  }

  Future<Directory> _updateDirectory() async {
    if (Platform.isAndroid) {
      final path = await _methods.invokeMethod<String>('updateCacheDir');
      if (path == null || path.isEmpty) {
        throw const UpdateException(
          'No se pudo preparar la carpeta de actualización.',
        );
      }
      return Directory(path);
    }
    final dir = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}Bit-Share-Update',
    );
    await dir.create(recursive: true);
    return dir;
  }

  /// Windows installers are PE images ("MZ"); Android packages are zip
  /// archives ("PK\x03\x04"). A corrupt or truncated download, or a server
  /// that answered with an HTML error page instead of the binary, fails
  /// this check instead of being handed to the OS.
  Future<void> _verifySignature(File file) async {
    final handle = await file.open();
    try {
      final header = await handle.read(4);
      final valid = Platform.isWindows
          ? header.length >= 2 && header[0] == 0x4D && header[1] == 0x5A
          : header.length >= 4 &&
                header[0] == 0x50 &&
                header[1] == 0x4B &&
                header[2] == 0x03 &&
                header[3] == 0x04;
      if (!valid) {
        throw const UpdateException(
          'El archivo descargado está dañado o incompleto.',
        );
      }
    } finally {
      await handle.close();
    }
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on Object {
      // Best effort cleanup only.
    }
  }
}

/// Captures the single [Digest] a chunked sha256 conversion produces, so the
/// file can be hashed in the same pass as it is written instead of being
/// read back into memory afterwards.
class _DigestSink implements Sink<Digest> {
  Digest? _digest;

  @override
  void add(Digest data) => _digest = data;

  @override
  void close() {}

  Digest get digest => _digest!;
}
