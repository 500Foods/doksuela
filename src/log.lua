--- Append-only command log. Tokens are scrubbed before they touch disk or memory.

local json = require("doksuela.json")

local M = {}

local REDACT_NEXT = {
  ["--access-token"] = true,
  ["-t"] = true,
  ["--token"] = true,
}

function M.looks_like_token(s)
  if type(s) ~= "string" then
    return false
  end
  if s:find("^dop_v1_") then
    return true
  end
  if s:find("^sk%-") or s:find("^sk_") then
    return true
  end
  if s:find("Bearer ") then
    return true
  end
  return false
end

function M.scrub_argv(argv)
  local out = {}
  local redact_next = false
  for i, arg in ipairs(argv) do
    local text = tostring(arg)
    if redact_next or M.looks_like_token(text) then
      out[i] = "***"
      redact_next = false
    else
      out[i] = text
      if REDACT_NEXT[text] then
        redact_next = true
      end
    end
  end
  return out
end

function M.format_duration(seconds)
  seconds = tonumber(seconds) or 0
  if seconds < 0 or seconds ~= seconds or seconds == math.huge then
    seconds = 0
  end
  return string.format("%07.3f", seconds)
end

local function utc_epoch(iso)
  if type(iso) ~= "string" then
    return nil
  end
  local y, mo, d, h, mi, se = iso:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
  if not y then
    return nil
  end
  local as_local = os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(se),
  })
  if not as_local then
    return nil
  end
  local now = os.time()
  local utc_now = os.time(os.date("!*t", now))
  return as_local - os.difftime(now, utc_now)
end

function M.format_started(rec)
  rec = rec or {}
  local epoch = tonumber(rec.started)
  if not epoch then
    epoch = utc_epoch(rec.time)
    if epoch then
      epoch = epoch - (tonumber(rec.duration) or 0)
    end
  end
  if not epoch then
    return ""
  end
  return os.date("%Y-%m-%d %H:%M:%S", math.floor(epoch))
end

function M.open(path)
  local command_log = { path = path, records = {} }
  if not path then
    return command_log
  end
  local f = io.open(path, "r")
  if not f then
    return command_log
  end
  for line in f:lines() do
    local rec = json.decode(line)
    if type(rec) == "table" and type(rec.argv) == "table" then
      command_log.records[#command_log.records + 1] = rec
    end
  end
  f:close()
  return command_log
end

function M.append(command_log, rec)
  local stderr = rec.stderr or ""
  if #stderr > 4000 then
    stderr = stderr:sub(-4000)
  end
  local copy = {
    time = rec.time or os.date("!%Y-%m-%dT%H:%M:%SZ"),
    started = tonumber(rec.started),
    duration = rec.duration or 0,
    exit = rec.exit or 0,
    argv = M.scrub_argv(rec.argv or {}),
    stderr = stderr,
  }
  command_log.records[#command_log.records + 1] = copy
  if command_log.path then
    local f = io.open(command_log.path, "a")
    if f then
      f:write(json.encode(copy), "\n")
      f:close()
    end
  end
  return copy
end

return M
