--- Run a command without blocking the UI, or finish a fixture on the first poll.

local clock = require("doksuela.clock")

local M = {}

function M.quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

function M.display(argv)
  local parts = {}
  for i, arg in ipairs(argv) do
    arg = tostring(arg)
    if arg == "" or arg:find("[%s'\"]") then
      parts[i] = M.quote(arg)
    else
      parts[i] = arg
    end
  end
  return table.concat(parts, " ")
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return ""
  end
  local body = f:read("a") or ""
  f:close()
  return body
end

local function ensure_dir(dir)
  os.execute("mkdir -p " .. M.quote(dir))
end

--- Start argv.
-- item.fixture completes in poll with item.fixture_stdout / fixture_stderr / fixture_exit.
-- Otherwise stdout, stderr, and the exit code land in item.workdir.
function M.start(argv, item)
  item = item or {}
  local job = {
    argv = argv,
    item = item,
    done = false,
    t0 = clock.wall(),
  }
  if item.fixture then
    job.fixture = true
    job.exit_code = item.fixture_exit or 0
    job.stdout = item.fixture_stdout or ""
    job.stderr = item.fixture_stderr or ""
    return job
  end

  local dir = item.workdir
  if not dir then
    error("exec.start needs item.workdir")
  end
  ensure_dir(dir)
  job.stdout_path = dir .. "/stdout"
  job.stderr_path = dir .. "/stderr"
  job.code_path = dir .. "/code"
  -- A previous run can leave an exit file in a reused directory. Poll would
  -- treat the new command as finished and read a truncated stdout.
  os.remove(job.stdout_path)
  os.remove(job.stderr_path)
  os.remove(job.code_path)

  local inner = M.display(argv)
    .. " > " .. M.quote(job.stdout_path)
    .. " 2> " .. M.quote(job.stderr_path)
    .. "; echo $? > " .. M.quote(job.code_path)
  -- setsid so the child keeps running after popen returns and does not see our tty.
  local launcher = "setsid sh -c " .. M.quote(inner) .. " >/dev/null 2>&1 & echo $!"
  local pipe = assert(io.popen(launcher, "r"))
  local pid = pipe:read("*l")
  pipe:close()
  job.pid = tonumber(pid)
  return job
end

--- Return true once the job has exited and its output is loaded.
function M.poll(job)
  if job.done then
    return true
  end
  if job.fixture then
    job.duration = 0
    job.done = true
    return true
  end
  local code_file = io.open(job.code_path, "r")
  if not code_file then
    return false
  end
  local body = code_file:read("a") or ""
  code_file:close()
  local code = body:match("(%d+)")
  if not code then
    return false
  end
  job.exit_code = tonumber(code) or 1
  job.stdout = read_file(job.stdout_path)
  job.stderr = read_file(job.stderr_path)
  job.duration = clock.wall() - (job.t0 or clock.wall())
  job.done = true
  return true
end

return M
