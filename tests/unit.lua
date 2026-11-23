-- Unit tests for the pure modules. Run from the repo root: lua tests/unit.lua
local root = arg[0]:match("^(.*)/tests/") or "."
local function load(file) return dofile(root .. "/Retile.spoon/" .. file) end

local layouts = load("layouts.lua")
local chords = load("chords.lua")
local config = load("config.lua")
local actions = load("actions.lua")(layouts)

local KEYS = {}
for _, k in ipairs({ "left", "right", "up", "down", "return", "space", "escape", "tab", "f5", "pad+",
  "[", "]", ",", ".", "=", "-" }) do KEYS[k] = true end
for c in ("abcdefghijklmnopqrstuvwxyz0123456789"):gmatch(".") do KEYS[c] = true end
local function isKey(k) return KEYS[k] == true end
local ENV = { chords = chords, actions = actions, layouts = layouts.names, isKey = isKey }

local failures, count = 0, 0
local function test(name, fn)
  count = count + 1
  local ok, err = pcall(fn)
  if not ok then
    failures = failures + 1
    print("FAIL " .. name .. "\n  " .. tostring(err))
  end
end

local function show(v)
  if type(v) ~= "table" then return string.format("%q", v) end
  local parts, n = {}, 0
  while v[n + 1] ~= nil do
    n = n + 1
    parts[n] = show(v[n])
  end
  local rest = {}
  for k, x in pairs(v) do
    if not (math.type(k) == "integer" and k >= 1 and k <= n) then
      rest[#rest + 1] = (type(k) == "string" and k or "[" .. tostring(k) .. "]") .. "=" .. show(x)
    end
  end
  table.sort(rest)
  return "{" .. table.concat(table.move(rest, 1, #rest, n + 1, parts), ",") .. "}"
end

local function eq(actual, expected, what)
  if show(actual) ~= show(expected) then
    error(string.format("%s: expected %s, got %s", what or "value", show(expected), show(actual)), 2)
  end
end

local function contains(s, part)
  if not tostring(s):find(part, 1, true) then
    error(string.format("expected %q to contain %q", tostring(s), part), 2)
  end
end

local function frame(x, y, w, h) return { x = x, y = y, w = w, h = h } end
local NOGAPS = { ratio = 0.6, masters = 1, gaps = { outer = 0, inner = 0 } }
local LANDSCAPE = frame(0, 0, 1200, 800)

-- layouts --------------------------------------------------------------------

test("every layout tiles its area exactly for 1-9 windows", function()
  for _, name in ipairs(layouts.names) do
    for _, area in ipairs({ LANDSCAPE, frame(100, 50, 800, 1200) }) do
      for n = 1, 9 do
        local frames = layouts.arrange(name, n, area, NOGAPS)
        eq(#frames, n, name .. " count")
        local total = 0
        for i, f in ipairs(frames) do
          assert(f.x >= area.x and f.y >= area.y and f.x + f.w <= area.x + area.w
            and f.y + f.h <= area.y + area.h, name .. " frame outside area")
          total = total + f.w * f.h
          for j = i + 1, n do
            local g = frames[j]
            local overlaps = f.x < g.x + g.w and g.x < f.x + f.w and f.y < g.y + g.h and g.y < f.y + f.h
            assert(name == "monocle" or not overlaps, string.format("%s n=%d: %d overlaps %d", name, n, i, j))
          end
        end
        if name ~= "monocle" then eq(total, area.w * area.h, name .. " n=" .. n .. " covered area") end
      end
    end
  end
end)

test("grid puts floor(sqrt(n)) rows with the extra windows first", function()
  eq(layouts.arrange("grid", 5, LANDSCAPE, NOGAPS), {
    frame(0, 0, 400, 400), frame(400, 0, 400, 400), frame(800, 0, 400, 400),
    frame(0, 400, 600, 400), frame(600, 400, 600, 400),
  })
  -- Portrait screens get columns instead of rows.
  eq(layouts.arrange("grid", 3, frame(0, 0, 800, 1200), NOGAPS), {
    frame(0, 0, 800, 400), frame(0, 400, 800, 400), frame(0, 800, 800, 400),
  })
end)

test("tall and wide honour ratio and masters", function()
  eq(layouts.arrange("tall", 3, LANDSCAPE, NOGAPS), {
    frame(0, 0, 720, 800), frame(720, 0, 480, 400), frame(720, 400, 480, 400),
  })
  eq(layouts.arrange("tall", 3, LANDSCAPE, { ratio = 0.5, masters = 2, gaps = NOGAPS.gaps }), {
    frame(0, 0, 600, 400), frame(0, 400, 600, 400), frame(600, 0, 600, 800),
  })
  eq(layouts.arrange("tall", 2, LANDSCAPE, { ratio = 0.5, masters = 3, gaps = NOGAPS.gaps }), {
    frame(0, 0, 1200, 400), frame(0, 400, 1200, 400),
  })
  eq(layouts.arrange("wide", 3, LANDSCAPE, NOGAPS), {
    frame(0, 0, 1200, 480), frame(0, 480, 600, 320), frame(600, 480, 600, 320),
  })
end)

test("spiral alternates sides, first split by ratio", function()
  eq(layouts.arrange("spiral", 4, LANDSCAPE, NOGAPS), {
    frame(0, 0, 720, 800), frame(720, 0, 480, 400), frame(720, 400, 240, 400), frame(960, 400, 240, 400),
  })
end)

test("gaps: outer at the screen edges, inner between windows", function()
  local opts = { ratio = 0.6, masters = 1, gaps = { outer = 8, inner = 8 } }
  eq(layouts.arrange("columns", 2, frame(0, 25, 1200, 775), opts), {
    frame(8, 33, 588, 759), frame(604, 33, 588, 759),
  })
  opts.gaps = { outer = 0, inner = 10 }
  local f = layouts.arrange("rows", 2, frame(0, 0, 100, 100), opts)
  eq(f, { frame(0, 0, 100, 45), frame(0, 55, 100, 45) })
  eq(layouts.arrange("grid", 0, LANDSCAPE, opts), {})
end)

test("neighbor follows the layout's geometry", function()
  local tall = layouts.arrange("tall", 4, LANDSCAPE, NOGAPS) -- main + 3 stacked
  eq(layouts.neighbor(tall, 1, "right"), 3, "main -> middle of stack")
  eq(layouts.neighbor(tall, 2, "left"), 1)
  eq(layouts.neighbor(tall, 2, "down"), 3)
  eq(layouts.neighbor(tall, 2, "up"), nil)
  eq(layouts.neighbor(tall, 1, "left"), nil)
  local grid = layouts.arrange("grid", 5, LANDSCAPE, { ratio = 0.6, masters = 1, gaps = { outer = 8, inner = 8 } })
  eq(layouts.neighbor(grid, 4, "up"), 1, "bottom-left up")
  eq(layouts.neighbor(grid, 5, "up"), 3, "bottom-right up")
  eq(layouts.neighbor(grid, 2, "down"), 4, "top-middle down: an exact tie goes to the first")
  eq(layouts.neighbor(grid, 3, "left"), 2)
  eq(layouts.neighbor(grid, 3, "right"), nil)
  eq(layouts.neighbor(layouts.arrange("monocle", 3, LANDSCAPE, NOGAPS), 1, "right"), nil)
  -- Below the first: 2 is mostly under it, 3's centre is closer.
  local frames = { frame(0, 0, 100, 100), frame(40, 110, 200, 100), frame(0, 110, 30, 100) }
  eq(layouts.neighbor(frames, 1, "down"), 2, "bigger overlap beats closer centre")
  eq(layouts.neighbor({ frame(100, 0, 30, 30), frame(140, 0, 30, 30) }, 1, "left"), nil, "a window to the right isn't left")
  -- Snapped, 5 ends 9pt above 6 and the diagonal main window 8pt.
  local air = layouts.arrange("tall", 8, frame(0, 25, 1280, 775), { ratio = 0.6, masters = 2, gaps = { outer = 8, inner = 8 } })
  eq(layouts.neighbor(air, 6, "up"), 5, "a gap widened by snapping still counts")
end)

test("reconcile keeps known order and places new windows", function()
  eq(layouts.reconcile({ 1, 2, 3 }, { 3, 1, 4, 5 }, "last"), { 1, 3, 4, 5 })
  eq(layouts.reconcile({ 1, 2, 3 }, { 3, 1, 4, 5 }, "first"), { 4, 5, 1, 3 })
  eq(layouts.reconcile({}, { 7, 8 }, "last"), { 7, 8 })
  eq(layouts.reconcile({ 1, 1, 2 }, { 2, 1 }, "last"), { 1, 2 })
end)

test("reconcile puts incoming windows last", function()
  eq(layouts.reconcile({ 1, 2, 3 }, { 1, 2, 3 }, "first", { 1 }), { 2, 3, 1 })
  eq(layouts.reconcile({}, { 9 }, "last", { 9 }), { 9 })
  eq(layouts.reconcile({ 1, 2 }, { 1, 2, 9 }, "first", { 9, 7, 9 }), { 1, 2, 9 })
  eq(layouts.reconcile({ 1, 2, 3 }, { 1, 2, 3 }, "last", { 3, 1 }), { 2, 3, 1 })
end)

-- chords ---------------------------------------------------------------------

test("parse normalises modifier order and aliases", function()
  local c = chords.parse("cmd+shift+left", isKey)
  eq(c, { mods = { "shift", "cmd" }, key = "left", id = "shift+cmd+left" })
  eq(chords.parse("Shift+Command+LEFT", isKey).id, "shift+cmd+left")
  eq(chords.parse("⌥+⌃+1", isKey).id, "ctrl+alt+1")
  eq(chords.parse("option+control+1", isKey).id, "ctrl+alt+1")
  eq(chords.parse("f5", isKey), { mods = {}, key = "f5", id = "f5" })
  eq(chords.parse("ctrl+pad+", isKey).id, "ctrl+pad+")
  eq(chords.parse("cmd+=", isKey).id, "cmd+=")
  eq(chords.parse(" Cmd + Left ", isKey).id, "cmd+left")
end)

test("parse rejects bad chords with a useful message", function()
  local c, err = chords.parse("cmd+cmd+x", isKey)
  eq(c, nil)
  contains(err, "repeats cmd")
  c, err = chords.parse("cmd+leftt", isKey)
  eq(c, nil)
  contains(err, 'unknown key "leftt"')
  contains(select(2, chords.parse("hyper+x", isKey)), "unknown key")
  contains(select(2, chords.parse(5, isKey)), "must be a string, got 5")
end)

test("fromHotkeyIndex inverts hs.hotkey indexes", function()
  eq(chords.fromHotkeyIndex("⌘⇧LEFT").id, "shift+cmd+left")
  eq(chords.fromHotkeyIndex("⌘⌃⌥⇧A").id, "ctrl+alt+shift+cmd+a")
  eq(chords.fromHotkeyIndex("✧A").id, "ctrl+alt+shift+cmd+a")
  eq(chords.fromHotkeyIndex("⌃O"), { mods = { "ctrl" }, key = "o", id = "ctrl+o" })
  eq(chords.fromHotkeyIndex("F5").id, "f5")
end)

-- config ---------------------------------------------------------------------

test("defaults build and bind the documented keys", function()
  local cfg = assert(config.build(nil, ENV))
  local n = 0
  for _ in pairs(cfg.bindings) do n = n + 1 end
  local expected = 0
  for _ in pairs(config.defaults.keys) do expected = expected + 1 end
  eq(n, expected, "binding count")
  local b = cfg.bindings["shift+cmd+left"]
  eq({ b.action, b.arg, b.group, b.desc }, { "moveToSpace", "left", "workspace", "Move window to the previous space" })
  eq(cfg.bindings["cmd+left"].desc, "Move window left in the layout")
  eq(cfg.bindings["ctrl+alt+left"].desc, "Focus the window to the left")
  eq(cfg.bindings["shift+cmd+up"].desc, "Move window to the display above")
  eq(cfg.gaps, { outer = 8, inner = 8 })
  eq(cfg.keys, nil)
end)

test("user keys override defaults under any spelling, false unbinds", function()
  local cfg = assert(config.build({
    keys = { ["Shift+Cmd+Left"] = "focus left", ["cmd+y"] = false, ["alt+k"] = "keymap" },
  }, ENV))
  eq(cfg.bindings["shift+cmd+left"].action, "focus")
  eq(cfg.bindings["cmd+y"], nil)
  eq(cfg.bindings["alt+k"].action, "keymap")
end)

test("defaultKeys = false keeps only the user's keys", function()
  local fn = function() end
  local cfg = assert(config.build({ defaultKeys = false, keys = { ["alt+k"] = { fn = fn, desc = "Hi" } } }, ENV))
  local ids = {}
  for id in pairs(cfg.bindings) do ids[#ids + 1] = id end
  eq(ids, { "alt+k" })
  eq({ cfg.bindings["alt+k"].fn == fn, cfg.bindings["alt+k"].desc, cfg.bindings["alt+k"].group }, { true, "Hi", "custom" })
end)

test("partial gaps merge with the defaults, which stay intact", function()
  eq(assert(config.build({ gaps = { inner = 0 } }, ENV)).gaps, { outer = 8, inner = 0 })
  eq(assert(config.build(nil, ENV)).gaps, { outer = 8, inner = 8 })
end)

test("a table binding without desc is a described custom action", function()
  local b = assert(config.build({ keys = { ["alt+k"] = { fn = function() end } } }, ENV)).bindings["alt+k"]
  eq({ b.desc, b.group }, { "Custom action", "custom" })
end)

test("invalid settings are all reported", function()
  local cases = {
    { { gap = 4 }, 'unknown setting "gap"' },
    { { gaps = { inner = -1 } }, "gaps inner must be a whole number of at least 0" },
    { { gaps = { inner = 7.5 } }, "gaps inner must be a whole number" },
    { { gaps = { outer = math.huge } }, "gaps outer must be a whole number" },
    { { gaps = { [{}] = 1 } }, "gaps has unknown field" },
    { { gaps = { top = 4 } }, 'unknown field "top"' },
    { { gaps = 4 }, "gaps must be a table" },
    { { ratio = 0.95 }, "ratio must be a number from 0.1 to 0.9" },
    { { ratio = math.huge }, "ratio must be" },
    { { ratio = 0.05 }, "ratio must be a number from 0.1 to 0.9" },
    { { ratioStep = 0 }, "ratioStep must be a number between 0 and 1" },
    { { ratioStep = 1 }, "ratioStep must be a number between 0 and 1" },
    { { animationDuration = -1 }, "animationDuration must be a number of at least 0" },
    { { animationDuration = math.huge }, "animationDuration must be a number of at least 0" },
    { { ignoreApps = { safari = "Safari" } }, "ignoreApps must be a list" },
    { { masters = 1.5 }, "masters must be a whole number" },
    { { masters = 0 }, "masters must be a whole number" },
    { { layout = "bsp" }, "layout must be one of: grid, tall" },
    { { layouts = {} }, "layouts must be a non-empty list" },
    { { layouts = { "grid", "bsp" } }, 'contains unknown layout "bsp"' },
    { { newWindows = "middle" }, "newWindows must be one of: last, first" },
    { { onlyApps = "Safari" }, "onlyApps must be a list" },
    { { autoTile = "yes" }, "autoTile must be true or false" },
    { { keys = { ["cmd+y"] = "swap" } }, '"swap" needs one of: left, right, up, down' },
    { { keys = { ["cmd+y"] = "swap sideways" } }, '"swap" needs one of' },
    { { keys = { ["cmd+y"] = "keymap now" } }, '"keymap" takes no argument' },
    { { keys = { ["cmd+y"] = "swap left right" } }, '"swap" needs one of' },
    { { keys = { ["cmd+y"] = "swapp left" } }, 'unknown action "swapp"' },
    { { keys = { ["cmd+y"] = 3 } }, "must be an action string" },
    { { keys = { ["cmd+y"] = { desc = "x" } } }, "needs fn = function" },
    { { keys = { ["cmd+y"] = { fn = print, descr = "x" } } }, 'has unknown field "descr" (use fn, desc)' },
    { { keys = { ["cmd+y"] = { fn = print, desc = 1 } } }, "desc must be a string" },
    { { keys = { "cmd+y" } }, "a key chord must be a string, got 1" },
    { { keys = { ["cmd+shift+x"] = "retile", ["shift+cmd+x"] = "keymap" } }, "are the same chord" },
    { { keys = { ["cmd+nope"] = "retile" } }, 'unknown key "nope"' },
    { "nope", "must be a table" },
  }
  for _, case in ipairs(cases) do
    local cfg, err = config.build(case[1], ENV)
    eq(cfg, nil, "config for " .. case[2])
    contains(err, case[2])
  end
  local _, err = config.build({ gap = 1, ratio = 2 }, ENV)
  contains(err, 'unknown setting "gap"')
  contains(err, "\nratio must be")
end)

test("every action describes every argument", function()
  for name, action in pairs(actions) do
    for _, arg in ipairs(action.args or { false }) do
      local desc = action.describe(arg or nil)
      assert(type(desc) == "string" and #desc > 0, name .. " " .. tostring(arg))
    end
  end
  eq(actions.layout.describe("tall"), "Layout: tall - main column with a stack beside it")
  eq(actions.resize.describe("grow"), "Grow the main area")
  eq(actions.resize.describe("shrink"), "Shrink the main area")
  eq(actions.cycleLayout.describe("prev"), "Switch to the previous layout")
  eq(actions.masters.describe("fewer"), "Put fewer windows in the main area")
end)

print(string.format("%d/%d tests passed", count - failures, count))
os.exit(failures == 0 and 0 or 1)
