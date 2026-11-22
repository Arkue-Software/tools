# tools

Configuración del API Gateway de RedVital y de las herramientas que lo acompañan.

| Carpeta | Contenido |
|---|---|
| [`APISIX-config/`](APISIX-config/README.md) | Apache APISIX 3.19 en modo sin base de datos: rutas, validación del token, compuerta por rol, límite de tasa, correlación y el plugin propio `redvital-autorizacion` |

## Cómo se usa

Este repositorio no se despliega solo. La composición de la VM de borde, en
`Arkue-Software/Despliegue_RedVital` (`vm-borde/docker-compose.yml`), monta
`APISIX-config/config` y `APISIX-config/plugins` en el contenedor de APISIX, que
queda detrás del Caddy de borde y no publica puertos. El script
`scripts/clonar-repos.sh` de ese repositorio arma las carpetas desde la rama
`develop`.

Las rutas y los roles de `APISIX-config/config/apisix.yaml` salen de la matriz
de autorización del DD (sección 15.5). Un cambio de ruta o de rol se hace en
ese archivo y en el servicio dueño de la ruta, que vuelve a validar el token y
aplica la jurisdicción.

## Pruebas

`APISIX-config/pruebas/` trae las pruebas del gateway (T-305.6), la entrega de
denegaciones a la auditoría (T-305.4) y la verificación de que QA rechaza la
llave de prueba (T-303.3). `correr-local.sh` las ejecuta contra un APISIX local
con un doble de Identidad (`mock_identity.py`).
