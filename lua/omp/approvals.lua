local state = require("omp.state")

local M = {}

function M.eligible(request)
  local title = request.method == "select" and request.title
  local tool = type(title) == "string" and title:match("^Allow tool: ([^\n]+)")
  if not tool or not tool:match("%S") then return false end
  if title:find("ch elided", 1, true) or title:find("\nProvider safety checks:", 1, true)
    or title:find("\nReason:", 1, true) then return false end
  return #request.options == 2 and request.options[1] == "Approve" and request.options[2] == "Deny"
end

function M.path()
  return state.session_dir and state.session_dir .. "/approvals.json" or nil
end

local function read_list()
  local path = M.path()
  if not path then return nil, "No project session directory" end
  local stat, err = vim.uv.fs_stat(path)
  if not stat then
    if err and not err:find("ENOENT", 1, true) then return nil, err end
    return { version = 1, commands = {} }
  end
  if stat.type ~= "file" then return nil, "Approval list is not a file" end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then return nil, tostring(lines) end
  local valid, data = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not valid or type(data) ~= "table" or data.version ~= 1
    or type(data.commands) ~= "table" then return nil, "Invalid approval list" end
  for _, title in pairs(data.commands) do
    if type(title) ~= "string" then return nil, "Invalid approval entry" end
  end
  return data
end

function M.list()
  local data, err = read_list()
  return data, M.path(), err
end

local function contains(commands, title)
  for _, saved in ipairs(commands) do
    if saved == title then return true end
  end
  return false
end

function M.match(request)
  if not M.eligible(request) then return nil end
  local data, err = read_list()
  if not data then return nil, err end
  return contains(data.commands, request.title)
end

function M.remember(request)
  if not M.eligible(request) then return false, "Only complete tool approvals can be remembered" end
  local data, err = read_list()
  if not data then return false, err end
  if contains(data.commands, request.title) then return true end
  data.commands[#data.commands + 1] = request.title
  local path = M.path()
  if vim.fn.mkdir(state.session_dir, "p", 448) == 0 and not vim.uv.fs_stat(state.session_dir) then
    return false, "Cannot create approval directory"
  end
  local temporary = path .. "." .. vim.fn.getpid() .. "." .. vim.uv.hrtime() .. ".tmp"
  local fd, open_err = vim.uv.fs_open(temporary, "wx", 384)
  if not fd then return false, open_err end
  local content = vim.json.encode(data) .. "\n"
  local written, write_err = vim.uv.fs_write(fd, content, 0)
  vim.uv.fs_close(fd)
  if written ~= #content then
    vim.uv.fs_unlink(temporary)
    return false, write_err or "Incomplete approval list write"
  end
  local moved, rename_err = vim.uv.fs_rename(temporary, path)
  if not moved then
    vim.uv.fs_unlink(temporary)
    return false, rename_err
  end
  return true
end

return M
