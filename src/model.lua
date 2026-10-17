--- Turn normalized API data into menu counts, context strings, and list rows.

local match = require("doksuela.match")
local shape = require("doksuela.shape")

local M = {}

local function ns_name(obj)
  local meta = obj.metadata or {}
  return meta.namespace or "", meta.name or ""
end

local function pvc_size(pvc)
  local cap = (pvc.status or {}).capacity
  if type(cap) == "table" and cap.storage then
    return cap.storage
  end
  local requests = (((pvc.spec or {}).resources or {}).requests) or {}
  return requests.storage or "—"
end

local function lines(parts)
  return table.concat(parts, "\n")
end

function M.parse_utc(ts)
  if type(ts) ~= "string" then
    return nil
  end
  local y, mo, d, h, mi, s = ts:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
  if not y then
    return nil
  end
  local as_local = os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(s),
  })
  local offset = os.difftime(os.time(), os.time(os.date("!*t")))
  return as_local + offset
end

function M.since(ts, now)
  local then_t = M.parse_utc(ts)
  if not then_t then
    return "—"
  end
  local delta = math.max(0, (now or os.time()) - then_t)
  if delta < 60 then
    return delta .. "s"
  end
  if delta < 3600 then
    return math.floor(delta / 60) .. "m"
  end
  if delta < 86400 then
    return math.floor(delta / 3600) .. "h"
  end
  return math.floor(delta / 86400) .. "d"
end

function M.ago(fetched_at, now, confirmed)
  if not fetched_at then
    return "not checked yet"
  end
  local delta = math.max(0, (now or os.time()) - fetched_at)
  local rel
  if delta < 10 then
    rel = "just now"
  elseif delta < 60 then
    rel = math.floor(delta) .. "s ago"
  elseif delta < 3600 then
    rel = math.floor(delta / 60) .. "m ago"
  elseif delta < 86400 then
    rel = math.floor(delta / 3600) .. "h ago"
  else
    rel = math.floor(delta / 86400) .. "d ago"
  end
  if confirmed then
    return "checked " .. rel
  end
  return "from cache, " .. rel
end

local function count_phrase(n, singular, plural)
  if n == 1 then
    return "1 " .. singular
  end
  return n .. " " .. (plural or (singular .. "s"))
end

