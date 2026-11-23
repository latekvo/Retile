-- Keeps one tiling layout per (space, screen) and applies it with hs.window.
local Tiler = {}
Tiler.__index = Tiler

local SIDES = { left = "to the left", right = "to the right", up = "above", down = "below" }

local function indexOf(list, value)
  for i, v in ipairs(list) do
    if v == value then return i end
  end
end

local function listed(list, app)
  if not list or not app then return false end
  local name, bundle = app:name(), app:bundleID()
  for _, entry in ipairs(list) do
    if entry == name or entry == bundle then return true end
  end
  return false
end

local function sameFrame(a, b)
  return math.abs(a.x - b.x) < 1 and math.abs(a.y - b.y) < 1
    and math.abs(a.w - b.w) < 1 and math.abs(a.h - b.h) < 1
end

local function readingOrder(a, b)
  local fa, fb = a:frame(), b:frame()
  if fa.y ~= fb.y then return fa.y < fb.y end
  return fa.x < fb.x
end

-- Adds a space to `screen` and returns its id.
local function addSpace(screen)
  local before = {}
  for _, id in ipairs(hs.spaces.spacesForScreen(screen) or {}) do before[id] = true end
  local ok, err = hs.spaces.addSpaceToScreen(screen, false)
  hs.spaces.closeMissionControl()
  if not ok then return nil, err end
  for _, id in ipairs(hs.spaces.spacesForScreen(screen) or {}) do
    if not before[id] then return id end
  end
  return nil, "the new space did not appear"
end

function Tiler.new(cfg, layouts, log)
  return setmetatable({
    cfg = cfg,
    layouts = layouts,
    log = log,
    states = {}, -- "space@screenUUID" -> { layout, ratio, masters, order, incoming, paused }
    floating = {}, -- window id -> true
    resizable = {}, -- window id -> whether AXSize is settable
    timers = {}, -- one-shot timers, referenced so they are not collected before firing
  }, Tiler)
end

function Tiler:info(message)
  if self.cfg.alerts then hs.alert.show(message, 0.8) end
end

function Tiler:fail(message)
  self.log.w(message)
  hs.alert.show(message, 2)
end

function Tiler:after(seconds, fn)
  local timer
  timer = hs.timer.doAfter(seconds, function()
    self.timers[timer] = nil
    fn()
  end)
  self.timers[timer] = true
end

-- One layout per space and screen: with "Displays have separate Spaces" off,
-- every screen shows the same space.
function Tiler:stateFor(space, screen)
  local key = tostring(space) .. "@" .. screen:getUUID()
  local state = self.states[key]
  if not state then
    state = {
      layout = self.cfg.layout,
      ratio = self.cfg.ratio,
      masters = self.cfg.masters,
      order = {},
      incoming = {},
      paused = false,
    }
    self.states[key] = state
  end
  return state
end

-- Windows Retile may move between spaces and screens, floating ones included.
function Tiler:isManaged(win)
  if not win or not win:isStandard() or win:isFullScreen() then return false end
  local app = win:application()
  if listed(self.cfg.ignoreApps, app) then return false end
  return not self.cfg.onlyApps or listed(self.cfg.onlyApps, app)
end

function Tiler:isTileable(win)
  local id = win:id()
  if not id or self.floating[id] or not self:isManaged(win) then return false end
  if self.cfg.floatNonResizable then
    if self.resizable[id] == nil then
      local ax = hs.axuielement.windowElement(win)
      local settable = ax and ax:isAttributeSettable("AXSize")
      -- nil is an AX error, worth asking again next time.
      if settable == nil then return false end
      self.resizable[id] = settable
    end
    return self.resizable[id]
  end
  return true
end

