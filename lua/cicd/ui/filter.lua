local M = {}

local state_mod = require("cicd.state")
local render_mod = require("cicd.ui.render")

local function rebuild_filtered()
  local state = state_mod.state
  if state.filter_text == "" then
    state.filtered_jobs = state.jobs
    return
  end
  state.filtered_jobs = {}
  local pattern = state.filter_text:lower()
  for _, job in ipairs(state.jobs) do
    local searchable = string.lower(
      (job.name or "") .. " " .. (job.stage or "") .. " " .. (job.status or "")
    )
    if searchable:find(pattern, 1, true) then
      table.insert(state.filtered_jobs, job)
    end
  end
end

---Re-applies the filter and re-renders. Pass true to also reset cursor_line.
---@param reset_cursor boolean|nil
function M.apply(reset_cursor)
  local state = state_mod.state
  rebuild_filtered()
  if reset_cursor then
    state.cursor_line = 1
  end
  render_mod.render()
end

function M.start()
  local state = state_mod.state
  state.filter_mode = true
  state.filter_text = ""
  render_mod.render()
end

function M.exit()
  local state = state_mod.state
  state.filter_mode = false
  if state.filter_text == "" then
    state.filtered_jobs = state.jobs
  end
  render_mod.render()
end

function M.clear()
  local state = state_mod.state
  state.filter_mode = false
  state.filter_text = ""
  state.filtered_jobs = state.jobs
  state.cursor_line = 1
  render_mod.render()
end

return M
