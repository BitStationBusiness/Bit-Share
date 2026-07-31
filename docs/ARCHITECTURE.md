# Arquitectura

## Alcance actual

Un único repositorio Flutter contiene Android, Windows y Web. El dominio y los
contratos son Dart puro. Android implementa la recepción del Sharesheet en
Kotlin. Windows ejecuta un motor local de procesos. Web no simula capacidades
nativas que todavía no existen.

## Capas

- `app`: tema, navegación y cadenas de interfaz.
- `domain`: entidades y contratos sin dependencias de plataforma.
- `features`: pantallas organizadas por capacidad.
- `platform`: adaptación Dart de canales nativos.
- `android`: Intents, validación, descarga y publicación.
- `windows_download`: interfaz y coordinación de procesos locales Windows.

## Android

- `bitshare/methods`: inicialización, payload y comandos.
- `bitshare/events`: contenido nuevo, progreso y resultados.
- Kotlin controla yt-dlp, FFmpeg y MediaStore.

## Windows

- La interfaz Flutter presenta entrada, formatos y estado.
- `WindowsProcessDownloadBackend` ejecuta yt-dlp sin shell y con argumentos
  separados.
- FFmpeg une o convierte pistas.
- Deno aporta el runtime JavaScript requerido por extractores actuales.
- Los ejecutables viven en `runtime` junto a `bit_share.exe`.
- Cada descarga se limita a `Downloads/Bit-Share`; la ruta final se valida
  antes de mostrarla.
- La sesión del navegador no se solicita por defecto. Si el extractor devuelve
  autenticación requerida, el usuario elige Edge, Chrome o Firefox, inicia
  sesión allí y autoriza un reintento con `--cookies-from-browser`.

## Destinos

- Android: activo, API mínima 26.
- Windows x64: primera versión activa para enlaces.
- Web: shell generado; sin motor multimedia nativo.
