# Bit-Share Flutter

Cliente compartido con experiencias específicas:

- Android recibe enlaces y archivos desde el menú Compartir.
- Windows permite pegar un enlace, elegir formato o resolución y descargar.
- Web conserva el shell, sin motor multimedia nativo.

El build Windows requiere preparar primero su runtime desde la raíz:

```powershell
powershell -ExecutionPolicy Bypass -File tools/setup_windows_runtime.ps1
flutter build windows --release
```
