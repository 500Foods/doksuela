--- A 10-cell progress bar. Each cell is one of four quarter blocks, so the bar has 40 steps.
-- An empty step is a space so a dark background still draws the track.

local M = {}

M.cells = 10
M.steps = 40

local QUARTERS = {
  [0] = " ",
  [1] = "▎",
  [2] = "▌",
  [3] = "▊",
  [4] = "█",
}

function M.glyphs(steps, cells)
  cells = math.floor(tonumber(cells) or M.cells)
  if cells < 1 then
    return ""
  end
  steps = math.floor(tonumber(steps) or 0)
  if steps < 0 then
    steps = 0
  elseif steps > M.steps then
    steps = M.steps
  end
  local filled_steps = steps
  if cells ~= M.cells then
    filled_steps = math.floor(steps * cells * 4 / M.steps)
  end
  local parts = {}
  for i = 1, cells do
    local filled = filled_steps - (i - 1) * 4
    if filled < 0 then
      filled = 0
    elseif filled > 4 then
      filled = 4
    end
    parts[i] = QUARTERS[filled]
  end
  return table.concat(parts)
end

-- Idle draws a full bar. Otherwise steps are floor(40 * done / total).
function M.from_counts(done, total, idle)
  if idle then
    return M.steps
  end
  total = math.floor(tonumber(total) or 0)
  done = math.floor(tonumber(done) or 0)
  if total < 1 or done <= 0 then
    return 0
  end
  if done > total then
    done = total
  end
  return math.floor(M.steps * done / total)
end

return M
