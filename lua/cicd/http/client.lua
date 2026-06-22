-- Async HTTP client built on `vim.system` + the `curl` binary.
--
-- We deliberately do NOT use plenary.curl: when curl exits non-zero
-- (no network, DNS fail, timeout) plenary raises an unhandled error from a
-- libuv callback, which bypasses pcall and surfaces as a stack trace. With
-- vim.system we get the exit code in our completion handler and can map it
-- to a human-readable message.
--
-- Contract: cb receives { ok, status, body, headers, err }. Network failures
-- and non-2xx responses both set ok=false with err populated; cb always runs
-- on the main loop.

local M = {}

local CURL_EXIT_MESSAGES = {
  [3] = "malformed URL",
  [5] = "couldn't resolve proxy",
  [6] = "couldn't resolve host",
  [7] = "could not connect (offline / VPN?)",
  [22] = "HTTP error returned",
  [28] = "request timed out",
  [35] = "SSL handshake failed",
  [47] = "too many redirects",
  [52] = "empty reply from server",
  [56] = "network connection reset",
  [60] = "SSL certificate problem",
  [77] = "CA certificate read error",
}

---@param status number|nil
---@return string
function M.describe_error(status)
  if status == 401 then return "auth failed (check ~/.netrc or token)" end
  if status == 403 then return "insufficient token scope (need api)" end
  if status == 404 then return "not found" end
  if status == 429 then return "rate limited" end
  if status and status >= 500 then return "server error " .. status end
  return "HTTP " .. tostring(status or "?")
end

---@param code integer  curl process exit code
---@return string
function M.describe_curl_exit(code)
  return CURL_EXIT_MESSAGES[code] or ("curl exit code " .. code)
end

---URL-encode a string for use as a path segment / query value.
---vim.uri_encode("rfc3986") leaves "/" and a few other reserved chars alone,
---which breaks GitLab's URL-encoded project identifiers (group/sub/repo must
---become group%2Fsub%2Frepo). We encode every byte that isn't in the
---unreserved set (alpha / digit / "-" / "." / "_" / "~").
---@param s string
---@return string
function M.uri_encode(s)
  return (s:gsub("[^%w%-_%.~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

local function build_query_string(query)
  if not query or vim.tbl_isempty(query) then return "" end
  local parts = {}
  for k, v in pairs(query) do
    table.insert(parts, M.uri_encode(tostring(k)) .. "=" .. M.uri_encode(tostring(v)))
  end
  return "?" .. table.concat(parts, "&")
end

local function build_args(opts)
  local args = { "curl", "--silent", "--include", "--max-time", "30",
                 "-X", (opts.method or "GET"):upper() }
  -- Follow redirects (e.g. GitHub's per-job log endpoint 302s to a pre-signed
  -- blob URL). parse_response already restarts on each fresh HTTP/ status line,
  -- so the final 200 body is recovered correctly.
  if opts.follow_redirects then
    table.insert(args, "--location")
  end
  if opts.headers then
    for k, v in pairs(opts.headers) do
      table.insert(args, "-H")
      table.insert(args, k .. ": " .. v)
    end
  end
  if opts.body then
    table.insert(args, "--data")
    table.insert(args, opts.body)
  end
  table.insert(args, opts.url .. build_query_string(opts.query))
  return args
end

---Parses a curl --include response into status/body/headers.
---Walks the stream line-by-line so that blank lines or "HTTP/..." substrings
---inside the JSON body never get mistaken for the header/body separator
---(GitHub for example pretty-prints empty arrays as "[\n\n  ]"). Handles
---1xx preludes by restarting at every fresh status line.
---@param raw string
---@return integer|nil status, string|nil body, table|nil headers
local function parse_response(raw)
  if not raw or raw == "" then return nil end

  local pos = 1
  local len = #raw
  local status
  local headers = {}

  while pos <= len do
    -- Find end of current line (CRLF or LF).
    local nl = raw:find("\n", pos, true)
    local line, line_end
    if not nl then
      line = raw:sub(pos)
      line_end = len + 1
    else
      local stop = nl - 1
      if stop >= pos and raw:sub(stop, stop) == "\r" then stop = stop - 1 end
      line = raw:sub(pos, stop)
      line_end = nl + 1
    end

    if line == "" then
      -- Blank line ends the current header block. If a status line follows,
      -- it was a 1xx prelude — restart. Otherwise the rest is body.
      local peek = raw:sub(line_end, line_end + 4)
      if peek == "HTTP/" then
        status = nil
        headers = {}
        pos = line_end
      else
        return status, raw:sub(line_end), headers
      end
    else
      local code = line:match("^HTTP/[%d%.]+ (%d+)")
      if code then
        status = tonumber(code)
        headers = {}
      else
        local k, v = line:match("^([^:]+):%s*(.-)%s*$")
        if k then headers[k:lower()] = v end
      end
      pos = line_end
    end
  end

  -- Stream ended inside the header block (no body) — still a valid response.
  return status, "", headers
end

---@param opts { url: string, method: string?, headers: table?, query: table?, body: string?, follow_redirects: boolean? }
---@param cb fun(result: { ok: boolean, status: number?, body: string?, headers: table?, err: string? })
function M.request(opts, cb)
  local args = build_args(opts)
  local ok, err = pcall(vim.system, args, { text = true }, function(out)
    vim.schedule(function()
      if out.code ~= 0 then
        cb({ ok = false, err = M.describe_curl_exit(out.code) })
        return
      end
      local status, body, headers = parse_response(out.stdout or "")
      if not status then
        cb({ ok = false, err = "malformed response" })
        return
      end
      if status >= 200 and status < 300 then
        cb({ ok = true, status = status, body = body, headers = headers })
      else
        cb({
          ok = false, status = status, body = body, headers = headers,
          err = M.describe_error(status),
        })
      end
    end)
  end)

  if not ok then
    vim.schedule(function() cb({ ok = false, err = "curl invocation failed: " .. tostring(err) }) end)
  end
end

---Decode JSON body; returns the value or nil, err.
---@param body string|nil
---@return any|nil, string|nil
function M.decode_json(body)
  if not body or body == "" then return nil, "empty body" end
  local ok, val = pcall(vim.json.decode, body)
  if not ok then return nil, "json decode failed" end
  return val
end

---Case-insensitive header lookup. Headers from this client are normalized to
---a lowercase-keyed dict, but we tolerate plenary-style list-of-strings too.
---@param headers any
---@param name string
---@return string|nil
function M.get_header(headers, name)
  if not headers or not name then return nil end
  local target = name:lower()
  if type(headers) == "table" then
    for k, v in pairs(headers) do
      if type(k) == "string" and k:lower() == target then return v end
    end
    for _, line in ipairs(headers) do
      if type(line) == "string" then
        local k, v = line:match("^([^:]+):%s*(.-)%s*$")
        if k and k:lower() == target then return v end
      end
    end
  end
  return nil
end

return M
