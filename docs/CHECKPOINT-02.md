# CHECKPOINT 02 - Descarga pública e icono provisional

Fecha: 30 de julio de 2026

## Falla

- La interfaz indicaba que la descarga pertenecía al siguiente checkpoint.
- No existían motor, progreso, cancelación, MediaStore ni acción de reenvío.
- Las repeticiones del enlace de Facebook en el emulador mostraron fallos TLS
  intermitentes del runtime embebido después de una descarga correcta.
- La primera inicialización de la APK release en ARM64 cerraba el proceso con
  `ExceptionInInitializerError`: R8 retiraba el constructor reflectivo de
  `AsiExtraField`, usado por Apache Commons Compress.

## Mejora

- Integrado `youtubedl-android` 0.18.1 como PoC detrás de una abstracción Kotlin.
- Lista permitida inicial para Facebook, `fb.watch`, X y Twitter.
- Formato combinado `best[ext=mp4]/best`, sin FFmpeg.
- Progreso, ETA, cancelación, errores accionables y reintento desde la UI.
- Publicación mediante MediaStore en `Descargas/Bit-Share`.
- Reenvío mediante URI segura y Android Sharesheet.
- Reintentos de red y timeout configurados.
- Icono provisional morado/oscuro generado e instalado en los mipmaps Android.
- Regla R8 basada en `ZipExtraField` para conservar las implementaciones
  concretas y sus constructores sin desactivar la optimización general.
- Barrera de `Throwable`, código técnico saneado y registro privado únicamente
  en compilaciones depurables para que una dependencia no cierre la aplicación.

## Verificación

- `dart format`: superado.
- `flutter analyze`: sin incidencias.
- `flutter test`: 3 pruebas superadas.
- `gradlew test`: pruebas Kotlin superadas, incluido `ProviderRegistry`.
- `flutter build apk --debug`: superado.
- `flutter build apk --release --target-platform android-arm64`: superado.
- Emulador Android 16/API 36.1:
  - enlace de Facebook recibido como URL;
  - descarga completada;
  - resultado publicado en MediaStore;
  - Android Sharesheet abierto con un archivo;
  - temporales eliminados.
- HONOR LLY-NX1 físico, Android 16/API 36, ARM64:
  - instalación de la APK release;
  - datos privados borrados para simular el primer arranque;
  - enlace de Facebook recibido mediante `ACTION_SEND`;
  - descarga completada sin cierre del proceso;
  - resultado indexado por MediaStore como `video/mp4`;
  - reproducción real abierta en el teléfono.

Resultado inspeccionado con `ffprobe`:

| Campo | Valor |
| --- | --- |
| Archivo | `917905357373013.mp4` |
| Tamaño | 5.335.218 bytes |
| Duración | 43,188 s |
| Vídeo | H.264, 720x1280 |
| Audio | AAC |

APK debug:

- tamaño: 118.433.587 bytes;
- SHA-256:
  `793CD74D4B263581CD0264C437B8A74D136FCAE1141CB51D41BB4F71D9AABFBF`.

APK release ARM64 instalada y validada:

- tamaño: 52.772.317 bytes;
- firma APK v2 verificada;
- alineación de 16 KiB verificada;
- SHA-256:
  `228836F01A7968F767722F03885118DC68AB5187B78BE1FE84914D7DCD29CAB9`.

Evidencia:

- [resultado guardado en el emulador](evidence/emulator-facebook-download-success.png);
- [resultado release en el teléfono físico](evidence/physical-facebook-download-release.png);
- [reproducción del MP4 en el teléfono](evidence/physical-facebook-playback.png).

## Riesgos

- El wrapper y su código están bajo GPL-3.0.
- No se ha aprobado su uso para una edición Google Play.
- El runtime TLS del emulador falló de forma intermitente en repeticiones; la
  primera descarga produjo un archivo válido y las siguientes pueden requerir
  reintento.
- El trabajo no sobrevive todavía al cierre del proceso Flutter.
- No hay selector de calidad ni unión de pistas.
- La validación física cubre Android 16/ARM64; aún faltan versiones Android
  anteriores de la matriz.

## Recomendación

El siguiente checkpoint debe mover la tarea a WorkManager/foreground service,
persistir el estado y ampliar la matriz física. En paralelo debe decidirse si el
producto aceptará GPL-3.0 o necesita un runtime propio con otra estrategia de
licenciamiento.
