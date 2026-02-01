--[[
  Lua Config Parser (LCP)
  Copyright (c) 2018 Cannonballdex
  MIT License (see header)
  
  Purpose
  - Small, robust INI-style parser and writer.
  - Loads an INI file into a Lua table: tables are keyed by section names, each section
    is a table of key/value pairs.
  - Saves a Lua table back to an INI file, sorting sections and keys for predictable output.
  - Converts numeric and boolean-looking values to native Lua types.
  - Tolerant of comments, quoted values, BOM, and blank lines.
  - Designed to be safe for use from MQ scripts (returns an empty table when file not found).
--]]

--- MIT License
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.

local LCP = {}

local function trim(s)
  if s == nil then return nil end
  return (s:gsub('^%s*(.-)%s*$', '%1'))
end

local function unquote(s)
  if s == nil then return nil end
  if #s >= 2 then
    local first = s:sub(1,1)
    local last  = s:sub(-1)
    if (first == '"' or first == "'") and last == first then
      return s:sub(2, -2)
    end
  end
  return s
end

local function parse_value(raw)
  if raw == nil then return nil end
  local v = trim(raw)
  v = unquote(v)

  -- numeric
  local n = tonumber(v)
  if n ~= nil then return n end

  -- booleans
  local low = (v or ''):lower()
  if low == 'true'  then return true end
  if low == 'false' then return false end

  -- string (empty preserved)
  return v
end

--- Load INI-style file into table.
-- Returns an empty table if file does not exist.
function LCP.load(fileName)
  assert(type(fileName) == 'string', 'LCP.load: fileName must be a string')

  local fh, err = io.open(fileName, 'r')
  if not fh then
    -- Return {} for missing file, but surface other IO errors
    if err and (err:find('No such file') or err:find('cannot open') or err:find('Permission denied')) then
      return {}
    end
    error('LCP.load: Error opening file: ' .. tostring(err or fileName))
  end

  local data = {}
  local current = nil

  for rawline in fh:lines() do
    local line = rawline

    -- strip UTF-8 BOM (if present)
    if line and #line >= 3 and line:byte(1) == 0xEF and line:byte(2) == 0xBB and line:byte(3) == 0xBF then
      line = line:sub(4)
    end

    line = trim(line)
    if not line or line == '' then
      -- ignore blank lines
    else
      local first = line:sub(1,1)
      if first == ';' or first == '#' then
        -- full-line comment
      else
        -- section header [name]
        local sec = line:match('^%[([^%[%]]+)%]$')
        if sec then
          local key = tonumber(trim(sec)) or trim(sec)
          current = key
          data[current] = data[current] or {}
        else
          -- key = value (split at first '=')
          local kpart, vpart = line:match('^([^=]+)=(.*)$')
          if kpart and current ~= nil then
            local key = trim(kpart)
            local value_raw = vpart or ''

            -- strip inline comment if preceded by whitespace (e.g. "value ; comment")
            local cpos = value_raw:find('%s[;#]')
            if cpos then value_raw = trim(value_raw:sub(1, cpos - 1)) end

            local value = parse_value(value_raw)

            local nkey = tonumber(key)
            if nkey then key = nkey end

            data[current][key] = value
          end
        end
      end
    end
  end

  fh:close()
  return data
end

--- Save Lua table to INI-style file. Sections and keys sorted for stable output.
function LCP.save(fileName, data)
  assert(type(fileName) == 'string', 'LCP.save: fileName must be a string')
  assert(type(data) == 'table', 'LCP.save: data must be a table')

  local parts = {}

  -- collect and sort section keys
  local sections = {}
  for k, _ in pairs(data) do table.insert(sections, k) end
  table.sort(sections, function(a,b) return tostring(a) < tostring(b) end)

  for _, sk in ipairs(sections) do
    table.insert(parts, ('[%s]'):format(tostring(sk)))

    -- collect and sort keys for section
    local keys = {}
    for k, _ in pairs(data[sk] or {}) do table.insert(keys, k) end
    table.sort(keys, function(a,b) return tostring(a) < tostring(b) end)

    for _, k in ipairs(keys) do
      local v = data[sk][k]
      local vs
      if type(v) == 'boolean' then
        vs = v and 'true' or 'false'
      else
        vs = tostring(v)
      end
      table.insert(parts, ('%s=%s'):format(tostring(k), vs))
    end

    table.insert(parts, '') -- blank line after section
  end

  local contents = table.concat(parts, '\n')

  -- atomic write (tmp then rename)
  local tmp = fileName .. '.tmp'
  local fh, err = io.open(tmp, 'w+b')
  if not fh then error('LCP.save: could not open temp file: ' .. tostring(err)) end
  fh:write(contents)
  fh:close()

  -- try to replace existing file (ignore remove errors) and finalize rename
  pcall(function() os.remove(fileName) end)
  local ok, ren_err = os.rename(tmp, fileName)
  if not ok then error('LCP.save: rename failed: ' .. tostring(ren_err)) end
end

return LCP
