# Dependencias de terceros evaluadas

## youtubedl-android 0.18.1

- Coordenadas:
  - `io.github.junkfood02.youtubedl-android:library:0.18.1`
  - `io.github.junkfood02.youtubedl-android:ffmpeg:0.18.1`
- Uso: PoC Android de yt-dlp/Python, QuickJS y merge FFmpeg.
- Licencia declarada por el repositorio: GPL-3.0.
- Estado: aceptada solo para prototipo interno.

Antes de distribuir, BitStation debe revisar obligaciones de código fuente,
avisos, compatibilidad con la licencia del producto y políticas de las
plataformas cuyos enlaces se procesan.

## yt-dlp

La release integra `2026.08.19` dentro del APK mediante Chaquopy. No existe
actualización de código en caliente: la versión efectiva debe registrarse,
probarse y firmarse en cada APK.

## Chaquopy y CPython

- Chaquopy `17.0.0`: SDK de Python para Android, licencia MIT.
- CPython `3.13`: licencia PSF-2.0.
- Uso: ejecutar localmente el puente mínimo de yt-dlp dentro del proceso
  Android.

## curl-cffi y soporte FFI

- curl-cffi `0.15.0`: licencia MIT.
- cffi `1.17.1`: licencia MIT.
- chaquopy-libffi `3.3`: biblioteca libffi para Android.
- pycparser `2.22`: licencia BSD-3-Clause.
- certifi `2026.07.22`: licencia MPL-2.0.
- Uso: transporte TLS con huella de navegador para los sitios que rechazan
  clientes HTTP convencionales.

La compatibilidad Android usa el wheel ARM64 público de curl-cffi y el backend
cffi disponible para Chaquopy. Esta combinación quedó validada en el HONOR
LLY-NX1, pero debe repetirse la prueba al cambiar cualquiera de sus versiones.

## FFmpeg

Incluido mediante el módulo del mismo wrapper para merge de pistas. La prueba
física informó FFmpeg `7.1.1`. Antes de distribuir deben registrarse sus flags
de compilación, bibliotecas externas, avisos y obligaciones LGPL/GPL concretas.

## Press Start 2P

- Fuente: Google Fonts.
- Archivo integrado: `apps/bit_share_flutter/assets/fonts/PressStart2P-Regular.ttf`.
- Licencia: SIL Open Font License 1.1.
- Aviso incluido: `apps/bit_share_flutter/assets/fonts/OFL.txt`.

## Runtime Windows

- yt-dlp `2026.08.19`, ejecutable oficial para Windows.
- FFmpeg `8.1.2`, build Windows de Gyan enlazado por el sitio oficial de
  FFmpeg. El artefacto local actual es `full_build`.
- Deno `2.9.4`, ejecutable oficial x64 para Windows.
- Uso: inspección, descarga, unión de pistas y soporte JavaScript de extractores.

El script `tools/setup_windows_runtime.ps1` verifica los hashes SHA-256
publicados antes de sustituir un componente. Antes de distribuir el ZIP deben
acompañarse los avisos y textos de licencia exigidos por cada build.
