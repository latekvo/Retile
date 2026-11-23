-- Everything a key can be bound to ("swap left", "layout tall", ...): the
-- argument it takes, its group in the keyboard map, its description there,
-- and what it does. `run` receives the Retile spoon.
return function(layouts)
  local DIRECTIONS = { "left", "right", "up", "down" }
  local SIDES = { left = "to the left", right = "to the right", up = "above", down = "below" }

  return {
    keymap = {
      group = "app",
      describe = function() return "Show or hide this keyboard map" end,
      run = function(r) r.overlay:toggle() end,
    },
    swap = {
      group = "move",
      args = DIRECTIONS,
      describe = function(dir) return "Move window " .. dir .. " in the layout" end,
      run = function(r, dir) r.tiler:swap(dir) end,
    },
    promote = {
      group = "move",
      describe = function() return "Swap window with the main window" end,
      run = function(r) r.tiler:promote() end,
    },
    moveToSpace = {
      group = "workspace",
      args = { "left", "right" },
      describe = function(dir)
        return "Move window to the " .. (dir == "left" and "previous" or "next") .. " space"
      end,
      run = function(r, dir) r.tiler:moveToSpace(dir) end,
    },
    moveToScreen = {
      group = "workspace",
      args = DIRECTIONS,
      describe = function(dir) return "Move window to the display " .. SIDES[dir] end,
      run = function(r, dir) r.tiler:moveToScreen(dir) end,
    },
    focus = {
      group = "focus",
      args = DIRECTIONS,
      describe = function(dir) return "Focus the window " .. SIDES[dir] end,
      run = function(r, dir) r.tiler:focus(dir) end,
    },
    layout = {
      group = "layout",
      args = layouts.names,
      describe = function(name) return "Layout: " .. name .. " - " .. layouts.descriptions[name] end,
      run = function(r, name) r.tiler:setLayout(name) end,
    },
    cycleLayout = {
      group = "layout",
      args = { "next", "prev" },
      describe = function(dir) return "Switch to the " .. (dir == "next" and "next" or "previous") .. " layout" end,
      run = function(r, dir) r.tiler:cycleLayout(dir == "next" and 1 or -1) end,
    },
    resize = {
      group = "layout",
      args = { "grow", "shrink" },
      describe = function(how) return (how == "grow" and "Grow" or "Shrink") .. " the main area" end,
      run = function(r, how) r.tiler:resize(how == "grow" and 1 or -1) end,
    },
    masters = {
      group = "layout",
      args = { "more", "fewer" },
      describe = function(how) return "Put " .. how .. " windows in the main area" end,
      run = function(r, how) r.tiler:changeMasters(how == "more" and 1 or -1) end,
    },
    toggleFloat = {
      group = "layout",
      describe = function() return "Float or tile the focused window" end,
      run = function(r) r.tiler:toggleFloat() end,
    },
    togglePause = {
      group = "layout",
      describe = function() return "Pause or resume tiling on this space" end,
      run = function(r) r.tiler:togglePause() end,
    },
    retile = {
      group = "layout",
      describe = function() return "Re-tile every screen" end,
      run = function(r) r.tiler:tileAll() end,
    },
  }
end
