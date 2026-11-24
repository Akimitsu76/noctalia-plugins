--!nonstrict
-- gothic-sticker — sticker com moldura gótica NATIVA (desenhada pelo plugin).
-- Mesmo princípio do fastfetch: borda externa na ui.column, borda interna
-- no ui.image, com um pequeno "matte" entre elas. Sem PNG sobreposto.
-- image_width/image_height acompanham o box do widget (mantidos pelo
-- noctalia-widget-frames), então tudo escala junto.
--
-- GIFs animados: ui.image mostra apenas o primeiro frame. Seguimos o mesmo
-- padrão do audio-sticker: ffmpeg/ffprobe decodificam o GIF em PNGs com a
-- duração de cada frame e onFrameTick troca o frame exibido.

local OUTER_COLOR = "#6b0f2a"  -- vinho escuro gótico
local INNER_COLOR = "#8a1230"  -- vermelho escuro
local OUTER_W = 3
local INNER_W = 2
local MATTE = 4
-- 208 é o tamanho do box do adesivo; extrair perto do tamanho exibido evita
-- redecodificar PNGs grandes a cada troca de frame (era a causa do engasgo).
local FRAME_SCALE = 208
local CACHE_VERSION = 2

local dataDir = noctalia.pluginDataDir() or ""

-- Config em estado local: onFrameTick() não deve consultar getConfig() a cada
-- tick, senão a animação disputa leituras de config com o thread da UI.
local imagePath = ""
local imageWidth = 320
local imageHeight = 320

local gifPath = nil
local gifFrames = nil
local gifDurations = nil
local gifTotalDuration = 0
local gifStartTime = 0
local gifLoading = false
local gifLoadStart = 0
local lastRenderedFrame = nil

local function isGif(path)
  return path ~= "" and path:lower():match("%.gif$") ~= nil
end

local function gifCacheDir(path)
  local safe = path:gsub("[^a-zA-Z0-9_.-]", "_")
  safe = safe:gsub("%.gif$", "")
  return dataDir .. "/gif-cache/" .. safe
end

local function parseFfmpegDurations(stdout)
  -- ffprobe devolve o PTS absoluto de cada frame, em segundos. A duração de um
  -- frame é o intervalo até o próximo PTS; o último repete o anterior.
  local pts = {}
  for line in stdout:gmatch("[^\r\n]+") do
    local sec = tonumber(line)
    if sec then table.insert(pts, math.floor(sec * 1000)) end
  end

  local durations, total = {}, 0
  for i = 1, #pts do
    local dur = 33
    if i < #pts then
      dur = pts[i + 1] - pts[i]
    elseif i > 1 then
      dur = pts[i] - pts[i - 1]
    end
    if dur <= 0 then dur = 33 end
    table.insert(durations, dur)
    total = total + dur
  end
  return durations, total
end

local function saveGifMetadata(cacheDir, frames, durations, totalDuration, sourceMtime, sourceSize)
  local encoded = noctalia.json.encode({
    frames = frames,
    durations = durations,
    totalDuration = totalDuration,
    sourceMtime = sourceMtime,
    sourceSize = sourceSize,
    cacheVersion = CACHE_VERSION,
  })
  if encoded then
    noctalia.writeFile(cacheDir .. "/metadata.json", encoded)
  end
end

local function loadGifMetadata(cacheDir, path)
  local raw = noctalia.readFile(cacheDir .. "/metadata.json")
  if not raw then return false end
  local meta = noctalia.json.decode(raw)
  if type(meta) ~= "table" or type(meta.frames) ~= "table" then return false end
  if meta.cacheVersion ~= CACHE_VERSION
    or meta.sourceMtime == nil or meta.sourceSize == nil then
    return false
  end
  local info = noctalia.fileInfo(path)
  if info and (meta.sourceMtime ~= info.mtime or meta.sourceSize ~= info.size) then
    return false
  end
  gifFrames = {}
  for _, name in ipairs(meta.frames) do
    table.insert(gifFrames, cacheDir .. "/" .. name)
  end
  gifDurations = meta.durations
  gifTotalDuration = meta.totalDuration or 0
  return true
end

local function finalizeFrames(path, cacheDir, frameCount, durations, totalDuration, sourceMtime, sourceSize)
  local frames = {}
  for i = 1, frameCount do
    table.insert(frames, string.format("frame-%03d.png", i))
  end
  saveGifMetadata(cacheDir, frames, durations, totalDuration, sourceMtime, sourceSize)
  gifFrames = {}
  for _, name in ipairs(frames) do
    table.insert(gifFrames, cacheDir .. "/" .. name)
  end
  gifPath = path
  gifDurations = durations
  gifTotalDuration = totalDuration
  gifStartTime = noctalia.nowMs()
  gifLoading = false
  lastRenderedFrame = nil
end

