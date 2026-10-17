--- SGR mouse sequences from terminal.input.readansi.

local M = {}

function M.parse(seq)
  if type(seq) ~= "string" then
    return nil
  end
  local btn, col, row, kind = seq:match("^\27%[<(%d+);(%d+);(%d+)([Mm])$")
  if not btn then
    return nil
  end
  btn = tonumber(btn)
  local motion = (btn & 32) ~= 0
  local wheel = (btn & 64) ~= 0
  local button = btn & 3
  return {
    row = tonumber(row),
    col = tonumber(col),
    motion = motion,
    wheel = wheel,
    wheel_up = wheel and button == 0,
    wheel_down = wheel and button == 1,
    press = kind == "M" and not motion and not wheel,
    release = kind == "m" and not wheel,
    left = (not wheel) and button == 0,
  }
end

function M.hit(box, row, col)
  return box
    and row == box.row
    and col >= box.col
    and col < box.col + box.width
end

function M.find(boxes, row, col)
  for _, box in ipairs(boxes) do
    if M.hit(box, row, col) then
      return box
    end
  end
  return nil
end

return M
