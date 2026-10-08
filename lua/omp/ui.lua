local state = require("omp.state")
local append = require("omp.transcript").append
local set_activity = require("omp.statusline").set_activity
local render_statusline = require("omp.statusline").render_statusline
local render_divider = require("omp.statusline").render_divider
local rpc = require("omp.rpc")
local history = require("omp.history")

local M = {}

local function history_key(direction, key)
  if not history.navigate(direction) then
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "n", false)
  end
end

function M.submit()
  if not state.prompt or not vim.api.nvim_buf_is_valid(state.prompt) then return end
  local text = table.concat(vim.api.nvim_buf_get_lines(state.prompt, 0, -1, false), "\n")
  if text:match("^%s*$") then return end
  if state.new_requested then return end
  if text:match("^%s*/new%s*$") then
    if not rpc.send({ type = "new_session" }) then return end
    state.new_requested = true
    append({ "Agent creating new session..." })
    vim.api.nvim_buf_set_lines(state.prompt, 0, -1, false, { "" })
    return
  end
  if text:match("^%s*/high%s*$") then
    if not rpc.send({ type = "set_thinking_level", level = "high" }) then return end
    history.add(text)
    vim.api.nvim_buf_set_lines(state.prompt, 0, -1, false, { "" })
    return
  end
  state.next_id = state.next_id + 1
  if not rpc.send({ id = tostring(state.next_id), type = "prompt", message = text, streamingBehavior = "steer" }) then return end
  history.add(text)
  set_activity("Working")
  local lines = { "", "You" }
  vim.list_extend(lines, vim.split(text, "\n", { plain = true }))
  append(lines, { [2] = "Question" })
  if state.transcript_win and vim.api.nvim_win_is_valid(state.transcript_win)
    and vim.api.nvim_win_get_buf(state.transcript_win) == state.transcript then
    vim.api.nvim_win_set_cursor(state.transcript_win, { vim.api.nvim_buf_line_count(state.transcript), 0 })
    vim.api.nvim_win_call(state.transcript_win, function() vim.cmd("normal! zb") end)
  end
  vim.api.nvim_buf_set_lines(state.prompt, 0, -1, false, { "" })
end

function M.abort()
  rpc.send({ type = "abort" })
end

function M.statusline()
  return render_statusline()
end

function M.divider()
  return render_divider()
end

function M.open()
  if state.prompt_win and vim.api.nvim_win_is_valid(state.prompt_win)
    and vim.api.nvim_win_get_buf(state.prompt_win) == state.prompt
    and state.transcript_win and vim.api.nvim_win_is_valid(state.transcript_win)
    and vim.api.nvim_win_get_buf(state.transcript_win) == state.transcript then
    vim.wo[state.prompt_win].statusline = "%!v:lua.require'omp'.statusline()"
    vim.wo[state.transcript_win].statusline = "%#Normal#%{repeat(' ',winwidth(0))}"
    vim.wo[state.prompt_win].winbar = "%!v:lua.require'omp'.divider()"
    vim.api.nvim_set_current_win(state.prompt_win)
    if not state.job then rpc.start() end
    return
  end
  if state.prompt_win and vim.api.nvim_win_is_valid(state.prompt_win)
    and vim.api.nvim_win_get_buf(state.prompt_win) == state.prompt then
    vim.api.nvim_win_close(state.prompt_win, true)
  end
  if state.transcript_win and vim.api.nvim_win_is_valid(state.transcript_win)
    and vim.api.nvim_win_get_buf(state.transcript_win) == state.transcript then
    vim.api.nvim_win_close(state.transcript_win, true)
  end
  if not state.transcript or not vim.api.nvim_buf_is_valid(state.transcript) then
    state.transcript = vim.api.nvim_create_buf(false, true)
    vim.bo[state.transcript].bufhidden = "hide"
    vim.b[state.transcript].airline_disable_statusline = 1
    vim.bo[state.transcript].filetype = "omp"
    if not pcall(vim.treesitter.start, state.transcript, "markdown") then
      vim.bo[state.transcript].syntax = "markdown"
    end
    vim.api.nvim_buf_set_lines(state.transcript, 0, -1, false, { "Agent starting..." })
    vim.bo[state.transcript].modifiable = false
    for _, key in ipairs({ "i", "I", "a", "A", "o", "O", "s", "S", "R", "C", "gi", "gI" }) do
      vim.keymap.set("n", key, function()
        M.open()
        vim.cmd("startinsert")
      end, { buffer = state.transcript, desc = "Edit Agent prompt" })
    end
  end
  if not state.prompt or not vim.api.nvim_buf_is_valid(state.prompt) then
    state.prompt = vim.api.nvim_create_buf(false, true)
    vim.bo[state.prompt].bufhidden = "hide"
    vim.b[state.prompt].airline_disable_statusline = 1
    vim.bo[state.prompt].filetype = "omp"
    vim.bo[state.prompt].syntax = "markdown"
    vim.keymap.set("n", "<CR>", M.submit, { buffer = state.prompt, desc = "Send prompt to Agent" })
    vim.keymap.set("n", "<C-c>", M.abort, { buffer = state.prompt, desc = "Abort Agent response" })
    for _, binding in ipairs({ { "<Up>", -1 }, { "k", -1 }, { "<Down>", 1 }, { "j", 1 } }) do
      vim.keymap.set("n", binding[1], function() history_key(binding[2], binding[1]) end,
        { buffer = state.prompt, desc = "Navigate Agent prompt history" })
    end
    for _, binding in ipairs({ { "<Up>", -1 }, { "<Down>", 1 } }) do
      vim.keymap.set("i", binding[1], function() history_key(binding[2], binding[1]) end,
        { buffer = state.prompt, desc = "Navigate Agent prompt history" })
    end
  end
  vim.cmd("botright " .. math.floor(vim.o.columns * 0.45) .. "vnew")
  state.transcript_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.transcript_win, state.transcript)
  vim.wo[state.transcript_win].wrap = true
  vim.wo[state.transcript_win].linebreak = false
  vim.wo[state.transcript_win].number = false
  vim.wo[state.transcript_win].relativenumber = false
  vim.wo[state.transcript_win].signcolumn = "no"
  vim.wo[state.transcript_win].statusline = "%#Normal#%{repeat(' ',winwidth(0))}"
  vim.cmd("belowright split")
  state.prompt_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.prompt_win, state.prompt)
  vim.wo[state.prompt_win].wrap = true
  vim.wo[state.prompt_win].linebreak = false
  vim.wo[state.prompt_win].number = false
  vim.wo[state.prompt_win].relativenumber = false
  vim.wo[state.prompt_win].signcolumn = "no"
  vim.wo[state.prompt_win].statusline = "%!v:lua.require'omp'.statusline()"
  vim.wo[state.prompt_win].winbar = "%!v:lua.require'omp'.divider()"
  vim.api.nvim_win_set_height(state.prompt_win, 4)
  vim.wo[state.prompt_win].winfixheight = true
  vim.api.nvim_set_current_win(state.prompt_win)
  if not state.job then rpc.start() end
end

return M
