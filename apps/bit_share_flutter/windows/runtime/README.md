# Runtime local de Windows

Esta carpeta recibe los ejecutables portables usados por Bit-Share:

- `yt-dlp.exe`: resolución y descarga.
- `ffmpeg.exe`: unión y conversión multimedia.
- `deno.exe`: runtime JavaScript requerido por extractores modernos.

Desde la raíz del repositorio:

```powershell
powershell -ExecutionPolicy Bypass -File tools/setup_windows_runtime.ps1
```

El script consulta publicaciones oficiales, verifica SHA-256 y deja
`VERSIONS.txt`. CMake copia la carpeta junto a `bit_share.exe`; el programa no
depende de una instalación global ni modifica el `PATH` del usuario.
