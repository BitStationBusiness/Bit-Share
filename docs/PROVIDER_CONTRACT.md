# Contrato de proveedores

Cada proveedor se implementará detrás de `ProviderAdapter` y declarará:

- identificador y hosts reconocidos;
- niveles de acceso compatibles;
- método de inspección;
- formatos expuestos;
- mecanismo de autorización, si existe;
- restricciones, términos y fecha de verificación.

Niveles previstos: `public`, `sharedFile`, `authorizedApi`,
`bitShareSession`, `authRequired`, `notExposed` y `protected`.

No se codificarán reglas de proveedores dentro de widgets ni del receptor
Android. El primer adaptador será genérico; yt-dlp y APIs oficiales se
evaluarán después de los PoC de la Fase 0.