-- Tileable windows on each screen's active space, keyed by screen UUID.
function Tiler:collect()
  local entries = {}
  for _, screen in ipairs(hs.screen.allScreens()) do
    local space = hs.spaces.activeSpaceOnScreen(screen)
    if space then
      entries[screen:getUUID()] = { screen = screen, space = space, windows = {} }
    end
  end
  for _, win in ipairs(hs.window.visibleWindows()) do
    local screen = win:screen()
    local entry = screen and entries[screen:getUUID()]
    -- hs.window can list windows of inactive spaces as visible.
    if entry and self:isTileable(win) and indexOf(hs.spaces.windowSpaces(win) or {}, entry.space) then
      entry.windows[#entry.windows + 1] = win
    end
  end
  return entries
end

-- One collected screen's state, its window ids in layout order and the
-- windows in that order; the order kept in the state is left as it was.
function Tiler:ordered(entry)
  local state = self:stateFor(entry.space, entry.screen)
  table.sort(entry.windows, readingOrder)
  local byId, present = {}, {}
  for _, win in ipairs(entry.windows) do
    byId[win:id()] = win
    present[#present + 1] = win:id()
  end
  local order = self.layouts.reconcile(state.order, present, self.cfg.newWindows, state.incoming)
  local windows = {}
  for i, id in ipairs(order) do windows[i] = byId[id] end
  return state, order, windows
end

-- Lays out one screen. Returns its state, its windows in layout order and
-- their frames, or nil when tiling is paused there or a window is carried.
function Tiler:tileEntry(entry)
  local state = self:stateFor(entry.space, entry.screen)
  -- A carried window would be tiled mid-flight; the carry re-tiles on landing.
  if state.paused or self.carrying then return end
  local _, order, windows = self:ordered(entry)
  state.order, state.incoming = order, {}

  local frames = self.layouts.arrange(state.layout, #order, entry.screen:frame(), {
    ratio = state.ratio,
    masters = state.masters,
    gaps = self.cfg.gaps,
  })
  for i, win in ipairs(windows) do
    if not sameFrame(win:frame(), frames[i]) then
      win:setFrame(frames[i], self.cfg.animationDuration)
    end
  end
  return { state = state, windows = windows, frames = frames }
end

function Tiler:tileAll()
  local tiled = {}
  for uuid, entry in pairs(self:collect()) do
    tiled[uuid] = self:tileEntry(entry)
  end
  return tiled
end

function Tiler:scheduleTile(delay)
  if self.tileTimer then self.tileTimer:stop() end
  self.tileTimer = hs.timer.doAfter(delay, function()
    self.tileTimer = nil
    self:tileAll()
  end)
end

-- The focused window's layout after re-tiling, and the window's slot in it;
-- nothing while a window is carried.
function Tiler:focused()
  if self.carrying then return end
  local win = hs.window.focusedWindow()
  local screen = win and win:screen()
  if not screen then return nil, win end
  local tiled = self:tileAll()[screen:getUUID()]
  local i = tiled and indexOf(tiled.state.order, win:id())
  if i then return tiled, win, i end
  return nil, win
end

-- The state of the focused window's screen (or the mouse's, with no focused
-- window), and that screen's collected entry; nothing while a window is carried.
function Tiler:current()
  if self.carrying then return end
  local win = hs.window.focusedWindow()
  local screen = win and win:screen() or hs.mouse.getCurrentScreen()
  local entry = self:collect()[screen:getUUID()]
  if entry then return self:stateFor(entry.space, entry.screen), entry end
end

function Tiler:neighbor(tiled, i, dir)
  return self.layouts.neighbor(tiled.frames, i, dir, tiled.state.layout)
end

function Tiler:swapSlots(tiled, i, j)
  local order = tiled.state.order
  order[i], order[j] = order[j], order[i]
  self:tileAll()
end

function Tiler:swap(dir)
  local tiled, _, i = self:focused()
  if not tiled then return end
  local j = self:neighbor(tiled, i, dir)
  if j then self:swapSlots(tiled, i, j) end
end

function Tiler:promote()
  local tiled, _, i = self:focused()
  if tiled and #tiled.windows > 1 then self:swapSlots(tiled, i, i == 1 and 2 or 1) end
