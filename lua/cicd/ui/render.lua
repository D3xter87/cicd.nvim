-- Renders the pipeline browser contents into the floating buffer.
-- Writes back `state.header_end` (the number of lines before the first job
-- row) so navigation can compute cursor targets without hardcoding offsets.

local M = {}

local state_mod = require("cicd.state")
local stages_mod = require("cicd.ui.stages")

local STATUS_ICONS = {
  success = " ",
  passed = " ",
  failed = " ",
  running = " ",
  pending = " ",
  canceled = " ",
  cancelled = " ",
  skipped = " ",
  manual = " ",
  created = " ",
}

local STATUS_HL = {
  success = "DiagnosticOk",
  passed = "DiagnosticOk",
  failed = "DiagnosticError",
  running = "DiagnosticInfo",
  pending = "DiagnosticWarn",
  canceled = "Comment",
  cancelled = "Comment",
  skipped = "Comment",
  manual = "Comment",
  created = "Comment",
}

local NS_ID = vim.api.nvim_create_namespace("cicd")

-- Column geometry for the job table. The JOB column flexes to fill whatever
-- width the window has; everything else is fixed. Header and rows are built
-- through the same `row()` builder so values always line up under headers.
local LEFT_MARGIN = 2
local ICON_W = 2
local STATUS_W = 10
local DUR_W = 10
-- Width of everything except the flexible name column (margin + icon + the
-- three single-space gaps + status + duration).
local FIXED_COLS = LEFT_MARGIN + ICON_W + 1 + 1 + STATUS_W + 1 + DUR_W

-- Inner (text-area) width of the float, queried live so the layout follows
-- the window even after a resize. Falls back to the open-time sizing formula.
local function inner_width(state)
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    return vim.api.nvim_win_get_width(state.win)
  end
  return math.floor(vim.o.columns * 0.8)
end

