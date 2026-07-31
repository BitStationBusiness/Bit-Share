# ADR-0002: PoC de yt-dlp y FFmpeg

Estado: Aceptado para PoC, no para publicación  
Fecha: 2026-07-29

## Contexto

El MVP necesita inspección/descarga autorizada y operaciones de remux, merge y
extracción de audio. En Android, la elección del runtime afecta compatibilidad,
tamaño, mantenimiento, políticas de tienda y supervivencia en segundo plano.

## Decisión

Integrar temporalmente `youtubedl-android` 0.18.1 detrás de
`DownloadCoordinator` para validar Facebook/X con un formato MP4 combinado.
No activar el actualizador interno del wrapper. El runtime base queda incluido
en el APK.

FFmpeg sigue pendiente. El proyecto no usará FFmpegKit oficial porque está
retirado; deberá evaluar un build propio o un fork mantenido, con licencias y
soporte de páginas de 16 KB verificados.

Cada PoC medirá tamaño de APK/AAB, tiempo de inicialización, consumo de memoria,
compatibilidad API 26-36, licencias y estado de mantenimiento.

## Alternativas

Se evaluarán tras obtener resultados reproducibles. No se selecciona un wrapper
solo por popularidad o por conveniencia del prototipo.

## Consecuencias

- El flujo público completo ya puede probarse.
- La dependencia `youtubedl-android` es GPL-3.0; no se aprueba aún como base de
  una distribución cerrada o en Google Play.
- El APK debug incluye Python, yt-dlp y bibliotecas nativas, por lo que su
  tamaño y tiempo de instalación son mayores.
- El emulador produjo una descarga válida y también fallos TLS intermitentes
  tras repeticiones; se requieren pruebas arm64 antes de estabilizar el motor.
- La UI y el dominio permanecen desacoplados de la API concreta del wrapper.

## Validación

- Descarga pública de Facebook completada en emulador x86_64.
- Resultado MP4 H.264/AAC publicado en MediaStore y compartido por URI.
- Cancelación conectada a `destroyProcessById`.
- Temporales eliminados al completar o fallar.

Pendiente: dispositivo arm64, supervivencia al cierre, AAB por ABI, decisión de
licencia, FFmpeg y revisión formal de política de distribución.
