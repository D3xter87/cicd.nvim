-- Controller: orchestrates provider ↔ UI ↔ monitor.
--
-- Responsibilities:
--   * open(): detect git remote → choose provider → build remote ctx → open
--             window, wire keymaps, fetch initial pipeline.
--   * refresh_pipeline(): pull the current pipeline through the provider,
--             update state, re-render, toggle auto-refresh.
--   * trigger_selected_job / trigger_all_stage_jobs: run_action via provider
--             then hand off to monitor for status notifications.

local M = {}

local state_mod = require("cicd.state")
local config_mod = require("cicd.config")
local stages_mod = require("cicd.ui.stages")
local filter_mod = require("cicd.ui.filter")
local window_mod = require("cicd.ui.window")
local keymaps_mod = require("cicd.ui.keymaps")
local providers = require("cicd.providers")
local git_remote = require("cicd.http.git_remote")
local git_util = require("cicd.util.git")
local monitor = require("cicd.monitor")
local browser = require("cicd.util.browser")
local logview = require("cicd.ui.logview")

---@class CicdRef
---@field kind "branch"|"tag"|"sha"
---@field value string  full SHA for kind="sha", ref name otherwise
---@field short string|nil  7-char SHA for kind="sha"

---@class CicdCtx
---@field provider table
---@field remote table
---@field ref CicdRef
---@type CicdCtx|nil
local ctx = nil  -- current open-session context

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "CI/CD" })
end

monitor.set_notifier(notify)

local function has_running_jobs()
  for _, job in ipairs(state_mod.state.jobs) do
    if job.status == "running" or job.status == "pending" then return true end
  end
  return false
end

local function build_fetch_fn()
  return function(cb)
    if not ctx then return cb(nil, "no session") end
    ctx.provider.fetch_current_pipeline(ctx.remote, ctx.ref, function(pipeline, err)
      cb(pipeline, err)
    end)
  end
end

---Switches `ctx`/`state` from a SHA target to its branch-HEAD fallback. Called
---once per session, when a SHA ref yields no pipeline. Updates the header
---label so the UI reflects that the user is looking at the branch latest,
---not the originally-requested commit.
local function apply_branch_fallback()
  local state = state_mod.state
  if not ctx or state.fallback_attempted then return false end
  state.fallback_attempted = true

  local branch = git_util.current_branch()
  if branch == "" then return false end

  local original_short = state.ref and state.ref.short
  ctx.ref = { kind = "branch", value = branch }
  state.ref = ctx.ref
  if original_short then
    state.branch = string.format("branch: %s (no pipeline for %s)", branch, original_short)
  else
    state.branch = "branch: " .. branch
  end
  notify("no pipeline for commit — showing branch '" .. branch .. "' latest", vim.log.levels.DEBUG)
  return true
end

