--- Cluster session: cache, command queue, and section summaries.
-- Drawing lives in app.lua. This module stays free of the terminal.

local bar = require("doksuela.bar")
local cache = require("doksuela.cache")
local checks = require("doksuela.checks")
local clock = require("doksuela.clock")
local exec = require("doksuela.exec")
local fresh = require("doksuela.fresh")
local json = require("doksuela.json")
local logmod = require("doksuela.log")
local match = require("doksuela.match")
local model = require("doksuela.model")
local queue = require("doksuela.queue")
local shape = require("doksuela.shape")

local ACCOUNT = "_account"
local PARALLEL_STEPS = { 1, 2, 4, 8 }

local function parallel_limit(n)
  n = math.floor(tonumber(n) or 2)
  if n < 1 then
    return 1
  end
  if n > PARALLEL_STEPS[#PARALLEL_STEPS] then
    return PARALLEL_STEPS[#PARALLEL_STEPS]
  end
  return n
end

local DEFS = {
  nodes = { needs = { "node_pools", "nodes" }, kubectl = true },
  pods = { needs = { "pods" }, kubectl = true },
  workloads = { needs = { "deployments", "statefulsets", "daemonsets" }, kubectl = true },
  services = { needs = { "services", "associated" }, kubectl = true },
  domains = { needs = { "ingresses", "services", "domains" }, dynamic = "records", kubectl = true },
  volumes = { needs = { "pvcs", "pvs", "associated" }, dynamic = "volume", kubectl = true },
  load_balancers = { needs = { "associated" }, dynamic = "lb" },
  lint = { needs = { "lint" }, kubectl = true },
}

local MENU = {
  { id = "nodes", label = "Nodes", key = "n" },
  { id = "pods", label = "Pods", key = "p" },
  { id = "workloads", label = "Workloads", key = "w" },
  { id = "services", label = "Services", key = "s" },
  { id = "domains", label = "Domains", key = "d" },
  { id = "volumes", label = "Volumes", key = "v" },
  { id = "load_balancers", label = "Load balancers", key = "l" },
  { id = "lint", label = "Clusterlint", key = "t" },
  { id = "clusters", label = "Clusters", key = "c" },
  { id = "theme", label = "Theme", key = "m" },
}

-- Account-wide doctl lists. Keys stay unique against MENU.
local ACCOUNT_MENU = {
  { id = "droplets", label = "Droplets", key = "o" },
  { id = "block_storage", label = "Block storage", key = "b" },
  { id = "firewalls", label = "Firewalls", key = "f" },
  { id = "reserved_ips", label = "Reserved IPs", key = "i" },
  { id = "snapshots", label = "Snapshots", key = "a" },
  { id = "databases", label = "Managed DBs", key = "g" },
  { id = "networks", label = "Networks", key = "e" },
  { id = "projects", label = "Projects", key = "j" },
}

local function trigger_label(id)
  for _, item in ipairs(MENU) do
    if item.id == id then
      return item.label
    end
  end
  for _, item in ipairs(ACCOUNT_MENU) do
    if item.id == id then
      return item.label
    end
  end
  return id
end

local Session = {}
Session.__index = Session
Session.menu = MENU
Session.account_menu = ACCOUNT_MENU
Session.defs = DEFS

local function trim_err(text, code)
  text = text or ""
  if #text > 4000 then
    text = text:sub(-4000)
  end
  text = text:gsub("%s+$", "")
  if text ~= "" then
    return text
  end
  return "exit " .. tostring(code or 1)
end

-- clusterlint writes usage errors to stdout and leaves stderr empty.
local function command_error(stderr, stdout, code)
  local err = trim_err(stderr, code)
  if stderr and stderr:gsub("%s", "") ~= "" then
    return err
  end
  local line = tostring(stdout or ""):match("^[^\r\n]+") or ""
  line = line:gsub("^%s+", ""):gsub("%s+$", "")
  if line ~= "" and not line:find("^[%[{]") then
    if #line > 180 then
      line = line:sub(1, 177) .. "..."
    end
    return line
  end
  return "exit " .. tostring(code or 1)
end

function Session.new(opts)
  opts = opts or {}
  local root = opts.cache_root or ((os.getenv("HOME") or ".") .. "/.cache/doksuela")
  local store = cache.open(root)
  local state = cache.load_state(store)
  local max = opts.max
  if max == nil then
    max = state.parallel or 2
  end
  local self = setmetatable({
    cache = store,
    fixture = opts.fixture,
    log = logmod.open(root .. "/commands.log"),
    queue = queue.new({ max = parallel_limit(max) }),
    raw = {},
    sections = {},
    clusters = {},
    cluster = nil,
    context_name = nil,
    overview = nil,
    overview_state = { summary = nil, confirmed = false, error = nil },
    note = nil,
    job_seq = 0,
    wave_done = 0,
    latest_seq = {},
    reason = "Init",
  }, Session)
  self.remembered_id = state.cluster_id
  self.remembered_name = state.cluster_name
  self:_load_bucket(ACCOUNT)
  local account = self.raw[ACCOUNT] and self.raw[ACCOUNT].clusters
  if account and account.ok then
    self.clusters = model.clusters(account.data)
  end
  if self.remembered_id then
    self:_load_bucket(self.remembered_id)
    self.cluster = self:find_cluster(self.remembered_id)
    if self.cluster then
      self:_restore_context()
    end
  end
  self:rebuild_all()
  return self
end

function Session:_load_bucket(cluster_id)
  self.raw[cluster_id] = self.raw[cluster_id] or {}
  for _, check_id in ipairs(cache.list_raw(self.cache, cluster_id)) do
    local rec = cache.load_raw(self.cache, cluster_id, check_id)
    if rec then
      rec.confirmed = false
      self.raw[cluster_id][check_id] = rec
    end
  end
end

function Session:account_clusters()
  local bucket = self.raw["_account"]
  return bucket and bucket.clusters or nil
end

function Session:find_cluster(id)
  for _, cluster in ipairs(self.clusters) do
    if cluster.id == id or cluster.name == id then
      return cluster
    end
  end
  return nil
end

function Session:_bucket()
  if not self.cluster then
    return {}
  end
  self.raw[self.cluster.id] = self.raw[self.cluster.id] or {}
  return self.raw[self.cluster.id]
end

function Session:namespaces()
  local bucket = self:_bucket()
  local sources = {}
  for _, id in ipairs({
    "namespaces", "pods", "deployments", "statefulsets", "daemonsets",
    "services", "ingresses", "pvcs", "lint",
  }) do
    local rec = bucket[id]
    if rec and rec.ok then
      sources[id] = rec.data
    end
  end
  return model.namespace_names(sources)
end

function Session:_data(id)
  local rec = self:_bucket()[id]
  if rec and rec.ok then
    return rec.data
  end
  return nil
end

function Session:_grouped(prefix)
  local out = {}
  local n = #prefix
  for key, rec in pairs(self:_bucket()) do
    if key:sub(1, n) == prefix and rec.ok and type(rec.data) == "table" then
      out[key:sub(n + 1)] = rec.data
    end
  end
  return out
end

function Session:_restore_context()
  local kube = self:_data("kubeconfig")
  if kube and self.cluster then
    self.context_name = match.context_for(self.cluster, kube)
  end
end

function Session:_workdir()
  self.job_seq = self.job_seq + 1
  local stamp = tostring(clock.wall()):gsub("%.", "")
  local dir = self.cache.root .. "/jobs/" .. stamp .. "-" .. tostring(self.job_seq)
  cache.ensure(dir)
  return dir
end

function Session:_begin_wave(reason)
  self.wave_done = 0
  self.reason = reason or "Init"
end

-- A fresh trigger starts the bar over. A trigger that arrives while work is
-- still queued keeps the same bar and only changes the verb on new commands.
function Session:_touch_wave(reason)
  if self:idle() then
    self:_begin_wave(reason)
  else
    self.reason = reason or self.reason or "Init"
  end
end

function Session:enqueue(cluster_id, spec, again, reason)
  if again then
    self.queue:drop_pending(spec.id)
  elseif self.queue:has(spec.id) then
    return false
  end
  local item = {
    id = spec.id,
    cluster_id = cluster_id,
    argv = spec.argv,
    parse = spec.parse or "json",
    priority = spec.priority or 10,
    workdir = self:_workdir(),
    reason = reason or self.reason or "Init",
    seq = self.job_seq,
  }
  self.latest_seq[spec.id] = item.seq
  if self.fixture then
    local body, err = checks.read_fixture(self.fixture, spec.argv)
    item.fixture = true
    if err then
      item.fixture_exit = 1
      item.fixture_stdout = ""
      item.fixture_stderr = err
    else
      item.fixture_exit = 0
      item.fixture_stdout = body
      item.fixture_stderr = ""
    end
  end
  if again then
    return self.queue:force(item)
  end
  return self.queue:push(item)
end

function Session:enqueue_cluster(reason)
  local cluster = self.cluster
  if not cluster then
    return
  end
  for _, spec in ipairs(checks.cluster_specs(cluster)) do
    self:enqueue(cluster.id, spec, false, reason)
  end
  if self.context_name then
    self:_enqueue_kubectl(reason)
  end
end

function Session:_enqueue_kubectl(reason)
  if not self.context_name or not self.cluster then
    return
  end
  for _, spec in ipairs(checks.kubectl_specs(self.context_name)) do
    self:enqueue(self.cluster.id, spec, false, reason)
  end
  self:enqueue(self.cluster.id, checks.lint_spec(self.context_name), false, reason)
end

function Session:boot()
  self:_begin_wave("Init")
  self:enqueue(ACCOUNT, checks.cluster_list())
  for _, spec in ipairs(checks.account_specs()) do
    self:enqueue(ACCOUNT, spec)
  end
  if self.cluster then
    self:enqueue_cluster()
  end
end

function Session:reload()
  self:_begin_wave("Reload")
  self.queue:clear_pending()
  for _, bucket in pairs(self.raw) do
    if type(bucket) == "table" then
      for _, rec in pairs(bucket) do
        if type(rec) == "table" then
          rec.confirmed = false
        end
      end
    end
  end
  self:rebuild_all()
  local function hot(bucket_id, spec)
    spec.priority = 0
    self:enqueue(bucket_id, spec, true)
  end
  hot(ACCOUNT, checks.cluster_list())
  for _, spec in ipairs(checks.account_specs()) do
    hot(ACCOUNT, spec)
  end
  if not self.cluster then
    return
  end
  for _, spec in ipairs(checks.cluster_specs(self.cluster)) do
    hot(self.cluster.id, spec)
  end
  if not self.context_name then
    return
  end
  for _, spec in ipairs(checks.kubectl_specs(self.context_name)) do
    hot(self.cluster.id, spec)
  end
  hot(self.cluster.id, checks.lint_spec(self.context_name))
  local assoc = shape.associated(self:_data("associated"))
  for _, id in ipairs(assoc.load_balancers) do
    hot(self.cluster.id, checks.lb_spec(id))
  end
  for _, id in ipairs(assoc.volumes) do
    hot(self.cluster.id, checks.volume_spec(id))
  end
  for _, domain in ipairs(shape.as_list(self:_data("domains"))) do
    if type(domain.name) == "string" and domain.name ~= "" then
      hot(self.cluster.id, checks.records_spec(domain.name))
    end
  end
end

function Session:select_cluster(cluster)
  self.cluster = cluster
  self.remembered_id = cluster.id
  self.remembered_name = cluster.name
  self.note = nil
  cache.save_state(self.cache, {
    cluster_id = cluster.id,
    cluster_name = cluster.name,
  })
  self:_load_bucket(cluster.id)
  self.context_name = nil
  self:_restore_context()
  self:rebuild_all()
  self:_touch_wave("Clusters")
  self:enqueue_cluster()
end

function Session:_account_spec(check_id)
  for _, spec in ipairs(checks.account_specs()) do
    if spec.id == check_id then
      return spec
    end
  end
  return nil
end

function Session:focus(section_id)
  if self:_account_spec(section_id) then
    self.queue:boost(section_id)
    return
  end
  local def = DEFS[section_id]
  if not def then
    return
  end
  for _, need in ipairs(def.needs) do
    self.queue:boost(need)
  end
end

function Session:refresh(section_id)
  if section_id == "clusters" then
    self:_touch_wave(trigger_label(section_id))
    self.queue:drop_pending("clusters")
    local spec = checks.cluster_list()
    spec.priority = 0
    self:enqueue(ACCOUNT, spec)
    return
  end
  local account_spec = self:_account_spec(section_id)
  if account_spec then
    self:_touch_wave(trigger_label(section_id))
    self:_requeue_spec(account_spec, ACCOUNT)
    return
  end
  local def = DEFS[section_id]
  if not def or not self.cluster then
    return
  end
  self:_touch_wave(trigger_label(section_id))
  for _, need in ipairs(def.needs) do
    self:_requeue(need)
  end
  if def.dynamic == "lb" then
    for _, id in ipairs(shape.associated(self:_data("associated")).load_balancers) do
      self:_requeue_spec(checks.lb_spec(id))
    end
  elseif def.dynamic == "volume" then
    for _, id in ipairs(shape.associated(self:_data("associated")).volumes) do
      self:_requeue_spec(checks.volume_spec(id))
    end
  elseif def.dynamic == "records" then
    for _, domain in ipairs(shape.as_list(self:_data("domains"))) do
      if type(domain.name) == "string" and domain.name ~= "" then
        self:_requeue_spec(checks.records_spec(domain.name))
      end
    end
  end
end

function Session:_requeue(check_id)
  local spec = self:_spec_for(check_id)
  if spec then
    self:_requeue_spec(spec)
  end
end

function Session:_requeue_spec(spec, bucket_id)
  bucket_id = bucket_id or (self.cluster and self.cluster.id) or ACCOUNT
  self.queue:drop_pending(spec.id)
  spec.priority = 0
  local bucket = self.raw[bucket_id]
  if bucket and bucket[spec.id] then
    bucket[spec.id].confirmed = false
  end
  self:enqueue(bucket_id, spec)
  self:rebuild_all()
end

function Session:_spec_for(check_id)
  if not self.cluster then
    return nil
  end
  for _, spec in ipairs(checks.cluster_specs(self.cluster)) do
    if spec.id == check_id then
      return spec
    end
  end
  if self.context_name then
    for _, spec in ipairs(checks.kubectl_specs(self.context_name)) do
      if spec.id == check_id then
        return spec
      end
    end
    if check_id == "lint" then
      return checks.lint_spec(self.context_name)
    end
  end
  return nil
end

function Session:save_prompt()
  local name = self.cluster and self.cluster.name or "this cluster"
  return "Save kubeconfig for " .. name .. "? This writes ~/.kube/config."
end

function Session:confirm_save()
  if not self.cluster then
    return
  end
  self:_touch_wave("Kubeconfig")
  self:enqueue(self.cluster.id, checks.save_kubeconfig(self.cluster))
end

local function first_problem(bucket, ids)
  for _, id in ipairs(ids) do
    local rec = bucket[id]
    if rec and not rec.ok then
      return rec.error or "check failed"
    end
  end
  return nil
end

local function all_confirmed(bucket, ids)
  for _, id in ipairs(ids) do
    local rec = bucket[id]
    if not rec or not rec.ok or not rec.confirmed then
      return false
    end
  end
  return true
end

function Session:_dynamic_ids(def, bucket)
  local ids = {}
  if def.dynamic == "lb" then
    local assoc = bucket.associated
    if not assoc or not assoc.ok then
      return nil
    end
    for _, id in ipairs(shape.associated(assoc.data).load_balancers) do
      ids[#ids + 1] = "lb__" .. id
    end
  elseif def.dynamic == "volume" then
    local assoc = bucket.associated
    if not assoc or not assoc.ok then
      return nil
    end
    for _, id in ipairs(shape.associated(assoc.data).volumes) do
      ids[#ids + 1] = "volume__" .. id
    end
  elseif def.dynamic == "records" then
    local domains = bucket.domains
    if not domains or not domains.ok then
      return nil
    end
    for _, domain in ipairs(shape.as_list(domains.data)) do
      if type(domain.name) == "string" and domain.name ~= "" then
        ids[#ids + 1] = "records__" .. domain.name
      end
    end
  end
  return ids
end

function Session:_rebuild_account()
  local bucket = self.raw[ACCOUNT] or {}
  for _, item in ipairs(ACCOUNT_MENU) do
    local rec = bucket[item.id]
    local summary, err, complete
    if rec and rec.ok then
      summary = model.account(item.id, rec.data)
      if summary then
        summary.fetched_at = rec.fetched_at
      end
      complete = rec.confirmed and true or false
    elseif rec and not rec.ok then
      err = rec.error or "check failed"
      complete = false
    end
    self.sections[item.id] = fresh.apply(self.sections[item.id], summary, complete, err)
  end
end

function Session:rebuild_all()
  self:_rebuild_account()
  if not self.cluster then
    return
  end
  local bucket = self:_bucket()
  for id, def in pairs(DEFS) do
    local needs = {}
    for _, need in ipairs(def.needs) do
      needs[#needs + 1] = need
    end
    local dynamic = self:_dynamic_ids(def, bucket)
    local waiting_on_dynamic = def.dynamic and dynamic == nil
    if dynamic then
      for _, extra in ipairs(dynamic) do
        needs[#needs + 1] = extra
      end
    end
    local err = first_problem(bucket, needs)
    local complete = not waiting_on_dynamic and all_confirmed(bucket, needs)
    if def.kubectl and not self.context_name then
      complete = false
    end
    local any = false
    for _, need in ipairs(def.needs) do
      if bucket[need] and bucket[need].ok then
        any = true
      end
    end
    local summary = any and self:_summarize(id) or nil
    if summary then
      summary.fetched_at = self:_newest(needs)
    end
    self.sections[id] = fresh.apply(self.sections[id], summary, complete, err)
  end
  self:_rebuild_overview()
end

function Session:_newest(ids)
  local newest
  local bucket = self:_bucket()
  for _, id in ipairs(ids) do
    local rec = bucket[id]
    if rec and rec.fetched_at and (not newest or rec.fetched_at > newest) then
      newest = rec.fetched_at
    end
  end
  return newest
end

function Session:_summarize(id)
  local cluster = self:_data("cluster") or self.cluster
  if id == "nodes" then
    return model.nodes(self:_data("node_pools"), self:_data("nodes"))
  end
  if id == "pods" then
    return model.pods(self:_data("pods"))
  end
  if id == "workloads" then
    return model.workloads(self:_data("deployments"), self:_data("statefulsets"), self:_data("daemonsets"))
  end
  if id == "services" then
    return model.services(self:_data("services"))
  end
  if id == "load_balancers" then
    return model.load_balancers(self:_data("associated"), self:_grouped("lb__"))
  end
  if id == "domains" then
    local records = self:_grouped("records__")
    local addresses = model.addresses_of(self:_data("services"), self:_grouped("lb__"))
    return model.domains(self:_data("ingresses"), self:_data("services"), self:_data("domains"), records, addresses)
  end
  if id == "volumes" then
    return model.volumes(self:_data("pvcs"), self:_data("pvs"), self:_data("associated"), self:_grouped("volume__"))
  end
  if id == "lint" then
    return model.lint(self:_data("lint"))
  end
  return nil
end

function Session:_rebuild_overview()
  local bucket = self:_bucket()
  local cluster = self:_data("cluster") or self.cluster
  local summary = model.overview(cluster, self:_data("upgrades"), self.context_name)
  summary.fetched_at = self:_newest({ "cluster", "upgrades" })
  local err = first_problem(bucket, { "cluster", "upgrades" })
  local complete = all_confirmed(bucket, { "cluster", "upgrades" })
  self.overview = summary
  self.overview_state = fresh.apply(self.overview_state, summary, complete, err)
end

function Session:_store(cluster_id, check_id, ok, data, err)
  local rec = {
    ok = ok and true or false,
    confirmed = ok and true or false,
    fetched_at = clock.wall(),
    error = err,
    data = data,
  }
  self.raw[cluster_id] = self.raw[cluster_id] or {}
  self.raw[cluster_id][check_id] = rec
  local disk = {
    ok = rec.ok,
    confirmed = false,
    fetched_at = rec.fetched_at,
    error = rec.error,
    data = rec.data,
  }
  cache.save_raw(self.cache, cluster_id, check_id, disk)
end

function Session:_after(spec, data)
  if spec.id == "clusters" then
    self.clusters = model.clusters(data)
    if self.cluster and not self:find_cluster(self.cluster.id) then
      self.note = "Saved cluster is no longer in this account."
    end
    return
  end
  if spec.id == "kubeconfig" and self.cluster then
    local previous = self.context_name
    local ctx = match.context_for(self.cluster, data)
    self.context_name = ctx
    if ctx and ctx ~= previous then
      self:_enqueue_kubectl(spec.reason)
    end
    return
  end
  if spec.id == "kubeconfig_save" then
    local spec_kube = nil
    for _, item in ipairs(checks.cluster_specs(self.cluster)) do
      if item.id == "kubeconfig" then
        spec_kube = item
      end
    end
    if spec_kube then
      self.queue:drop_pending("kubeconfig")
      spec_kube.priority = 0
      self:enqueue(self.cluster.id, spec_kube, true, spec.reason)
    end
    return
  end
  if spec.id == "associated" then
    local assoc = shape.associated(data)
    for _, id in ipairs(assoc.load_balancers) do
      self:enqueue(self.cluster.id, checks.lb_spec(id), false, spec.reason)
    end
    for _, id in ipairs(assoc.volumes) do
      self:enqueue(self.cluster.id, checks.volume_spec(id), false, spec.reason)
    end
    return
  end
  if spec.id == "domains" then
    for _, domain in ipairs(shape.as_list(data)) do
      if type(domain.name) == "string" and domain.name ~= "" then
        self:enqueue(self.cluster.id, checks.records_spec(domain.name), false, spec.reason)
      end
    end
  end
end

function Session:_finish(job)
  self.wave_done = (self.wave_done or 0) + 1
  local item = job.item
  local stderr = job.stderr or ""
  local failed = (job.exit_code or 1) ~= 0
  local err_text = failed and command_error(stderr, job.stdout, job.exit_code) or nil
  local logged = stderr
  if failed and logged:gsub("%s", "") == "" and err_text and not err_text:find("^exit ") then
    logged = err_text
  end
  logmod.append(self.log, {
    started = job.t0,
    duration = job.duration or 0,
    exit = job.exit_code or 0,
    argv = job.argv,
    stderr = logged,
  })
  -- A newer run of this check is already in flight. Keep its result.
  if item.seq and (self.latest_seq[item.id] or 0) > item.seq then
    return
  end
  if item.parse == "text" then
    local ok = not failed
    self:_store(item.cluster_id, item.id, ok, job.stdout, ok and nil or err_text)
    if ok then
      self:_after(item, job.stdout)
    end
    self:rebuild_all()
    return
  end
  if failed then
    self:_store(item.cluster_id, item.id, false, nil, err_text)
    self:rebuild_all()
    return
  end
  local decoded, err = json.decode(job.stdout or "")
  if not decoded then
    self:_store(item.cluster_id, item.id, false, nil, err or "invalid json")
    self:rebuild_all()
    return
  end
  decoded = checks.narrow(item.argv, decoded)
  self:_store(item.cluster_id, item.id, true, decoded, nil)
  self:_after(item, decoded)
  self:rebuild_all()
end

function Session:tick()
  local previous = {}
  for i, job in ipairs(self.queue.running) do
    previous[i] = job
  end
  local done = self.queue:tick()
  local changed = #done > 0 or #self.queue.running ~= #previous
  if not changed then
    for i, job in ipairs(self.queue.running) do
      if job ~= previous[i] then
        changed = true
        break
      end
    end
  end
  for _, job in ipairs(done) do
    self:_finish(job)
  end
  return changed
end

function Session:idle()
  return self.queue:idle()
end

function Session:current_argv()
  return self.queue:current()
end

function Session:running_argvs()
  local out = {}
  for _, job in ipairs(self:running()) do
    out[#out + 1] = job.argv
  end
  return out
end

function Session:running()
  local out = {}
  for _, job in ipairs(self.queue.running) do
    if job.argv then
      out[#out + 1] = {
        argv = job.argv,
        reason = (job.item and job.item.reason) or self.reason or "Init",
      }
    end
  end
  return out
end

function Session:footer_text()
  local parts = {}
  for _, job in ipairs(self:running()) do
    parts[#parts + 1] = job.reason .. " " .. exec.display(job.argv)
  end
  return table.concat(parts, "  ·  ")
end

function Session:footer_status()
  local text = self:footer_text()
  if text == "" then
    return "Ready"
  end
  return text
end

function Session:parallel()
  return self.queue.max
end

function Session:set_parallel(n)
  n = parallel_limit(n)
  if n == self.queue.max then
    return false
  end
  self.queue.max = n
  cache.save_state(self.cache, { parallel = n })
  return true
end

function Session:bump_parallel(direction)
  local current = self:parallel()
  local target
  if direction < 0 then
    target = PARALLEL_STEPS[1]
    for _, step in ipairs(PARALLEL_STEPS) do
      if step < current then
        target = step
      end
    end
  else
    target = PARALLEL_STEPS[#PARALLEL_STEPS]
    for _, step in ipairs(PARALLEL_STEPS) do
      if step > current then
        target = step
        break
      end
    end
  end
  return self:set_parallel(target)
end

function Session:progress_steps()
  if self:idle() then
    return bar.steps
  end
  local remaining = #self.queue.pending + #self.queue.running
  local done = self.wave_done or 0
  return bar.from_counts(done, done + remaining, false)
end

function Session:drain()
  local guard = 0
  while not self:idle() do
    self:tick()
    guard = guard + 1
    if guard > 500 then
      error("command queue did not drain")
    end
  end
end

return Session
