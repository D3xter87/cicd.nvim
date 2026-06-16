local M = {}

local defaults = {
  intervals = {
    single_monitor = 10000,
    batch_monitor = 5000,
    auto_refresh = 5000,
    min = 3000,
  },
  providers = {
    -- gitlab = { token = "glpat-..." }, -- optional explicit override for testing
    -- github = { token = "ghp-..." },
  },
  host_providers = {
    -- ["gitlab.internal.corp"] = "gitlab",
    -- ["ghes.corp"] = "github",
  },
  host_schemes = {
    -- Override the API URL scheme per host. By default the scheme is taken
    -- from the http(s):// prefix of `git remote get-url origin`; SSH/scp
    -- remotes default to https. Set this when your remote is SSH but the
    -- API only listens on http (or vice-versa).
    -- ["gitlab.internal.example.com"] = "http",
  },
  host_bases = {
    -- Full base URL override (wins over scheme + default path). Use for
    -- non-standard API roots, e.g. GitHub Enterprise:
    -- ["ghes.corp"] = "https://ghes.corp/api/v3",
  },
  debug = false,
}

local options = vim.deepcopy(defaults)

function M.setup(opts)
  options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

function M.get()
  return options
end

return M
