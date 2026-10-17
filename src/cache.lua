--- On-disk snapshots under ~/.cache/doksuela.

local json = require("doksuela.json")
local exec = require("doksuela.exec")

local M = {}

local function safe(id)
  return (tostring(id):gsub("[^%w._%-]", "_"))
end

function M.ensure(dir)
  os.execute("mkdir -p " .. exec.quote(dir))
end

function M.open(root)
  M.ensure(root)
  return { root = root }
end

function M.read_json(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local body = f:read("a")
  f:close()
  if not body or body == "" then
    return nil
  end
  local value, err = json.decode(body)
  if err then
    return nil
  end
  return value
end

function M.write_json(path, value)
  local dir = path:match("^(.*)/[^/]+$")
  if dir then
    M.ensure(dir)
  end
  local f = assert(io.open(path, "wb"))
  f:write(json.encode(value))
  f:close()
end

function M.load_state(store)
  return M.read_json(store.root .. "/state.json") or {}
end

function M.save_state(store, state)
  local current = M.load_state(store)
  local out = {
    cluster_id = current.cluster_id,
    cluster_name = current.cluster_name,
  }
  if current.parallel ~= nil then
    out.parallel = current.parallel
  end
  if state.cluster_id ~= nil or state.cluster_name ~= nil then
    out.cluster_id = state.cluster_id
    out.cluster_name = state.cluster_name
  end
  if state.parallel ~= nil then
    out.parallel = state.parallel
  end
  M.write_json(store.root .. "/state.json", out)
end

function M.raw_path(store, cluster_id, check_id)
  return store.root .. "/clusters/" .. safe(cluster_id) .. "/" .. safe(check_id) .. ".json"
end

function M.load_raw(store, cluster_id, check_id)
  return M.read_json(M.raw_path(store, cluster_id, check_id))
end

function M.save_raw(store, cluster_id, check_id, value)
  M.write_json(M.raw_path(store, cluster_id, check_id), value)
end

function M.list_raw(store, cluster_id)
  local dir = store.root .. "/clusters/" .. safe(cluster_id)
  local pipe = io.popen("ls -1 " .. exec.quote(dir) .. " 2>/dev/null", "r")
  if not pipe then
    return {}
  end
  local names = {}
  for line in pipe:lines() do
    local id = line:match("^(.+)%.json$")
    if id then
      names[#names + 1] = id
    end
  end
  pipe:close()
  return names
end

return M
