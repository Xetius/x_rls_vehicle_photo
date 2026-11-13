-- RLS Vehicle Photo
-- Adds "New image" to RLS Career Overhaul's My Vehicles menu. A temporary copy of the car is spawned
-- in a studio bowl high above the map (the stock showroom backdrop), photographed off-screen, then
-- removed. The photo is kept per career profile and takes priority over RLS's own thumbnail choice.
local M = {}

local logTag = 'xRlsVehiclePhoto'
local photoRoot = '/settings/x_rls_vehicle_photo/photos/'
local configFile = '/settings/x_rls_vehicle_photo/config.json'
local materialsFile = '/x_rls_vehicle_photo/backdrop.materials.json'
local materialName = 'x_rls_vehicle_photo_backdrop'
local backdropShape = '/levels/showroom_v2/art/shapes/main/backdrop_b.dae'

-- Any of these can be overridden in /settings/x_rls_vehicle_photo/config.json (inside your BeamNG user folder).
local defaults = {
  width = 640,
  height = 360,
  fov = 40,
  cameraDistance = 1.25, -- 1 = the game's tight framing; higher pulls back for room around the vehicle
  cameraPitch = 0,       -- degrees to raise the camera above the game's angle; negative lowers it
  frameShiftUp = 0,      -- move the vehicle up in the picture, as a fraction of its height (0.1 = a touch)
  frameShiftRight = 0,   -- move the vehicle right in the picture, as a fraction of its width
  nearPlane = 0.1,
  studioHeight = 1500,   -- metres above the camera where the studio is built
  useBackdrop = true,    -- false: plain sky behind the car
  forceDaylight = true,  -- borrow midday light for the shot when it is dark
  daylightWindow = 0.17, -- time-of-day distance from noon that already counts as daylight
  daylightTime = 0.06,   -- BeamNG time of day: 0 is noon, 0.5 is midnight
  settleSeconds = 1.5,   -- wait for the copy to finish loading meshes and textures
  screenshotDelay = 0.6,
  manualEV = nil,        -- fixed exposure; nil copies the game's current exposure
  backdropReach = 20,    -- keep the studio wall this many camera-distances away
  backdropHeight = 3,    -- stretch the studio walls upward; raise if sky shows at the top of photos
  shadowSoftness = 0.8,  -- sun shadow blur during the shot (levels use ~0.2); false leaves it alone
  yawDegrees = 0,        -- turn the car in the studio
}

local cfg
local busy = false

local function loadConfig()
  cfg = deepcopy(defaults)
  local user = FS:fileExists(configFile) and jsonReadFile(configFile)
  if type(user) == 'table' then
    for key, value in pairs(user) do cfg[key] = value end
  end
end

local function notify(text, kind)
  log(kind == 'error' and 'W' or 'I', logTag, text)
  if ui_message then ui_message(text, 5, logTag) end
end

local function inventory()
  return rawget(_G, 'overhaul_career_garage_inventory')
end

-- Photo storage --------------------------------------------------------------------------------------
-- Not inside the RLS save folder: RLS treats any folder there without info.json as a save slot.

local function profileDir()
  local saveSystem = rawget(_G, 'overhaul_career_saveSystem')
  local profile = saveSystem and saveSystem.getCurrentProfile()
  if type(profile) ~= 'string' or profile == '' then return nil end
  return photoRoot .. profile:gsub('[^%w%-_ ]', '_') .. '/'
end

local function readIndex(dir)
  local index = dir and FS:fileExists(dir .. 'index.json') and jsonReadFile(dir .. 'index.json')
  return type(index) == 'table' and index or {}
end

local function getVehicleRecord(inventoryId)
  local inv = inventory()
  local vehicles = inv and inv.getVehicles and inv.getVehicles()
  return vehicles and vehicles[inventoryId]
end

-- Cached so the thumbnail lookup (called for every row of every list) never re-reads the index.
local indexCache = {dir = nil, index = nil}

