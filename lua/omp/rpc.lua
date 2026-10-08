local state = require("omp.state")
local transcript = require("omp.transcript")
local status = require("omp.statusline")
local dialog = require("omp.dialog")
local history = require("omp.history")

local append = transcript.append
local append_todos = transcript.append_todos
local append_block = transcript.append_block
local append_reasoning = transcript.append_reasoning
local append_result = transcript.append_result
local append_call = transcript.append_call
local restore_history = transcript.restore_history
local stream_delta = transcript.stream_delta
local set_activity = status.set_activity

local M = {}
local dialog_generation = 0

function M.send(frame, initializing)
  if state.job and (state.ready or initializing) then
    if frame.type == "new_session" then
      dialog_generation = dialog_generation + 1
      dialog.clear()
    end
    vim.fn.chansend(state.job, vim.json.encode(frame) .. "\n")
    return true
  end
  append({ state.job and "Agent connecting" or "Agent not connected" })
  return false
end

local function refresh_statusline()
  M.send({ type = "get_state" })
  M.send({ type = "get_session_stats" })
end

local function update_task(id, index, status, label, named)
  if status == "started" or status == "running" then
    local previous = state.running_tasks[id]
    state.running_tasks[id] = {
      index = index,
      label = previous and previous.named and previous.label or (label or id):gsub("%s+", " "),
      named = named or (previous and previous.named) or false,
    }
  else
    state.running_tasks[id] = nil
  end
  vim.cmd("redrawstatus")
end

local function update_jobs(jobs, delivered)
  if type(jobs) ~= "table" then return end
  for _, job in ipairs(jobs) do
    local id = job.jobId or job.id
    if type(id) == "string" then
      if delivered or job.status ~= "running" then
        state.running_jobs[id] = nil
      elseif (job.type == "bash" or job.type == "eval") and type(job.label) == "string" then
        state.running_jobs[id] = job.label:gsub("%s+", " ")
      end
    end
  end
  vim.cmd("redrawstatus")
end

local function finish_session_open()
  if state.displayed_session_id == state.session_id then
    state.ready = true
    append({ "Agent reconnected: " .. state.session_name })
    refresh_statusline()
  else
    M.send({ type = "get_messages" }, true)
  end
end

