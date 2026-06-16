-- Provider registry + auto-detection.
--
-- Each provider module (providers/gitlab.lua, providers/github.lua) conforms
-- to a shared interface:
--
--   provider.name                                 : "gitlab" | "github"
--   provider.build_remote(remote_info, cfg)       : table|nil, err
--   provider.fetch_current_pipeline(remote, ref, cb)
--                                                 : ref = { kind, value }
--                                                   kind = "branch" | "sha"
--   provider.fetch_pipeline(remote, pipeline_id, cb)
--   provider.resolve_web_url(remote, ref, cb)     : cheap pipeline URL lookup,
--                                                   no job fetch; falls back
--                                                   to a sensible listing URL
--   provider.run_action(remote, job, cb)          : router for play/retry/rerun
--
-- UI code consumes the normalized { Pipeline = {id, branch, status, jobs} }
-- shape regardless of provider. Individual providers own their own status
-- normalization logic.

local M = {}

local REGISTRY = {
  gitlab = "cicd.providers.gitlab",
  github = "cicd.providers.github",
}

---@param name string
---@return table provider module
function M.get(name)
  local mod = REGISTRY[name]
  if not mod then
    error("cicd: unknown provider: " .. tostring(name))
  end
  local m = require(mod)
  return m
end

---Heuristic host→provider mapping, overridable via cfg.host_providers.
---@param host string
---@param cfg table|nil
---@return string provider_name
function M.detect(host, cfg)
  cfg = cfg or {}
  host = (host or ""):lower()

  if cfg.host_providers and cfg.host_providers[host] then
    return cfg.host_providers[host]
  end

  if host == "github.com" or host:match("^ghes%.") then
    return "github"
  end
  if host:match("^gitlab%.") or host:match("gitlab") then
    return "gitlab"
  end

  -- Default fallback: gitlab (this plugin originated as GitLab-only; users
  -- with self-hosted GitHub Enterprise should set cfg.host_providers).
  return "gitlab"
end

return M
