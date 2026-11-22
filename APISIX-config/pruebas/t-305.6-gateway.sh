#!/usr/bin/env bash
# RedVital — T-305.6 · Pruebas del API Gateway (APISIX)
# Requiere el gateway, identity-service y campaign-service corriendo en
# Development. Los tokens se generan con identity-service/herramientas/LlaveDePrueba:
#   export TOKEN_OPERADOR=$(dotnet run --project <ruta>/LlaveDePrueba -- emitir-token --perfil operador)
#   export TOKEN_ADMIN=$(dotnet run --project <ruta>/LlaveDePrueba -- emitir-token --perfil admin_banco)
#   export TOKEN_SERVICIO=$(dotnet run --project <ruta>/LlaveDePrueba -- emitir-token --perfil servicio --cliente donacion)
# Opcional, para comprobar T-305.4 en la base:  export DB_IDENTIDAD="postgresql://postgres:...@localhost:5432/db_identidad"

set -u
GW="${GATEWAY:-http://localhost:9080}"
ID_FALSO="00000000-0000-0000-0000-000000000001"
fallos=0

comprobar() { # descripcion esperado obtenido
  if [ "$2" == "$3" ]; then echo "  OK   $1"; else echo "  FALLA $1 (esperado $2, obtenido $3)"; fallos=$((fallos+1)); fi
}
estado() { curl -s -o /dev/null -w "%{http_code}" "$@"; }

echo "T-305.1 — rutas /v1/* y exclusión de /internal/"
comprobar "/api/internal/... bloqueada"            404 "$(estado "$GW/api/internal/v1/sesiones/servicio")"
comprobar "/internal/... bloqueada"                404 "$(estado "$GW/internal/v1/auditoria/denegaciones")"
comprobar "listado público enrutado (quita /api)"  200 "$(estado "$GW/api/v1/campanias")"

echo "T-305.5 — identificador de correlación"
generado=$(curl -s -D - -o /dev/null "$GW/api/v1/campanias" | grep -i '^x-correlacion-id:' | tr -d '\r' | awk '{print $2}')
comprobar "se genera si no viene" "si" "$([ -n "$generado" ] && echo si || echo no)"
propagado=$(curl -s -D - -o /dev/null -H "X-Correlacion-Id: prueba-305-5" "$GW/api/v1/campanias" | grep -i '^x-correlacion-id:' | tr -d '\r' | awk '{print $2}')
comprobar "se respeta el que envía el cliente" "prueba-305-5" "$propagado"

echo "T-305.2 — firma y vigencia contra el JWKS"
comprobar "detalle sin token → 401"     401 "$(estado "$GW/api/v1/campanias/$ID_FALSO")"
comprobar "token alterado → 401"        401 "$(estado -H "Authorization: Bearer ${TOKEN_OPERADOR}x" "$GW/api/v1/campanias/$ID_FALSO")"
comprobar "token válido pasa el gateway (404 viene del servicio)" 404 \
  "$(estado -H "Authorization: Bearer $TOKEN_OPERADOR" "$GW/api/v1/campanias/$ID_FALSO")"

echo "T-305.3 — compuerta por ruta y rol"
comprobar "operador NO publica → 403" 403 \
  "$(estado -X POST -H "Authorization: Bearer $TOKEN_OPERADOR" -H "X-Correlacion-Id: prueba-305-3" "$GW/api/v1/campanias/$ID_FALSO/publicacion")"
comprobar "admin_banco pasa la compuerta (404 viene del servicio)" 404 \
  "$(estado -X POST -H "Authorization: Bearer $TOKEN_ADMIN" "$GW/api/v1/campanias/$ID_FALSO/publicacion")"
comprobar "token de servicio no entra por el gateway público → 403" 403 \
  "$(estado -H "Authorization: Bearer $TOKEN_SERVICIO" "$GW/api/v1/campanias/$ID_FALSO")"

echo "T-305.4 — la denegación llega a la auditoría de Identidad"
if [ -n "${DB_IDENTIDAD:-}" ]; then
  sleep 2
  n=$(psql "$DB_IDENTIDAD" -tAc "SELECT count(*) FROM registro_auditoria_ident WHERE correlacion_id='prueba-305-3' AND resultado='denegado'")
  comprobar "registro con correlación prueba-305-3" 1 "$n"
else
  echo "  (omitida: define DB_IDENTIDAD para comprobarlo en la base)"
fi

echo; [ $fallos -eq 0 ] && echo "T-305.6: todo correcto" || echo "T-305.6: $fallos prueba(s) fallaron"
exit $fallos
