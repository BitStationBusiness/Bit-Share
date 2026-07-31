# Entorno fijado

Verificado el 29 de julio de 2026:

| Componente | Versión |
| --- | --- |
| Flutter | 3.41.5 stable, revisión `2c9eb20739` |
| Dart | 3.11.3 |
| Android SDK | 36.1 |
| compileSdk / targetSdk | 36 |
| minSdk | 26 |
| NDK | 28.2.13676358 |
| Android Gradle Plugin | 8.11.1 |
| Gradle wrapper | 8.14 |
| Kotlin | 2.2.20 |
| Java para Android | JDK 21.0.9 |
| Windows SDK | 10.0.26100.0 |
| yt-dlp Windows | 2026.07.04 |
| FFmpeg Windows | 8.1.2 full build |
| Deno Windows | 2.9.4 |

`flutter doctor -v` no reportó incidencias. Java 25 está presente en el `PATH`
general de la máquina, pero Gradle 8.14 debe ejecutarse con el JDK 21 incluido
en Android Studio. Flutter ya selecciona ese JDK automáticamente.

## Runtime Windows

Se prepara con `tools/setup_windows_runtime.ps1`. El build falla de forma
explícita si falta yt-dlp, FFmpeg o Deno, evitando generar un paquete que solo
funcione en el equipo de desarrollo.
