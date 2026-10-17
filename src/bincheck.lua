--- Report CLIs that are not on PATH.

local M = {}

function M.missing(names)
  local gone = {}
  for _, name in ipairs(names) do
    local pipe = io.popen("command -v " .. name .. " 2>/dev/null", "r")
    local found = pipe and pipe:read("*l")
    if pipe then
      pipe:close()
    end
    if not found or found == "" then
      gone[#gone + 1] = name
    end
  end
  return gone
end

return M
