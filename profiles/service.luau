-- victor/profiles service — salva/aplica perfis completos do Noctalia.
-- IPC:
--   noctalia msg plugin victor/profiles:service all "save <nome>"
--   noctalia msg plugin victor/profiles:service all "apply <nome>"
--   noctalia msg plugin victor/profiles:service all "list"
--   noctalia msg plugin victor/profiles:service all "delete <nome>"
--   noctalia msg plugin victor/profiles:service all "export <nome> [arquivo.tar.gz]"
--   noctalia msg plugin victor/profiles:service all "import <arquivo.tar.gz> [nome]"

local CMD = "noctalia-profile"

-- Aplicar/importar perfis com dezenas de plugins pode passar do timeout padrão
-- de 5s do host de scripts (exit 143 no meio da instalação). 60s é o teto
-- aceito; o CLI ignora plugins já habilitados nas novas tentativas.
local CMD_TIMEOUT_MS = 60000

-- CLI embarcado no plugin: acompanha o auto-update da fonte git, ao contrario
-- de ~/.local/bin/noctalia-profile (que pode ficar antigo na outra maquina).
local PLUGIN_DIR = (noctalia.pluginDir and noctalia.pluginDir()) or ""
local BUNDLED_CLI = PLUGIN_DIR ~= "" and (PLUGIN_DIR .. "/bin/noctalia-profile") or ""

local function cliArgv(args)
    local out = {}
    if BUNDLED_CLI ~= "" and noctalia.fileExists(BUNDLED_CLI) then
        table.insert(out, "python3")
        table.insert(out, BUNDLED_CLI)
    else
        table.insert(out, CMD)
    end
    for _, a in ipairs(args) do table.insert(out, a) end
    return out
end

local function notify(t, b)
    if noctalia.notify then noctalia.notify(t, b or "") end
end

local function log(m)
    if noctalia.log then noctalia.log("[profiles] " .. tostring(m)) end
end

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

