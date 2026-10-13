--[[
Farm_Vendor/log.lua
======================

Structured logging for Farm Vendor.

Every event has:
  * a timestamp      (local time, YYYY-MM-DD HH:MM:SS)
  * a level          (DEBUG, INFO, WARN, ERROR)
  * an event name    (dotted, machine-friendly, e.g. "sale.verified")
  * key=value fields (sorted by key so lines are diff-friendly)

Example line:
  2026-10-13 14:02:11 INFO  sale.verified id=13073 name="Bone Chips" pack=3 qty=20 slot=5

Destinations
  1. MacroQuest console via print() (documented: print is redirected to MQ chat)
  2. Optional file under mq.configDir, rotated at config.LOG_MAX_BYTES
  3. A bounded in-memory ring the UI shows as the Activity Log

Design notes
  * Logging must never crash the script: file errors are caught, reported once
    to the console, and file logging is disabled for the rest of the session.
  * Values are sanitized: newlines/control characters removed, quotes escaped,
    long values truncated, so one bad item name cannot corrupt the log format.
  * Only standard Lua io/os functions are used for the file; no MQ commands.
]]

local log = {}

local LEVEL_RANK = { DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4 }
local MAX_VALUE_LEN = 200

local state = {
    prefix       = '[FarmVendor]',
    consoleRank  = LEVEL_RANK.INFO,
    fileRank     = LEVEL_RANK.DEBUG,
    filePath     = nil,      -- nil disables file logging
    maxBytes     = 1048576,
    ring         = {},       -- array of {level=, text=}
    ringMax      = 200,
    ringVersion  = 0,        -- increments on every append (UI can detect change)
    fileFailed   = false,
}

--- Remove control characters and limit length.
local function sanitize(s)
    s = tostring(s)
    s = s:gsub('[%c]', ' ')
    if #s > MAX_VALUE_LEN then s = s:sub(1, MAX_VALUE_LEN) .. '...' end
    return s
end

--- Format one field value: bare if simple, quoted if it has spaces/specials.
local function formatValue(v)
    local s = sanitize(v)
    if s == '' or s:find('[%s"=]') then
        s = '"' .. s:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
    end
    return s
end

--- Build "k=v k=v" with keys sorted.
local function formatFields(fields)
    if type(fields) ~= 'table' then return '' end
    local keys = {}
    for k in pairs(fields) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        local key = sanitize(k):gsub('[^%w_%.]', '_')
        parts[#parts + 1] = key .. '=' .. formatValue(fields[k])
    end
    return table.concat(parts, ' ')
end

--- Rotate the file when it exceeds maxBytes (keeps exactly one .1 backup).
local function rotateIfNeeded()
    local f = io.open(state.filePath, 'rb')
    if not f then return end
    local size = f:seek('end')
    f:close()
    if size and size > state.maxBytes then
        local backup = state.filePath .. '.1'
        os.remove(backup)                -- ok if it does not exist
        os.rename(state.filePath, backup)
    end
end

local function writeFile(line)
    if not state.filePath or state.fileFailed then return end
    local ok, err = pcall(function()
        rotateIfNeeded()
        local f, openErr = io.open(state.filePath, 'a')
        if not f then error(openErr or 'unable to open log file') end
        f:write(line, '\n')
        f:close()
    end)
    if not ok then
        state.fileFailed = true
        print(('%s ERROR log.file_disabled path=%s error=%s'):format(
            state.prefix, formatValue(state.filePath), formatValue(err)))
    end
end

--- Configure the logger. Safe to call more than once.
--- @param opts table {prefix, consoleLevel, fileLevel, filePath|nil, maxBytes, ringMax}
function log.configure(opts)
    opts = opts or {}
    state.prefix      = opts.prefix or state.prefix
    state.consoleRank = LEVEL_RANK[opts.consoleLevel] or state.consoleRank
    state.fileRank    = LEVEL_RANK[opts.fileLevel] or state.fileRank
    state.filePath    = opts.filePath
    state.maxBytes    = opts.maxBytes or state.maxBytes
    state.ringMax     = opts.ringMax or state.ringMax
    state.fileFailed  = false
end

--- Core emit function.
--- @param level string  DEBUG|INFO|WARN|ERROR
--- @param event string  dotted event name
--- @param fields table|nil key/value pairs
function log.event(level, event, fields)
    local rank = LEVEL_RANK[level] or LEVEL_RANK.INFO
    level = LEVEL_RANK[level] and level or 'INFO'
    local body = sanitize(event)
    local f = formatFields(fields)
    if f ~= '' then body = body .. ' ' .. f end
    local stamp = os.date('%Y-%m-%d %H:%M:%S')
    local line = ('%s %-5s %s'):format(stamp, level, body)

    if rank >= state.consoleRank then
        print(('%s %s %s'):format(state.prefix, level, body))
    end
    if rank >= state.fileRank then writeFile(line) end

    -- UI ring keeps INFO and above (DEBUG would drown the panel)
    if rank >= LEVEL_RANK.INFO then
        local ring = state.ring
        ring[#ring + 1] = { level = level, text = os.date('%H:%M:%S') .. ' ' .. body }
        while #ring > state.ringMax do table.remove(ring, 1) end
        state.ringVersion = state.ringVersion + 1
    end
end

function log.debug(event, fields) log.event('DEBUG', event, fields) end
function log.info(event, fields)  log.event('INFO',  event, fields) end
function log.warn(event, fields)  log.event('WARN',  event, fields) end
function log.error(event, fields) log.event('ERROR', event, fields) end

--- Read-only access for the UI.
function log.ring() return state.ring end
function log.ringVersion() return state.ringVersion end
function log.filePath() return (not state.fileFailed) and state.filePath or nil end

return log
