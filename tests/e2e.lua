-- End-to-end test, run inside Hammerspoon by tests/e2e.sh. Presses Retile's
-- real hotkeys against RetileFixture's windows; onlyApps keeps every other
-- window untouched. Waits for the user to be idle first, and puts spaces,
-- focus and the mouse back afterwards.
local root = debug.getinfo(1, "S").source:match("^@(.*)/tests/e2e%.lua$")
local RESULT = root .. "/build/e2e.out"
local SETTINGS = { onlyApps = { "RetileFixture" }, alerts = false, layout = "columns" }

local layouts = dofile(root .. "/Retile.spoon/layouts.lua")
local lines, failures = {}, 0
local state = {}

local function log(fmt, ...) lines[#lines + 1] = string.format(fmt, ...) end
local function check(ok, what, detail)
  if ok then
    log("ok   %s", what)
  else
    failures = failures + 1
    log("FAIL %s%s", what, detail and (" - " .. tostring(detail)) or "")
  end
  return ok
end
local function now() return hs.timer.secondsSinceEpoch() end
local function wait(s) coroutine.applicationYield(s) end
local function waitFor(fn, timeout)
  local deadline = now() + (timeout or 3)
  repeat
    local v = fn()
    if v then return v end
    wait(0.05)
  until now() > deadline
  return fn()
end
local function rect(f) return string.format("[%d,%d %dx%d]", f.x, f.y, f.w, f.h) end
local function sameRect(a, b)
  return math.abs(a.x - b.x) <= 1 and math.abs(a.y - b.y) <= 1 and math.abs(a.w - b.w) <= 1 and math.abs(a.h - b.h) <= 1
end
local function contains(list, v)
  for _, x in ipairs(list or {}) do
    if x == v then return true end
  end
  return false
end
-- Hardware arrow keys carry fn, and hotkeys on arrows only match with it.
local ARROWS = { left = true, right = true, up = true, down = true }
local function press(mods, key)
  if not ARROWS[key] then return hs.eventtap.keyStroke(mods, key, 20000) end
  local withFn = { "fn", table.unpack(mods) }
  hs.eventtap.event.newKeyEvent(withFn, key, true):post()
  hs.timer.usleep(20000)
  hs.eventtap.event.newKeyEvent(withFn, key, false):post()
end

-- Runs `code` in the webview and returns its JSON result decoded, or nil and
-- the reason.
local function js(view, code)
  local result, err, done
  view:evaluateJavaScript("(() => { try { return JSON.stringify({ ok: " .. code .. " }) }"
    .. " catch (e) { return JSON.stringify({ error: String(e) }) } })()", function(r, e)
    result, err, done = r, e, true
  end)
  if not waitFor(function() return done end, 2) then return nil, "no reply" end
  if not result then return nil, hs.inspect(err) end
  local reply = hs.json.decode(result)
  return reply.ok, reply.error
end

local fixture, Retile

local function fixtureWindows()
  local app = hs.application.get(fixture:pid())
  local wins = {}
  for _, w in ipairs(app and app:allWindows() or {}) do
    if w:title():match("^Fixture") then wins[#wins + 1] = w end
  end
  return wins
end

local function windowNamed(title)
  local app = hs.application.get(fixture:pid())
  for _, w in ipairs(app and app:allWindows() or {}) do
    if w:title() == title then return w end
  end
end

-- The frames Retile should produce, computed when called: the usable screen
-- area changes, e.g. when the Dock shrinks to fit another app's icon.
-- (A held hs.screen keeps its old frame, so it is looked up each time.)
local function expected(name, n, screen, extra)
  local opts = { ratio = 0.6, masters = 1, gaps = { outer = 8, inner = 8 } }
  for k, v in pairs(extra or {}) do opts[k] = v end
  local uuid = screen:getUUID()
  return function() return layouts.arrange(name, n, hs.screen.find(uuid):frame(), opts) end
end

-- Waits until `wins` sit exactly on `frames()` (same order), and checks it.
local function expectTiled(what, wins, frames)
  local ok = waitFor(function()
    for i, w in ipairs(wins) do
      if not sameRect(w:frame(), frames()[i]) then return false end
    end
    return true
  end, 3)
  local detail = {}
  for i, w in ipairs(wins) do detail[#detail + 1] = w:title() .. "=" .. rect(w:frame()) .. " want " .. rect(frames()[i]) end
  check(ok, what, not ok and table.concat(detail, "; ") or nil)
end

-- Windows sorted left to right, then top to bottom: their slots in columns.
local function bySlot(wins)
  table.sort(wins, function(a, b)
    local fa, fb = a:frame(), b:frame()
    if fa.x ~= fb.x then return fa.x < fb.x end
    return fa.y < fb.y
  end)
  return wins
end

local function focus(win)
  win:focus()
  return check(waitFor(function()
    local f = hs.window.focusedWindow()
    return f and f:id() == win:id()
  end, 2), "focus " .. win:title())
end

local function goToSpace(screen, space)
  if hs.spaces.activeSpaceOnScreen(screen) == space then return true end
  hs.spaces.gotoSpace(space)
  return waitFor(function() return hs.spaces.activeSpaceOnScreen(screen) == space end, 5)
end

local function run()
  local deadline = now() + 180
  while hs.host.idleTime() < 15 and now() < deadline do wait(1) end
  log("user idle for %.0fs", hs.host.idleTime())

  state.mouse = hs.mouse.absolutePosition()
  state.focused = hs.window.focusedWindow()
  state.spaces = {}
  for _, s in ipairs(hs.screen.allScreens()) do state.spaces[s:getUUID()] = hs.spaces.activeSpaceOnScreen(s) end
  if spoon and spoon.Retile and spoon.Retile.tiler then
    state.reload = true
    spoon.Retile:stop()
  end

  -- macOS picks the space for a background app's windows, possibly a hidden
  -- one, where accessibility can't see them: find it and show it. (Titles
  -- need Screen Recording access, so windows are told apart by size.)
  fixture = hs.task.new(root .. "/build/RetileFixture", nil, { "3" }):start()
  local space = waitFor(function()
    local ok, ids = hs.osascript.javascript(string.format([[
      ObjC.import("CoreGraphics");
      ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionAll, 0)))
        .filter(w => w.kCGWindowOwnerPID === %d && w.kCGWindowLayer === 0 && w.kCGWindowBounds.Height > 100)
        .map(w => w.kCGWindowNumber)]], fixture:pid()))
    if ok and #ids == 4 then return (hs.spaces.windowSpaces(ids[1]) or {})[1] end
  end, 5)
  assert(space, "fixture windows did not appear")
  local screen
  for uuid, list in pairs(hs.spaces.allSpaces()) do
    if contains(list, space) then screen = hs.screen.find(uuid) end
  end
  assert(goToSpace(screen, space), "could not show the fixture's space")
  assert(waitFor(function() return #fixtureWindows() == 3 and windowNamed("Fixed") end, 3), "fixture windows not visible")
  wait(0.3)
  log("testing on space %d of %s", space, screen:name())
  local fixed = windowNamed("Fixed")
  local fixedFrame = fixed:frame()

  Retile = dofile(root .. "/Retile.spoon/init.lua")
  Retile:start(SETTINGS)
  check(Retile.tiler ~= nil, "Retile starts with the test settings")

  -- Auto-tiling on start
  local wins = fixtureWindows()
  local cols3 = expected("columns", 3, screen)
  local placed = waitFor(function()
    local slots = bySlot(fixtureWindows())
    for i, w in ipairs(slots) do
      if not sameRect(w:frame(), cols3()[i]) then return false end
    end
    return slots
  end, 3)
  check(placed, "windows tiled into 3 columns on start")
  wins = bySlot(wins)
  check(sameRect(fixed:frame(), fixedFrame), "non-resizable window left floating")

  -- ⌘→ / ⌘← swap within the layout
  local a, b, c = wins[1], wins[2], wins[3]
  focus(a)
  press({ "cmd" }, "right")
  expectTiled("⌘→ swaps with the right neighbour", { b, a, c }, cols3)
  press({ "cmd" }, "left")
  expectTiled("⌘← swaps back", { a, b, c }, cols3)
  focus(c)
  press({ "cmd" }, "right")
  wait(0.3)
  expectTiled("⌘→ at the right edge changes nothing", { a, b, c }, cols3)

  -- ⌃⌥→ focus
  focus(a)
  press({ "ctrl", "alt" }, "right")
  check(waitFor(function()
    local f = hs.window.focusedWindow()
    return f and f:id() == b:id()
  end, 2), "⌃⌥→ focuses the right neighbour")

  -- Layout keys
  press({ "ctrl", "alt" }, "2")
  expectTiled("⌃⌥2 switches to tall", { a, b, c }, expected("tall", 3, screen))
  press({ "ctrl", "alt" }, "]")
  expectTiled("⌃⌥] grows the main area", { a, b, c }, expected("tall", 3, screen, { ratio = 0.65 }))
  press({ "ctrl", "alt" }, ".")
  expectTiled("⌃⌥. puts two windows in the main area", { a, b, c },
    expected("tall", 3, screen, { ratio = 0.65, masters = 2 }))
  press({ "ctrl", "alt" }, "l")
  expectTiled("⌃⌥L cycles to wide", { a, b, c }, expected("wide", 3, screen, { ratio = 0.65, masters = 2 }))
  focus(a)
  press({ "ctrl", "alt" }, "return")
  wait(0.3)
  expectTiled("⌃⌥↩ on the main window swaps it with the next", { b, a, c },
    expected("wide", 3, screen, { ratio = 0.65, masters = 2 }))
  press({ "ctrl", "alt" }, "4")
  expectTiled("⌃⌥4 switches to columns", { b, a, c }, cols3)

  -- Floating
  focus(a)
  local floatFrame = a:frame()
  press({ "ctrl", "alt" }, "f")
  expectTiled("⌃⌥F floats the window, the others close up", { b, c }, expected("columns", 2, screen))
  check(sameRect(a:frame(), floatFrame), "floated window stays put")
  press({ "ctrl", "alt" }, "f")
  expectTiled("⌃⌥F again tiles it at the end", { b, c, a }, cols3)

  -- Windows opening and closing re-tile automatically
  hs.execute("kill -USR1 " .. fixture:pid())
  local d = waitFor(function() return windowNamed("Fixture 4") end, 3)
  check(d, "fixture opened a fourth window")
  if d then
    expectTiled("a new window joins at the end", { b, c, a, d }, expected("columns", 4, screen))
    d:close()
    expectTiled("closing a window re-tiles the rest", { b, c, a }, cols3)
  end
  -- Hiding, unlike minimizing, leaves the Dock and so the screen alone: only the
  -- unhide can apply the layout picked meanwhile. Minimizing goes last, as its
  -- Dock change re-tiles a second later.
  local app = hs.application.get(fixture:pid())
  app:hide()
  waitFor(function() return #(Retile.tiler:collect()[screen:getUUID()] or { windows = {} }).windows == 0 end, 2)
  press({ "ctrl", "alt" }, "2")
  waitFor(function() return (Retile.tiler:current() or {}).layout == "tall" and not Retile.tiler.tileTimer end, 2)
  app:unhide()
  expectTiled("unhiding the app re-tiles its windows", { b, c, a },
    expected("tall", 3, screen, { ratio = 0.65, masters = 2 }))
  press({ "ctrl", "alt" }, "4")
  expectTiled("back to columns", { b, c, a }, cols3)
  c:minimize()
  expectTiled("minimizing a window re-tiles the rest", { b, a }, expected("columns", 2, screen))
  c:unminimize()
  expectTiled("restoring it tiles it at the end", { b, a, c }, cols3)

  -- Pausing
  focus(b)
  press({ "ctrl", "alt" }, "p")
  wait(0.2)
  hs.execute("kill -USR1 " .. fixture:pid())
  local e = waitFor(function() return windowNamed("Fixture 5") end, 3)
  if e then
    wait(0.6)
    check(e:frame().w == 420, "a new window on a paused space is left alone", rect(e:frame()))
    focus(b)
    press({ "ctrl", "alt" }, "p")
    expectTiled("⌃⌥P resumes and tiles the new window", { b, a, c, e }, expected("columns", 4, screen))
    e:close()
    expectTiled("back to three", { b, a, c }, cols3)
  else
    check(false, "fixture opened a window while paused")
  end

  -- ⇧⌘↑ / ⇧⌘↓ move between displays
  local OPPOSITE = { up = "down", down = "up", left = "right", right = "left" }
  local TOWARDS = { up = "toNorth", down = "toSouth", left = "toWest", right = "toEast" }
  local dir, other
  for _, side in ipairs({ "up", "down", "left", "right" }) do
    local s2 = screen[TOWARDS[side]](screen)
    if not dir and s2 and hs.spaces.spaceType(hs.spaces.activeSpaceOnScreen(s2)) == "user" then dir, other = side, s2 end
  end
  if dir then
    focus(b)
    press({ "cmd", "shift" }, dir)
    check(waitFor(function() return b:screen():getUUID() == other:getUUID() end, 3),
      "⇧⌘" .. dir .. " moves the window to the display " .. dir)
    expectTiled("it fills that display", { b }, expected("columns", 1, other))
    expectTiled("the rest close up", { a, c }, expected("columns", 2, screen))
    focus(b)
    press({ "cmd", "shift" }, OPPOSITE[dir])
    check(waitFor(function() return b:screen():getUUID() == screen:getUUID() end, 3), "⇧⌘" .. OPPOSITE[dir] .. " brings it back")
    expectTiled("and it joins at the end", { a, c, b }, cols3)
  else
    log("skip display moves: no other display showing a desktop")
  end

  -- ⇧⌘→ / ⇧⌘← carry the window between spaces
  local spaces = hs.spaces.spacesForScreen(screen)
  local at
  for i, s in ipairs(spaces) do if s == space then at = i end end
  local right, left = spaces[at + 1], spaces[at - 1]
  local win = bySlot(fixtureWindows())[1]
  local rest = bySlot(fixtureWindows())
  table.remove(rest, 1)
  if left and hs.spaces.spaceType(left) ~= "user" then
    focus(win)
    press({ "cmd", "shift" }, "left")
    wait(1)
    check(hs.spaces.activeSpaceOnScreen(screen) == space and contains(hs.spaces.windowSpaces(win), space),
      "⇧⌘← refuses to carry a window into a full-screen app's space")
  end
  if not right or hs.spaces.spaceType(right) == "user" then
    focus(win)
    local mouse = hs.mouse.absolutePosition()
    press({ "cmd", "shift" }, "right")
    -- Without a space to the right, Retile adds one (createSpaces).
    local target = waitFor(function()
      local active = hs.spaces.activeSpaceOnScreen(screen)
      return active ~= space and contains(hs.spaces.windowSpaces(win), active) and active
    end, 5)
    check(target and (not right or target == right), "⇧⌘→ carries the window to the next space and follows it",
      "active=" .. tostring(hs.spaces.activeSpaceOnScreen(screen)) .. " window=" .. hs.inspect(hs.spaces.windowSpaces(win)))
    if target then
      state.created = not right and target or nil
      expectTiled("it is tiled alone there", { win }, expected("columns", 1, screen))
      check(waitFor(function()
        local f = hs.window.focusedWindow()
        return f and f:id() == win:id()
      end, 2), "and keeps focus")
      local p = hs.mouse.absolutePosition()
      check(math.abs(p.x - mouse.x) < 1 and math.abs(p.y - mouse.y) < 1, "the mouse is put back")
      press({ "cmd", "shift" }, "left")
      check(waitFor(function()
        return hs.spaces.activeSpaceOnScreen(screen) == space and contains(hs.spaces.windowSpaces(win), space)
      end, 5), "⇧⌘← carries it back")
      table.insert(rest, win)
      expectTiled("the original space re-tiles with it at the end", rest, cols3)
    end
  else
    log("skip space moves: the space to the right is a full-screen app")
  end

  -- ⌘Y keyboard map
  local first = bySlot(fixtureWindows())[1]
  focus(first)
  state.shadow = hs.hotkey.bind({ "ctrl", "alt" }, "r", "Shadowing test hotkey", function() end)
  press({ "cmd" }, "y")
  local view = waitFor(function() return Retile.overlay.view end, 2)
  check(view, "⌘Y opens the keyboard map")
  if view then
    wait(0.8)
    local hw = view:hswindow()
    check(sameRect(hw:frame(), screen:fullFrame()), "it covers the screen", rect(hw:frame()))
    local key = hs.window.focusedWindow()
    check(key and key:id() == hw:id(), "and takes key focus for hover and Escape")
    Retile.tiler:tileAll()
    check(sameRect(hw:frame(), screen:fullFrame()), "re-tiling leaves the overlay alone")
    local t0 = now()
    check(waitFor(function() return js(view, "window.RETILE && document.readyState") == "complete" end, 5),
      "the page loads", string.format("after %.1fs", now() - t0))

    local arrow, why = js(view, [[(() => {
      const R = window.RETILE;
      const i = R.binds.findIndex((b) => b.key === "left" && b.mods.join() === "shift,cmd");
      const seg = document.querySelector(`.seg[data-b="${i}"]`);
      const r = seg.getBoundingClientRect();
      return { x: r.left + r.width / 2, y: r.top + r.height / 2,
        mods: [...seg.parentElement.querySelectorAll(".mods")].map((m) => m.textContent),
        count: R.binds.length,
        r: R.binds.filter((b) => b.key === "r").map((b) => b.mods.join("+") + " " + b.group + ": " + b.desc) };
    })()]])
    check(arrow and table.concat(arrow.mods, " ") == "⌘ ⌃⌥ ⇧⌘", "← shows its three bindings side by side, modifiers on top",
      arrow and table.concat(arrow.mods, " ") or why)
    check(arrow and arrow.count == #hs.hotkey.getHotkeys(), "every active Hammerspoon hotkey is listed once",
      arrow and arrow.count .. " of " .. #hs.hotkey.getHotkeys() or why)
    check(arrow and table.concat(arrow.r, "; ") == "ctrl+alt external: Shadowing test hotkey",
      "a later hotkey on ⌃⌥R replaces Retile's in the map", arrow and table.concat(arrow.r, "; ") or why)
    if arrow then
      local f = hw:frame()
      hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.mouseMoved, { x = f.x + arrow.x, y = f.y + arrow.y }):post()
      local tip = waitFor(function()
        local t = js(view, [[{ on: document.getElementById("tip").classList.contains("on"),
          chord: document.getElementById("tip-chord").textContent,
          desc: document.getElementById("tip-desc").textContent,
          lit: [...document.querySelectorAll(".key.lit")].map((k) => k.dataset.mod) }]])
        return t and t.on and t
      end, 2)
      check(tip and tip.desc == "Move window to the previous space" and tip.chord == "⇧⌘ ←",
        "hovering ⇧⌘← with the real mouse explains it", tip and (tip.chord .. " " .. tip.desc))
      if tip then table.sort(tip.lit) end
      check(tip and table.concat(tip.lit, " ") == "cmd cmd shift shift", "and lights both ⇧ and both ⌘ keys",
        tip and table.concat(tip.lit, " "))
    end
    press({}, "escape")
    check(waitFor(function() return Retile.overlay.view == nil end, 2), "Escape closes it")
    check(waitFor(function()
      local f = hs.window.focusedWindow()
      return f and f:id() == first:id()
    end, 2), "and focus returns to the previous window")
  end
end

local function main()
  local ok, err = xpcall(run, debug.traceback)
  if not ok then
    failures = failures + 1
    log("ERROR %s", err)
  end
  if state.shadow then state.shadow:delete() end
  if Retile then Retile:stop() end
  if fixture then fixture:terminate() end
  for uuid, space in pairs(state.spaces or {}) do
    if hs.spaces.activeSpaceOnScreen(uuid) ~= space then
      hs.spaces.gotoSpace(space)
      waitFor(function() return hs.spaces.activeSpaceOnScreen(uuid) == space end, 5)
    end
  end
  if state.created then
    local removed, removeErr = hs.spaces.removeSpace(state.created)
    log("removed the space the test added: %s", removed and "yes" or tostring(removeErr))
  end
  if state.mouse then hs.mouse.absolutePosition(state.mouse) end
  if state.focused then state.focused:focus() end
  log("%s: %d failed", failures == 0 and "PASS" or "FAIL", failures)
  local f = io.open(RESULT, "w")
  f:write(table.concat(lines, "\n"), "\n")
  f:close()
  if state.reload then hs.reload() end
end

-- Started once the `hs -c` call that loaded this file has disconnected:
-- print() is forwarded to connected CLIs, which aborts Hammerspoon when done
-- from a coroutine (e.g. hs.hotkey logging as Retile starts).
state.starter = hs.timer.doAfter(1, function() coroutine.wrap(main)() end)
