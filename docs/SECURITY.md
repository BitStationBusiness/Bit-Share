# Seguridad

## Frontera obligatoria

Bit-Share solo procesa datos entregados explícitamente mediante un Intent,
OAuth/API oficial o una sesión propia permitida. No lee cookies, tokens, bases
de datos ni caché privada de otras aplicaciones. No usa root, Shizuku,
Accessibility Service, hooking ni evasión de DRM.

## Controles del receptor y descarga

- Solo `ACTION_SEND` y `ACTION_SEND_MULTIPLE`.
- MIME permitido: `text/plain`, `image/*`, `audio/*` y `video/*`.
- Máximo 20 URI y 100.000 caracteres de texto por Intent.
- Solo URI con esquema `content://`; nunca se resuelven rutas reales.
- La Activity exportada trata cada campo como entrada no confiable.
- Tráfico HTTP en claro y copias de seguridad Android deshabilitados.
- Solo URLs HTTP/HTTPS públicas, sin credenciales embebidas.
- Bloqueo de `localhost`, sufijos locales e IP privadas, loopback, link-local o
  multicast.
- El selector de vídeo exige una pista con `vcodec`.
- No se reutilizan cookies ni sesiones de otras apps.
- No existe un límite artificial de descarga; se comprueba el espacio libre con
  margen para archivos temporales antes de iniciar.
- Diagnóstico saneado: se eliminan URLs y patrones de credenciales.

## Pendiente antes de distribución

- Nombres de archivo y metadatos con pruebas negativas adicionales.
- Persistencia segura de tareas y cancelación tras reinicio.
- Threat model completo.
- Sustituir la actualización estable directa del PoC por artefactos fijados,
  firma, hash, rollback y auditoría de cadena de suministro.

## Windows

- yt-dlp se ejecuta directamente, nunca mediante `cmd.exe`, y cada argumento
  se entrega por separado.
- Solo se aceptan enlaces HTTP/HTTPS sin credenciales embebidas.
- Los archivos finales deben permanecer dentro de `Downloads/Bit-Share`.
- No se registran URLs completas, cookies, cabeceras ni contraseñas.
- La sesión del navegador permanece desactivada para contenido público.
- Si el sitio exige autenticación, el usuario elige explícitamente un navegador
  y reintenta. Bit-Share no presenta ni captura el formulario de contraseña.
- No se copian cookies a servidores ni se intenta eludir DRM, paywalls o
  controles de acceso.
- La comprobación de espacio impide iniciar una opción que no quepa, pero no
  impone un límite artificial de tamaño.
