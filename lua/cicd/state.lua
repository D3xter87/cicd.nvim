local M = {}

M.state = {
  buf = nil,
  win = nil,
  jobs = {},
  filtered_jobs = {},
  stages = {},
  current_stage_idx = 1,
  jobs_by_stage = {},
  cursor_line = 1,
  filter_text = "",
  filter_mode = false,
  header_end = 0,
  branch = "",
  provider_name = "",
  -- Resolved target reference. kind = "branch" | "sha".
  -- value is the branch name or full 40-char SHA; short is the 7-char SHA
  -- (only set when kind == "sha"). Populated by controller.open.
  ref = nil,
  -- True after the controller has already substituted a branch fallback for a
  -- SHA target that returned no pipeline. Prevents pingponging the refresh.
  fallback_attempted = false,
}

function M.reset()
  M.state.buf = nil
  M.state.win = nil
  M.state.jobs = {}
  M.state.filtered_jobs = {}
  M.state.stages = {}
  M.state.current_stage_idx = 1
  M.state.jobs_by_stage = {}
  M.state.cursor_line = 1
  M.state.filter_text = ""
  M.state.filter_mode = false
  M.state.header_end = 0
  M.state.branch = ""
  M.state.provider_name = ""
  M.state.ref = nil
  M.state.fallback_attempted = false
end

return M
