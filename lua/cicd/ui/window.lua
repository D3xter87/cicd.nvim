-- Floating window lifecycle. Window close delegates timer teardown to the
-- caller via an on_close callback (injected by the controller), so this
-- module does not need to know about monitor.lua.

local M = {}

local state_mod = require("cicd.state")

local TITLES = {
  gitlab = " GitLab CI/CD ",
  github = " GitHub Actions ",
}

local FOOTERS = {
  gitlab = " h/l:stages  j/k:jobs  /:filter  <CR>:act  a:act-all  r:refresh  q:close ",
  github = " h/l:workflows  j/k:jobs  /:filter  <CR>:act  a:act-all  r:refresh  q:close ",
}

local function title_for(provider)
  local base = TITLES[provider] or " CI/CD Pipeline "
  local ref = state_mod.state.ref
  if ref and ref.kind == "sha" and ref.short then
    return base:gsub("%s+$", "") .. " — commit " .. ref.short .. " "
  end
  return base
end
local function footer_for(provider) return FOOTERS[provider] or FOOTERS.gitlab end

local RESIZE_GROUP = "CicdWindowResize"

---Floating geometry derived from the current editor size (80% × 70%, centered).
local function geometry()
  local width = math.floor(vim.o.columns * 0.8)
  local height = math.floor(vim.o.lines * 0.7)
  return {
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
  }
end

---Creates the floating pipeline browser window + buffer.
---@return integer buf, integer win
function M.create()
  local state = state_mod.state

  local geo = geometry()
  local width, height = geo.width, geo.height
  local row, col = geo.row, geo.col

  state.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = state.buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = state.buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = state.buf })
  vim.api.nvim_set_option_value("filetype", "cicd", { buf = state.buf })

  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = title_for(state.provider_name),
    title_pos = "center",
    footer = footer_for(state.provider_name),
    footer_pos = "center",
  })

  vim.api.nvim_set_option_value("cursorline", true, { win = state.win })
  vim.api.nvim_set_option_value("wrap", false, { win = state.win })
  vim.api.nvim_set_option_value("number", false, { win = state.win })
  vim.api.nvim_set_option_value("relativenumber", false, { win = state.win })

  -- Keep the float centered and re-flow its contents when the editor resizes.
  local group = vim.api.nvim_create_augroup(RESIZE_GROUP, { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      if not (state.win and vim.api.nvim_win_is_valid(state.win)) then return end
      vim.api.nvim_win_set_config(state.win, vim.tbl_extend("force", { relative = "editor" }, geometry()))
      require("cicd.ui.render").render()
    end,
  })

  return state.buf, state.win
end

---Closes the window, invokes the on_close callback for timer cleanup, and
---resets UI state (single-job monitoring state lives elsewhere and survives).
---@param on_close fun()|nil
function M.close(on_close)
  local state = state_mod.state
  if on_close then
    pcall(on_close)
  end
  pcall(vim.api.nvim_del_augroup_by_name, RESIZE_GROUP)
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state_mod.reset()
end

return M
