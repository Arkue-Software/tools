#!/usr/bin/env python3
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

auditorias = []
secreto_cliente = "integration-test-secret"


class Handler(BaseHTTPRequestHandler):
    def _json(self, status, body):
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path == "/.well-known/openid-configuration":
            self._json(200, {
                "issuer": "http://identity-service:8080",
                "jwks_uri": "http://identity-service:8080/.well-known/jwks.json",
                "authorization_endpoint": "http://identity-service:8080/authorize",
                "token_endpoint": "http://identity-service:8080/token",
                "response_types_supported": ["code"],
                "subject_types_supported": ["public"],
                "id_token_signing_alg_values_supported": ["RS256"],
            })
        elif self.path == "/.well-known/jwks.json":
            self._json(200, {"keys": []})
        elif self.path == "/test/auditorias":
            self._json(200, auditorias)
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        if self.path == "/internal/v1/sesiones/servicio":
            solicitud = json.loads(body)
            if (
                solicitud.get("cliente") != "gateway"
                or solicitud.get("secreto") != secreto_cliente
            ):
                self._json(401, {"error": "unauthorized"})
                return
            self._json(200, {"token_acceso": "integration-service-token", "expira_en": 900})
        elif self.path == "/internal/v1/auditoria/denegaciones":
            if self.headers.get("Authorization") != "Bearer integration-service-token":
                self._json(401, {"error": "unauthorized"})
                return
            auditorias.append(json.loads(body))
            self._json(202, {"accepted": True})
        else:
            self._json(404, {"error": "not found"})

    def log_message(self, _format, *_args):
        return


HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
