-- Pure geometry: layout algorithms, gaps, directional neighbours and window
-- ordering. No hs.* here so it runs under plain Lua in the unit tests.
local M = {}

local function rect(x, y, w, h)
  return { x = x, y = y, w = w, h = h }
end

-- Splits `area` into `count` equal parts side by side (`horizontal`) or stacked.
local function split(area, count, horizontal)
  local parts = {}
  for i = 0, count - 1 do
    if horizontal then
      local w = area.w / count
      parts[#parts + 1] = rect(area.x + i * w, area.y, w, area.h)
    else
      local h = area.h / count
      parts[#parts + 1] = rect(area.x, area.y + i * h, area.w, h)
    end
  end
  return parts
end

local function append(dst, src)
  for _, v in ipairs(src) do dst[#dst + 1] = v end
  return dst
end

-- Main area of `ratio` on one side holding `masters` windows, the rest stacked
-- on the other side. `horizontal` puts the main area on the left, else on top.
local function mainAndStack(n, area, opts, horizontal)
  local masters = math.min(opts.masters, n)
  if masters == n then return split(area, n, not horizontal) end
  local main, stack
  if horizontal then
    local w = area.w * opts.ratio
    main = rect(area.x, area.y, w, area.h)
    stack = rect(area.x + w, area.y, area.w - w, area.h)
  else
    local h = area.h * opts.ratio
    main = rect(area.x, area.y, area.w, h)
    stack = rect(area.x, area.y + h, area.w, area.h - h)
  end
  return append(split(main, masters, not horizontal), split(stack, n - masters, not horizontal))
end

M.algorithms = {
  -- floor(sqrt(n)) rows (columns on a portrait area), windows spread as evenly
  -- as possible with the extra ones in the first lines.
  grid = function(n, area)
    local portrait = area.h > area.w
    local lines = math.max(1, math.floor(math.sqrt(n)))
    local base, extra = n // lines, n % lines
    local frames = {}
    for i, line in ipairs(split(area, lines, portrait)) do
      append(frames, split(line, base + (i <= extra and 1 or 0), not portrait))
    end
    return frames
  end,
  tall = function(n, area, opts) return mainAndStack(n, area, opts, true) end,
  wide = function(n, area, opts) return mainAndStack(n, area, opts, false) end,
  columns = function(n, area) return split(area, n, true) end,
  rows = function(n, area) return split(area, n, false) end,
  -- Each window takes part of what is left, alternating side and bottom; the
  -- first split uses the main ratio, the rest halve.
  spiral = function(n, area, opts)
    local frames, rest = {}, area
    for i = 1, n - 1 do
      local share = i == 1 and opts.ratio or 0.5
      if i % 2 == 1 then
        local w = rest.w * share
        frames[i] = rect(rest.x, rest.y, w, rest.h)
        rest = rect(rest.x + w, rest.y, rest.w - w, rest.h)
      else
        local h = rest.h * share
        frames[i] = rect(rest.x, rest.y, rest.w, h)
        rest = rect(rest.x, rest.y + h, rest.w, rest.h - h)
      end
    end
    frames[n] = rest
    return frames
  end,
  monocle = function(n, area)
    local frames = {}
    for i = 1, n do frames[i] = rect(area.x, area.y, area.w, area.h) end
    return frames
  end,
}

M.names = { "grid", "tall", "wide", "columns", "rows", "spiral", "monocle" }

M.descriptions = {
  grid = "even grid",
  tall = "main column with a stack beside it",
  wide = "main row with a stack below it",
  columns = "side-by-side columns",
  rows = "stacked rows",
  spiral = "spiral",
  monocle = "one full-size window at a time",
}

-- Frames for `n` windows of layout `name` on `screenFrame`, `gaps.outer` from
-- the screen edges and `gaps.inner` between windows, snapped to whole points
-- (which can widen a gap by one).
function M.arrange(name, n, screenFrame, opts)
  if n == 0 then return {} end
  local pad = opts.gaps.outer - opts.gaps.inner / 2
  local area = rect(screenFrame.x + pad, screenFrame.y + pad, screenFrame.w - 2 * pad, screenFrame.h - 2 * pad)
  local half = opts.gaps.inner / 2
  local frames = {}
  for i, f in ipairs(M.algorithms[name](n, area, opts)) do
    local x1, y1 = math.floor(f.x + half + 0.5), math.floor(f.y + half + 0.5)
    local x2, y2 = math.floor(f.x + f.w - half + 0.5), math.floor(f.y + f.h - half + 0.5)
    frames[i] = rect(x1, y1, math.max(x2 - x1, 1), math.max(y2 - y1, 1))
  end
  return frames
end

local AXES = {
  left = { along = "x", size = "w", cross = "y", crossSize = "h", sign = -1 },
  right = { along = "x", size = "w", cross = "y", crossSize = "h", sign = 1 },
  up = { along = "y", size = "h", cross = "x", crossSize = "w", sign = -1 },
  down = { along = "y", size = "h", cross = "x", crossSize = "w", sign = 1 },
}

-- Index of the frame next to frames[i] in `dir`: among the nearest frames
-- entirely on that side, the one overlapping it most across the axis, then the
-- one whose centre is closest. Nil at the edge of the layout.
function M.neighbor(frames, i, dir)
  local a, cur = AXES[dir], frames[i]
  local candidates, nearest = {}, math.huge
  for j, f in ipairs(frames) do
    local gap = a.sign > 0 and f[a.along] - (cur[a.along] + cur[a.size])
      or cur[a.along] - (f[a.along] + f[a.size])
    if j ~= i and gap >= 0 then
      candidates[#candidates + 1] = { index = j, gap = gap, frame = f }
      nearest = math.min(nearest, gap)
    end
  end
  local best, bestOverlap, bestOffset
  for _, c in ipairs(candidates) do
    if c.gap <= nearest + 1 then -- snapping can widen a gap by one
      local f = c.frame
      local overlap = math.min(cur[a.cross] + cur[a.crossSize], f[a.cross] + f[a.crossSize])
        - math.max(cur[a.cross], f[a.cross])
      local offset = math.abs((cur[a.cross] + cur[a.crossSize] / 2) - (f[a.cross] + f[a.crossSize] / 2))
      -- Snapping to whole points makes equal overlaps differ by a point or two.
      local tie = best and math.abs(overlap - bestOverlap) <= 2
      if not best or (tie and offset < bestOffset) or (not tie and overlap > bestOverlap) then
        best, bestOverlap, bestOffset = c.index, overlap, offset
      end
    end
  end
  return best
end

-- New window order for a space: ids in `order` still present keep their
-- place; ids only in `present` (given in reading order) go at the start when
-- `placement` is "first", else at the end. Present ids in `incoming` (moved
-- here from another space or screen) go last.
function M.reconcile(order, present, placement, incoming)
  local alive = {}
  for _, id in ipairs(present) do alive[id] = true end
  local result, known, tail = {}, {}, {}
  for _, id in ipairs(incoming or {}) do
    if alive[id] and not known[id] then
      tail[#tail + 1] = id
      known[id] = true
    end
  end
  for _, id in ipairs(order) do
    if alive[id] and not known[id] then
      result[#result + 1] = id
      known[id] = true
    end
  end
  local at = placement == "first" and 1 or #result + 1
  for _, id in ipairs(present) do
    if not known[id] then
      table.insert(result, at, id)
      at = at + 1
    end
  end
  return table.move(tail, 1, #tail, #result + 1, result)
end

return M
