-- victor/profiles service — salva/aplica perfis completos do Noctalia.
-- IPC:
--   noctalia msg plugin victor/profiles:service all "save <nome>"
--   noctalia msg plugin victor/profiles:service all "apply <nome>"
--   noctalia msg plugin victor/profiles:service all "list"
--   noctalia msg plugin victor/profiles:service all "delete <nome>"
--   noctalia msg plugin victor/profiles:service all "export <nome> [arquivo.tar.gz]"
--   noctalia msg plugin victor/profiles:service all "import <arquivo.tar.gz> [nome]"

local CMD = "noctalia-profile"

local function notify(t, b)
    if noctalia.notify then noctalia.notify(t, b or "") end
end

local function log(m)
    if noctalia.log then noctalia.log("[profiles] " .. tostring(m)) end
end

local function run(args, done)
    noctalia.runAsync({CMD, table.unpack(args)}, function(r)
        local out = ""
        if type(r) == "table" then
            out = (r.stdout or "")
            if r.stderr and r.stderr ~= "" then out = out .. "\n" .. r.stderr end
        elseif type(r) == "string" then
            out = r
        end
        if done then done(out) end
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
        run({"save", name}, function(out)
            notify("Perfil salvo", name .. (out ~= "" and ("\n" .. out) or ""))
        end)
    elseif action == "apply" then
        if not name or name == "" then notify("Profiles", "uso: apply <nome>"); return end
        run({"apply", name}, function(out)
            notify("Perfil aplicado", name .. (out ~= "" and ("\n" .. out) or ""))
        end)
    elseif action == "list" then
        run({"list"}, function(out)
            notify("Perfis", out ~= "" and out or "nenhum perfil salvo")
        end)
    elseif action == "delete" then
        if not name or name == "" then notify("Profiles", "uso: delete <nome>"); return end
        run({"delete", name}, function(out)
            notify("Perfil removido", name)
        end)
    elseif action == "export" then
        if not name or name == "" then notify("Profiles", "uso: export <nome> [arquivo.tar.gz]"); return end
        local args = {"export", name}
        if extra and extra ~= "" then table.insert(args, extra) end
        run(args, function(out)
            local path = clean(out):match("(%S+%.tar%.gz)")
            notify("Perfil exportado", path or clean(out))
        end)
    elseif action == "import" then
        if not name or name == "" then notify("Profiles", "uso: import <arquivo.tar.gz> [nome]"); return end
        local args = {"import", name}
        if extra and extra ~= "" then table.insert(args, extra) end
        run(args, function(out)
            notify("Perfil importado", clean(out))
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
            if not name then name = payload
            elseif not extra then extra = payload end
        end
    end
    handle(action, name, extra)
end

function onConfigChanged() end

log("service pronto")
