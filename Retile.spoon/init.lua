--- === Retile ===
---
--- Tiling window manager driven by hotkeys, with a keyboard map of every
--- binding (⌘Y by default). See README.md for the settings.
local obj = {}
obj.__index = obj

obj.name = "Retile"
obj.version = "1.0"

local function load(file)
  return dofile(hs.spoons.resourcePath(file))
end

local layouts = load("layouts.lua")
local chords = load("chords.lua")
local config = load("config.lua")
local actions = load("actions.lua")(layouts)
local Tiler = load("tiler.lua")
local Overlay = load("overlay.lua")

local GROUPS = {
  { id = "move", label = "Move in layout" },
  { id = "workspace", label = "Spaces & displays" },
  { id = "focus", label = "Focus" },
  { id = "layout", label = "Layout" },
  { id = "app", label = "Retile" },
  { id = "custom", label = "Custom" },
  { id = "external", label = "Other Hammerspoon hotkeys" },
}

obj.logger = hs.logger.new("Retile", "info")

--- Retile:start([settings]) -> Retile
--- Method
--- Validates `settings` (merged over the defaults), binds the keys and, with
--- `autoTile`, starts tiling. Calling it again restarts with the new settings.
--- Invalid settings are reported in the console and leave Retile stopped.
function obj:start(settings)
  self:stop()
  local cfg, err = config.build(settings, {
    chords = chords,
    actions = actions,
    layouts = layouts.names,
    isKey = function(key) return hs.keycodes.map[key] ~= nil end,
  })
  if not cfg then
    self.logger.e("invalid settings:\n" .. err)
    hs.alert.show("Retile: invalid settings, see the Hammerspoon console", 5)
    return self
  end

  self.config = cfg
  self.tiler = Tiler.new(cfg, layouts, self.logger)
  self.overlay = Overlay.new(hs.spoons.resourcePath("overlay.html"), function() return self:keymap() end)
  self.hotkeys = {} -- hs.hotkey -> binding
  for _, b in pairs(cfg.bindings) do
    local fn = b.fn or function() actions[b.action].run(self, b.arg) end
    local hotkey = hs.hotkey.new(b.mods, b.key, fn)
    if hotkey:enable() then
      self.hotkeys[hotkey] = b
    else
      self.logger.w("could not bind " .. b.id .. ", is macOS using it?")
      hotkey:delete()
    end
  end
  if cfg.autoTile then self.tiler:start() end
  return self
end

--- Retile:stop() -> Retile
--- Method
--- Unbinds the keys and stops tiling; windows stay where they are.
function obj:stop()
  for hotkey in pairs(self.hotkeys or {}) do hotkey:delete() end
  if self.overlay then self.overlay:hide() end
  if self.tiler then self.tiler:stop() end
  self.hotkeys, self.overlay, self.tiler, self.config = nil, nil, nil, nil
  return self
end

-- Data for overlay.html: the active hotkeys (a later hs.hotkey on one of
-- Retile's chords shadows it), others only with showOtherHotkeys.
function obj:keymap()
  local binds = {}
  for _, hotkey in ipairs(hs.hotkey.getHotkeys()) do
    local b = self.hotkeys[hotkey]
    if b then
      binds[#binds + 1] = { key = b.key, mods = b.mods, desc = b.desc, group = b.group }
    elseif self.config.showOtherHotkeys then
      local chord = chords.fromHotkeyIndex(hotkey.idx)
      -- msg is "<idx>: <message>", or just idx without a message.
      local desc = hotkey.msg:sub(#hotkey.idx + 3)
      binds[#binds + 1] = {
        key = chord.key,
        mods = chord.mods,
        desc = desc ~= "" and desc or "Hammerspoon hotkey without a description",
        group = "external",
      }
    end
  end

  local used = {}
  for _, b in ipairs(binds) do used[b.group] = true end
  local groups = {}
  for _, g in ipairs(GROUPS) do
    if used[g.id] then groups[#groups + 1] = g end
  end
  return { title = "Retile", subtitle = self.tiler:describe(), groups = groups, binds = binds }
end

return obj
