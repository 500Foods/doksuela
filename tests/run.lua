#!/usr/bin/env lua
--- Unit tests for doksuela. No tty and no live cluster.

local script = arg[0]
local root = script:match("^(.*)/tests/run%.lua$") or script:match("^(.*)/[^/]+$") or "."
if root == "" then
  root = "."
end

package.path = table.concat({
  root .. "/src/?.lua",
  root .. "/src/?/init.lua",
  root .. "/src/vendor/?.lua",
  os.getenv("HOME") .. "/.luarocks/share/lua/5.5/?.lua",
  os.getenv("HOME") .. "/.luarocks/share/lua/5.5/?/init.lua",
  package.path,
}, ";")
package.cpath = table.concat({
  os.getenv("HOME") .. "/.luarocks/lib64/lua/5.5/?.so",
  os.getenv("HOME") .. "/.luarocks/lib/lua/5.5/?.so",
  package.cpath,
}, ";")

table.insert(package.searchers, 1, function(name)
  local rest = name:match("^doksuela%.(.+)$")
  if not rest then
    return nil
  end
  local path = root .. "/src/" .. rest:gsub("%.", "/") .. ".lua"
  local loader = loadfile(path)
  if loader then
    return loader, path
  end
  return nil
end)

local cache = require("doksuela.cache")
local checks = require("doksuela.checks")
local exec = require("doksuela.exec")
local fresh = require("doksuela.fresh")
local json = require("doksuela.json")
local listwin = require("doksuela.listwin")
local logmod = require("doksuela.log")
local match = require("doksuela.match")
local model = require("doksuela.model")
local shape = require("doksuela.shape")
local mouse = require("doksuela.ui.mouse")
local queue = require("doksuela.queue")
local Session = require("doksuela.session")
local version = require("doksuela.version")

local failures = 0
local checks_run = 0

local function fail(message)
  failures = failures + 1
  io.stderr:write("FAIL ", message, "\n")
end

local function eq(actual, expected, message)
  checks_run = checks_run + 1
  if actual ~= expected then
    fail(message .. "\n  actual:   " .. tostring(actual) .. "\n  expected: " .. tostring(expected))
  end
end

eq(version, "1.0.0", "doksuela version")

local function truthy(value, message)
  checks_run = checks_run + 1
  if not value then
    fail(message .. " (got " .. tostring(value) .. ")")
  end
end

local fixture = root .. "/tests/fixtures"

local function read_json(name)
  local f = assert(io.open(fixture .. "/" .. name, "rb"))
  local body = f:read("a")
  f:close()
  return assert(json.decode(body))
end

-- quoting and display
eq(exec.quote("a b"), "'a b'", "quote spaces")
eq(exec.quote("a'b"), "'a'\\''b'", "quote quote")
eq(exec.display({ "doctl", "kubernetes", "cluster", "get", "prod" }),
  "doctl kubernetes cluster get prod", "display argv")

-- tokens never reach the log
local scrubbed = logmod.scrub_argv({ "doctl", "--access-token", "dop_v1_secret", "kubernetes" })
eq(scrubbed[3], "***", "scrub flag value")
eq(logmod.looks_like_token("dop_v1_abc"), true, "dop token shape")
eq(logmod.looks_like_token("bd5f5959-5e1e-4205-a714-a914373942af"), false, "uuid is not a token")

