--- Normalize the JSON shapes doctl, kubectl, and clusterlint actually emit.

local M = {}

local function is_list(value)
  return type(value) == "table" and value[1] ~= nil
end

function M.as_list(decoded)
  if type(decoded) ~= "table" then
    return {}
  end
  if is_list(decoded) then
    return decoded
  end
  if decoded.kubernetes_clusters then
    return decoded.kubernetes_clusters
  end
  if decoded.kubernetes_cluster then
    return { decoded.kubernetes_cluster }
  end
  if next(decoded) == nil then
    return {}
  end
  return { decoded }
end

function M.kube_items(decoded)
  if type(decoded) ~= "table" then
    return {}
  end
  if type(decoded.items) == "table" then
    return decoded.items
  end
  return {}
end

--- One object from a doctl get, which is sometimes the object and sometimes a one-element array.
function M.object(decoded)
  if type(decoded) ~= "table" then
    return {}
  end
  if is_list(decoded) then
    if type(decoded[1]) == "table" then
      return decoded[1]
    end
    return {}
  end
  return decoded
end

local function resource_id(item)
  if type(item) == "string" and item ~= "" then
    return item
  end
  if type(item) == "table" then
    local id = item.id or item.ID
    if type(id) == "string" and id ~= "" then
      return id
    end
  end
  return nil
end

function M.associated(decoded)
  local empty = { volumes = {}, volume_snapshots = {}, load_balancers = {} }
  if type(decoded) ~= "table" then
    return empty
  end
  if is_list(decoded) then
    return M.associated(decoded[1])
  end
  local function ids(snake, pascal)
    local value = decoded[snake] or decoded[pascal] or {}
    if type(value) ~= "table" then
      return {}
    end
    local out = {}
    for _, item in ipairs(value) do
      local id = resource_id(item)
      if id then
        out[#out + 1] = id
      end
    end
    return out
  end
  return {
    volumes = ids("volumes", "Volumes"),
    volume_snapshots = ids("volume_snapshots", "VolumeSnapshots"),
    load_balancers = ids("load_balancers", "LoadBalancers"),
  }
end

function M.upgrades(decoded)
  local versions = {}
  local function add(value)
    if type(value) == "string" and value ~= "" then
      versions[#versions + 1] = value
    elseif type(value) == "table" then
      local slug = value.slug or value.version or value.kubernetes_version or value.Version
      if type(slug) == "string" and slug ~= "" then
        versions[#versions + 1] = slug
      end
    end
  end
  if type(decoded) ~= "table" then
    return versions
  end
  local list = decoded.available_upgrades or decoded.available_upgrade_versions or decoded
  if type(list) ~= "table" then
    return versions
  end
  if list[1] == nil and (list.slug or list.version) then
    add(list)
    return versions
  end
  for _, item in ipairs(list) do
    add(item)
  end
  return versions
end

function M.diagnostics(decoded)
  if type(decoded) ~= "table" then
    return {}
  end
  local list = decoded.diagnostics or decoded.Diagnostics
  if list == nil then
    if decoded.Check or decoded.check or decoded.check_name then
      list = { decoded }
    elseif decoded[1] ~= nil then
      list = decoded
    else
      return {}
    end
  end
  if list.Check or list.check or list.check_name then
    list = { list }
  end
  local out = {}
  for _, item in ipairs(list) do
    local obj = item.Object or item.object or {}
    out[#out + 1] = {
      check = item.Check or item.check or item.check_name or "",
      severity = string.lower(tostring(item.Severity or item.severity or "")),
      message = item.Message or item.message or "",
      kind = string.lower(tostring(item.Kind or item.kind or obj.kind or "")),
      name = obj.name or obj.Name or item.name or "",
      namespace = obj.namespace or obj.Namespace or item.namespace or "",
    }
  end
  return out
end

function M.status_state(cluster)
  local status = cluster and cluster.status
  if type(status) == "string" then
    return status
  end
  if type(status) == "table" then
    return status.state or ""
  end
  return ""
end

return M
