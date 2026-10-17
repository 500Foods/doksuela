# doksuela: read-only DOKS explorer

doksuela is a full-screen terminal UI for one DigitalOcean Kubernetes (DOKS) cluster. It shows the DigitalOcean side (`doctl`) and the Kubernetes side (`kubectl`) together, and surfaces `clusterlint` diagnostics with a jump to the object they mention.

The README already states that goal. The only program is an untracked splash screen, `doksuela.lua`, which draws the title, highlights `<ENTER>` under the mouse, and exits. Lua 5.5.1, `terminal` 0.1.0 (LuaRocks), `luasystem` 0.7.1, `doctl` 1.175.0, `kubectl`, and `clusterlint` 0.14.0 are installed on this machine. No JSON library is installed.

The first build is a read-only explorer. The mouse drives it. Cached facts paint immediately. A check from an earlier session shows in blue until a live check confirms it, then that number turns green. Every `doctl`, `kubectl`, and `clusterlint` command is written to a log. Later builds add confirmed mutations, upgrades, and packaging.

## First build

A person who already has `doctl auth` and the three CLIs can:

1. Open doksuela, pass the splash, and land on the last cluster they selected.
2. See a vertical main menu at once, with a count on the left of each row and issues or other context on the right, drawn from the last successful check.
3. Watch each count turn from blue to green as that check finishes in the background. The mouse keeps working while checks run.
4. Open a row and browse the joined data: nodes and node pools, pods, domains, services, volumes, load balancers, and clusterlint.
5. Read a log of every CLI command the session issued.
6. Switch clusters. The choice is remembered for the next launch.

Creating or deleting clusters, scaling, cordon, drain, upgrade, pod logs, exec, and apply wait for a later build.

## Freshness colors

Color describes how old a fact is. The words next to a number describe health.

- Blue: the value was loaded from the on-disk cache. It is the last successful check, and this session has not confirmed it yet.
- Green: a check started in this session has returned successfully, and the number on screen is that result.
- Dim: this section has never been checked, so there is no count to show. The first successful check paints it green.

The label of the row stays the normal text color. The left-hand count and the right-hand context use the freshness color. A failed recheck leaves the previous number blue and puts a short error on the right in yellow. A failure never turns the row green.

Each section has its own freshness. Nodes can already be green while lint is still blue.

## Cache

Cache lives in `~/.cache/doksuela/`.

- `state.json` stores the last selected cluster id and name.
- `clusters/<id>/<section>.json` stores the decoded snapshot, the summary counts, the right-hand context string, and `fetched_at`.
- `commands.log` is an append-only log of CLI invocations.

Startup reads the cache and draws before any CLI runs. Refresh writes a section file only after a successful decode. A failed check leaves the previous file in place. Cache files contain resource names, ids, and status fields. They do not contain kubeconfig secrets or API tokens. `kubectl config view` is called without `--raw`.

## Command log

Every `doctl`, `kubectl`, and `clusterlint` invocation appends one record: local time, duration, exit code, and the argument vector. The log stores the real command, such as `doctl kubernetes cluster get example --output json --interactive=false`. It does not store the shell wrapper used to run that command in the background. Stderr is kept, trimmed to the last few kilobytes. Stdout is kept only long enough to decode; the decoded snapshot lives in the section cache.

The footer shows the command currently running, or the most recent one when the queue is idle. `l`, or a click on that footer line, opens the log. The log is a scrollable list. Clicking a row shows duration, exit code, and the stderr tail. The same records are in `commands.log` for use outside the UI.

## How commands run

doksuela is a front-end. It shells out and parses JSON. It does not call the DigitalOcean or Kubernetes HTTP APIs itself, and it does not scrape text tables.

Every `doctl` invocation passes `--output json` and `--interactive=false`. The TUI owns the tty, and doctl enables interactive behavior when it thinks it is attached to a terminal. Every `kubectl` invocation passes `-o json`, `--context`, and `--request-timeout=15s`. clusterlint is invoked as `clusterlint run --output json --context <name> --timeout 30s`.