-- Pad `s` with trailing spaces to a target *display* width (handles icons and
-- multi-byte names, unlike string.format's byte-based widths).
local function pad(s, width)
  local d = vim.fn.strdisplaywidth(s)
  if d >= width then return s end
  return s .. string.rep(" ", width - d)
end

-- Truncate `s` (by display width) to fit `width`, appending ".." when cut.
local function truncate(s, width)
  if vim.fn.strdisplaywidth(s) <= width then return s end
  while #s > 0 and vim.fn.strdisplaywidth(s) > width - 2 do
    s = s:sub(1, #s - 1)
  end
  return s .. ".."
end

-- Format a duration (in seconds) using the largest sensible unit:
--   < 60s   -> "Xs"      (e.g. "12s", rounded to whole seconds)
--   < 1h    -> "Xm Ys"   (e.g. "1m 5s")
--   >= 1h   -> "Xh Ym"   (e.g. "2h 15m")
local function format_duration(seconds)
  if not seconds then
    return "-"
  end
  if seconds < 60 then
    return string.format("%ds", math.floor(seconds + 0.5))
  end
  if seconds < 3600 then
    local mins = math.floor(seconds / 60)
    local secs = math.floor(seconds % 60)
    return string.format("%dm %ds", mins, secs)
  end
  local hours = math.floor(seconds / 3600)
  local mins = math.floor((seconds % 3600) / 60)
  return string.format("%dh %dm", hours, mins)
end

-- Per-provider UI terminology so users see the language they expect
-- (GitLab calls them "stages", GitHub calls them "workflows").
local TERMS = {
  gitlab = {
    section = "Stage",      no_section = "No stages found",
    no_jobs  = "No jobs in this stage",
  },
  github = {
    section = "Workflow",   no_section = "No workflows found",
    no_jobs  = "No jobs in this workflow",
  },
}

local function terms_for(provider_name)
  return TERMS[provider_name] or TERMS.gitlab
end

-- Aggregate a stage's color from its jobs' statuses. Priority (highest first):
-- any failed -> red, any running -> in-progress, any pending -> pending,
-- any active job succeeded -> green. A stage where nothing has been activated
-- (only manual/created/skipped/canceled, or no jobs) stays white ("Normal").
local function aggregate_stage(stage_jobs)
  local has_failed, has_running, has_pending, has_success = false, false, false, false
  for _, job in ipairs(stage_jobs) do
    local s = job.status
    if s == "failed" then has_failed = true
    elseif s == "running" then has_running = true
    elseif s == "pending" then has_pending = true
    elseif s == "success" or s == "passed" then has_success = true end
  end
  if has_failed then return " ", "DiagnosticError" end
  if has_running then return " ", "DiagnosticInfo" end
  if has_pending then return " ", "DiagnosticWarn" end
  if has_success then return " ", "DiagnosticOk" end
  return " ", "Normal"
end

-- Combines the PmenuSel background (the selection indicator) with a status
-- foreground so the selected stage keeps its highlight *and* shows its color.
-- Rebuilt each render so it follows colorscheme changes. For "Normal" the
-- foreground is nil, leaving the default (white) text on the selection bg.
local function selected_stage_hl(status_hl)
  local name = "CicdStageSel_" .. status_hl
  local sel = vim.api.nvim_get_hl(0, { name = "PmenuSel" })
  local fg = vim.api.nvim_get_hl(0, { name = status_hl })
  vim.api.nvim_set_hl(0, name, { bg = sel.bg, fg = fg.fg, bold = true })
  return name
end

function M.render()
  local state = state_mod.state
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end

  vim.api.nvim_set_option_value("modifiable", true, { buf = state.buf })

  local terms = terms_for(state.provider_name)
  local width = inner_width(state)
  local current_jobs = stages_mod.get_current_stage_jobs(state)

  -- Size the JOB column to the longest visible name (plus a small gap) so the
  -- STATUS/DURATION columns sit just to its right rather than being pushed to
  -- the far edge. Capped at the available width so a very long name can't
  -- overflow (truncate() trims names past the cap).
  local longest = vim.fn.strdisplaywidth("JOB")
  for _, job in ipairs(current_jobs) do
    longest = math.max(longest, vim.fn.strdisplaywidth(job.name or "unknown"))
  end
  local name_w = math.min(width - FIXED_COLS, math.max(12, longest + 2))

  -- Single source of truth for the table's column layout: used for both the
  -- header and every job row so the values stay aligned under their headers.
  local function row(icon, name, status, duration)
    return string.rep(" ", LEFT_MARGIN)
      .. pad(icon, ICON_W) .. " "
      .. pad(name, name_w) .. " "
      .. pad(status, STATUS_W) .. " "
      .. duration
  end

  local lines = {}
  local highlights = {}

  table.insert(lines, "")
  table.insert(lines, string.format("  %s", state.branch or ""))
  table.insert(lines, "")

  if #state.stages > 0 then
    local stage_line = "  "
    local stage_positions = {}
    for i, stage in ipairs(state.stages) do
      local start_pos = #stage_line
      local stage_jobs = state.jobs_by_stage[stage] or {}
      local job_count = #stage_jobs
      local stage_icon, stage_hl = aggregate_stage(stage_jobs)

      local display_stage = stage
      if #display_stage > 12 then
        display_stage = display_stage:sub(1, 10) .. ".."
      end

      if i == state.current_stage_idx then
        stage_line = stage_line .. string.format("[%s%s (%d)]", stage_icon, display_stage, job_count)
      else
        stage_line = stage_line .. string.format(" %s%s (%d) ", stage_icon, display_stage, job_count)
      end

      local end_pos = #stage_line
      table.insert(stage_positions, {
        start = start_pos, finish = end_pos, hl = stage_hl, selected = i == state.current_stage_idx,
      })

      if i < #state.stages then
        stage_line = stage_line .. " → "
      end
    end
    table.insert(lines, stage_line)

    local stage_line_num = #lines
    for _, pos in ipairs(stage_positions) do
      local hl = pos.selected and selected_stage_hl(pos.hl) or pos.hl
      table.insert(highlights, {
        line = stage_line_num, col_start = pos.start, col_end = pos.finish, hl_group = hl,
      })
    end
  else
    table.insert(lines, "  " .. terms.no_section)
  end

  table.insert(lines, "")

  if state.filter_mode then
    table.insert(lines, string.format("  / %s█", state.filter_text))
  elseif state.filter_text ~= "" then
    table.insert(lines, string.format("  Filter: %s (press Esc to clear)", state.filter_text))
  else
    table.insert(lines, "")
  end
  table.insert(lines, string.rep("─", width))
  table.insert(lines, "")

  local current_stage = state.stages[state.current_stage_idx] or "N/A"
  table.insert(lines, string.format("  %s: %s", terms.section, current_stage))
  table.insert(lines, "")

  table.insert(lines, row("", "JOB", "STATUS", "DURATION"))
  table.insert(lines, string.rep("─", width))

  local header_end = #lines
  state.header_end = header_end

  if #current_jobs == 0 then
    table.insert(lines, "")
    table.insert(lines, "  " .. terms.no_jobs)
    if state.filter_text ~= "" then
      table.insert(lines, "  Try a different filter or press Esc to clear")
    end
  else
    for i, job in ipairs(current_jobs) do
      local icon = STATUS_ICONS[job.status] or "? "
      local name = truncate(job.name or "unknown", name_w)
      local status = job.status or ""
      local duration = format_duration(job.duration)

      local line = row(icon, name, status, duration)
      table.insert(lines, line)

      local hl_group = STATUS_HL[job.status] or "Normal"
      table.insert(highlights, {
        line = header_end + i, col_start = 2, col_end = #line, hl_group = hl_group,
      })
    end
  end

  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(state.buf, NS_ID, 0, -1)
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(state.buf, NS_ID, hl.hl_group, hl.line - 1, hl.col_start, hl.col_end)
  end

  vim.api.nvim_set_option_value("modifiable", false, { buf = state.buf })

  if #current_jobs > 0 and state.win and vim.api.nvim_win_is_valid(state.win) then
    if state.cursor_line > #current_jobs then state.cursor_line = #current_jobs end
    if state.cursor_line < 1 then state.cursor_line = 1 end
    local target_line = header_end + state.cursor_line
    local total_lines = vim.api.nvim_buf_line_count(state.buf)
    if target_line <= total_lines then
      vim.api.nvim_win_set_cursor(state.win, { target_line, 0 })
    end
  end
end

return M
