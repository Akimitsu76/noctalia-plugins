-- victor/profiles service — salva/aplica perfis completos do Noctalia.
-- IPC:
--   noctalia msg plugin victor/profiles:service all "save <nome>"
--   noctalia msg plugin victor/profiles:service all "apply <nome>"
--   noctalia msg plugin victor/profiles:service all "list"
--   noctalia msg plugin victor/profiles:service all "delete <nome>"
--   noctalia msg plugin victor/profiles:service all "export <nome> [arquivo.tar.gz]"
--   noctalia msg plugin victor/profiles:service all "import <arquivo.tar.gz> [nome]"

local CMD = "noctalia-profile"

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

local function run(args, done)
    noctalia.runAsync(cliArgv(args), function(r)
        local ok, out, err = resultInfo(r)
        if done then done(out, ok, err) end
    end)
end

local function split(s)
    local parts = {}
    for p in tostring(s):gmatch("%S+") do table.insert(parts, p) end
    return parts
end

local function clean(out)
    return (tostring(out or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function handle(action, name, extra)
    log("acao=" .. tostring(action) .. " nome=" .. tostring(name))
    if action == "save" then
        if not name or name == "" then notify("Profiles", "uso: save <nome>"); return end
        run({"save", name}, function(out, ok, err)
            if not ok then notify("Erro ao salvar", clean(err)); return end
            notify("Perfil salvo", name)
        end)
    elseif action == "apply" then
        if not name or name == "" then notify("Profiles", "uso: apply <nome>"); return end
        run({"apply", name}, function(out, ok, err)
            if not ok then notify("Erro ao aplicar", clean(err)); return end
            notify("Perfil aplicado", name)
        end)
    elseif action == "list" then
        run({"list"}, function(out, ok, err)
            if not ok then notify("Erro", clean(err)); return end
            notify("Perfis", clean(out) ~= "" and clean(out) or "nenhum perfil salvo")
        end)
    elseif action == "delete" then
        if not name or name == "" then notify("Profiles", "uso: delete <nome>"); return end
        run({"delete", name}, function(out, ok, err)
            if not ok then notify("Erro ao remover", clean(err)); return end
            notify("Perfil removido", name)
        end)
    elseif action == "export" then
        if not name or name == "" then notify("Profiles", "uso: export <nome> [arquivo.tar.gz]"); return end
        local args = {"export", name}
        if extra and extra ~= "" then table.insert(args, extra) end
        run(args, function(out, ok, err)
            if not ok then notify("Erro ao exportar", clean(err)); return end
            notify("Perfil exportado", clean(out):match("(%S+%.tar%.gz)") or clean(out))
        end)
    elseif action == "import" then
        if not name or name == "" then notify("Profiles", "uso: import <arquivo.tar.gz> [nome]"); return end
        local args = {"import", name}
        if extra and extra ~= "" then table.insert(args, extra) end
        run(args, function(out, ok, err)
            local pname = clean(out):match("PROFILE=([^\r\n]+)")
            if not ok and not pname then
                notify("Erro ao importar", clean(err) ~= "" and clean(err) or "falha ao executar " .. CMD)
                return
            end
            notify(out:match("APPLIED=1") and "Perfil importado e aplicado" or "Perfil importado", pname or "perfil")
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
