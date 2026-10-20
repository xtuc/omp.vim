vim.opt.rtp:append(vim.fn.getcwd())

local state = require("omp.state")
local tables = require("omp.tables")
state.job = true
state.session_name = "table smoke"
require("omp.ui").open()
local transcript = require("omp.transcript")
local buf, win = state.transcript, state.transcript_win

local source = "| Feature | Description | Default |\n| --- | :---: | ---: |\n| Search | Searches over all open files | enabled |"
transcript.restore_history({
  { role = "user", content = "| A | B |\n| --- | --- |\n| x | y |" },
  { role = "assistant", content = { { type = "text", text = source } } },
})
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
assert(vim.tbl_contains(lines, "| x   | y   |"))
local first = vim.fn.index(lines, "Agent") + 1
assert(first > 0)
assert(lines[first + 1]:find("Feature", 1, true))
assert(lines[first + 3]:find("Search", 1, true))
assert(vim.api.nvim_win_text_height(win, { start_row = first, end_row = #lines - 1 }).all == #lines - first)
for i = first + 1, #lines do
  assert(vim.fn.strdisplaywidth(lines[i]) <= vim.api.nvim_win_get_width(win))
end

vim.api.nvim_win_set_width(win, 60)
vim.api.nvim_exec_autocmds("WinResized", { pattern = "*" })
lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
assert(vim.tbl_contains(lines, "| Search  | Searches over all open files | enabled |"))
vim.api.nvim_win_set_width(win, 20)
vim.api.nvim_exec_autocmds("WinResized", { pattern = "*" })
lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
assert(vim.tbl_contains(lines, "Feature: Search"))
assert(vim.tbl_contains(lines, "Description: Searches over all open files"))
vim.api.nvim_win_set_width(win, 60)
vim.api.nvim_exec_autocmds("WinResized", { pattern = "*" })
lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
assert(vim.tbl_contains(lines, "| Search  | Searches over all open files | enabled |"))

local escaped, changed = tables.render({
  "| `a|b` | x\\|y |", "| --- | --- |", "| `c|d` | q\\|r |",
}, 40)
assert(changed and #escaped == 3 and escaped[3]:find("q\\|r", 1, true))
local trailing, trailing_changed = tables.render({
  "| A | B |", "| --- | --- |", "| x | y\\|",
}, 40)
assert(trailing_changed and trailing[3]:find("y\\|", 1, true))
local even, even_changed = tables.render({
  "| A | B |", "| --- | --- |", "| x\\\\|y | z |",
}, 40)
assert(even_changed and even[3] == "| x\\\\|y | z |")
local fenced, fenced_changed = tables.render({
  "```md", "| A | B |", "| --- | --- |", "| x | y |", "```",
}, 40)
assert(not fenced_changed and fenced[4] == "| x | y |")
local mixed, mixed_changed = tables.render({
  "~~~", "| A | B |", "| --- | --- |", "~~~",
  "| C | D |", "| --- | --- |", "| 字 | emoji |",
}, 30)
assert(mixed_changed and mixed[2] == "| A | B |" and mixed[7]:find("字", 1, true))
for _, row in ipairs(mixed) do
  if row:match("^|") then assert(vim.fn.strdisplaywidth(row) <= 30) end
end

print("table layout: passed")
