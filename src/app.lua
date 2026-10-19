--- Full-screen UI. Input and drawing. Data lives on the session.

local bar = require("doksuela.bar")
local bincheck = require("doksuela.bincheck")
local cache = require("doksuela.cache")
local exec = require("doksuela.exec")
local fresh = require("doksuela.fresh")
local listwin = require("doksuela.listwin")
local logmod = require("doksuela.log")
local model = require("doksuela.model")
local mouse = require("doksuela.ui.mouse")
local sessionlib = require("doksuela.session")
local textfit = require("doksuela.textfit")
local theme = require("doksuela.ui.theme")
local version = require("doksuela.version")

local t = require("terminal")
local Screen = require("terminal.ui.panel.screen")
local Panel = require("terminal.ui.panel")
local width = require("terminal.text.width")

local keys = t.input.keymap.get_keys()
local key_map = t.input.keymap.default_key_map

local MOUSE_ON = "\27[?1000h\27[?1003h\27[?1006h"
local MOUSE_OFF = "\27[?1006l\27[?1003l\27[?1000l"
-- Hold the frame until it is complete so a repaint does not flash blank.
local SYNC_ON = "\27[?2026h"
local SYNC_OFF = "\27[?2026l"

local ENTER_LABEL = "<ENTER>"
local PROMPT_SUFFIX = " to continue"
local TITLE = "doksuela"
local VERSION_LABEL = "v" .. version
local BORDER_TITLE = " " .. TITLE .. " " .. VERSION_LABEL .. " "

local M = {}

local function swidth(text)
  text = tostring(text)
  local ok, n = pcall(width.utf8swidth, text)
  if ok then
    return n
  end
  return width.utf8swidth(textfit.sanitize(text))
end

local function set_mouse(enabled)
  t.output.write(enabled and MOUSE_ON or MOUSE_OFF)
  t.output.flush()
end

local function write_at(row, col, text, attr)
  if text == nil or text == "" then
    return
  end
  t.cursor.position.set(row, col)
  if attr then
    t.text.push(attr)
  end
  t.output.write(text)
  if attr then
    t.text.pop()
  end
end

