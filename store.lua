--[[
Farm_Vendor/store.lua
========================

Per-server, per-character INI storage for checked (remembered) items.

File location
  <mq.configDir>/Farm_Vendor_<server>_<character>.ini
  Server and character names are percent-encoded so any character that is
  unsafe in a Windows filename becomes %XX. No installation path is hardcoded;
  mq.configDir is the documented MacroQuest config directory.

File format (schema 1)
  [Meta]
  Schema=1
  Tool=Farm_Vendor
  [Settings]
  ProtectedBags=1,2          ; optional, pack numbers 1-12, comma separated
  [SelectedItems]
  13073=1                    ; item ID = 1 (checked)
  [ItemNames]
  13073=Bone Chips           ; readability only; never used for matching

Rules carried from MagFarm
  * The file is DATA, never executed as code (no loadstring/dofile).
  * Writes go to <file>.tmp, are read back and re-parsed, the current file is
    copied to <file>.bak, then the temp file replaces the original. On any
    failure the previous file is restored from the backup when possible.
  * A file with an unsupported schema is loaded READ-ONLY and never overwritten.
  * Unknown sections are preserved verbatim on rewrite.
  * Status is explicit: 'new', 'loaded', 'loaded_with_warnings', 'readonly',
    'saved', 'failed'. A failed save is never reported as success.
  * Remembered checks never trigger a sale; they only pre-check the boxes.
]]

local store = {}

local KNOWN_SECTIONS = { Meta = true, Settings = true, SelectedItems = true, ItemNames = true }
local MAX_ITEM_ID = 2147483647
local MAX_LINES = 50000

--- Percent-encode anything that is not a letter or digit.
function store.encodeName(s)
    return (tostring(s):gsub('[^%w]', function(c) return ('%%%02X'):format(c:byte()) end))
end

