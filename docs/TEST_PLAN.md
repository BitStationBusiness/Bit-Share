# Plan de pruebas

## Windows - enlaces

- Ejecutar el release desde otra carpeta sin yt-dlp, FFmpeg ni Deno globales.
- Pegar un enlace válido y comprobar que el análisis comienza automáticamente.
- Mostrar todas las alturas únicas, ordenadas de mayor a menor.
- Seleccionar vídeo o solo audio y comprobar el tamaño estimado.
- Avisar si el espacio no cubre el archivo y sus temporales, sin establecer un
  límite artificial.
- Descargar en 1080p, unir vídeo y audio y validar el archivo con ffprobe.
- Cancelar y comprobar que termina también el árbol de procesos FFmpeg.
- Confirmar que la sesión de navegador no aparece para contenido público.
- Simular `AUTH_REQUIRED`, elegir Edge/Chrome/Firefox y mostrar el reintento
  explícito sin pedir contraseña dentro de Bit-Share.

Regresión real:

```text
https://youtu.be/hRE80Qn1NNc?is=js2y9uySGvU-hG5s
```

Debe ofrecer 1080p, 720p, 480p, 360p, 240p y 144p y completar la descarga
1080p con audio.

## Checkpoint 3

- Dart: extracción defensiva de URL desde texto compartido y parseo de las
  opciones de formato recibidas desde Android.
- Kotlin: hosts públicos genéricos, proveedores conocidos y rechazo de
  localhost, redes privadas e IPv6 loopback.
- UI física: al compartir un enlace se inspecciona automáticamente y se
  muestran directamente Audio/Vídeo, Resolución y Descargar.
- Marca: no existe título `Bit-Share` en la parte superior y el pie conserva
  `powered by BitStation` con Press Start 2P.
- Integración Android: el paquete no publica `MAIN/LAUNCHER`, pero mantiene
  `ShareReceiverActivity` como destino de `ACTION_SEND`.
- Formatos: selector Audio/Vídeo y lista de resoluciones ordenada de mayor a
  menor, con estimaciones de tamaño.
- Almacenamiento: no existe una cuota de aplicación; solo se impide iniciar
  cuando la estimación y el margen temporal superan el espacio libre.
- E2E físico: motor CPython/curl-cffi integrado, descarga separada de vídeo y
  audio desde YouTube, merge FFmpeg, publicación en MediaStore y reproducción.
- Regresión de instalación limpia: desinstalar Bit-Share antes de instalar el
  APK bajo prueba. La primera descarga debe inicializar tanto el paquete Python
  de youtubedl-android como FFmpeg; `libexpat.so.1` debe existir antes de
  ejecutar el merge. Esta prueba evita depender de archivos conservados por una
  instalación anterior.
- Regresión: el selector de vídeo exige `vcodec`; audio solo no cuenta como
  vídeo completado.
- Regresión release/R8: se conservan los métodos del callback invocados desde
  Python para que la descarga optimizada informe progreso y cancelación.
- Donación: el contador solo avanza después de publicar correctamente el
  archivo; solicita apoyo en 5, 10, 15... y nunca bloquea la descarga.
- Impersonación TLS: el enlace reportado desde Chrome muestra en el HONOR
  físico `1080p`, `720p`, `480p` y `240p`, sin cookies compartidas.

## Resultado automatizado actual

- `flutter analyze`: sin incidencias.
- `flutter test`: 10 pruebas superadas.
- `gradlew testReleaseUnitTest`: superado con JDK 21.
- Build release ARM64: superado.
- E2E release en HONOR Android 16: inspección del enlace reportado y descarga,
  merge FFmpeg y publicación de un vídeo público corto superados.

## Prueba manual Android

1. Instalar el APK ARM64 en un dispositivo API 26 o superior.
   Para una prueba de release, desinstalar primero la versión anterior.
2. Confirmar que Bit-Share no aparece en el cajón de aplicaciones y sí en
   Ajustes > Aplicaciones.
3. Compartir una URL pública y elegir Bit-Share.
4. Confirmar que las opciones aparecen automáticamente.
5. Alternar entre Audio y Vídeo.
6. Abrir `Resolución` y confirmar que las opciones coinciden con el enlace.
7. Elegir una calidad, comprobar la estimación y descargar.
8. Confirmar el resultado en Descargas y reproducirlo.
9. Repetir con una URL no compatible, contenido privado, red desconectada y
   almacenamiento insuficiente.
10. Confirmar que cancelar no publica archivos parciales.
11. Al completar la quinta descarga, comprobar que el diálogo de donación
    permite `Ahora no` o abrir Ko-fi.
12. Desde una instalación limpia, compartir
    `https://youtu.be/hRE80Qn1NNc?is=js2y9uySGvU-hG5s`, elegir vídeo 1080p y
    confirmar descarga, merge y publicación. Este caso necesita dos pistas y
    detecta un runtime FFmpeg incompleto.

## Matriz futura

Android 10, 12, 14, 15 y 16; revisar Android 17 antes de publicar. Añadir pérdida
de red, falta de espacio, reinicio y otras arquitecturas.