end

local FOCUS_FALLBACK = {
  left = "focusWindowWest",
  right = "focusWindowEast",
  up = "focusWindowNorth",
  down = "focusWindowSouth",
}

function Tiler:focus(dir)
  local tiled, win, i = self:focused()
  if tiled then
    local j = self:neighbor(tiled, i, dir)
    if j then tiled.windows[j]:focus() end
  elseif win then
    -- Floating windows and paused spaces use plain geometry.
    win[FOCUS_FALLBACK[dir]](win)
  end
end

-- macOS 14.5+ ignores hs.spaces.moveWindowToSpace for other apps' windows, so
-- the window is carried the way a user would: held by its title bar while
-- the space-switch shortcut runs.
function Tiler:moveToSpace(dir)
  local win = hs.window.focusedWindow()
  if self.carrying or not self:isManaged(win) then return end
  local screen = win:screen()
  local spaces = hs.spaces.spacesForScreen(screen) or {}
  local i = indexOf(spaces, hs.spaces.activeSpaceOnScreen(screen))
  if not i then return end
  local target = spaces[i + (dir == "right" and 1 or -1)]
  if target then
    if hs.spaces.spaceType(target) ~= "user" then
      return self:fail("The space " .. SIDES[dir] .. " is a full-screen app")
    end
    return self:carry(win, screen, target, dir)
  end
  if dir == "left" or not self.cfg.createSpaces then return self:fail("No space " .. SIDES[dir]) end
  local err
  target, err = addSpace(screen)
  if not target then return self:fail("Adding a space failed: " .. tostring(err)) end
  -- Mission Control has to finish closing before the window can be grabbed;
  -- the carry counts as started already.
  self.carrying = function() self.carrying = nil end
  self:after(0.7, function()
    self.carrying = nil
    self:carry(win, screen, target, dir)
    -- Failed before grabbing: tile what the wait held back.
    if not self.carrying then self:tileAll() end
  end)
end