local function extractWithFfmpeg(path, cacheDir, sourceMtime, sourceSize)
  noctalia.runAsync({
    "ffprobe", "-v", "error", "-select_streams", "v:0",
    "-show_entries", "frame=pts_time", "-of", "csv=p=0", path
  }, function(probe)
    if probe.exitCode ~= 0 then
      noctalia.log("gothic-sticker: ffprobe falhou: " .. (probe.stderr or ""))
      gifLoading = false
      return
    end
    local durations, totalDuration = parseFfmpegDurations(probe.stdout or "")
    local frameCount = #durations
    if frameCount == 0 then
      durations = { 100 }
      totalDuration = 100
      frameCount = 1
    end

    -- A metadata é autoritativa: se ela falhou (versão diferente, arquivo da
    -- fonte mudou etc.), refaz os PNGs em vez de reaproveitar frames antigos
    -- com outra resolução.
    noctalia.runAsync({
      "ffmpeg", "-y", "-i", path,
      "-vf", "scale=" .. FRAME_SCALE .. ":-1:flags=lanczos",
      "-pix_fmt", "rgba",
      cacheDir .. "/frame-%03d.png"
    }, function(result)
      if result.exitCode ~= 0 then
        noctalia.log("gothic-sticker: ffmpeg falhou: " .. (result.stderr or ""))
        gifLoading = false
        return
      end
      finalizeFrames(path, cacheDir, frameCount, durations, totalDuration, sourceMtime, sourceSize)
    end)
  end)
end

local function resetGif()
  gifPath = nil
  gifFrames = nil
  gifDurations = nil
  gifTotalDuration = 0
  gifStartTime = 0
  gifLoading = false
  gifLoadStart = 0
  lastRenderedFrame = nil
end

local function extractGifFrames(path)
  if gifLoading then
    if noctalia.nowMs() - gifLoadStart < 30000 then return end
    noctalia.log("gothic-sticker: extração do GIF travou, tentando de novo")
  end
  if dataDir == "" then
    noctalia.log("gothic-sticker: sem diretório de dados, não dá para animar o GIF")
    return
  end
  if not noctalia.commandExists("ffmpeg") or not noctalia.commandExists("ffprobe") then
    noctalia.log("gothic-sticker: ffmpeg/ffprobe são necessários para GIFs animados")
    return
  end

  gifLoading = true
  gifLoadStart = noctalia.nowMs()
  local cacheDir = gifCacheDir(path)
  noctalia.mkdirAll(cacheDir)

  local info = noctalia.fileInfo(path)
  local sourceMtime = info and info.mtime or 0
  local sourceSize = info and info.size or 0

  if loadGifMetadata(cacheDir, path) then
    gifPath = path
    gifStartTime = noctalia.nowMs()
    gifLoading = false
    lastRenderedFrame = nil
    return
  end
  extractWithFfmpeg(path, cacheDir, sourceMtime, sourceSize)
end

local function currentGifFrame()
  if not gifFrames or #gifFrames == 0 then return nil end
  if gifTotalDuration <= 0 then return gifFrames[1] end
  local elapsed = (noctalia.nowMs() - gifStartTime) % gifTotalDuration
  local acc = 0
  for i, dur in ipairs(gifDurations) do
    acc = acc + dur
    if elapsed < acc then return gifFrames[i] end
  end
  return gifFrames[#gifFrames]
end

local function drawImage(path)
  local iw = imageWidth - 2 * (OUTER_W + MATTE)
  local ih = imageHeight - 2 * (OUTER_W + MATTE)
  local image = path ~= "" and ui.image({
    key = "gothic-sticker-image",
    path = path,
    width = iw,
    height = ih,
    fit = "stretch",
    radius = 0,
    border = INNER_COLOR,
    borderWidth = INNER_W,
  }) or ui.glyph({ key = "gothic-sticker-image", name = "photo", size = 32, color = "on_surface_variant" })

  desktopWidget.render(ui.column({
    key = "gothic-sticker-root",
    fill = "#0c0c10",
    border = OUTER_COLOR,
    borderWidth = OUTER_W,
    radius = 0,
    padding = MATTE,
    align = "center",
    justify = "center",
  }, { image }))
end

local function render()
  if isGif(imagePath) then
    if gifPath ~= imagePath then extractGifFrames(imagePath) end
    local frame = currentGifFrame() or imagePath
    if frame ~= lastRenderedFrame then
      lastRenderedFrame = frame
      drawImage(frame)
    end
    return
  end
  lastRenderedFrame = nil
  drawImage(imagePath)
end

function update()
  desktopWidget.setNeedsFrameTick(true)

  -- Config é lida apenas em update(); os ticks só avançam o frame atual.
  imagePath = noctalia.getConfig("image_path") or ""
  imageWidth = tonumber(noctalia.getConfig("image_width")) or 320
  imageHeight = tonumber(noctalia.getConfig("image_height")) or 320

  if not isGif(imagePath) then
    resetGif()
  elseif gifPath ~= imagePath then
    extractGifFrames(imagePath)
  end
  lastRenderedFrame = nil
  render()
end

function onFrameTick(deltaMs)
  if not isGif(imagePath) or not gifFrames or #gifFrames == 0 then return end
  local frame = currentGifFrame()
  if frame and frame ~= lastRenderedFrame then
    lastRenderedFrame = frame
    drawImage(frame)
  end
end

update()
