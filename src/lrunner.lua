#!/usr/bin/env lua5.3
-- depends on inotify and luaposix

local inotify = require("inotify")
local unistd = require("posix.unistd")
local sdl = require("SDL")
local ttf = require("SDL.ttf")

-- reads settings from /etc/lrunner.conf and ~/.config/lrunner.conf
-- these tell us mostly where to find searchers.
-- searchers are written in any language you like but must be executable.
-- they are invoked like this:
--  $ searcher "query"
-- they must write results into stdout, like this:
--  str:action:qualifier
--  str:action:qualifier
--  ...
-- str is the displayed name
-- action is the action to execute:
--  lua(...): execute some lua code
--  exec(...): execute a file directly
--  open: open the file in user's specified text editor (or file manager)
--  complete: complete the search query using that entry
--  copy: copy result to clipboard
-- qualifier field is optional but may be:
--  solo: this is the only result displayed
-- e.g. fs_searcher "/li"
--  /lib:complete
--  /libexec:complete
--  /linux:exec(/linux)
-- or calculator "4²+18"
--  34:copy:solo

local function die(...)
  io.stderr:write(string.format("lrunner: %s\n", string.format(...)))
  os.exit(1)
end

local function readFile(file)
  local hand, err = io.open(file, "r")
  if not hand then return nil, err end
  local data = hand:read("a")
  hand:close()
  return data
end

-- load configuration
local function lc(file)
  local data, err = readFile(file)
  if not data then return nil, err end

  local configenv = {}
  setmetatable(configenv, {__index = function(t, k)
    return function(v)
      for kk, vv in pairs(v) do
        if type(vv) == "string" then
          v[kk] = vv:gsub("%b()", function(m)
            return assert(load("return " .. m, "="..file, "t", configenv))()
          end):gsub("$([0-9a-zA-z]+)", function(m)
            return os.getenv(m) or ""
          end)
        end
      end
      t[k] = v
    end
  end})

  assert(load(data, "="..file, "t", configenv))()

  getmetatable(configenv).__index = nil
  return configenv
end

local config = {global = lc("/etc/lrunner.conf"), user = lc(os.getenv("HOME").."/.config/lrunner.conf")}

if not (config.global or config.user) then
  die("no configuration found")
end

local function split(s, d)
  local w = {}
  for W in s:gmatch("[^"..d.."]+") do
    w[#w+1] = W
  end
  return w
end

local function search(t, k)
  local current = t
  for i=1, #k do
    if not current then return end
    if current[k[i]] then
      current = current[k[i]]
      if i == #k then return current end
    end
  end
end

local function config_get(k)
  local fields = split(k, ".")
  return search(config.user, fields) or search(config.global, fields)
end

assert(sdl.init {
  sdl.flags.Video,
  sdl.flags.Events
})

assert(ttf.init())

local dmode = assert(sdl.getDesktopDisplayMode(0))
local width, height = dmode.w, dmode.h

local window = sdl.createWindow {
  width = width,
  height = 20,
  flags = {
    --sdl.window.Borderless,
    sdl.window.Resizable,
    --sdl.window.InputFocused
  }
}

local size = config_get("appearance.font_size") or 12
local font = ttf.open(config_get("appearance.font"), size)
local bg = config_get("appearance.background") or 0x323232
local bg_focused = config_get("appearance.focused") or 0x285577
local fg = config_get("appearance.text") or 0xffffff

local renderer = sdl.createRenderer(window, 0, {sdl.rendererFlags.PresentVSYNC})

local function render(lines, selected)
  window:setSize(width, (size + 4) * #lines)
  local ws = sdl.createRGBSurface(width, (size + 4) * #lines)
  for i=1, #lines do
    --local w = font:sizeUtf8(lines[i])
    local s = font:renderUtf8(lines[i], "shaded", i == selected and 0xAAAAFF or 0xFFFFFF)--, i == selected and bg_focused or bg)
    --ws:fillRect({w = width, h = size + 4, x = 0, y = (size + 4) * (i - 1)}, i == selected and bg_focused or bg)
    s:blit(ws, nil, {w = w, h = size + 4, x = 0, y = (size + 4) * (i - 1)})
  end
  local tex = renderer:createTextureFromSurface(ws)
  renderer:copy(tex)
  renderer:present()
  --window:updateSurface()
end

local quit
while not quit do
  render({"this", "is", "a", "test"}, 3)
  for e in sdl.pollEvent() do
    if e.type == sdl.event.Quit then
      quit = true
    end
  end
end

sdl.quit()
