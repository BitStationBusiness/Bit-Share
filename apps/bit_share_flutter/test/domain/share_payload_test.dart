import 'package:bit_share/domain/entities/input_kind.dart';
import 'package:bit_share/domain/entities/share_payload.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SharePayload', () {
    test('convierte un payload recibido por MethodChannel', () {
      final payload = SharePayload.fromMap({
        'id': 'payload-1',
        'action': 'android.intent.action.SEND',
        'mimeType': 'text/plain',
        'text': 'https://example.com/video',
        'uris': <String>[],
        'inputKind': 'url',
        'receivedAt': '2026-07-29T20:00:00Z',
      });

      expect(payload.id, 'payload-1');
      expect(payload.inputKind, InputKind.url);
      expect(payload.hasContent, isTrue);
      expect(payload.receivedAt.isUtc, isTrue);
    });

    test('degrada tipos futuros a unknown sin fallar', () {
      final payload = SharePayload.fromMap({
        'id': 'payload-2',
        'action': 'android.intent.action.SEND',
        'uris': ['content://provider/item'],
        'inputKind': 'futureKind',
        'receivedAt': 'invalid',
      });

      expect(payload.inputKind, InputKind.unknown);
      expect(payload.hasContent, isTrue);
    });
  });
}
