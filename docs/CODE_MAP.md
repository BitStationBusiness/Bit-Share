# Mapa de código

## Raíz

- `README.md`: entrada del proyecto y comandos.
- `assets/branding`: fuentes maestras de identidad visual provisional.
- `Bit-Share_Documentacion_Planificacion_Prompt_Maestro.pdf`: especificación
  de producto y planificación.
- `apps/bit_share_flutter`: aplicación Flutter.
- `docs`: arquitectura, seguridad, contratos, pruebas, updater y ADR.
- `packages`: reservado para paquetes Dart compartidos cuando la separación
  aporte valor.
- `native`: reservado para PoC versionados de yt-dlp y FFmpeg.
- `tools`: reservado para scripts reproducibles de build y verificación.

Documentos operativos:

- `docs/ENVIRONMENT.md`: versiones fijadas del toolchain.
- `docs/CHECKPOINT-01.md`: alcance y resultados verificables del primer bloque.
- `docs/CHECKPOINT-02.md`: PoC de descarga pública y resultados en emulador.
- `docs/THIRD_PARTY_LICENSES.md`: dependencias evaluadas y obligaciones.

## Flutter

- `lib/main.dart`: bootstrap y selección de entrada normal o Sharesheet.
- `lib/app`: tema BitStation, composición y cadenas.
- `lib/domain/entities`: modelos independientes de plataforma.
- `lib/domain/repositories`: contratos de acceso a datos.
- `lib/domain/usecases`: orquestación de dominio.
- `lib/features/home`: shell principal.
- `lib/features/share_receiver`: hoja compacta del contenido compartido.
- `lib/platform`: `MethodChannel` y `EventChannel`.
- `test`: pruebas Dart y de widgets.

## Android

- `MainActivity.kt`: entrada de la aplicación completa.
- `share/ShareReceiverActivity.kt`: entrada transparente desde Sharesheet.
- `share/ShareIntentParser.kt`: validación y normalización defensiva.
- `share/ShareIntentLimits.kt`: cuotas y MIME permitidos.
- `bridge/BitSharePlugin.kt`: canales Flutter - Kotlin y eventos de Intent.
- `providers/ProviderRegistry.kt`: lista permitida de proveedores del PoC.
- `download/DownloadCoordinator.kt`: ejecución en hilo de fondo y cancelación.
- `media/MediaStoreRepository.kt`: publicación atómica en Descargas.
- `src/test`: pruebas unitarias Kotlin.

## Dependencias

La UI depende de dominio y plataforma. La plataforma implementa contratos del
dominio. El dominio no depende de Flutter ni Android. Kotlin no conoce widgets
ni reglas visuales.

## Windows

- `lib/features/windows_download`: pantalla, modelos, contrato y backend de
  procesos.
- `windows/runtime`: yt-dlp, FFmpeg, Deno y manifiesto de versiones.
- `windows/CMakeLists.txt`: valida y copia el runtime al paquete release.
- `windows/runner`: ventana, recursos, icono y metadatos del ejecutable.
- `tools/setup_windows_runtime.ps1`: descarga componentes, verifica SHA-256 y
  prepara un build portable.
