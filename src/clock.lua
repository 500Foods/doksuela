--- Wall clock. LuaSystem's gettime returns seconds as a float when it is installed.

local ok, system = pcall(require, "system")

local M = {}

function M.wall()
  if ok and system.gettime then
    local seconds, fraction = system.gettime()
    if type(seconds) == "number" and type(fraction) == "number" then
      return seconds + fraction / 1e6
    end
    if type(seconds) == "number" then
      return seconds
    end
  end
  return os.time()
end

return M
