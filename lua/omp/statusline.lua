local M = {}
local state = require('omp.state')

local function short_number(n)
  if n < 1000 then return tostring(n) end
  if n < 10000 then return (string.format("%.1f", n / 1000):gsub("%.0$", "")) .. "K" end
  if n < 1000000 then return math.floor(n / 1000 + 0.5) .. "K" end
  if n < 10000000 then return (string.format("%.1f", n / 1000000):gsub("%.0$", "")) .. "M" end
  return math.floor(n / 1000000 + 0.5) .. "M"
end

local function fit(text, width)
  if width <= 0 then return "" end
  if vim.fn.strdisplaywidth(text) <= width then return text end
  text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text) - 1)
  while vim.fn.strdisplaywidth(text) >= width do
    text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text) - 1)
  end
  return text .. "…"
end
local spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

function M.set_activity(activity)
  if state.activity == activity then return end
  state.activity = activity
  if activity and not state.activity_timer then
    state.spin = 1
    state.activity_timer = vim.fn.timer_start(160, function()
      state.spin = state.spin % #spinner + 1
      vim.cmd("redrawstatus")
    end, { ["repeat"] = -1 })
  elseif not activity and state.activity_timer then
    vim.fn.timer_stop(state.activity_timer)
    state.activity_timer = nil
  end
  vim.cmd("redrawstatus")
end


function M.render_statusline()
  if not state.prompt_win or not vim.api.nvim_win_is_valid(state.prompt_win)
    or vim.api.nvim_win_get_buf(state.prompt_win) ~= state.prompt then return "" end
  local width = (vim.o.laststatus == 3 and vim.o.columns or vim.api.nvim_win_get_width(state.prompt_win)) - 2
  if not state.ready then
    return "%#Comment# Agent " .. (state.job and "connecting…" or "offline")
  end

  local stats = state.stats or {}
  local tokens = stats.tokens or {}
  local usage = state.session and state.session.contextUsage
  if type(usage) ~= "table" then usage = nil end
  local model = state.session and state.session.model
  if type(model) ~= "table" then model = nil end
  local window = model and model.contextWindow or 0
  if usage then window = usage.contextWindow or window end
  local context = (usage and window > 0 and string.format("%.1f%%", usage.percent) or "?")
    .. "/" .. (window > 0 and short_number(window) or "?")
  local cost = string.format("$%.3f", stats.cost or 0)
  local essential = context .. " " .. cost
  local activity = state.activity and (spinner[state.spin or 1] .. " " .. state.activity .. "…") or "Ready"
  local effort = model and model.thinking and type(state.session.thinkingLevel) == "string"
    and state.session.thinkingLevel or nil
  local thinking = effort and " • " .. effort or ""
  if width < vim.fn.strdisplaywidth(activity) + 2 then
    return "%#Comment# " .. fit(activity, width) .. " "
  end
  local left = "Agent " .. essential
  if vim.fn.strdisplaywidth(left .. activity) + 2 > width then left = essential end
  if vim.fn.strdisplaywidth(left .. activity) + 2 > width then
    left = fit(context, width - vim.fn.strdisplaywidth(activity) - 2)
  end

  local model_label = model and model.id or "no-model"
  local model_text = model_label .. thinking
  local model_budget = width - vim.fn.strdisplaywidth(left) - vim.fn.strdisplaywidth(activity) - 4
  if vim.fn.strdisplaywidth(model_text) > model_budget then
    if effort and vim.fn.strdisplaywidth(effort) <= model_budget then
      model_text = effort
    elseif vim.fn.strdisplaywidth(model_label) <= model_budget then
      model_text = model_label
    else
      model_text = ""
    end
  end
  local right = (model_text ~= "" and model_text .. "  " or "") .. activity
  local parts = {}
  for _, metric in ipairs({ { "↑", tokens.input }, { "↓", tokens.output }, { "R", tokens.cacheRead }, { "W", tokens.cacheWrite } }) do
    if metric[2] and metric[2] > 0 then parts[#parts + 1] = metric[1] .. short_number(metric[2]) end
  end
  local token_text = table.concat(parts, " ")
  if token_text ~= "" and vim.fn.strdisplaywidth(token_text .. " " .. left .. "  " .. right) <= width then
    left = token_text .. " " .. left
  end
  if state.branch then
    local branch = "(" .. state.branch .. ")"
    if vim.fn.strdisplaywidth(branch .. "  " .. left .. "  " .. right) <= width then
      left = branch .. "  " .. left
    end
  end
  local gap = right ~= "" and math.max(2, width - vim.fn.strdisplaywidth(left) - vim.fn.strdisplaywidth(right)) or 0
  local content = left .. string.rep(" ", gap) .. right
  return "%#Comment# " .. content:gsub("%%", "%%%%") .. " "
end

function M.render_divider()
  if not state.transcript_win or not vim.api.nvim_win_is_valid(state.transcript_win)
    or vim.api.nvim_win_get_buf(state.transcript_win) ~= state.transcript then return "" end
  local width = vim.api.nvim_win_get_width(state.transcript_win)
  local tasks = {}
  for _, task in pairs(state.running_tasks or {}) do tasks[#tasks + 1] = task end
  table.sort(tasks, function(a, b) return a.index < b.index end)
  local parts = {}
  if #tasks > 0 then
    local names = {}
    for _, task in ipairs(tasks) do names[#names + 1] = task.label end
    parts[#parts + 1] = "Tasks: " .. table.concat(names, ", ")
  end
  local job_ids = {}
  for id in pairs(state.running_jobs or {}) do job_ids[#job_ids + 1] = id end
  table.sort(job_ids)
  if #job_ids > 0 then
    local names = {}
    for _, id in ipairs(job_ids) do names[#names + 1] = id .. " " .. state.running_jobs[id] end
    parts[#parts + 1] = "Jobs: " .. table.concat(names, ", ")
  end
  local commands = {}
  for _, label in pairs(state.running_commands or {}) do commands[#commands + 1] = label end
  if #commands > 0 then
    table.sort(commands)
    parts[#parts + 1] = "Commands: " .. table.concat(commands, ", ")
  end
  if #parts == 0 and not state.has_pending_async then
    return "%#WinSeparator#" .. string.rep("─", width)
  end
  if width < 3 then return "%#WinSeparator#" .. string.rep("─", width) end
  local summary = #parts > 0 and table.concat(parts, " · ") or "Background work"
  local text = " " .. fit(summary, width - 2) .. " "
  return "%#Comment#" .. text:gsub("%%", "%%%%")
    .. "%#WinSeparator#" .. string.rep("─", math.max(0, width - vim.fn.strdisplaywidth(text)))
end

return M
