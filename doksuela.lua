#!/usr/local/bin/lua
--- doksuela: a TUI for exploring DigitalOcean Kubernetes (DOKS) clusters.
-- Requires Lua 5.5 and the lunarmodules terminal.lua library.

if not _VERSION:find("^Lua 5%.5") then
  io.stderr:write("doksuela requires Lua 5.5 (found " .. _VERSION .. ")\n")
  os.exit(1)
end

local script = arg[0]
local root = script:match("^(.*)/") or "."

do
  local home = os.getenv("HOME") or ""
  local ver = "5.5"
  package.path = table.concat({
    root .. "/src/?.lua",
    root .. "/src/?/init.lua",
    root .. "/src/vendor/?.lua",
    home .. "/.luarocks/share/lua/" .. ver .. "/?.lua",
    home .. "/.luarocks/share/lua/" .. ver .. "/?/init.lua",
    package.path,
  }, ";")
  package.cpath = table.concat({
    home .. "/.luarocks/lib64/lua/" .. ver .. "/?.so",
    home .. "/.luarocks/lib/lua/" .. ver .. "/?.so",
    package.cpath,
  }, ";")
end

local fixture, cache_root
local index = 1
while index <= #arg do
  local item = arg[index]
  if item == "--fixture" and arg[index + 1] then
    fixture = arg[index + 1]
    index = index + 2
  elseif item == "--cache" and arg[index + 1] then
    cache_root = arg[index + 1]
    index = index + 2
  elseif item == "--help" or item == "-h" then
    io.stdout:write("Usage: doksuela [--fixture DIR] [--cache DIR]\n")
    os.exit(0)
  else
    io.stderr:write("unknown argument: " .. item .. "\n")
    os.exit(2)
  end
end

if fixture and fixture:sub(1, 1) ~= "/" then
  fixture = root .. "/" .. fixture
end

-- Checkout layout is src/<name>.lua. LuaRocks installs the same files as doksuela.<name>.
table.insert(package.searchers, 1, function(name)
  local rest = name:match("^doksuela%.(.+)$")
  if not rest then
    return nil
  end
  local path = root .. "/src/" .. rest:gsub("%.", "/") .. ".lua"
  local loader = loadfile(path)
  if loader then
    return loader, path
  end
  return nil
end)

local t = require("terminal")
local app = require("doksuela.app")

t.initwrap(function()
  app.run({
    fixture = fixture,
    cache_root = cache_root,
    root = root,
  })
end, {
  displaybackup = true,
  filehandle = io.stdout,
})()
