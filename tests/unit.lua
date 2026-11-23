-- Unit tests for the pure modules. Run from the repo root: lua tests/unit.lua
local root = arg[0]:match("^(.*)/tests/") or "."
local function load(file) return dofile(root .. "/Retile.spoon/" .. file) end

local layouts = load("layouts.lua")
local chords = load("chords.lua")
local config = load("config.lua")
local actions = load("actions.lua")(layouts)
local preview = load("preview.lua")(layouts)

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
  local monocle = layouts.arrange("monocle", 3, LANDSCAPE, NOGAPS)
  eq(layouts.neighbor(monocle, 1, "right"), nil)
  eq({ layouts.neighbor(monocle, 1, "right", "monocle"), layouts.neighbor(monocle, 1, "up", "monocle") }, { 2, 3 },
    "monocle steps through the order, wrapping")
  eq(layouts.neighbor({ LANDSCAPE }, 1, "left", "monocle"), nil, "a lone monocle window has no neighbour")
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

test("layout settings step within their bounds", function()
  local list = { "grid", "tall", "monocle" }
  eq({ layouts.cycle(list, "tall", 1), layouts.cycle(list, "monocle", 1), layouts.cycle(list, "grid", -1) },
    { "monocle", "grid", "monocle" })
  eq({ layouts.cycle(list, "rows", 1), layouts.cycle(list, "rows", -1) }, { "grid", "monocle" }, "from outside the list")
  eq({ layouts.stepRatio(0.6, 1, 0.05), layouts.stepRatio(0.88, 1, 0.05), layouts.stepRatio(0.12, -1, 0.05) },
    { 0.65, 0.9, 0.1 })
  local r = 0.6
  for _ = 1, 3 do r = layouts.stepRatio(r, 1, 0.1) end
  eq(r, 0.9, "steps don't drift")
  eq({ layouts.stepMasters(1, 1, 3), layouts.stepMasters(3, 1, 3), layouts.stepMasters(1, -1, 3), layouts.stepMasters(5, -1, 2) },
    { 2, 3, 1, 2 })
end)

-- preview --------------------------------------------------------------------

local CFG = assert(config.build(nil, ENV))
local SCREEN = { frame = frame(0, 25, 1200, 775), full = frame(0, 0, 1200, 800), name = "Studio Display" }
local function tile(layout, n, area, extra)
  local opts = { ratio = 0.6, masters = 1, gaps = CFG.gaps }
  for k, v in pairs(extra or {}) do opts[k] = v end
  return layouts.arrange(layout, n, area or SCREEN.frame, opts)
end
local function settings(layout, windows, paused)
  return { layout = layout, ratio = 0.6, masters = 1, paused = paused or false, count = windows }
end
-- Three columns, the first focused; spaces: user, here, full-screen app;
-- a display above with one window.
local UPPER = { full = frame(0, -900, 1600, 900), frame = frame(0, -875, 1600, 875) }
local function scene(changes)
  local s = {
    layout = "columns", ratio = 0.6, masters = 1, paused = false,
    screen = SCREEN, windows = tile("columns", 3), focus = 1,
    spaces = {
      index = 2, kinds = { "user", "user", "other" },
      left = { user = true, state = settings("rows", 2) }, right = { user = false, state = settings("grid", 0) },
    },
    displays = {
      up = { full = UPPER.full, frame = UPPER.frame, user = true, state = settings("tall"), windows = tile("tall", 1, UPPER.frame) },
    },
  }
  for k, v in pairs(changes or {}) do s[k] = v end
  return s
end
local function build(action, arg, s, cfg) return preview.build(s or scene(), action, arg, cfg or CFG) end
-- To a hundredth of a point, which also makes 480 and 480.0 compare equal.
local function near(r)
  local t = {}
  for k, v in pairs(r) do t[k] = string.format("%.2f", v) end
  return t
end
local function targets(spec)
  local list = {}
  for i, w in ipairs(spec.windows) do list[i] = w.to end
  return list
end

