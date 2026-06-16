# cicd.nvim

Interactive CI/CD pipeline browser for Neovim. Talks to GitLab and GitHub
through their public REST APIs from a single floating window — no `glab`,
no `gh`, no external Lua HTTP libraries, just system `curl`.

## What it does

- Opens a floating browser for the **current pipeline of the active branch**.
- Lists jobs grouped by stage (GitLab) or workflow (GitHub Actions).
- One-key job actions:
  - `manual` → play
  - `failed` / `canceled` → retry
  - `running` / `pending` → cancel
- Live filter, auto-refresh while jobs are running, batch trigger ("act
  every actionable job in the visible stage").
- Identical UX for both providers — provider is auto-detected from the
  `origin` remote URL.

## Quick example

```vim
:Cicd                  " browse pipeline of current HEAD
:Cicd feature/foo      " browse a specific branch
:Actions               " same thing — alias when you're on GitHub
```

Inside the window:

| Key       | Action                                |
|-----------|---------------------------------------|
| `j`/`k`   | move between jobs in current stage    |
| `h`/`l`   | move between stages                   |
| `gg` / `G`| first / last job                      |
| `/`       | live filter (start typing)            |
| `<CR>`    | act on selected job                   |
| `a`       | act on every actionable visible job   |
| `r`       | refresh                               |
| `q`       | close                                 |

## Installation

`lazy.nvim`:

```lua
{
  "D3xter87/cicd.nvim",
  cmd = { "Cicd", "Actions" },
  opts = {},
}
```

## Authentication

The plugin looks for a token in this order:

1. `opts.providers.<name>.token` (rarely useful — see configuration).
2. `~/.netrc` (or `%USERPROFILE%\_netrc` on Windows) — host-keyed:
   ```
   machine gitlab.example.com
     login   <ignored>
     password glpat-XXXXXXXXXXXXXXXX
   ```
   For `github.com` use `machine api.github.com` (the API host, not the
   site host).
3. Environment variables `$GITLAB_TOKEN` / `$GITHUB_TOKEN`.

Required scopes:
- **GitLab**: `api` (the plugin needs to play / retry / cancel — `read_api`
  is not enough).
- **GitHub**: `repo` for private repos, `public_repo` for public.

## Configuration

Every key is optional; defaults are sensible.

```lua
require("cicd").setup({
  intervals = {
    single_monitor = 10000,  -- ms; per-job poll while watching one job
    batch_monitor  = 5000,   -- ms; act-all watcher
    auto_refresh   = 5000,   -- ms; window auto-refresh
    min            = 3000,
  },
  providers = {
    -- explicit token override (useful for scripted setups / tests)
    -- gitlab = { token = vim.env.MY_GITLAB_TOKEN },
  },
  host_providers = {
    -- override provider when hostname doesn't match the heuristics
    -- ["ci.internal"]      = "gitlab",
    -- ["ghes.example.com"] = "github",
  },
  host_schemes = {
    -- override the API URL scheme per host (e.g. SSH remote, HTTP-only API)
    -- ["gitlab.intranet"] = "http",
  },
  host_bases = {
    -- full base URL override; useful for GitHub Enterprise
    -- ["ghes.example.com"] = "https://ghes.example.com/api/v3",
  },
})
```

## Provider detection

The `origin` remote URL is parsed into `{ host, path, scheme }` and the
provider is picked by:

1. `cfg.host_providers[host]` if set.
2. `host == "github.com"` or `host` matches `^ghes%.` → `github`.
3. `host` starts with `gitlab.` or contains `gitlab` → `gitlab`.
4. Fallback → `gitlab`.

For self-hosted forges with unusual hostnames, set `host_providers` /
`host_bases` accordingly.

## Help

After installation:

```vim
:help cicd
```

## License

MIT — see [LICENSE](./LICENSE).
