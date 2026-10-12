local state = require("omp.state")
local append = require("omp.transcript").append
local approvals = require("omp.approvals")

local M = {}
local choice_queue = {}
local active_choice
local clearing = false
local show_next
local selection_ns = vim.api.nvim_create_namespace("omp_dialog_selection")

local function dismiss(pending)
  if pending.inline then
    local win = pending.win
    if pending.autocmd then vim.api.nvim_del_autocmd(pending.autocmd) end
    if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == pending.buf then
      vim.api.nvim_win_set_buf(win, state.prompt)
      vim.wo[win].cursorline = pending.cursorline
      vim.wo[win].linebreak = pending.linebreak
      vim.wo[win].winfixheight = false
      vim.api.nvim_win_set_height(win, pending.height)
      vim.wo[win].winfixheight = pending.winfixheight
      if vim.api.nvim_get_current_win() == win and pending.previous_win
        and vim.api.nvim_win_is_valid(pending.previous_win) then
        vim.api.nvim_set_current_win(pending.previous_win)
        if pending.was_insert then vim.cmd("startinsert") end
      end
    end
  elseif pending.win and vim.api.nvim_win_is_valid(pending.win) then
    vim.api.nvim_win_close(pending.win, true)
  end
  if pending.buf and vim.api.nvim_buf_is_valid(pending.buf) then
    vim.api.nvim_buf_delete(pending.buf, { force = true })
  end
end

local function cancel(id)
  local pending = state.pending[id]
  if not pending then return end
  state.pending[id] = nil
  if active_choice == pending then
    active_choice = nil
    dismiss(pending)
    if not clearing then show_next() end
  elseif pending.inline then
    for i, queued in ipairs(choice_queue) do
      if queued == pending then table.remove(choice_queue, i) break end
    end
  else
    dismiss(pending)
  end
end

function M.clear()
  clearing = true
  for id in pairs(state.pending) do cancel(id) end
  choice_queue = {}
  clearing = false
end

local function respond(request, pending, result, send)
  if state.pending[request.id] ~= pending then return end
  if result.value == "Approve" and approvals.eligible(request) then
    local ok, err = approvals.remember(request)
    if not ok then append({ "Approved once; could not save project grant: " .. tostring(err) }) end
  end
  cancel(request.id)
  send(vim.tbl_extend("force", { type = "extension_ui_response", id = request.id }, result))
end

local function dismissal(request)
  return request.method == "confirm" and { confirmed = false } or { cancelled = true }
end

local function track(request, buf, win, send)
  cancel(request.id)
  local pending = { buf = buf, win = win }
  state.pending[request.id] = pending
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win), once = true,
    callback = function()
      pending.win = nil
      respond(request, pending, dismissal(request), send)
    end,
  })
  return pending
end

local function open_float(request, lines, send, editable)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  if not editable then vim.bo[buf].modifiable = false end
  local width = math.max(1, math.min(80, vim.o.columns - 4))
  local height = math.max(1, math.min(#lines, 12, vim.o.lines - 4))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", row = math.max(0, math.floor((vim.o.lines - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width, height = height, border = "single", title = request.title,
  })
  vim.wo[win].wrap = true
  vim.wo[win].cursorline = not editable
  local pending = track(request, buf, win, send)
  local function cancelled() respond(request, pending, dismissal(request), send) end
  vim.keymap.set("n", "q", cancelled, { buffer = buf })
  vim.keymap.set("n", "<Esc>", cancelled, { buffer = buf })
  return buf, win, pending
end