local function getPhoto(inventoryId)
  local dir = profileDir()
  if not dir then return nil end
  if indexCache.dir ~= dir then indexCache.dir, indexCache.index = dir, readIndex(dir) end
  local entry = indexCache.index[tostring(inventoryId)]
  if not entry then return nil end
  -- An id reused by a different car after a sale must not show the old car.
  local record = getVehicleRecord(tonumber(inventoryId) or inventoryId)
  if not record or record.model ~= entry.model then return nil end
  -- Photos from the first versions of this mod have no file entry and use <id>.jpg.
  local file = dir .. (entry.file or (tostring(inventoryId) .. '.jpg'))
  if not FS:fileExists(file) then return nil end
  return file, entry
end

local function photoFileName(inventoryId, takenAt)
  return tostring(inventoryId) .. '_' .. tostring(takenAt) .. '.jpg'
end

local function rememberPhoto(dir, inventoryId, model, takenAt)
  local index = readIndex(dir)
  local previous = index[tostring(inventoryId)]
  local file = photoFileName(inventoryId, takenAt)
  index[tostring(inventoryId)] = {model = model, takenAt = takenAt, file = file}
  jsonWriteFile(dir .. 'index.json', index, true)
  indexCache.dir, indexCache.index = dir, index
  local oldFile = previous and (previous.file or (tostring(inventoryId) .. '.jpg'))
  if oldFile and oldFile ~= file then FS:removeFile(dir .. oldFile) end
end

-- Thumbnail override ---------------------------------------------------------------------------------
-- RLS resolves a vehicle's picture through a local getVehicleThumbnail that prefers the stock config
-- preview, so a modified car keeps its factory picture. Every reference to that function (upvalues
-- shared by the inventory closures and table fields such as the public API) is pointed at a wrapper
-- that returns our photo first.

local patched = {inventory = nil, original = nil, wrapper = nil, dataFns = {}}

