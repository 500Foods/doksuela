--- Join DigitalOcean objects with Kubernetes objects.

local shape = require("doksuela.shape")

local M = {}

local LB_ANNOTATIONS = {
  "service.beta.kubernetes.io/do-loadbalancer-id",
  "kubernetes.digitalocean.com/load-balancer-id",
}

local function host_of(url)
  if type(url) ~= "string" then
    return ""
  end
  return url:gsub("^https?://", ""):gsub("/.*$", ""):gsub(":%d+$", "")
end

function M.context_for(cluster, kube)
  if type(cluster) ~= "table" or type(kube) ~= "table" then
    return nil
  end
  local want = host_of(cluster.endpoint)
  local cluster_names = {}
  for _, entry in ipairs(kube.clusters or {}) do
    local server = ((entry.cluster or {}).server) or ""
    if want ~= "" and host_of(server) == want then
      cluster_names[entry.name] = true
    end
  end
  for _, ctx in ipairs(kube.contexts or {}) do
    local cluster_name = (ctx.context or {}).cluster
    if cluster_names[cluster_name] then
      return ctx.name
    end
  end
  if cluster.region and cluster.name then
    local fallback = "do-" .. cluster.region .. "-" .. cluster.name
    for _, ctx in ipairs(kube.contexts or {}) do
      if ctx.name == fallback then
        return fallback
      end
    end
  end
  return nil
end

local function ready_of(node)
  for _, condition in ipairs((node.status or {}).conditions or {}) do
    if condition.type == "Ready" then
      if condition.status == "True" then
        return "Ready"
      end
      return "NotReady"
    end
  end
  return "Unknown"
end

local function find_node(pool, droplet, by_name, items)
  if droplet.name and by_name[droplet.name] then
    return by_name[droplet.name]
  end
  for _, node in ipairs(items) do
    local labels = (node.metadata or {}).labels or {}
    if droplet.id and labels["doks.digitalocean.com/node-id"] == droplet.id then
      return node
    end
    if pool.id and labels["doks.digitalocean.com/node-pool-id"] == pool.id
      and droplet.name == nil then
      return node
    end
  end
  return nil
end

function M.nodes(pools, node_list)
  pools = shape.as_list(pools)
  local items = shape.kube_items(node_list)
  local by_name = {}
  for _, node in ipairs(items) do
    local name = (node.metadata or {}).name
    if name then
      by_name[name] = node
    end
  end
  local used = {}
  local rows = {}
  local not_ready = 0
  for _, pool in ipairs(pools) do
    local droplets = pool.nodes or {}
    if #droplets == 0 then
      rows[#rows + 1] = {
        pool = pool,
        node = nil,
        droplet = nil,
        status = "empty pool",
        missing = "no droplets reported",
      }
    end
    for _, droplet in ipairs(droplets) do
      local node = find_node(pool, droplet, by_name, items)
      local status
      local missing
      if node then
        used[(node.metadata or {}).name] = true
        status = ready_of(node)
      else
        status = "missing from Kubernetes"
        missing = "missing from Kubernetes"
      end
      if status ~= "Ready" then
        not_ready = not_ready + 1
      end
      rows[#rows + 1] = {
        pool = pool,
        node = node,
        droplet = droplet,
        status = status,
        missing = missing,
      }
    end
  end
  for _, node in ipairs(items) do
    local name = (node.metadata or {}).name
    if name and not used[name] then
      local status = ready_of(node)
      if status ~= "Ready" then
        not_ready = not_ready + 1
      end
      rows[#rows + 1] = {
        pool = nil,
        node = node,
        droplet = nil,
        status = status,
        missing = "missing from DigitalOcean node pools",
      }
    end
  end
  return {
    rows = rows,
    k8s_count = #items,
    not_ready = not_ready,
    pool_count = #pools,
  }
end

function M.lb_id(service)
  local annotations = (service.metadata or {}).annotations or {}
  for _, key in ipairs(LB_ANNOTATIONS) do
    if annotations[key] and annotations[key] ~= "" then
      return annotations[key]
    end
  end
  return nil
end

function M.lb_pending(service)
  if ((service.spec or {}).type) ~= "LoadBalancer" then
    return false
  end
  local ingress = (((service.status or {}).loadBalancer or {}).ingress) or {}
  return #ingress == 0
end

local DOBS = "dobs.csi.digitalocean.com"

function M.volume_handle(pv)
  local csi = (pv.spec or {}).csi
  if type(csi) ~= "table" then
    return nil
  end
  if csi.driver ~= DOBS then
    return nil
  end
  return csi.volumeHandle
end

function M.hostnames(ingresses, services)
  local seen = {}
  local list = {}
  local function add(host, source)
    if type(host) ~= "string" or host == "" or seen[host] then
      return
    end
    seen[host] = true
    list[#list + 1] = { host = host, source = source }
  end
  for _, ingress in ipairs(ingresses or {}) do
    local meta = ingress.metadata or {}
    local source = "ingress " .. (meta.namespace or "") .. "/" .. (meta.name or "")
    for _, rule in ipairs((ingress.spec or {}).rules or {}) do
      add(rule.host, source)
    end
    for _, tls in ipairs((ingress.spec or {}).tls or {}) do
      for _, host in ipairs(tls.hosts or {}) do
        add(host, source)
      end
    end
  end
  for _, service in ipairs(services or {}) do
    local spec = service.spec or {}
    if spec.type == "ExternalName" and spec.externalName then
      local meta = service.metadata or {}
      add(spec.externalName, "service " .. (meta.namespace or "") .. "/" .. (meta.name or ""))
    end
  end
  table.sort(list, function(a, b)
    return a.host < b.host
  end)
  return list
end

function M.dns(hosts, domains, records_by_domain, addresses)
  local wanted = {}
  for _, address in ipairs(addresses or {}) do
    wanted[address] = true
  end
  local rows = {}
  local unmatched = 0
  for _, host in ipairs(hosts) do
    local matched
    for _, domain in ipairs(domains or {}) do
      local name = domain.name or domain
      if type(name) == "string" and (host.host == name or host.host:sub(-(#name + 1)) == "." .. name) then
        local label = host.host == name and "@" or host.host:sub(1, #host.host - #name - 1)
        for _, rec in ipairs(records_by_domain[name] or {}) do
          local rec_name = rec.name or ""
          if (rec_name == label or rec_name == host.host) and wanted[rec.data] then
            matched = rec
            break
          end
        end
      end
      if matched then
        break
      end
    end
    if not matched then
      unmatched = unmatched + 1
    end
    rows[#rows + 1] = {
      host = host.host,
      source = host.source,
      record = matched,
    }
  end
  return rows, unmatched
end

return M