-- Holds `win` just outside its zoom button, which is always bare title bar,
-- while switching `screen` one space towards `dir`, then tiles it there.
function Tiler:carry(win, screen, target, dir)
  local zoom = win:zoomButtonRect()
  if not zoom then return self:fail("Can't grab " .. (win:title() or "the window") .. " by its title bar") end
  local grab = { x = zoom.x - 1, y = zoom.y - 1 }
  local mouse = hs.mouse.absolutePosition()
  local event = hs.eventtap.event
  local function post(type, point)
    -- Explicit empty flags: the hotkey's modifiers are still held.
    event.newMouseEvent(type, point, {}):post()
  end

  local function release()
    post(event.types.leftMouseUp, grab)
    hs.mouse.absolutePosition(mouse)
    self.carrying = nil
  end
  -- Also how stop() lets go of a window mid-carry.
  self.carrying = release
  local function finish(err)
    release()
    if err then
      self:fail(err)
    else
      local incoming = self:stateFor(target, screen).incoming
      incoming[#incoming + 1] = win:id()
      win:focus()
    end
    self:tileAll()
  end

  post(event.types.leftMouseDown, grab)
  self:after(0.05, function()
    post(event.types.leftMouseDragged, { x = grab.x + 1, y = grab.y })
    -- Hardware arrow keys carry fn, and the shortcut only matches with it.
    event.newKeyEvent({ "ctrl", "fn" }, dir, true):post()
    event.newKeyEvent({ "ctrl", "fn" }, dir, false):post()
    local deadline = hs.timer.secondsSinceEpoch() + 1.5
    -- By UUID: for a screen object whose display is gone it throws, which
    -- would stop this timer with the mouse button still down.
    local uuid = screen:getUUID()
    self.arrival = hs.timer.doEvery(0.05, function()
      if hs.spaces.activeSpaceOnScreen(uuid) == target then
        self.arrival:stop()
        self.arrival = nil
        -- Released mid-animation, the window drops back to where it was.
        self:after(0.5, function()
          local arrived = indexOf(hs.spaces.windowSpaces(win) or {}, target)
          finish(not arrived and "The window didn't come along to the new space" or nil)
        end)
      elseif hs.timer.secondsSinceEpoch() > deadline then
        self.arrival:stop()
        self.arrival = nil
        finish('Switching spaces failed: is "Move ' .. dir .. ' a space" on in Keyboard Shortcuts > Mission Control?')
      end
    end)
  end)
end

local SCREEN_TOWARDS = { left = "toWest", right = "toEast", up = "toNorth", down = "toSouth" }

function Tiler:moveToScreen(dir)
  local win = hs.window.focusedWindow()
  if self.carrying or not self:isManaged(win) then return end
  local from = win:screen()
  local target = from[SCREEN_TOWARDS[dir]](from)
  if not target then return self:fail("No display " .. SIDES[dir]) end
  local space = hs.spaces.activeSpaceOnScreen(target)
  -- The window would land on a hidden space behind the full-screen app.
  if not space or hs.spaces.spaceType(space) ~= "user" then
    return self:fail("The display " .. SIDES[dir] .. " is showing a full-screen app")
  end
  local incoming = self:stateFor(space, target).incoming
  incoming[#incoming + 1] = win:id()
  win:moveToScreen(target, false, true, 0)
  self:tileAll()
  win:focus()
end

function Tiler:setLayout(name)
  local state, entry = self:current()
  if not state then return end
  state.layout = name
  self:tileEntry(entry)
  self:info("Layout: " .. name)
end

function Tiler:cycleLayout(step)
  local state = self:current()
  if not state then return end
  self:setLayout(self.layouts.cycle(self.cfg.layouts, state.layout, step))
end

function Tiler:resize(sign)
  local state, entry = self:current()
  if not state then return end
  state.ratio = self.layouts.stepRatio(state.ratio, sign, self.cfg.ratioStep)
  self:tileEntry(entry)
  self:info(string.format("Main area %d%%", math.floor(state.ratio * 100 + 0.5)))
end

function Tiler:changeMasters(sign)
  local state, entry = self:current()
  if not state then return end
  state.masters = self.layouts.stepMasters(state.masters, sign, #entry.windows)
  self:tileEntry(entry)
  self:info("Main area: " .. state.masters .. (state.masters == 1 and " window" or " windows"))
end

function Tiler:toggleFloat()
  local win = hs.window.focusedWindow()
  if not win then return end
  local id = win:id()
  if self.floating[id] then
    self.floating[id] = nil
    self:info("Tiled")
  elseif self:isTileable(win) then
    self.floating[id] = true
    self:info("Floating")
  else
    return self:fail("This window isn't tiled")
  end
  self:tileAll()
end

function Tiler:togglePause()
  local state, entry = self:current()
  if not state then return end
  state.paused = not state.paused
  if not state.paused then self:tileEntry(entry) end
  self:info(state.paused and "Tiling paused on this space" or "Tiling resumed")
end

local function plain(f)
  return { x = f.x, y = f.y, w = f.w, h = f.h }
end

local function frames(windows)
  local list = {}
  for i, win in ipairs(windows) do list[i] = plain(win:frame()) end
  return list
end

local function settings(state, count)
  return { layout = state.layout, ratio = state.ratio, masters = state.masters, paused = state.paused, count = count }
end

-- What the keyboard map's previews start from (see preview.lua): the focused
-- window's screen, or the mouse's, with its tiled windows in layout order, the
-- spaces beside it and the displays around it. Only reads; nil while a window
-- is carried.
function Tiler:scene()
  if self.carrying then return end
  local win = hs.window.focusedWindow()
  local screen = win and win:screen() or hs.mouse.getCurrentScreen()
  local entries = self:collect()
  local entry = entries[screen:getUUID()]
  if not entry then return end
  local state, order, windows = self:ordered(entry)
  local scene = settings(state)
  scene.screen = { frame = plain(screen:frame()), full = plain(screen:fullFrame()), name = screen:name() }
  scene.windows = frames(windows)
  scene.focus = win and indexOf(order, win:id())
  if win and not scene.focus and win:isStandard() then
    scene.loose = { frame = plain(win:frame()), floated = self.floating[win:id()] == true, managed = self:isManaged(win) }
  end

  -- Spaces Retile hasn't tiled yet start from the settings' defaults.
  local function remembered(space)
    local kept = self.states[tostring(space) .. "@" .. screen:getUUID()]
    return settings(kept or { layout = self.cfg.layout, ratio = self.cfg.ratio, masters = self.cfg.masters, paused = false },
      kept and #kept.order or 0)
  end
  local spaces = hs.spaces.spacesForScreen(screen) or {}
  local at = indexOf(spaces, entry.space)
  scene.spaces = { index = at, kinds = {} }
  for i, space in ipairs(spaces) do
    scene.spaces.kinds[i] = hs.spaces.spaceType(space) == "user" and "user" or "other"
  end
  for dir, step in pairs({ left = -1, right = 1 }) do
    local space = at and spaces[at + step]
    if space then scene.spaces[dir] = { user = scene.spaces.kinds[at + step] == "user", state = remembered(space) } end
  end

  scene.displays = {}
  for dir, towards in pairs(SCREEN_TOWARDS) do
    local other = screen[towards](screen)
    local there = other and entries[other:getUUID()]
    if there then
      local otherState, _, otherWindows = self:ordered(there)
      scene.displays[dir] = {
        full = plain(other:fullFrame()),
        frame = plain(other:frame()),
        user = hs.spaces.spaceType(there.space) == "user",
        state = settings(otherState),
        windows = frames(otherWindows),
      }
    end
  end
  return scene
end

function Tiler:start()
  self.filter = hs.window.filter.new(nil)
  local wf = hs.window.filter
  self.filter:subscribe({
    -- windowVisible/NotVisible: windowUnminimized and windowUnhidden never
    -- reach a filter that only allows visible windows.
    wf.windowCreated, wf.windowDestroyed, wf.windowVisible, wf.windowNotVisible,
    wf.windowFullscreened, wf.windowUnfullscreened,
  }, function(win, _, event)
    if event == wf.windowDestroyed then
      local id = win and win:id()
      if id then
        self.floating[id] = nil
        self.resizable[id] = nil
      end
    end
    self:scheduleTile(0.1)
  end)
  -- Space switches finish animating after the watcher fires.
  self.spaceWatcher = hs.spaces.watcher.new(function()
    self:pruneStates()
    self:scheduleTile(0.3)
  end):start()
  self.screenWatcher = hs.screen.watcher.new(function() self:scheduleTile(1) end):start()
  self:tileAll()
end

-- Forgets layouts of spaces that no longer exist.
function Tiler:pruneStates()
  local all = hs.spaces.allSpaces()
  if not all then return end
  local alive = {}
  for uuid, spaces in pairs(all) do
    for _, space in ipairs(spaces) do alive[tostring(space) .. "@" .. uuid] = true end
  end
  for key in pairs(self.states) do
    if not alive[key] then self.states[key] = nil end
  end
end

function Tiler:stop()
  if self.carrying then self.carrying() end
  if self.filter then self.filter:delete() end
  if self.spaceWatcher then self.spaceWatcher:stop() end
  if self.screenWatcher then self.screenWatcher:stop() end
  if self.tileTimer then self.tileTimer:stop() end
  if self.arrival then self.arrival:stop() end
  for timer in pairs(self.timers) do timer:stop() end
  self.filter, self.spaceWatcher, self.screenWatcher, self.tileTimer, self.arrival = nil, nil, nil, nil, nil
  self.timers = {}
end

return Tiler
