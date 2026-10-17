--- Keep a selected row inside a scrolling window. No terminal dependency.

local M = {}

function M.ensure(count, selected, scroll, height)
  if height < 1 then
    height = 1
  end
  if count < 1 then
    return 1, 0
  end
  if selected < 1 then
    selected = 1
  end
  if selected > count then
    selected = count
  end
  if scroll < 0 then
    scroll = 0
  end
  if scroll > selected - 1 then
    scroll = selected - 1
  end
  if selected > scroll + height then
    scroll = selected - height
  end
  local max_scroll = math.max(0, count - height)
  if scroll > max_scroll then
    scroll = max_scroll
  end
  return selected, scroll
end

function M.page(count, selected, scroll, height, direction)
  local step = height
  if step < 1 then
    step = 1
  end
  selected = selected + direction * step
  return M.ensure(count, selected, scroll, height)
end

return M
