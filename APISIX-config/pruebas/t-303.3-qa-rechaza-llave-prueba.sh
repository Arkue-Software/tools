#!/usr/bin/env bash
# RedVital — T-303.3 · Contra el ambiente de QA desplegado.
# Un token firmado con la llave de PRUEBA debe ser rechazado por QA.
#   export GATEWAY_QA="https://<maquina-qa>/"   (a través de Caddy)
#   export TOKEN_PRUEBA=$(dotnet run --project <ruta>/LlaveDePrueba -- emitir-token --perfil operador)
set -u
codigo=$(curl -sk -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN_PRUEBA" \
  "${GATEWAY_QA%/}/api/v1/campanias/00000000-0000-0000-0000-000000000001")
if [ "$codigo" == "401" ]; then
  echo "OK — QA rechaza la llave de prueba (401)"; exit 0
else
  echo "FALLA — QA respondió $codigo con un token de la llave de prueba"; exit 1
fi
