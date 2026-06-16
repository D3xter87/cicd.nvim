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

local function aggregate_stage(stage_jobs)
  local has_failed, has_running, has_manual, all_success = false, false, false, true
  for _, job in ipairs(stage_jobs) do
    if job.status == "failed" then has_failed = true; all_success = false end
    if job.status == "running" then has_running = true; all_success = false end
    if job.status == "manual" then has_manual = true; all_success = false end
    if job.status ~= "success" and job.status ~= "passed" then all_success = false end
  end
  if has_failed then return " ", "DiagnosticError" end
  if has_running then return " ", "DiagnosticInfo" end
  if all_success and #stage_jobs > 0 then return " ", "DiagnosticOk" end
  if has_manual then return " ", "DiagnosticHint" end
  return " ", "Comment"
end

function M.render()
  local state = state_mod.state
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end

  vim.api.nvim_set_option_value("modifiable", true, { buf = state.buf })

  local terms = terms_for(state.provider_name)
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
      if pos.selected then
        table.insert(highlights, {
          line = stage_line_num, col_start = pos.start, col_end = pos.finish, hl_group = "PmenuSel",
        })
      end
      table.insert(highlights, {
        line = stage_line_num, col_start = pos.start + 1, col_end = pos.start + 4, hl_group = pos.hl,
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
  table.insert(lines, string.rep("─", 78))
  table.insert(lines, "")

  local current_stage = state.stages[state.current_stage_idx] or "N/A"
  table.insert(lines, string.format("  %s: %s", terms.section, current_stage))
  table.insert(lines, "")

  table.insert(lines, string.format("  %-3s %-45s %-12s %s", "", "JOB", "STATUS", "DURATION"))
  table.insert(lines, string.rep("─", 78))

  local header_end = #lines
  state.header_end = header_end

  local current_jobs = stages_mod.get_current_stage_jobs(state)

  if #current_jobs == 0 then
    table.insert(lines, "")
    table.insert(lines, "  " .. terms.no_jobs)
    if state.filter_text ~= "" then
      table.insert(lines, "  Try a different filter or press Esc to clear")
    end
  else
    for i, job in ipairs(current_jobs) do
      local icon = STATUS_ICONS[job.status] or "? "
      local name = job.name or "unknown"
      local status = job.status or ""
      local duration = job.duration and string.format("%.1fs", job.duration) or "-"

      if #name > 43 then
        name = name:sub(1, 40) .. "..."
      end

      local line = string.format("  %s %-45s %-12s %s", icon, name, status, duration)
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
