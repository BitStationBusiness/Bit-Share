import 'package:flutter/services.dart';

import '../domain/entities/share_payload.dart';
import '../domain/repositories/share_payload_repository.dart';
import 'bitshare_events.dart';

enum DownloadMode { audio, video }

class ResolutionOption {
  const ResolutionOption({
    required this.height,
    required this.label,
    this.estimatedBytes,
    this.fitsStorage,
  });

  factory ResolutionOption.fromMap(Map<Object?, Object?> map) {
    return ResolutionOption(
      height: (map['height'] as num?)?.toInt() ?? 0,
      label: map['label'] as String? ?? '',
      estimatedBytes: (map['estimatedBytes'] as num?)?.toInt(),
      fitsStorage: map['fitsStorage'] as bool?,
    );
  }

  final int height;
  final String label;
  final int? estimatedBytes;
  final bool? fitsStorage;
}

class MediaInspection {
  const MediaInspection({
    required this.title,
    required this.providerName,
    required this.availableBytes,
    required this.audioAvailable,
    required this.resolutions,
    this.audioEstimatedBytes,
    this.audioFitsStorage,
  });

  factory MediaInspection.fromMap(Map<Object?, Object?> map) {
    final rawResolutions = map['resolutions'];
    return MediaInspection(
      title: map['title'] as String? ?? '',
      providerName: map['providerName'] as String? ?? '',
      availableBytes: (map['availableBytes'] as num?)?.toInt() ?? 0,
      audioAvailable: map['audioAvailable'] as bool? ?? false,
      audioEstimatedBytes: (map['audioEstimatedBytes'] as num?)?.toInt(),
      audioFitsStorage: map['audioFitsStorage'] as bool?,
      resolutions: rawResolutions is List
          ? rawResolutions
                .whereType<Map>()
                .map(
                  (item) => ResolutionOption.fromMap(
                    Map<Object?, Object?>.from(item),
                  ),
                )
                .where((item) => item.height > 0)
                .toList(growable: false)
          : const [],
    );
  }

  final String title;
  final String providerName;
  final int availableBytes;
  final bool audioAvailable;
  final int? audioEstimatedBytes;
  final bool? audioFitsStorage;
  final List<ResolutionOption> resolutions;
}

class BitShareChannel implements SharePayloadRepository {
  BitShareChannel({MethodChannel? methods, EventChannel? events})
    : _methods = methods ?? const MethodChannel('bitshare/methods'),
      _events = events ?? const EventChannel('bitshare/events');

  final MethodChannel _methods;
  final EventChannel _events;

  Future<void> initializeEngine() async {
    try {
      await _methods.invokeMethod<void>('initializeEngine');
    } on MissingPluginException {
      // Windows and Web keep the shared UI but do not implement Android APIs.
    }
  }

  @override
  Future<SharePayload?> getInitialPayload() async {
    try {
      final raw = await _methods.invokeMapMethod<Object?, Object?>(
        'getInitialSharePayload',
      );
      return raw == null ? null : SharePayload.fromMap(raw);
    } on MissingPluginException {
      return null;
    }
  }

  Future<MediaInspection> inspectUrl(String url) async {
    final response = await _methods.invokeMapMethod<Object?, Object?>(
      'inspectUrl',
      {'url': url},
    );
    if (response == null) {
      throw PlatformException(
        code: 'missing_inspection',
        message: 'Android no devolvió opciones de descarga.',
      );
    }
    return MediaInspection.fromMap(response);
  }

  Future<String> startDownload(
    String url, {
    required DownloadMode mode,
    int? height,
    int? estimatedBytes,
  }) async {
    final response = await _methods.invokeMapMethod<Object?, Object?>(
      'startDownload',
      {
        'url': url,
        'mode': mode.name,
        'height': height,
        'estimatedBytes': estimatedBytes,
      },
    );
    final taskId = response?['taskId'] as String?;
    if (taskId == null || taskId.isEmpty) {
      throw PlatformException(
        code: 'missing_task_id',
        message: 'Android no devolvió un identificador de tarea.',
      );
    }
    return taskId;
  }

  Future<bool> cancelDownload(String taskId) async {
    return await _methods.invokeMethod<bool>('cancelDownload', {
          'taskId': taskId,
        }) ??
        false;
  }

  Future<bool> shareResult(String taskId) async {
    return await _methods.invokeMethod<bool>('shareResult', {
          'taskId': taskId,
        }) ??
        false;
  }

  Future<bool> openDonationPage() async {
    return await _methods.invokeMethod<bool>('openDonationPage') ?? false;
  }

  /// Opens the provider's own login page in an in-app WebView and, once the
  /// user confirms they signed in, saves the resulting session cookies for
  /// future downloads from that provider. Returns false if the user
  /// cancelled without logging in.
  Future<bool> openLoginSession(String providerId) async {
    return await _methods.invokeMethod<bool>('openLoginSession', {
          'providerId': providerId,
        }) ??
        false;
  }

  /// Loads [url] in the same in-app WebView used for login and returns
  /// wherever it lands once client-side redirects settle — e.g. Facebook's
  /// `/share/<id>/` links only resolve to their real content URL through a
  /// real browser engine. Returns null if resolution fails or times out, in
  /// which case callers should fall back to the original url.
  Future<String?> resolveShareLink(String url) async {
    return _methods.invokeMethod<String>('resolveShareLink', {'url': url});
  }

  Stream<BitShareEvent> watchEvents() {
    return _events
        .receiveBroadcastStream()
        .where((raw) {
          return raw is Map;
        })
        .map((raw) {
          return BitShareEvent.fromMap(Map<Object?, Object?>.from(raw as Map));
        });
  }

  @override
  Stream<SharePayload> watchPayloads() {
    return watchEvents()
        .where((event) => event is ShareReceivedEvent)
        .cast<ShareReceivedEvent>()
        .map((event) => event.payload);
  }
}
