--- Clip and pad a string to a display width.

local M = {}

function M.fit(s, maxw, swidth)
  swidth = swidth or function(text)
    return #tostring(text)
  end
  s = tostring(s or "")
  if maxw <= 0 then
    return ""
  end
  if swidth(s) <= maxw then
    return s
  end
  if maxw == 1 then
    return "…"
  end
  local budget = maxw - 1
  while #s > 0 and swidth(s) > budget do
    s = s:sub(1, -2)
  end
  return s .. "…"
end

function M.pad(s, width, swidth)
  swidth = swidth or function(text)
    return #tostring(text)
  end
  s = tostring(s or "")
  local gap = width - swidth(s)
  if gap > 0 then
    return s .. string.rep(" ", gap)
  end
  return s
end

return M
