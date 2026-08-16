# Protocolo de actualización

El checkpoint 3 fija yt-dlp, curl-cffi, CPython y FFmpeg dentro del APK. La
aplicación no descarga ni activa código de dependencias en segundo plano.
Actualizar cualquiera de estos componentes requiere un build nuevo, pruebas
de regresión y la firma de un APK nuevo.

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
previamente un protocolo firmado, versionado, aislado y con rollback.
