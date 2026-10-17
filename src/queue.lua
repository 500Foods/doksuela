--- A small priority queue of commands. Lower priority runs first. At most `max` run at once.

local exec = require("doksuela.exec")

local M = {}

function M.new(opts)
  return setmetatable({
    max = (opts and opts.max) or 2,
    pending = {},
    running = {},
  }, { __index = M })
end

function M.has(q, id)
  for _, item in ipairs(q.pending) do
    if item.id == id then
      return true
    end
  end
  for _, job in ipairs(q.running) do
    if job.item and job.item.id == id then
      return true
    end
  end
  return false
end

function M.clear_pending(q)
  q.pending = {}
end

function M.force(q, item)
  item.priority = item.priority or 0
  local at = #q.pending + 1
  for i, other in ipairs(q.pending) do
    if item.priority < other.priority then
      at = i
      break
    end
  end
  table.insert(q.pending, at, item)
  return true
end

function M.drop_pending(q, id)
  local kept = {}
  for _, item in ipairs(q.pending) do
    if item.id ~= id then
      kept[#kept + 1] = item
    end
  end
  q.pending = kept
end

function M.push(q, item)
  if M.has(q, item.id) then
    return false
  end
  item.priority = item.priority or 10
  local at = #q.pending + 1
  for i, other in ipairs(q.pending) do
    if item.priority < other.priority then
      at = i
      break
    end
  end
  table.insert(q.pending, at, item)
  return true
end

function M.boost(q, id)
  for i, item in ipairs(q.pending) do
    if item.id == id then
      table.remove(q.pending, i)
      item.priority = 0
      M.push(q, item)
      return true
    end
  end
  return false
end

function M.current(q)
  local job = q.running[1]
  if job then
    return job.argv
  end
  return nil
end

function M.idle(q)
  return #q.pending == 0 and #q.running == 0
end

function M.tick(q)
  while #q.running < q.max and #q.pending > 0 do
    local item = table.remove(q.pending, 1)
    local job = exec.start(item.argv, item)
    job.item = item
    q.running[#q.running + 1] = job
  end
  local done = {}
  local i = 1
  while i <= #q.running do
    local job = q.running[i]
    if exec.poll(job) then
      table.remove(q.running, i)
      done[#done + 1] = job
    else
      i = i + 1
    end
  end
  return done
end

return M