local function clean(out)
    return (tostring(out or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Linhas machine-readable impressas pelo CLI v2.
local function machineInfo(out)
    local text = tostring(out or "")
    local phases = {}
    for line in text:gmatch("[^\r\n]+") do
        local p = line:match("^PHASE=(.+)$")
        if p then table.insert(phases, p) end
    end
    return {
        phases = phases,
        lastPhase = #phases > 0 and phases[#phases] or "",
        installed = clean(text:match("PLUGINS_INSTALLED=([^\r\n]*)")
            or text:match("INSTALLED_PLUGINS=([^\r\n]*)") or ""),
        installedDeps = clean(text:match("DEPENDENCIES_INSTALLED=([^\r\n]*)") or ""),
        missingDeps = clean(text:match("MISSING_DEPENDENCIES=([^\r\n]*)") or ""),
        missing = clean(text:match("MISSING_PLUGINS=([^\r\n]*)") or ""),
        widgets = tonumber(clean(text:match("WIDGETS_RESTORED=(%d+)") or "")) or 0,
        remap = clean(text:match("OUTPUT_REMAP=([^\r\n]*)") or ""),
        errorLine = clean(text:match("ERROR=([^\r\n]+)") or ""),
        applied = text:match("APPLIED=1") ~= nil,
    }
end

local function countList(s)
    local n = 0
    if s ~= "" then for _ in s:gmatch("[^,]+") do n = n + 1 end end
    return n
end

local function run(args, done)
    -- Avisa no log em qual fase o CLI está (o runAsync devolve só o resultado
    -- final, mas as linhas PHASE= vão todas no log ao terminar).
    -- timeoutMs é limitado a 60000 pela API; a fase de plugins do CLI é
    -- best-effort para o apply caber nesse limite.
    noctalia.runAsync(cliArgv(args), function(r)
        local ok, out, err = resultInfo(r)
        local info = machineInfo(out)
        for _, p in ipairs(info.phases) do log("fase: " .. p) end
        if done then done(out, ok, err, info) end
    end, CMD_TIMEOUT_MS)
end

local function split(s)
    local parts = {}
    for p in tostring(s):gmatch("%S+") do table.insert(parts, p) end
    return parts
end

-- Causa concreta: nunca devolve só "comando falhou" nem uma linha de log.
local function reason(err, out, info)
    if info.errorLine ~= "" then return info.errorLine end
    if clean(err):match("%(timeout%)$") then
        return "tempo limite de " .. math.floor(CMD_TIMEOUT_MS / 1000)
            .. "s; execute novamente (plugins já ativos são ignorados)"
    end
    -- O CLI registra progresso no stderr ([noctalia-profile] backup criado...).
    -- Isso não é o erro: pega a última linha que não seja log informativo.
    local last
    for line in clean(err):gmatch("[^\r\n]+") do
        if not line:match("^%[noctalia%-profile%]") then last = line end
    end
    if last and last ~= "" then return last end
    local line = clean(out):match("[^\r\n]+")
    if line and line ~= "" then return line end
    if info.lastPhase ~= "" then return "falha em: " .. info.lastPhase end
    return "CLI " .. CMD .. " terminou sem código de erro, mas sem saída útil"
end

local function summary(info)
    local parts = {}
    if info.lastPhase ~= "" then table.insert(parts, "fase: " .. info.lastPhase) end
    if info.widgets > 0 then
        table.insert(parts, info.widgets .. " widget(s) restaurado(s)")
    end
    local n = countList(info.installed)
    if n > 0 then table.insert(parts, n .. " plugin(s)/fonte(s) instalado(s)") end
    if info.remap ~= "" then table.insert(parts, "monitores: " .. info.remap) end
    if countList(info.installedDeps) > 0 then
        table.insert(parts, countList(info.installedDeps) .. " dependência(s) instalada(s)")
    end
    if info.missingDeps ~= "" then table.insert(parts, "dependências: " .. info.missingDeps) end
    if info.missing ~= "" then table.insert(parts, "faltaram: " .. info.missing) end
    return table.concat(parts, " · ")
end

local function handle(action, name, extra)
    log("acao=" .. tostring(action) .. " nome=" .. tostring(name))
    if action == "save" then
        if not name or name == "" then notify("Profiles", "uso: save <nome>"); return end
        run({"save", name}, function(out, ok, err, info)
            if not ok then notify("Erro ao salvar", reason(err, out, info)); return end
            notify("Perfil salvo", name)
        end)
    elseif action == "apply" then
        if not name or name == "" then notify("Profiles", "uso: apply <nome>"); return end
        run({"apply", name, "--yes"}, function(out, ok, err, info)
            if not ok then notify("Erro ao aplicar", reason(err, out, info)); return end
            notify("Perfil aplicado", name .. "\n" .. summary(info))
        end)
    elseif action == "list" then
        run({"list"}, function(out, ok, err, info)
            if not ok then notify("Erro", reason(err, out, info)); return end
            notify("Perfis", clean(out) ~= "" and clean(out) or "nenhum perfil salvo")
        end)
    elseif action == "delete" then
        if not name or name == "" then notify("Profiles", "uso: delete <nome>"); return end
        run({"delete", name}, function(out, ok, err, info)
            if not ok then notify("Erro ao remover", reason(err, out, info)); return end
            notify("Perfil removido", name)
        end)
    elseif action == "export" then
        if not name or name == "" then notify("Profiles", "uso: export <nome> [arquivo.tar.gz]"); return end
        local args = {"export", name}
        if extra and extra ~= "" then table.insert(args, extra) end
        run(args, function(out, ok, err, info)
            if not ok then notify("Erro ao exportar", reason(err, out, info)); return end
            notify("Perfil exportado", clean(out):match("(%S+%.tar%.gz)") or clean(out))
        end)
    elseif action == "import" then
        if not name or name == "" then notify("Profiles", "uso: import <arquivo.tar.gz> [nome]"); return end
        local args = {"import", name}
        if extra and extra ~= "" then table.insert(args, extra) end
        table.insert(args, "--yes")
        run(args, function(out, ok, err, info)
            local pname = clean(out):match("PROFILE=([^\r\n]+)")
            if not ok and not pname then
                notify("Erro ao importar", reason(err, out, info))
                return
            end
            notify(info.applied and "Perfil importado e aplicado" or "Perfil importado",
                (pname or "perfil") .. "\n" .. summary(info))
        end)
    else
        notify("Profiles", "acao desconhecida: " .. tostring(action) ..
            "\nuse save|apply|list|delete|export|import")
    end
end

function onIpc(event, payload)
    local action, name, extra
    if type(payload) == "table" then
        action = payload.action or event
        name = payload.name or payload.file
        extra = payload.extra or payload.output
    else
        local parts = split(event)
        action = parts[1]
        name = parts[2]
        extra = parts[3]
        if type(payload) == "string" and payload ~= "" then
            -- o IPC separa o evento do resto: "export" + "nome /caminho.tar.gz"
            local rest = split(payload)
            if not name then name = rest[1] end
            if not extra then extra = rest[2] end
        end
    end
    handle(action, name, extra)
end

function onConfigChanged() end

log("service pronto")