Render functions never run commands. The event loop draws from snapshots.

Checks run off the event loop so mouse and keyboard keep working. On Linux the runner starts a command with stdout, stderr, and the exit code sent to temp files, records the pid, and returns. Each `readansi(0.15)` tick polls those pids. When a pid exits, the loop reads the files, decodes JSON, updates the snapshot, flips that section to green, and appends the command log. At most two commands run at once. Opening a section moves its check to the front of the queue. `r` requeues the visible section.

Add `dkjson` with LuaRocks for Lua 5.5. It is pure Lua. Missing or unexpected fields render as `—`. Decoders accept the JSON this machine's CLIs emit, pinned by fixtures.

kubeconfig is read with `kubectl config view -o json`, which redacts certificates and tokens. A cluster matches a context when the context's server host equals the cluster `endpoint` host. The fallback name is `do-<region>-<cluster>`, which is what `doctl kubernetes cluster kubeconfig save` writes.

When nothing matches, Kubernetes rows on the menu say so on the right, and `s` offers to save a kubeconfig. That write changes `~/.kube/config`, so the UI asks for confirmation first. The command is `doctl kubernetes cluster kubeconfig save <id> --interactive=false`. Cache updates and the command log are local bookkeeping and do not ask.

## Screens

The splash stays. Enter or a left click on `<ENTER>` continues. `q` quits. When `state.json` names a cluster that is still in the cached cluster list, continue opens that cluster's main menu. Otherwise it opens the cluster list.

The cluster list comes from cache first, then from `doctl kubernetes cluster list -o json`. Columns are name, region, version, status, HA, and node-pool count. The remembered cluster is marked. Clicking a row or pressing Enter selects it, writes `state.json`, and opens the main menu.

### Main menu

The main screen is a `terminal.ui.panel.Screen`:

- Header bar: cluster name, region, version, status, and kubectl context. Those values follow the same blue, green, and dim rules as the menu counts.
- Body: a vertical menu. Each row is `count`, label, and context. A hover highlight follows the mouse, the same way the splash highlights `<ENTER>`.
- Footer key bar, plus the current command.

`terminal` has no table widget. The menu and the drill-in lists are a small table: selection, scrolling, wheel and click hit-testing, and column clipping with `terminal.text.width`.

Clicking a row, or pressing Enter, opens that section. Esc returns to the menu. A Clusters row at the bottom of the menu returns to the cluster list.

The menu, and the context each row shows:

| Row | Left count | Right-hand context |
| --- | --- | --- |
| Nodes | Kubernetes node count | not-ready count, and the node-pool count |
| Pods | pod count | pods that are not Running and not Succeeded |
| Workloads | Deployment + StatefulSet + DaemonSet count | objects with unavailable replicas |
| Services | Service count | LoadBalancer Services still waiting for an address |
| Domains | hostname count | hostnames with no DigitalOcean DNS record aimed at this cluster |
| Volumes | PVC count | unbound PVCs, and DigitalOcean volumes in the associated-resources list |
| Load balancers | DigitalOcean load balancer count | balancers whose status is not healthy |
| Lint | diagnostic count | error count and warning count |

Overview facts live in the header: version, region, status, HA, auto-upgrade, surge upgrade, maintenance window, and whether `get-upgrades` lists a newer version. They refresh with the cluster-get check and use the same colors.

Inside a section, a context line under the header repeats that row's count and context, plus the check time ("checked just now" or "from cache, 3h ago"). Lists keep per-row context so the surrounding facts stay visible after you leave the menu. The detail pane below the list is the selected object.

### Nodes

Pools from `doctl kubernetes cluster node-pool list <id> -o json`. Nodes from `kubectl --context <ctx> get nodes -o json`.

Join on Kubernetes node name, which DOKS sets to the droplet name. When that misses, fall back to the node label `doks.digitalocean.com/node-id` or `doks.digitalocean.com/node-pool-id`.

