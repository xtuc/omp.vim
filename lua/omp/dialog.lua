local state = require("omp.state")
local append = require("omp.transcript").append

local M = {}

local function dismiss(pending)
  if pending.win and vim.api.nvim_win_is_valid(pending.win) then
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
  dismiss(pending)
end

function M.clear()
  for id in pairs(state.pending) do cancel(id) end
end

local function respond(request, pending, result, send)
  if state.pending[request.id] ~= pending then return end
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

local function choose(request, lines, first, send, result)
  local buf, win, pending = open_float(request, lines, send, false)
  vim.api.nvim_win_set_cursor(win, { first, 0 })
  vim.keymap.set("n", "<CR>", function()
    if state.pending[request.id] ~= pending or not vim.api.nvim_win_is_valid(win) then return end
    local value = result(vim.api.nvim_win_get_cursor(win)[1] - first + 1)
    if value then respond(request, pending, value, send) end
  end, { buffer = buf })
end

function M.handle(request, send)
  if request.method == "cancel" then
    cancel(request.targetId)
  elseif request.method == "notify" then
    append({ "Agent: " .. request.message })
  elseif request.method == "set_editor_text" then
    vim.api.nvim_buf_set_lines(state.prompt, 0, -1, false, vim.split(request.text, "\n", { plain = true }))
  elseif request.method == "select" then
    local lines = {}
    for i, option in ipairs(request.options) do
      local detail = request.optionDetails and request.optionDetails[i]
      lines[i] = option .. (detail and detail.description and " — " .. detail.description or "")
    end
    choose(request, lines, 1, send, function(index)
      local value = request.options[index]
      return value and { value = value } or nil
    end)
  elseif request.method == "confirm" then
    local lines = vim.split(request.message or "", "\n", { plain = true })
    lines[#lines + 1] = ""
    local first = #lines + 1
    lines[first], lines[first + 1] = "Reject", "Approve"
    choose(request, lines, first, send, function(index)
      if index < 1 or index > 2 then return nil end
      return { confirmed = index == 2 }
    end)
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
