--!nonstrict
-- victor/profiles — painel gótico de gerenciamento de perfis do Noctalia.
--
-- Salva e aplica perfis completos (config, widgets, layout, frames, fontes,
-- cores, wallpaper e plugins) via `noctalia-profile`.
--
-- Abrir: noctalia msg panel-toggle victor/profiles:profiles

local HOME = noctalia.getenv("HOME") or ""
local configuredDir = noctalia.getConfig("profiles_dir")
local PROFILES_DIR = (type(configuredDir) == "string" and configuredDir ~= "")
    and noctalia.expandPath(configuredDir)
    or noctalia.expandPath("~/.local/state/noctalia/profiles")
local CMD = "noctalia-profile"
local PANEL_ID = "victor/profiles:profiles"

-- Usa SEMPRE o CLI que vem dentro do plugin (materializado junto com a fonte
-- git). O ~/.local/bin/noctalia-profile pode ficar desatualizado na outra maquina.
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

-- O seletor de arquivos roda fora do painel (o zenity rouba o foco e o painel
-- fecha). O caminho escolhido fica num "stash" e é consumido em onOpen.
local PICK_DIR = (noctalia.pluginDataDir and noctalia.pluginDataDir())
    or (HOME .. "/.local/state/noctalia/plugins/data/victor/profiles")
local PICK_STASH = PICK_DIR .. "/pick-import"

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function shellQuote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local profiles = {}
local selected = nil
local nameInput = ""
local importPath = ""
local status = "Pronto. Selecione um perfil ou salve a config atual."
local statusKind = "info" -- info | ok | err
local pendingDelete = nil
local busy = false

local function setStatus(msg, kind)
    status = msg or ""
    statusKind = kind or "info"
end

local function metaLine(p)
    local when = p.saved_at or "?"
    when = when:gsub("T", " "):sub(1, 16)
    local host = p.hostname or "?"
    local nwall = 0
    if type(p.wallpapers) == "table" then
        for _ in pairs(p.wallpapers) do nwall = nwall + 1 end
    end
    return when .. "  ·  " .. host .. "  ·  " .. nwall .. " wallpaper(s)"
end

local function refreshProfiles()
    profiles = {}
    local names = noctalia.listDir(PROFILES_DIR)
    if names ~= nil then
        for _, n in ipairs(names) do
            if n:sub(1, 1) ~= "." then
                local meta = { name = n }
                local mf = PROFILES_DIR .. "/" .. n .. "/manifest.json"
                if noctalia.fileExists(mf) then
                    local ok, raw = pcall(noctalia.readFile, mf)
                    if ok and raw then
                        local ok2, decoded = pcall(noctalia.json.decode, raw)
                        if ok2 and type(decoded) == "table" then
                            for k, v in pairs(decoded) do meta[k] = v end
                            meta.name = n
                        end
                    end
                end
                table.insert(profiles, meta)
            end
        end
    end
    table.sort(profiles, function(a, b)
        return tostring(a.saved_at or "") > tostring(b.saved_at or "")
    end)
end

-- O formato do resultado do runAsync muda entre versoes do Noctalia: umas
-- usam exitCode, outras exit_code/status/success. Aceita todos; nunca mais
-- "comando falhou" sem motivo real.
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

local function manifestField(name, field)
    if not name or name == "" then return nil end
    local mf = PROFILES_DIR .. "/" .. name .. "/manifest.json"
    if not noctalia.fileExists(mf) then return nil end
    local ok, raw = pcall(noctalia.readFile, mf)
    if not ok or not raw then return nil end
    local ok2, decoded = pcall(noctalia.json.decode, raw)
    if not ok2 or type(decoded) ~= "table" then return nil end
    return decoded[field]
end

local function runProfile(args, onDone)
    busy = true
    setStatus("Executando…", "info")
    render()
    noctalia.runAsync(cliArgv(args), function(r)
        busy = false
        local ok, out, err = resultInfo(r)
        refreshProfiles()
        if not ok then
            local msg = trim(err):match("[^\r\n]+")
                or trim(out):match("[^\r\n]+")
                or ("falha ao executar " .. CMD)
            setStatus("Erro: " .. msg, "err")
            pcall(function()
                if noctalia.log then
                    noctalia.log("[profiles] falha: " .. tostring(args[1])
                        .. " exit=" .. tostring(r.exitCode or r.exit_code or r.status)
                        .. " stdout=" .. trim(out) .. " stderr=" .. trim(err))
                end
            end)
        end
        if onDone then onDone(out, ok, err) end
        render()
    end)
end

