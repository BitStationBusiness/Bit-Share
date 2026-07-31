import 'package:bit_share/platform/bitshare_channel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('conserva las resoluciones ordenadas informadas por Android', () {
    final inspection = MediaInspection.fromMap({
      'title': 'Vídeo de prueba',
      'providerName': 'YouTube',
      'availableBytes': 2_000_000_000,
      'audioAvailable': true,
      'audioEstimatedBytes': 8_000_000,
      'audioFitsStorage': true,
      'resolutions': [
        {
          'height': 1080,
          'label': '1080p',
          'estimatedBytes': 275_000_000,
          'fitsStorage': true,
        },
        {
          'height': 720,
          'label': '720p',
          'estimatedBytes': 120_000_000,
          'fitsStorage': true,
        },
      ],
    });

    expect(inspection.providerName, 'YouTube');
    expect(inspection.audioAvailable, isTrue);
    expect(inspection.resolutions.map((item) => item.height), [1080, 720]);
    expect(inspection.resolutions.first.estimatedBytes, 275_000_000);
    expect(inspection.resolutions.first.fitsStorage, isTrue);
  });

  test('ignora entradas sin una altura válida', () {
    final inspection = MediaInspection.fromMap({
      'resolutions': [
        {'height': 0, 'label': 'desconocida'},
        {'height': 480, 'label': '480p'},
      ],
    });

    expect(inspection.resolutions, hasLength(1));
    expect(inspection.resolutions.single.height, 480);
  });
}
