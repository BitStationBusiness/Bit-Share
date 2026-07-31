import '../domain/entities/share_payload.dart';

sealed class BitShareEvent {
  const BitShareEvent();

  factory BitShareEvent.fromMap(Map<Object?, Object?> map) {
    switch (map['type']) {
      case 'shareReceived':
        final payload = map['payload'];
        if (payload is Map) {
          return ShareReceivedEvent(
            SharePayload.fromMap(Map<Object?, Object?>.from(payload)),
          );
        }
      case 'downloadProgress':
        return DownloadProgressEvent(
          taskId: map['taskId'] as String? ?? '',
          progress: (map['progress'] as num?)?.toDouble() ?? 0,
          etaSeconds: (map['etaSeconds'] as num?)?.toInt(),
          stage: map['stage'] as String? ?? 'downloading',
          providerName: map['providerName'] as String?,
        );
      case 'taskCompleted':
        return TaskCompletedEvent(
          taskId: map['taskId'] as String? ?? '',
          fileName: map['fileName'] as String? ?? '',
          contentUri: map['contentUri'] as String? ?? '',
          mimeType: map['mimeType'] as String? ?? 'application/octet-stream',
          completedDownloadCount:
              (map['completedDownloadCount'] as num?)?.toInt() ?? 0,
          showDonationPrompt: map['showDonationPrompt'] as bool? ?? false,
        );
      case 'taskFailed':
        return TaskFailedEvent(
          taskId: map['taskId'] as String? ?? '',
          code: map['code'] as String? ?? 'unknown',
          message:
              map['message'] as String? ?? 'No se pudo completar la tarea.',
        );
      case 'taskCancelled':
        return TaskCancelledEvent(map['taskId'] as String? ?? '');
      default:
        break;
    }
    return const UnknownBitShareEvent();
  }
}

final class ShareReceivedEvent extends BitShareEvent {
  const ShareReceivedEvent(this.payload);

  final SharePayload payload;
}

final class UnknownBitShareEvent extends BitShareEvent {
  const UnknownBitShareEvent();
}

final class DownloadProgressEvent extends BitShareEvent {
  const DownloadProgressEvent({
    required this.taskId,
    required this.progress,
    required this.stage,
    this.etaSeconds,
    this.providerName,
  });

  final String taskId;
  final double progress;
  final int? etaSeconds;
  final String stage;
  final String? providerName;
}

final class TaskCompletedEvent extends BitShareEvent {
  const TaskCompletedEvent({
    required this.taskId,
    required this.fileName,
    required this.contentUri,
    required this.mimeType,
    this.completedDownloadCount = 0,
    this.showDonationPrompt = false,
  });

  final String taskId;
  final String fileName;
  final String contentUri;
  final String mimeType;
  final int completedDownloadCount;
  final bool showDonationPrompt;
}

final class TaskFailedEvent extends BitShareEvent {
  const TaskFailedEvent({
    required this.taskId,
    required this.code,
    required this.message,
  });

  final String taskId;
  final String code;
  final String message;
}

final class TaskCancelledEvent extends BitShareEvent {
  const TaskCancelledEvent(this.taskId);

  final String taskId;
}
