-- The keyboard map's view of Tiler:scene(): its header line, and for each
-- action what pressing it would do there, as window frames before and after
-- for overlay.html to animate. When the scene gives an action nothing to act
-- on, an example scene shows it instead. Pure, like layouts.lua.
return function(layouts)
  local M = {}

  local SIDES = { left = "to the left", right = "to the right", up = "above", down = "below" }
  local EXAMPLE_WINDOWS = 4

  local function rect(x, y, w, h)
    return { x = x, y = y, w = w, h = h }
  end

  local function offset(r, dx, dy)
    return rect(r.x + dx, r.y + dy, r.w, r.h)
  end

  local function union(a, b)
    local x, y = math.min(a.x, b.x), math.min(a.y, b.y)
    return rect(x, y, math.max(a.x + a.w, b.x + b.w) - x, math.max(a.y + a.h, b.y + b.h) - y)
  end

  -- Where hs.window:moveToScreen puts `r`: the same place relative to the usable area.
  local function rescale(r, from, to)
    local sx, sy = to.w / from.w, to.h / from.h
    return rect(to.x + (r.x - from.x) * sx, to.y + (r.y - from.y) * sy, r.w * sx, r.h * sy)
  end

  local function same(a, b)
    return math.abs(a.x - b.x) < 1 and math.abs(a.y - b.y) < 1 and math.abs(a.w - b.w) < 1 and math.abs(a.h - b.h) < 1
  end

  local function arrange(state, n, frame, gaps)
    return layouts.arrange(state.layout, n, frame, { ratio = state.ratio, masters = state.masters, gaps = gaps })
  end

  local function settings(scene, changes)
    return {
      layout = changes.layout or scene.layout,
      ratio = changes.ratio or scene.ratio,
      masters = changes.masters or scene.masters,
    }
  end

  -- The scene as it stands. A focused window that isn't tiled comes last.
  local function still(scene)
    local windows = {}
    for i, f in ipairs(scene.windows) do windows[i] = { from = f, to = f } end
    local focus = scene.focus
    if scene.loose then
      windows[#windows + 1] = { from = scene.loose.frame, to = scene.loose.frame, floating = "both" }
      focus = #windows
    end
    return {
      view = scene.screen.full,
      desktops = { scene.screen.full },
      windows = windows,
      focus = focus and { from = focus, to = focus },
    }
  end

  -- The scene once its windows are tiled with `state` (default: the scene's
  -- own settings), as every key acting in the layout tiles first.
  local function retiled(scene, cfg, state)
    local spec = still(scene)
    for i, f in ipairs(arrange(state or scene, #scene.windows, scene.screen.frame, cfg.gaps)) do
      spec.windows[i].to = f
    end
    return spec
  end

  -- Nothing happens: the window (or with no `window`, the focus) nudges
  -- towards `dir` and `note` says why.
  local function bump(spec, window, dir, note)
    spec.bump = { window = window, dir = dir }
    spec.note = note
    return spec
  end

  local function changed(spec)
    if spec.focus and spec.focus.from ~= spec.focus.to then return true end
    for _, w in ipairs(spec.windows) do
      if not same(w.from, w.to) then return true end
    end
    return false
  end

  local function tiledFocus(scene)
    if scene.paused then return nil, "Tiling is paused on this space" end
    if not scene.focus then return nil, "No tiled window is focused" end
    return scene.focus
  end

  -- The focused window, if Retile may move it to another space or display.
  local function movable(scene)
    if scene.focus then return scene.focus end
    if scene.loose and scene.loose.managed then return #scene.windows + 1 end
    return nil, scene.loose and "Retile doesn't manage the focused window" or "No window is focused"
  end

  local function swapped(scene, cfg, i, j)
    local spec, frames = still(scene), arrange(scene, #scene.windows, scene.screen.frame, cfg.gaps)
    for k = 1, #scene.windows do
      spec.windows[k].to = frames[k == i and j or k == j and i or k]
    end
    if scene.layout == "monocle" then spec.note = "In monocle this only changes the window order" end
    return spec
  end

  -- Settings changes: the windows re-tiled with `state`; `unchanged` says why
  -- that would look the same.
  local function relayout(scene, cfg, state, label, unchanged)
    if scene.paused then return nil, "Tiling is paused on this space" end
    local n = #scene.windows
    if n < 2 then return nil, n == 0 and "No windows are tiled here" or "Only one window is tiled" end
    local spec = retiled(scene, cfg, state)
    if changed(spec) then
      spec.label = label
    else
      spec.note = unchanged
    end
    return spec
  end

  -- Builders: (scene, cfg, arg) -> spec, or nil and why the scene can't show it.
  local B = {}

  function B.keymap(scene)
    local spec = still(scene)
    spec.keymap = true
    return spec
  end

  function B.swap(scene, cfg, dir)
    local i, why = tiledFocus(scene)
    if not i then return nil, why end
    local j = layouts.neighbor(arrange(scene, #scene.windows, scene.screen.frame, cfg.gaps), i, dir, scene.layout)
    if not j then return bump(retiled(scene, cfg), i, dir, "No window " .. SIDES[dir]) end
    return swapped(scene, cfg, i, j)
  end

  function B.promote(scene, cfg)
    local i, why = tiledFocus(scene)
    if not i then return nil, why end
    if #scene.windows < 2 then return nil, "Only one window is tiled" end
    return swapped(scene, cfg, i, i == 1 and 2 or 1)
  end

  function B.focus(scene, cfg, dir)
    local i, why = tiledFocus(scene)
    if not i then return nil, why end
    local spec = retiled(scene, cfg)
    local j = layouts.neighbor(arrange(scene, #scene.windows, scene.screen.frame, cfg.gaps), i, dir, scene.layout)
    if not j then return bump(spec, nil, dir, "No window " .. SIDES[dir]) end
    spec.focus.to = j
    return spec
  end

  -- The window is carried to the space beside, which slides into view; the
  -- space it left keeps its gap until it is shown again.
  function B.moveToSpace(scene, cfg, dir)
    local k, why = movable(scene)
    if not k then return nil, why end
    local spec, spaces = still(scene), scene.spaces
    if not spaces.index then return nil, "macOS isn't listing this display's spaces" end
    local step = dir == "right" and 1 or -1
    local target = spaces[dir]
    spec.dots = { kinds = table.move(spaces.kinds, 1, #spaces.kinds, 1, {}), from = spaces.index, to = spaces.index }
    if not target then
      if dir == "left" or not cfg.createSpaces then return bump(spec, k, dir, "No space " .. SIDES[dir]) end
      target = { user = true, state = { layout = cfg.layout, ratio = cfg.ratio, masters = cfg.masters, paused = false, count = 0 } }
      spec.dots.kinds[#spec.dots.kinds + 1] = "user"
      spec.dots.added = true
      spec.label = "New space"
    end
    if not target.user then return bump(spec, k, dir, "The space " .. SIDES[dir] .. " is a full-screen app") end

    local full = scene.screen.full
    local dx = full.w * 1.06 * step
    local there = offset(scene.screen.frame, dx, 0)
    spec.desktops[2] = offset(full, dx, 0)
    spec.pan = { x = dx, y = 0 }
    spec.dots.to = spaces.index + step

    local w, state = spec.windows[k], target.state
    w.via = offset(w.from, dx, 0)
    local before = arrange(state, state.count, there, cfg.gaps)
    if w.floating or state.paused then
      w.to = w.via
      for _, f in ipairs(before) do spec.windows[#spec.windows + 1] = { from = f, to = f } end
    else
      local after = arrange(state, state.count + 1, there, cfg.gaps)
      for m, f in ipairs(before) do spec.windows[#spec.windows + 1] = { from = f, to = after[m] } end
      w.to = after[state.count + 1]
    end
    return spec
  end

  function B.moveToScreen(scene, cfg, dir)
    local k, why = movable(scene)
    if not k then return nil, why end
    local spec, display = still(scene), scene.displays[dir]
    if not display then return bump(spec, k, dir, "No display " .. SIDES[dir]) end
    if not display.user then return bump(spec, k, dir, "The display " .. SIDES[dir] .. " is showing a full-screen app") end
    spec.view = union(scene.screen.full, display.full)
    spec.desktops[2] = display.full

    local w, n = spec.windows[k], #scene.windows
    if not scene.paused then
      local rest = arrange(scene, w.floating and n or n - 1, scene.screen.frame, cfg.gaps)
      local slot = 0
      for m = 1, n do
        if m ~= k then
          slot = slot + 1
          spec.windows[m].to = rest[slot]
        end
      end
    end
    local state, theirs = display.state, display.windows
    if w.floating or state.paused then
      w.to = rescale(w.from, scene.screen.frame, display.frame)
      for _, f in ipairs(theirs) do spec.windows[#spec.windows + 1] = { from = f, to = f } end
    else
      local after = arrange(state, #theirs + 1, display.frame, cfg.gaps)
      for m, f in ipairs(theirs) do spec.windows[#spec.windows + 1] = { from = f, to = after[m] } end
      w.to = after[#theirs + 1]
    end
    return spec
  end

  function B.layout(scene, cfg, name)
    return relayout(scene, cfg, settings(scene, { layout = name }), name,
      name == scene.layout and "Already the " .. name .. " layout"
        or string.format("With %d windows, %s looks the same as %s", #scene.windows, name, scene.layout))
  end

  function B.cycleLayout(scene, cfg, dir)
    return B.layout(scene, cfg, layouts.cycle(cfg.layouts, scene.layout, dir == "next" and 1 or -1))
  end

  function B.resize(scene, cfg, how)
    local ratio = layouts.stepRatio(scene.ratio, how == "grow" and 1 or -1, cfg.ratioStep)
    local why
    if scene.layout ~= "tall" and scene.layout ~= "wide" and scene.layout ~= "spiral" then
      why = "The " .. scene.layout .. " layout has no main area"
    elseif ratio == scene.ratio then
      why = "The main area is at its " .. (how == "grow" and "largest" or "smallest")
    else
      why = "Every window is in the main area"
    end
    return relayout(scene, cfg, settings(scene, { ratio = ratio }),
      string.format("Main area %d%%", math.floor(ratio * 100 + 0.5)), why)
  end

  function B.masters(scene, cfg, how)
    local masters = layouts.stepMasters(scene.masters, how == "more" and 1 or -1, #scene.windows)
    local why
    if scene.layout ~= "tall" and scene.layout ~= "wide" then
      why = "The " .. scene.layout .. " layout has no main area"
    elseif how == "fewer" and masters == 1 then
      why = "The main area has just one window"
    else
      why = "Every window is in the main area"
    end
    return relayout(scene, cfg, settings(scene, { masters = masters }),
      masters .. (masters == 1 and " main window" or " main windows"), why)
  end

  -- Floating leaves the window where it is and closes the layout up under
  -- it; tiling it again adds it where new windows go.
  function B.toggleFloat(scene, cfg)
    local loose = scene.loose
    if not scene.focus and not loose then return nil, "No window is focused" end
    if loose and not loose.floated then
      local spec = still(scene)
      spec.note = "This window isn't tiled"
      return spec
    end
    if scene.paused then return nil, "Tiling is paused on this space" end
    local spec, n = still(scene), #scene.windows
    if scene.focus then
      local rest = arrange(scene, n - 1, scene.screen.frame, cfg.gaps)
      local slot = 0
      for m = 1, n do
        if m ~= scene.focus then
          slot = slot + 1
          spec.windows[m].to = rest[slot]
        end
      end
      spec.windows[scene.focus].floating = "after"
      spec.label = "Floating"
      return spec
    end
    local after = arrange(scene, n + 1, scene.screen.frame, cfg.gaps)
    local first = cfg.newWindows == "first" and 1 or 0
    for m = 1, n do spec.windows[m].to = after[m + first] end
    local w = spec.windows[n + 1]
    w.floating, w.to = "before", after[first == 1 and 1 or n + 1]
    spec.label = "Tiled"
    return spec
  end

  -- Resuming tiles the space; pausing shows a window opening, and taking
  -- focus, untiled.
  function B.togglePause(scene, cfg)
    local spec = still(scene)
    spec.paused = { from = scene.paused, to = not scene.paused }
    if scene.paused then
      for i, f in ipairs(arrange(scene, #scene.windows, scene.screen.frame, cfg.gaps)) do spec.windows[i].to = f end
    else
      local f = scene.screen.frame
      spec.windows[#spec.windows + 1] = { to = rect(f.x + f.w * 0.3, f.y + f.h * 0.22, f.w * 0.4, f.h * 0.45) }
      if spec.focus then spec.focus.to = #spec.windows end
    end
    return spec
  end

  function B.retile(scene, cfg)
    if scene.paused then return nil, "Tiling is paused on this space" end
    if #scene.windows == 0 then return nil, "No windows are tiled here" end
    local spec = retiled(scene, cfg)
    if not changed(spec) then spec.note = "Every window is in place already" end
    return spec
  end

  -- `scene` with EXAMPLE_WINDOWS tiled in `layout`, a space on either side
  -- and a display on every side.
  local function example(scene, cfg, layout)
    local full, frame = scene.screen.full, scene.screen.frame
    local state = { layout = layout, ratio = scene.ratio, masters = scene.masters, paused = false, count = 1 }
    local displays = {}
    for dir, d in pairs({ left = { -1, 0 }, right = { 1, 0 }, up = { 0, -1 }, down = { 0, 1 } }) do
      local dx, dy = d[1] * full.w, d[2] * full.h
      local there = offset(frame, dx, dy)
      displays[dir] = {
        full = offset(full, dx, dy), frame = there, user = true, state = state,
        windows = arrange(state, 1, there, cfg.gaps),
      }
    end
    return {
      layout = layout, ratio = scene.ratio, masters = scene.masters, paused = false,
      screen = scene.screen,
      windows = arrange(state, EXAMPLE_WINDOWS, frame, cfg.gaps),
      spaces = { index = 2, kinds = { "user", "user", "user" }, left = { user = true, state = state }, right = { user = true, state = state } },
      displays = displays,
    }
  end

  -- The preview of `action` with `arg` on `scene`. `cfg` is Retile's config.
  -- Examples try the scene's layout first, then the others, with each window
  -- focused in turn, until the action visibly does something.
  function M.build(scene, action, arg, cfg)
    local build = B[action]
    local spec, why = build(scene, cfg, arg)
    if spec then return spec end
    local first
    for _, layout in ipairs({ scene.layout, table.unpack(layouts.names) }) do
      local ex = example(scene, cfg, layout)
      -- Re-tiling only shows on a window out of place.
      if action == "retile" then
        local f = ex.windows[1]
        ex.windows[1] = rect(f.x + f.w * 0.12, f.y + f.h * 0.15, f.w * 0.7, f.h * 0.6)
      end
      for i = 1, EXAMPLE_WINDOWS do
        ex.focus = i
        spec = build(ex, cfg, arg)
        first = first or spec
        if changed(spec) then
          spec.example, spec.note = true, why
          return spec
        end
      end
    end
    first.example, first.note = true, why
    return first
  end

  -- One line about the scene's space for the keyboard map's header.
  function M.describe(scene)
    local n = #scene.windows
    local parts = {
      scene.paused and "tiling paused" or scene.layout .. " layout",
      n .. (n == 1 and " window" or " windows"),
    }
    local index, count = nil, 0
    for i, kind in ipairs(scene.spaces.kinds) do
      if kind == "user" then
        count = count + 1
        if i == scene.spaces.index then index = count end
      end
    end
    if index then parts[#parts + 1] = string.format("space %d of %d", index, count) end
    parts[#parts + 1] = scene.screen.name
    return table.concat(parts, " · ")
  end

  return M
end
