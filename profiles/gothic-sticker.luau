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
local FRAME_SCALE = 320       -- resolução dos frames extraídos
local CACHE_VERSION = 1

local dataDir = noctalia.pluginDataDir() or ""

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
  -- ffprobe devolve o PTS absoluto de cada frame, em segundos.
  local durations, total, lastMs = {}, 0, 0
  for line in stdout:gmatch("[^\r\n]+") do
    local sec = tonumber(line)
    if sec then
      local ms = math.floor(sec * 1000)
      local dur = ms - lastMs
      lastMs = ms
      if dur <= 0 then dur = 33 end
      table.insert(durations, dur)
      total = total + dur
    end
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

local function finalizeFrames(cacheDir, frameCount, durations, totalDuration, sourceMtime, sourceSize)
  local frames = {}
  for i = 1, frameCount do
    table.insert(frames, string.format("frame-%03d.png", i))
  end
  saveGifMetadata(cacheDir, frames, durations, totalDuration, sourceMtime, sourceSize)
  gifFrames = {}
  for _, name in ipairs(frames) do
    table.insert(gifFrames, cacheDir .. "/" .. name)
  end
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

    local cached = true
    for i = 1, frameCount do
      if not noctalia.fileExists(string.format(cacheDir .. "/frame-%03d.png", i)) then
        cached = false
        break
      end
    end
    if cached then
      finalizeFrames(cacheDir, frameCount, durations, totalDuration, sourceMtime, sourceSize)
      return
    end

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
      finalizeFrames(cacheDir, frameCount, durations, totalDuration, sourceMtime, sourceSize)
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

local function drawImage(path, iw, ih)
  local image = path ~= "" and ui.image({
    path = path,
    width = iw - 2 * (OUTER_W + MATTE),
    height = ih - 2 * (OUTER_W + MATTE),
    fit = "stretch",
    radius = 0,
    border = INNER_COLOR,
    borderWidth = INNER_W,
  }) or ui.glyph({ name = "photo", size = 32, color = "on_surface_variant" })

  desktopWidget.render(ui.column({
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
  local path = noctalia.getConfig("image_path") or ""
  local iw = tonumber(noctalia.getConfig("image_width")) or 320
  local ih = tonumber(noctalia.getConfig("image_height")) or 320

  if isGif(path) then
    if gifPath ~= path then extractGifFrames(path) end
    local frame = currentGifFrame() or path
    if frame ~= lastRenderedFrame then
      lastRenderedFrame = frame
      drawImage(frame, iw, ih)
    end
    return
  end
  lastRenderedFrame = nil
  drawImage(path, iw, ih)
end

function update()
  desktopWidget.setNeedsFrameTick(true)
  local path = noctalia.getConfig("image_path") or ""
  if not isGif(path) then
    resetGif()
  elseif gifPath ~= path then
    extractGifFrames(path)
  end
  lastRenderedFrame = nil
  render()
end

function onFrameTick(deltaMs)
  local path = noctalia.getConfig("image_path") or ""
  if not isGif(path) or not gifFrames or #gifFrames == 0 then return end
  local frame = currentGifFrame()
  if frame and frame ~= lastRenderedFrame then
    lastRenderedFrame = frame
    render()
  end
end

update()
