-- ============================================================================
-- cicd.nvim — interactive CI/CD pipeline browser for Neovim
-- ============================================================================
-- Public entry point. Real implementation lives in `cicd.controller` and
-- supporting modules (`providers/`, `ui/`, `monitor`, `state`, `http/`).
--
-- Supports GitLab (REST API v4) and GitHub Actions (REST). Provider is
-- auto-detected from the `origin` remote URL parsed by `cicd.http.git_remote`,
-- so `:Cicd` and `:Actions` are interchangeable aliases — pick whichever
-- reads naturally for the repository.
--
-- Authentication uses `~/.netrc` (or `%USERPROFILE%\_netrc` on Windows)
-- keyed by the API host, with `$GITLAB_TOKEN` / `$GITHUB_TOKEN` env vars as
-- fallback. Tokens are never logged or persisted.
--
-- See `:help cicd` for the full reference (commands, in-window key-map,
-- configuration schema, troubleshooting).
-- ============================================================================

local M = {}

---Open the pipeline browser for the current repository.
---@param opts? table  { branch = "<name>" }   - target a specific branch
---                    { commit_sha = "<sha>" } - target a specific commit
---                    nil / empty             - target the current HEAD (SHA,
---                                              falls back to branch if no
---                                              pipeline exists for HEAD).
---                    `origin/` prefix in `branch` is stripped automatically.
function M.open_pipeline_browser(opts)
  require("cicd.controller").open(opts)
end

---Apply user configuration. See |cicd-config| for the schema; every key is
---optional. Typically called via lazy.nvim's `opts = {...}`.
---@param opts? table
function M.setup(opts)
  require("cicd.config").setup(opts)
end

return M
