--- Clip and pad a string to a display width.
-- Clipping walks whole UTF-8 characters. A byte chop through a marker such as
-- "·" or "…" makes utf8 width measurement raise and tears down the UI.

local utf8 = utf8

local M = {}

local ELLIPSIS = "…"

-- Drop one trailing UTF-8 character, including a broken tail.
local function drop_last(s)
  local i = #s
  if i == 0 then
    return s
  end
  while i > 1 and s:byte(i) >= 0x80 and s:byte(i) < 0xC0 do
    i = i - 1
  end
  return s:sub(1, i - 1)
end

function M.sanitize(s)
  s = tostring(s or "")
  local parts = {}
  local i = 1
  local n = #s
  while i <= n do
    local ok, cp, next_i = pcall(function()
      local code = utf8.codepoint(s, i)
      return code, utf8.offset(s, 2, i)
    end)
    if ok and cp then
      if next_i then
        parts[#parts + 1] = s:sub(i, next_i - 1)
        i = next_i
      else
        parts[#parts + 1] = s:sub(i)
        break
      end
    else
      parts[#parts + 1] = "?"
      i = i + 1
    end
  end
  return table.concat(parts)
end

local function measure(s, swidth)
  local ok, n = pcall(swidth, s)
  if ok then
    return s, n
  end
  s = M.sanitize(s)
  return s, swidth(s)
end

function M.fit(s, maxw, swidth)
  swidth = swidth or function(text)
    return #tostring(text)
  end
  s = tostring(s or "")
  if maxw <= 0 then
    return ""
  end
  local width
  s, width = measure(s, swidth)
  if width <= maxw then
    return s
  end
  local mark = ELLIPSIS
  local mark_w
  mark, mark_w = measure(mark, swidth)
  if mark_w > maxw then
    mark = ""
    mark_w = 0
  end
  local budget = maxw - mark_w
  while #s > 0 do
    local current
    s, current = measure(s, swidth)
    if current <= budget then
      break
    end
    local shorter = drop_last(s)
    if #shorter == #s then
      s = ""
      break
    end
    s = shorter
  end
  return s .. mark
end

function M.pad(s, width, swidth)
  swidth = swidth or function(text)
    return #tostring(text)
  end
  local measured
  s, measured = measure(tostring(s or ""), swidth)
  local gap = width - measured
  if gap > 0 then
    return s .. string.rep(" ", gap)
  end
  return s
end

return M
