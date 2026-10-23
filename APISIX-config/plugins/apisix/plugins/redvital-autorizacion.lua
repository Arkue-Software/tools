-- RedVital — api-gateway
-- Plugin propio de APISIX: redvital-autorizacion
--
-- T-305.3 — Compuerta por ruta y rol según la matriz del DD.
--   Cada ruta declara qué roles leen (GET/HEAD) y cuáles escriben. Un rol
--   que escribe también lee. Si el rol no está, 403 "operacion-no-permitida".
--   La jurisdicción NO se decide aquí: el gateway no puede saber a qué
--   institución pertenece un recurso concreto. Eso lo hace cada servicio.
--
-- T-305.4 — Envío de denegaciones a la auditoría de Identidad.
--   Toda petición que el GATEWAY rechaza (401 del token, 403 de esta
--   compuerta) se entrega a POST /internal/v1/auditoria/denegaciones de
--   identity-service, con un token de servicio propio (cliente "gateway").
--   El envío es asíncrono (ngx.timer): la respuesta al usuario nunca espera
--   a la auditoría. Nunca se envía el dato al que se intentó acceder.
--
-- Orden: corre DESPUÉS de openid-connect (prioridad 2599 > 2400), así que
-- cuando este plugin lee el token, su firma y vigencia ya fueron validadas.

local core   = require("apisix.core")
local plugin = require("apisix.plugin")
local http   = require("resty.http")
local ngx    = ngx

local plugin_name = "redvital-autorizacion"

local schema = {
    type = "object",
    properties = {
        grupo        = { type = "string" },                         -- grupo de operaciones (Tabla 31)
        recurso_tipo = { type = "string", default = "ruta" },
        lectura      = { type = "array", items = { type = "string" }, default = {} },
        escritura    = { type = "array", items = { type = "string" }, default = {} },
    },
}

local metadata_schema = {
    type = "object",
    properties = {
        identidad_url = { type = "string" },
        cliente       = { type = "string", default = "gateway" },
        ruta_secreto  = { type = "string", default = "/run/secrets/gateway-secreto-cliente" },
    },
    required = { "identidad_url" },
}

local _M = {
    version = 0.1,
    priority = 2400,
    name = plugin_name,
    schema = schema,
    metadata_schema = metadata_schema,
}

function _M.check_schema(conf, schema_type)
    if schema_type == core.schema.TYPE_METADATA then
        return core.schema.check(metadata_schema, conf)
    end
    return core.schema.check(schema, conf)
end

-- ---------------------------------------------------------------- utilidades

local function contiene(lista, valor)
    for _, v in ipairs(lista or {}) do
        if v == valor then return true end
    end
    return false
end

-- Lee las reivindicaciones del token. No vuelve a verificar la firma:
-- openid-connect ya lo hizo antes de llegar aquí.
local function leer_reivindicaciones(cabecera)
    if not cabecera then return nil end
    local token = cabecera:match("^[Bb]earer%s+(.+)$")
    if not token then return nil end
    local carga = token:match("^[^.]+%.([^.]+)%.")
    if not carga then return nil end
    carga = carga:gsub("%-", "+"):gsub("_", "/")
    local resto = #carga % 4
    if resto > 0 then carga = carga .. string.rep("=", 4 - resto) end
    local texto = ngx.decode_base64(carga)
    if not texto then return nil end
    return core.json.decode(texto)
end

local function problema(estado, tipo, titulo, detalle, correlacion)
    core.response.set_header("Content-Type", "application/problem+json")
    return estado, { tipo = tipo, titulo = titulo, estado = estado, detalle = detalle, correlacion_id = correlacion }
end

-- ---------------------------------------------------------------- T-305.3

function _M.access(conf, ctx)
    local claims = leer_reivindicaciones(core.request.header(ctx, "Authorization"))
    ctx.redvital_claims = claims

    local rol = claims and claims.role
    local metodo = core.request.get_method()
    local es_lectura = (metodo == "GET" or metodo == "HEAD")

    local permitido = rol ~= nil and (
        contiene(conf.escritura, rol) or (es_lectura and contiene(conf.lectura, rol))
    )

    if not permitido then
        return problema(403, "operacion-no-permitida", "Operación no permitida",
            "El rol no autoriza esta operación.", core.request.header(ctx, "X-Correlacion-Id"))
    end
