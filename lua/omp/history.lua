local state = require("omp.state")

local M = {}
local limit = 100

function M.add(text)
  if not text:match("%S") then return end
  local entries = state.prompt_history or {}
  for i = #entries, 1, -1 do
    if entries[i] == text then table.remove(entries, i) end
  end
  table.insert(entries, 1, text)
  if #entries > limit then table.remove(entries) end
  state.prompt_history = entries
  state.history_index = nil
  state.history_draft = nil
end

function M.restore(prompts)
  state.prompt_history = {}
  state.history_index = nil
  state.history_draft = nil
  for _, text in ipairs(prompts) do M.add(text) end
end

function M.navigate(direction)
  local buf = state.prompt
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return false end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  if direction < 0 and row > 1 or direction > 0 and row < #lines then return false end

  local entries = state.prompt_history or {}
  local index = state.history_index
  local current = table.concat(lines, "\n")
  if index and current ~= entries[index] then
    index = nil
    state.history_index = nil
    state.history_draft = nil
  end
  if direction < 0 then
    if #entries == 0 then return false end
    if index == #entries then return true end
    if not index then state.history_draft = current end
    index = (index or 0) + 1
  else
    if not index then return false end
    index = index - 1
  end

  local text = index > 0 and entries[index] or state.history_draft
  state.history_index = index > 0 and index or nil
  if index == 0 then state.history_draft = nil end
  local replacement = vim.split(text, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, replacement)
  local target = direction < 0 and 1 or #replacement
  vim.api.nvim_win_set_cursor(0, { target, direction < 0 and 0 or #replacement[target] })
  return true
end

return M