-- Put the photo into one car's UI data. Every photo has its own file name, so no screen can keep
-- showing a cached older one; dirtyDate (the pages' cache key) gets the photo's time as well.
local function applyPhoto(vehicleData, inventoryId)
  if type(vehicleData) ~= 'table' then return end
  local photo, entry = getPhoto(inventoryId)
  if not photo then return end
  vehicleData.thumbnail = photo
  vehicleData.dirtyDate = tostring(vehicleData.dirtyDate or '') .. '-' .. tostring(entry.takenAt or '')
end

local function replaceReferences(root, from, to)
  local seen, count = {}, 0
  local skip = {[_G] = true, [package] = true, [package.loaded] = true, [extensions] = true}

  local visitTable, visitFunction
  function visitFunction(fn, depth)
    if seen[fn] or depth > 6 then return end
    seen[fn] = true
    local i = 1
    while true do
      local name, value = debug.getupvalue(fn, i)
      if not name then break end
      -- rawequal: vec3/quat values have an __eq that errors when compared with a function
      if rawequal(value, from) then
        debug.setupvalue(fn, i, to)
        count = count + 1
      elseif type(value) == 'function' then
        visitFunction(value, depth + 1)
      elseif type(value) == 'table' then
        visitTable(value, depth + 1)
      end
      i = i + 1
    end
  end

  function visitTable(tbl, depth)
    if seen[tbl] or skip[tbl] or depth > 3 then return end
    seen[tbl] = true
    local size = 0
    for key, value in pairs(tbl) do
      size = size + 1
      if size > 400 then return end -- data tables (vehicles, parts) hold no functions worth patching
      if rawequal(value, from) then
        tbl[key] = to
        count = count + 1
      elseif type(value) == 'function' then
        visitFunction(value, depth)
      elseif type(value) == 'table' then
        visitTable(value, depth + 1)
      end
    end
  end

  visitTable(root, 0)
  return count
end

local function patchInventory()
  local inv = inventory()
  if not inv or rawequal(patched.inventory, inv) then return end
  if type(inv.getVehicleThumbnail) ~= 'function' then
    log('W', logTag, 'RLS inventory has no getVehicleThumbnail (' .. type(inv.getVehicleThumbnail) .. ')')
    patched.inventory = inv
    return
  end
  local original = inv.getVehicleThumbnail
  local wrapper = function(inventoryId, ...)
    local ok, photo = pcall(getPhoto, inventoryId)
    if ok and photo then return photo end
    return original(inventoryId, ...)
  end
  local ok, result = pcall(replaceReferences, inv, original, wrapper)
  if not ok then
    -- Remember the failure too, so it is logged once rather than every second.
    patched.inventory = inv
    log('E', logTag, 'Could not hook RLS thumbnails: ' .. tostring(result))
    return
  end
  patched.inventory, patched.original, patched.wrapper = inv, original, wrapper
  indexCache.dir = nil

  -- Screens such as the garage computer ask for a car's UI data straight from the page; RLS fills
  -- its picture internally, so put the photo into whatever these return.
  patched.dataFns = {}
  for _, name in ipairs({'getVehicleUiData', 'getVehicleDetailsUiData'}) do
    local originalFn = inv[name]
    if type(originalFn) == 'function' then
      local dataWrapper = function(inventoryId, ...)
        local data = originalFn(inventoryId, ...)
        pcall(applyPhoto, data, tonumber(inventoryId) or inventoryId)
        return data
      end
      inv[name] = dataWrapper
      patched.dataFns[name] = {original = originalFn, wrapper = dataWrapper}
    end
  end
  log('I', logTag, string.format('Hooked RLS vehicle thumbnails (%d references)', result))
end

-- Second route, independent of the above: rewrite the My Vehicles payload on its way to the UI.
local originalTrigger
local function rewriteInventoryPayload(data)
  if type(data) ~= 'table' or type(data.vehicles) ~= 'table' then return end
  for id, vehicle in pairs(data.vehicles) do
    pcall(applyPhoto, vehicle, tonumber(id) or id)
  end
end

local function installTriggerHook()
  if originalTrigger or not guihooks or type(guihooks.trigger) ~= 'function' then return end
  originalTrigger = guihooks.trigger
  guihooks.trigger = function(name, data, ...)
    if name == 'vehicleInventoryData' then pcall(rewriteInventoryPayload, data) end
    return originalTrigger(name, data, ...)
  end
end

local function uninstallTriggerHook()
  -- Leave it alone if something else has wrapped it since; ours then just passes through.
  if originalTrigger and guihooks then guihooks.trigger = originalTrigger end
  originalTrigger = nil
end

local function unpatchInventory()
  if patched.wrapper and patched.inventory == inventory() then
    pcall(replaceReferences, patched.inventory, patched.wrapper, patched.original)
    for name, fns in pairs(patched.dataFns) do
      if rawequal(patched.inventory[name], fns.wrapper) then patched.inventory[name] = fns.original end
    end
  end
  patched.inventory, patched.original, patched.wrapper, patched.dataFns = nil, nil, nil, {}
end

-- Studio ---------------------------------------------------------------------------------------------

local function borrowDaylight()
  if not cfg.forceDaylight or not core_environment then return nil end
  local tod = core_environment.getTimeOfDay()
  if type(tod) ~= 'table' or type(tod.time) ~= 'number' then return nil end
  local t = tod.time % 1
  if math.min(t, 1 - t) <= cfg.daylightWindow then return nil end
  core_environment.setTimeOfDay({time = cfg.daylightTime})
  return tod.time
end

-- Softens the sun's shadow for the shot; returns what to restore.
local function softenShadows()
  if not cfg.shadowSoftness then return nil end
  local saved = {}
  for _, name in ipairs(scenetree.findClassObjects('ScatterSky') or {}) do
    local sky = scenetree.findObject(name)
    local ok, current = pcall(function() return sky:getField('shadowSoftness', 0) end)
    if sky and ok and current and current ~= '' then
      saved[#saved + 1] = {sky = sky, value = current}
      pcall(function() sky:setField('shadowSoftness', 0, tostring(cfg.shadowSoftness)) end)
    end
  end
  return saved
end

local function restoreShadows(saved)
  for _, entry in ipairs(saved or {}) do
    pcall(function() entry.sky:setField('shadowSoftness', 0, entry.value) end)
  end
end

-- The showroom bowl is ~105 m in radius. A long vehicle puts the camera far back, so grow it to keep its
-- wall about backdropReach times the camera distance away. (Its rim height is handled in createBackdrop.)
local backdropRadius = 105
local function backdropScale(subject, camPosition)
  local ok, distance = pcall(function()
    return (vec3(camPosition) - vec3(subject:getSpawnWorldOOBB():getCenter())):length()
  end)
  if not ok or not distance then distance = (vec3(camPosition) - vec3(subject:getPosition())):length() end
  return math.max(1, distance * cfg.backdropReach / backdropRadius)
end

local function createBackdrop(pos, scale)
  if not cfg.useBackdrop or not FS:fileExists(backdropShape) then return nil end
  if not scenetree.findObject(materialName) and loadJsonMaterialsFile then
    pcall(loadJsonMaterialsFile, materialsFile)
  end
  local obj = createObject('TSStatic')
  obj:setField('shapeName', 0, backdropShape)
  obj:setField('collisionType', 0, 'None')
  obj:setField('decalType', 0, 'None')
  obj:setPosition(pos)
  -- The bowl's rim is only ~19 degrees up from its centre at any uniform size, and the flatter camera
  -- angle used for long vehicles sees over it. Taller walls (the floor is at z = 0, so it stays put)
  -- lift the rim out of frame.
  obj:setScale(vec3(scale, scale, scale * cfg.backdropHeight))
  obj:setCanSave(false)
  obj:registerObject('xRlsVehiclePhotoBackdrop')
  pcall(function() obj:setRenderEnabled(true) end)
  if scenetree.MissionGroup then scenetree.MissionGroup:addObject(obj) end
  return obj
end

-- Slide the camera sideways and up/down (not turning it) until the vehicle's box sits in the middle of the
-- picture. Aiming at the box centre isn't enough: the near end looks bigger, so it ends up cut off.
local function centerFraming(subject, camPosition, camRotation)
  local bb = subject:getSpawnWorldOOBB()
  local corners = {}
  for i = 0, 7 do corners[i + 1] = vec3(bb:getPoint(i)) end
  local rot = quat(camRotation)
  local forward, right, up = rot * vec3(0, 1, 0), rot * vec3(1, 0, 0), rot * vec3(0, 0, 1)
  local pos = vec3(camPosition)
  for _ = 1, 6 do
    local uMin, uMax, vMin, vMax = math.huge, -math.huge, math.huge, -math.huge
    for _, corner in ipairs(corners) do
      local rel = corner - pos
      local depth = rel:dot(forward)
      if depth <= 0.01 then return camPosition end -- camera inside the box; leave it alone
      local u, v = rel:dot(right) / depth, rel:dot(up) / depth
      uMin, uMax, vMin, vMax = math.min(uMin, u), math.max(uMax, u), math.min(vMin, v), math.max(vMax, v)
    end
    -- The shifts are fractions of the vehicle's size in the picture, so they look the same for any vehicle.
    local uTarget = (cfg.frameShiftRight or 0) * (uMax - uMin)
    local vTarget = (cfg.frameShiftUp or 0) * (vMax - vMin)
    local depth = (vec3(bb:getCenter()) - pos):dot(forward)
    pos = pos + right * (((uMin + uMax) / 2 - uTarget) * depth) + up * (((vMin + vMax) / 2 - vTarget) * depth)
  end
  return pos
end

local function lowestPoint(veh)
  local ok, z = pcall(function()
    local bb = veh:getSpawnWorldOOBB()
    local lowest = math.huge
    for i = 0, 7 do lowest = math.min(lowest, bb:getPoint(i).z) end
    return lowest
  end)
  if ok and z and z < math.huge then return z end
  return veh:getPosition().z
end

local function spawnConfig(inventoryId, record)
  local inv = inventory()
  local vehId = inv.getVehicleIdFromInventoryId and inv.getVehicleIdFromInventoryId(inventoryId)
  -- A car out in the world may have changes the record does not have yet.
  local live = vehId and core_vehicle_manager.getVehicleData(vehId)
  local config = deepcopy(live and live.config or record.config)
  if type(config) ~= 'table' then return nil, vehId end
  if config.partsTree then
    config.parts = core_vehicle_partmgmt.partsTreeToPartsMap(config.partsTree)
    config.partsTree = nil
  end
  local pc = config.partConfigFilename
  if type(pc) == 'string' and pc ~= '' and not FS:fileExists(pc) and not FS:fileExists('/' .. pc:gsub('^/', '')) then
    config.partConfigFilename = nil
  end
  return config, vehId
end

-- Render view capture --------------------------------------------------------------------------------
-- An off-screen view: the player's camera, UI and graphics settings are left alone.

local function capture(job, filename, camera)
  local view = RenderViewManagerInstance:getOrCreateView('xRlsVehiclePhoto')
  local ok, result = pcall(function()
    view.luaOwned = true
    view:maskSet(63)
    local matrix = QuatF(camera.rot.x, camera.rot.y, camera.rot.z, camera.rot.w):getMatrix()
    matrix:setPosition(camera.pos)
    view.cameraMatrix = matrix
    view.renderCubemap = false
    view.resolution = Point2I(cfg.width, cfg.height)
    view.viewPort = RectI(0, 0, cfg.width, cfg.height)
    view.namedTexTargetColor = 'xRlsVehiclePhoto'
    view.frustum = Frustum.construct(false, math.rad(cfg.fov), cfg.width / cfg.height, cfg.nearPlane, 2000)
    view.fov = cfg.fov
    view.renderEditorIcons = false
    if cfg.manualEV then
      view.useManualEV = true
      view.manualEV = cfg.manualEV
    else
      local exposure = scenetree.findObject('PostEffectLocalExposureObject')
      local main = RenderViewManagerInstance:getView('main')
      view.useManualEV = exposure and exposure.autoExposure ~= true or false
      if view.useManualEV then view.manualEV = exposure.manualEV
      elseif main and main.currentExposure then view.currentExposure = main.currentExposure end
    end
    job.sleep(cfg.screenshotDelay)
    local temporary = filename .. '.tmp.png'
    if not view:saveToDisk(temporary) then return false end
    local bitmap = GBitmap()
    local loaded = bitmap:loadFile(temporary)
    FS:removeFile(temporary)
    if not loaded then return false end
    bitmap:setFormat(10) -- R8G8B8, so the jpg has no alpha
    return bitmap:saveFile(filename) == true
  end)
  pcall(function() RenderViewManagerInstance:destroyView(view) end)
  if not ok then log('E', logTag, 'Capture failed: ' .. tostring(result)) end
  return ok and result
end

-- Photo job ------------------------------------------------------------------------------------------

local function finishPhoto(inventoryId, model, dir, takenAt, success, message)
  if success then
    rememberPhoto(dir, inventoryId, model, takenAt)
    patchInventory()
    local inv = inventory()
    local record = getVehicleRecord(inventoryId)
    -- dirtyDate is the UI's image cache key; RLS refreshes thumbnails the same way.
    -- pcall: some RLS versions hand out read-only record views.
    if record then pcall(function() record.dirtyDate = os.date('!%Y-%m-%dT%H:%M:%SZ') end) end
    if inv and inv.setVehicleDirty then inv.setVehicleDirty(inventoryId) end
    installTriggerHook()
    -- The full list, not a diff: a diff skips the car if RLS's own copy of it did not change.
    if inv and inv.sendDataToUi then inv.sendDataToUi() end
    notify('Vehicle photo updated')
    -- What each route reports, so a log shows which one is failing if the picture does not change.
    local okRls, rlsThumb = pcall(function() return inv.getVehicleThumbnail(inventoryId) end)
    local okList, listData = pcall(function() return inv.getVehicleUiData(inventoryId) end)
    log('I', logTag, string.format('Photo check: ours=%s rls=%s list=%s',
      tostring(getPhoto(inventoryId)), tostring(okRls and rlsThumb),
      tostring(okList and type(listData) == 'table' and listData.thumbnail)))
  else
    notify(message or 'Could not take a vehicle photo (see the log)', 'error')
  end
  guihooks.trigger('XRlsVehiclePhotoDone', {inventoryId = inventoryId, success = success})
end

local function runPhoto(job, inventoryId, record, config, liveVehId)
  local dir = profileDir()
  FS:directoryCreate(dir, true)
  local takenAt = os.time()
  local filename = dir .. photoFileName(inventoryId, takenAt)

  local physicsWasRunning = be:getPhysicsRunning()
  local savedTime, savedShadows, clone, backdrop
  local success, message = false, nil

  local ok, problem = pcall(function()
    local camPos = core_camera.getPosition()
    local studio = vec3(camPos.x, camPos.y, camPos.z + cfg.studioHeight)

    savedTime = borrowDaylight()
    savedShadows = softenShadows()
    -- Frozen physics keeps the copy where it spawned; the floor is fitted to it afterwards.
    be:setPhysicsRunning(false)
    core_vehicle_manager.queueAdditionalVehicleData({spawnWithEngineRunning = false})
    clone = core_vehicles.spawnNewVehicle(record.model, {
      config = config,
      pos = studio,
      rot = quatFromEuler(0, 0, math.rad(cfg.yawDegrees or 0)),
      autoEnterVehicle = false,
      canSpawnAnotherVehicleCheck = false,
      cling = false, -- no ground snap: the ground is far below the studio
      vehicleName = 'xRlsVehiclePhotoCopy',
    })

    local waited = 0
    while waited < cfg.settleSeconds do
      be:setPhysicsRunning(false)
      job.sleep(0.1)
      waited = waited + 0.1
    end

    log('I', logTag, 'Copy spawned: ' .. tostring(clone and clone:getID()))
    local subject = clone
    if not subject then
      -- No copy (spawn failed): photograph the real car where it stands, if it is out.
      subject = liveVehId and getObjectByID(liveVehId)
      if not subject then message = 'Could not spawn a copy of this vehicle for its photo'; return end
      log('W', logTag, 'Copy spawn failed, photographing the vehicle in place')
    end

    if not util_screenshotCreator then extensions.load('util_screenshotCreator') end
    local camPosition, camRotation = util_screenshotCreator.frameVehicle(
      subject, cfg.fov, cfg.nearPlane, cfg.width / cfg.height, {cfg.width, cfg.height})
    if not camPosition then message = 'Could not frame the vehicle'; return end

    -- Swing the camera up (or down) around the vehicle, keeping its distance, and aim back at the vehicle.
    if cfg.cameraPitch and cfg.cameraPitch ~= 0 then
      local ok, pos, rot = pcall(function()
        local center = vec3(subject:getSpawnWorldOOBB():getCenter())
        local offset = vec3(camPosition) - center
        local flat = vec3(offset.x, offset.y, 0)
        local radius = offset:length()
        local elevation = math.atan2(offset.z, flat:length()) + math.rad(cfg.cameraPitch)
        elevation = math.max(math.rad(-10), math.min(math.rad(85), elevation))
        local moved = center + flat:normalized() * (radius * math.cos(elevation)) + vec3(0, 0, radius * math.sin(elevation))
        return moved, quatFromDir(center - moved, vec3(0, 0, 1))
      end)
      if ok and pos then camPosition, camRotation = pos, rot else log('W', logTag, 'Could not raise the camera: ' .. tostring(pos)) end
    end

    -- Pull back along the line of sight for some room around the vehicle; the aim stays the same.
    if cfg.cameraDistance and cfg.cameraDistance ~= 1 then
      local ok, moved = pcall(function()
        local forward = quat(camRotation) * vec3(0, 1, 0)
        local distance = (vec3(camPosition) - vec3(subject:getSpawnWorldOOBB():getCenter())):length()
        return vec3(camPosition) - forward * (distance * (cfg.cameraDistance - 1))
      end)
      if ok and moved then camPosition = moved else log('W', logTag, 'Could not move the camera back: ' .. tostring(moved)) end
    end

    local centered, centeredPos = pcall(centerFraming, subject, camPosition, camRotation)
    if centered and centeredPos then camPosition = centeredPos else log('W', logTag, 'Could not centre the vehicle: ' .. tostring(centeredPos)) end

    -- The backdrop comes after framing: its size depends on how far back the camera ended up.
    if clone then
      local pos = clone:getPosition()
      local scale = backdropScale(clone, camPosition)
      log('I', logTag, string.format('Backdrop scale %.2f', scale))
      backdrop = createBackdrop(vec3(pos.x, pos.y, lowestPoint(clone) - 0.01), scale)
      job.sleep(0.3)
    end

    log('I', logTag, 'Capturing')
    success = capture(job, filename, {pos = camPosition, rot = camRotation})
    log('I', logTag, 'Capture finished: ' .. tostring(success))
  end)
  if not ok then log('E', logTag, tostring(problem)) end

  if clone then pcall(function() clone:delete() end) end
  if backdrop then pcall(function() backdrop:delete() end) end
  if savedTime then pcall(core_environment.setTimeOfDay, {time = savedTime}) end
  restoreShadows(savedShadows)
  be:setPhysicsRunning(physicsWasRunning)
  busy = false

  finishPhoto(inventoryId, record.model, dir, takenAt, ok and success, message)
end

-- Public API -----------------------------------------------------------------------------------------

local function takePhoto(inventoryId)
  inventoryId = tonumber(inventoryId) or inventoryId
  -- A photo job that died without finishing must not block every later one.
  if busy and os.clock() - busy > 30 then
    log('W', logTag, 'Previous photo never finished, starting over')
    busy = false
  end
  if busy then notify('Already taking a photo, one moment'); return false end
  if not inventory() then notify('Vehicle photos only work in an RLS career', 'error'); return false end
  patchInventory()
  if not profileDir() then notify('No career profile loaded', 'error'); return false end

  local record = getVehicleRecord(inventoryId)
  if not record then notify('Vehicle not found', 'error'); return false end
  if record.missingFile or tableIsEmpty(core_vehicles.getModel(record.model)) then
    notify('This vehicle\'s mod is missing, so it cannot be photographed', 'error')
    return false
  end
  local config, liveVehId = spawnConfig(inventoryId, record)
  if not config then notify('This vehicle has no saved configuration', 'error'); return false end

  loadConfig()
  busy = os.clock()
  notify('Taking vehicle photo...')
  core_jobsystem.create(function(job) runPhoto(job, inventoryId, record, config, liveVehId) end)
  return true
end

-- Drop a custom photo and go back to RLS's own thumbnail.
local function clearPhoto(inventoryId)
  local dir = profileDir()
  if not dir then return false end
  local index = readIndex(dir)
  local entry = index[tostring(inventoryId)]
  index[tostring(inventoryId)] = nil
  jsonWriteFile(dir .. 'index.json', index, true)
  indexCache.dir, indexCache.index = dir, index
  if entry then FS:removeFile(dir .. (entry.file or (tostring(inventoryId) .. '.jpg'))) end
  local inv = inventory()
  if inv and inv.sendVehicleUpdatesToUi then inv.sendVehicleUpdatesToUi() end
  return true
end

local function hasPhoto(inventoryId)
  return getPhoto(tonumber(inventoryId) or inventoryId) ~= nil
end

local sincePatchCheck = 0
local function onUpdate(dtReal)
  sincePatchCheck = sincePatchCheck + dtReal
  if sincePatchCheck < 1 then return end
  sincePatchCheck = 0
  -- The career recreates its inventory extension on every load, so hook whichever one is current.
  if not rawequal(inventory(), patched.inventory) then patchInventory() end
end

local function onExtensionLoaded()
  loadConfig()
  installTriggerHook()
  patchInventory()
end

local function onExtensionUnloaded()
  uninstallTriggerHook()
  unpatchInventory()
end

M.takePhoto = takePhoto
M.clearPhoto = clearPhoto
M.hasPhoto = hasPhoto
M.onUpdate = onUpdate
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

return M
