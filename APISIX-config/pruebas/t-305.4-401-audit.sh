#!/usr/bin/env bash
set -euo pipefail

gateway="${GATEWAY:-http://127.0.0.1:9080}"
url="$gateway/api/v1/campanias/00000000-0000-0000-0000-000000000001"
response_headers=$(mktemp)
response_body=$(mktemp)
trap 'rm -f "$response_headers" "$response_body"' EXIT

status=$(curl --silent --show-error \
  --dump-header "$response_headers" \
  --output "$response_body" \
  --write-out '%{http_code}' \
  "$url")

if [ "$status" != 401 ]; then
  echo "Esperaba HTTP 401 por falta de token; recibí $status."
  cat "$response_body"
  exit 1
fi

for attempt in $(seq 1 15); do
  auditorias=$(curl --fail --silent --show-error \
    http://127.0.0.1:8081/test/auditorias 2>/dev/null || true)
  if printf '%s' "$auditorias" | jq -e 'any(.[]; .operacion == "campanias:GET" and .actor_id == null)' >/dev/null; then
    echo "OK — OpenID Connect rechazó la petición con 401 y el plugin log entregó la denegación a Identidad."
    exit 0
  fi
  sleep 1
done

echo "La petición recibió 401, pero la denegación no llegó al endpoint de auditoría de Identidad."
printf '%s\n' "$auditorias"
exit 1
