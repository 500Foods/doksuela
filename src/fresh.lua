--- Freshness is about age. Health stays in the words beside the number.

local M = {}

--- Decide what to keep when a section is rebuilt.
-- A failed recheck keeps the previous summary so its number stays cached (blue).
function M.apply(previous, summary, complete, err)
  if err and previous and previous.summary then
    return {
      summary = previous.summary,
      confirmed = false,
      error = err,
    }
  end
  return {
    summary = summary,
    confirmed = complete and not err or false,
    error = err,
  }
end

--- Colors for the number and the right-hand context.
-- number/context: "fresh" | "cached" | "dim" | "error"
function M.paint(section)
  section = section or {}
  if not section.summary then
    return {
      number = "dim",
      context = section.error and "error" or "dim",
    }
  end
  if section.confirmed and not section.error then
    return { number = "fresh", context = "fresh" }
  end
  if section.error then
    return { number = "cached", context = "error" }
  end
  return { number = "cached", context = "cached" }
end

return M
