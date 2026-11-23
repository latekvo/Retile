-- Default settings and validation of the table passed to Retile:start().
local M = {}

M.defaults = {
  layout = "grid",
  layouts = { "grid", "tall", "wide", "columns", "rows", "spiral", "monocle" },
  ratio = 0.6,
  ratioStep = 0.05,
  masters = 1,
  gaps = { outer = 8, inner = 8 },
  autoTile = true,
  newWindows = "last",
  createSpaces = true,
  ignoreApps = {},
  onlyApps = nil,
  floatNonResizable = true,
  animationDuration = 0,
  alerts = true,
  showOtherHotkeys = true,
  defaultKeys = true,
  keys = {
    ["cmd+y"] = "keymap",

    ["cmd+left"] = "swap left",
    ["cmd+right"] = "swap right",
    ["cmd+up"] = "swap up",
    ["cmd+down"] = "swap down",
    ["ctrl+alt+return"] = "promote",

    ["cmd+shift+left"] = "moveToSpace left",
    ["cmd+shift+right"] = "moveToSpace right",
    ["cmd+shift+up"] = "moveToScreen up",
    ["cmd+shift+down"] = "moveToScreen down",

    ["ctrl+alt+left"] = "focus left",
    ["ctrl+alt+right"] = "focus right",
    ["ctrl+alt+up"] = "focus up",
    ["ctrl+alt+down"] = "focus down",

    ["ctrl+alt+1"] = "layout grid",
    ["ctrl+alt+2"] = "layout tall",
    ["ctrl+alt+3"] = "layout wide",
    ["ctrl+alt+4"] = "layout columns",
    ["ctrl+alt+5"] = "layout rows",
    ["ctrl+alt+6"] = "layout spiral",
    ["ctrl+alt+7"] = "layout monocle",
    ["ctrl+alt+l"] = "cycleLayout next",
    ["ctrl+alt+shift+l"] = "cycleLayout prev",
    ["ctrl+alt+["] = "resize shrink",
    ["ctrl+alt+]"] = "resize grow",
    ["ctrl+alt+,"] = "masters fewer",
    ["ctrl+alt+."] = "masters more",
    ["ctrl+alt+f"] = "toggleFloat",
    ["ctrl+alt+p"] = "togglePause",
    ["ctrl+alt+r"] = "retile",
  },
}

local function isFinite(v)
  return type(v) == "number" and v == v and v > -math.huge and v < math.huge
end

local function contains(list, value)
  for _, v in ipairs(list) do
    if v == value then return true end
  end
  return false
end

local function isStringList(v)
  if type(v) ~= "table" then return false end
  for k, s in pairs(v) do
    if math.type(k) ~= "integer" or type(s) ~= "string" then return false end
  end
  return true
end

local function sortedKeys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = tostring(k) end
  table.sort(keys)
  return keys
end

-- Each checker returns an error message, or nil when `v` is valid.
local function checkers(layoutNames)
  local function oneOf(options)
    return function(v)
      if not contains(options, v) then return "must be one of: " .. table.concat(options, ", ") end
    end
  end
  local function boolean(v)
    if type(v) ~= "boolean" then return "must be true or false" end
  end
  local function nonNegative(v)
    if not isFinite(v) or v < 0 then return "must be a number of at least 0" end
  end
  local function points(v)
    if math.type(v) ~= "integer" or v < 0 then return "must be a whole number of at least 0" end
  end
  local function strings(v)
    if not isStringList(v) then return "must be a list of app names or bundle IDs" end
  end
  return {
    layout = oneOf(layoutNames),
    layouts = function(v)
      if not isStringList(v) or #v == 0 then return "must be a non-empty list of layout names" end
      for _, name in ipairs(v) do
        if not contains(layoutNames, name) then
          return string.format("contains unknown layout %q (known: %s)", name, table.concat(layoutNames, ", "))
        end
      end
    end,
    ratio = function(v)
      if not isFinite(v) or v < 0.1 or v > 0.9 then return "must be a number from 0.1 to 0.9" end
    end,
    ratioStep = function(v)
      if not isFinite(v) or v <= 0 or v >= 1 then return "must be a number between 0 and 1" end
    end,
    masters = function(v)
      if math.type(v) ~= "integer" or v < 1 then return "must be a whole number of at least 1" end
    end,
    gaps = function(v)
      if type(v) ~= "table" then return "must be a table like { outer = 8, inner = 8 }" end
      for k, n in pairs(v) do
        if k ~= "outer" and k ~= "inner" then return string.format("has unknown field %q (use outer, inner)", tostring(k)) end
        local err = points(n)
        if err then return k .. " " .. err end
      end
    end,
    autoTile = boolean,
    newWindows = oneOf({ "last", "first" }),
    createSpaces = boolean,
    ignoreApps = strings,
    onlyApps = strings,
    floatNonResizable = boolean,
    animationDuration = nonNegative,
    alerts = boolean,
    showOtherHotkeys = boolean,
    defaultKeys = boolean,
    keys = function(v)
      if type(v) ~= "table" then return "must be a table of chord = action" end
    end,
  }
