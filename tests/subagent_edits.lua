vim.opt.rtp:append(vim.fn.getcwd())

local state = require("omp.state")
state.job = true
state.ready = true
state.running_tasks = {}
state.session_name = "subagent edit smoke"
require("omp.ui").open()

local rpc = require("omp.rpc")
local handle
for index = 1, 20 do
  local name, value = debug.getupvalue(rpc.start, index)
  if name == "handle" then handle = value; break end
end
assert(handle, "RPC event handler not found")

local file = vim.fn.tempname() .. ".txt"
vim.fn.writefile({ "before" }, file)
vim.cmd("edit " .. vim.fn.fnameescape(file))
local buffer = vim.api.nvim_get_current_buf()

local function edit(id, index, label, tool, new_text)
  handle({ type = "subagent_lifecycle", payload = {
    id = id, index = index, status = "started", description = label,
  } })
  handle({ type = "subagent_event", payload = { id = id, event = {
    type = "tool_execution_start", toolCallId = id .. "-edit", toolName = tool,
    args = { i = "Updating " .. label }, intent = "Updating " .. label,
  } } })
  local old_text = vim.fn.readfile(file)[1]
  vim.fn.writefile({ new_text }, file)
  handle({ type = "subagent_event", payload = { id = id, event = {
    type = "tool_execution_end", toolCallId = id .. "-edit", toolName = tool,
    result = { details = { perFileResults = { {
      path = file, diff = "--- a/file\n+++ b/file\n@@ -1 +1 @@\n-" .. old_text .. "\n+" .. new_text,
    } } } },
  } } })
end

edit("agent-1", 1, "Alpha", "edit", "first")
assert(vim.api.nvim_buf_get_lines(buffer, 0, -1, false)[1] == "first", "clean buffer did not reload")
edit("agent-2", 2, "Beta", "write", "second")
local lines = vim.api.nvim_buf_get_lines(state.transcript, 0, -1, false)
local text = table.concat(lines, "\n")
assert(text:find("Diff: Subagent #1 (Alpha) · " .. file, 1, true), "first diff not attributed")
assert(text:find("Diff: Subagent #2 (Beta) · " .. file, 1, true), "second diff not attributed")
assert(text:find("+first", 1, true) and text:find("+second", 1, true), "agent diffs not rendered")
assert(vim.api.nvim_buf_get_lines(buffer, 0, -1, false)[1] == "second", "later edit did not reload")

vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "unsaved" })
edit("agent-3", 3, "Gamma", "edit", "third")
assert(vim.api.nvim_buf_get_lines(buffer, 0, -1, false)[1] == "unsaved", "unsaved buffer overwritten")
vim.fn.delete(file)
print("subagent edits: passed")
