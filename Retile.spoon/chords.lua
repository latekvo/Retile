-- Key chords: "cmd+shift+left" <-> { mods = { "shift", "cmd" }, key = "left" }.
local M = {}

-- Canonical (and macOS display) modifier order.
M.ORDER = { "ctrl", "alt", "shift", "cmd" }

local ALIASES = {
  ctrl = "ctrl", control = "ctrl", ["⌃"] = "ctrl",
  alt = "alt", opt = "alt", option = "alt", ["⌥"] = "alt",
  shift = "shift", ["⇧"] = "shift",
  cmd = "cmd", command = "cmd", ["⌘"] = "cmd",
}

local GLYPHS = { ["⌃"] = "ctrl", ["⌥"] = "alt", ["⇧"] = "shift", ["⌘"] = "cmd" }

local function chord(present, key)
  local mods = {}
  for _, m in ipairs(M.ORDER) do
    if present[m] then mods[#mods + 1] = m end
  end
  local id = #mods > 0 and table.concat(mods, "+") .. "+" .. key or key
  return { mods = mods, key = key, id = id }
end

-- Parses "mod+mod+key" (any modifier order or alias, any case). `isKey`
-- decides which key names exist. The key itself may contain "+" ("pad+").
function M.parse(text, isKey)
  if type(text) ~= "string" then return nil, "a key chord must be a string, got " .. tostring(text) end
  local present, rest = {}, text:gsub("%s+", "")
  while true do
    local word, tail = rest:match("^([^+]+)%+(.+)$")
    local mod = word and ALIASES[word:lower()]
    if not mod then break end
    if present[mod] then return nil, string.format("%q repeats %s", text, mod) end
    present[mod] = true
    rest = tail
  end
  local key = rest:lower()
  if not isKey(key) then return nil, string.format("%q: unknown key %q", text, rest) end
  return chord(present, key)
end

-- Inverse of hs.hotkey's index strings ("⌘⇧LEFT", "✧A" for all four).
function M.fromHotkeyIndex(idx)
  local present = {}
  if idx:sub(1, 3) == "✧" then
    for _, m in ipairs(M.ORDER) do present[m] = true end
    idx = idx:sub(4)
  end
  while true do
    local mod = GLYPHS[idx:sub(1, 3)]
    if not mod then break end
    present[mod] = true
    idx = idx:sub(4)
  end
  return chord(present, idx:lower())
end

return M
