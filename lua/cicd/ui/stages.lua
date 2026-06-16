-- Pure helpers for stage ordering, grouping, and filtered selection.
-- No Neovim state dependencies; everything takes raw data in and returns data.

local M = {}

---Topologically orders stage names by job dependencies (Kahn's algorithm).
---Stages with the same in-degree are returned in pipeline (first-appearance)
---order — i.e. the order each stage first shows up in `jobs`. Providers are
---responsible for delivering `jobs` in pipeline order (oldest-first); both the
---GitLab and GitHub providers reverse their API's default newest-first order.
---@param jobs table[]  normalized jobs (each has .stage and optional .needs[])
---@return string[]
function M.order_by_dependencies(jobs)
  local stage_deps = {}
  local stage_set = {}
  local first_seen = {}

  for idx, job in ipairs(jobs) do
    local stage = job.stage or "unknown"
    stage_set[stage] = true
    if first_seen[stage] == nil then first_seen[stage] = idx end
    stage_deps[stage] = stage_deps[stage] or {}

    local needs = job.needs or {}
    for _, need in ipairs(needs) do
      for _, j in ipairs(jobs) do
        if j.name == need or (type(need) == "table" and j.name == need.job) then
          local dep_stage = j.stage or "unknown"
          if dep_stage ~= stage then
            stage_deps[stage][dep_stage] = true
          end
        end
      end
    end
  end

  local in_degree = {}
  local stages = {}
  for stage in pairs(stage_set) do
    table.insert(stages, stage)
    in_degree[stage] = 0
  end

  for stage, deps in pairs(stage_deps) do
    for dep in pairs(deps) do
      if stage_set[dep] then
        in_degree[stage] = (in_degree[stage] or 0) + 1
      end
    end
  end

  local result = {}
  local queue = {}

  for _, stage in ipairs(stages) do
    if in_degree[stage] == 0 then
      table.insert(queue, stage)
    end
  end

  while #queue > 0 do
    table.sort(queue, function(a, b)
      return (first_seen[a] or math.huge) < (first_seen[b] or math.huge)
    end)
    local stage = table.remove(queue, 1)
    table.insert(result, stage)

    for s, deps in pairs(stage_deps) do
      if deps[stage] then
        in_degree[s] = in_degree[s] - 1
        if in_degree[s] == 0 then
          table.insert(queue, s)
        end
      end
    end
  end

  -- Any remaining stages (cycle detection fallback)
  for _, stage in ipairs(stages) do
    local found = false
    for _, s in ipairs(result) do
      if s == stage then found = true; break end
    end
    if not found then
      table.insert(result, stage)
    end
  end

  return result
end

---Groups jobs by stage.
---@param jobs table[]
---@return table<string, table[]>
function M.group_by_stage(jobs)
  local by_stage = {}
  for _, job in ipairs(jobs) do
    local stage = job.stage or "unknown"
    by_stage[stage] = by_stage[stage] or {}
    table.insert(by_stage[stage], job)
  end
  return by_stage
end

---Returns current stage's jobs, optionally filtered by substring search.
---@param state table  the cicd.state.state table
---@return table[]
function M.get_current_stage_jobs(state)
  if #state.stages == 0 then return {} end
  local stage = state.stages[state.current_stage_idx]
  local jobs = state.jobs_by_stage[stage] or {}

  if state.filter_text == "" then return jobs end

  local filtered = {}
  local pattern = state.filter_text:lower()
  for _, job in ipairs(jobs) do
    local searchable = string.lower(
      (job.name or "") .. " " .. (job.stage or "") .. " " .. (job.status or "")
    )
    if searchable:find(pattern, 1, true) then
      table.insert(filtered, job)
    end
  end
  return filtered
end

return M
