-- Parses the URL returned by `git remote get-url origin` into {host, path, scheme}.
-- Supports scp-like (git@host:path), https://, http://, and ssh:// forms.
-- Any userinfo (e.g. https://oauth2:TOKEN@host/...) is stripped so tokens
-- never leak out. The `scheme` field carries the http/https hint when the
-- remote URL has one — providers use it to pick the API base URL scheme.

local M = {}

---@param url string
---@return {host: string, path: string, scheme: string|nil}|nil, string|nil
function M.parse(url)
  if type(url) ~= "string" or url == "" then
    return nil, "empty remote url"
  end

  url = url:gsub("%s+$", "")
  local stripped = url:gsub("%.git$", "")

  -- ssh://user@host[:port]/path
  local host, path = stripped:match("^ssh://[^@/]+@([^:/]+):?%d*/(.+)$")
  if host and path then
    return { host = host:lower(), path = path, scheme = nil }
  end
  -- ssh://host[:port]/path
  host, path = stripped:match("^ssh://([^:/@]+):?%d*/(.+)$")
  if host and path then
    return { host = host:lower(), path = path, scheme = nil }
  end

  -- scp-like: user@host:path  (must appear before http(s):// check because
  -- both contain '@', but scp form has no scheme)
  host, path = stripped:match("^[^@:/]+@([^:/]+):(.+)$")
  if host and path then
    return { host = host:lower(), path = path, scheme = nil }
  end

  -- http(s)://[userinfo@]host/path  — strip userinfo to avoid token leaks
  local scheme, hostinfo, rest = stripped:match("^(https?)://([^/]+)/(.+)$")
  if scheme and hostinfo and rest then
    host = hostinfo:gsub("^[^@]+@", "")
    return { host = host:lower(), path = rest, scheme = scheme }
  end

  return nil, "unrecognized remote url: " .. url
end

---Runs `git remote get-url origin` in cwd and parses the result.
---@return {host: string, path: string, scheme: string|nil}|nil, string|nil
function M.detect()
  local out = vim.fn.systemlist({ "git", "remote", "get-url", "origin" })
  if vim.v.shell_error ~= 0 or not out or #out == 0 then
    return nil, "git remote get-url origin failed"
  end
  return M.parse(out[1])
end

return M
