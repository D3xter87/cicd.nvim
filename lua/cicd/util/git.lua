-- Synchronous git helpers used by the cicd controller and command parsers.
-- Wrapping `git` here keeps `controller.lua` and `plugins/git/cicd.lua` free
-- of duplicated `vim.fn.systemlist({ "git", ... })` boilerplate.

local M = {}

local function trim(s) return (s or ""):gsub("%s+$", "") end

---Current branch name (short ref), or "" if detached / not a git repo.
---@return string
function M.current_branch()
  local out = vim.fn.systemlist({ "git", "rev-parse", "--abbrev-ref", "HEAD" })
  if vim.v.shell_error ~= 0 or not out or #out == 0 then return "" end
  return trim(out[1])
end

---Full 40-char SHA of HEAD, or nil if no commit / not a repo.
---@return string|nil
function M.head_sha()
  local out = vim.fn.systemlist({ "git", "rev-parse", "HEAD" })
  if vim.v.shell_error ~= 0 or not out or #out == 0 then return nil end
  return trim(out[1])
end

---Test whether `arg` is an existing commit object in the current repo.
---Uses `git cat-file -e <arg>^{commit}` — peels tags and rejects trees/blobs.
---Caveat: also succeeds for branch/tag names (they peel to commits). Callers
---that want a strict SHA-ish classification should check `is_branch`/`is_tag`
---first.
---@param arg string
---@return boolean
function M.is_commit(arg)
  if not arg or arg == "" then return false end
  vim.fn.system({ "git", "cat-file", "-e", arg .. "^{commit}" })
  return vim.v.shell_error == 0
end

---Test whether `arg` matches an existing local branch or `origin/<arg>`
---remote-tracking branch.
---@param arg string
---@return boolean
function M.is_branch(arg)
  if not arg or arg == "" then return false end
  vim.fn.system({ "git", "show-ref", "--verify", "--quiet", "refs/heads/" .. arg })
  if vim.v.shell_error == 0 then return true end
  vim.fn.system({ "git", "show-ref", "--verify", "--quiet", "refs/remotes/origin/" .. arg })
  return vim.v.shell_error == 0
end

---Test whether `arg` matches an existing tag (annotated or lightweight).
---@param arg string
---@return boolean
function M.is_tag(arg)
  if not arg or arg == "" then return false end
  vim.fn.system({ "git", "show-ref", "--verify", "--quiet", "refs/tags/" .. arg })
  return vim.v.shell_error == 0
end

---Resolve any rev-spec (short SHA, HEAD~3, tag, etc.) to a full SHA.
---@param arg string
---@return string|nil
function M.resolve_full_sha(arg)
  if not arg or arg == "" then return nil end
  local out = vim.fn.systemlist({ "git", "rev-parse", arg })
  if vim.v.shell_error ~= 0 or not out or #out == 0 then return nil end
  return trim(out[1])
end

---Short SHAs of the last N commits on the current branch (oldest-first not
---guaranteed; rg.: --pretty=%h returns newest-first which is fine for
---completion). Returns {} on error.
---@param n integer|nil  default 20
---@return string[]
function M.recent_short_shas(n)
  n = n or 20
  local out = vim.fn.systemlist({ "git", "log", "--pretty=%h", "-n", tostring(n) })
  if vim.v.shell_error ~= 0 or not out then return {} end
  local res = {}
  for _, s in ipairs(out) do
    s = trim(s)
    if s ~= "" then table.insert(res, s) end
  end
  return res
end

return M
