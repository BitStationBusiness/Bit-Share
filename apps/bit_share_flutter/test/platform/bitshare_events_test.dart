import 'package:bit_share/platform/bitshare_events.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('interpreta el recordatorio de donación en una descarga completada', () {
    final event = BitShareEvent.fromMap({
      'type': 'taskCompleted',
      'taskId': 'task-5',
      'fileName': 'video.mp4',
      'contentUri': 'content://downloads/video',
      'mimeType': 'video/mp4',
      'completedDownloadCount': 5,
      'showDonationPrompt': true,
    });

    expect(event, isA<TaskCompletedEvent>());
    final completed = event as TaskCompletedEvent;
    expect(completed.completedDownloadCount, 5);
    expect(completed.showDonationPrompt, isTrue);
  });

  test('el recordatorio es opcional para eventos antiguos', () {
    final event =
        BitShareEvent.fromMap({'type': 'taskCompleted', 'taskId': 'legacy'})
            as TaskCompletedEvent;

    expect(event.completedDownloadCount, 0);
    expect(event.showDonationPrompt, isFalse);
  });
}
