#!/usr/bin/env lua5.3
-- depends on inotify and luaposix

local inotify = require("inotify")
local unistd = require("posix.unistd")
local dirent = require("posix.dirent")
local signal = require("posix.signal")
local fcntl = require("posix.fcntl")
local stat = require("posix.sys.stat")
local wait = require("posix.sys.wait")
local sdl = require("SDL")
local ttf = require("SDL.ttf")

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

-- checking this file notifies the existing lrunner process that its window should pop into existence
-- inotify is magical
if stat.stat("/proc/"..(readFile("/tmp/lrunner-process") or 0)) then return end

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

local function split(s, d, q)
  local w = {}
  for p, W in s:gmatch("()([^"..d.."]+)") do
    if s:sub(p-2,p-2) == q then
      w[#w] = w[#w]:sub(1,-2) .. d .. W
    else
      w[#w+1] = W
    end
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
  width = 80*7,
  height = 25*16,
  x = 0, y = 0,
  title = "LRunner",
  flags = {
    sdl.window.Borderless,
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
  local width, height = window:getSize()
  local ws = sdl.createRGBSurface(width, height)
  renderer:clear()
  ws:fillRect({{w = width, h = height, x = 0, y = 0}, bg})
  for i=1, #lines do
    local s = font:renderUtf8(lines[i].text or lines[i], "shaded", i == selected and 0xAAAAFF or 0xFFFFFF)--, i == selected and bg_focused or bg)
    ws:fillRect({w = width, h = size + 4, x = 0, y = (size + 4) * (i - 1)}, i == selected and bg_focused or bg)
    s:blit(ws, nil, {w = width, h = size + 4, x = 0, y = (size + 4) * (i - 1)})
  end
  local tex = renderer:createTextureFromSurface(ws)
  renderer:copy(tex)
  renderer:present()
end

local quit

local query, position, results, selected = "", 0, {}, 1
local queries, cqid = {}, 0

local runners = {}
local processing = {}
do
  local dirs_global, dirs_local = config.global and config.global.searchers, config.user and config.user.searchers
  local function add_runners(dirs)
    for i=1, #dirs do
      local files = dirent.dir(dirs[i])
      table.sort(files)
      for f=1, #files do if files[f]:sub(1,1) ~= "." then runners[#runners+1] = dirs[i].."/"..files[f] end end
    end
  end

  if dirs_local then add_runners(dirs_local) end
  if dirs_global then add_runners(dirs_global) end
end

local function beginQuery(text)
  selected = 1
  local id = math.random(100000, 999999)
  if #text == 0 then
    results = {}
    for i=#processing, 1, -1 do table.remove(processing, i).handle:close() end
    return end
  local handle = inotify.init { blocking = false }
  local watchers = {}
  local pids = {}
  for i=1, #runners do
    local runner_id = math.random(1000000, 9999999)
    local output_file = "/tmp/lrunner-"..id.."-"..runner_id
    -- create output file
    io.open(output_file, "w"):close()
    -- launch searcher in new process
    local pid = unistd.fork()
    if pid == 0 then
      handle:close()
      --sdl.quit()
      local fd = fcntl.open(output_file, fcntl.O_WRONLY)
      unistd.dup2(fd, 1) -- redirect stdout to tmpfile
      unistd.execp(runners[i], {text})
    else
      pids[i] = pid
      local wid = handle:addwatch(output_file, inotify.IN_CLOSE_WRITE)
      if wid then watchers[wid] = output_file end
    end
  end
  cqid = id
  queries[cqid] = {handle = handle, pids = pids, watchers = watchers}
end

-- TODO: handle `:` in search queries?
local function processResult(line)
  local text, action, qualify = table.unpack(split(line, ":", "%"))
  if not text or #text == 0 then return end
  local result = {}
  if action:sub(1,8) == "complete" then
    result.text = "... | " .. text
    local provided = action:match("%b()")
    if provided then provided = provided:sub(2,-2) end
    result.complete = provided or text
  elseif action:sub(1,4) == "exec" then
    result.text = "~$: | " .. text
    result.exec = action:match("%b()"):sub(2,-2)
  elseif action:sub(1,3) == "lua" then
    result.text = "lua | " .. text
    result.lua = action:match("%b()")
  elseif action:sub(1,4) == "copy" then
    result.text = " ^C | " .. text
    result.copy = text
  elseif action:sub(1,4) == "open" then
    result.text = "</> | " .. text
    result.open = action:match("%b()"):sub(2,-2)
  end

  result.qualify = qualify

  results[#results+1] = result
  
  table.sort(results, function(a, b) return a.text < b.text end)
end

local hidden = false
local function act(result)
  if result.lua then
    -- TODO
  elseif result.exec then
    hidden = true
    local pid = unistd.fork()
    if pid == 0 then
      -- hack to make this work correctly
      local pidReal = unistd.fork()
      if pidReal == 0 then
        unistd.execp("sh", {"-c", result.exec})
      else
        error("os.exit() doesn't work here for some reason", 0)
        os.exit(0)
      end
    else
      wait.wait(pid)
    end
  elseif result.open then
    local editor = config_get("programs.editor") or "/bin/xdg-open"
    local files = config_get("programs.files") or "/bin/xdg-open"
    local info = stat.stat(result.open)
    hidden = true
    local pid = unistd.fork()
    if pid == 0 then
      if stat.S_ISDIR(info.st_mode) ~= 0 then
        unistd.execp("sh", {"-c", files.." "..result.open, "&", "exit"})
      else
        unistd.execp("sh", {"-c", editor.." "..result.open})
      end
    end
  elseif result.complete then
    query = result.complete
    position = #query
    beginQuery(query)
    hidden = false
  elseif result.copy then
    hidden = true
    local pid = unistd.fork()
    if pid == 0 then
      unistd.execp(config_get("programs.clipboard") or "wl-copy", {result.copy})
    end
  end
end

local function processEvent(e)
  if e.type == sdl.event.Quit then
    quit = true
  elseif e.type == sdl.event.WindowEvent then
    if e.event == sdl.eventWindow.FocusLost then
      window:raise()
    end
  elseif e.type == sdl.event.TextInput then
    query = query:sub(1, position) .. e.text .. query:sub(position + 1)
    position = position + 1
    beginQuery(query)
  elseif e.type == sdl.event.KeyDown then
    if e.keysym.sym == sdl.key.Backspace then
      query = query:sub(1, position - 1) .. query:sub(position + 1)
      position = math.max(0, position - 1)
      beginQuery(query)
    elseif e.keysym.sym == sdl.key.Delete then
      query = query:sub(1, position) .. query:sub(position + 2)
      beginQuery(query)
    elseif e.keysym.sym == sdl.key.Escape then
      if #query == 0 then
        hidden = true
      else
        query = ""
        position = 0
      end
    elseif e.keysym.sym == sdl.key.Home then
      position = 0
    elseif e.keysym.sym == sdl.key.End then
      position = #query
    elseif e.keysym.sym == sdl.key.Left then
      position = math.max(0, position - 1)
    elseif e.keysym.sym == sdl.key.Right then
      position = math.min(#query, position + 1)
    elseif e.keysym.sym == sdl.key.Up then
      selected = math.max(1, selected - 1)
    elseif e.keysym.sym == sdl.key.Down then
      selected = math.max(1, math.min(#results, selected + 1))
    elseif e.keysym.sym == sdl.key.Return then
      if results[selected] then
        hidden = true
        act(results[selected])
      end
    end
  end
end

local function checkResults()
  local cq = queries[cqid]
  -- trim old queries
  for k, v in pairs(queries) do
    -- wait for searcher processes
    for i=#v.pids, 1, -1 do
      if select(2, wait.wait(v.pids[i], wait.WNOHANG)) ~= "running" then
        wait.wait(v.pids[i])
        table.remove(v.pids, i)
      end
    end

    if k ~= cqid then -- don't trim current
      -- close inotify handle, if open
      if v.handle then
        v.handle:close()
        v.handle = nil
      end
      -- close results handle and clean up tmpfile
      for i=#processing, 1, -1 do
        if processing[i].qid == k then
          processing[i].handle:close()
          os.remove(processing[i].file)
          table.remove(processing, i)
        end
      end
      for i=#v.pids, 1, -1 do
        signal.kill(v.pids[i])
      end
      -- remove from table once all searcher processes have exited
      if #v.pids == 0 then
        queries[k] = nil
      end
    end
  end

  local got_results = false
  if cq then
    for e in cq.handle:events() do
      local wid = e.wd
      local handle = io.open(cq.watchers[wid], "r")
      if not cq.got_results then results = {} end
      cq.got_results = true
      got_results = true
      if handle then
        processing[#processing+1] = {handle = handle, qid = cqid, file = cq.watchers[wid]}
      end
    end
  end
end

local lr = io.open("/tmp/lrunner-process", "w")
lr:write(tostring(unistd.getpid()))
lr:close()

local lrp = inotify.init {blocking=true}
lrp:addwatch("/tmp/lrunner-process", inotify.IN_ACCESS)

while not quit do
  if hidden then
    local e = lrp:read()
    hidden = false
    if not hidden then window:show() end
  else
    local _, h = window:getSize()
    local maxnum = math.ceil(h / (size + 4))
    render(table.pack("? " .. query:sub(1,position).."|"..query:sub(position+1) .. " ", table.unpack(results, 1, maxnum)), selected+1)
    for e in sdl.pollEvent() do
      processEvent(e)
    end
    checkResults()
    -- process 100 results per update
    -- not _fast_ on my machine, but keeps things moving
    local total = 0
    local max = config_get("performance.results_per_render")
    for i=#processing, 1, -1 do
      repeat
        local line = processing[i].handle:read("l")
        if line then
          total = total + 1
          processResult(line)
        else
          -- clean up file
          os.remove(processing[i].file)
          table.remove(processing, i).handle:close()
        end
      until total >= max or not line
      if total >= max then break end
    end

    -- cpu time optimization: block on waiting for an event if the current query has no remaining queries
    if #processing == 0 then
      local e = sdl.waitEvent(300)
      if e then
        processEvent(e)
      end
    end
    if hidden then window:hide() end
  end
end

sdl.quit()
