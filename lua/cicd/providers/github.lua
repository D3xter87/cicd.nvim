-- GitHub Actions provider.
--
-- Differences from GitLab worth remembering when reading this file:
--
--   * API host ≠ git remote host for github.com:
--       remote  = github.com               → auth/API host = api.github.com
--       remote  = ghe.corp (GH Enterprise) → auth/API host = ghe.corp
--     ~/.netrc therefore needs `machine api.github.com ...` for github.com
--     repos. See auth_host_for below.
--
--   * Base URL: github.com → https://api.github.com
--               GHE        → https://<host>/api/v3
--
--   * Auth header: Authorization: Bearer <token>  (not PRIVATE-TOKEN).
--     Already produced by cicd.http.auth.headers_for("github", …).
--
--   * Pipeline model: GitHub has no first-class "pipeline" or "stage". We
--     synthesize one Pipeline by listing the latest workflow_run per
--     workflow_id on the branch and using each run's name as a stage. Jobs
--     of all those runs are aggregated into a single jobs[] list, each
--     tagged with stage = workflow_run.name.
--
--   * `needs` / DAG: not exposed by Jobs API; we leave it nil. With no
--     dependencies, ui/stages.lua falls back to first-appearance order, so we
--     aggregate jobs in workflow-run order (see fetch_current_pipeline) to make
--     the resulting stage order deterministic and run-ordered.
--
--   * run_action mapping (intentionally narrower than GitLab's):
--       failed                   → POST /actions/jobs/{id}/rerun
--       running | pending        → POST /actions/runs/{run_id}/cancel
--                                  (GitHub has NO per-job cancel — this
--                                  cancels the whole workflow run, by design)
--       manual (action_required) → error: needs web UI for env approval
--       success | skipped | etc. → not actionable

local M = {}

M.name = "github"

local client = require("cicd.http.client")
local auth = require("cicd.http.auth")

---@param remote_host string
---@return string
function M.auth_host_for(remote_host)
  if remote_host == "github.com" then
    return "api.github.com"
  end
  return remote_host
end

-- vim.json.decode maps JSON `null` to vim.NIL (a userdata that is truthy).
-- Same boundary normalization as the GitLab provider.
local function nullable(v)
  if v == vim.NIL then return nil end
  return v
end

---Composed status × conclusion → normalized job status.
local function normalize_status(status, conclusion)
  status = nullable(status)
  conclusion = nullable(conclusion)

  if status == "queued" or status == "waiting" or status == "requested" then
    return "pending"
  end
  if status == "in_progress" then
    return "running"
  end
  if status == "completed" then
    if conclusion == "success" or conclusion == "neutral" then return "success" end
    if conclusion == "failure" or conclusion == "timed_out" then return "failed" end
    if conclusion == "cancelled" then return "canceled" end
    if conclusion == "skipped" or conclusion == "stale" then return "skipped" end
    if conclusion == "action_required" then return "manual" end
    return "created"
  end
  return "created"
end

---Best-effort duration from started_at / completed_at ISO 8601 timestamps.
---Returns seconds (number) or nil if either timestamp is missing/unparseable.
local function compute_duration(started_at, completed_at)
  started_at = nullable(started_at)
  completed_at = nullable(completed_at)
  if not started_at or not completed_at then return nil end
  local function parse(s)
    local Y, Mo, D, H, Mi, S = s:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    if not Y then return nil end
    return os.time({ year = Y, month = Mo, day = D, hour = H, min = Mi, sec = S })
  end
  local a, b = parse(started_at), parse(completed_at)
  if not a or not b then return nil end
  local d = b - a
  return d >= 0 and d or nil
end

local function normalize_job(raw, run)
  return {
    id = nullable(raw.id),
    name = nullable(raw.name) or "?",
    status = normalize_status(raw.status, raw.conclusion),
    stage = (run and run.name) or nullable(raw.workflow_name) or "workflow",
    duration = compute_duration(raw.started_at, raw.completed_at),
    needs = nil,
    web_url = nullable(raw.html_url),
    raw = raw,
  }
end

---@param remote_info { host: string, path: string, scheme: string|nil }
---@param cfg table
---@return table|nil remote, string|nil err
function M.build_remote(remote_info, cfg)
  local auth_host = M.auth_host_for(remote_info.host)
  local token, err = auth.get_token(auth_host, "github", cfg)
  if not token then return nil, err end

  local base_url
  if cfg.host_bases and cfg.host_bases[remote_info.host] then
    base_url = cfg.host_bases[remote_info.host]
  elseif remote_info.host == "github.com" then
    base_url = "https://api.github.com"
  else
    -- GitHub Enterprise: API at /api/v3 on the same host as the git remote.
    local scheme = (cfg.host_schemes and cfg.host_schemes[remote_info.host])
        or remote_info.scheme
        or "https"
    base_url = string.format("%s://%s/api/v3", scheme, remote_info.host)
  end

  return {
    host = remote_info.host,
    auth_host = auth_host,
    path = remote_info.path,
    base_url = base_url,
    -- Note: GitHub API takes literal "owner/repo" in URLs; do NOT uri-encode
    -- the slash. The GitLab provider encodes by contrast (group%2Fsub%2Frepo).
    owner_repo = remote_info.path,
    headers = auth.headers_for("github", token),
  }
end

---Fetches jobs of one workflow run, paginated, normalizes each. Stops when a
---page returns fewer than per_page jobs or after max_pages.
---@param remote table
---@param run table  workflow_run object (must have .id and .name)
---@param cb fun(jobs: table[]|nil, err: string|nil)
function M._fetch_jobs_for_run(remote, run, cb)
  local url = string.format(
    "%s/repos/%s/actions/runs/%s/jobs",
    remote.base_url, remote.owner_repo, tostring(run.id)
  )
  local page = 1
  local max_pages = 5
  local per_page = 100
  local all = {}

  local function fetch_page()
    client.request({
      url = url,
      method = "get",
      headers = remote.headers,
      query = { per_page = per_page, page = page, filter = "latest" },
    }, function(res)
      if not res.ok then return cb(nil, res.err or "failed to list jobs") end
      local body, derr = client.decode_json(res.body)
      if not body then return cb(nil, derr) end
      local jobs = body.jobs or {}
      for _, j in ipairs(jobs) do table.insert(all, j) end

      if #jobs == per_page and page < max_pages then
        page = page + 1
        fetch_page()
      else
        local normalized = {}
        for _, j in ipairs(all) do
          table.insert(normalized, normalize_job(j, run))
        end
        cb(normalized)
      end
    end)
  end

  fetch_page()
end

---Lists recent workflow runs filtered by ref. For branch refs we pass
---`?branch=<name>`; for SHA refs (and tags, keyed by their target commit) we
---pass `?head_sha=<sha>` (GitHub indexes runs by both, but not by a generic
---"ref"). Keeps the latest per workflow_id (API returns desc by created_at, so
---the first occurrence wins).
---@param remote table
---@param ref { kind: "branch"|"sha"|"tag", value: string, sha: string|nil }
---@param cb fun(runs: table[]|nil, err: string|nil)
function M._fetch_workflow_runs(remote, ref, cb)
  local url = string.format("%s/repos/%s/actions/runs", remote.base_url, remote.owner_repo)
  local query = {
    per_page = 20,
    exclude_pull_requests = "true",
  }
  if ref.kind == "sha" then
    query.head_sha = ref.value
  elseif ref.kind == "tag" and ref.sha then
    query.head_sha = ref.sha
  else
    query.branch = ref.value
  end
  client.request({
    url = url,
    method = "get",
    headers = remote.headers,
    query = query,
  }, function(res)
    if not res.ok then return cb(nil, res.err or "failed to list workflow runs") end
    local body, derr = client.decode_json(res.body)
    if not body then return cb(nil, derr) end
    local runs = body.workflow_runs or {}

    local seen = {}
    local latest = {}
    for _, r in ipairs(runs) do
      local wid = r.workflow_id
      if wid and not seen[wid] then
        seen[wid] = true
        table.insert(latest, r)
      end
    end
    cb(latest)
  end)
end

---@param remote table
---@param ref { kind: "branch"|"sha"|"tag", value: string, sha: string|nil }
---@param cb fun(pipeline: table|nil, err: string|nil)
function M.fetch_current_pipeline(remote, ref, cb)
  M._fetch_workflow_runs(remote, ref, function(runs, err)
    if err then return cb(nil, err) end
    runs = runs or {}
    if #runs == 0 then
      return cb({ id = "multi", ref = ref, branch = ref.value, status = "created", jobs = {}, web_url = nil })
    end

    -- Counter pattern: launch N parallel job fetches and aggregate. A failure
    -- on any single run is logged-but-tolerated (partial success > total
    -- failure for a CI browser).
    --
    -- Jobs land in per-run buckets keyed by the run's position, then are
    -- concatenated in run order — NOT in request-completion order. This keeps
    -- stage ordering (stage = run.name) deterministic and aligned with the
    -- workflow-run order, which ui/stages.lua uses as the pipeline order.
    --
    -- _fetch_workflow_runs returns runs newest-first (API is desc by
    -- created_at), so the last-created stage (e.g. deploy) would otherwise lead.
    -- We walk buckets oldest-first (#runs..1) to recover true pipeline order.
    local pending = #runs
    local buckets = {}
    local first_html_url = nullable(runs[1] and runs[1].html_url)

    for i, run in ipairs(runs) do
      M._fetch_jobs_for_run(remote, run, function(jobs, _per_run_err)
        buckets[i] = jobs or {}
        pending = pending - 1
        if pending == 0 then
          local aggregate = {}
          for ri = #runs, 1, -1 do
            for _, j in ipairs(buckets[ri] or {}) do
              table.insert(aggregate, j)
            end
          end
          cb({
            id = "multi",
            ref = ref,
            branch = ref.value,
            status = "running",
            jobs = aggregate,
            web_url = first_html_url,
          })
        end
      end)
    end
  end)
end

---Map an API host back to its web host. api.github.com → github.com; GHE
---instances host the web UI on the same hostname as the API.
local function web_host_for(api_host)
  if api_host == "api.github.com" then return "github.com" end
  return api_host
end

---Resolve a browser URL for a ref without fetching jobs.
---@param remote table
---@param ref { kind: "branch"|"sha"|"tag", value: string, sha: string|nil }
---@param cb fun(url: string|nil, err: string|nil)
function M.resolve_web_url(remote, ref, cb)
  local web_host = web_host_for(remote.host)
  local scheme = remote.base_url:match("^(https?)://") or "https"
  local web_base = string.format("%s://%s/%s", scheme, web_host, remote.owner_repo)

  M._fetch_workflow_runs(remote, ref, function(runs, err)
    if not err and runs and runs[1] then
      local url = nullable(runs[1].html_url)
      if url and url ~= "" then return cb(url) end
    end
    -- Fallback when no run matches (or the lookup failed). A sha or tag links
    -- to the commit checks page (tag runs are keyed by the target commit).
    local commit_sha = ref.kind == "sha" and ref.value or (ref.kind == "tag" and ref.sha or nil)
    if commit_sha then
      cb(string.format("%s/commit/%s/checks", web_base, commit_sha))
    else
      cb(string.format("%s/actions?query=branch%%3A%s", web_base, ref.value))
    end
  end)
end

---Stub for interface compliance; the live runtime path uses
---fetch_current_pipeline. GitHub has no "pipeline_id" we could hand to a
---generic fetcher (we synthesize one Pipeline from N runs).
---@param _remote table
---@param _pipeline_id any
---@param cb fun(pipeline: table|nil, err: string|nil)
function M.fetch_pipeline(_remote, _pipeline_id, cb)
  cb(nil, "fetch_pipeline by id is not supported on github (use fetch_current_pipeline)")
end

---Fetches the plain-text log for a single job. The logs endpoint 302-redirects
---to a pre-signed blob URL, so we follow redirects (curl drops the auth header
---across hosts, which is correct — the target is pre-signed).
---@param remote table
---@param job table  normalized job (must have id)
---@param cb fun(text: string|nil, err: string|nil)
function M.fetch_job_log(remote, job, cb)
  if not job or not job.id then
    return cb(nil, "missing job id")
  end
  local url = string.format(
    "%s/repos/%s/actions/jobs/%s/logs",
    remote.base_url, remote.owner_repo, tostring(job.id)
  )
  client.request({
    url = url,
    method = "get",
    headers = remote.headers,
    follow_redirects = true,
  }, function(res)
    if res.ok then return cb(res.body or "") end
    cb(nil, res.err or "failed to fetch job log")
  end)
end

---@param remote table
---@param job table  normalized job (must carry job.id and job.raw.run_id)
---@param cb fun(ok: boolean, err: string|nil)
function M.run_action(remote, job, cb)
  if not job or not job.id then
    return cb(false, "missing job id")
  end

  if job.status == "manual" then
    return cb(false, "GitHub manual approval requires web UI")
  end

  if job.status == "failed" then
    local url = string.format(
      "%s/repos/%s/actions/jobs/%s/rerun",
      remote.base_url, remote.owner_repo, tostring(job.id)
    )
    return client.request({ url = url, method = "post", headers = remote.headers },
      function(res) cb(res.ok, res.err) end)
  end

  if job.status == "running" or job.status == "pending" then
    local run_id = job.raw and job.raw.run_id
    if not run_id then
      return cb(false, "no run_id on job — cannot cancel")
    end
    local url = string.format(
      "%s/repos/%s/actions/runs/%s/cancel",
      remote.base_url, remote.owner_repo, tostring(run_id)
    )
    return client.request({ url = url, method = "post", headers = remote.headers },
      function(res) cb(res.ok, res.err) end)
  end

  cb(false, "job status '" .. tostring(job.status) .. "' is not actionable")
end

return M