function M.clusters(decoded)
  local list = {}
  for _, cluster in ipairs(shape.as_list(decoded)) do
    if type(cluster) == "table" and (cluster.id or cluster.name) then
      list[#list + 1] = cluster
    end
  end
  return list
end

function M.cluster_rows(clusters, current_id)
  local rows = {}
  for _, cluster in ipairs(clusters or {}) do
    local pools = cluster.node_pools or {}
    local mark = cluster.id == current_id and "current" or ""
    rows[#rows + 1] = {
      id = cluster.id,
      name = cluster.name,
      cells = {
        cluster.name or "—",
        cluster.region or "—",
        cluster.version or "—",
        shape.status_state(cluster),
        cluster.ha and "HA" or "—",
        tostring(#pools),
        mark,
      },
      detail = lines({
        "id: " .. tostring(cluster.id or "—"),
        "endpoint: " .. tostring(cluster.endpoint or "—"),
        "ipv4: " .. tostring(cluster.ipv4 or "—"),
        "vpc: " .. tostring(cluster.vpc_uuid or "—"),
      }),
    }
  end
  return rows
end

function M.overview(cluster, upgrades, context_name)
  cluster = shape.object(cluster)
  local versions = shape.upgrades(upgrades)
  local upgrade = #versions > 0 and table.concat(versions, ", ") or "no upgrades published"
  local maintenance = cluster.maintenance_policy or {}
  local bits = {
    "auto-upgrade " .. (cluster.auto_upgrade and "on" or "off"),
    "surge " .. (cluster.surge_upgrade and "on" or "off"),
    "maintenance " .. tostring(maintenance.day or "—") .. " " .. tostring(maintenance.start_time or ""),
    "registry " .. (cluster.registry_enabled and "on" or "off"),
    upgrade,
  }
  return {
    name = cluster.name or "—",
    region = cluster.region or "—",
    version = cluster.version or "—",
    status = shape.status_state(cluster),
    ha = cluster.ha and "HA" or "single control plane",
    context = context_name or "no context",
    context_line = table.concat(bits, "  "),
    count = cluster.version or "—",
  }
end

local function address_of(node, kind)
  for _, entry in ipairs(((node or {}).status or {}).addresses or {}) do
    if type(entry) == "table" and entry.type == kind then
      local address = entry.address
      if type(address) == "string" and address ~= "" then
        return address
      end
    end
  end
  return nil
end

-- The public address when the node has one, otherwise the in-cluster address.
local function node_ip(node)
  return address_of(node, "ExternalIP") or address_of(node, "InternalIP") or "—"
end

local function node_detail(row)
  local pool = row.pool or {}
  local node = row.node or {}
  local meta = node.metadata or {}
  local info = (node.status or {}).nodeInfo or {}
  local alloc = (node.status or {}).allocatable or {}
  local droplet = row.droplet or {}
  local scale = ""
  if pool.auto_scale then
    scale = "autoscale " .. tostring(pool.min_nodes or "?") .. "-" .. tostring(pool.max_nodes or "?")
  end
  local external = address_of(node, "ExternalIP")
  local internal = address_of(node, "InternalIP")
  local parts = {
    "pool: " .. tostring(pool.name or "—"),
    "size: " .. tostring(pool.size or "—"),
    scale,
    "node: " .. tostring(meta.name or droplet.name or "—"),
    "status: " .. tostring(row.status or "—"),
    "ip: " .. (external or internal or "—"),
  }
  if external and internal and external ~= internal then
    parts[#parts + 1] = "private: " .. internal
  end
  parts[#parts + 1] = "droplet: " .. tostring(droplet.droplet_id or droplet.id or "—")
  parts[#parts + 1] = "kubelet: " .. tostring(info.kubeletVersion or "—")
  parts[#parts + 1] = "cpu: " .. tostring(alloc.cpu or "—")
  parts[#parts + 1] = "memory: " .. tostring(alloc.memory or "—")
  parts[#parts + 1] = row.missing or ""
  return lines(parts)
end

function M.nodes(pools, node_list)
  local joined = match.nodes(pools, node_list)
  local rows = {}
  for _, row in ipairs(joined.rows) do
    local pool = row.pool or {}
    local node = row.node or {}
    local meta = node.metadata or {}
    local info = ((node.status or {}).nodeInfo) or {}
    local droplet = row.droplet or {}
    rows[#rows + 1] = {
      cells = {
        pool.name or "—",
        meta.name or droplet.name or "—",
        node_ip(node),
        address_of(node, "InternalIP") or "—",
        row.status or "—",
        pool.size or "—",
        info.kubeletVersion or "—",
        tostring(droplet.droplet_id or droplet.id or "—"),
      },
      detail = node_detail(row),
    }
  end
  return {
    count = tostring(joined.k8s_count),
    context = joined.not_ready .. " not ready, " .. count_phrase(joined.pool_count, "pool"),
    columns = { "pool", "node", "ip", "private", "status", "size", "kubelet", "droplet" },
    -- IPv4 addresses are 15 characters. Keep both columns at that width.
    widths = { nil, nil, 15, 15, nil, nil, nil, nil },
    rows = rows,
  }
end

local function pod_ready(pod)
  local statuses = (pod.status or {}).containerStatuses or {}
  local ready = 0
  for _, status in ipairs(statuses) do
    if status.ready then
      ready = ready + 1
    end
  end
  local total = #((pod.spec or {}).containers or {})
  if total == 0 then
    total = #statuses
  end
  return ready .. "/" .. total
end

local function restarts_of(pod)
  local n = 0
  for _, status in ipairs((pod.status or {}).containerStatuses or {}) do
    n = n + (status.restartCount or 0)
  end
  return n
end

local function requests_label(pod)
  for _, container in ipairs((pod.spec or {}).containers or {}) do
    local requests = (container.resources or {}).requests or {}
    if not requests.cpu or not requests.memory then
      return "requests: missing"
    end
  end
  return "requests: set"
end

function M.pods(decoded, now)
  local items = shape.kube_items(decoded)
  local bad = 0
  local rows = {}
  for _, pod in ipairs(items) do
    local phase = (pod.status or {}).phase or ""
    if phase ~= "Running" and phase ~= "Succeeded" then
      bad = bad + 1
    end
    local namespace, name = ns_name(pod)
    local containers = {}
    for _, container in ipairs((pod.spec or {}).containers or {}) do
      containers[#containers + 1] = (container.name or "?") .. "  " .. (container.image or "—")
    end
    rows[#rows + 1] = {
      kind = "pod",
      namespace = namespace,
      name = name,
      cells = {
        namespace,
        name,
        pod_ready(pod),
        phase,
        tostring(restarts_of(pod)),
        M.since((pod.metadata or {}).creationTimestamp, now),
        (pod.spec or {}).nodeName or "—",
      },
      detail = lines({
        namespace .. "/" .. name,
        "phase: " .. phase,
        requests_label(pod),
        table.concat(containers, "\n"),
      }),
    }
  end
  return {
    count = tostring(#items),
    context = bad .. " not running",
    columns = { "namespace", "name", "ready", "status", "restarts", "age", "node" },
    rows = rows,
  }
end

local function unavailable(obj)
  local status = obj.status or {}
  if (status.unavailableReplicas or 0) > 0 then
    return true
  end
  local spec = obj.spec or {}
  if spec.replicas ~= nil then
    return (status.readyReplicas or 0) < spec.replicas
  end
  if status.desiredNumberScheduled ~= nil then
    return (status.numberReady or 0) < status.desiredNumberScheduled
  end
  return false
end

local function workload_rows(items, kind, now)
  local rows = {}
  local bad = 0
  for _, obj in ipairs(items) do
    if unavailable(obj) then
      bad = bad + 1
    end
    local namespace, name = ns_name(obj)
    local status = obj.status or {}
    local ready = tostring(status.readyReplicas or status.numberReady or 0)
    local want = tostring((obj.spec or {}).replicas or status.desiredNumberScheduled or 0)
    rows[#rows + 1] = {
      kind = kind,
      namespace = namespace,
      name = name,
      cells = { kind, namespace, name, ready .. "/" .. want, M.since((obj.metadata or {}).creationTimestamp, now) },
      detail = lines({
        kind .. " " .. namespace .. "/" .. name,
        "ready: " .. ready .. "/" .. want,
      }),
      bad = unavailable(obj),
    }
  end
  return rows, bad
end

function M.workloads(deployments, statefulsets, daemonsets, now)
  local rows = {}
  local bad = 0
  local function take(decoded, kind)
    local part, part_bad = workload_rows(shape.kube_items(decoded), kind, now)
    bad = bad + part_bad
    for _, row in ipairs(part) do
      rows[#rows + 1] = row
    end
  end
  take(deployments, "deploy")
  take(statefulsets, "sts")
  take(daemonsets, "ds")
  return {
    count = tostring(#rows),
    context = bad .. " unavailable",
    columns = { "kind", "namespace", "name", "ready", "age" },
    rows = rows,
  }
end

function M.services(decoded, now)
  local items = shape.kube_items(decoded)
  local pending = 0
  local rows = {}
  for _, service in ipairs(items) do
    local spec = service.spec or {}
    local wait = match.lb_pending(service)
    if wait then
      pending = pending + 1
    end
    local namespace, name = ns_name(service)
    local ingress = (((service.status or {}).loadBalancer or {}).ingress) or {}
    local external = {}
    for _, item in ipairs(ingress) do
      external[#external + 1] = item.ip or item.hostname or ""
    end
    rows[#rows + 1] = {
      kind = "service",
      namespace = namespace,
      name = name,
      cells = {
        namespace,
        name,
        spec.type or "—",
        spec.clusterIP or "—",
        #external > 0 and table.concat(external, ",") or "—",
        match.lb_id(service) or "—",
      },
      detail = lines({
        namespace .. "/" .. name,
        "type: " .. tostring(spec.type or "—"),
        "lb: " .. tostring(match.lb_id(service) or "—"),
        "external: " .. (#external > 0 and table.concat(external, ", ") or "—"),
      }),
    }
  end
  return {
    count = tostring(#items),
    context = pending .. " load balancers waiting",
    columns = { "namespace", "name", "type", "cluster IP", "external", "do lb" },
    rows = rows,
  }
end

local function lb_healthy(lb)
  local status = lb.status or lb.state or ""
  if type(status) == "table" then
    status = status.state or ""
  end
  status = string.lower(tostring(status))
  return status == "active" or status == "healthy"
end

function M.load_balancers(associated, by_id)
  local ids = shape.associated(associated).load_balancers
  local rows = {}
  local unhealthy = 0
  for _, id in ipairs(ids) do
    local lb = shape.object(by_id[id])
    local healthy = next(lb) ~= nil and lb_healthy(lb)
    if not healthy then
      unhealthy = unhealthy + 1
    end
    local status = lb.status or "unknown"
    if type(status) == "table" then
      status = status.state or "unknown"
    end
    local region = lb.region
    if type(region) == "table" then
      region = region.slug or region.name
    end
    rows[#rows + 1] = {
      cells = { lb.name or id, tostring(status), tostring(region or "—"), tostring(lb.ip or "—") },
      detail = lines({
        "id: " .. id,
        "name: " .. tostring(lb.name or "—"),
        "status: " .. tostring(status),
        "ip: " .. tostring(lb.ip or "—"),
      }),
    }
  end
  return {
    count = tostring(#ids),
    context = unhealthy .. " not healthy",
    columns = { "name", "status", "region", "ip" },
    rows = rows,
  }
end

function M.addresses_of(services, lbs_by_id)
  local seen = {}
  local list = {}
  local function add(value)
    if type(value) == "string" and value ~= "" and not seen[value] then
      seen[value] = true
      list[#list + 1] = value
    end
  end
  for _, service in ipairs(shape.kube_items(services)) do
    for _, ingress in ipairs((((service.status or {}).loadBalancer or {}).ingress) or {}) do
      add(ingress.ip)
      add(ingress.hostname)
    end
  end
  for _, lb in pairs(lbs_by_id or {}) do
    add(lb.ip)
    add(lb.ipv6)
  end
  return list
end

function M.domains(ingresses, services, domains, records_by_domain, addresses)
  local hosts = match.hostnames(shape.kube_items(ingresses), shape.kube_items(services))
  local domain_list = shape.as_list(domains)
  local joined, unmatched = match.dns(hosts, domain_list, records_by_domain or {}, addresses or {})
  local rows = {}
  for _, row in ipairs(joined) do
    local rec = row.record
    rows[#rows + 1] = {
      cells = {
        row.host,
        row.source,
        rec and ((rec.type or "") .. " " .. (rec.name or "") .. " " .. (rec.data or "")) or "no matching record",
      },
      detail = lines({
        row.host,
        row.source,
        rec and ("dns: " .. (rec.type or "") .. " " .. (rec.data or "")) or "no DigitalOcean DNS record aimed at this cluster",
      }),
    }
  end
  return {
    count = tostring(#hosts),
    context = unmatched .. " without a DNS record",
    columns = { "host", "from", "dns" },
    rows = rows,
  }
end

function M.volumes(pvcs, pvs, associated, volumes_by_id)
  local claims = shape.kube_items(pvcs)
  local vols = shape.kube_items(pvs)
  local by_claim = {}
  for _, pv in ipairs(vols) do
    local ref = (pv.spec or {}).claimRef
    if ref and ref.name then
      by_claim[(ref.namespace or "") .. "/" .. ref.name] = pv
    end
  end
  local unbound = 0
  local rows = {}
  for _, pvc in ipairs(claims) do
    local namespace, name = ns_name(pvc)
    local phase = (pvc.status or {}).phase or ""
    if phase ~= "Bound" then
      unbound = unbound + 1
    end
    local pv = by_claim[namespace .. "/" .. name]
    local handle = pv and match.volume_handle(pv) or nil
    local volume = handle and volumes_by_id[handle] and shape.object(volumes_by_id[handle]) or nil
    rows[#rows + 1] = {
      kind = "pvc",
      namespace = namespace,
      name = name,
      cells = {
        namespace .. "/" .. name,
        phase,
        tostring(pvc_size(pvc)),
        handle or "—",
        volume and (volume.name or volume.size_gigabytes and (tostring(volume.size_gigabytes) .. " GiB") or "—") or "—",
      },
      detail = lines({
        namespace .. "/" .. name,
        "phase: " .. phase,
        "volume: " .. tostring(handle or "—"),
        volume and ("do: " .. tostring(volume.name or handle) .. " " .. tostring(volume.size_gigabytes or "") .. " GiB") or "",
      }),
    }
  end
  local assoc = shape.associated(associated)
  return {
    count = tostring(#claims),
    context = unbound .. " unbound, " .. #assoc.volumes .. " DO volumes",
    columns = { "claim", "phase", "size", "handle", "volume" },
    rows = rows,
  }
end

function M.lint(decoded)
  local items = shape.diagnostics(decoded)
  local errors, warnings = 0, 0
  local rows = {}
  for _, item in ipairs(items) do
    if item.severity == "error" then
      errors = errors + 1
    elseif item.severity == "warning" then
      warnings = warnings + 1
    end
    rows[#rows + 1] = {
      kind = item.kind,
      namespace = item.namespace,
      name = item.name,
      severity = item.severity,
      cells = {
        item.severity,
        item.check,
        item.kind,
        item.namespace,
        item.name,
        item.message,
      },
      detail = lines({
        item.severity .. "  " .. item.check,
        item.kind .. " " .. item.namespace .. "/" .. item.name,
        item.message,
      }),
    }
  end
  return {
    count = tostring(#items),
    context = errors .. " errors, " .. warnings .. " warnings",
    columns = { "severity", "check", "kind", "namespace", "name", "message" },
    rows = rows,
  }
end

--- Namespaces from the namespace list plus any namespace already seen on a resource.
function M.namespace_names(sources)
  sources = sources or {}
  local seen = {}
  local function add(name)
    if type(name) == "string" and name ~= "" then
      seen[name] = true
    end
  end
  if sources.namespaces then
    for _, item in ipairs(shape.kube_items(sources.namespaces)) do
      add((item.metadata or {}).name)
    end
  end
  for _, id in ipairs({ "pods", "deployments", "statefulsets", "daemonsets", "services", "ingresses", "pvcs" }) do
    if sources[id] then
      for _, item in ipairs(shape.kube_items(sources[id])) do
        add((item.metadata or {}).namespace)
      end
    end
  end
  if sources.lint then
    for _, item in ipairs(shape.diagnostics(sources.lint)) do
      add(item.namespace)
    end
  end
  local names = {}
  for name in pairs(seen) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

--- Keep rows in the selected namespace. Rows with no namespace stay visible.
function M.restrict_namespace(rows, namespace)
  if type(namespace) ~= "string" or namespace == "" then
    return rows
  end
  local out = {}
  for _, row in ipairs(rows or {}) do
    if row.namespace == nil or row.namespace == namespace then
      out[#out + 1] = row
    end
  end
  return out
end

local function region_of(obj)
  local region = obj.region
  if type(region) == "table" then
    return region.slug or region.name or "—"
  end
  if type(region) == "string" and region ~= "" then
    return region
  end
  if type(obj.regions) == "table" then
    local first = obj.regions[1]
    if type(first) == "string" then
      return first
    end
    if type(first) == "table" then
      return first.slug or first.name or "—"
    end
  end
  return "—"
end

local function account_row(cells, detail)
  return { cells = cells, detail = detail }
end

local function droplet_ip(obj)
  local nets = ((obj.networks or {}).v4) or {}
  local fallback = nil
  for _, net in ipairs(nets) do
    if type(net) == "table" and type(net.ip_address) == "string" and net.ip_address ~= "" then
      fallback = fallback or net.ip_address
      if net.type == "public" then
        return net.ip_address
      end
    end
  end
  return fallback or "—"
end

local function droplet_size(obj)
  if type(obj.size) == "table" then
    return obj.size.slug or obj.size.name or "—"
  end
  if type(obj.size) == "string" and obj.size ~= "" then
    return obj.size
  end
  if type(obj.size_slug) == "string" and obj.size_slug ~= "" then
    return obj.size_slug
  end
  return "—"
end

--- Account-wide doctl lists. The id matches the menu row.
function M.account(id, decoded)
  local list = {}
  for _, obj in ipairs(shape.as_list(decoded)) do
    if type(obj) == "table" then
      list[#list + 1] = obj
    end
  end
  local function done(context, columns, rows)
    if #list == 0 then
      context = "none"
    end
    return {
      count = tostring(#list),
      context = context,
      columns = columns,
      rows = rows,
    }
  end
  if id == "droplets" then
    local off = 0
    local rows = {}
    for _, obj in ipairs(list) do
      local status = obj.status or "—"
      if status ~= "active" then
        off = off + 1
      end
      local ip = droplet_ip(obj)
      local size = droplet_size(obj)
      local name = obj.name or tostring(obj.id or "—")
      rows[#rows + 1] = account_row({ name, status, region_of(obj), size, ip }, lines({
        "name: " .. name,
        "id: " .. tostring(obj.id or "—"),
        "status: " .. tostring(status),
        "region: " .. region_of(obj),
        "size: " .. size,
        "ip: " .. ip,
      }))
    end
    local context = off == 0 and "all active" or count_phrase(off, "off", "off")
    return done(context, { "name", "status", "region", "size", "ip" }, rows)
  end
  if id == "block_storage" then
    local loose = 0
    local rows = {}
    for _, obj in ipairs(list) do
      local ids = obj.droplet_ids
      local attached = type(ids) == "table" and #ids > 0
      if not attached then
        loose = loose + 1
      end
      local size = obj.size_gigabytes and (tostring(obj.size_gigabytes) .. " GiB") or "—"
      local name = obj.name or tostring(obj.id or "—")
      rows[#rows + 1] = account_row({
        name,
        size,
        region_of(obj),
        attached and tostring(#ids) or "no",
      }, lines({
        "name: " .. name,
        "id: " .. tostring(obj.id or "—"),
        "size: " .. size,
        "region: " .. region_of(obj),
        "droplets: " .. (attached and tostring(#ids) or "none"),
      }))
    end
    local context = loose == 0 and "all attached" or count_phrase(loose, "unattached", "unattached")
    return done(context, { "name", "size", "region", "attached" }, rows)
  end
  if id == "firewalls" then
    local idle = 0
    local rows = {}
    for _, obj in ipairs(list) do
      local droplets = type(obj.droplet_ids) == "table" and #obj.droplet_ids or 0
      local tags = type(obj.tags) == "table" and #obj.tags or 0
      if droplets + tags == 0 then
        idle = idle + 1
      end
      local name = obj.name or tostring(obj.id or "—")
      rows[#rows + 1] = account_row({
        name,
        obj.status or "—",
        tostring(droplets),
        tostring(tags),
      }, lines({
        "name: " .. name,
        "id: " .. tostring(obj.id or "—"),
        "status: " .. tostring(obj.status or "—"),
        "droplets: " .. tostring(droplets),
        "tags: " .. tostring(tags),
      }))
    end
    local context = idle == 0 and "all in use" or count_phrase(idle, "with no targets", "with no targets")
    return done(context, { "name", "status", "droplets", "tags" }, rows)
  end
  if id == "reserved_ips" then
    local free = 0
    local rows = {}
    for _, obj in ipairs(list) do
      local droplet = obj.droplet
      local name = "unassigned"
      if type(droplet) == "table" and (droplet.name or droplet.id) then
        name = droplet.name or tostring(droplet.id)
      else
        free = free + 1
      end
      local ip = obj.ip or "—"
      rows[#rows + 1] = account_row({ ip, region_of(obj), name }, lines({
        "ip: " .. tostring(ip),
        "region: " .. region_of(obj),
        "droplet: " .. name,
      }))
    end
    local context = free == 0 and "all assigned" or count_phrase(free, "unassigned", "unassigned")
    return done(context, { "ip", "region", "droplet" }, rows)
  end
  if id == "snapshots" then
    local droplets, volumes = 0, 0
    local rows = {}
    for _, obj in ipairs(list) do
      local kind = obj.resource_type or "—"
      if kind == "droplet" then
        droplets = droplets + 1
      elseif kind == "volume" then
        volumes = volumes + 1
      end
      local size = obj.size_gigabytes and (tostring(obj.size_gigabytes) .. " GiB") or "—"
      local name = obj.name or tostring(obj.id or "—")
      rows[#rows + 1] = account_row({ name, kind, region_of(obj), size }, lines({
        "name: " .. name,
        "id: " .. tostring(obj.id or "—"),
        "type: " .. tostring(kind),
        "region: " .. region_of(obj),
        "size: " .. size,
      }))
    end
    local context = droplets .. " droplet, " .. volumes .. " volume"
    return done(context, { "name", "type", "region", "size" }, rows)
  end
  if id == "databases" then
    local down = 0
    local rows = {}
    for _, obj in ipairs(list) do
      local status = obj.status or "—"
      if status ~= "online" then
        down = down + 1
      end
      local engine = obj.engine or "—"
      if obj.version then
        engine = engine .. " " .. tostring(obj.version)
      end
      local size = type(obj.size) == "string" and obj.size or droplet_size(obj)
      local name = obj.name or tostring(obj.id or "—")
      rows[#rows + 1] = account_row({
        name,
        engine,
        status,
        region_of(obj),
        tostring(obj.num_nodes or "—"),
      }, lines({
        "name: " .. name,
        "id: " .. tostring(obj.id or "—"),
        "engine: " .. engine,
        "status: " .. tostring(status),
        "region: " .. region_of(obj),
        "size: " .. tostring(size),
        "nodes: " .. tostring(obj.num_nodes or "—"),
      }))
    end
    local context = down == 0 and "all online" or count_phrase(down, "not online", "not online")
    return done(context, { "name", "engine", "status", "region", "nodes" }, rows)
  end
  if id == "networks" then
    local defaults = 0
    local rows = {}
    for _, obj in ipairs(list) do
      local is_default = obj.default or obj.is_default
      if is_default then
        defaults = defaults + 1
      end
      local name = obj.name or tostring(obj.id or "—")
      local range = obj.ip_range or obj.ipRange or "—"
      rows[#rows + 1] = account_row({
        name,
        region_of(obj),
        range,
        is_default and "yes" or "no",
      }, lines({
        "name: " .. name,
        "id: " .. tostring(obj.id or "—"),
        "region: " .. region_of(obj),
        "range: " .. tostring(range),
        "default: " .. (is_default and "yes" or "no"),
      }))
    end
    local context = count_phrase(defaults, "default", "defaults")
    return done(context, { "name", "region", "range", "default" }, rows)
  end
  if id == "projects" then
    local default_name = nil
    local rows = {}
    for _, obj in ipairs(list) do
      if obj.is_default and obj.name then
        default_name = obj.name
      end
      local name = obj.name or tostring(obj.id or "—")
      rows[#rows + 1] = account_row({
        name,
        obj.environment or "—",
        obj.purpose or "—",
        obj.is_default and "yes" or "no",
      }, lines({
        "name: " .. name,
        "id: " .. tostring(obj.id or "—"),
        "environment: " .. tostring(obj.environment or "—"),
        "purpose: " .. tostring(obj.purpose or "—"),
        "default: " .. (obj.is_default and "yes" or "no"),
      }))
    end
    local context = default_name and (default_name .. " is default") or "no default"
    return done(context, { "name", "environment", "purpose", "default" }, rows)
  end
  return nil
end

function M.jump_section(kind)
  kind = string.lower(kind or "")
  if kind == "pod" then
    return "pods"
  end
  if kind == "deployment" or kind == "statefulset" or kind == "daemonset" or kind == "deploy" then
    return "workloads"
  end
  if kind == "service" then
    return "services"
  end
  if kind == "persistentvolumeclaim" or kind == "pvc" or kind == "persistentvolume" then
    return "volumes"
  end
  return nil
end

return M