end

-- Resolves one `keys` value into a binding, or returns an error message.
local function binding(value, actions)
  if type(value) == "table" then
    for k in pairs(value) do
      if k ~= "fn" and k ~= "desc" then return nil, string.format("has unknown field %q (use fn, desc)", tostring(k)) end
    end
    if type(value.fn) ~= "function" then return nil, "a table binding needs fn = function() ... end" end
    if value.desc ~= nil and type(value.desc) ~= "string" then return nil, "desc must be a string" end
    return { fn = value.fn, desc = value.desc or "Custom action", group = "custom" }
  end
  if type(value) ~= "string" then
    return nil, 'must be an action string like "swap left", a { fn = ..., desc = ... } table, or false'
  end
  local name, arg = value:match("^%s*(%S+)%s*(.-)%s*$")
  local action = name and actions[name]
  if not action then
    return nil, string.format("unknown action %q (known: %s)", tostring(name or value), table.concat(sortedKeys(actions), ", "))
  end
  if arg == "" then arg = nil end
  if action.args and not contains(action.args, arg) then
    return nil, string.format("%q needs one of: %s", name, table.concat(action.args, ", "))
  end
  if not action.args and arg then return nil, string.format("%q takes no argument", name) end
  return { action = name, arg = arg, desc = action.describe(arg), group = action.group }
end

-- Parses `user`'s key table into `into` (chord id -> binding, or false to unbind).
local function addKeys(into, keys, env, errors, source)
  local entries = {}
  for text, value in pairs(keys) do entries[#entries + 1] = { text = text, value = value } end
  table.sort(entries, function(a, b) return tostring(a.text) < tostring(b.text) end)
  local seen = {}
  for _, e in ipairs(entries) do
    local text, value = e.text, e.value
    local chord, err = env.chords.parse(text, env.isKey)
    if not chord then
      errors[#errors + 1] = source .. ": " .. err
    elseif seen[chord.id] then
      errors[#errors + 1] = string.format("%s: %q and %q are the same chord", source, seen[chord.id], text)
    else
      seen[chord.id] = text
      if value == false then
        into[chord.id] = false
      else
        local b, bindErr = binding(value, env.actions)
        if b then
          b.mods, b.key, b.id = chord.mods, chord.key, chord.id
          into[chord.id] = b
        else
          errors[#errors + 1] = string.format("%s[%q] %s", source, text, bindErr)
        end
      end
    end
  end
end

-- Merges `user` over the defaults and validates the result. `env` provides
-- `chords`, `actions`, `layouts` (names list) and `isKey(name)`. Returns the
-- config, whose `bindings` maps chord ids to resolved bindings, or nil and
-- every problem found, one per line.
function M.build(user, env)
  user = user or {}
  if type(user) ~= "table" then return nil, "the config must be a table" end
  local check = checkers(env.layouts)
  local errors = {}
  local cfg = {}
  for k, v in pairs(M.defaults) do cfg[k] = v end
  cfg.gaps = { outer = M.defaults.gaps.outer, inner = M.defaults.gaps.inner }

  for _, k in ipairs(sortedKeys(user)) do
    local v = user[k]
    if not check[k] then
      errors[#errors + 1] = string.format("unknown setting %q (known: %s)", k, table.concat(sortedKeys(check), ", "))
    else
      local err = check[k](v)
      if err then
        errors[#errors + 1] = k .. " " .. err
      elseif k == "gaps" then
        for side, n in pairs(v) do cfg.gaps[side] = n end
      elseif k ~= "keys" then
        cfg[k] = v
      end
    end
  end

  local bindings = {}
  if cfg.defaultKeys then addKeys(bindings, M.defaults.keys, env, errors, "default keys") end
  if type(user.keys) == "table" then addKeys(bindings, user.keys, env, errors, "keys") end
  cfg.bindings = {}
  for id, b in pairs(bindings) do
    if b then cfg.bindings[id] = b end
  end
  cfg.keys = nil

  if #errors > 0 then return nil, table.concat(errors, "\n") end
  return cfg
end

return M
