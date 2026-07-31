# Checkpoint 04 - Windows básico

## Alcance

Primera versión funcional de escritorio sin modificar la experiencia Android:

- pegar un enlace desde el portapapeles;
- inspeccionar título, proveedor, audio y resoluciones;
- elegir vídeo o solo audio;
- lista ordenada de resoluciones y tamaños estimados;
- comprobar espacio libre sin imponer límite de descarga;
- progreso, cancelación y acceso a la carpeta final;
- autenticación opcional con Edge, Chrome o Firefox solo después de
  `AUTH_REQUIRED`.

## Runtime

El paquete incluye yt-dlp 2026.07.04, FFmpeg 8.1.2 y Deno 2.9.4. CMake copia
los binarios junto a `bit_share.exe`. El script de preparación descarga y
verifica cada componente antes de usarlo.

## Validación

- `flutter analyze`: sin incidencias.
- `flutter test`: 12 pruebas superadas.
- `flutter build windows --release`: correcto.
- Prueba visual del release: correcta.
- YouTube de regresión:
  - título: `el tiangis | bebos #54`;
  - resoluciones: 1080p, 720p, 480p, 360p, 240p y 144p;
  - descarga 1080p finalizada desde la propia interfaz.

## Seguridad de la sesión

Bit-Share no pide ni almacena contraseñas. Ante un recurso autenticado abre el
navegador elegido por el usuario y solo reutiliza su sesión local después de
un reintento explícito. La disponibilidad continúa dependiendo del proveedor,
los permisos de la cuenta y la ausencia de DRM.
