import 'package:bit_share/features/share_receiver/share_receiver_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('extractWebUrl', () {
    test('acepta un enlace web compartido como texto', () {
      expect(
        extractWebUrl(
          'Mira este vídeo: https://www.youtube.com/watch?v=aqz-KE-bpKQ',
        ),
        'https://www.youtube.com/watch?v=aqz-KE-bpKQ',
      );
    });

    test('limpia puntuación final habitual', () {
      expect(
        extractWebUrl('https://media.example.org/video/123).'),
        'https://media.example.org/video/123',
      );
    });

    test('rechaza esquemas no web y credenciales embebidas', () {
      expect(extractWebUrl('file:///data/local/tmp/video.mp4'), isNull);
      expect(extractWebUrl('https://user:secret@example.org/video'), isNull);
    });
  });
}