local function doImport(pathArg)
    if busy then return end
    local path = trim(pathArg or importPath):gsub('^"', ""):gsub('"$', "")
    if path == "" then
        setStatus("Escolha um arquivo .tar.gz.", "err")
        render()
        return
    end
    path = noctalia.expandPath(path)
    importPath = path

    local guess = path:match("([^/]+)%.tar%.gz$") or "perfil"
    local before = manifestField(guess, "imported_at")

    runProfile({ "import", path }, function(out, ok)
        -- O CLI imprime o nome real do perfil (pode vir do manifesto, nao do arquivo).
        local name = trim(out:match("PROFILE=([^\r\n]+)") or "")
        if name == "" then name = guess end

        -- Verificacao final: so considera sucesso se o manifesto mudou. Isso
        -- evita "importado" quando o CLI falhou ou o perfil ja existia.
        local after = manifestField(name, "imported_at")
        if not after or after == before then return end

        selected = name
        refreshProfiles()
        if out:match("APPLIED=1") then
            setStatus("Importado e aplicado: " .. name, "ok")
        else
            -- CLI antigo (ou aplicacao pulada): garante a aplicacao aqui.
            setStatus("Importado: " .. name .. ". Aplicando…", "info")
            render()
            runProfile({ "apply", name }, function(_, ok2)
                if ok2 then setStatus("Importado e aplicado: " .. name, "ok") end
            end)
        end
    end)
end

local function pickFile()
    if busy then return end
    if not noctalia.commandExists or not noctalia.commandExists("zenity") then
        setStatus("zenity nao encontrado — digite o caminho do .tar.gz.", "err")
        render()
        return
    end
    local start = trim(importPath)
    start = (start ~= "" and noctalia.expandPath(start)
        or noctalia.expandPath("~/Documents/noctalia-profiles") .. "/")
    -- `;` antes de panel-open: cancelar o dialog também devolve o painel.
    local cmd = "mkdir -p " .. shellQuote(PICK_DIR)
        .. " && p=$(zenity --file-selection"
        .. " --title=" .. shellQuote("Selecionar perfil .tar.gz")
        .. " --filename=" .. shellQuote(start)
        .. " --file-filter=" .. shellQuote("Perfis Noctalia (*.tar.gz) | *.tar.gz")
        .. ") && printf '%s' \"$p\" > " .. shellQuote(PICK_STASH)
        .. "; noctalia msg panel-open " .. shellQuote(PANEL_ID)
    noctalia.runAsync(cmd)
    setStatus("Escolha o arquivo na janela que abriu…", "info")
    render()
end

local function consumePick()
    if not noctalia.fileExists(PICK_STASH) then return end
    local path = trim(noctalia.readFile(PICK_STASH) or "")
    pcall(noctalia.removeFile, PICK_STASH)
    if path ~= "" then
        importPath = path
        doImport(path)
    end
end

local function divider()
    return ui.column({ height = 1, fill = "outline_variant", radius = 0 })
end

local function glyphFor(p)
    if selected == p.name then return "check" end
    return "window"
end

local function profileRow(p)
    local isSel = (selected == p.name)
    local children = {
        ui.glyph({ name = glyphFor(p), size = 16, color = isSel and "primary" or "on_surface_variant" }),
        ui.column({ flexGrow = 1, gap = 2, align = "stretch" }, {
            ui.label({
                text = p.name,
                fontSize = 14,
                fontWeight = "bold",
                color = isSel and "primary" or "on_surface",
                maxLines = 1,
            }),
            ui.label({
                text = metaLine(p),
                fontSize = 10,
                color = "on_surface_variant",
                maxLines = 1,
            }),
        }),
    }
    if pendingDelete == p.name then
        table.insert(children, ui.button({
            glyph = "check",
            variant = "primary",
            onClick = function()
                pendingDelete = nil
                runProfile({ "delete", p.name }, function(out, ok)
                    if not ok then return end
                    setStatus("Perfil '" .. p.name .. "' removido.", "ok")
                    if selected == p.name then selected = nil end
                end)
            end,
        }))
        table.insert(children, ui.button({
            glyph = "close",
            variant = "ghost",
            onClick = function() pendingDelete = nil; render() end,
        }))
    else
        table.insert(children, ui.button({
            glyph = "download",
            variant = "ghost",
            onClick = function()
                if busy then return end
                runProfile({ "export", p.name }, function(out, ok)
                    if not ok then return end
                    local path = out:match("(%S+%.tar%.gz)")
                    setStatus(path and ("Exportado: " .. path) or "Perfil exportado.", "ok")
                end)
            end,
        }))
        table.insert(children, ui.button({
            glyph = "trash",
            variant = "ghost",
            onClick = function()
                pendingDelete = p.name
                setStatus("Confirmar exclusão de '" .. p.name .. "'?", "err")
                render()
            end,
        }))
    end
    return ui.row({
        key = "profile-" .. p.name .. (isSel and "-sel" or "-idle") .. (pendingDelete == p.name and "-del" or ""),
        gap = 10,
        align = "center",
        padding = 10,
        paddingH = 12,
        fill = isSel and "primary/0.14" or "surface",
        border = isSel and "primary" or "outline_variant",
        borderWidth = 1,
        radius = 2,
        onClick = function()
            selected = p.name
            pendingDelete = nil
            setStatus("Perfil selecionado: " .. p.name, "info")
            render()
        end,
    }, children)
