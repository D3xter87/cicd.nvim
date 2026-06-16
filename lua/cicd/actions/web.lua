-- :CicdWeb [branch|<sha>]
--
-- Opens the pipeline / workflow run for the resolved ref in the system
-- default browser. Without an argument: targets the current HEAD SHA (so the
-- user lands on the pipeline that ran for their currently-checked-out
-- commit). Falls back to a sensible commit/branch listing URL when no
-- matching pipeline exists.

local M = {}

local git_remote = require("cicd.http.git_remote")
local providers = require("cicd.providers")
local config_mod = require("cicd.config")
local git_util = require("cicd.util.git")
local browser = require("cicd.util.browser")

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "CI/CD" })
end

---@param opts table  { branch = "<name>" } | { tag = "<name>" } | { commit_sha = "<sha>" }
---@return { kind: "branch"|"tag"|"sha", value: string, short: string|nil }|nil ref, string|nil err
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
  -- Default: current HEAD SHA. No branch fallback for the web command — the
  -- provider's resolve_web_url returns a commit-checks page if no run exists.
  local sha = git_util.head_sha()
  if sha and sha ~= "" then
    return { kind = "sha", value = sha, short = sha:sub(1, 7) }
  end
  return nil, "could not resolve HEAD (not a git repo?)"
end

function M.run(opts)
  opts = opts or {}

  local cfg = config_mod.get()

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

  if type(provider.resolve_web_url) ~= "function" then
    notify("provider '" .. provider_name .. "' has no web URL support", vim.log.levels.ERROR)
    return
  end

  provider.resolve_web_url(remote, ref, function(url, resolve_err)
    if not url then
      notify((resolve_err or "could not resolve web URL"), vim.log.levels.ERROR)
      return
    end
    if browser.open(url) then
      notify("opened " .. url)
    else
      notify("could not open browser — copy URL manually: " .. url, vim.log.levels.WARN)
    end
  end)
end

return M