local function handle(frame)
  local event = frame.assistantMessageEvent
  if frame.type ~= "message_update" or not event
    or (event.type ~= "text_delta" and event.type ~= "thinking_delta") then
    transcript.flush_stream()
  end
  if frame.type == "ready" then
    M.send({ type = "set_subagent_subscription", level = "progress" }, true)
    M.send({ type = "open_session", sessionDir = state.session_dir }, true)
  elseif frame.type == "subagent_lifecycle" then
    local task = frame.payload
    update_task(task.id, task.index, task.status, task.description or task.agent, task.description ~= nil)
  elseif frame.type == "subagent_progress" then
    local task = frame.payload
    update_task(task.progress.id, task.index, task.progress.status, task.task or task.agent)
  elseif frame.type == "response" and not frame.success then
    append({ "Agent error: " .. tostring(frame.error) }, { [1] = "DiagnosticError" })
    if frame.command == "new_session" and state.new_requested then
      state.new_requested = nil
    elseif frame.command == "open_session" or frame.command == "new_session"
      or frame.command == "set_session_name" or (frame.command == "get_state" and not state.ready) then
      vim.fn.jobstop(state.job)
    elseif frame.command == "get_messages" then
      state.ready = false
      vim.fn.jobstop(state.job)
    end
  elseif frame.type == "response" and frame.command == "open_session" then
    if frame.data.cancelled then
      append({ "Agent session open cancelled" }, { [1] = "DiagnosticError" })
      vim.fn.jobstop(state.job)
    elseif not frame.data.resumed then
      M.send({ type = "new_session" }, true)
    else
      M.send({ type = "get_state" }, true)
    end
  elseif frame.type == "response" and frame.command == "new_session" then
    if frame.data.cancelled then
      append({ "Agent session creation cancelled" }, { [1] = "DiagnosticError" })
      if state.new_requested then state.new_requested = nil else vim.fn.jobstop(state.job) end
    else
      if state.new_requested then
        history.restore({})
        state.new_requested = nil
        state.ready = false
        state.displayed_session_id = nil
        state.session = nil
        state.stats = nil
        state.running_tasks = {}
        state.running_jobs = {}
        state.running_commands = {}
        state.has_pending_async = false
        state.todo_seen = false
        state.active = nil
        state.answer_row = nil
        state.reason_row = nil
        state.reason_pending = nil
        set_activity(nil)
      end
      if not state.ready then
        state.next_id = state.next_id + 1
        state.new_state_id = tostring(state.next_id)
        M.send({ id = state.new_state_id, type = "get_state" }, true)
      else
        M.send({ type = "get_state" }, true)
      end
    end
  elseif frame.type == "response" and frame.command == "set_session_name" then
    finish_session_open()
  elseif frame.type == "response" and frame.command == "get_messages" then
    history.restore(restore_history(frame.data.messages))
    state.displayed_session_id = state.session_id
    state.ready = true
    append({ "Agent connected: " .. state.session_name })
    refresh_statusline()
  elseif frame.type == "response" and frame.command == "set_subagent_subscription" then
    M.send({ type = "get_subagents" }, true)
  elseif frame.type == "response" and frame.command == "get_subagents" then
    state.running_tasks = {}
    for _, task in ipairs(frame.data.subagents) do
      if task.status == "running" then
        state.running_tasks[task.id] = {
          index = task.index, label = (task.description or task.task or task.agent):gsub("%s+", " "),
          named = task.description ~= nil,
        }
      end
    end
    vim.cmd("redrawstatus")
  elseif frame.type == "response" and frame.success and frame.command == "get_state" then
    if state.new_state_id then
      if frame.id ~= state.new_state_id then return end
      state.new_state_id = nil
    end
    state.session = frame.data
    state.has_pending_async = frame.data.hasPendingAsyncWork
    if frame.data.isSettled == false and not state.activity then set_activity("Working") end
    vim.cmd("redrawstatus")
    if not state.ready then
      state.session_id = frame.data.sessionId
      if frame.data.sessionName == state.session_name then
        finish_session_open()
      else
        M.send({ type = "set_session_name", name = state.session_name }, true)
      end
    elseif not state.todo_seen and frame.data.todoPhases and #frame.data.todoPhases > 0 then
      append_todos(frame.data.todoPhases)
      state.todo_seen = true
    end
  elseif frame.type == "response" and frame.success and frame.command == "get_session_stats" then
    state.stats = frame.data
    vim.cmd("redrawstatus")
  elseif frame.type == "response" and frame.command == "set_thinking_level" then
    refresh_statusline()
  elseif frame.type == "prompt_result" then
    set_activity(frame.sessionSettled == false and "Working" or nil)
    if frame.status == "error" then
      append({ "Agent error: " .. (frame.error and frame.error.message or "prompt failed") }, { [1] = "DiagnosticError" })
    elseif frame.status == "aborted" then
      append({ "Agent aborted" }, { [1] = "DiagnosticWarn" })
    end
    refresh_statusline()
  elseif frame.type == "session_settled" then
    state.has_pending_async = false
    set_activity(nil)
    state.running_jobs = {}
    state.running_commands = {}
    vim.cmd("redrawstatus")
  elseif frame.type == "agent_start" then
    set_activity("Working")
  elseif frame.type == "command_output" then
    if type(frame.text) == "string" and frame.text:match("%S") then
      append_block("Output", vim.split(frame.text, "\n", { plain = true }), "String")
    end
  elseif frame.type == "message_start" and frame.message and frame.message.customType == "async-result" then
    update_jobs(frame.message.details and frame.message.details.jobs, true)
  elseif frame.type == "message_start" and frame.message and frame.message.role == "assistant" then
    set_activity("Working")
    state.active = frame.messageId
    state.answer_row = nil
    state.reason_row = nil
    state.reason_pending = nil
  elseif frame.type == "message_update" and frame.messageId == state.active then
    local event = frame.assistantMessageEvent
    if event and event.type == "thinking_start" then
      set_activity("Thinking")
      state.reason_pending = ""
    elseif event and event.type == "thinking_delta" and event.delta ~= "" then
      set_activity("Thinking")
      local delta = event.delta
      if not state.reason_row then
        delta = (state.reason_pending or "") .. delta
        if delta:match("%S") then
          state.reason_pending = nil
          append({ "", "" })
          state.reason_row = vim.api.nvim_buf_line_count(state.transcript) - 1
          stream_delta("reason_row", delta, "Comment")
        else
          state.reason_pending = delta
        end
      else
        stream_delta("reason_row", delta, "Comment")
      end
    elseif event and event.type == "thinking_end" then
      if not state.reason_row and type(event.content) == "string" and event.content:match("%S") then
        append_reasoning(event.content)
      end
      state.reason_row = nil
      state.reason_pending = nil
      set_activity("Working")
    elseif event and event.type == "text_delta" and event.delta ~= "" then
      if not state.answer_row then set_activity("Working") end
      if not state.answer_row then
        append({ "", "Agent", "" }, { [2] = "Title" })
        state.answer_row = vim.api.nvim_buf_line_count(state.transcript) - 1
      end
      stream_delta("answer_row", event.delta, nil)
    elseif event and event.type == "text_end" then
      state.answer_row = nil
    end
  elseif frame.type == "message_end" and frame.messageId == state.active then
    state.active = nil
    state.answer_row = nil
    state.reason_row = nil
    state.reason_pending = nil
  elseif frame.type == "tool_execution_start" then
    set_activity("Working")
    state.answer_row = nil
    if (frame.toolName == "bash" or frame.toolName == "eval") and frame.toolCallId then
      local args = type(frame.args) == "table" and frame.args or {}
      local label = frame.intent or args.i or args.title or args.command or frame.toolName
      state.running_commands[frame.toolCallId] = label:gsub("%s+", " ")
      vim.cmd("redrawstatus")
    end
    append_call(frame.toolName, frame.args, frame.intent)
  elseif frame.type == "tool_execution_end" then
    if frame.isError then append({ "✗ " .. frame.toolName }, { [1] = "DiagnosticError" }) end
    local details = frame.result and frame.result.details
    local label = frame.toolCallId and state.running_commands[frame.toolCallId]
    if label then state.running_commands[frame.toolCallId] = nil end
    if type(details) == "table" then
      local async = details.async
      if not frame.isError and type(async) == "table" and async.state == "running"
        and type(async.jobId) == "string" and (async.type == "bash" or async.type == "eval") then
        state.running_jobs[async.jobId] = label or frame.toolName
        state.has_pending_async = true
      elseif details.op then
        update_jobs(details.jobs, false)
      end
    end
    vim.cmd("redrawstatus")
    if frame.toolName == "todo" and not frame.isError and type(details) == "table" and type(details.phases) == "table" then
      append_todos(details.phases)
      state.todo_seen = true
    elseif frame.isError or frame.toolName ~= "todo" then
      append_result(frame.result, frame.toolName, frame.isError)
    end
    vim.cmd("checktime")
  elseif frame.type == "model_changed" or frame.type == "thinking_level_changed" then
    refresh_statusline()
  elseif frame.type == "extension_ui_request" then
    local job, generation = state.job, dialog_generation
    dialog.handle(frame, function(reply)
      if state.job == job and dialog_generation == generation then M.send(reply, true) end
    end)
  end
