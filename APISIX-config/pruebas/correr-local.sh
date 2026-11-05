#!/usr/bin/env bash
# RedVital · api-gateway · Corre en tu máquina lo mismo que el CI (ci-apisix.yml):
#   1. yamllint de config/ y marcador #END del modo standalone;
#   2. servicios simulados (Identidad, Campañas, Donación, Institucional) en una red aislada;
#   3. APISIX 3.19 con la configuración y el plugin del repo, sin errores al arrancar;
#   4. t-305.4: un 401 de APISIX llega a la auditoría de Identidad.
# Al terminar, bien o mal, borra los contenedores y la red.
#
#   bash pruebas/correr-local.sh        (desde APISIX-config/)
# Usa los puertos 127.0.0.1:9080 y 127.0.0.1:8081 mientras corre.
set -euo pipefail

cd "$(dirname "$0")/.."
RAIZ=$PWD
RED=apisix-prueba-local
SECRETO=$(mktemp)
CONTENEDORES="apisix-prueba-local identidad-prueba-local campanas-prueba-local donacion-prueba-local institucional-prueba-local"

limpiar() {
  docker rm -f $CONTENEDORES >/dev/null 2>&1 || true
  docker network rm "$RED" >/dev/null 2>&1 || true
  rm -f "$SECRETO"
}
trap limpiar EXIT
limpiar

for puerto in 9080 8081; do
  if (exec 3<>"/dev/tcp/127.0.0.1/$puerto") 2>/dev/null; then
    echo "El puerto 127.0.0.1:$puerto está ocupado: libéralo y vuelve a correr." >&2
    exit 2
  fi
done

echo "1/4 yamllint y marcador #END"
docker run --rm -v "$RAIZ/config:/data:ro" cytopia/yamllint:latest \
  -d '{extends: default, rules: {braces: {min-spaces-inside: 1, max-spaces-inside: 1}, line-length: {max: 140}}}' /data
test "$(tail -n 1 config/apisix.yaml | tr -d '\r\n')" = "#END"

echo "2/4 Servicios simulados"
docker network create "$RED" >/dev/null
# El simulador de Identidad (mock_identity.py) solo acepta este secreto de prueba.
printf '%s\n' 'integration-test-secret' > "$SECRETO"
chmod 644 "$SECRETO"
docker run -d --name identidad-prueba-local --network "$RED" --network-alias identity-service \
  -p 127.0.0.1:8081:8080 -v "$RAIZ/pruebas/mock_identity.py:/app/mock_identity.py:ro" \
  python:3.12-alpine python /app/mock_identity.py >/dev/null
docker run -d --name campanas-prueba-local --network "$RED" --network-alias campaign-service \
  python:3.12-alpine python -m http.server 8082 --bind 0.0.0.0 >/dev/null
docker run -d --name donacion-prueba-local --network "$RED" --network-alias donation-service \
  python:3.12-alpine python -m http.server 8083 --bind 0.0.0.0 >/dev/null
docker run -d --name institucional-prueba-local --network "$RED" --network-alias institutional-service \
  python:3.12-alpine python -m http.server 8084 --bind 0.0.0.0 >/dev/null

echo "3/4 APISIX con la configuración del repo"
docker run -d --name apisix-prueba-local --network "$RED" \
  -v "$RAIZ/config/config.yaml:/usr/local/apisix/conf/config.yaml:ro" \
  -v "$RAIZ/config/apisix.yaml:/usr/local/apisix/conf/apisix.yaml:ro" \
  -v "$RAIZ/plugins:/usr/local/apisix/custom:ro" \
  -v "$SECRETO:/run/secrets/gateway-secreto-cliente:ro" \
  -e APISIX_STANDALONE=true -p 127.0.0.1:9080:9080 \
  apache/apisix:3.19.0-debian >/dev/null
for _ in $(seq 1 30); do
  codigo=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9080/ || true)
  [ -n "$codigo" ] && [ "$codigo" != 000 ] && break
  sleep 1
done
if docker logs apisix-prueba-local 2>&1 | grep -iE "\[(error|emerg|crit)\]|fatal"; then
  echo "APISIX reportó un error al cargar la configuración o el plugin." >&2
  exit 1
fi

echo "4/4 t-305.4: 401 auditado en Identidad"
if command -v jq >/dev/null; then
  GATEWAY=http://127.0.0.1:9080 bash pruebas/t-305.4-401-audit.sh
else
  # Sin jq en la máquina: la prueba corre en un contenedor que lo trae.
  docker run --rm --network host -v "$RAIZ/pruebas:/pruebas:ro" -e GATEWAY=http://127.0.0.1:9080 alpine:3 \
    sh -c 'apk add --no-cache -q bash curl jq && bash /pruebas/t-305.4-401-audit.sh'
fi
echo "GATEWAY: OK"