end

-- ---------------------------------------------------------------- T-305.4

-- Token de servicio del gateway, cacheado por proceso hasta 60 s antes de vencer.
local token_servicio = { valor = nil, vence = 0 }

local function obtener_token_servicio(meta)
    if token_servicio.valor and ngx.time() < token_servicio.vence - 60 then
        return token_servicio.valor
    end

    local archivo = io.open(meta.ruta_secreto, "r")
    if not archivo then return nil, "no se encontró el secreto de cliente en " .. meta.ruta_secreto end
    local secreto = (archivo:read("*a"):gsub("%s+$", ""))
    archivo:close()

    local httpc = http.new()
    httpc:set_timeout(3000)
    local res, err = httpc:request_uri(meta.identidad_url .. "/internal/v1/sesiones/servicio", {
        method = "POST",
        body = core.json.encode({ cliente = meta.cliente, secreto = secreto }),
        headers = { ["Content-Type"] = "application/json" },
    })
    if not res then return nil, err end
    if res.status ~= 200 then return nil, "Identidad respondió " .. res.status end

    local cuerpo = core.json.decode(res.body)
    if not cuerpo or not cuerpo.token_acceso then return nil, "respuesta sin token_acceso" end

    token_servicio.valor = cuerpo.token_acceso
    token_servicio.vence = ngx.time() + (cuerpo.expira_en or 900)
    return token_servicio.valor
end

local function entregar(premature, denegacion, meta)
    if premature then return end

    local token, err = obtener_token_servicio(meta)
    if not token then
        -- Sin la entrega, la denegación queda solo en el registro de error del
        -- gateway. El DD pide medir esto como
        -- auditoria_denegaciones_no_entregadas_total (pendiente de métricas, Sprint 4).
        core.log.error("auditoria_denegaciones_no_entregadas_total +1: ", err)
        return
    end

    local httpc = http.new()
    httpc:set_timeout(3000)
    local res, err2 = httpc:request_uri(meta.identidad_url .. "/internal/v1/auditoria/denegaciones", {
        method = "POST",
        body = core.json.encode(denegacion),
        headers = {
            ["Content-Type"] = "application/json",
            ["Authorization"] = "Bearer " .. token,
            ["X-Correlacion-Id"] = denegacion.correlacion_id,
        },
    })
    if not res or res.status >= 300 then
        core.log.error("auditoria_denegaciones_no_entregadas_total +1: ", err2 or res.status)
    end
end

function _M.log(conf, ctx)
    local estado = ngx.status
    if estado ~= 401 and estado ~= 403 then return end

    -- Si el servicio destino respondió, la denegación es suya y la audita él
    -- mismo en su propia serie. Aquí solo se entregan las del gateway.
    local estado_upstream = ngx.var.upstream_status
    if estado_upstream and estado_upstream ~= "" then return end

    local meta = plugin.plugin_metadata(plugin_name)
    if not meta or not meta.value then
        core.log.error("redvital-autorizacion sin plugin_metadata: no se puede entregar la denegación")
        return
    end

    local claims = ctx.redvital_claims
    local denegacion = {
        -- Con 401 no hay nadie identificable: actor_id nulo → Identidad lo registra como "anonimo".
        actor_id = (estado == 403 and claims) and claims.sub or nil,
        rol = (estado == 403 and claims) and claims.role or nil,
        jurisdiccion_solicitada = nil,   -- el gateway no conoce la jurisdicción del recurso
        operacion = (conf.grupo or "ruta") .. ":" .. core.request.get_method(),
        recurso_tipo = conf.recurso_tipo or "ruta",
        correlacion_id = core.request.header(ctx, "X-Correlacion-Id") or "",
        origen = core.request.header(ctx, "X-Forwarded-For") or ngx.var.remote_addr,
        ocurrido_en = os.date("!%Y-%m-%dT%H:%M:%SZ", ngx.time()),
    }

    local ok, err = ngx.timer.at(0, entregar, denegacion, meta.value)
    if not ok then
        core.log.error("auditoria_denegaciones_no_entregadas_total +1: no se pudo programar el envío: ", err)
    end
end

return _M
