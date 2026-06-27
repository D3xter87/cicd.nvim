-- GitLab REST v4 provider.
--
-- Maps the formerly-glab-driven operations to HTTPS calls:
--   fetch_current_pipeline  = pipelines?ref=<branch>&per_page=1  +  pipelines/:id/jobs
--   run_action              = jobs/:id/play (manual) | jobs/:id/retry (failed/canceled)
--
-- Jobs are returned in the normalized shape that UI already consumes (the
-- same fields that `glab ci get` used to produce, so render code doesn't care).

local M = {}

M.name = "gitlab"

local client = require("cicd.http.client")
local auth = require("cicd.http.auth")

-- vim.json.decode maps JSON `null` to vim.NIL (a userdata). vim.NIL is
-- truthy in Lua, which silently breaks `if x then ...` checks downstream.
-- We collapse NIL to plain nil at the provider boundary so UI / monitor
-- never have to think about it.
local function nullable(v)
  if v == vim.NIL then return nil end
  return v
end

local STATUS_MAP = {
  success = "success",
  passed = "success",
  failed = "failed",
  running = "running",
  pending = "pending",
  preparing = "pending",
  waiting_for_resource = "pending",
  scheduled = "pending",
  manual = "manual",
  canceled = "canceled",
  cancelled = "canceled",
  skipped = "skipped",
  created = "created",
}

local function normalize_status(s)
  s = nullable(s)
  return STATUS_MAP[s] or s or "created"
end

local function normalize_needs(needs)
  needs = nullable(needs)
  if type(needs) ~= "table" then return nil end
  local out = {}
  for _, n in ipairs(needs) do
    if type(n) == "table" then
      table.insert(out, n.job or n.name)
    elseif type(n) == "string" then
      table.insert(out, n)
    end
  end
  return out
end

local function normalize_job(raw)
  local duration = nullable(raw.duration)
  return {
    id = nullable(raw.id),
    name = nullable(raw.name) or "?",
    status = normalize_status(raw.status),
    stage = nullable(raw.stage) or "",
    duration = type(duration) == "number" and duration or nil,
    needs = normalize_needs(raw.needs),
    web_url = nullable(raw.web_url),
    raw = raw,
  }
end

---For GitLab the API lives on the same host as the git remote (only the path
---differs: /api/v4). Auth host therefore equals the remote host.
---@param remote_host string
---@return string
function M.auth_host_for(remote_host)
  return remote_host
end

---Builds the provider-specific remote context used by all subsequent calls.
---Scheme resolution order:
---   1. cfg.host_bases[host]         (explicit full base URL override)
---   2. cfg.host_schemes[host]       (just override the scheme)
---   3. remote_info.scheme           (taken from `git remote get-url`)
---   4. "https"                      (default for SSH/scp remotes)
---@param remote_info { host: string, path: string, scheme: string|nil }
---@param cfg table  output of cicd.config.get()
---@return table|nil remote, string|nil err
function M.build_remote(remote_info, cfg)
  local auth_host = M.auth_host_for(remote_info.host)
  local token, err = auth.get_token(auth_host, "gitlab", cfg)
  if not token then return nil, err end

  local base_url
  if cfg.host_bases and cfg.host_bases[remote_info.host] then
    base_url = cfg.host_bases[remote_info.host]
  else
    local scheme = (cfg.host_schemes and cfg.host_schemes[remote_info.host])
        or remote_info.scheme
        or "https"
    base_url = string.format("%s://%s/api/v4", scheme, remote_info.host)
  end

  return {
    host = remote_info.host,
    auth_host = auth_host,
    path = remote_info.path,
    base_url = base_url,
    project_id = client.uri_encode(remote_info.path),
    headers = auth.headers_for("gitlab", token),
  }
end

---Fetches the latest pipeline for the given ref, then its jobs. GitLab's `ref`
---filter matches branch/tag *names* only, NOT commit SHAs — and a tag's
---pipeline is keyed by the commit it points to (its ref is the triggering
---branch), so SHA and tag targets must query the dedicated `sha` parameter.
---@param remote table
---@param ref { kind: "branch"|"sha"|"tag", value: string, sha: string|nil }
---@param cb fun(pipeline: table|nil, err: string|nil)
function M.fetch_current_pipeline(remote, ref, cb)
  local pipelines_url = string.format("%s/projects/%s/pipelines", remote.base_url, remote.project_id)

  local query = { order_by = "updated_at", sort = "desc", per_page = 1 }
  if ref.kind == "sha" then
    query.sha = ref.value
  elseif ref.kind == "tag" and ref.sha then
    query.sha = ref.sha
  else
    query.ref = ref.value
  end

  client.request({
    url = pipelines_url,
    method = "get",
    headers = remote.headers,
    query = query,
  }, function(res)
    if not res.ok then
      return cb(nil, res.err or "failed to list pipelines")
    end
    local list, decode_err = client.decode_json(res.body)
    if not list then return cb(nil, decode_err) end
    if type(list) ~= "table" or #list == 0 then
      return cb({ id = nil, ref = ref, branch = ref.value, status = "created", jobs = {}, web_url = nil })
    end
    local pipeline = list[1]
    M._fetch_jobs(remote, pipeline, ref, cb)
  end)
end

---@param remote table
---@param pipeline_id string|number
---@param cb fun(pipeline: table|nil, err: string|nil)
function M.fetch_pipeline(remote, pipeline_id, cb)
  M._fetch_jobs(remote, { id = pipeline_id }, nil, cb)
end

---Internal: GETs /projects/:id/pipelines/:pid/jobs paginated, then returns a
---Pipeline object with normalized jobs.
---@param remote table
---@param pipeline table        raw pipeline from list endpoint (must have id;
---                             may carry .web_url and .ref)
---@param ref table|nil         { kind, value } if invoked from fetch_current_pipeline
---@param cb fun(pipeline: table|nil, err: string|nil)
function M._fetch_jobs(remote, pipeline, ref, cb)
  local url = string.format(
    "%s/projects/%s/pipelines/%s/jobs",
    remote.base_url, remote.project_id, tostring(pipeline.id)
  )
  local page = 1
  local max_pages = 5
  local all = {}

  local function fetch_page()
    client.request({
      url = url,
      method = "get",
      headers = remote.headers,
      query = {
        per_page = 100,
        page = page,
        include_retried = false,
      },
    }, function(res)
      if not res.ok then return cb(nil, res.err or "failed to list jobs") end
      local jobs, derr = client.decode_json(res.body)
      if not jobs then return cb(nil, derr) end
      for _, j in ipairs(jobs) do table.insert(all, j) end

      local next_page = client.get_header(res.headers, "x-next-page")
      if next_page and next_page ~= "" and page < max_pages then
        page = page + 1
        fetch_page()
      else
        -- GitLab's jobs endpoint returns jobs descending by id (latest stage
        -- first). ui/stages.lua derives pipeline order from first-appearance,
        -- so we reverse to oldest-first to recover true pipeline order.
        local normalized = {}
        for i = #all, 1, -1 do table.insert(normalized, normalize_job(all[i])) end
        cb({
          id = pipeline.id,
          ref = ref,
          branch = (ref and ref.value) or pipeline.ref,
          status = normalize_status(pipeline.status),
          jobs = normalized,
          web_url = nullable(pipeline.web_url),
        })
      end
    end)
  end

  fetch_page()
