local M = {}

local function cells(line)
  if not line:find("|", 1, true) then return nil end
  local parts, current, code, i, last_delimiter = {}, {}, nil, 1, nil
  while i <= #line do
    local char = line:sub(i, i)
    if char == "\\" and (line:sub(i + 1, i + 1) == "|" or line:sub(i + 1, i + 1) == "\\") then
      current[#current + 1] = line:sub(i, i + 1)
      i = i + 2
    elseif char == "`" then
      local run = line:match("^`+", i)
      if not code then code = #run elseif code == #run then code = nil end
      current[#current + 1] = run
      i = i + #run
    elseif char == "|" and not code then
      last_delimiter = i
      parts[#parts + 1] = table.concat(current):match("^%s*(.-)%s*$")
      current = {}
      i = i + 1
    else
      current[#current + 1] = char
      i = i + 1
    end
  end
  parts[#parts + 1] = table.concat(current):match("^%s*(.-)%s*$")
  if line:match("^%s*|") then table.remove(parts, 1) end
  if last_delimiter and line:sub(last_delimiter + 1):match("^%s*$") then table.remove(parts) end
  return parts
end

local function fence(line)
  local indent, run = line:match("^( *)([`~]+)")
  if not run or #indent > 3 or #run < 3 or run:find("[^" .. run:sub(1, 1) .. "]") then return nil end
  return run:sub(1, 1), #run
end

local function wrap(text, width)
  local lines, line = {}, ""
  for word in text:gsub("%s+", " "):gmatch("%S+") do
    local joined = line == "" and word or line .. " " .. word
    if vim.fn.strdisplaywidth(joined) <= width then
      line = joined
    else
      if line ~= "" then lines[#lines + 1], line = line, "" end
      for index = 0, vim.fn.strchars(word) - 1 do
        local char = vim.fn.strcharpart(word, index, 1)
        if line ~= "" and vim.fn.strdisplaywidth(line .. char) > width then
          lines[#lines + 1], line = line, ""
        end
        line = line .. char
      end
    end
  end
  lines[#lines + 1] = line
  return lines
end

local function format_row(row, widths, align)
  local wrapped, height = {}, 1
  for col, width in ipairs(widths) do
    wrapped[col] = wrap(row[col] or "", width)
    height = math.max(height, #wrapped[col])
  end
  local lines = {}
  for index = 1, height do
    local parts = {}
    for col, width in ipairs(widths) do
      local text = wrapped[col][index] or ""
      local padding = width - vim.fn.strdisplaywidth(text)
      local left = align[col] == "right" and padding or align[col] == "center" and math.floor(padding / 2) or 0
      parts[col] = string.rep(" ", left) .. text .. string.rep(" ", padding - left)
    end
    lines[#lines + 1] = "| " .. table.concat(parts, " | ") .. " |"
  end
  return lines
end

local function layout(header, separator, rows, width)
  local count, widths, natural, align = #header, {}, {}, {}
  local budget, used = width - 3 * count - 1, 0
  for col = 1, count do
    local mark = separator[col]
    align[col] = mark:match("^:") and mark:match(":$") and "center"
      or mark:match(":$") and "right" or "left"
    widths[col] = math.max(3, vim.fn.strdisplaywidth(header[col]))
    natural[col] = widths[col]
    for _, row in ipairs(rows) do natural[col] = math.max(natural[col], vim.fn.strdisplaywidth(row[col] or "")) end
    used = used + widths[col]
  end
  if used > budget then
    local stacked = {}
    if #rows == 0 then rows = { {} } end
    for _, row in ipairs(rows) do
      if #stacked > 0 then stacked[#stacked + 1] = "" end
      for col = 1, count do stacked[#stacked + 1] = header[col] .. ": " .. (row[col] or "") end
    end
    return stacked
  end
  while used < budget do
    local best, gap = nil, 0
    for col = 1, count do
      if natural[col] - widths[col] > gap then best, gap = col, natural[col] - widths[col] end
    end
    if not best then break end
    widths[best] = widths[best] + 1
    used = used + 1
  end
  local output = format_row(header, widths, align)
  local rules = {}
  for col, size in ipairs(widths) do
    rules[col] = (separator[col]:match("^:") and ":" or "")
      .. string.rep("-", size - (separator[col]:match("^:") and 1 or 0)
        - (separator[col]:match(":$") and 1 or 0))
      .. (separator[col]:match(":$") and ":" or "")
  end
  vim.list_extend(output, format_row(rules, widths, align))
  for _, row in ipairs(rows) do vim.list_extend(output, format_row(row, widths, align)) end
  return output
end

function M.render(lines, width)
  local output, changed, index, marker, marker_length = {}, false, 1, nil, nil
  while index <= #lines do
    local line = lines[index]
    local kind, length = fence(line)
    if kind then
      if not marker then
        marker, marker_length = kind, length
      elseif kind == marker and length >= marker_length and line:match("^%s*[`~]+%s*$") then
        marker, marker_length = nil, nil
      end
    end
    local header, separator = not marker and cells(line), not marker and cells(lines[index + 1] or "")
    local valid = header and separator and #header > 0 and #header == #separator
    if valid then
      for _, cell in ipairs(separator) do
        if not cell:match("^:?-+:?$") or #cell < 3 then valid = false break end
      end
    end
    if valid then
      local rows, next_index = {}, index + 2
      while next_index <= #lines do
        local row = cells(lines[next_index])
        if not row or #row > #header then break end
        rows[#rows + 1] = row
        next_index = next_index + 1
      end
      vim.list_extend(output, layout(header, separator, rows, width))
      index, changed = next_index, true
    else
      output[#output + 1] = line
      index = index + 1
    end
  end
  return output, changed
end

return M
