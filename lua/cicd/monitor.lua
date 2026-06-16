-- Pipeline polling timers.
--
-- Three independent modes:
--
--   single:  per-job 10s polling until the job reaches a terminal status
--            (success/failed/canceled). Survives window close — a job
--            triggered with <CR> keeps being watched even after the user
--            closes the browser, and the finish notify still fires.
--
--   batch:   stage-level 5s polling for jobs triggered by 'a'. Reports each
--            skipped job as a warning, immediately errors out on the first
--            failed job, and reports success once every job finishes.
--
--   auto_refresh: 5s tick while the browser window is open and any job is
--            running/pending. Pauses while the user is typing a filter.
--
-- All provider interaction is injected via a `fetch_fn(cb)` callback supplied
-- by the controller, so this module has no GitLab/GitHub knowledge.

local M = {}

local notify_fn
local function notify(msg, level)
  if notify_fn then
    notify_fn(msg, level)
  else
    vim.notify(msg, level or vim.log.levels.INFO, { title = "CI/CD" })
  end
end

---@param fn fun(msg: string, level: integer)|nil
function M.set_notifier(fn)
  notify_fn = fn
end

-- --------------------------------------------------------------------------
-- Single-job monitoring
-- --------------------------------------------------------------------------

local single = {
  jobs = {},        -- job_name -> { timer }
  interval = 10000,
}

local TERMINAL = {
  success = true,
  passed = true,
  failed = true,
  canceled = true,
  cancelled = true,
}

---Starts polling for one specific job until it reaches a terminal status.
---Idempotent: a second call for the same job is a no-op.
---@param job_name string
---@param fetch_fn fun(cb: fun(pipeline: table|nil, err: string|nil))
---@param on_done fun(job_name: string, final_status: string)|nil
function M.start_single(job_name, fetch_fn, on_done)
  if single.jobs[job_name] then return end

  local function check()
    fetch_fn(function(pipeline, err)
      if err or not pipeline then return end
      for _, job in ipairs(pipeline.jobs) do
        if job.name == job_name and TERMINAL[job.status] then
          local level = vim.log.levels.INFO
          local icon = "✓"
          if job.status == "failed" then
            level = vim.log.levels.ERROR
            icon = "✗"
          elseif job.status == "canceled" or job.status == "cancelled" then
            level = vim.log.levels.WARN
            icon = "⊘"
          end
          notify(string.format("%s Job '%s' finished: %s", icon, job_name, job.status), level)
          M.stop_single(job_name)
          if on_done then pcall(on_done, job_name, job.status) end
          return
        end
      end
    end)
  end

  local timer = vim.fn.timer_start(single.interval, function() check() end, { ["repeat"] = -1 })
  single.jobs[job_name] = { timer = timer }
end

function M.stop_single(job_name)
  local entry = single.jobs[job_name]
  if entry and entry.timer then
    vim.fn.timer_stop(entry.timer)
  end
  single.jobs[job_name] = nil
end

function M.stop_all_single()
  for name, _ in pairs(single.jobs) do
    M.stop_single(name)
  end
end

function M.is_single_active(job_name)
  return single.jobs[job_name] ~= nil
end

-- --------------------------------------------------------------------------
-- Batch monitoring
-- --------------------------------------------------------------------------

local batch = {
  active = false,
  stage = nil,
  job_names = {},
  job_statuses = {},
  timer = nil,
  interval = 5000,
  first_failed = nil,
  skipped_jobs = {},
}

function M.stop_batch()
  if batch.timer then
    vim.fn.timer_stop(batch.timer)
    batch.timer = nil
  end
  batch.active = false
  batch.stage = nil
  batch.job_names = {}
  batch.job_statuses = {}
  batch.first_failed = nil
  batch.skipped_jobs = {}
end

---@param stage string
---@param job_names string[]
---@param fetch_fn fun(cb: fun(pipeline: table|nil, err: string|nil))
---@param callbacks { on_done: fun()|nil }
function M.start_batch(stage, job_names, fetch_fn, callbacks)
  callbacks = callbacks or {}
  M.stop_batch()

  batch.active = true
  batch.stage = stage
  batch.job_names = job_names
  batch.job_statuses = {}
  batch.first_failed = nil
  batch.skipped_jobs = {}
  for _, name in ipairs(job_names) do batch.job_statuses[name] = "pending" end

  local function check()
    if not batch.active then return end
    fetch_fn(function(pipeline, err)
      if err or not pipeline or not batch.active then return end
      local jobs = pipeline.jobs

      local all_finished = true
      local all_success = true
      local has_failed = false

      for _, job_name in ipairs(batch.job_names) do
        for _, job in ipairs(jobs) do
          if job.name == job_name then
            local old_status = batch.job_statuses[job_name]
            batch.job_statuses[job_name] = job.status

            if job.status == "skipped" and old_status ~= "skipped" then
              notify(string.format("⊘ Job '%s' was skipped", job_name), vim.log.levels.WARN)
              table.insert(batch.skipped_jobs, job_name)
            end

            if job.status == "running" or job.status == "pending" or job.status == "created" then
              all_finished = false
              all_success = false
            elseif job.status == "failed" then
              has_failed = true
              all_success = false
              if not batch.first_failed then batch.first_failed = job_name end
            elseif job.status ~= "success" and job.status ~= "passed" and job.status ~= "skipped" then
              all_success = false
            end
            break
          end
        end
      end

      if has_failed then
        notify(string.format("✗ Stage '%s' failed: job '%s'", batch.stage, batch.first_failed), vim.log.levels.ERROR)
        M.stop_batch()
        if callbacks.on_done then pcall(callbacks.on_done) end
      elseif all_finished then
        if all_success then
          notify(string.format("✓ Stage '%s' completed successfully", batch.stage), vim.log.levels.INFO)
        end
        -- Mixed terminal results (e.g. all canceled, or some success + some
        -- canceled) — stop quietly; the user can read the outcome from the
        -- refreshed window. Failure case is handled by the branch above.
        M.stop_batch()
        if callbacks.on_done then pcall(callbacks.on_done) end
      end
    end)
  end

  batch.timer = vim.fn.timer_start(batch.interval, function() check() end, { ["repeat"] = -1 })
  check()
end

-- --------------------------------------------------------------------------
-- Auto-refresh
-- --------------------------------------------------------------------------

local auto = {
  timer = nil,
  interval = 5000,
}

---@param tick_fn fun()  runs on each tick; must itself decide whether to fetch
function M.start_auto_refresh(tick_fn)
  if auto.timer then return end
  auto.timer = vim.fn.timer_start(auto.interval, function() tick_fn() end, { ["repeat"] = -1 })
end

function M.stop_auto_refresh()
  if auto.timer then
    vim.fn.timer_stop(auto.timer)
    auto.timer = nil
  end
end

---Stops window-scoped timers (auto-refresh + batch). Single-job timers are
---intentionally preserved so their finish-notify still fires after close.
function M.stop_window_scoped()
  M.stop_auto_refresh()
  M.stop_batch()
end

---@param cfg table  cicd.config.get() output
function M.configure(cfg)
  if cfg and cfg.intervals then
    single.interval = cfg.intervals.single_monitor or single.interval
    batch.interval = cfg.intervals.batch_monitor or batch.interval
    auto.interval = cfg.intervals.auto_refresh or auto.interval
  end
end

return M
