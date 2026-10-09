local M = {}

local state = require('omp.state')
local transcript_hl = vim.api.nvim_create_namespace("omp_transcript")
local reasoning_hl = vim.api.nvim_create_namespace("omp_reasoning")
local pending_stream
local flush_stream

local function should_follow()
  local win = state.transcript_win
  return win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == state.transcript
    and (vim.api.nvim_get_current_win() == state.prompt_win
      or vim.api.nvim_win_get_cursor(win)[1] == vim.api.nvim_buf_line_count(state.transcript))
end

local function scroll_to_end(last_line)
  local buf, win = state.transcript, state.transcript_win
  if not buf or not vim.api.nvim_buf_is_valid(buf) or not win or not vim.api.nvim_win_is_valid(win)
    or vim.api.nvim_win_get_buf(win) ~= buf then return end
  local last = vim.api.nvim_buf_line_count(buf)
  local line = last_line or vim.api.nvim_buf_get_lines(buf, last - 1, last, false)[1] or ""
  vim.api.nvim_win_set_cursor(win, { last, #line })
end

local function append(lines, colors)
  if not state.transcript or not vim.api.nvim_buf_is_valid(state.transcript) then return end
  for _, line in ipairs(lines) do
    if line:find("\n", 1, true) then
      local split_lines, split_colors = {}, {}
      for index, text in ipairs(lines) do
        for _, part in ipairs(vim.split(text, "\n", { plain = true })) do
          split_lines[#split_lines + 1] = part
          split_colors[#split_lines] = colors and colors[index]
        end
      end
      lines, colors = split_lines, split_colors
      break
    end
  end
  if pending_stream then flush_stream() end
  local old_count = vim.api.nvim_buf_line_count(state.transcript)
  local follow = should_follow()
  vim.bo[state.transcript].modifiable = true
  vim.api.nvim_buf_set_lines(state.transcript, -1, -1, false, lines)
  vim.bo[state.transcript].modifiable = false
  for index, group in pairs(colors or {}) do
    if #lines[index] > 0 then
      vim.api.nvim_buf_set_extmark(state.transcript, transcript_hl, old_count + index - 1, 0,
        { end_col = #lines[index], hl_group = group, priority = 150 })
    end
  end
  if follow then scroll_to_end(lines[#lines]) end
end

local function append_todos(phases)
  local lines, colors = { "", "Todo" }, { [2] = "Title" }
  local symbols = { pending = "○", in_progress = "●", completed = "✓", blocked = "!", abandoned = "×" }
  local groups = { pending = "Comment", in_progress = "Statement", completed = "String", blocked = "DiagnosticWarn", abandoned = "Comment" }
  for _, phase in ipairs(phases) do
    lines[#lines + 1] = phase.name
    colors[#lines] = "Identifier"
    for _, task in ipairs(phase.tasks) do
      lines[#lines + 1] = "  " .. (symbols[task.status] or "○") .. " " .. task.content
        .. (task.blocker and " — " .. task.blocker or "")
      colors[#lines] = groups[task.status] or "Comment"
    end
  end
  append(lines, colors)
end

local function append_block(title, body, group, diff)
  local lines, colors = { "", "── " .. title .. " ──" }, { [2] = group }
  for _, text in ipairs(body) do
    lines[#lines + 1] = text
    if type(diff) == "table" then
      colors[#lines] = diff[#lines - 2] or "Comment"
    elseif diff then
      colors[#lines] = text:match("^%+") and not text:match("^%+%+%+") and "DiffAdd"
        or text:match("^%-") and not text:match("^%-%-%-") and "DiffDelete"
        or text:match("^@@") and "DiffChange" or "Comment"
    elseif group == "Comment" then
      colors[#lines] = group
    end
  end
  append(lines, colors)
end

local function append_reasoning(text)
  local lines, colors = { "" }, {}
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    lines[#lines + 1] = line
    colors[#lines] = "Comment"
  end
  append(lines, colors)
end


local function difft_preview(file)
  if vim.fn.executable("difft") == 0 then return nil end
  if type(file.oldText) ~= "string" or type(file.newText) ~= "string" then return nil end
  local ext = vim.fn.fnamemodify(file.path or "", ":e")
  local suffix = ext ~= "" and "." .. ext or ""
  local old_path, new_path = vim.fn.tempname() .. suffix, vim.fn.tempname() .. suffix
  local function write_snapshot(path, text)
    local fd = vim.uv.fs_open(path, "w", 384)
    if not fd then return false end
    local written = vim.uv.fs_write(fd, text, 0)
    vim.uv.fs_close(fd)
    return written == #text
  end
  local old_text, new_text = file.oldText or "", file.newText or ""
  local written = write_snapshot(old_path, old_text) and write_snapshot(new_path, new_text)
  local ok, output
  if written then
    local width = state.transcript_win and vim.api.nvim_win_is_valid(state.transcript_win)
      and vim.api.nvim_win_get_width(state.transcript_win) or vim.o.columns
    ok, output = pcall(vim.fn.system, {
      "difft", "--color=never", "--display=inline", "--width=" .. width, old_path, new_path,
    })
  end
  vim.uv.fs_unlink(old_path)
  vim.uv.fs_unlink(new_path)
  if not ok or vim.v.shell_error ~= 0 or not output then return nil end
  local body = output:match("^[^\n]*\n(.*)")
  if not body or body == "" then return nil end
  local lines = vim.split(body:gsub("\n+$", ""), "\n", { plain = true })
  local old_changed, new_changed = {}, {}
  for _, hunk in ipairs(vim.diff(old_text, new_text, { result_type = "indices" })) do
    for line = hunk[1], hunk[1] + hunk[2] - 1 do old_changed[line] = true end
    for line = hunk[3], hunk[3] + hunk[4] - 1 do new_changed[line] = true end
  end
  local colors = {}
  for index, line in ipairs(lines) do
    local old_line = line:match("^(%d+)%s")
    local new_line = line:match("^%s+(%d+)%s")
    if old_line and old_changed[tonumber(old_line)] then
      colors[index] = "DiffDelete"
    elseif new_line and new_changed[tonumber(new_line)] then
      colors[index] = "DiffAdd"
    end
  end
  return lines, colors
end

local function append_diff(file, tool_name)
  if type(file.diff) ~= "string" or file.diff == "" then return end
  local lines, colors = difft_preview(file)
  append_block("Diff: " .. (file.path or tool_name),
    lines or vim.split(file.diff, "\n", { plain = true }), "Identifier", colors or true)
end

local function append_result(result, tool_name, is_error)
  if type(result) ~= "table" then return end
  local empty_bash_seconds
  if tool_name == "bash" and not (is_error or result.isError)
    and type(result.content) == "table" and #result.content == 1 then
    local block = result.content[1]
    if block.type == "text" and type(block.text) == "string" then
      empty_bash_seconds = block.text:match("^%(no output%)\n\nWall time: (%d+%.%d%d) seconds\n?$")
    end
  end
  if empty_bash_seconds then
    append({ "- bash wall time: " .. empty_bash_seconds .. " seconds" }, { [1] = "Comment" })
  end
  local hide_output = empty_bash_seconds ~= nil or (not (is_error or result.isError)
    and (tool_name == "read" or tool_name == "grep" or tool_name == "edit" or tool_name == "eval"))
  if not hide_output then
    local lines = {}
    local has_text = false
    for _, block in ipairs(type(result.content) == "table" and result.content or {}) do
      if block.type == "text" and type(block.text) == "string" then
        for line in (block.text .. "\n"):gmatch("(.-)\n") do
          lines[#lines + 1] = line
          if line:match("%S") then has_text = true end
        end
      end
    end
    if has_text then
      local group = "String"
      if tool_name == "eval" or tool_name == "bash" or tool_name == "glob" or tool_name == "write" or tool_name == "wait" then
        group = "Comment"
      end
      if (is_error or result.isError) and (tool_name == "glob" or tool_name == "write" or tool_name == "wait" or group == "String") then
        group = "DiagnosticError"
      end
      append_block("Output: " .. tool_name, lines, group)
    end
  end

  local details = result.details
  if type(details) ~= "table" then return end
  local files = type(details.perFileResults) == "table" and details.perFileResults or nil
  if files and #files > 0 then
    for _, file in ipairs(files) do
      append_diff(file, tool_name)
    end
  elseif type(details.diff) == "string" and details.diff ~= "" then
    append_diff(details, tool_name)
  end
end

local function append_call(name, args, intent)
  if name == "bash" and type(args) == "table" and type(args.command) == "string" and args.command ~= "" then
    append_block("Command", vim.split(args.command, "\n", { plain = true }), "Comment")
  elseif name == "read" and type(args) == "table" and type(args.path) == "string" then
    append({ "- read: " .. args.path }, { [1] = "Comment" })
  elseif name == "grep" and type(args) == "table" and type(args.pattern) == "string" then
    local query = args.pattern:gsub("\n", "\\n")
    local path = type(args.path) == "string" and "  " .. args.path or ""
    append({ "- grep: " .. query .. path }, { [1] = "Comment" })
  else
    local summary = intent or (name ~= "todo" and vim.json.encode(args or {}) or "")
    append({ "- " .. name .. (summary ~= "" and ": " .. summary or "") }, { [1] = "Comment" })
  end
end

local function content_text(content)
  if type(content) == "string" then return content end
  local parts = {}
  for _, block in ipairs(type(content) == "table" and content or {}) do
    if block.type == "text" and type(block.text) == "string" then parts[#parts + 1] = block.text end
  end
  return table.concat(parts, "\n")
end

local function restore_history(messages)
  if pending_stream then flush_stream() end
  local buf = state.transcript
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Agent session: " .. state.session_name })
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, transcript_hl, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, reasoning_hl, 0, -1)
  local prompts = {}
  for _, message in ipairs(messages) do
    if message.role == "user" then
      local text = content_text(message.content)
      if text ~= "" then
        prompts[#prompts + 1] = text
        local lines = { "", "You" }
        vim.list_extend(lines, vim.split(text, "\n", { plain = true }))
        append(lines, { [2] = "Question" })
      end
    elseif message.role == "assistant" then
      for _, block in ipairs(type(message.content) == "table" and message.content or {}) do
        if block.type == "thinking" and type(block.thinking) == "string" and block.thinking:match("%S") then
          append_reasoning(block.thinking)
        elseif block.type == "text" and type(block.text) == "string" and block.text ~= "" then
          local lines = { "", "Agent" }
          vim.list_extend(lines, vim.split(block.text, "\n", { plain = true }))
          append(lines, { [2] = "Title" })
        elseif block.type == "toolCall" then
          append_call(block.name, block.arguments, block.intent)
        end
      end
    elseif message.role == "toolResult" then
      if message.toolName == "todo" and type(message.details) == "table"
        and type(message.details.phases) == "table" then
        append_todos(message.details.phases)
      else
        append_result(message, message.toolName)
      end
    end
  end
  return prompts
end

flush_stream = function()
  local pending = pending_stream
  if not pending then return end
  pending_stream = nil
  local buf, row_key, last = pending.buf, pending.row_key, pending.last
  if buf ~= state.transcript or not vim.api.nvim_buf_is_valid(buf) or state[row_key] ~= last then return end
  local previous = vim.api.nvim_buf_get_lines(buf, last, last + 1, false)[1]
  if not previous then return end
  local lines = vim.split(table.concat(pending.parts), "\n", { plain = true })
  lines[1] = previous .. lines[1]
  local follow = should_follow()
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, last, last + 1, false, lines)
  vim.bo[buf].modifiable = false
  if pending.highlight then
    vim.api.nvim_buf_clear_namespace(buf, reasoning_hl, last, last + #lines)
    for index, line in ipairs(lines) do
      vim.api.nvim_buf_set_extmark(buf, reasoning_hl, last + index - 1, 0,
        { end_col = #line, hl_group = pending.highlight, priority = 150 })
    end
  end
  state[row_key] = last + #lines - 1
  if follow then scroll_to_end(lines[#lines]) end
end

local function stream_delta(row_key, delta, highlight)
  local buf = state.transcript
  if pending_stream and (pending_stream.buf ~= buf or pending_stream.row_key ~= row_key
    or pending_stream.last ~= state[row_key] or pending_stream.highlight ~= highlight) then
    flush_stream()
  end
  local last = state[row_key]
  if not pending_stream then
    pending_stream = { buf = buf, row_key = row_key, last = last, highlight = highlight, parts = {} }
    local pending = pending_stream
    vim.defer_fn(function()
      if pending_stream == pending then flush_stream() end
    end, 16)
  end
  local parts = pending_stream.parts
  parts[#parts + 1] = delta
end

M.scroll_to_end = scroll_to_end
M.append = append
M.append_todos = append_todos
M.append_block = append_block
M.append_reasoning = append_reasoning
M.append_result = append_result
M.append_call = append_call
M.restore_history = restore_history
M.stream_delta = stream_delta
M.flush_stream = flush_stream

return M