end

function M.start()
  local bun = vim.fn.expand("~/.bun/bin/bun")
  local omp = vim.fn.expand("~/.bun/bin/omp")
  dialog_generation = dialog_generation + 1
  dialog.clear()
  transcript.flush_stream()
  state.ready = false
  state.new_requested = nil
  state.new_state_id = nil
  set_activity(nil)
  state.partial = ""
  state.session = nil
  state.stats = nil
  state.running_tasks = {}
  state.running_jobs = {}
  state.running_commands = {}
  state.has_pending_async = false
  state.todo_seen = false
  state.cwd = vim.uv.fs_realpath(vim.fn.getcwd()) or vim.fn.getcwd()
  local folder = vim.fn.fnamemodify(state.cwd, ":t")
  if folder == "" then folder = "root" end
  state.session_name = folder .. " main"
  state.session_dir = vim.fn.expand("~/.omp/agent/sessions/")
    .. folder:gsub("[^%w._-]", "-") .. "-" .. vim.fn.sha256(state.cwd):sub(1, 12) .. "-main"
  state.branch = nil
  if #vim.fs.find(".git", { path = state.cwd, upward = true }) > 0 then
    local branch = vim.fn.systemlist({ "git", "-C", state.cwd, "branch", "--show-current" })[1]
    if vim.v.shell_error == 0 and branch ~= "" then state.branch = branch end
  end
  local job = vim.fn.jobstart({ bun, omp, "--mode", "rpc", "--session-dir", state.session_dir }, {
    cwd = state.cwd,
    env = { DFT_WIDTH = tostring(vim.api.nvim_win_get_width(state.transcript_win)) },
    on_stdout = function(id, data)
      if state.job ~= id or not data then return end
      local first = state.partial .. data[1]
      for i = 2, #data do
        if first ~= "" then
          local ok, frame = pcall(vim.json.decode, first)
          if ok then handle(frame) else append({ "Agent protocol error: " .. tostring(frame) }) end
        end
        first = data[i]
      end
      state.partial = first
    end,
    on_stderr = function(id, data)
      if state.job ~= id then return end
      for _, line in ipairs(data or {}) do
        if line ~= "" then append({ "Agent stderr: " .. line }) end
      end
    end,
    on_exit = function(id, code)
      if state.job ~= id then return end
      state.job = nil
      dialog_generation = dialog_generation + 1
      dialog.clear()
      transcript.flush_stream()
      state.ready = false
      state.new_requested = nil
      state.new_state_id = nil
      state.session = nil
      state.stats = nil
      state.running_tasks = {}
      state.running_jobs = {}
      state.running_commands = {}
      state.has_pending_async = false
      set_activity(nil)
      vim.cmd("redrawstatus")
      append({ "Agent exited (" .. code .. "). Reopen pane to restart." })
    end,
  })
  if job <= 0 then
    append({ "Could not start Agent: " .. tostring(job) })
  else
    state.job = job
    vim.cmd("redrawstatus")
  end
end

return M