show_next = function()
  if active_choice or #choice_queue == 0 then return end
  local pending = table.remove(choice_queue, 1)
  local request, send = pending.request, pending.send
  local win = state.prompt_win
  if not win or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= state.prompt then
    require("omp.ui").open()
    win = state.prompt_win
  end
  local title = vim.split(request.title or "", "\n", { plain = true })
  local lines = { title[1] }
  local first = 2
  local tool_approval = request.method == "select" and #request.options == 2
    and request.options[1] == "Approve" and request.options[2] == "Deny"
  local options = request.options
  if request.method == "select" then
    for i, option in ipairs(options) do
      local detail = request.optionDetails and request.optionDetails[i]
      local label = tool_approval and i == 2 and "Reject" or option
      local key = tool_approval and (i == 1 and " [a]" or " [r]") or ""
      lines[#lines + 1] = label .. key .. (detail and detail.description and " — " .. detail.description or "")
    end
  else
    lines[2], lines[3] = "Reject", "Approve"
  end
  lines[#lines + 1] = ""
  for i = 2, #title do lines[#lines + 1] = title[i] end
  if request.method == "confirm" then
    vim.list_extend(lines, vim.split(request.message or "", "\n", { plain = true }))
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.b[buf].airline_disable_statusline = 1
  pending.buf, pending.win = buf, win
  pending.height = vim.api.nvim_win_get_height(win)
  pending.winfixheight = vim.wo[win].winfixheight
  pending.linebreak = vim.wo[win].linebreak
  pending.cursorline = vim.wo[win].cursorline
  pending.previous_win = vim.api.nvim_get_current_win()
  pending.was_insert = vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
  active_choice = pending
  vim.wo[win].winfixheight = false
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].linebreak = true
  local width = math.max(1, vim.api.nvim_win_get_width(win))
  local rows = 0
  for _, line in ipairs(lines) do
    rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width))
  end
  vim.api.nvim_win_set_height(win, math.min(rows, math.max(4, vim.o.lines - 6)))
  vim.wo[win].cursorline = true
  vim.api.nvim_set_current_win(win)
  local selected = tool_approval and #options or 1
  vim.api.nvim_win_set_cursor(win, { first + selected - 1, 0 })
  if pending.was_insert then vim.cmd("stopinsert") end
  local marker
  local function mark_selection()
    if state.pending[request.id] ~= pending or not vim.api.nvim_win_is_valid(win) then return end
    if marker then vim.api.nvim_buf_del_extmark(buf, selection_ns, marker) end
    local index = vim.api.nvim_win_get_cursor(win)[1] - first + 1
    if index >= 1 and index <= (request.method == "select" and #options or 2) then
      marker = vim.api.nvim_buf_set_extmark(buf, selection_ns, first + index - 2, 0,
        { virt_text = { { "> ", "WarningMsg" } }, virt_text_pos = "inline" })
    else
      marker = nil
    end
  end
  mark_selection()
  vim.api.nvim_create_autocmd("CursorMoved", { buffer = buf, callback = mark_selection })
  pending.autocmd = vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win), once = true,
    callback = function()
      pending.autocmd = nil
      pending.win = nil
      respond(request, pending, dismissal(request), send)
    end,
  })
  vim.keymap.set("n", "<CR>", function()
    if state.pending[request.id] ~= pending or not vim.api.nvim_win_is_valid(win) then return end
    local index = vim.api.nvim_win_get_cursor(win)[1] - first + 1
    if request.method == "select" then
      local value = options[index]
      if value then respond(request, pending, { value = value }, send) end
    elseif index == 1 or index == 2 then
      respond(request, pending, { confirmed = index == 2 }, send)
    end
  end, { buffer = buf })
  local function cancel_choice() respond(request, pending, dismissal(request), send) end
  vim.keymap.set("n", "q", cancel_choice, { buffer = buf })
  vim.keymap.set("n", "<Esc>", cancel_choice, { buffer = buf })
  if tool_approval then
    vim.keymap.set("n", "a", function() respond(request, pending, { value = "Approve" }, send) end, { buffer = buf })
    vim.keymap.set("n", "r", function() respond(request, pending, { value = "Deny" }, send) end, { buffer = buf })
  elseif request.method == "confirm" then
    vim.keymap.set("n", "a", function() respond(request, pending, { confirmed = true }, send) end, { buffer = buf })
    vim.keymap.set("n", "r", function() respond(request, pending, { confirmed = false }, send) end, { buffer = buf })
  end
end

function M.focus_confirmation()
  local pending = active_choice
  if not pending or not pending.win or not vim.api.nvim_win_is_valid(pending.win)
    or vim.api.nvim_win_get_buf(pending.win) ~= pending.buf then return false end
  vim.api.nvim_set_current_win(pending.win)
  return true
end


function M.handle(request, send)
  if request.method == "cancel" then
    cancel(request.targetId)
  elseif request.method == "notify" then
    append({ "Agent: " .. request.message })
  elseif request.method == "set_editor_text" then
    vim.api.nvim_buf_set_lines(state.prompt, 0, -1, false, vim.split(request.text, "\n", { plain = true }))
  elseif request.method == "select" or request.method == "confirm" then
    cancel(request.id)
    if approvals.eligible(request) then
      local saved, err = approvals.match(request)
      if err then append({ "Approval list unreadable: " .. tostring(err) }) end
      if saved then
        append({ "Reused project approval: " .. request.title })
        send({ type = "extension_ui_response", id = request.id, value = "Approve" })
        return
      end
    end
    local pending = { inline = true, request = request, send = send }
    state.pending[request.id] = pending
    choice_queue[#choice_queue + 1] = pending
    show_next()
  elseif request.method == "input" then
    local buf, _, pending = open_float({ id = request.id, title = request.title
      .. (request.placeholder and " (" .. request.placeholder .. ")" or "") .. ":" }, { "" }, send, true)
    local function submit()
      if state.pending[request.id] ~= pending then return end
      local value = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
      vim.cmd("stopinsert")
      respond(request, pending, { value = value }, send)
    end
    vim.keymap.set("n", "<CR>", submit, { buffer = buf })
    vim.keymap.set("i", "<CR>", submit, { buffer = buf })
    vim.keymap.set("i", "<Esc>", function()
      vim.cmd("stopinsert")
      respond(request, pending, { cancelled = true }, send)
    end, { buffer = buf })
    vim.cmd("startinsert")
  elseif request.method == "editor" then
    local buf = vim.api.nvim_create_buf(false, true)
    local lines = vim.split(request.prefill or "", "\n", { plain = true })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local width = math.max(1, math.min(80, vim.o.columns - 4))
    local height = math.max(1, math.min(12, vim.o.lines - 4))
    local win = vim.api.nvim_open_win(buf, true, {
      relative = "editor", row = math.max(0, math.floor((vim.o.lines - height) / 2)),
      col = math.max(0, math.floor((vim.o.columns - width) / 2)),
      width = width, height = height, border = "single", title = request.title,
    })
    local pending = track(request, buf, win, send)
    vim.keymap.set("n", "<CR>", function()
      respond(request, pending, { value = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") }, send)
    end, { buffer = buf })
    vim.keymap.set("n", "q", function() respond(request, pending, { cancelled = true }, send) end, { buffer = buf })
  elseif request.method == "open_url" then
    append({ request.instructions or "Open URL:", request.launchUrl or request.url })
  end
end

return M
