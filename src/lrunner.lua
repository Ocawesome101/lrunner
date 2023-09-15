#!/usr/bin/env lua5.3
-- depends on inotify and luaposix

local inotify = require("inotify")
local unistd = require("posix.unistd")

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
