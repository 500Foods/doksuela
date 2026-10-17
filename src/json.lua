--- JSON encode and decode. Prefers a LuaRocks dkjson, then the vendored copy.

local ok, dkjson = pcall(require, "dkjson")
if not ok then
  error("dkjson is not available: " .. tostring(dkjson))
end

local M = {}

function M.decode(s)
  if type(s) ~= "string" or s == "" then
    return nil, "empty response"
  end
  local value, _, err = dkjson.decode(s, 1, nil)
  if err then
    return nil, err
  end
  return value
end

function M.encode(value)
  return dkjson.encode(value)
end

return M
