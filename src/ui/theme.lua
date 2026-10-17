--- Freshness colors. Blue is the last cached check. Green is confirmed this session.
-- Shortcut letters are orange with no background. The Theme screen can replace any role.

local M = {
  cached = { fg = "blue", brightness = "bright" },
  fresh = { fg = "green", brightness = "bright" },
  dim = { fg = "white", brightness = "dim" },
  error = { fg = "yellow", brightness = "bright" },
  label = { fg = "white" },
  title = { fg = "white", brightness = "bright" },
  marker = { fg = "cyan", brightness = "bright" },
  border = { fg = "cyan", brightness = "bright" },
  muted = { fg = "white" },
  -- Orange #FFA500. No background.
  shortcut = { fg_r = 255, fg_g = 165, fg_b = 0 },
  -- Light gray #D3D3D3. The bar track stores its color as a foreground too,
  -- and the footer paints that color as the background.
  progress = { fg_r = 211, fg_g = 211, fg_b = 211 },
  progress_bg = { fg_r = 48, fg_g = 48, fg_b = 48 },
}

-- Colors the Theme screen can apply. Order is the Left/Right cycle.
M.palette = {
  { name = "orange", attr = { fg_r = 255, fg_g = 165, fg_b = 0 } },
  { name = "dark orange", attr = { fg_r = 255, fg_g = 140, fg_b = 0 } },
  { name = "amber", attr = { fg_r = 255, fg_g = 191, fg_b = 0 } },
  { name = "red", attr = { fg = "red", brightness = "bright" } },
  { name = "green", attr = { fg = "green", brightness = "bright" } },
  { name = "yellow", attr = { fg = "yellow", brightness = "bright" } },
  { name = "blue", attr = { fg = "blue", brightness = "bright" } },
  { name = "magenta", attr = { fg = "magenta", brightness = "bright" } },
  { name = "cyan", attr = { fg = "cyan", brightness = "bright" } },
  { name = "white", attr = { fg = "white", brightness = "bright" } },
  { name = "dim white", attr = { fg = "white", brightness = "dim" } },
  { name = "light gray", attr = { fg_r = 211, fg_g = 211, fg_b = 211 } },
  { name = "dark gray", attr = { fg_r = 48, fg_g = 48, fg_b = 48 } },
}

M.roles = {
  { id = "shortcut", label = "Shortcut", sample = "N", note = "Shortcut letters use this color." },
  { id = "fresh", label = "Fresh", sample = "12", note = "A check that succeeded in this session." },
  { id = "cached", label = "Cached", sample = "12", note = "A count remembered from an earlier session." },
  { id = "error", label = "Error", sample = "failed", note = "A failed recheck keeps the old count and shows this." },
  { id = "dim", label = "Unchecked", sample = "·", note = "No check has been stored yet." },
  { id = "marker", label = "Marker", sample = ">", note = "The cursor beside the selected row." },
  { id = "border", label = "Border", sample = "+", note = "The frame around the screen." },
  { id = "title", label = "Title", sample = "Title", note = "Headings and the selected row." },
  { id = "progress", label = "Progress", sample = "████", note = "The filled part of the progress bar." },
  { id = "progress_bg", label = "Bar track", sample = "████", note = "The progress bar background.", as_bg = true },
}

local FIELDS = { "fg", "fg_r", "fg_g", "fg_b", "bg", "bg_r", "bg_g", "bg_b", "brightness" }

local function copy_attr(attr)
  local out = {}
  for _, field in ipairs(FIELDS) do
    if attr[field] ~= nil then
      out[field] = attr[field]
    end
  end
  return out
end

local function same_attr(a, b)
  a = a or {}
  b = b or {}
  for _, field in ipairs(FIELDS) do
    if a[field] ~= b[field] then
      return false
    end
  end
  return true
end

function M.pick(name)
  return M[name] or M.label
end

-- Foreground from Progress, background from Bar track. The track role is stored
-- as a foreground color so Left/Right can cycle it like the others.
function M.bar_attr()
  local fg = M.progress or {}
  local bg = M.progress_bg or {}
  local attr = {}
  for _, field in ipairs({ "fg", "fg_r", "fg_g", "fg_b", "brightness" }) do
    if fg[field] ~= nil then
      attr[field] = fg[field]
    end
  end
  if bg.fg_r ~= nil then
    attr.bg_r = bg.fg_r
    attr.bg_g = bg.fg_g
    attr.bg_b = bg.fg_b
  elseif bg.fg ~= nil then
    attr.bg = bg.fg
  end
  return attr
end

function M.describe(attr)
  attr = attr or {}
  for _, choice in ipairs(M.palette) do
    if same_attr(choice.attr, attr) then
      return choice.name
    end
  end
  if attr.fg_r then
    return string.format("%d,%d,%d", attr.fg_r or 0, attr.fg_g or 0, attr.fg_b or 0)
  end
  local name = tostring(attr.fg or "default")
  if attr.brightness == "bright" then
    return "bright " .. name
  end
  if attr.brightness == "dim" then
    return "dim " .. name
  end
  return name
end

function M.cycle(id, direction)
  if M[id] == nil then
    return
  end
  local index = 1
  for i, choice in ipairs(M.palette) do
    if same_attr(choice.attr, M[id]) then
      index = i
      break
    end
  end
  local next_index = index + (direction or 1)
  if next_index < 1 then
    next_index = #M.palette
  elseif next_index > #M.palette then
    next_index = 1
  end
  M[id] = copy_attr(M.palette[next_index].attr)
end

function M.export()
  local out = {}
  for _, role in ipairs(M.roles) do
    out[role.id] = copy_attr(M[role.id] or {})
  end
  return out
end

function M.load(saved)
  if type(saved) ~= "table" then
    return
  end
  for _, role in ipairs(M.roles) do
    local attr = saved[role.id]
    if type(attr) == "table" and (attr.fg or attr.fg_r) then
      M[role.id] = copy_attr(attr)
    end
  end
end

return M
