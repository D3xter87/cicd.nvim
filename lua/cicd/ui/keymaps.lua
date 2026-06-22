-- Buffer-local keymaps for the pipeline browser. Callers inject action
-- callbacks (close, trigger_selected, trigger_all, refresh) so this module
-- does not couple to the controller or monitor.
--
-- Every alphanumeric key is mapped: in filter mode it appends to the filter,
-- in normal mode it executes its bound action (or is no-op). This prevents
-- Vim from interpreting letters like s/c/d/x as edit commands against our
-- scratch buffer.

local M = {}

local state_mod = require("cicd.state")
local filter_mod = require("cicd.ui.filter")
local render_mod = require("cicd.ui.render")
local nav = require("cicd.ui.navigation")

---@param actions { close: fun(), trigger_selected: fun(), trigger_all: fun(), refresh: fun(), open_job: fun(), open_pipeline: fun(), view_log: fun() }
function M.setup(actions)
  local state = state_mod.state
  local opts = { buffer = state.buf, silent = true, noremap = true }

  local function filter_or_action(char, action)
    return function()
      if state.filter_mode then
        state.filter_text = state.filter_text .. char
        filter_mod.apply(true)
      elseif action then
        action()
      end
    end
  end

  local function filter_only(char)
    return filter_or_action(char, nil)
  end

  -- Window controls
  vim.keymap.set("n", "q", filter_or_action("q", actions.close), opts)
  vim.keymap.set("n", "<Esc>", function()
    if state.filter_mode then
      filter_mod.exit()
    elseif state.filter_text ~= "" then
      filter_mod.clear()
    else
      actions.close()
    end
  end, opts)

  -- Navigation: jobs (up/down)
  vim.keymap.set("n", "j", filter_or_action("j", function() nav.move_cursor(1) end), opts)
  vim.keymap.set("n", "k", filter_or_action("k", function() nav.move_cursor(-1) end), opts)
  vim.keymap.set("n", "<Down>", function() nav.move_cursor(1) end, opts)
  vim.keymap.set("n", "<Up>", function() nav.move_cursor(-1) end, opts)

  -- Navigation: stages (left/right)
  vim.keymap.set("n", "h", filter_or_action("h", function() nav.move_stage(-1) end), opts)
  vim.keymap.set("n", "l", filter_or_action("l", function() nav.move_stage(1) end), opts)
  vim.keymap.set("n", "<Left>", function() nav.move_stage(-1) end, opts)
  vim.keymap.set("n", "<Right>", function() nav.move_stage(1) end, opts)

  -- Jump to first/last
  vim.keymap.set("n", "g", filter_only("g"), opts)
  vim.keymap.set("n", "gg", function()
    if state.filter_mode then
      state.filter_text = state.filter_text .. "g"
      filter_mod.apply(true)
      return
    end
    nav.jump_first()
  end, opts)
  vim.keymap.set("n", "G", filter_or_action("G", nav.jump_last), opts)

  -- Filter
  vim.keymap.set("n", "/", function()
    if not state.filter_mode then filter_mod.start() end
  end, opts)
  vim.keymap.set("n", "<BS>", function()
    if state.filter_mode and #state.filter_text > 0 then
      state.filter_text = state.filter_text:sub(1, -2)
      filter_mod.apply(true)
    end
  end, opts)
  vim.keymap.set("n", "<Space>", function()
    if state.filter_mode then
      state.filter_text = state.filter_text .. " "
      filter_mod.apply(true)
    end
  end, opts)

  -- Actions
  vim.keymap.set("n", "<CR>", function()
    if state.filter_mode then
      state.filter_mode = false
      render_mod.render()
    else
      actions.trigger_selected()
    end
  end, opts)
  vim.keymap.set("n", "a", filter_or_action("a", actions.trigger_all), opts)
  vim.keymap.set("n", "r", filter_or_action("r", actions.refresh), opts)

  -- Open / log
  vim.keymap.set("n", "o", filter_or_action("o", actions.open_job), opts)
  vim.keymap.set("n", "O", filter_or_action("O", actions.open_pipeline), opts)
  vim.keymap.set("n", "L", filter_or_action("L", actions.view_log), opts)

  -- Capture remaining keys so Vim doesn't interpret them as edit commands.
  -- (o / O / L are bound above, so they're excluded here.)
  local remaining_lower = { "b", "c", "d", "e", "f", "i", "m", "n", "p", "s", "t", "u", "v", "w", "x", "y", "z" }
  for _, char in ipairs(remaining_lower) do
    vim.keymap.set("n", char, filter_only(char), opts)
  end
  local remaining_upper = { "A", "B", "C", "D", "E", "F", "H", "I", "J", "K", "M", "N", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z" }
  for _, char in ipairs(remaining_upper) do
    vim.keymap.set("n", char, filter_only(char), opts)
  end
  for i = 0, 9 do
    vim.keymap.set("n", tostring(i), filter_only(tostring(i)), opts)
  end
  for _, char in ipairs({ "-", "_", "." }) do
    vim.keymap.set("n", char, filter_only(char), opts)
  end
end

return M