-- Paint text, with the shortcut letter in uppercase orange and no background.
local function write_marked(row, col, text, key, attr)
  text = tostring(text or "")
  local at = nil
  if type(key) == "string" and key ~= "" then
    at = text:lower():find(key:lower(), 1, true)
  end
  if not at then
    write_at(row, col, text, attr)
    return col + swidth(text)
  end
  local prefix = text:sub(1, at - 1)
  local mark = text:sub(at, at + #key - 1)
  if mark:find("%a") then
    mark = mark:upper()
  end
  local suffix = text:sub(at + #key)
  write_at(row, col, prefix, attr)
  col = col + swidth(prefix)
  write_at(row, col, mark, theme.shortcut)
  col = col + swidth(mark)
  write_at(row, col, suffix, attr)
  return col + swidth(suffix)
end

local function row_end(panel)
  return panel.inner_col + panel.inner_width
end

local function blank(panel, row)
  if row < panel.inner_row or row >= panel.inner_row + panel.inner_height then
    return
  end
  t.cursor.position.set(row, panel.inner_col)
  t.output.write(string.rep(" ", math.max(0, panel.inner_width)))
end

local function erase_tail(row, col, end_col)
  local width = end_col - col
  if width > 0 then
    t.cursor.position.set(row, col)
    t.output.write(string.rep(" ", width))
  end
end

-- One full line, padded so the previous text on that row is covered.
local function paint_line(panel, row, text, attr)
  if row < panel.inner_row or row >= panel.inner_row + panel.inner_height then
    return
  end
  local fitted = textfit.pad(textfit.fit(text or "", panel.inner_width, swidth), panel.inner_width, swidth)
  write_at(row, panel.inner_col, fitted, attr)
end

local function paint_span(row, col, span, text, attr)
  if span <= 0 then
    return
  end
  local fitted = textfit.pad(textfit.fit(text or "", span, swidth), span, swidth)
  write_at(row, col, fitted, attr)
end

local function clear_panel(panel)
  for row = panel.inner_row, panel.inner_row + panel.inner_height - 1 do
    blank(panel, row)
  end
end

local function ui_new()
  return {
    mode = "splash",
    selected = 1,
    scroll = 0,
    side = "cluster",
    hold = { cluster = 1, account = 1 },
    hold_scroll = { cluster = 0, account = 0 },
    filter = "",
    filtering = false,
    namespace = nil,
    ns_query = "",
    lint_level = nil,
    section = "nodes",
    hits = {},
    splash_hit = nil,
    footer_hit = nil,
    parallel_hit = nil,
    refresh_hit = nil,
    yes_hit = nil,
    no_hit = nil,
    missing = nil,
    popup = false,
    force_clear = false,
    dirty = true,
  }
end

local function section_state(session, id)
  return session.sections[id] or { summary = nil, confirmed = false, error = nil }
end

local function column_entries(session, items, with_clusters)
  local entries = {}
  for _, item in ipairs(items) do
    if with_clusters and item.id == "clusters" then
      local account = session:account_clusters()
      local tone = "dim"
      if account and account.confirmed and account.ok then
        tone = "fresh"
      elseif account and account.ok then
        tone = "cached"
      end
      local count = account and account.ok and tostring(#session.clusters) or "·"
      entries[#entries + 1] = {
        id = "clusters",
        label = item.label,
        key = item.key,
        count = count,
        context = "switch cluster",
        number_tone = tone,
        context_tone = tone,
      }
    elseif item.id == "theme" then
      entries[#entries + 1] = {
        id = "theme",
        label = item.label,
        key = item.key,
        count = "·",
        context = theme.describe(theme.shortcut),
        number_tone = "dim",
        context_tone = "shortcut",
      }
    else
      local state = section_state(session, item.id)
      local paint = fresh.paint(state)
      entries[#entries + 1] = {
        id = item.id,
        label = item.label,
        key = item.key,
        count = state.summary and state.summary.count or "·",
        context = state.error or (state.summary and state.summary.context) or "not checked yet",
        number_tone = paint.number,
        context_tone = paint.context,
      }
    end
  end
  return entries
end

local function menu_entries(session)
  return column_entries(session, sessionlib.menu, true)
end

local function account_entries(session)
  return column_entries(session, sessionlib.account_menu, false)
end

local function active_entries(session, ui)
  if ui.mode == "menu" and ui.side == "account" then
    return account_entries(session)
  end
  return menu_entries(session)
end

local function focus_side(ui, side, index)
  side = side == "account" and "account" or "cluster"
  if ui.side ~= side then
    ui.hold[ui.side or "cluster"] = ui.selected
    ui.hold_scroll[ui.side or "cluster"] = ui.scroll
    ui.side = side
    ui.selected = ui.hold[side] or 1
    ui.scroll = ui.hold_scroll[side] or 0
  end
  if index then
    ui.selected = index
  end
  ui.hold[ui.side] = ui.selected
  ui.hold_scroll[ui.side] = ui.scroll
end

local function section_label(id)
  for _, item in ipairs(sessionlib.menu) do
    if item.id == id then
      return item.label
    end
  end
  for _, item in ipairs(sessionlib.account_menu) do
    if item.id == id then
      return item.label
    end
  end
  return id
end

local function apply_filter(rows, filter)
  if not filter or filter == "" then
    return rows
  end
  local want = filter:lower()
  local filtered = {}
  for _, row in ipairs(rows) do
    local parts = {}
    for _, cell in ipairs(row.cells or {}) do
      parts[#parts + 1] = tostring(cell)
    end
    if table.concat(parts, " "):lower():find(want, 1, true) then
      filtered[#filtered + 1] = row
    end
  end
  return filtered
end

local function row_source(session, ui)
  if ui.mode == "namespaces" then
    local query = (ui.ns_query or ""):lower()
    local rows = {}
    for _, name in ipairs(session:namespaces()) do
      if query == "" or name:lower():find(query, 1, true) then
        rows[#rows + 1] = { cells = { name }, name = name }
      end
    end
    return rows, { "namespace" }
  end
  if ui.mode == "clusters" then
    return apply_filter(model.cluster_rows(session.clusters, session.remembered_id), ui.filter),
      { "name", "region", "version", "status", "ha", "pools", "" }
  end
  if ui.mode == "log" then
    local rows = {}
    for index = #session.log.records, 1, -1 do
      local rec = session.log.records[index]
      local stderr = rec.stderr
      if stderr == nil or stderr == "" then
        stderr = "(no stderr)"
      end
      rows[#rows + 1] = {
        cells = {
          logmod.format_started(rec),
          logmod.format_duration(rec.duration),
          exec.display(rec.argv or {}),
        },
        detail = "exit " .. tostring(rec.exit)
          .. "\nduration " .. logmod.format_duration(rec.duration)
          .. "\n" .. stderr,
      }
    end
    return apply_filter(rows, ui.filter), { "started", "duration", "command" }
  end
  if ui.mode == "section" then
    local state = section_state(session, ui.section)
    local summary = state.summary
    local rows = summary and summary.rows or {}
    if ui.section == "lint" and ui.lint_level then
      local filtered = {}
      for _, row in ipairs(rows) do
        if row.severity == ui.lint_level then
          filtered[#filtered + 1] = row
        end
      end
      rows = filtered
    end
    rows = model.restrict_namespace(rows, ui.namespace)
    return apply_filter(rows, ui.filter), summary and summary.columns or {}, summary and summary.widths
  end
  return {}, {}
end

local function column_widths(n, inner_width, widths)
  local gap = 1
  local width_of = {}
  local fixed = false
  if widths then
    for i = 1, n do
      local w = tonumber(widths[i])
      if w and w > 0 then
        fixed = true
        break
      end
    end
  end
  if not fixed then
    local colw = math.max(3, math.floor((inner_width - gap * (n - 1)) / n))
    for i = 1, n do
      width_of[i] = colw
    end
    return width_of
  end
  local room = inner_width - gap * (n - 1)
  if room < n then
    room = n
  end
  local reserved = 0
  local flex = {}
  for i = 1, n do
    local w = tonumber(widths[i])
    if w and w > 0 then
      width_of[i] = math.floor(w)
      reserved = reserved + width_of[i]
    else
      flex[#flex + 1] = i
    end
  end
  if reserved + #flex > room and reserved > 0 then
    local scale = math.max(0, room - #flex) / reserved
    reserved = 0
    for i = 1, n do
      if width_of[i] then
        width_of[i] = math.max(1, math.floor(width_of[i] * scale))
        reserved = reserved + width_of[i]
      end
    end
  end
  local each = 1
  if #flex > 0 then
    each = math.floor((room - reserved) / #flex)
    if each < 1 then
      each = 1
    end
  end
  for _, i in ipairs(flex) do
    width_of[i] = each
  end
  return width_of
end

local function line_of_cells(cells, inner_width, widths)
  local n = #cells
  if n == 0 then
    return ""
  end
  local gap = 1
  local width_of = column_widths(n, inner_width, widths)
  local parts = {}
  local used = 0
  for i, cell in ipairs(cells) do
    local width_for = width_of[i]
    if i == n then
      width_for = math.max(1, inner_width - used)
    end
    local fitted = textfit.fit(cell, width_for, swidth)
    if i < n then
      fitted = textfit.pad(fitted, width_for, swidth)
      used = used + width_for + gap
      parts[#parts + 1] = fitted .. " "
    else
      parts[#parts + 1] = fitted
    end
  end
  return table.concat(parts)
end

-- History keeps the start time and the 000.000 duration at a fixed width.
local function history_line(cells, inner_width)
  local started_w = 19
  local duration = tostring(cells[2] or "")
  local duration_w = math.max(8, swidth(duration))
  local command_w = inner_width - started_w - duration_w - 2
  if command_w < 8 then
    started_w = math.max(8, started_w - (8 - command_w))
    command_w = inner_width - started_w - duration_w - 2
  end
  if command_w < 1 then
    command_w = 1
  end
  local started = textfit.pad(textfit.fit(tostring(cells[1] or ""), started_w, swidth), started_w, swidth)
  local dur = textfit.pad(textfit.fit(duration, duration_w, swidth), duration_w, swidth)
  local command = textfit.fit(tostring(cells[3] or ""), command_w, swidth)
  return started .. " " .. dur .. " " .. command
end

local function add_hit(ui, kind, index, row, col, hit_width, side)
  ui.hits[#ui.hits + 1] = {
    kind = kind,
    index = index,
    row = row,
    col = col,
    width = hit_width,
    side = side,
  }
end

local function erase_span(row, col, span)
  if span > 0 then
    t.cursor.position.set(row, col)
    t.output.write(string.rep(" ", span))
  end
end

local function draw_splash(panel, ui)
  clear_panel(panel)
  ui.splash_hit = nil
  if panel.inner_height < 1 or panel.inner_width < 1 then
    return
  end
  local title_w = swidth(TITLE)
  local enter_w = swidth(ENTER_LABEL)
  local suffix_w = swidth(PROMPT_SUFFIX)
  local prompt_w = enter_w + suffix_w
  local title_row = panel.inner_row + math.max(0, math.floor((panel.inner_height - 3) / 2))
  local prompt_row = math.min(panel.inner_row + panel.inner_height - 1, title_row + 2)
  local title_col = panel.inner_col + math.max(0, math.floor((panel.inner_width - title_w) / 2))
  local prompt_col = panel.inner_col + math.max(0, math.floor((panel.inner_width - prompt_w) / 2))
  if title_w <= panel.inner_width then
    write_at(title_row, title_col, TITLE, theme.title)
  end
  local version_w = swidth(VERSION_LABEL)
  local version_row = title_row + 1
  if version_row < prompt_row and version_w <= panel.inner_width then
    local version_col = panel.inner_col + math.max(0, math.floor((panel.inner_width - version_w) / 2))
    write_at(version_row, version_col, VERSION_LABEL, theme.muted)
  end
  if prompt_w <= panel.inner_width then
    local enter_attr = theme.shortcut
    if ui.splash_hover then
      enter_attr = { fg = "white", bg = "red", brightness = "bright" }
    end
    write_at(prompt_row, prompt_col, ENTER_LABEL, enter_attr)
    write_at(prompt_row, prompt_col + enter_w, PROMPT_SUFFIX, theme.label)
    ui.splash_hit = { row = prompt_row, col = prompt_col, width = enter_w }
  end
end

local REFRESH_LABEL = "` Refresh"

local function draw_header(panel, session, ui)
  ui.refresh_hit = nil
  if panel.inner_height < 1 then
    return
  end
  local state = session.overview_state or {}
  local overview = state.summary or session.overview or {}
  local paint = fresh.paint(state)
  local tone = theme.pick(paint.number)
  local parts = {
    { overview.name or "doksuela", theme.title },
    { " " .. (overview.region or ""), tone },
    { " " .. (overview.version or ""), tone },
    { " " .. (overview.status or ""), tone },
    { " " .. (overview.ha or ""), theme.muted },
    { " " .. (overview.context or ""), tone },
  }
  local col = panel.inner_col
  local row = panel.inner_row
  local full_limit = row_end(panel)
  local limit = full_limit
  local button_w = swidth(REFRESH_LABEL)
  local button_col = full_limit
  if panel.inner_width >= button_w then
    button_col = panel.inner_col + panel.inner_width - button_w
    limit = button_col
  end
  for _, part in ipairs(parts) do
    local room = limit - col
    if room <= 0 then
      break
    end
    local text = textfit.fit(part[1], room, swidth)
    write_at(row, col, text, part[2])
    col = col + swidth(text)
  end
  if not session.context_name and session.cluster and col < limit then
    local hint = "  k saves kubeconfig"
    local room = limit - col
    local text = textfit.fit(hint, room, swidth)
    write_marked(row, col, text, "k", theme.error)
    col = col + swidth(text)
  end
  erase_tail(row, col, button_col)
  if button_col < row_end(panel) then
    write_marked(row, button_col, REFRESH_LABEL, "`", theme.label)
    ui.refresh_hit = { row = row, col = button_col, width = button_w }
  end
  if panel.inner_height >= 2 then
    local line = overview.context_line or ""
    if session.note then
      line = session.note .. "  " .. line
    end
    local show_filter = ui.filtering or (ui.filter and ui.filter ~= "")
    local filter = show_filter and ("/" .. (ui.filter or "")) or ""
    local badge = (ui.namespace and ui.namespace ~= "") and ("/" .. ui.namespace) or ""
    local badge_w = swidth(badge)
    local gap = filter ~= "" and "  " or ""
    local reserved = badge_w
    if badge_w > 0 then
      reserved = reserved + 1
    end
    local room = math.max(0, panel.inner_width - swidth(gap) - swidth(filter) - reserved)
    local text = textfit.fit(line, room, swidth)
    local row2 = row + 1
    write_at(row2, panel.inner_col, text, theme.pick(paint.context))
    local col2 = panel.inner_col + swidth(text)
    if filter ~= "" and col2 < full_limit - reserved then
      write_at(row2, col2, gap, theme.pick(paint.context))
      col2 = col2 + swidth(gap)
      col2 = write_marked(row2, col2, filter, "/", theme.title)
    end
    if badge_w > 0 then
      local badge_col = math.max(panel.inner_col, full_limit - badge_w)
      erase_tail(row2, col2, badge_col)
      local shown = textfit.fit(badge, full_limit - badge_col, swidth)
      write_marked(row2, badge_col, shown, "/", theme.title)
    else
      erase_tail(row2, col2, full_limit)
    end
  end
end

local function draw_footer(panel, session, ui)
  ui.footer_hit = nil
  ui.parallel_hit = nil
  if panel.inner_height < 1 or panel.inner_width < 1 then
    return
  end
  local row = panel.inner_row
  local bar_w = math.min(bar.cells, panel.inner_width)
  local command = session:footer_text()
  local status = command ~= "" and command or "Ready"
  local status_attr = command ~= "" and theme.label or theme.fresh
  local chip = "×" .. tostring(session:parallel())
  local chip_w = swidth(chip)
  local gap = 1
  local text_w = panel.inner_width - bar_w - chip_w - gap
  if text_w < 1 then
    chip = ""
    chip_w = 0
    gap = 0
    text_w = panel.inner_width - bar_w
    if text_w < 0 then
      bar_w = panel.inner_width
      text_w = 0
    end
  end
  local shown = status
  if text_w > 0 then
    shown = textfit.fit(status, text_w, swidth)
    paint_span(row, panel.inner_col, text_w, shown, status_attr)
  end
  if gap > 0 then
    write_at(row, panel.inner_col + text_w, " ", theme.label)
  end
  if chip_w > 0 then
    local chip_col = panel.inner_col + text_w + gap
    write_at(row, chip_col, chip, theme.shortcut)
    ui.parallel_hit = { kind = "parallel", row = row, col = chip_col, width = chip_w }
  end
  if bar_w > 0 then
    write_at(row, panel.inner_col + text_w + gap + chip_w, bar.glyphs(session:progress_steps(), bar_w), theme.bar_attr())
  end
  if command ~= "" and text_w > 0 then
    ui.footer_hit = {
      kind = "footer",
      row = row,
      col = panel.inner_col,
      width = text_w,
    }
  end
end

local function align_right(text, width)
  text = tostring(text or "")
  if width < 1 then
    return ""
  end
  if swidth(text) > width then
    text = textfit.fit(text, width, swidth)
  end
  local gap = width - swidth(text)
  if gap > 0 then
    return string.rep(" ", gap) .. text
  end
  return text
end

local function column_layout(width)
  local count_w = 4
  local label_w = width >= 56 and 16 or math.max(8, math.min(14, width - count_w - 12))
  local used = 2 + count_w + 1 + label_w + 1
  if used > width then
    label_w = math.max(1, width - (2 + count_w + 2))
    used = 2 + count_w + 1 + label_w + 1
  end
  if label_w < 1 then
    label_w = 1
  end
  return count_w, label_w, math.max(0, width - used)
end

local function paint_menu_column(ui, row, origin, width, entry, index, marked, side)
  erase_span(row, origin, width)
  if not entry or width < 1 then
    return
  end
  local count_w, label_w, context_w = column_layout(width)
  write_at(row, origin, marked and ">" or " ", theme.marker)
  if width < 3 then
    add_hit(ui, "row", index, row, origin, width, side)
    return
  end
  if origin + 2 + count_w > origin + width then
    count_w = math.max(0, width - 2)
  end
  local count = align_right(entry.count, count_w)
  write_at(row, origin + 2, count, theme.pick(entry.number_tone))
  local label_col = origin + 2 + count_w + 1
  if label_col < origin + width then
    local room = math.min(label_w, origin + width - label_col)
    local label = textfit.fit(entry.label, room, swidth)
    local label_end = write_marked(row, label_col, label, entry.key, theme.label)
    local label_stop = math.min(origin + width, label_col + room)
    if label_end < label_stop then
      write_at(row, label_end, string.rep(" ", label_stop - label_end), theme.label)
    end
  end
  if context_w > 0 then
    local context_col = label_col + label_w + 1
    if context_col < origin + width then
      local context = textfit.fit(entry.context, origin + width - context_col, swidth)
      write_at(row, context_col, context, theme.pick(entry.context_tone))
    end
  end
  add_hit(ui, "row", index, row, origin, width, side)
end

local function draw_menu(panel, session, ui)
  local left = menu_entries(session)
  local right = account_entries(session)
  local gap = 2
  local left_w = math.floor(math.max(0, panel.inner_width - gap) / 2)
  local right_w = math.max(0, panel.inner_width - gap - left_w)
  local right_origin = panel.inner_col + left_w + gap
  local heading = panel.inner_height > 1
  local list_height = heading and (panel.inner_height - 1) or panel.inner_height
  if list_height < 1 then
    list_height = 1
  end
  local list_top = heading and (panel.inner_row + 1) or panel.inner_row
  ui.list_height = list_height

  local left_sel, left_scroll
  local right_sel, right_scroll
  if ui.side == "account" then
    right_sel, right_scroll = listwin.ensure(#right, ui.selected, ui.scroll, list_height)
    left_sel, left_scroll = listwin.ensure(#left, ui.hold.cluster or 1, ui.hold_scroll.cluster or 0, list_height)
    ui.selected, ui.scroll = right_sel, right_scroll
  else
    left_sel, left_scroll = listwin.ensure(#left, ui.selected, ui.scroll, list_height)
    right_sel, right_scroll = listwin.ensure(#right, ui.hold.account or 1, ui.hold_scroll.account or 0, list_height)
    ui.selected, ui.scroll = left_sel, left_scroll
    ui.side = "cluster"
  end
  ui.hold.cluster, ui.hold_scroll.cluster = left_sel, left_scroll
  ui.hold.account, ui.hold_scroll.account = right_sel, right_scroll

  if heading then
    local head = panel.inner_row
    erase_span(head, panel.inner_col, left_w)
    write_at(head, panel.inner_col, textfit.fit("Kubernetes Cluster", left_w, swidth), theme.title)
    erase_span(head, panel.inner_col + left_w, gap)
    erase_span(head, right_origin, right_w)
    write_at(head, right_origin, textfit.fit("DigitalOcean Account", right_w, swidth), theme.title)
  end
  for i = 1, list_height do
    local row = list_top + i - 1
    if row >= panel.inner_row + panel.inner_height then
      break
    end
    local left_index = left_scroll + i
    local right_index = right_scroll + i
    paint_menu_column(
      ui, row, panel.inner_col, left_w, left[left_index], left_index,
      ui.side ~= "account" and left_index == left_sel, "cluster"
    )
    erase_span(row, panel.inner_col + left_w, gap)
    paint_menu_column(
      ui, row, right_origin, right_w, right[right_index], right_index,
      ui.side == "account" and right_index == right_sel, "account"
    )
  end
end

local function draw_rows(panel, session, ui, top_lines)
  top_lines = top_lines or 0
  local rows, columns, widths = row_source(session, ui)
  local list_top = panel.inner_row + top_lines
  local list_height = panel.inner_height - top_lines
  local detail_h = 0
  if ui.mode == "section" or ui.mode == "log" or ui.mode == "clusters" then
    detail_h = math.max(3, math.floor(panel.inner_height * 0.35))
    if list_height - detail_h < 3 then
      detail_h = math.max(0, list_height - 3)
    end
    list_height = list_height - detail_h
  end
  local text_width = math.max(1, panel.inner_width - 2)
  local function cells_line(cells)
    if ui.mode == "log" then
      return history_line(cells, text_width)
    end
    return line_of_cells(cells, text_width, widths)
  end
  if #columns > 0 and list_height > 1 then
    paint_line(panel, list_top, "  " .. cells_line(columns), theme.dim)
    list_top = list_top + 1
    list_height = list_height - 1
  end
  ui.list_height = math.max(1, list_height)
  ui.selected, ui.scroll = listwin.ensure(#rows, ui.selected, ui.scroll, ui.list_height)
  for i = 1, math.max(0, list_height) do
    local index = ui.scroll + i
    local row = list_top + i - 1
    local entry = rows[index]
    if not entry then
      blank(panel, row)
    else
      local marker = index == ui.selected and ">" or " "
      local text = textfit.fit(cells_line(entry.cells or {}), text_width, swidth)
      local attr = index == ui.selected and theme.title or theme.label
      write_at(row, panel.inner_col, marker, theme.marker)
      write_at(row, panel.inner_col + 2, text, attr)
      erase_tail(row, panel.inner_col + 2 + swidth(text), row_end(panel))
      add_hit(ui, "row", index, row, panel.inner_col, panel.inner_width)
    end
  end
  if detail_h > 0 then
    local detail_row = panel.inner_row + panel.inner_height - detail_h
    local selected = rows[ui.selected]
    local detail = selected and selected.detail or ""
    if #rows == 0 then
      detail = "Nothing to show."
    end
    local line_no = 0
    for line in (detail .. "\n"):gmatch("(.-)\n") do
      if line_no >= detail_h then
        break
      end
      paint_line(panel, detail_row + line_no, line, theme.muted)
      line_no = line_no + 1
    end
    while line_no < detail_h do
      blank(panel, detail_row + line_no)
      line_no = line_no + 1
    end
  end
  return rows
end

local function draw_namespaces(panel, session, ui)
  local query = "/" .. (ui.ns_query or "")
  if panel.inner_height > 0 then
    local label = "Namespace  "
    write_at(panel.inner_row, panel.inner_col, label, theme.title)
    write_marked(panel.inner_row, panel.inner_col + swidth(label), query, "/", theme.title)
    erase_tail(panel.inner_row, panel.inner_col + swidth(label) + swidth(query), row_end(panel))
  end
  local rows = row_source(session, ui)
  draw_rows(panel, session, ui, 1)
  if #rows == 0 and panel.inner_height > 2 then
    paint_line(panel, panel.inner_row + 2, "no namespaces", theme.dim)
  end
end

local function draw_section(panel, session, ui)
  local state = section_state(session, ui.section)
  local when = model.ago(state.summary and state.summary.fetched_at, os.time(), state.confirmed)
  local context = state.error or (state.summary and state.summary.context) or "not checked yet"
  local paint = fresh.paint(state)
  local count = state.summary and state.summary.count or "·"
  if ui.namespace and ui.namespace ~= "" then
    count = tostring(#row_source(session, ui))
  end
  local banner = section_label(ui.section) .. "  " .. count .. "  " .. context .. "  " .. when
  if panel.inner_height > 0 then
    paint_line(panel, panel.inner_row, banner, theme.pick(paint.context))
  end
  draw_rows(panel, session, ui, 1)
end

local function display_key(key)
  if type(key) == "string" and #key == 1 and key:match("%a") then
    return key:upper()
  end
  return tostring(key or "")
end

local function shortcut_items(session, ui)
  local items = {}
  local function add(key, text)
    items[#items + 1] = { key = key, text = text }
  end
  local function screen_keys()
    add("`", "refresh the screen")
    add("~", "reload all data")
  end
  local function parallel_keys()
    add("+", "more queries at once")
    add("-", "fewer queries at once")
  end
  if ui.filtering then
    add("Esc", "clear the filter")
    add("Enter", "keep the filter")
    add("Backspace", "delete a character")
    screen_keys()
    add("?", "close")
    return items
  end
  if ui.mode == "splash" then
    add("Enter", "continue")
    screen_keys()
    add("q", "quit")
    add("?", "close")
    return items
  end
  if ui.mode == "missing" then
    add("Enter", "quit")
    add("Esc", "quit")
    screen_keys()
    add("q", "quit")
    add("?", "close")
    return items
  end
  if ui.mode == "confirm" then
    add("y", "save kubeconfig")
    add("n", "cancel")
    add("Enter", "save kubeconfig")
    add("Esc", "cancel")
    screen_keys()
    add("?", "close")
    return items
  end
  if ui.mode == "menu" then
    for _, entry in ipairs(sessionlib.menu) do
      add(entry.key, entry.label)
    end
    for _, entry in ipairs(sessionlib.account_menu) do
      add(entry.key, entry.label)
    end
    add("Enter", "open")
    add("Up", "move")
    add("Down", "move")
    add("Left", "switch column")
    add("Right", "switch column")
    screen_keys()
    add("r", "recheck")
    add("/", "namespace")
    add("h", "history")
    parallel_keys()
    if session.cluster then
      add("k", "save kubeconfig")
    end
    add("Esc", "clusters")
    add("q", "quit")
    add("?", "close")
    return items
  end
  if ui.mode == "section" then
    if ui.section == "lint" then
      add("e", "errors")
      add("w", "warnings")
      add("g", "suggestions")
      add("Enter", "jump to the resource")
    end
    add("Up", "move")
    add("Down", "move")
    screen_keys()
    add("r", "recheck")
    add("/", "namespace")
    add("h", "history")
    parallel_keys()
    add("c", "clusters")
    if session.cluster then
      add("k", "save kubeconfig")
    end
    add("Esc", "back")
    add("q", "quit")
    add("?", "close")
    return items
  end
  if ui.mode == "theme" then
    add("Up", "move")
    add("Down", "move")
    add("Left", "previous color")
    add("Right", "next color")
    add("Enter", "next color")
    screen_keys()
    parallel_keys()
    add("/", "namespace")
    add("Esc", "back")
    add("q", "quit")
    add("?", "close")
    return items
  end
  if ui.mode == "namespaces" then
    add("Up", "move")
    add("Down", "move")
    add("Enter", "use this namespace")
    add("Backspace", "delete, or clear the filter")
    add("Esc", "back")
    add("?", "close")
    return items
  end
  if ui.mode == "clusters" then
    add("Enter", "open")
    add("Up", "move")
    add("Down", "move")
    screen_keys()
    add("r", "recheck")
    add("/", "namespace")
    add("h", "history")
    parallel_keys()
    add("Esc", "quit")
    add("q", "quit")
    add("?", "close")
    return items
  end
  if ui.mode == "log" then
    add("Up", "move")
    add("Down", "move")
    screen_keys()
    parallel_keys()
    add("/", "namespace")
    add("Esc", "back")
    add("q", "quit")
    add("?", "close")
    return items
  end
  add("?", "close")
  return items
end

local function paint_popup_row(row, left, total_w, left_ch, right_ch, fill)
  write_at(row, left, left_ch, theme.border)
  local col = left + 1
  local content_end = left + total_w - 1
  local next_col = fill(row, col, content_end)
  if next_col < content_end then
    write_at(row, next_col, string.rep(" ", content_end - next_col), theme.label)
  end
  write_at(row, content_end, right_ch, theme.border)
end

local function draw_popup(panel, session, ui)
  local items = shortcut_items(session, ui)
  if panel.inner_height < 3 or panel.inner_width < 12 or #items == 0 then
    return
  end
  local key_w = 1
  for _, item in ipairs(items) do
    key_w = math.max(key_w, swidth(display_key(item.key)))
  end
  -- The drawn row is a pad, the key column, a gap, and the label.
  local text_w = swidth("Shortcuts")
  for _, item in ipairs(items) do
    text_w = math.max(text_w, key_w + 2 + swidth(item.text))
  end
  local total_w = math.min(panel.inner_width, text_w + 4)
  if total_w < 8 then
    return
  end
  local max_body = panel.inner_height - 2
  local shown = items
  if #items > max_body then
    shown = {}
    local keep = math.max(0, max_body - 1)
    for i = 1, keep do
      shown[#shown + 1] = items[i]
    end
    shown[#shown + 1] = items[#items]
  end
  local total_h = #shown + 2
  local top = panel.inner_row + math.max(0, math.floor((panel.inner_height - total_h) / 2))
  local left = panel.inner_col + math.max(0, math.floor((panel.inner_width - total_w) / 2))
  paint_popup_row(top, left, total_w, "┌", "┐", function(row, col, content_end)
    local title = " Shortcuts "
    local room = content_end - col
    if swidth(title) >= room then
      title = textfit.fit(title, room, swidth)
      write_at(row, col, title, theme.title)
      return col + swidth(title)
    end
    local dashes = room - swidth(title)
    local left_n = math.floor(dashes / 2)
    write_at(row, col, string.rep("─", left_n), theme.border)
    write_at(row, col + left_n, title, theme.title)
    write_at(row, col + left_n + swidth(title), string.rep("─", dashes - left_n), theme.border)
    return content_end
  end)
  for i, item in ipairs(shown) do
    paint_popup_row(top + i, left, total_w, "│", "│", function(row, col, content_end)
      if col >= content_end then
        return col
      end
      write_at(row, col, " ", theme.label)
      col = col + 1
      local room = content_end - col
      local key_room = math.min(key_w, math.max(0, room))
      local key = textfit.pad(textfit.fit(display_key(item.key), key_room, swidth), key_room, swidth)
      write_at(row, col, key, theme.shortcut)
      col = col + swidth(key)
      if col < content_end - 1 then
        write_at(row, col, "  ", theme.label)
        col = col + 2
      end
      room = content_end - col - 1
      if room > 0 then
        local text = textfit.fit(item.text, room, swidth)
        write_at(row, col, text, theme.label)
        col = col + swidth(text)
      end
      return col
    end)
  end
  paint_popup_row(top + #shown + 1, left, total_w, "└", "┘", function(row, col, content_end)
    local dashes = content_end - col
    if dashes > 0 then
      write_at(row, col, string.rep("─", dashes), theme.border)
    end
    return content_end
  end)
end

local function draw_missing(panel, ui)
  local line = "Missing " .. table.concat(ui.missing or {}, ", ") .. ". Install them and start doksuela again."
  paint_line(panel, panel.inner_row, line, theme.error)
  for row = panel.inner_row + 1, panel.inner_row + panel.inner_height - 1 do
    blank(panel, row)
  end
end

local function draw_confirm(panel, session, ui)
  clear_panel(panel)
  local prompt = session:save_prompt()
  paint_line(panel, panel.inner_row, prompt, theme.title)
  if panel.inner_height >= 3 then
    local row = panel.inner_row + 2
    local yes = { fg = "white", bg = "green", brightness = "bright" }
    local yes_key = {}
    for key, value in pairs(theme.shortcut) do
      yes_key[key] = value
    end
    yes_key.bg = "green"
    yes_key.brightness = "bright"
    local no = { fg = "white", bg = "red", brightness = "bright" }
    local no_key = {}
    for key, value in pairs(theme.shortcut) do
      no_key[key] = value
    end
    no_key.bg = "red"
    no_key.brightness = "bright"
    write_at(row, panel.inner_col, " ", yes)
    write_at(row, panel.inner_col + 1, "Y", yes_key)
    write_at(row, panel.inner_col + 2, "es ", yes)
    write_at(row, panel.inner_col + 6, " ", no)
    write_at(row, panel.inner_col + 7, "N", no_key)
    write_at(row, panel.inner_col + 8, "o ", no)
    ui.yes_hit = { kind = "yes", row = row, col = panel.inner_col, width = 5 }
    ui.no_hit = { kind = "no", row = row, col = panel.inner_col + 6, width = 4 }
  end
end

local function draw_theme(panel, ui)
  local roles = theme.roles
  local top = 0
  if panel.inner_height > 1 then
    paint_line(panel, panel.inner_row, "Theme    Left and Right change the selected color", theme.title)
    top = 1
  end
  local list_height = math.max(1, panel.inner_height - top)
  local detail_h = 0
  if list_height > 6 then
    detail_h = 3
    list_height = list_height - detail_h
  end
  ui.list_height = list_height
  ui.selected, ui.scroll = listwin.ensure(#roles, ui.selected, ui.scroll, list_height)
  for i = 1, list_height do
    local index = ui.scroll + i
    local row = panel.inner_row + top + i - 1
    local role = roles[index]
    if not role or row >= panel.inner_row + panel.inner_height then
      blank(panel, row)
    else
      local marker = index == ui.selected and ">" or " "
      write_at(row, panel.inner_col, marker, theme.marker)
      local label = textfit.pad(textfit.fit(role.label, 12, swidth), 12, swidth)
      local label_attr = index == ui.selected and theme.title or theme.label
      write_at(row, panel.inner_col + 2, label, label_attr)
      local sample = " " .. role.sample .. " "
      local sample_col = panel.inner_col + 15
      local sample_attr = theme[role.id] or theme.label
      if role.as_bg then
        sample_attr = theme.bar_attr()
      end
      write_at(row, sample_col, sample, sample_attr)
      local name_col = sample_col + swidth(sample) + 1
      local name = theme.describe(theme[role.id])
      local room = math.max(0, row_end(panel) - name_col)
      local text = textfit.fit(name, room, swidth)
      write_at(row, name_col, text, theme.muted)
      erase_tail(row, name_col + swidth(text), row_end(panel))
      add_hit(ui, "row", index, row, panel.inner_col, panel.inner_width)
    end
  end
  if detail_h > 0 then
    local detail_row = panel.inner_row + panel.inner_height - detail_h
    local role = roles[ui.selected]
    local note = role and role.note or ""
    paint_line(panel, detail_row, note, theme.muted)
    for extra = 1, detail_h - 1 do
      blank(panel, detail_row + extra)
    end
  end
end

local function draw_body(panel, session, ui)
  ui.hits = {}
  ui.yes_hit = nil
  ui.no_hit = nil
  if ui.mode == "splash" then
    draw_splash(panel, ui)
  elseif ui.mode == "missing" then
    draw_missing(panel, ui)
  elseif ui.mode == "confirm" then
    draw_confirm(panel, session, ui)
  elseif ui.mode == "menu" then
    draw_menu(panel, session, ui)
  elseif ui.mode == "theme" then
    draw_theme(panel, ui)
  elseif ui.mode == "namespaces" then
    draw_namespaces(panel, session, ui)
  elseif ui.mode == "section" then
    draw_section(panel, session, ui)
  else
    draw_rows(panel, session, ui, 0)
  end
  if ui.popup then
    draw_popup(panel, session, ui)
  end
end

local function reset_list(ui)
  ui.selected = 1
  ui.scroll = 0
  ui.filter = ""
  ui.filtering = false
end

local function close_namespaces(ui, keep_place)
  ui.mode = ui.return_mode or "menu"
  ui.ns_query = ""
  if keep_place then
    ui.selected = ui.ns_selected or 1
    ui.scroll = ui.ns_scroll or 0
  end
end

local function open_entry(session, ui)
  if ui.mode == "namespaces" then
    local rows = row_source(session, ui)
    local row = rows[ui.selected]
    if row and row.name then
      ui.namespace = row.name
    end
    close_namespaces(ui, true)
    return
  end
  if ui.mode == "menu" then
    local entries = active_entries(session, ui)
    local entry = entries[ui.selected]
    if not entry then
      return
    end
    if entry.id == "clusters" then
      ui.mode = "clusters"
      reset_list(ui)
      session:refresh("clusters")
      return
    end
    if entry.id == "theme" then
      ui.mode = "theme"
      reset_list(ui)
      return
    end
    ui.section = entry.id
    ui.mode = "section"
    ui.lint_level = nil
    reset_list(ui)
    session:focus(entry.id)
    return
  end
  if ui.mode == "clusters" then
    local rows = row_source(session, ui)
    local row = rows[ui.selected]
    if not row then
      return
    end
    local cluster = session:find_cluster(row.id)
    if cluster then
      if not session.cluster or session.cluster.id ~= cluster.id then
        ui.namespace = nil
      end
      session:select_cluster(cluster)
      ui.mode = "menu"
      reset_list(ui)
    end
    return
  end
  if ui.mode == "section" and ui.section == "lint" then
    local rows = row_source(session, ui)
    local row = rows[ui.selected]
    if not row then
      return
    end
    local dest = model.jump_section(row.kind)
    if dest then
      ui.section = dest
      ui.mode = "section"
      ui.filter = row.name or ""
      ui.filtering = false
      ui.lint_level = nil
      ui.selected = 1
      ui.scroll = 0
      session:focus(dest)
    end
  end
end

local function go_back(ui)
  if ui.mode == "namespaces" then
    close_namespaces(ui, true)
    return true
  end
  if ui.filtering then
    ui.filtering = false
    ui.filter = ""
    return true
  end
  if ui.mode == "confirm" or ui.mode == "log" then
    ui.mode = ui.return_mode or "menu"
    return true
  end
  if ui.mode == "section" or ui.mode == "theme" then
    ui.mode = "menu"
    reset_list(ui)
    return true
  end
  if ui.mode == "clusters" or ui.mode == "menu" then
    ui.mode = "clusters"
    if ui.mode == "clusters" then
      return false
    end
  end
  return false
end

local function letter_of(keyname)
  if type(keyname) == "string" and #keyname == 1 and not keyname:find("%c") then
    return keyname:lower()
  end
  return nil
end

-- Terminals send DEL (\127) for Backspace. The keymap calls that ctrl_?.
local function is_backspace(keyname)
  return keyname == keys.backspace or keyname == "ctrl_?"
end

local function query_char(keyname)
  if type(keyname) == "string" and #keyname == 1 and keyname:match("[%w%-%.]") then
    return keyname:lower()
  end
  return nil
end

local function open_namespaces(session, ui)
  ui.ns_selected = ui.selected
  ui.ns_scroll = ui.scroll
  ui.return_mode = ui.mode
  ui.mode = "namespaces"
  ui.ns_query = ""
  ui.scroll = 0
  ui.selected = 1
  if ui.namespace and ui.namespace ~= "" then
    local rows = row_source(session, ui)
    for index, row in ipairs(rows) do
      if row.name == ui.namespace then
        ui.selected = index
        break
      end
    end
  end
end

local function open_history(ui)
  if ui.mode == "log" or ui.mode == "splash" or ui.mode == "missing" or ui.mode == "confirm" then
    return false
  end
  ui.return_mode = ui.mode
  ui.mode = "log"
  reset_list(ui)
  return true
end

local function open_menu_letter(session, ui, letter)
  for index, entry in ipairs(menu_entries(session)) do
    if entry.key == letter then
      focus_side(ui, "cluster", index)
      open_entry(session, ui)
      return true
    end
  end
  for index, entry in ipairs(account_entries(session)) do
    if entry.key == letter then
      focus_side(ui, "account", index)
      open_entry(session, ui)
      return true
    end
  end
  return false
end

local function activate_key(session, ui, keyname)
  if ui.popup then
    if keyname == keys.ctrl_c then
      return "quit"
    end
    if keyname == "?" or keyname == keys.escape then
      ui.popup = false
    end
    return nil
  end
  if keyname == "?" then
    ui.popup = true
    return nil
  end
  if keyname == "`" then
    return "refresh_screen"
  end
  if keyname == "~" then
    if ui.mode ~= "missing" then
      session:reload()
    end
    return nil
  end
  local letter = letter_of(keyname)
  if keyname == keys.ctrl_c or (letter == "q" and ui.mode ~= "namespaces") then
    return "quit"
  end
  if ui.mode == "missing" then
    if keyname == keys.enter or keyname == keys.cr or keyname == keys.escape then
      return "quit"
    end
    return nil
  end
  if ui.mode == "splash" then
    if keyname == keys.enter or keyname == keys.cr then
      return "leave_splash"
    end
    if keyname == keys.escape then
      return "quit"
    end
    return nil
  end
  if ui.mode == "confirm" then
    if letter == "y" or keyname == keys.enter or keyname == keys.cr then
      session:confirm_save()
      ui.mode = ui.return_mode or "menu"
    elseif letter == "n" or keyname == keys.escape then
      ui.mode = ui.return_mode or "menu"
    end
    return nil
  end
  if ui.mode == "namespaces" then
    if keyname == keys.escape then
      close_namespaces(ui, true)
      return nil
    end
    if keyname == keys.enter or keyname == keys.cr then
      open_entry(session, ui)
      return nil
    end
    if is_backspace(keyname) then
      if ui.ns_query and ui.ns_query ~= "" then
        ui.ns_query = ui.ns_query:sub(1, -2)
        ui.selected = 1
        ui.scroll = 0
      else
        ui.namespace = nil
        close_namespaces(ui, true)
      end
      return nil
    end
    local typed = query_char(keyname)
    if typed then
      ui.ns_query = (ui.ns_query or "") .. typed
      ui.selected = 1
      ui.scroll = 0
      return nil
    end
    if keyname ~= keys.up and keyname ~= keys.down and keyname ~= keys.pageup and keyname ~= keys.pagedown then
      return nil
    end
  end
  if ui.filtering then
    if keyname == keys.escape then
      ui.filtering = false
      ui.filter = ""
    elseif keyname == keys.enter or keyname == keys.cr then
      ui.filtering = false
    elseif is_backspace(keyname) then
      ui.filter = ui.filter:sub(1, -2)
    elseif letter then
      ui.filter = ui.filter .. keyname
    end
    return nil
  end
  if ui.mode ~= "confirm" then
    local direction = nil
    if keyname == "+" or keyname == "=" then
      direction = 1
    elseif keyname == "-" then
      direction = -1
    end
    if direction then
      session:bump_parallel(direction)
      return nil
    end
  end
  if keyname == keys.escape then
    if ui.mode == "menu" then
      ui.mode = "clusters"
      reset_list(ui)
    elseif ui.mode == "clusters" then
      return "quit"
    else
      go_back(ui)
    end
    return nil
  end
  if ui.mode == "theme" and (keyname == keys.left or keyname == keys.right or keyname == keys.enter or keyname == keys.cr) then
    local role = theme.roles[ui.selected]
    if role then
      local direction = keyname == keys.left and -1 or 1
      theme.cycle(role.id, direction)
      if session.cache and session.cache.root then
        cache.write_json(session.cache.root .. "/theme.json", theme.export())
      end
    end
    return nil
  end
  if keyname == keys.enter or keyname == keys.cr then
    open_entry(session, ui)
    return nil
  end
  if ui.mode == "menu" and (keyname == keys.left or keyname == keys.right) then
    focus_side(ui, keyname == keys.left and "cluster" or "account")
    return nil
  end
  if ui.mode == "menu" and letter and open_menu_letter(session, ui, letter) then
    return nil
  end
  local rows = {}
  if ui.mode == "menu" then
    rows = active_entries(session, ui)
  elseif ui.mode == "theme" then
    rows = theme.roles
  else
    rows = row_source(session, ui)
  end
  local height = ui.list_height or 10
  if keyname == keys.up then
    ui.selected = ui.selected - 1
  elseif keyname == keys.down then
    ui.selected = ui.selected + 1
  elseif keyname == keys.pageup then
    ui.selected, ui.scroll = listwin.page(#rows, ui.selected, ui.scroll, height, -1)
    return nil
  elseif keyname == keys.pagedown then
    ui.selected, ui.scroll = listwin.page(#rows, ui.selected, ui.scroll, height, 1)
    return nil
  elseif letter == "r" then
    if ui.mode == "section" then
      session:refresh(ui.section)
    elseif ui.mode == "menu" then
      local entries = active_entries(session, ui)
      local entry = entries[ui.selected]
      if entry then
        session:refresh(entry.id)
      end
    elseif ui.mode == "clusters" then
      session:refresh("clusters")
    end
  elseif letter == "h" then
    open_history(ui)
  elseif letter == "c" and ui.mode ~= "clusters" then
    ui.mode = "clusters"
    reset_list(ui)
  elseif letter == "k" and session.cluster then
    ui.return_mode = ui.mode
    ui.mode = "confirm"
  elseif keyname == "/" then
    open_namespaces(session, ui)
  elseif ui.mode == "section" and ui.section == "lint" then
    if letter == "e" then
      ui.lint_level = ui.lint_level == "error" and nil or "error"
    elseif letter == "w" then
      ui.lint_level = ui.lint_level == "warning" and nil or "warning"
    elseif letter == "g" then
      ui.lint_level = ui.lint_level == "suggestion" and nil or "suggestion"
    end
  end
  if keyname == keys.up or keyname == keys.down then
    ui.selected, ui.scroll = listwin.ensure(#rows, ui.selected, ui.scroll, math.max(1, #rows))
  end
  return nil
end

local function leave_splash(session, ui)
  if ui.missing then
    ui.mode = "missing"
    return
  end
  session:boot()
  if session.cluster then
    ui.mode = "menu"
  else
    ui.mode = "clusters"
  end
  reset_list(ui)
end

local function on_mouse(session, ui, event)
  if ui.popup then
    if event.press then
      ui.popup = false
      return true
    end
    return false
  end
  if event.press and event.left and mouse.hit(ui.refresh_hit, event.row, event.col) then
    ui.force_clear = true
    return true
  end
  if event.press and event.left and mouse.hit(ui.parallel_hit, event.row, event.col) then
    session:bump_parallel(1)
    return true
  end
  if ui.mode == "splash" and mouse.hit(ui.splash_hit, event.row, event.col) then
    if event.motion and not ui.splash_hover then
      ui.splash_hover = true
      return true
    end
    if event.press and event.left then
      leave_splash(session, ui)
      return true
    end
  elseif ui.mode == "splash" and event.motion and ui.splash_hover then
    ui.splash_hover = false
    return true
  end
  if event.motion then
    local box = mouse.find(ui.hits, event.row, event.col)
    if box and box.index then
      if box.side and box.side ~= ui.side then
        focus_side(ui, box.side, box.index)
        return true
      end
      if box.index ~= ui.selected then
        ui.selected = box.index
        if box.side then
          ui.hold[box.side] = box.index
        end
        return true
      end
    end
  end
  if event.press and event.left then
    if mouse.hit(ui.footer_hit, event.row, event.col) and open_history(ui) then
      return true
    end
    if ui.mode == "confirm" then
      if mouse.hit(ui.yes_hit, event.row, event.col) then
        session:confirm_save()
        ui.mode = ui.return_mode or "menu"
        return true
      end
      if mouse.hit(ui.no_hit, event.row, event.col) then
        ui.mode = ui.return_mode or "menu"
        return true
      end
    end
    local box = mouse.find(ui.hits, event.row, event.col)
    if box and box.index then
      if box.side then
        focus_side(ui, box.side, box.index)
      else
        ui.selected = box.index
      end
      open_entry(session, ui)
      return true
    end
  end
  if event.wheel_up or event.wheel_down then
    if ui.mode == "menu" then
      local box = mouse.find(ui.hits, event.row, event.col)
      if box and box.side then
        focus_side(ui, box.side)
      end
    end
    local rows
    if ui.mode == "menu" then
      rows = active_entries(session, ui)
    elseif ui.mode == "theme" then
      rows = theme.roles
    else
      rows = row_source(session, ui)
    end
    local direction = event.wheel_up and -1 or 1
    ui.selected = ui.selected + direction
    ui.selected, ui.scroll = listwin.ensure(#rows, ui.selected, ui.scroll, math.max(1, #rows))
    if ui.mode == "menu" and ui.side then
      ui.hold[ui.side] = ui.selected
      ui.hold_scroll[ui.side] = ui.scroll
    end
    return true
  end
  return false
end

function M.run(opts)
  opts = opts or {}
  local session = sessionlib.new(opts)
  if session.cache and session.cache.root then
    theme.load(cache.read_json(session.cache.root .. "/theme.json"))
  end
  local ui = ui_new()
  if not opts.fixture then
    local missing = bincheck.missing({ "doctl", "kubectl", "clusterlint" })
    if #missing > 0 then
      ui.missing = missing
    end
  end

  t.cursor.visible.push(false)
  set_mouse(true)

  local header = Panel {
    name = "header",
    min_height = 2,
    max_height = 2,
    clear_content = false,
    content = function(self)
      ui.refresh_hit = nil
      if ui.mode == "splash" or ui.mode == "missing" then
        clear_panel(self)
        return
      end
      draw_header(self, session, ui)
    end,
  }
  local body = Panel {
    name = "body",
    clear_content = false,
    border = {
      format = t.draw.box_fmt.single,
      attr = theme.border,
      title = BORDER_TITLE,
    },
    content = function(self)
      draw_body(self, session, ui)
    end,
  }
  local footer = Panel {
    name = "footer",
    min_height = 1,
    max_height = 1,
    clear_content = false,
    content = function(self)
      if ui.mode == "splash" or ui.mode == "missing" then
        clear_panel(self)
        return
      end
      draw_footer(self, session, ui)
    end,
  }
  local screen = Screen {
    header = header,
    body = body,
    footer = footer,
    name = "doksuela",
  }

  local function render()
    t.output.write(SYNC_ON)
    if ui.force_clear then
      ui.force_clear = false
      t.output.write("\27[2J\27[H")
      t.output.write(MOUSE_ON)
    end
    screen:calculate_layout()
    screen:render()
    t.output.write(SYNC_OFF)
    t.output.flush()
  end

  local function finish()
    set_mouse(false)
    t.cursor.visible.pop()
  end

  local ok, err = pcall(function()
    render()
    while true do
      local raw, keytype = t.input.readansi(0.15)
      local changed = false
      if ui.mode ~= "splash" and ui.mode ~= "missing" then
        changed = session:tick()
        if session.cluster == nil and ui.mode == "menu" then
          ui.mode = "clusters"
          changed = true
        end
      end
      local action
      if raw ~= nil then
        local keyname = key_map[raw]
        local event = keytype == "ansi" and mouse.parse(raw) or nil
        if event then
          if on_mouse(session, ui, event) then
            changed = true
          end
        elseif keyname then
          action = activate_key(session, ui, keyname)
          changed = true
        elseif type(raw) == "string" and not raw:find("%c") then
          action = activate_key(session, ui, raw)
          changed = true
        end
        if action == "quit" then
          break
        end
        if action == "leave_splash" then
          leave_splash(session, ui)
          changed = true
        end
        if action == "refresh_screen" then
          ui.force_clear = true
          changed = true
        end
      end
      local resized = screen:check_resize(false)
      if resized then
        local height, width_now = t.size()
        screen._last_height = height
        screen._last_width = width_now
      end
      if changed or resized then
        render()
      end
    end
  end)

  finish()
  if not ok then
    error(err, 0)
  end
end

return M