local function trim(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end

--- Parse a ProtectedBags value. Returns list or nil,error.
function store.parseProtectedBags(text)
    local list, seen = {}, {}
    text = trim(text or '')
    if text == '' then return list end
    for token in text:gmatch('[^,]+') do
        local t = trim(token)
        local n = tonumber(t)
        if not t:match('^%d+$') or not n or n < 1 or n > 12 then
            return nil, ('invalid pack number %q (allowed 1-12)'):format(t)
        end
        if not seen[n] then list[#list + 1] = n; seen[n] = true end
    end
    table.sort(list)
    return list
end

--- Parse INI text into a structured record. Never raises.
--- @return table record, string[] warnings
function store.parse(text, opts)
    opts = opts or {}
    local maxName = opts.maxNameLength or 128
    local rec = {
        schema = nil, tool = nil,
        protectedBagsText = nil,
        selected = {},     -- [id:number] = true
        names = {},        -- [id:number] = string
        extra = {},        -- preserved unknown sections: array of {name=, lines={}}
    }
    local warnings = {}
    local section, extraSection = nil, nil
    local lineNo = 0

    for raw in (text .. '\n'):gmatch('([^\n]*)\n') do
        lineNo = lineNo + 1
        if lineNo > MAX_LINES then
            warnings[#warnings + 1] = ('stopped reading after %d lines'):format(MAX_LINES)
            break
        end
        local line = trim(raw:gsub('\r$', ''))
        if line == '' or line:sub(1, 1) == ';' or line:sub(1, 1) == '#' then
            if extraSection then extraSection.lines[#extraSection.lines + 1] = raw:gsub('\r$', '') end
        else
            local name = line:match('^%[([^%]]+)%]$')
            if name then
                name = trim(name)
                if KNOWN_SECTIONS[name] then
                    section, extraSection = name, nil
                elseif name:match('^[%w_%.%-]+$') then
                    section = nil
                    extraSection = { name = name, lines = {} }
                    rec.extra[#rec.extra + 1] = extraSection
                else
                    section, extraSection = nil, nil
                    warnings[#warnings + 1] = ('line %d: ignored invalid section name'):format(lineNo)
                end
            elseif extraSection then
                extraSection.lines[#extraSection.lines + 1] = (raw:gsub('\r$', ''))
            else
                local key, value = line:match('^([^=]+)=(.*)$')
                if not key then
                    warnings[#warnings + 1] = ('line %d: ignored (expected key=value)'):format(lineNo)
                else
                    key, value = trim(key), trim(value)
                    if section == 'Meta' then
                        if key == 'Schema' then rec.schema = tonumber(value)
                        elseif key == 'Tool' then rec.tool = value end
                    elseif section == 'Settings' then
                        if key == 'ProtectedBags' then rec.protectedBagsText = value end
                    elseif section == 'SelectedItems' or section == 'ItemNames' then
                        local id = key:match('^%d+$') and tonumber(key)
                        if not id or id < 1 or id > MAX_ITEM_ID then
                            warnings[#warnings + 1] = ('line %d: ignored invalid item ID %q'):format(lineNo, key)
                        elseif section == 'SelectedItems' then
                            if value == '1' then rec.selected[id] = true
                            elseif value ~= '0' then
                                warnings[#warnings + 1] = ('line %d: item %d value must be 0 or 1; left unchecked'):format(lineNo, id)
                            end
                        else
                            local clean = value:gsub('%c', '')
                            rec.names[id] = clean:sub(1, maxName)
                        end
                    else
                        warnings[#warnings + 1] = ('line %d: key outside a known section ignored'):format(lineNo)
                    end
                end
            end
        end
    end
    return rec, warnings
end

--- Serialize a record to INI text (schema 1).
function store.serialize(rec, opts)
    opts = opts or {}
    local maxName = opts.maxNameLength or 128
    local out = {}
    local function add(s) out[#out + 1] = s end
    add('; Farm Vendor selections. Data only; edit with care.')
    add('; Item IDs are authoritative. [ItemNames] is for readability only.')
    add('[Meta]')
    add('Schema=' .. tostring(opts.schema or 1))
    add('Tool=Farm_Vendor')
    add('[Settings]')
    if rec.protectedBagsText and rec.protectedBagsText ~= '' then
        add('ProtectedBags=' .. rec.protectedBagsText)
    else
        add('ProtectedBags=')
    end
    local ids = {}
    for id in pairs(rec.selected) do ids[#ids + 1] = id end
    table.sort(ids)
    add('[SelectedItems]')
    for _, id in ipairs(ids) do add(('%d=1'):format(id)) end
    add('[ItemNames]')
    for _, id in ipairs(ids) do
        local n = (rec.names[id] or ''):gsub('%c', ''):sub(1, maxName)
        add(('%d=%s'):format(id, n))
    end
    for _, sec in ipairs(rec.extra or {}) do
        add('[' .. sec.name .. ']')
        for _, l in ipairs(sec.lines) do add(l) end
    end
    return table.concat(out, '\n') .. '\n'
end

local function readAll(path, maxBytes)
    local f = io.open(path, 'rb')
    if not f then return nil, 'missing' end
    local size = f:seek('end')
    if size and maxBytes and size > maxBytes then
        f:close()
        return nil, ('file is %d bytes, above the %d byte limit'):format(size, maxBytes)
    end
    f:seek('set', 0)
    local data = f:read('*a')
    f:close()
    return data or ''
end

local function writeAll(path, data)
    local f, err = io.open(path, 'wb')
    if not f then return false, err or 'open failed' end
    local ok, werr = f:write(data)
    local cok, cerr = f:close()
    if not ok then return false, werr or 'write failed' end
    if not cok then return false, cerr or 'close failed' end
    return true
end

-- ---------------------------------------------------------------------------
-- Store object
-- ---------------------------------------------------------------------------

--- Create a store bound to one file.
--- @param path string full path
--- @param opts table {schema, maxBytes, maxNameLength}
function store.new(path, opts)
    local self = {
        path = path,
        opts = opts or {},
        record = { selected = {}, names = {}, extra = {}, protectedBagsText = nil },
        status = 'new',          -- see header for allowed values
        statusDetail = '',
        warnings = {},
        readonly = false,
        lastSavedAt = nil,
        saveCount = 0,           -- session-local counter, not an audit record
    }
    return setmetatable(self, { __index = store })
end

--- Load from disk. Missing file => empty 'new' store (not an error).
function store:load()
    local text, err = readAll(self.path, self.opts.maxBytes)
    if not text then
        if err == 'missing' then
            self.status, self.statusDetail = 'new', 'No saved selections yet'
            return true
        end
        self.status, self.statusDetail, self.readonly = 'readonly', 'Unreadable: ' .. tostring(err), true
        return false, self.statusDetail
    end
    local rec, warnings = store.parse(text, { maxNameLength = self.opts.maxNameLength })
    self.warnings = warnings
    local expected = self.opts.schema or 1
    if rec.schema ~= nil and rec.schema ~= expected then
        -- Unsupported schema: keep the user's data untouched, never overwrite.
        self.record = rec
        self.readonly = true
        self.status = 'readonly'
        self.statusDetail = ('Schema %s is not supported (expected %d). File preserved; saving disabled.')
            :format(tostring(rec.schema), expected)
        return false, self.statusDetail
    end
    self.record = rec
    if #warnings > 0 then
        self.status = 'loaded_with_warnings'
        self.statusDetail = ('%d line(s) ignored; see log'):format(#warnings)
    else
        self.status, self.statusDetail = 'loaded', 'Selections loaded'
    end
    return true
end

--- Replace the checked set (in memory only). names: [id]=name
function store:setSelections(selected, names)
    local sel, nm = {}, {}
    for id, on in pairs(selected) do
        if on and type(id) == 'number' then
            sel[id] = true
            nm[id] = names[id] or self.record.names[id] or ''
        end
    end
    self.record.selected, self.record.names = sel, nm
end

--- Atomic save with read-back verification and backup restore.
--- @return boolean ok, string|nil error
function store:save()
    if self.readonly then
        return false, 'Store is read-only: ' .. self.statusDetail
    end
    local data = store.serialize(self.record, self.opts)
    local tmp, bak = self.path .. '.tmp', self.path .. '.bak'

    local ok, err = writeAll(tmp, data)
    if not ok then
        os.remove(tmp)
        self.status, self.statusDetail = 'failed', 'Temp write failed: ' .. tostring(err)
        return false, self.statusDetail
    end
    -- Read back and verify the temp file parses to the same selection set.
    local back = readAll(tmp, self.opts.maxBytes)
    local verify = back and store.parse(back, { maxNameLength = self.opts.maxNameLength })
    local same = verify ~= nil
    if same then
        for id in pairs(self.record.selected) do if not verify.selected[id] then same = false end end
        for id in pairs(verify.selected) do if not self.record.selected[id] then same = false end end
    end
    if not same then
        os.remove(tmp)
        self.status, self.statusDetail = 'failed', 'Verification of temp file failed'
        return false, self.statusDetail
    end
    -- Backup current file (if any).
    local current = readAll(self.path, self.opts.maxBytes)
    if current then
        local bok, berr = writeAll(bak, current)
        if not bok then
            os.remove(tmp)
            self.status, self.statusDetail = 'failed', 'Backup write failed: ' .. tostring(berr)
            return false, self.statusDetail
        end
        os.remove(self.path)     -- Windows os.rename will not overwrite
    end
    local rok, rerr = os.rename(tmp, self.path)
    if not rok then
        if current then writeAll(self.path, current) end   -- restore original
        os.remove(tmp)
        self.status, self.statusDetail = 'failed', 'Replace failed: ' .. tostring(rerr)
        return false, self.statusDetail
    end
    self.saveCount = self.saveCount + 1
    self.lastSavedAt = os.date('%Y-%m-%d %H:%M:%S')
    self.status, self.statusDetail = 'saved', ('Saved %s'):format(self.lastSavedAt)
    return true
end

--- Protected bag list from INI override, or the config default.
--- @return number[]|nil list, string|nil error (error => selling must be blocked)
function store:protectedBags(defaultList)
    local text = self.record.protectedBagsText
    if text == nil or trim(text) == '' then
        local copy = {}
        for i, v in ipairs(defaultList or {}) do copy[i] = v end
        return copy
    end
    return store.parseProtectedBags(text)
end

return store