Rows group under the pool: size slug, count, min/max when autoscaling is on. Each node row shows ready state, roles, kubelet version, and droplet id. The detail pane shows conditions, allocatable CPU and memory, and the labels and taints that came from DigitalOcean. A pool node with no Kubernetes object, and a Kubernetes node with no pool, both stay visible and name the missing side.

### Pods and workloads

Pods are `kubectl get pods -A -o json`. Columns are namespace, name, ready, status, restarts, age, and node. The detail pane shows containers, images, and whether requests and limits are set. Age is computed from `creationTimestamp`.

Workloads are Deployments, StatefulSets, and DaemonSets, all namespaces. Columns are kind, namespace, name, ready, and age. The detail pane lists the pod template's containers and the replica counts.

### Services and load balancers

Services come from kubectl, all namespaces. LoadBalancer Services show the external address. The DigitalOcean load balancer id comes from the annotation `service.beta.kubernetes.io/do-loadbalancer-id`. Those ids, plus the ids from `doctl kubernetes cluster list-associated-resources <id> -o json`, are loaded with `doctl compute load-balancer get <id> -o json`. The detail pane shows Service ports beside the load balancer name, status, region, and droplet tag.

The Load balancers row lists every associated balancer, including one that no longer has a Service.

### Domains

Hostnames come from Ingress rules and TLS hosts, and from Service external names. DigitalOcean DNS comes from `doctl compute domain list -o json` and the records of domains that contain one of those hosts. A hostname is matched when a record's name equals it and the record data is one of this cluster's load balancer addresses. The right-hand count of "unmatched" hostnames is the issue context. The detail pane shows the Ingress or Service that published the host, and the DNS record when one matched.

### Volumes

PVCs and PVs come from kubectl. A PV whose CSI driver is `dobs.csi.digitalocean.com` joins to a DigitalOcean volume on `spec.csi.volumeHandle`. Volume details come from `doctl compute volume get <id> -o json`, limited to ids in the associated-resources list. Columns are claim, capacity, status, volume name, and size.

### Lint

`clusterlint run -o json` for the selected context. Installed clusterlint is 0.14.0. Its JSON uses the CLI's own field names, which differ from the public API. Capture one fixture and decode that.

Columns are severity, check name, kind, namespace, name, and message. Keys `e`, `w`, and `g` filter to error, warning, and suggestion. Enter on a diagnostic opens the matching object when the kind is one Pods, Workloads, Services, or Volumes already knows. clusterlint is queued after the faster checks. The footer names the running command, and the menu keeps the previous blue count until the run returns.

## Keys and mouse

The splash's SGR mouse parser moves into a shared module. Hit boxes cover `<ENTER>`, menu rows, list rows, the footer command, and back.

- `q` quits from the list, the menu, or a section.
- Up and down move the row. Page Up and Page Down scroll. The wheel scrolls. Hover moves the highlight. A left click selects, the same as Enter.
- Enter opens the highlighted menu row or follows a lint object. Esc returns to the menu, and from the menu returns to the cluster list.
- `r` requeues the visible section. `/` starts a filter inside a section; Esc clears it. The filter is a one-line buffer in the footer.
- `l` opens the command log. `c` opens the cluster list. `s` asks to save a kubeconfig when the cluster has no context.
- `?` opens a help overlay. Esc closes it.
- Resize goes through `screen:check_resize(true)` on the same timeout loop the splash uses.

## Errors and empty states

Each failed command stores stderr and the exit code on that section. The context line shows the error. The previous cached numbers stay blue. Other rows keep refreshing.

- Missing `doctl`, `kubectl`, or `clusterlint`: a full-screen message names the missing binary before any fetch.
- `doctl` auth failure: show stderr and the line `doctl auth init`.
- Empty cluster list, empty section, or a filter with no matches: the list says there is nothing to show.
- A section with no cache yet shows a dim count and the footer names the queued command.

## Code layout

`doksuela.lua` stays the executable entry point. It checks Lua 5.5, prepends the LuaRocks 5.5 paths, and prepends `<script-dir>/src/?.lua` derived from `arg[0]` so the program runs from any working directory.

