-- Floating viewer for a single job's log / trace. Independent of the pipeline
-- browser window: it owns its own scratch buffer + float and restores focus to
-- the previous window on close.
--
-- Supports periodic auto-refresh (running jobs keep producing output) via an
-- injected fetch callback. Refresh "tails" the log — it follows new output only
-- when the cursor is already at the bottom, otherwise your scroll position is
-- preserved. `r` inside the viewer refreshes on demand.
--
-- Typical flow from the controller:
--   local view = logview.open_loading("build")          -- shows "Loading log…"
--   local function fetch(cb) provider.fetch_job_log(..., cb) end
--   fetch(function(text, err) ... logview.set_body(view, text) end)  -- first load
--   logview.attach_refresh(view, fetch, { interval = 3000, auto = true })

local M = {}

-- Strip terminal control noise so the log reads cleanly in a normal buffer:
--   * ANSI CSI sequences (colors, cursor moves): ESC [ ... <final byte>
--   * solitary ESC + single char (e.g. ESC ] OSC starts we don't expand)
--   * GitLab section markers: section_start:<ts>:<name> / section_end:<ts>:<name>
--   * carriage returns (CRLF and progress-bar \r overwrites)
---@param body string
---@return string[] lines
local function to_lines(body)
  body = body or ""
  body = body:gsub("\27%[[0-9;?]*[ -/]*[@-~]", "") -- CSI sequences
  body = body:gsub("\27[@-Z\\-_]", "")             -- other 2-byte escapes
  body = body:gsub("section_[%a]+:%d+:[%w_%-%.]+\r?", "")
  body = body:gsub("\r\n", "\n"):gsub("\r", "")
  local lines = vim.split(body, "\n", { plain = true })
  -- Drop trailing empty lines produced by final newlines / removed markers.
  while #lines > 1 and lines[#lines] == "" do
    table.remove(lines, #lines)
  end
  return lines
end

---@param buf integer
---@param lines string[]
local function set_lines(buf, lines)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

---Re-fetch and redraw. Errors are swallowed (a transient fetch failure during
---polling shouldn't replace the log with noise); the next tick retries.
---@param view table
local function do_refresh(view)
  if not view or not view.fetch then return end
  if not (view.win and vim.api.nvim_win_is_valid(view.win)) then return end
  view.fetch(function(text, err)
    if err then return end
    if view.win and vim.api.nvim_win_is_valid(view.win) then
      M.set_body(view, text or "")
    end
  end)
end

---Opens the float showing `lines` (array of strings). Returns a view handle:
---{ buf, win, prev_win, timer, fetch, loaded }.
---@param title string
---@param lines string[]
---@return table view
local function open_window(title, lines)
  local prev_win = vim.api.nvim_get_current_win()

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_set_option_value("filetype", "cicdlog", { buf = buf })

  local width = math.floor(vim.o.columns * 0.9)
  local height = math.floor(vim.o.lines * 0.8)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " log: " .. (title or "") .. " ",
    title_pos = "center",
    footer = " r:refresh  q/<Esc>:close ",
    footer_pos = "center",
  })
  vim.api.nvim_set_option_value("wrap", false, { win = win })
  vim.api.nvim_set_option_value("cursorline", true, { win = win })
  vim.api.nvim_set_option_value("number", false, { win = win })

  local view = { buf = buf, win = win, prev_win = prev_win, timer = nil, fetch = nil, loaded = false }

  set_lines(buf, lines)

  local function close()
    if view.timer then
      vim.fn.timer_stop(view.timer)
      view.timer = nil
    end
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_win_is_valid(prev_win) then
      vim.api.nvim_set_current_win(prev_win)
    end
  end

  local opts = { buffer = buf, silent = true, noremap = true }
  vim.keymap.set("n", "q", close, opts)
  vim.keymap.set("n", "<Esc>", close, opts)
  vim.keymap.set("n", "r", function() do_refresh(view) end, opts)

  return view
end

---Open the viewer immediately with a placeholder; fill it later via set_body.
---@param title string
---@return table view
function M.open_loading(title)
  return open_window(title, { "", "  Loading log…" })
end

---Replace the viewer's contents with the fetched log text. On the first load
---(and whenever the cursor is already at the bottom) it jumps to the end so the
---latest output stays in view; otherwise the scroll position is preserved.
---@param view table  handle returned by open_loading
---@param body string
function M.set_body(view, body)
  if not view or not view.buf then return end
  local lines = to_lines(body)
  if #lines == 0 or (#lines == 1 and lines[1] == "") then
    lines = { "", "  (no log available for this job)" }
  end

  -- Decide whether to follow the tail. First load always follows; afterwards,
  -- follow only if the cursor sits on the last line.
  local follow = true
  local cur
  if view.loaded and view.win and vim.api.nvim_win_is_valid(view.win) then
    local total = vim.api.nvim_buf_line_count(view.buf)
    local ok, pos = pcall(vim.api.nvim_win_get_cursor, view.win)
    if ok then
      cur = pos
      follow = pos[1] >= total
    end
  end

  set_lines(view.buf, lines)
  view.loaded = true

  if view.win and vim.api.nvim_win_is_valid(view.win) then
    local count = vim.api.nvim_buf_line_count(view.buf)
    if follow then
      pcall(vim.api.nvim_win_set_cursor, view.win, { count, 0 })
    elseif cur then
      pcall(vim.api.nvim_win_set_cursor, view.win, { math.min(cur[1], count), cur[2] })
    end
  end
end

---Wire a fetch callback into the viewer so `r` can refresh on demand, and
---optionally start a repeating timer that tails the log.
---@param view table
---@param fetch fun(cb: fun(text: string|nil, err: string|nil))
---@param opts { interval: integer?, auto: boolean? }|nil
function M.attach_refresh(view, fetch, opts)
  if not view then return end
  opts = opts or {}
  view.fetch = fetch
  if opts.auto then
    local interval = opts.interval or 3000
    view.timer = vim.fn.timer_start(interval, function()
      if not (view.win and vim.api.nvim_win_is_valid(view.win)) then
        if view.timer then
          vim.fn.timer_stop(view.timer)
          view.timer = nil
        end
        return
      end
      do_refresh(view)
    end, { ["repeat"] = -1 })
  end
end

---Convenience: open directly with a full body in one call.
---@param title string
---@param body string
---@return table view
function M.open(title, body)
  local view = open_window(title, { "" })
  M.set_body(view, body)
  return view
end

return M
