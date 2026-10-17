--- Argument vectors for doctl, kubectl, and clusterlint, plus fixture lookup.

local M = {}

local JSON = { "--output", "json", "--interactive=false" }

local function doctl(args)
  local argv = { "doctl" }
  for _, arg in ipairs(args) do
    argv[#argv + 1] = arg
  end
  for _, flag in ipairs(JSON) do
    argv[#argv + 1] = flag
  end
  return argv
end

function M.account_specs()
  local function spec(id, args)
    return {
      id = id,
      priority = 40,
      parse = "json",
      argv = doctl(args),
    }
  end
  return {
    spec("droplets", { "compute", "droplet", "list" }),
    spec("block_storage", { "compute", "volume", "list" }),
    spec("firewalls", { "compute", "firewall", "list" }),
    spec("reserved_ips", { "compute", "reserved-ip", "list" }),
    spec("snapshots", { "compute", "snapshot", "list" }),
    spec("databases", { "databases", "list" }),
    spec("networks", { "vpcs", "list" }),
    spec("projects", { "projects", "list" }),
  }
end

function M.cluster_list()
  return {
    id = "clusters",
    priority = 10,
    parse = "json",
    argv = doctl({ "kubernetes", "cluster", "list" }),
  }
end

function M.cluster_specs(cluster)
  local id = cluster.id or cluster.name
  return {
    {
      id = "cluster",
      priority = 10,
      parse = "json",
      argv = doctl({ "kubernetes", "cluster", "get", id }),
    },
    {
      id = "upgrades",
      priority = 10,
      parse = "json",
      argv = doctl({ "kubernetes", "cluster", "get-upgrades", id }),
    },
    {
      id = "node_pools",
      priority = 10,
      parse = "json",
      argv = doctl({ "kubernetes", "cluster", "node-pool", "list", id }),
    },
    {
      id = "associated",
      priority = 10,
      parse = "json",
      argv = doctl({ "kubernetes", "cluster", "list-associated-resources", id }),
    },
    {
      id = "domains",
      priority = 10,
      parse = "json",
      argv = doctl({ "compute", "domain", "list" }),
    },
    {
      id = "kubeconfig",
      priority = 5,
      parse = "json",
      argv = { "kubectl", "config", "view", "-o", "json" },
    },
  }
end

local function kubectl(context_name, kind, namespaced)
  local argv = { "kubectl", "--context", context_name, "get", kind, "-o", "json", "--request-timeout=15s" }
  if namespaced then
    table.insert(argv, 5, "-A")
  end
  return argv
end

function M.kubectl_specs(context_name)
  local function spec(id, kind, namespaced, priority)
    return {
      id = id,
      priority = priority or 20,
      parse = "json",
      argv = kubectl(context_name, kind, namespaced),
    }
  end
  return {
    spec("nodes", "nodes", false, 20),
    spec("namespaces", "namespaces", false, 20),
    spec("pods", "pods", true, 20),
    spec("deployments", "deployments", true, 20),
    spec("statefulsets", "statefulsets", true, 20),
    spec("daemonsets", "daemonsets", true, 20),
    spec("services", "services", true, 20),
    spec("ingresses", "ingresses", true, 20),
    spec("pvcs", "persistentvolumeclaims", true, 20),
    spec("pvs", "persistentvolumes", false, 20),
  }
end

function M.lint_spec(context_name)
  return {
    id = "lint",
    priority = 100,
    parse = "json",
    argv = { "clusterlint", "--context", context_name, "--timeout", "30s", "run", "--output", "json" },
  }
end

function M.lb_spec(id)
  return {
    id = "lb__" .. id,
    priority = 30,
    parse = "json",
    argv = doctl({ "compute", "load-balancer", "get", id }),
  }
end

function M.volume_spec(id)
  return {
    id = "volume__" .. id,
    priority = 30,
    parse = "json",
    argv = doctl({ "compute", "volume", "get", id }),
  }
end

function M.records_spec(domain)
  return {
    id = "records__" .. domain,
    priority = 30,
    parse = "json",
    argv = doctl({ "compute", "domain", "records", "list", domain }),
  }
end

function M.save_kubeconfig(cluster)
  return {
    id = "kubeconfig_save",
    priority = 0,
    parse = "text",
    argv = {
      "doctl", "kubernetes", "cluster", "kubeconfig", "save",
      cluster.id or cluster.name, "--interactive=false",
    },
  }
end

--- Map an argv to a fixture file name. Order matters.
function M.fixture_name(argv)
  local text = table.concat(argv, " ")
  if text:find("get%-upgrades", 1) then
    return "upgrades.json"
  end
  if text:find("node%-pool list", 1) then
    return "node_pools.json"
  end
  if text:find("list%-associated%-resources", 1) then
    return "associated.json"
  end
  if text:find("kubeconfig save", 1, true) then
    return "kubeconfig_save.txt"
  end
  if text:find("cluster list", 1, true) then
    return "clusters.json"
  end
  if text:find("cluster get", 1, true) then
    return "cluster.json"
  end
  if text:find("load%-balancer", 1) then
    return "load_balancers.json"
  end
  if text:find("volume get", 1, true) or text:find("volume list", 1, true) then
    return "volumes.json"
  end
  if text:find("domain records", 1, true) then
    local domain = argv[#argv - 3]
    if domain and domain:find("%.") then
      local specific = "records-" .. domain .. ".json"
      return specific, "records.json"
    end
    return "records.json"
  end
  if text:find("domain list", 1, true) then
    return "domains.json"
  end
  if text:find("droplet list", 1, true) then
    return "droplets.json"
  end
  if text:find("firewall list", 1, true) then
    return "firewalls.json"
  end
  if text:find("reserved%-ip list", 1) then
    return "reserved_ips.json"
  end
  if text:find("snapshot list", 1, true) then
    return "snapshots.json"
  end
  if text:find("databases list", 1, true) then
    return "databases.json"
  end
  if text:find("vpcs list", 1, true) then
    return "vpcs.json"
  end
  if text:find("projects list", 1, true) then
    return "projects.json"
  end
  if text:find("config view", 1, true) then
    return "kubeconfig.json"
  end
  if argv[1] == "clusterlint" then
    return "lint.json"
  end
  -- Kind is a whole argument, so `-A` between `get` and the kind still matches.
  local function kind(name)
    for _, arg in ipairs(argv) do
      if arg == name then
        return true
      end
    end
    return false
  end
  if kind("namespaces") then
    return "namespaces.json"
  end
  if kind("nodes") then
    return "nodes.json"
  end
  if kind("pods") then
    return "pods.json"
  end
  if kind("deployments") then
    return "deployments.json"
  end
  if kind("statefulsets") then
    return "statefulsets.json"
  end
  if kind("daemonsets") then
    return "daemonsets.json"
  end
  if kind("services") then
    return "services.json"
  end
  if kind("ingresses") then
    return "ingresses.json"
  end
  if kind("persistentvolumeclaims") then
    return "pvcs.json"
  end
  if kind("persistentvolumes") then
    return "pvs.json"
  end
  return nil
end

local function slurp(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local body = f:read("a")
  f:close()
  return body
end

function M.read_fixture(dir, argv)
  local name, fallback = M.fixture_name(argv)
  if not name then
    return nil, "no fixture for: " .. table.concat(argv, " ")
  end
  local body = slurp(dir .. "/" .. name)
  if body == nil and fallback then
    body = slurp(dir .. "/" .. fallback)
  end
  if body == nil then
    return nil, "missing fixture " .. name
  end
  return body
end

--- When one fixture file holds many objects, pick the one this argv asked for.
function M.narrow(argv, decoded)
  if type(decoded) ~= "table" then
    return decoded
  end
  local text = table.concat(argv, " ")
  local function pick(id)
    if decoded[1] == nil then
      return decoded
    end
    for _, item in ipairs(decoded) do
      if type(item) == "table" and (item.id == id or item.name == id) then
        return item
      end
    end
    return decoded
  end
  if text:find("load%-balancer get", 1) or text:find("volume get", 1) then
    return pick(argv[#argv - 3])
  end
  return decoded
end

return M
