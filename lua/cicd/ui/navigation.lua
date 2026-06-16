local M = {}

local state_mod = require("cicd.state")
local stages_mod = require("cicd.ui.stages")
local render_mod = require("cicd.ui.render")

---Cursor ± direction. Lightweight: just moves the cursor, no re-render.
---Wraps at ends of the current stage's filtered job list.
---@param direction integer
function M.move_cursor(direction)
  local state = state_mod.state
  local current_jobs = stages_mod.get_current_stage_jobs(state)
  if #current_jobs == 0 then return end

  state.cursor_line = state.cursor_line + direction
  if state.cursor_line < 1 then
    state.cursor_line = #current_jobs
  elseif state.cursor_line > #current_jobs then
    state.cursor_line = 1
  end

  if state.win and vim.api.nvim_win_is_valid(state.win) then
    local target_line = (state.header_end or 0) + state.cursor_line
    local total_lines = vim.api.nvim_buf_line_count(state.buf)
    if target_line <= total_lines then
      vim.api.nvim_win_set_cursor(state.win, { target_line, 0 })
    end
  end
end

---Switches stage ± direction. Resets cursor to the first job and re-renders.
---@param direction integer
function M.move_stage(direction)
  local state = state_mod.state
  if #state.stages == 0 then return end

  state.current_stage_idx = state.current_stage_idx + direction
  if state.current_stage_idx < 1 then
    state.current_stage_idx = #state.stages
  elseif state.current_stage_idx > #state.stages then
    state.current_stage_idx = 1
  end

  state.cursor_line = 1
  render_mod.render()
end

function M.jump_first()
  local state = state_mod.state
  local current_jobs = stages_mod.get_current_stage_jobs(state)
  if #current_jobs == 0 then return end
  state.cursor_line = 1
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_set_cursor(state.win, { (state.header_end or 0) + 1, 0 })
  end
end

function M.jump_last()
  local state = state_mod.state
  local current_jobs = stages_mod.get_current_stage_jobs(state)
  if #current_jobs == 0 then return end
  state.cursor_line = #current_jobs
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_set_cursor(state.win, { (state.header_end or 0) + state.cursor_line, 0 })
  end
end

return M