```
doksuela.lua                 entry, splash handoff
src/exec.lua                 quote, background pid, poll, capture
src/log.lua                  command log, memory plus commands.log
src/cache.lua                state.json and per-section snapshots
src/json.lua                 dkjson decode
src/doctl.lua                cluster, pool, upgrade, associated resources, lb, volume, domain
src/kubectl.lua              config view, get, version
src/clusterlint.lua          run and decode
src/match.lua                context match, node join, service/LB join, PV/volume join, DNS join
src/fresh.lua                blue / green / dim / error for a section
src/app.lua                  splash, picker, menu, sections, key and mouse dispatch
src/ui/mouse.lua             SGR parse and hit boxes
src/ui/table.lua             list, scroll, selection, columns, freshness color
src/ui/theme.lua             blue, green, dim, error, hover
tests/run.lua                tiny assert runner, no extra framework
tests/fixtures/              recorded JSON, no live credentials
```

A `--fixture DIR` flag makes the command modules read those files and skip the CLIs. Jobs complete on the first poll. That is how the UI is developed without a cluster and how tests run.

## Tests and verification

`tests/run.lua` covers argument quoting, context matching, the joins, age formatting, table window math, mouse hit boxes, cache round-trip, and freshness transitions: no cache stays dim then turns green, a cached value stays blue until the new check returns, and a failed recheck stays blue with an error string. The command-log record contains the argv and excludes anything that looks like a token. The suite does not need a live cluster or a tty.

This is a terminal UI, so browser verification does not apply. Before calling the first build done:

- `lua tests/run.lua` passes.
- `lua doksuela.lua --fixture tests/fixtures` walks splash, remembered-cluster startup, the menu in blue then green, a click into Nodes, Domains, and Lint, the command log, filter, and resize.
- If a live DOKS cluster is available in the current `doctl` account, one manual pass confirms the same path against real CLIs, including a second launch that paints the cached menu before the new checks return.

## Repo cleanup in the same build

- Replace the Delphi `.gitignore` inherited from the template with ignores for LuaRocks output and `*.rock`. Cache and the command log live under `~/.cache/doksuela/`, outside the repo.
- Point the CLOC badge image at `500Foods/doksuela` and describe how to run the program in the README. Fix the typos in the opening paragraphs while that section is open.
- Leave the CLOC workflow as it is.
- Add a rockspec that depends on `terminal` and `dkjson` for Lua 5.5.
- Track `doksuela.lua`. It is currently untracked.

## Later builds

These wait until the read-only explorer is in daily use.

1. Confirmed actions. Each one names the object and asks before it runs: cordon and uncordon, drain, node-pool resize and autoscaler min/max, replace node, rerun one clusterlint check. Each action is a command-log entry.
2. Upgrades. The header already shows whether an upgrade is published. Running one requires typing the cluster name. The screen shows surge-upgrade state from the cluster object.
3. Packaging. A LuaRocks install path first. A single binary via `luastatic` (or similar) after that path is solid. The README's promise of platform binaries belongs to this build.

## Implementation order

1. Split the splash into the entry script and `src/`. Add `dkjson`, the fixture flag, the test runner, the gitignore, and the rockspec. The splash still exits on Enter.
2. Background command runner, command log, and disk cache. Fixture jobs complete on the first poll.
3. Cluster list from cache, then from `doctl`. Selecting a cluster writes `state.json`. The next launch opens that cluster.
4. Main menu chrome. Rows render from cache in blue, refresh in the background, and turn green per section. Mouse hover and click select a row.
5. Header overview from cluster get and get-upgrades, with the same colors. Confirmed kubeconfig save when no context matches.
6. Nodes, with the pool-to-node join and the menu's not-ready count.
7. Pods and workloads.
8. Services, load balancers, volumes, and domains, sharing one associated-resources fetch.
9. Lint, severity filter, and jump to an object. Lint stays last in the queue.
10. Command-log screen, filter, help, error and empty copy, README run instructions.
11. Fixture walkthrough, then a live pass when a cluster is reachable. Quit, relaunch, and confirm the menu is blue from cache before any check returns green.
