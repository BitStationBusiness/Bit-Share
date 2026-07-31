# ADR-0001: estructura y frontera de plataforma

Estado: Aceptado  
Fecha: 2026-07-29

## Contexto

Bit-Share necesita destinos Android, Web y Windows, pero la primera entrega es
exclusivamente Android y usa APIs que no existen en las otras plataformas.

## Decisión

Mantener una aplicación Flutter compartida con dominio Dart puro y adaptar cada
plataforma mediante contratos. Android usa Kotlin y canales. Windows y Web se
generan desde el inicio, pero no presentan funciones nativas ficticias.

El identificador Android es `com.bitstation.bitshare` y la API mínima es 26.

## Alternativas

- Igualar capacidades en las tres plataformas: descartado por restricciones de
  navegador y diferencias de integración.
- Crear tres repositorios: descartado porque duplicaría dominio y modelos.

## Consecuencias

Se conserva una base compartida sin acoplar el dominio a Android. Las pruebas
de plataforma permanecen separadas. yt-dlp y FFmpeg requieren ADR propios tras
medir los PoC reales en arm64.

## Validación

`flutter analyze`, `flutter test`, `gradlew test` y `flutter build apk --debug`.
