# CHECKPOINT 03 - Web público, formatos y descarga

Fecha: 30 de julio de 2026

## Objetivo

Aceptar enlaces públicos HTTP/HTTPS de sitios compatibles con yt-dlp, abrir
directamente las opciones disponibles y permitir elegir audio o vídeo con las
resoluciones que realmente expone cada enlace.

## Implementación

- Registro abierto para cualquier host web público, con nombres amigables para
  Facebook, X, YouTube, Instagram, TikTok, Vimeo y Reddit.
- Rechazo de esquemas no web, credenciales embebidas, `localhost`, sufijos
  locales y direcciones IP privadas, loopback, link-local o multicast.
- Extracción de la primera URL HTTP/HTTPS desde el texto compartido.
- Inspección automática al recibir el enlace: no existe una pantalla
  intermedia con un único botón.
- Panel reducido a cerrar, selector Audio/Vídeo, resolución, tamaño estimado y
  la acción final de descarga.
- Pie `powered by BitStation` con Press Start 2P. Se retiró el título superior
  `Bit-Share` para no duplicar información.
- Sin actividad `MAIN/LAUNCHER`: Bit-Share no aparece en el cajón de
  aplicaciones y se abre exclusivamente desde el menú Compartir. Sigue
  disponible en Ajustes > Aplicaciones para consultar información o
  desinstalarla.
- Consulta previa de metadatos y formatos mediante yt-dlp.
- Motor Android basado en CPython 3.13, yt-dlp `2026.07.04` y curl-cffi
  `0.15.0`, con impersonación TLS de Chrome sin leer cookies de Chrome.
- Selector `Audio` / `Vídeo`.
- Resoluciones reales en una lista desplegable, ordenadas de mayor a menor y
  acompañadas por su tamaño estimado.
- Selección inicial de la mayor resolución disponible hasta 1080p; el usuario
  puede elegir calidades superiores si el enlace las ofrece.
- Audio M4A y unión de pistas de vídeo/audio mediante FFmpeg 7.1.1.
- Sin límite artificial de tamaño de descarga.
- Comprobación de espacio libre antes de empezar. Se reserva margen para los
  archivos temporales y la unión; si el tamaño no está disponible, se informa
  y la descarga puede continuar.
- Versiones del motor fijadas dentro del APK para que el build sea reproducible.
  yt-dlp y las dependencias nativas se actualizan publicando un APK firmado
  nuevo; no se ejecuta código Python descargado dinámicamente.
- Contador local de descargas publicadas correctamente. Cada cinco descargas
  muestra un agradecimiento opcional con acceso a Ko-fi; omitirlo no limita ni
  interrumpe las descargas.
- APK Android ARM64 para este checkpoint físico.

## Validación física

Dispositivo: HONOR LLY-NX1, Android 16/API 36, ARM64.

- Android no resolvió ninguna actividad de lanzador para el paquete y sí
  resolvió `ShareReceiverActivity` para `ACTION_SEND text/plain`.
- La release abrió automáticamente las opciones Audio/Vídeo y Resolución, sin
  título superior, y conservó `powered by BitStation` en el pie.
- El enlace `viewkey=ph5dac7f7b0bbdd`, compartido desde Chrome, se inspeccionó
  en la release física y mostró `1080p`, `720p`, `480p` y `240p`.
- URL pública de YouTube recibida por `ACTION_SEND`.
- Vídeo de prueba 4K inspeccionado sin descargarlo: se mostraron `2160p`,
  `1440p`, `1080p`, `720p`, `480p`, `360p`, `240p` y `144p`.
- `1080p` quedó seleccionada por defecto y se mostró una estimación de
  275,0 MB.
- El enlace reportado por el usuario, que fallaba solo en release, quedó
  corregido preservando los modelos reflectivos de yt-dlp frente a R8. La
  release final mostró `1080p`, `720p`, `480p`, `360p`, `240p` y `144p`;
  no se inició la descarga del largometraje.
- Vídeo corto descargado con formatos `395+140`, unido con FFmpeg y publicado
  como MP4 de 533.915 bytes (`video/mp4`).
- El mismo vídeo se descargó en modo audio como M4A de 309.156 bytes
  (`audio/mp4`).
- Después de integrar curl-cffi se repitió el flujo con la release optimizada:
  inspección automática y descarga/merge/publicación de un vídeo público corto
  terminaron correctamente.
- Se corrigió una dependencia oculta de instalaciones anteriores: FFmpeg
  requiere bibliotecas compartidas incluidas en el paquete Python de
  youtubedl-android. El coordinador inicializa ambos paquetes antes de exponer
  los ejecutables y verifica `libexpat.so.1`. Desde una instalación limpia, el
  enlace `hRE80Qn1NNc` se descargó a 1080p, se unió y se publicó como MP4 de
  7.380.126 bytes.
- El MP4 final se abrió y reprodujo en el teléfono.
- Motor efectivo fijado en yt-dlp `2026.07.04` y curl-cffi `0.15.0`.
- Ninguna cookie, cuenta o sesión de YouTube fue reutilizada.

Evidencia:

- [hoja compacta](evidence/physical-generic-web-compact.png);
- [opciones automáticas y marca final](evidence/physical-auto-options-branding.png);
- [lista ordenada de resoluciones](evidence/physical-download-options.png);
- [descarga completada](evidence/physical-youtube-download-success.png);
- [reproducción del MP4](evidence/physical-youtube-playback.png).

## Alcance real

“Compatible con cualquier plataforma web” significa que Bit-Share no bloquea
dominios públicos antes de consultar el extractor. El resultado depende de que
el sitio y el enlace estén soportados, sean públicos, no usen DRM y sigan
exponiendo formatos descargables. No existe garantía técnica de compatibilidad
universal.

YouTube cambia sus requisitos con frecuencia y puede exigir Proof of Origin
tokens para algunos formatos o vídeos. Bit-Share no reutiliza cookies ni genera
tokens ligados a cuentas.

El sitio de la prueba exigió impersonación TLS de navegador. Bit-Share ahora la
realiza localmente con curl-cffi y el enlace reportado se pudo inspeccionar en
el dispositivo, sin reutilizar cookies ni sesiones de Chrome. Esto no evade
DRM, sesiones privadas, cuentas, controles de acceso ni restricciones del
proveedor.

No hay actualización de código en caliente. yt-dlp, curl-cffi, FFmpeg,
Chaquopy, Flutter, Kotlin y las demás dependencias se actualizan mediante un
APK nuevo y firmado. Esta decisión evita ejecutar dependencias modificadas sin
haberlas probado y firmado juntas.

## Pendiente antes de distribución

- Revisar GPL-3.0 del wrapper y obligaciones del build de FFmpeg.
- Automatizar builds firmados y pruebas de regresión al actualizar yt-dlp o
  curl-cffi.
- Persistir tareas en WorkManager o un foreground service.
- Ampliar la matriz a otras versiones y arquitecturas Android.