end

local function buildList()
    local rows = {}
    if #profiles == 0 then
        table.insert(rows, ui.column({ gap = 6, align = "center", padding = 18 }, {
            ui.glyph({ name = "moon", size = 26, color = "on_surface_variant" }),
            ui.label({ text = "Nenhum perfil ainda", color = "on_surface_variant", fontSize = 13 }),
            ui.label({ text = "Salve a config atual abaixo.", color = "on_surface_variant", fontSize = 11 }),
        }))
    else
        for _, p in ipairs(profiles) do
            table.insert(rows, profileRow(p))
        end
    end
    return ui.scroll({ flexGrow = 1, gap = 8, align = "stretch" }, rows)
end

local function statusColor()
    if statusKind == "ok" then return "primary" end
    if statusKind == "err" then return "error" end
    return "on_surface_variant"
end

function render()
    local header = ui.row({ align = "center", gap = 10, justify = "space_between" }, {
        ui.glyph({ name = "moon", size = 22, color = "primary" }),
        ui.column({ flexGrow = 1, gap = 0, align = "stretch" }, {
            ui.label({ text = "PROFILES", fontSize = 19, fontWeight = "bold", color = "primary" }),
            ui.label({ text = "GRIMÓRIO DO NOCTALIA", fontSize = 9, color = "on_surface_variant" }),
        }),
        ui.button({ glyph = "refresh", variant = "ghost", onClick = function()
            refreshProfiles(); setStatus("Lista atualizada.", "ok"); render()
        end }),
        ui.button({ glyph = "close", variant = "ghost", onClick = function() panel.close() end }),
    })

    local actions = ui.row({ gap = 8, align = "stretch" }, {
        ui.button({
            text = busy and "…" or "SALVAR ATUAL",
            glyph = "save",
            variant = "primary",
            onClick = function()
                if busy then return end
                local n = nameInput:gsub("^%s+", ""):gsub("%s+$", "")
                if n == "" then
                    setStatus("Digite um nome para o perfil.", "err"); render(); return
                end
                runProfile({ "save", n }, function(out, ok)
                    if not ok then return end
                    setStatus("Perfil '" .. n .. "' salvo.", "ok")
                    selected = n
                end)
            end,
        }),
        ui.button({
            text = busy and "…" or "APLICAR",
            glyph = "restore",
            variant = "primary",
            onClick = function()
                if busy then return end
                if not selected then
                    setStatus("Selecione um perfil na lista.", "err"); render(); return
                end
                local target = selected
                runProfile({ "apply", target }, function(out, ok)
                    if not ok then return end
                    setStatus("Perfil '" .. target .. "' aplicado.", "ok")
                end)
            end,
        }),
    })

    local nameField = ui.input({
        key = "profile-name",
        placeholder = "nome do novo perfil…",
        onChange = function(v) nameInput = v or "" end,
        onSubmit = function(v)
            nameInput = v or nameInput
            if nameInput ~= "" and not busy then
                runProfile({ "save", nameInput }, function(out, ok)
                    if not ok then return end
                    setStatus("Perfil '" .. nameInput .. "' salvo.", "ok")
                    selected = nameInput
                end)
            end
        end,
    })

    panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
        header,
        divider(),
        ui.label({ text = "PERFIS SALVOS", fontSize = 10, fontWeight = "medium", color = "on_surface_variant" }),
        buildList(),
        divider(),
        ui.label({ text = "SALVAR CONFIGURAÇÃO ATUAL", fontSize = 10, fontWeight = "medium", color = "on_surface_variant" }),
        nameField,
        actions,
        divider(),
        ui.label({ text = "IMPORTAR PERFIL (.tar.gz)", fontSize = 10, fontWeight = "medium", color = "on_surface_variant" }),
        ui.input({
            key = "import-path",
            placeholder = "caminho do .tar.gz…",
            onChange = function(v) importPath = v or "" end,
            onSubmit = function(v)
                importPath = v or importPath
                doImport()
            end,
        }),
        ui.row({ gap = 8, align = "stretch" }, {
            ui.button({ text = "PROCURAR ARQUIVO", glyph = "folder", variant = "ghost", onClick = pickFile }),
            ui.button({ text = "IMPORTAR", glyph = "upload", variant = "primary", onClick = function() doImport() end }),
        }),
        ui.label({ text = status, fontSize = 11, color = statusColor(), maxLines = 2 }),
    }))
end

function onOpen(_context)
    pendingDelete = nil
    refreshProfiles()
    if selected == nil and #profiles > 0 then
        selected = profiles[1].name
    end
    setStatus("Pronto.", "info")
    render()
    consumePick()
end
