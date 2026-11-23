-- The keyboard map: overlay.html in a transparent full-screen webview.
local Overlay = {}
Overlay.__index = Overlay

-- `getData` returns the table overlay.html renders.
function Overlay.new(templatePath, getData)
  local file = assert(io.open(templatePath, "r"))
  local template = file:read("a")
  file:close()
  return setmetatable({ template = template, getData = getData }, Overlay)
end

function Overlay:toggle()
  if self.view then self:hide() else self:show() end
end

function Overlay:show()
  self.previousWindow = hs.window.focusedWindow()
  self.previousApp = hs.application.frontmostApplication()
  local screen = self.previousWindow and self.previousWindow:screen() or hs.mouse.getCurrentScreen()

  -- No "<" may reach the HTML parser inside the <script>, e.g. "</script>" or "<!--".
  local json = hs.json.encode(self.getData()):gsub("<", "\\u003c")
  local html = self.template:gsub("__RETILE_DATA__", function() return json end)
  local controller = hs.webview.usercontent.new("retile"):setCallback(function(message)
    if type(message.body) == "table" and message.body.type == "close" then self:hide() end
  end)
  self.view = hs.webview.new(screen:fullFrame(), {}, controller)
    :windowStyle({ "borderless" })
    :transparent(true)
    :shadow(false)
    :allowTextEntry(true)
    :level(hs.drawing.windowLevels.overlay)
    :behavior(hs.drawing.windowBehaviors.canJoinAllSpaces)
    :html(html)
    :show()
  -- Hover and Escape only reach the page while its window is key.
  self.view:hswindow():focus()
end

function Overlay:hide()
  if not self.view then return end
  -- Deleting a visible webview finishes later on the calling Lua thread,
  -- which crashes Hammerspoon if that thread is a coroutine that has ended.
  self.view:hide():delete()
  self.view = nil
  if self.previousWindow then
    self.previousWindow:focus()
  elseif self.previousApp then
    self.previousApp:activate()
  end
  self.previousWindow, self.previousApp = nil, nil
end

return Overlay
