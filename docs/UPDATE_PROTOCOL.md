# Protocolo de actualización

El APK incluye yt-dlp, curl-cffi, CPython y FFmpeg. De todos ellos, **solo
yt-dlp se actualiza por sí mismo**; curl-cffi, CPython y FFmpeg llevan código
compilado y siguen fijados al build, así que cambiarlos exige un APK nuevo con
pruebas de regresión y firma.

La excepción de yt-dlp es deliberada: YouTube invalida el extractor cada pocas
semanas, mucho más rápido de lo que se publica una release, y mantenerlo atado
al ciclo de la app garantizaba semanas de descargas rotas. El mecanismo está
en `bitshare_ytdlp_updater.py` (Android) y `ytdlp_engine_updater.dart`
(Windows), y cumple las cuatro condiciones que exige la sección final de este
documento:

1. **Verificado.** El wheel se coteja contra el SHA-256 que publica PyPI para
   ese archivo exacto; el `.exe` de Windows, contra el `digest` del asset de
   GitHub. Un hash que no cuadra aborta la instalación.
2. **Versionado.** Cada descarga vive en su propio directorio con el número de
   versión, y un manifiesto registra cuál está en uso.
3. **Aislado.** Las actualizaciones van a almacenamiento privado de la app
   (Android) o a `%LOCALAPPDATA%\Bit-Share\engine` (Windows) y solo se
   anteponen a la copia empotrada. Nada de lo que se firmó se modifica, así
   que la versión distribuida sigue ahí intacta.
4. **Con rollback.** Android importa el override antes de fiarse de él y, ante
   cualquier fallo, borra el registro y vuelve al wheel del APK. Windows exige
   que el binario descargado conteste `--version` antes de sustituir al
   anterior.

Una versión recién descargada se activa en el **arranque siguiente**, nunca
por debajo de una descarga en curso.

> Nota de distribución: descargar código interpretado en ejecución es lo que
> restringe la política de Google Play. Este mecanismo es apto para la
> distribución actual por GitHub; una edición para Play tendría que
> desactivarlo o someterlo a revisión previa.

Para cada actualización se exige:

1. versión base funcional incluida en la app;
2. versiones y hashes registrados;
3. análisis estático y pruebas Dart/Kotlin;
4. inspección y descarga física de enlaces de regresión;
5. firma de distribución y verificación del APK;
6. conservación del APK anterior y rollback probado.

## Publicación obligatoria de mejoras

Toda mejora funcional, corrección o cambio de interfaz debe publicarse en
GitHub antes de considerarse terminada. El flujo mínimo es:

1. incrementar `version` y `versionCode` en `apps/bit_share_flutter/pubspec.yaml`;
2. ejecutar las pruebas y compilaciones de Android y Windows;
3. registrar los cambios en `docs/releases/v<versión>.md`;
4. crear la release correspondiente en
   `BitStationBusiness/Bit-Share` con el APK, el instalador Windows y
   `SHA256SUMS.txt`;
5. verificar que los tres artefactos estén subidos y que la release apunte a
   la rama `source`.

No se debe cerrar una mejora dejando únicamente cambios locales sin publicar.

La edición de Google Play no descargará DEX, JAR, bibliotecas `.so`, FFmpeg ni
el runtime de Python. Cualquier componente interpretado remoto requerirá una
revisión vigente de las políticas de la tienda.

No se implementará actualización interpretada remota sin diseñar y aprobar
previamente un protocolo firmado, versionado, aislado y con rollback. El
autoactualizador de yt-dlp descrito arriba es la única implementación que
cumple esas condiciones; cualquier otro componente sigue vetado.