function M.refresh_pipeline()
  local state = state_mod.state
  if not ctx or not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end

  ctx.provider.fetch_current_pipeline(ctx.remote, ctx.ref, function(pipeline, err)
    if err then
      notify("" .. err, vim.log.levels.ERROR)
      monitor.stop_auto_refresh()
      return
    end
    if not pipeline then return end

    -- SHA targets with no matching pipeline: fall back to branch HEAD once.
    if ctx.ref.kind == "sha"
        and (not pipeline.jobs or #pipeline.jobs == 0)
        and not state.fallback_attempted then
      if apply_branch_fallback() then
        return M.refresh_pipeline()
      end
    end

    local saved_stage_idx = state.current_stage_idx
    local saved_cursor_line = state.cursor_line

    state.jobs = pipeline.jobs or {}
    state.pipeline_web_url = pipeline.web_url
    state.jobs_by_stage = stages_mod.group_by_stage(state.jobs)
    state.stages = stages_mod.order_by_dependencies(state.jobs)

    if saved_stage_idx <= #state.stages then
      state.current_stage_idx = saved_stage_idx
    else
      state.current_stage_idx = 1
    end

    local current_jobs = stages_mod.get_current_stage_jobs(state)
    if saved_cursor_line <= #current_jobs then
      state.cursor_line = saved_cursor_line
    else
      state.cursor_line = math.max(1, #current_jobs)
    end

    filter_mod.apply(false)

    if has_running_jobs() then
      monitor.start_auto_refresh(function()
        local st = state_mod.state
        if not st.buf or not vim.api.nvim_buf_is_valid(st.buf) then
          monitor.stop_auto_refresh()
          return
        end
        if st.filter_mode then return end
        M.refresh_pipeline()
      end)
    else
      monitor.stop_auto_refresh()
    end
  end)
end

local function trigger_selected_job()
  local state = state_mod.state
  if not ctx then return end
  local current_jobs = stages_mod.get_current_stage_jobs(state)
  if #current_jobs == 0 then return end
  local job = current_jobs[state.cursor_line]
  if not job or not job.id then return end

  ctx.provider.run_action(ctx.remote, job, function(ok, err)
    if not ok then
      notify((err or "action failed"), vim.log.levels.ERROR)
      return
    end
    monitor.start_single(job.name, build_fetch_fn(), function()
      if state_mod.state.buf and vim.api.nvim_buf_is_valid(state_mod.state.buf) then
        M.refresh_pipeline()
      end
    end)
    vim.defer_fn(function() M.refresh_pipeline() end, 1000)
  end)
end

local function open_url(url)
  if browser.open(url) then
    notify("opened " .. url)
  else
    notify("could not open browser — copy URL manually: " .. url, vim.log.levels.WARN)
  end
end

---'o' — open the selected job's page in the system browser.
local function open_selected_job_web()
  local state = state_mod.state
  local current_jobs = stages_mod.get_current_stage_jobs(state)
  if #current_jobs == 0 then return end
  local job = current_jobs[state.cursor_line]
  if not job then return end
  if job.web_url and job.web_url ~= "" then
    open_url(job.web_url)
  else
    notify("no web URL for this job", vim.log.levels.WARN)
  end
end

---'O' — open the whole pipeline / latest run in the browser. Uses the URL the
---refresh already captured; falls back to a fresh resolve_web_url lookup that
---honors the session's (possibly branch-fallback) ref.
local function open_pipeline_web()
  local state = state_mod.state
  if state.pipeline_web_url and state.pipeline_web_url ~= "" then
    return open_url(state.pipeline_web_url)
  end
  if not ctx or type(ctx.provider.resolve_web_url) ~= "function" then
    notify("no pipeline URL available", vim.log.levels.WARN)
    return
  end
  ctx.provider.resolve_web_url(ctx.remote, ctx.ref, function(url, err)
    if not url then
      notify((err or "could not resolve pipeline URL"), vim.log.levels.ERROR)
      return
    end
    open_url(url)
  end)
end

-- Statuses for which a job's log is final and won't grow — no point polling.
local LOG_TERMINAL = {
  success = true, passed = true, failed = true,
  canceled = true, cancelled = true, skipped = true,
}

---'L' — fetch the selected job's log/trace and show it in a floating viewer.
---Auto-refreshes while the job may still be producing output; 'r' inside the
---viewer refreshes on demand.
local function view_selected_job_log()
  local state = state_mod.state
  if not ctx then return end
  local current_jobs = stages_mod.get_current_stage_jobs(state)
  if #current_jobs == 0 then return end
  local job = current_jobs[state.cursor_line]
  if not job or not job.id then return end
  if type(ctx.provider.fetch_job_log) ~= "function" then
    notify("provider has no log support", vim.log.levels.ERROR)
    return
  end

  local view = logview.open_loading(job.name or "job")

  local function fetcher(cb)
    if not ctx then return cb(nil, "no session") end
    ctx.provider.fetch_job_log(ctx.remote, job, cb)
  end

  -- Initial load surfaces fetch errors to the user.
  fetcher(function(text, err)
    if err then
      notify("could not fetch log: " .. err, vim.log.levels.ERROR)
      logview.set_body(view, "")
      return
    end
    logview.set_body(view, text or "")
  end)

  -- Poll while the job isn't in a terminal state. Manual 'r' works regardless.
  local intervals = config_mod.get().intervals or {}
  local interval = math.max(intervals.log_refresh or 3000, intervals.min or 3000)
  logview.attach_refresh(view, fetcher, {
    interval = interval,
    auto = not LOG_TERMINAL[job.status],
  })
end

local ACTIONABLE = {
  manual = true,
  failed = true,
  canceled = true,
  cancelled = true,
  running = true,
  pending = true,
  created = true,
}

local function trigger_all_stage_jobs()
  local state = state_mod.state
  if not ctx then return end
  local current_stage = state.stages[state.current_stage_idx]
  if not current_stage then return end

  -- Respect the active filter: get_current_stage_jobs returns the visible
  -- subset, so 'a' acts only on what the user actually sees.
  local visible_jobs = stages_mod.get_current_stage_jobs(state)
  if #visible_jobs == 0 then return end

  local jobs_to_trigger = {}
  local job_names = {}
  for _, job in ipairs(visible_jobs) do
    if ACTIONABLE[job.status] then
      table.insert(jobs_to_trigger, job)
      table.insert(job_names, job.name)
    end
  end
  if #jobs_to_trigger == 0 then return end

  local session = ctx
  local triggered_count = 0
  local total = #jobs_to_trigger
  for _, job in ipairs(jobs_to_trigger) do
    session.provider.run_action(session.remote, job, function(ok, err)
      if not ok then
        notify((err or ("action failed for '" .. job.name .. "'")), vim.log.levels.ERROR)
      end
      triggered_count = triggered_count + 1
      if triggered_count == total then
        monitor.start_batch(current_stage, job_names, build_fetch_fn(), {
          on_done = function()
            if state_mod.state.buf and vim.api.nvim_buf_is_valid(state_mod.state.buf) then
              M.refresh_pipeline()
            end
          end,
        })
        vim.defer_fn(function() M.refresh_pipeline() end, 1000)
      end
    end)
  end
end

local function close_window()
  window_mod.close(function()
    monitor.stop_window_scoped()
  end)
  ctx = nil
end

---Resolve the user's ref argument into a structured target.
---Precedence: explicit commit_sha → explicit tag → explicit branch → HEAD SHA
---→ branch HEAD.
---@param opts table
---@return CicdRef|nil ref, string|nil err
local function resolve_ref(opts)
  if opts.commit_sha and opts.commit_sha ~= "" then
    local full = git_util.resolve_full_sha(opts.commit_sha) or opts.commit_sha
    return { kind = "sha", value = full, short = full:sub(1, 7) }
  end
  if opts.tag and opts.tag ~= "" then
    return { kind = "tag", value = opts.tag }
  end
  if opts.branch and opts.branch ~= "" then
    return { kind = "branch", value = opts.branch:gsub("^origin/", "") }
  end
  local sha = git_util.head_sha()
  if sha and sha ~= "" then
    return { kind = "sha", value = sha, short = sha:sub(1, 7) }
  end
  local branch = git_util.current_branch()
  if branch ~= "" then
    return { kind = "branch", value = branch }
  end
  return nil, "could not resolve HEAD (not a git repo?)"
end

---@param opts? table  { branch = "<name>" } or { commit_sha = "<sha>" }; both
---                    optional — without either, targets current HEAD.
function M.open(opts)
  opts = opts or {}
  local state = state_mod.state
  state_mod.reset()

  local cfg = config_mod.get()
  monitor.configure(cfg)

  local remote_info, err = git_remote.detect()
  if not remote_info then
    notify((err or "no git remote"), vim.log.levels.ERROR)
    return
  end

  local provider_name = providers.detect(remote_info.host, cfg)
  local provider = providers.get(provider_name)

  local remote, build_err = provider.build_remote(remote_info, cfg)
  if not remote then
    notify((build_err or "failed to build remote"), vim.log.levels.ERROR)
    return
  end

  local ref, ref_err = resolve_ref(opts)
  if not ref then
    notify((ref_err or "could not resolve ref"), vim.log.levels.ERROR)
    return
  end

  state.ref = ref
  if ref.kind == "sha" then
    state.branch = "commit: " .. ref.short
  elseif ref.kind == "tag" then
    state.branch = "tag: " .. ref.value
  else
    state.branch = "branch: " .. ref.value
  end
  state.provider_name = provider_name
  ctx = {
    provider = provider,
    remote = remote,
    ref = ref,
  }

  window_mod.create()
  keymaps_mod.setup({
    close = close_window,
    trigger_selected = trigger_selected_job,
    trigger_all = trigger_all_stage_jobs,
    refresh = M.refresh_pipeline,
    open_job = open_selected_job_web,
    open_pipeline = open_pipeline_web,
    view_log = view_selected_job_log,
  })

  vim.api.nvim_set_option_value("modifiable", true, { buf = state.buf })
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, {
    "",
    "  Loading pipeline data...",
    "",
  })
  vim.api.nvim_set_option_value("modifiable", false, { buf = state.buf })

  M.refresh_pipeline()
end

return M
