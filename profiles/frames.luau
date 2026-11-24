-- victor/profiles:frames — serviço automático de molduras góticas.
-- Aplica moldura gótico-dark a qualquer widget de desktop automaticamente.
-- Reage a onConfigChanged (widget adicionado/removido/redimensionado).
--
-- IPC: noctalia msg plugin victor/profiles:frames all "refresh"

local CMD = "noctalia-widget-frames"
local PLUGIN_DIR = (noctalia.pluginDir and noctalia.pluginDir()) or ""
local BUNDLED = PLUGIN_DIR ~= "" and (PLUGIN_DIR .. "/bin/noctalia-widget-frames") or ""

local running = false
local lastRun = 0

local function log(m)
    if noctalia.log then noctalia.log("[frames] " .. tostring(m)) end
end

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function cliArgv(args)
    local out = {}
    if BUNDLED ~= "" and noctalia.fileExists(BUNDLED) then
        table.insert(out, "python3")
        table.insert(out, BUNDLED)
    else
        table.insert(out, CMD)
    end
    for _, a in ipairs(args) do table.insert(out, a) end
    return out
end

-- Mesma normalização do painel: versões diferentes do Noctalia devolvem
-- exitCode / exit_code / status / success. Nunca assumir "comando falhou".
local function resultInfo(r)
    if type(r) ~= "table" then return true, tostring(r or ""), "" end
    local out = r.stdout or r.output or r.out or ""
    local err = r.stderr or r.error or r.message or ""
    if type(out) ~= "string" then out = tostring(out) end
    if type(err) ~= "string" then err = tostring(err) end
    local code = r.exitCode or r.exit_code or r.code or r.status
    local ok
    if code ~= nil then ok = (tonumber(code) == 0)
    elseif r.success ~= nil then ok = (r.success == true)
    elseif r.ok ~= nil then ok = (r.ok == true)
    else ok = true end
    if r.timedOut == true or r.timed_out == true then
        ok = false
        err = err ~= "" and (err .. " (timeout)") or "comando excedeu o tempo limite"
    end
    return ok, out, err
end

local function firstLine(s)
    return trim(s):match("[^\r\n]+") or ""
end

local function applyFrames(force)
    if running then return end

    if BUNDLED == "" and noctalia.commandExists
        and not noctalia.commandExists(CMD) then
        log("erro: " .. CMD .. " não encontrado no PATH e nenhum CLI embarcado")
        return
    end

    running = true
    local args = {}
    if force then table.insert(args, "--full") end
    noctalia.runAsync(cliArgv(args), function(r)
        running = false
        local ok, out, err = resultInfo(r)
        if not ok then
            local msg = firstLine(err) ~= "" and firstLine(err)
                or firstLine(out) ~= "" and firstLine(out)
                or "falha ao executar o gerador de molduras"
            log("erro: " .. msg)
            return
        end
        if out:find("config atualizada") then
            log("molduras atualizadas")
            noctalia.runAsync({ "noctalia", "msg", "config-reload" }, function(rr)
                local reloaded, ro, re = resultInfo(rr)
                if not reloaded then
                    log("erro ao recarregar config: " ..
                        (firstLine(re) ~= "" and firstLine(re) or firstLine(ro)))
                end
            end)
        elseif out:find("nada a mudar") then
            -- silencioso: tudo correto
        else
            log(out)
        end
    end)
end

function onConfigChanged()
    -- debounce: evitar loop infinito (script escreve settings → onConfigChanged)
    local now = os.time()
    if now - lastRun < 3 then return end
    lastRun = now
    applyFrames(false)
end

function onIpc(event, _payload)
    if event == "refresh" or event == "full" then
        applyFrames(event == "full")
    end
end

log("serviço de molduras pronto")
