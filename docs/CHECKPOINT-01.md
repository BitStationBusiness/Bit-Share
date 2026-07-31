# CHECKPOINT 01 - Entorno y receptor Android

Fecha: 29 de julio de 2026

## Falla

- El repositorio solo contenía el PDF y no existía un proyecto Flutter.
- La primera ejecución de análisis detectó un encadenado de `Stream` no válido;
  se sustituyó por filtrado y `cast` tipado.
- `gradlew` directo tomó Java 25 del sistema. Se fijó el JDK 21 de Android
  Studio, que es el mismo que usa Flutter.

## Mejora

- Creado un proyecto Flutter con Android, Web y Windows.
- Android usa `com.bitstation.bitshare`, API mínima 26 y objetivo 36.
- Implementado `ShareReceiverActivity` translúcido para `ACTION_SEND` y
  `ACTION_SEND_MULTIPLE`.
- Validación inicial de acción, MIME, texto, número de elementos y URI
  `content://`.
- Implementados `bitshare/methods`, `bitshare/events`, modelos Dart y shell
  visual oscuro.
- Añadidos documentación, ADR, pruebas Dart/Kotlin y mapa de código.

## Resumen

Interfaces creadas:

- `SharePayloadRepository`
- `ReceiveSharedContent`
- `BitShareChannel`
- `BitSharePlugin`

Dependencias agregadas:

- JUnit 4.13.2 solo para pruebas Kotlin.
- No se añadieron dependencias de runtime.

## Verificación

- `flutter doctor -v`: sin incidencias.
- `dart format lib test`: sin cambios pendientes.
- `flutter analyze`: sin incidencias.
- `flutter test`: 3 pruebas superadas.
- `gradlew test` con JDK 21: superado.
- `flutter build apk --debug`: superado.
- `flutter build web`: superado.
- `flutter build windows`: superado.
- Prueba en emulador Android 16/API 36.1: instalación correcta,
  `ShareReceiverActivity` abrió desde un Intent `text/plain`, mostró el dato
  recibido y no produjo excepciones en Logcat.

Evidencia visual:
[receptor Android en el emulador](evidence/android-share-receiver.png).

Validación adicional aportada desde un dispositivo físico:
[Facebook compartiendo con Bit-Share](evidence/physical-facebook-share.png).

Artefacto Android:

- `build/app/outputs/flutter-apk/app-debug.apk`
- tamaño: 144.551.316 bytes (debug, múltiples ABI)
- SHA-256:
  `5CBB3A1AF388AE7B2010798410C1E8D545AFE249819F08798092D52DE23D137B`

## Recomendaciones

El siguiente bloque mínimo es la Fase 0 de runtimes: PoC medido de yt-dlp y
FFmpeg en arm64, ADR de selección, licencia y presupuesto de tamaño. Después,
implementar `ProviderRegistry` y el adaptador genérico sin acoplar la UI al
motor.

La recepción de imagen, audio, vídeo y selección múltiple aún requiere prueba
manual en un dispositivo arm64 real.

## Feedback

Antes de avanzar al motor de descarga, confirmar en un dispositivo Android que
Bit-Share aparece en Compartir para texto y vídeo, y que la hoja compacta abre
correctamente.