end

---Resolve a browser URL for a ref without fetching jobs.
---  * If a pipeline exists for the ref → its API-provided web_url.
---  * Otherwise a sensible fallback page (commit page for sha/tag, pipelines
---    list filtered by name for a branch).
---@param remote table
---@param ref { kind: "branch"|"sha"|"tag", value: string, sha: string|nil }
---@param cb fun(url: string|nil, err: string|nil)
function M.resolve_web_url(remote, ref, cb)
  local pipelines_url = string.format("%s/projects/%s/pipelines", remote.base_url, remote.project_id)
  local scheme = pipelines_url:match("^(https?)://") or "https"
  local web_base = string.format("%s://%s/%s", scheme, remote.host, remote.path)

  -- GitLab's pipelines `ref` filter matches branch/tag names only, NOT commit
  -- SHAs — and a tag's pipeline is keyed by its commit (its ref is the
  -- triggering branch), so both SHA and tag targets query the `sha` parameter.
  local query = { order_by = "updated_at", sort = "desc", per_page = 1 }
  local commit_sha = ref.kind == "sha" and ref.value or (ref.kind == "tag" and ref.sha or nil)
  if commit_sha then
    query.sha = commit_sha
  else
    query.ref = ref.value
  end

  client.request({
    url = pipelines_url,
    method = "get",
    headers = remote.headers,
    query = query,
  }, function(res)
    if res.ok then
      local list = client.decode_json(res.body)
      if type(list) == "table" and list[1] then
        local url = nullable(list[1].web_url)
        if url and url ~= "" then return cb(url) end
      end
    end
    -- Fallback when no pipeline is found (or the listing failed). For a sha or
    -- tag we link to the commit page (the pipelines list filtered by a tag name
    -- is empty — the pipeline's ref is the triggering branch, not the tag).
    if commit_sha then
      cb(string.format("%s/-/commit/%s", web_base, commit_sha))
    else
      cb(string.format("%s/-/pipelines?ref=%s", web_base, ref.value))
    end
  end)
end

---Fetches the raw trace (log) for a job as plain text.
---@param remote table
---@param job table  normalized job (must have id)
---@param cb fun(text: string|nil, err: string|nil)
function M.fetch_job_log(remote, job, cb)
  if not job or not job.id then
    return cb(nil, "missing job id")
  end
  local url = string.format(
    "%s/projects/%s/jobs/%s/trace",
    remote.base_url, remote.project_id, tostring(job.id)
  )
  client.request({
    url = url,
    method = "get",
    headers = remote.headers,
  }, function(res)
    if res.ok then return cb(res.body or "") end
    cb(nil, res.err or "failed to fetch job log")
  end)
end

---Per-status action routing. UI calls this without knowing which endpoint
---applies; the function picks play / retry / cancel based on job state.
---  manual                 → play   (POST .../play)
---  failed | canceled      → retry  (POST .../retry)
---  running | pending | created → cancel (POST .../cancel)
---@param remote table
---@param job table  normalized job (must have id + status)
---@param cb fun(ok: boolean, err: string|nil)
function M.run_action(remote, job, cb)
  if not job or not job.id then
    return cb(false, "missing job id")
  end

  local action
  if job.status == "manual" then
    action = "play"
  elseif job.status == "failed" or job.status == "canceled" or job.status == "cancelled" then
    action = "retry"
  elseif job.status == "running" or job.status == "pending" or job.status == "created" then
    action = "cancel"
  else
    return cb(false, "job status '" .. tostring(job.status) .. "' is not actionable")
  end

  local url = string.format(
    "%s/projects/%s/jobs/%s/%s",
    remote.base_url, remote.project_id, tostring(job.id), action
  )

  client.request({
    url = url,
    method = "post",
    headers = remote.headers,
  }, function(res)
    if res.ok then return cb(true) end
    cb(false, res.err or ("failed to " .. action))
  end)
end

return M
