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

La edición de Google Play no descargará DEX, JAR, bibliotecas `.so`, FFmpeg ni
el runtime de Python. Cualquier componente interpretado remoto requerirá una
revisión vigente de las políticas de la tienda.

No se implementará actualización interpretada remota sin diseñar y aprobar
previamente un protocolo firmado, versionado, aislado y con rollback.