test("every action has a preview", function()
  for name, action in pairs(actions) do
    for _, arg in ipairs(action.args or { false }) do
      local spec = build(name, arg or nil)
      assert(spec and #spec.windows > 0 and spec.view, name .. " " .. tostring(arg))
    end
  end
end)

test("swap previews trade places, or bump at the edge", function()
  local cols = tile("columns", 3)
  local spec = build("swap", "right")
  eq(targets(spec), { cols[2], cols[1], cols[3] })
  eq(spec.focus, { from = 1, to = 1 })
  eq({ spec.bump, spec.note, spec.example }, {})
  spec = build("swap", "right", scene({ focus = 3 }))
  eq(spec.bump, { window = 3, dir = "right" })
  eq(spec.note, "No window to the right")
  eq(targets(spec), cols, "nothing moves")
  eq(build("promote", nil, scene({ focus = 3 })).windows[3].to, cols[1], "promote swaps with the main window")
  eq(build("promote", nil).windows[1].to, cols[2], "the main window swaps with the next")
  spec = build("swap", "right", scene({ layout = "monocle", windows = tile("monocle", 3) }))
  eq(spec.note, "In monocle this only changes the window order")
end)

test("focus previews move the focus, or bump it at the edge", function()
  local spec = build("focus", "right", scene({ focus = 2 }))
  eq(spec.focus, { from = 2, to = 3 })
  spec = build("focus", "left")
  eq({ spec.focus, spec.bump, spec.note }, { { from = 1, to = 1 }, { dir = "left" }, "No window to the left" })
  eq(build("focus", "left", scene({ layout = "monocle", windows = tile("monocle", 3) })).focus, { from = 1, to = 3 })
end)

test("keys acting in the layout tile out-of-place windows first", function()
  local s = scene({ focus = 2 })
  s.windows = { frame(100, 100, 300, 300), s.windows[2], s.windows[3] }
  eq(build("focus", "right", s).windows[1].to, tile("columns", 3)[1])
  eq(build("retile", nil, s).windows[1], { from = frame(100, 100, 300, 300), to = tile("columns", 3)[1] })
  eq(build("retile").note, "Every window is in place already")
  local narrow = scene()
  local f = narrow.windows[1]
  narrow.windows[1] = frame(f.x, f.y, f.w - 40, f.h)
  eq(build("retile", nil, narrow).note, nil, "a window only too narrow is out of place")
end)

test("layout previews re-tile with the new settings and name them", function()
  local spec = build("layout", "tall")
  eq({ targets(spec), spec.label, spec.note }, { tile("tall", 3), "tall" })
  eq(build("layout", "columns").note, "Already the columns layout")
  local two = scene({ windows = tile("columns", 2) })
  eq(build("layout", "grid", two).note, "With 2 windows, grid looks the same as columns")
  local cfg = assert(config.build({ layouts = { "columns", "spiral", "tall" } }, ENV))
  eq(build("cycleLayout", "next", nil, cfg).label, "spiral", "next in the configured cycle")
  eq(build("cycleLayout", "prev", nil, cfg).label, "tall")

  local tall = scene({ layout = "tall", windows = tile("tall", 3) })
  spec = build("resize", "grow", tall)
  eq({ targets(spec), spec.label }, { tile("tall", 3, nil, { ratio = 0.65 }), "Main area 65%" })
  eq(build("resize", "grow", scene({ layout = "tall", ratio = 0.9, windows = tile("tall", 3, nil, { ratio = 0.9 }) })).note,
    "The main area is at its largest")
  eq(build("resize", "shrink").note, "The columns layout has no main area")
  spec = build("masters", "more", tall)
  eq({ targets(spec), spec.label }, { tile("tall", 3, nil, { masters = 2 }), "2 main windows" })
  eq(build("masters", "fewer", tall).note, "The main area has just one window")
  eq(build("masters", "more", scene({ layout = "tall", masters = 3, windows = tile("tall", 3, nil, { masters = 3 }) })).note,
    "Every window is in the main area")
end)

test("float previews: the window stays, the layout closes up or takes it in", function()
  local spec = build("toggleFloat", nil, scene({ focus = 2 }))
  local two = tile("columns", 2)
  eq(targets(spec), { two[1], tile("columns", 3)[2], two[2] })
  eq({ spec.windows[2].floating, spec.label }, { "after", "Floating" })

  local floated = scene({ focus = false, windows = tile("columns", 2), loose = { frame = frame(300, 200, 400, 300), floated = true, managed = true } })
  spec = build("toggleFloat", nil, floated)
  eq({ targets(spec), spec.windows[3].floating, spec.focus }, { tile("columns", 3), "before", { from = 3, to = 3 } })
  local first = assert(config.build({ newWindows = "first" }, ENV))
  local cols = tile("columns", 3)
  eq(targets(build("toggleFloat", nil, floated, first)), { cols[2], cols[3], cols[1] }, "joins first with newWindows = first")

  floated.loose.floated = false
  spec = build("toggleFloat", nil, floated)
  eq({ spec.note, targets(spec)[3] }, { "This window isn't tiled", frame(300, 200, 400, 300) })
end)

test("pause previews: resuming tiles, pausing leaves a new window be", function()
  local s = scene({ paused = true })
  s.windows = { frame(10, 40, 500, 500), s.windows[2], s.windows[3] }
  local spec = build("togglePause", nil, s)
  eq({ spec.paused, targets(spec) }, { { from = true, to = false }, tile("columns", 3) })
  spec = build("togglePause")
  eq({ spec.paused, #spec.windows, spec.windows[4].from, spec.focus }, { { from = false, to = true }, 4, nil, { from = 1, to = 4 } })
  eq(near(spec.windows[4].to), near(frame(360, 195.5, 480, 348.75)), "a window opening mid-screen")
end)

test("space previews pan to the space beside, carrying the window", function()
  local s = scene({ focus = 2 })
  local spec = build("moveToSpace", "left", s)
  local dx = -1200 * 1.06
  local there = { x = SCREEN.frame.x + dx, y = SCREEN.frame.y, w = SCREEN.frame.w, h = SCREEN.frame.h }
  local before, after = tile("rows", 2, there), tile("rows", 3, there)
  eq({ spec.pan, spec.dots, #spec.desktops }, { { x = dx, y = 0 }, { kinds = { "user", "user", "other" }, from = 2, to = 1 }, 2 })
  local cols = tile("columns", 3)
  eq(spec.windows[2], { from = cols[2], via = { x = cols[2].x + dx, y = cols[2].y, w = cols[2].w, h = cols[2].h }, to = after[3] })
  eq({ spec.windows[1].to, spec.windows[3].to }, { cols[1], cols[3] }, "the space left behind is re-tiled only when shown")
  eq({ spec.windows[4], spec.windows[5] }, { { from = before[1], to = after[1] }, { from = before[2], to = after[2] } })

  spec = build("moveToSpace", "right", s)
  eq({ spec.bump, spec.note, spec.pan }, { { window = 2, dir = "right" }, "The space to the right is a full-screen app" })
  s.spaces = { index = 2, kinds = { "user", "user" }, left = s.spaces.left }
  spec = build("moveToSpace", "right", s)
  eq({ spec.dots, spec.label }, { { kinds = { "user", "user", "user" }, from = 2, to = 3, added = true }, "New space" })
  eq(spec.windows[2].to, tile("grid", 1, { x = 1272, y = 25, w = 1200, h = 775 })[1], "alone on the new space")
  eq(build("moveToSpace", "right", s, assert(config.build({ createSpaces = false }, ENV))).note, "No space to the right")
  eq(build("moveToSpace", "left", scene({ spaces = { index = 1, kinds = { "user" } } })).note, "No space to the left")
  spec = build("moveToSpace", "right", scene({ spaces = { kinds = {} } }))
  eq({ spec.example, spec.note }, { true, "macOS isn't listing this display's spaces" })

  local loose = scene({ focus = false, loose = { frame = frame(300, 200, 400, 300), floated = true, managed = true } })
  spec = build("moveToSpace", "left", loose)
  eq(spec.windows[4].to, frame(300 + dx, 200, 400, 300), "a floating window keeps its place")
  eq(#spec.windows, 6)
end)

test("display previews move the window across and re-tile both", function()
  local spec = build("moveToScreen", "up", scene({ focus = 2 }))
  eq({ spec.view, spec.desktops }, { frame(0, -900, 1600, 1700), { SCREEN.full, UPPER.full } })
  local two, up = tile("columns", 2), tile("tall", 2, UPPER.frame)
  eq(targets(spec), { two[1], up[2], two[2], up[1] })
  eq(build("moveToScreen", "down").note, "No display below")
  local s = scene()
  s.displays.up.user = false
  eq(build("moveToScreen", "up", s).note, "The display above is showing a full-screen app")
  s.displays.up.user, s.displays.up.state.paused = true, true
  local cols = tile("columns", 3)
  eq(near(build("moveToScreen", "up", s).windows[1].to), near({
    x = (cols[1].x - SCREEN.frame.x) * 1600 / 1200, y = UPPER.frame.y + (cols[1].y - SCREEN.frame.y) * 875 / 775,
    w = cols[1].w * 1600 / 1200, h = cols[1].h * 875 / 775,
  }), "a paused display takes it where it falls")
end)

test("without anything to act on, previews show an example", function()
  local spec = build("swap", "left", scene({ focus = false }))
  eq({ spec.example, spec.note, spec.focus.from ~= nil }, { true, "No tiled window is focused", true })
  local ex = tile("columns", 4)
  eq(spec.windows[spec.focus.from].to, ex[spec.focus.from - 1], "an example window that can move left")
  spec = build("focus", "left", scene({ focus = false }))
  eq({ spec.example, spec.focus.to }, { true, spec.focus.from - 1 }, "an example window with a window to its left")
  eq(build("layout", "tall", scene({ paused = true })).note, "Tiling is paused on this space")
  spec = build("layout", "columns", scene({ windows = {}, focus = false }))
  eq({ spec.example, spec.note, spec.label }, { true, "No windows are tiled here", "columns" },
    "the example starts from another layout when the scene's own wouldn't change")
  spec = build("retile", nil, scene({ windows = {}, focus = false }))
  assert(not spec.windows[1].from or spec.windows[1].from.w ~= spec.windows[1].to.w, "an out-of-place example window")
  eq(build("moveToScreen", "up", scene({ focus = false, loose = { frame = SCREEN.frame, managed = false } })).note,
    "Retile doesn't manage the focused window")
end)

test("describe counts windows and user spaces", function()
  eq(preview.describe(scene()), "columns layout · 3 windows · space 2 of 2 · Studio Display")
  eq(preview.describe(scene({ paused = true, windows = { SCREEN.frame }, spaces = { index = 3, kinds = { "user", "other", "other" } } })),
    "tiling paused · 1 window · Studio Display")
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