eq(logmod.format_duration(0), "000.000", "zero duration")
eq(logmod.format_duration(1.5), "001.500", "duration is seconds.milliseconds")
eq(logmod.format_duration(12.3456), "012.346", "duration rounds to milliseconds")
eq(logmod.format_started({ started = 1700000000 }), os.date("%Y-%m-%d %H:%M:%S", 1700000000), "start time is local")
local fallback_start = logmod.format_started({ time = "2020-01-01T00:00:10Z", duration = 1.5 })
eq(#fallback_start, 19, "old records derive a start time")

do
  local dir = "/tmp/doksuela-log-test"
  os.execute("rm -rf " .. dir)
  os.execute("mkdir -p " .. dir)
  local lg = logmod.open(dir .. "/commands.log")
  logmod.append(lg, {
    argv = { "doctl", "kubernetes", "cluster", "list" },
    duration = 1.25,
    exit = 0,
    started = 1700000000,
    stderr = "",
  })
  local again = logmod.open(dir .. "/commands.log")
  eq(#again.records, 1, "history reloads from commands.log")
  eq(again.records[1].started, 1700000000, "start time is stored")
  eq(logmod.format_duration(again.records[1].duration), "001.250", "reloaded duration")
end

do
  local seen = {}
  local reserved = { h = true, k = true, q = true, r = true }
  local function scan(items)
    for _, item in ipairs(items) do
      truthy(type(item.key) == "string" and #item.key == 1, item.label .. " has one shortcut letter")
      truthy(not seen[item.key], "shortcut " .. tostring(item.key) .. " is unique")
      truthy(not reserved[item.key], item.label .. " does not use a global key")
      seen[item.key] = true
      truthy(item.label:lower():find(item.key, 1, true) ~= nil, item.label .. " contains its shortcut")
    end
  end
  scan(Session.menu)
  scan(Session.account_menu)
  eq(#Session.account_menu, 8, "account column has eight rows")
end

do
  local q = queue.new({ max = 1 })
  q.running[1] = { item = { id = "droplets" }, argv = { "doctl" } }
  truthy(q:has("droplets"), "a running id counts as queued")
  q:force({ id = "droplets", priority = 0, argv = { "doctl" } })
  eq(#q.pending, 1, "force queues a follow-up while one is running")
  q:clear_pending()
  eq(#q.pending, 0, "clear_pending drops the follow-up")
  truthy(q:has("droplets"), "clear_pending leaves the running command")
end

local app_chunk, app_err = loadfile(root .. "/src/app.lua")
truthy(app_chunk ~= nil, "app.lua compiles: " .. tostring(app_err))

do
  local dir = "/tmp/doksuela-running-test"
  os.execute("rm -rf " .. dir)
  local session = Session.new({ cache_root = dir, max = 1 })
  session:enqueue("_account", {
    id = "slow",
    argv = { "sleep", "0.3" },
    parse = "text",
    priority = 10,
  })
  eq(session:tick(), true, "starting a command asks for a redraw")
  local running = session:running_argvs()
  eq(running[1] and running[1][1], "sleep", "the running command is visible")
  eq(session:tick(), false, "an unfinished command does not redraw")
  local guard = 0
  while not session:idle() do
    session:tick()
    guard = guard + 1
    if guard > 100 then
      break
    end
    os.execute("sleep 0.05")
  end
  eq(#session:running_argvs(), 0, "a finished command clears the footer")
  truthy(session.log.records[1] and session.log.records[1].started, "history records when the command started")
end

-- freshness
local kept = fresh.apply({ summary = { count = "4" }, confirmed = true }, { count = "0" }, false, "boom")
eq(kept.summary.count, "4", "failed recheck keeps the previous count")
eq(kept.confirmed, false, "failed recheck is not confirmed")
eq(kept.error, "boom", "failed recheck keeps the error")
local paint = fresh.paint(kept)
eq(paint.number, "cached", "failed recheck number stays cached")
eq(paint.context, "error", "failed recheck context is the error color")

local fresh_section = fresh.apply(nil, { count = "2" }, true, nil)
eq(fresh.paint(fresh_section).number, "fresh", "confirmed check is fresh")
eq(fresh.paint({}).number, "dim", "never checked is dim")
local cached = fresh.apply(nil, { count = "2" }, false, nil)
eq(fresh.paint(cached).number, "cached", "unconfirmed summary is cached")

-- window
local selected, scroll = listwin.ensure(10, 8, 0, 5)
eq(selected, 8, "selection stays")
eq(scroll, 3, "window follows selection")
selected, scroll = listwin.page(10, 1, 0, 5, 1)
eq(selected, 6, "page down")

-- mouse
local event = mouse.parse("\27[<0;4;2M")
truthy(event and event.press and event.left, "left press")
eq(event.col, 4, "mouse col")
eq(event.row, 2, "mouse row")
truthy(mouse.hit({ row = 2, col = 3, width = 2 }, 2, 4), "hit inside")

-- joins
local kube = read_json("kubeconfig.json")
local cluster = read_json("cluster.json")
eq(match.context_for(cluster, kube), "do-nyc1-prod", "context matches endpoint")
eq(match.context_for({ name = "nope", region = "nyc1", endpoint = "https://other.invalid" }, kube), nil,
  "unknown endpoint does not match")

local nodes = model.nodes(read_json("node_pools.json"), read_json("nodes.json"))
eq(nodes.count, "2", "node count is the kubernetes count")
eq(nodes.context, "2 not ready, 1 pool", "node context counts missing and not ready")
eq(nodes.columns[3], "ip", "nodes have an ip column")
eq(nodes.columns[4], "private", "nodes have a private ip column")
eq(nodes.widths[4], 15, "private column is wide enough for an ipv4 address")
eq(nodes.rows[1].cells[3], "203.0.113.21", "node ip prefers the external address")
eq(nodes.rows[1].cells[4], "10.0.0.8", "node private ip is the internal address")
eq(nodes.rows[2].cells[3], "—", "a droplet missing from kubernetes has no ip")
eq(nodes.rows[2].cells[4], "—", "a droplet missing from kubernetes has no private ip")
eq(nodes.rows[3].cells[3], "10.0.0.9", "node ip falls back to the internal address")
eq(nodes.rows[3].cells[4], "10.0.0.9", "private column still shows the internal address")
truthy(nodes.rows[1].detail:find("private: 10.0.0.8", 1, true) ~= nil, "detail keeps the private address")

local pods = model.pods(read_json("pods.json"), os.time())
eq(pods.count, "2", "pod count")
eq(pods.context, "1 not running", "pending pod is not running")
eq(pods.rows[1].cells[3], "1/1", "ready fraction")

local work = model.workloads(read_json("deployments.json"), read_json("statefulsets.json"), read_json("daemonsets.json"), os.time())
eq(work.count, "2", "workload count")
eq(work.context, "1 unavailable", "unavailable deployment")

local services = model.services(read_json("services.json"))
eq(services.count, "3", "service count")
eq(services.context, "1 load balancers waiting", "pending load balancer")

local addresses = model.addresses_of(read_json("services.json"), { ["lb-1"] = read_json("load_balancers.json")[1] })
local found_ip = false
for _, address in ipairs(addresses) do
  if address == "203.0.113.10" then
    found_ip = true
  end
end
truthy(found_ip, "load balancer address collected")

local domains = model.domains(
  read_json("ingresses.json"),
  read_json("services.json"),
  read_json("domains.json"),
  { ["example.com"] = read_json("records-example.com.json") },
  addresses
)
eq(domains.count, "3", "hostname count")
eq(domains.context, "2 without a DNS record", "unmatched hostnames")

local volumes = model.volumes(
  read_json("pvcs.json"),
  read_json("pvs.json"),
  read_json("associated.json"),
  { ["vol-1"] = read_json("volumes.json")[1] }
)
eq(volumes.count, "2", "pvc count")
eq(volumes.context, "1 unbound, 1 DO volumes", "unbound pvc and do volume")

local object_assoc = shape.associated({
  load_balancers = { { id = "lb-9", name = "web" } },
  volumes = { { id = "vol-9", name = "data" } },
  volume_snapshots = {},
})
eq(object_assoc.load_balancers[1], "lb-9", "associated lb id from object")
eq(object_assoc.volumes[1], "vol-9", "associated volume id from object")
eq(checks.lb_spec(object_assoc.load_balancers[1]).id, "lb__lb-9", "lb check id from object")

local unwrapped = model.overview({ {
  name = "prod",
  region = "nyc1",
  version = "1.2.3",
  status = { state = "running" },
  ha = true,
  maintenance_policy = { day = "sunday", start_time = "04:00" },
} }, { { slug = "1.2.4-do.0", kubernetes_version = "1.2.4" } }, "ctx")
eq(unwrapped.name, "prod", "cluster get array unwraps")
eq(unwrapped.status, "running", "status state from cluster get")
truthy(unwrapped.context_line:find("1.2.4-do.0", 1, true), "upgrade slug")

local lbs = model.load_balancers(
  { load_balancers = { { id = "lb-9", name = "web" } } },
  { ["lb-9"] = { { id = "lb-9", name = "web", status = "active", region = { slug = "tor1" }, ip = "203.0.113.9" } } }
)
eq(lbs.count, "1", "object lb count")
eq(lbs.rows[1].cells[1], "web", "lb name from get array")
eq(lbs.rows[1].cells[2], "active", "lb status")
eq(lbs.rows[1].cells[3], "tor1", "lb region slug")
eq(lbs.context, "0 not healthy", "active lb is healthy")

local lint = model.lint(read_json("lint.json"))
eq(lint.count, "2", "lint count")
eq(lint.context, "1 errors, 1 warnings", "lint severities")
eq(model.jump_section("pod"), "pods", "lint jump")

local droplets = model.account("droplets", read_json("droplets.json"))
eq(droplets.count, "2", "droplet count")
eq(droplets.context, "1 off", "droplet context")
local block = model.account("block_storage", read_json("volumes.json"))
eq(block.count, "1", "block storage count")
eq(block.context, "1 unattached", "block storage context")
eq(model.account("firewalls", read_json("firewalls.json")).context, "1 with no targets", "firewall context")
eq(model.account("reserved_ips", read_json("reserved_ips.json")).context, "1 unassigned", "reserved ip context")
eq(model.account("snapshots", read_json("snapshots.json")).context, "1 droplet, 1 volume", "snapshot context")
eq(model.account("databases", read_json("databases.json")).context, "1 not online", "database context")
eq(model.account("networks", read_json("vpcs.json")).context, "1 default", "network context")
eq(model.account("projects", read_json("projects.json")).context, "first is default", "project context")

local past = model.since("2020-01-01T00:00:00Z", os.time())
truthy(past:find("d"), "old timestamp ages in days")
eq(model.ago(os.time() - 5, os.time(), true), "checked just now", "fresh age")
eq(model.ago(os.time() - 3 * 3600, os.time(), false), "from cache, 3h ago", "cached age")

-- kubectl -A is placed before the kind
local kubectl_pods = checks.kubectl_specs("do-nyc1-prod")
local pod_argv
for _, spec in ipairs(kubectl_pods) do
  if spec.id == "pods" then
    pod_argv = spec.argv
  end
end
eq(pod_argv[4], "get", "kubectl get")
eq(pod_argv[5], "-A", "namespaced get uses -A")
eq(pod_argv[6], "pods", "kind follows -A")
local ns_argv
for _, spec in ipairs(kubectl_pods) do
  if spec.id == "namespaces" then
    ns_argv = spec.argv
  end
end
eq(ns_argv[5], "namespaces", "namespaces are fetched with the cluster")

local names = model.namespace_names({
  namespaces = read_json("namespaces.json"),
  pods = read_json("pods.json"),
  statefulsets = read_json("statefulsets.json"),
})
eq(table.concat(names, ","), "data,default,kube-system", "namespace list is sorted and complete")
local pods = model.pods(read_json("pods.json"), os.time())
eq(#model.restrict_namespace(pods.rows, "default"), 2, "namespace filter keeps that namespace")
eq(#model.restrict_namespace(pods.rows, "kube-system"), 0, "namespace filter hides other namespaces")
local kept = model.restrict_namespace({
  { namespace = "default", cells = { "a" } },
  { cells = { "node" } },
}, "kube-system")
eq(#kept, 1, "rows without a namespace stay visible")
eq(kept[1].cells[1], "node", "the cluster-scoped row remains")

-- a real process, so the background runner is not only the fixture path
do
  local dir = "/tmp/doksuela-exec-test"
  os.execute("rm -rf " .. dir .. " && mkdir -p " .. dir)
  local job = exec.start({ "echo", "hello" }, { workdir = dir })
  local spins = 0
  while not exec.poll(job) do
    spins = spins + 1
    if spins > 200 then
      break
    end
    os.execute("sleep 0.01")
  end
  eq(job.exit_code, 0, "echo exits 0")
  eq((job.stdout or ""):gsub("%s+$", ""), "hello", "echo stdout")
end

-- a leftover exit file must not finish the next command early
do
  local dir = "/tmp/doksuela-stale-job"
  os.execute("rm -rf " .. dir .. " && mkdir -p " .. dir)
  local stale_code = assert(io.open(dir .. "/code", "w"))
  stale_code:write("0\n")
  stale_code:close()
  local stale_out = assert(io.open(dir .. "/stdout", "w"))
  stale_out:write("stale\n")
  stale_out:close()
  local job = exec.start({ "sh", "-c", "sleep 0.2; echo hello" }, { workdir = dir })
  eq(exec.poll(job), false, "stale exit file is not a finished job")
  local spins = 0
  while not exec.poll(job) do
    spins = spins + 1
    if spins > 200 then
      break
    end
    os.execute("sleep 0.01")
  end
  eq((job.stdout or ""):gsub("%s+$", ""), "hello", "stale directory still runs the new command")
end

-- fixture session: cache paints blue, then a drain turns it green
do
  local dir = "/tmp/doksuela-session-test"
  os.execute("rm -rf " .. dir)
  local session = Session.new({ fixture = fixture, cache_root = dir })
  session:boot()
  session:drain()
  eq(#session.clusters, 2, "fixture cluster list")
  session:select_cluster(session.clusters[1])
  session:drain()
  eq(session.context_name, "do-nyc1-prod", "session context")
  eq(table.concat(session:namespaces(), ","), "data,default,kube-system", "session namespace list")
  eq(session.sections.nodes.summary.count, "2", "session node count")
  truthy(session.sections.nodes.confirmed, "nodes confirmed after drain")
  eq(fresh.paint(session.sections.nodes).number, "fresh", "nodes turn green")
  eq(session.sections.domains.summary.context, "2 without a DNS record", "session domains")
  eq(session.sections.droplets.summary.count, "2", "session droplets")
  eq(session.sections.droplets.summary.context, "1 off", "session droplet context")
  truthy(session.sections.droplets.confirmed, "droplets confirmed after drain")
  eq(session.sections.block_storage.summary.context, "1 unattached", "session block storage")
  eq(session.sections.lint.summary.count, "2", "session clusterlint")
  eq(session.sections.lint.summary.context, "1 errors, 1 warnings", "session clusterlint context")
  truthy(#session.log.records > 0, "commands were logged")
  local blob = json.encode(session.log.records)
  truthy(blob:find("doctl", 1, true), "log names doctl")
  truthy(not blob:find("dop_v1_", 1, true), "log has no token")

  session:reload()
  eq(session.sections.droplets.confirmed, false, "reload clears confirmation")
  eq(session.sections.nodes.confirmed, false, "reload clears the cluster sections")
  truthy(not session:idle(), "reload enqueues work")
  session:drain()
  truthy(session.sections.droplets.confirmed, "reload confirms droplets again")
  truthy(session.sections.nodes.confirmed, "reload confirms nodes again")

  local again = Session.new({ fixture = fixture, cache_root = dir })
  eq(again.cluster and again.cluster.name, "prod", "cluster is remembered")
  eq(again.sections.nodes.confirmed, false, "relaunch is not confirmed yet")
  eq(fresh.paint(again.sections.nodes).number, "cached", "relaunch numbers are cached")
  eq(again.sections.nodes.summary.count, "2", "relaunch still shows the count")
end

-- cache round trip
do
  local dir = "/tmp/doksuela-cache-test"
  os.execute("rm -rf " .. dir)
  local store = cache.open(dir)
  cache.save_state(store, { cluster_id = "abc", cluster_name = "prod" })
  cache.save_raw(store, "abc", "nodes", { ok = true, data = { items = {} }, fetched_at = 10 })
  eq(cache.load_state(store).cluster_name, "prod", "state round trip")
  eq(cache.load_raw(store, "abc", "nodes").fetched_at, 10, "raw round trip")
end

-- doctl list-associated-resources returns objects, not bare id strings
do
  local dir = "/tmp/doksuela-assoc-test"
  os.execute("rm -rf " .. dir)
  local store = cache.open(dir)
  cache.save_state(store, { cluster_id = "c1", cluster_name = "prod" })
  cache.save_raw(store, "_account", "clusters", {
    ok = true,
    data = { { id = "c1", name = "prod", region = "nyc1" } },
  })
  cache.save_raw(store, "c1", "associated", {
    ok = true,
    data = {
      load_balancers = { { id = "lb-9", name = "web" } },
      volumes = {},
      volume_snapshots = {},
    },
  })
  local session = Session.new({ cache_root = dir })
  eq(session.cluster and session.cluster.name, "prod", "object cache still opens the cluster")
  eq(session.sections.load_balancers.summary.count, "1", "object load balancer id loads")
end

do
  local spec = checks.lint_spec("do-nyc1-prod")
  eq(table.concat(spec.argv, " "),
    "clusterlint --context do-nyc1-prod --timeout 30s run --output json",
    "clusterlint context and timeout precede run")
end

do
  local theme = require("doksuela.ui.theme")
  eq(theme.describe(theme.shortcut), "orange", "shortcut is normal orange")
  truthy(theme.shortcut.bg == nil and theme.shortcut.bg_r == nil, "shortcut has no background")
  eq(theme.shortcut.fg_r, 255, "shortcut red channel")
  eq(theme.shortcut.fg_g, 165, "shortcut green channel")
  eq(theme.shortcut.fg_b, 0, "shortcut blue channel")
  theme.cycle("shortcut", 1)
  eq(theme.describe(theme.shortcut), "dark orange", "cycle moves to the next palette color")
  theme.cycle("shortcut", -1)
  eq(theme.describe(theme.shortcut), "orange", "cycle returns to orange")
  local dir = "/tmp/doksuela-theme-test"
  os.execute("rm -rf " .. dir .. " && mkdir -p " .. dir)
  cache.write_json(dir .. "/theme.json", theme.export())
  theme.cycle("shortcut", 1)
  theme.load(cache.read_json(dir .. "/theme.json"))
  eq(theme.describe(theme.shortcut), "orange", "saved theme restores orange")
  truthy(theme.shortcut.bg_r == nil, "loaded shortcut still has no background")
  eq(theme.describe(theme.progress), "light gray", "progress starts light gray")
  eq(theme.describe(theme.progress_bg), "dark gray", "bar track starts dark gray")
  local attr = theme.bar_attr()
  eq(attr.fg_r, 211, "bar foreground red")
  eq(attr.bg_r, 48, "bar background red")
  eq(attr.bg_b, 48, "bar background blue")
  truthy(attr.bg == nil, "bar background is truecolor")
  local saved_bar = theme.export()
  theme.cycle("progress_bg", -1)
  eq(theme.describe(theme.progress_bg), "light gray", "bar track cycles like the other roles")
  eq(theme.bar_attr().bg_r, 211, "a cycled track color is painted as the background")
  theme.load(saved_bar)
  eq(theme.describe(theme.progress_bg), "dark gray", "bar track restores")
  eq(theme.describe(theme.progress), "light gray", "progress restores")
end

do
  local bar = require("doksuela.bar")
  eq(bar.glyphs(0), string.rep(" ", 10), "zero steps is an empty track")
  eq(bar.glyphs(1), "▎" .. string.rep(" ", 9), "one step is a quarter block")
  eq(bar.glyphs(10), "██▌" .. string.rep(" ", 7), "ten steps")
  eq(bar.glyphs(39), string.rep("█", 9) .. "▊", "thirty-nine steps")
  eq(bar.glyphs(40), string.rep("█", 10), "forty steps fill the bar")
  eq(bar.glyphs(80), string.rep("█", 10), "steps above forty stay full")
  eq(bar.from_counts(1, 1, true), 40, "an idle bar is full")
  eq(bar.from_counts(0, 9, false), 0, "a new load starts empty")
  eq(bar.from_counts(2, 9, false), 8, "two of nine items is eight steps")
  eq(bar.from_counts(9, 9, false), 40, "a finished count fills the bar")
end

do
  local dir = "/tmp/doksuela-wave-test"
  os.execute("rm -rf " .. dir)
  local session = Session.new({ fixture = fixture, cache_root = dir })
  eq(session:progress_steps(), 40, "idle progress is full")
  eq(session:footer_text(), "", "idle footer has no command")
  session:boot()
  local init_n = 0
  local other = false
  for _, item in ipairs(session.queue.pending) do
    init_n = init_n + 1
    if item.reason ~= "Init" then
      other = true
    end
  end
  truthy(init_n > 0 and not other, "boot marks every command Init")
  eq(session:progress_steps(), 0, "boot starts the bar empty")
  session:tick()
  eq(session:progress_steps(), 8, "two finished items of nine advance the bar")
  session:drain()
  eq(session:progress_steps(), 40, "a finished boot fills the bar")

  session:select_cluster(session.clusters[1])
  local clusters_ok = #session.queue.pending > 0
  for _, item in ipairs(session.queue.pending) do
    if item.reason ~= "Clusters" then
      clusters_ok = false
    end
  end
  truthy(clusters_ok, "opening a cluster marks commands Clusters")
  local saw_lb = false
  local guard = 0
  while not session:idle() do
    for _, item in ipairs(session.queue.pending) do
      if type(item.id) == "string" and item.id:sub(1, 4) == "lb__" then
        eq(item.reason, "Clusters", "a load balancer follow-up keeps Clusters")
        saw_lb = true
      end
    end
    session:tick()
    guard = guard + 1
    if guard > 500 then
      break
    end
  end
  truthy(saw_lb, "selecting a cluster queues a load balancer")
  eq(session:progress_steps(), 40, "the cluster load fills the bar")

  session:refresh("nodes")
  local nodes_ok = #session.queue.pending > 0
  for _, item in ipairs(session.queue.pending) do
    if item.reason ~= "Nodes" then
      nodes_ok = false
    end
  end
  truthy(nodes_ok, "recheck Nodes marks commands Nodes")
  session:drain()

  session:refresh("pods")
  local pods_ok = false
  for _, item in ipairs(session.queue.pending) do
    if item.reason == "Pods" then
      pods_ok = true
    end
  end
  truthy(pods_ok, "recheck Pods marks commands Pods")
  session:drain()

  session:reload()
  local reload_ok = #session.queue.pending > 0
  for _, item in ipairs(session.queue.pending) do
    if item.reason ~= "Reload" then
      reload_ok = false
    end
  end
  truthy(reload_ok, "reload marks commands Reload")
  eq(session:progress_steps(), 0, "reload starts the bar over")
  session:drain()
  eq(session:progress_steps(), 40, "an idle reload fills the bar")
end

do
  local dir = "/tmp/doksuela-verb-test"
  os.execute("rm -rf " .. dir)
  local session = Session.new({ cache_root = dir, max = 2 })
  session.reason = "Nodes"
  session:enqueue("_account", {
    id = "nodes-sleep",
    argv = { "sleep", "30" },
    parse = "text",
    priority = 10,
  })
  session.reason = "Pods"
  session:enqueue("_account", {
    id = "pods-sleep",
    argv = { "sleep", "30" },
    parse = "text",
    priority = 10,
  })
  session:tick()
  eq(session:footer_text(), "Nodes sleep 30  ·  Pods sleep 30", "each running command keeps its trigger")
  eq(session:progress_steps(), 0, "a running load starts empty")
  for _, job in ipairs(session.queue.running) do
    if job.pid then
      os.execute("kill -9 " .. tostring(job.pid) .. " >/dev/null 2>&1")
    end
  end
end

do
  local function drain_real(session)
    local spins = 0
    while not session:idle() do
      session:tick()
      spins = spins + 1
      if spins > 500 then
        break
      end
      if not session:idle() then
        os.execute("sleep 0.01")
      end
    end
    return spins
  end
  local dir = "/tmp/doksuela-usage-test"
  os.execute("rm -rf " .. dir)
  local session = Session.new({ cache_root = dir, max = 1 })
  session:enqueue("_account", {
    id = "usage",
    argv = { "sh", "-c", "printf '%s\\n' 'Incorrect Usage: flag provided but not defined: -context'; exit 1" },
    parse = "json",
    priority = 10,
  })
  drain_real(session)
  eq(session.raw._account.usage.error,
    "Incorrect Usage: flag provided but not defined: -context",
    "a usage error on stdout replaces exit 1")
  eq(session.log.records[1].stderr,
    "Incorrect Usage: flag provided but not defined: -context",
    "history keeps the usage line")

  session:enqueue("_account", {
    id = "jsonfail",
    argv = { "sh", "-c", "printf '%s\\n' '{\"Diagnostics\":[]}'; exit 1" },
    parse = "json",
    priority = 10,
  })
  drain_real(session)
  eq(session.raw._account.jsonfail.error, "exit 1", "failed json on stdout stays exit 1")
  eq(session.log.records[2].stderr, "", "failed json does not copy stdout into history")

  session:enqueue("_account", {
    id = "stderrfail",
    argv = { "sh", "-c", "printf '%s\\n' 'real problem' >&2; printf '%s\\n' 'stdout line'; exit 1" },
    parse = "json",
    priority = 10,
  })
  drain_real(session)
  eq(session.raw._account.stderrfail.error, "real problem", "stderr wins over stdout")
end

do
  local textfit = require("doksuela.textfit")
  local width = require("terminal.text.width")
  local function sw(s)
    return width.utf8swidth(s)
  end
  local joined = "Init doctl kubernetes cluster list --output json --interactive=false"
    .. "  ·  Init kubectl get pods -A -o json --context do-tor1-cluster-canada-001"
  for _, amb in ipairs({ 1, 2 }) do
    width.set_ambiguous_width(amb)
    local once = textfit.fit(joined, 40, sw)
    local twice = textfit.fit(once, 40, sw)
    local valid = pcall(function()
      for _ in utf8.codes(twice) do end
    end)
    truthy(valid, "clipped parallel footer stays valid UTF-8 at ambiguous width " .. amb)
    truthy(sw(twice) <= 40, "clipped parallel footer fits at ambiguous width " .. amb)
    local dash = textfit.fit("abcd—efghijkl", 6, sw)
    truthy(pcall(sw, dash) and sw(dash) <= 6, "an em dash clips on a character boundary")
  end
  width.set_ambiguous_width(1)
  local bad = textfit.fit("ok\255tail and more text", 8, sw)
  truthy(pcall(function()
    for _ in utf8.codes(bad) do end
  end), "invalid bytes are stripped before clipping")
  truthy(sw(bad) <= 8, "sanitized text still fits")
end

do
  local dir = "/tmp/doksuela-tty-test"
  os.execute("rm -rf " .. dir)
  local session = Session.new({ cache_root = dir, max = 4 })
  session:enqueue("_account", {
    id = "tty",
    argv = { "sh", "-c", "if test -t 0; then printf tty; else printf notty; fi" },
    parse = "text",
  })
  local spins = 0
  while not session:idle() do
    session:tick()
    spins = spins + 1
    if spins > 100 then
      break
    end
    if not session:idle() then
      os.execute("sleep 0.02")
    end
  end
  eq(session.raw._account.tty and session.raw._account.tty.data, "notty", "background commands do not inherit the tty")
end

do
  local dir = "/tmp/doksuela-stale-test"
  os.execute("rm -rf " .. dir)
  local session = Session.new({ cache_root = dir, max = 4 })
  session:enqueue("_account", {
    id = "race",
    argv = { "sh", "-c", "sleep 0.25; printf slow" },
    parse = "text",
  })
  session:enqueue("_account", {
    id = "race",
    argv = { "sh", "-c", "printf fast" },
    parse = "text",
  }, true)
  local spins = 0
  while not session:idle() do
    session:tick()
    spins = spins + 1
    if spins > 80 then
      break
    end
    if not session:idle() then
      os.execute("sleep 0.02")
    end
  end
  eq(session.raw._account.race and session.raw._account.race.data, "fast", "an older parallel run does not overwrite the newer result")
  truthy(session:idle(), "the parallel race drained")
end

if failures > 0 then
  io.stderr:write(failures, " failed, ", checks_run, " checks\n")
  os.exit(1)
end
io.stdout:write(checks_run, " checks passed\n")
