--[[==========================================================================
  FILE        : Farm_Vendor/core.lua
  PACKAGE     : Farm Vendor  (MacroQuest Lua / EverQuest)
  VERSION     : 1.3.0
  CHANGES     : 1.3.0  Consolidation. log.lua and store.lua were merged into
                       this one file as two sections. Code is unchanged (a
                       token comparison against 1.2.2 proves it); each section
                       keeps its private locals inside a do ... end block.
                       Every function now has a WHAT, WHY, WHERE, HOW and
                       WHEN block and every code line is explained.
                1.0.0 to 1.2.2  See the HISTORY line of each section and
                       CHANGELOG.md.

  CREDITS     : Original to Farm Vendor. The idea of a remembered sell list
                kept in an INI file comes from AutoVendor 3.6 by Ionis
                (RedGuides resource 1930); no code was copied. Full lineage
                in README.md, Credits.

  WHAT  : The two foundation services every other file stands on:
            log    structured events to the MacroQuest console, an optional
                   rotating log file, and the in-window Activity Log
            store  the per server, per character INI file that remembers
                   which items you checked, with atomic, verified saves

  WHY   : Both are plain Lua (standard io and os only), neither issues a game
          command, and neither depends on any other Farm Vendor file. Keeping
          them together gives one place to look for "how does Farm Vendor
          write to disk", and one require for init.lua.

  WHERE : <MacroQuest>/lua/Farm_Vendor/core.lua
          Required only by init.lua. The log table is then passed by init.lua
          to the selling engine and the UI through the shared app table.

  HOW   : local core = require('Farm_Vendor.core')
          local log, store = core.log, core.store
          The sections run top to bottom; they do not call each other.

  WHEN  : Loaded once, at /lua run Farm_Vendor, before anything is shown.

  READING GUIDE
    - Rule kept from 1.0.x: nothing in this file requires another Farm Vendor
      file and nothing here sends a slash command. core is the bottom of the
      dependency graph.
    - "core.lua/log" in a comment means the log section of this file.
==========================================================================]]--

-- Section tables, declared up front so each section below and the return at
-- the bottom can see them. Each is filled inside its own do ... end block,
-- which keeps that section's private helpers private.
local log   = {}   -- log section, see its block below
local store = {}   -- store section, see its block below

--[[==========================================================================
  SECTION     : log   (was Farm_Vendor/log.lua up to 1.2.2)
  HISTORY     : 1.2.0  Console prefix renamed to [FarmVendor].
                1.0.0  First release.

  WHAT  : Structured logging. Every event has a timestamp, a level (DEBUG,
          INFO, WARN, ERROR), a dotted event name such as sale.verified, and
          key=value fields sorted by key. Example:
            2026-10-13 14:02:11 INFO  sale.verified id=13073 name="Bone Chips" pack=3 qty=20 slot=5

  WHY   : When a sale misbehaves in game, the log is the evidence. A fixed,
          machine friendly format makes lines easy to search, compare and
          paste into a bug report, and it means one bad item name can never
          break the format.

  WHERE : Used by init.lua directly and by engine.lua/seller and ui.lua
          through app.log.

  HOW   : Three destinations per event:
            1. MacroQuest console through print (MQ2Lua sends print to chat)
            2. Optional file under mq.configDir, rotated at LOG_MAX_BYTES
            3. A bounded in memory ring the UI shows as the Activity Log
          A file error is reported once and file logging is switched off for
          the session, so logging can never crash the script.

  WHEN  : configure() once at startup, then event() and the level helpers
          whenever something worth recording happens.
==========================================================================]]--
--#BODY log
do
    -- Numeric rank per level, so "is this level at or above the threshold"
    -- is a single comparison.
    local LEVEL_RANK = { DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4 }
    local MAX_VALUE_LEN = 200   -- longest field value kept before "..." truncation

    -- Logger state. Filled with safe defaults so logging works even if an
    -- event is raised before configure() runs.
    local state = {
        prefix       = '[FarmVendor]',     -- console tag on every line
        consoleRank  = LEVEL_RANK.INFO,    -- minimum level printed to chat
        fileRank     = LEVEL_RANK.DEBUG,   -- minimum level written to file
        filePath     = nil,      -- nil disables file logging
        maxBytes     = 1048576,            -- rotate the file above this size
        ring         = {},       -- array of {level=, text=}
        ringMax      = 200,                -- Activity Log length
        ringVersion  = 0,        -- increments on every append (UI can detect change)
        fileFailed   = false,              -- true after the first file error
    }

    --[[--------------------------------------------------------------------
      sanitize(s)  (private)

      WHAT  : Turns any value into a single line string no longer than
              MAX_VALUE_LEN characters.
      WHY   : Item names and error messages come from the game and can hold
              newlines or control characters that would split one log line
              into several or corrupt the file.
      WHERE : formatValue and log.event in this section.
      HOW   : tostring, replace every control character with a space, then
              cut to length and add "..." when cut.
      WHEN  : For every event name and every field value.
    ----------------------------------------------------------------------]]
    --- Remove control characters and limit length.
    local function sanitize(s)
        s = tostring(s)                       -- accept numbers, booleans, nil
        s = s:gsub('[%c]', ' ')               -- control characters become spaces
        if #s > MAX_VALUE_LEN then s = s:sub(1, MAX_VALUE_LEN) .. '...' end  -- cap length
        return s                              -- one clean line
    end

    --[[--------------------------------------------------------------------
      formatValue(v)  (private)

      WHAT  : Formats one field value: bare when simple, double quoted with
              escapes when it contains spaces, quotes or an equals sign.
      WHY   : key=value lines must stay unambiguous: a name like
              Bone Chips must not look like two fields.
      WHERE : formatFields and writeFile in this section.
      HOW   : sanitize, then quote and escape backslashes and quotes when a
              space, quote or = is present, or the value is empty.
      WHEN  : For every field of every event.
    ----------------------------------------------------------------------]]
    --- Format one field value: bare if simple, quoted if it has spaces/specials.
    local function formatValue(v)
        local s = sanitize(v)                 -- single line, bounded length
        if s == '' or s:find('[%s"=]') then
            -- Escape backslashes first, then quotes, then wrap in quotes.
            s = '"' .. s:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
        end
        return s                              -- ready to place after key=
    end

    --[[--------------------------------------------------------------------
      formatFields(fields)  (private)

      WHAT  : Builds "k=v k=v" from a table, keys sorted alphabetically.
      WHY   : Sorted keys make two log lines for the same event line up, so
              differences are easy to spot.
      WHERE : log.event in this section.
      HOW   : Collects and sorts the keys, cleans each key to letters,
              digits, _ and ., formats each value, joins with spaces.
      WHEN  : Once per event.
    ----------------------------------------------------------------------]]
    --- Build "k=v k=v" with keys sorted.
    local function formatFields(fields)
        if type(fields) ~= 'table' then return '' end            -- no fields
        local keys = {}                                          -- key names
        for k in pairs(fields) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)                                         -- stable order
        local parts = {}                                         -- "k=v" pieces
        for _, k in ipairs(keys) do
            local key = sanitize(k):gsub('[^%w_%.]', '_')        -- safe key text
            parts[#parts + 1] = key .. '=' .. formatValue(fields[k])
        end
        return table.concat(parts, ' ')                          -- one string
    end

    --[[--------------------------------------------------------------------
      rotateIfNeeded()  (private)

      WHAT  : Renames the log file to <file>.1 when it has grown past
              state.maxBytes, keeping exactly one backup.
      WHY   : A log that grows forever eventually fills a disk or becomes
              too large to open.
      WHERE : writeFile in this section.
      HOW   : Opens the file, seeks to the end to read its size, and if too
              big removes any old .1 and renames the current file to .1.
      WHEN  : Before each line is appended.
    ----------------------------------------------------------------------]]
    --- Rotate the file when it exceeds maxBytes (keeps exactly one .1 backup).
    local function rotateIfNeeded()
        local f = io.open(state.filePath, 'rb')      -- read only, to measure
        if not f then return end                      -- no file yet
        local size = f:seek('end')                    -- size in bytes
        f:close()                                     -- release the handle
        if size and size > state.maxBytes then
            local backup = state.filePath .. '.1'     -- single backup name
            os.remove(backup)                -- ok if it does not exist
            os.rename(state.filePath, backup)         -- current becomes .1
        end
    end

    --[[--------------------------------------------------------------------
      writeFile(line)  (private)

      WHAT  : Appends one formatted line to the log file.
      WHY   : The file keeps DEBUG detail that the console hides, which is
              what is needed after the fact to explain a failed sale.
      WHERE : log.event in this section.
      HOW   : Skips when no path is set or the file already failed. Runs
              rotate, open, write and close inside pcall; on any error it
              switches file logging off and prints one console line.
      WHEN  : For each event at or above the file level.
    ----------------------------------------------------------------------]]
    local function writeFile(line)
        if not state.filePath or state.fileFailed then return end   -- disabled
        local ok, err = pcall(function()
            rotateIfNeeded()                                         -- size guard
            local f, openErr = io.open(state.filePath, 'a')          -- append mode
            if not f then error(openErr or 'unable to open log file') end
            f:write(line, '\n')                                      -- one line
            f:close()                                                -- flush to disk
        end)
        if not ok then
            -- Report once, then stop trying for the rest of the session.
            state.fileFailed = true
            print(('%s ERROR log.file_disabled path=%s error=%s'):format(
                state.prefix, formatValue(state.filePath), formatValue(err)))
        end
    end

    --[[--------------------------------------------------------------------
      log.configure(opts)

      WHAT  : Sets the console prefix, the two level thresholds, the file
              path (or nil), the rotation size and the Activity Log length.
      WHY   : These come from config.lua and the character name, which are
              only known once init.lua has validated the session.
      WHERE : init.lua, once, before the first startup event.
      HOW   : Copies each provided option over the current state; missing
              or unknown values keep the defaults. Clears fileFailed so a new
              path gets a fresh chance. Safe to call more than once.
      WHEN  : Startup.
    ----------------------------------------------------------------------]]
    --- Configure the logger. Safe to call more than once.
    --- @param opts table {prefix, consoleLevel, fileLevel, filePath|nil, maxBytes, ringMax}
    function log.configure(opts)
        opts = opts or {}                                            -- allow nil
        state.prefix      = opts.prefix or state.prefix              -- console tag
        state.consoleRank = LEVEL_RANK[opts.consoleLevel] or state.consoleRank
        state.fileRank    = LEVEL_RANK[opts.fileLevel] or state.fileRank
        state.filePath    = opts.filePath                            -- nil = off
        state.maxBytes    = opts.maxBytes or state.maxBytes          -- rotation size
        state.ringMax     = opts.ringMax or state.ringMax            -- UI lines kept
        state.fileFailed  = false                                    -- retry file
    end

    --[[--------------------------------------------------------------------
      log.event(level, event, fields)

      WHAT  : Records one event to the console, file and Activity Log,
              each filtered by its own threshold.
      WHY   : One function means every destination gets the same text and
              format, and an unknown level can never be lost.
      WHERE : log.debug/info/warn/error below, and anywhere in the package.
      HOW   : Normalises the level (unknown becomes INFO), builds the body
              "event k=v ...", stamps it, prints, writes the file, and adds
              INFO and above to the ring, trimming it to ringMax and bumping
              ringVersion so the UI knows to scroll.
      WHEN  : Any time something is worth recording.
    ----------------------------------------------------------------------]]
    --- Core emit function.
    --- @param level string  DEBUG|INFO|WARN|ERROR
    --- @param event string  dotted event name
    --- @param fields table|nil key/value pairs
    function log.event(level, event, fields)
        local rank = LEVEL_RANK[level] or LEVEL_RANK.INFO            -- unknown = INFO
        level = LEVEL_RANK[level] and level or 'INFO'                -- printed label
        local body = sanitize(event)                                 -- event name
        local f = formatFields(fields)                               -- "k=v ..."
        if f ~= '' then body = body .. ' ' .. f end
        local stamp = os.date('%Y-%m-%d %H:%M:%S')                   -- local time
        local line = ('%s %-5s %s'):format(stamp, level, body)       -- file line

        -- Console: prefix and level, no timestamp (chat already has one).
        if rank >= state.consoleRank then
            print(('%s %s %s'):format(state.prefix, level, body))
        end
        if rank >= state.fileRank then writeFile(line) end           -- file copy

        -- UI ring keeps INFO and above (DEBUG would drown the panel)
        if rank >= LEVEL_RANK.INFO then
            local ring = state.ring                                  -- shorthand
            ring[#ring + 1] = { level = level, text = os.date('%H:%M:%S') .. ' ' .. body }
            while #ring > state.ringMax do table.remove(ring, 1) end -- oldest out
            state.ringVersion = state.ringVersion + 1                -- tell the UI
        end
    end

    --[[--------------------------------------------------------------------
      log.debug / log.info / log.warn / log.error (event, fields)

      WHAT  : One line shortcuts for log.event at a fixed level.
      WHY   : Shorter, and the level is obvious at the call site.
      WHERE : Everywhere in the package.
      HOW   : Each calls log.event with its level.
      WHEN  : Any time something is worth recording.
    ----------------------------------------------------------------------]]
    -- Level shortcuts; each passes its fixed level to log.event.
    function log.debug(event, fields) log.event('DEBUG', event, fields) end
    -- INFO: normal milestones such as startup.ready and sale.verified.
    function log.info(event, fields)  log.event('INFO',  event, fields) end
    -- WARN: something was refused or skipped but the script is healthy.
    function log.warn(event, fields)  log.event('WARN',  event, fields) end
    -- ERROR: something failed and usually blocks selling.
    function log.error(event, fields) log.event('ERROR', event, fields) end

    --[[--------------------------------------------------------------------
      log.ring() / log.ringVersion() / log.filePath()

      WHAT  : Read only views for the UI: the Activity Log lines, a counter
              that changes whenever a line is added, and the file path (nil
              when file logging is off or failed).
      WHY   : The UI must show the log without being able to change it.
      WHERE : ui.lua drawActivity.
      HOW   : Return the internal values.
      WHEN  : Every frame the main window is drawn.
    ----------------------------------------------------------------------]]
    --- Read-only access for the UI.
    function log.ring() return state.ring end
    -- Changes on every append; the UI scrolls to the bottom when it changes.
    function log.ringVersion() return state.ringVersion end
    -- nil when file logging is disabled or has failed this session.
    function log.filePath() return (not state.fileFailed) and state.filePath or nil end
end
--#END log
--[[==========================================================================
  END OF SECTION : log
  PUBLIC : configure, event, debug, info, warn, error, ring, ringVersion,
           filePath
==========================================================================]]--

--[[==========================================================================
  SECTION     : store   (was Farm_Vendor/store.lua up to 1.2.2)
  HISTORY     : 1.2.0  File names and Tool= value renamed to Farm_Vendor.
                1.0.0  First release.

  WHAT  : Per server, per character INI storage for the items you checked.
          File: <mq.configDir>/Farm_Vendor_<server>_<character>.ini
          Server and character names are percent encoded so any character
          unsafe in a Windows file name becomes %XX.

          File format (schema 1)
            [Meta]
            Schema=1
            Tool=Farm_Vendor
            [Settings]
            ProtectedBags=1,2          ; optional, pack numbers 1-12
            [SelectedItems]
            13073=1                    ; item ID = 1 (checked)
            [ItemNames]
            13073=Bone Chips           ; readability only, never matched

  WHY   : Remembered checks save you ticking the same trash every visit.
          Losing or corrupting them silently would be worse than not having
          them, so every rule below fails closed.

  WHERE : init.lua creates one store with store.new and calls load, save,
          setSelections and protectedBags. ui.lua reads status fields only.

  HOW   : Rules carried from MagFarm:
            * The file is data, never executed (no loadstring or dofile).
            * Writes go to <file>.tmp, are read back and parsed, the current
              file is copied to <file>.bak, then the temp file replaces it.
              On failure the previous file is restored when possible.
            * A file with an unsupported schema is read only, never
              overwritten.
            * Unknown sections are preserved word for word on rewrite.
            * Status is explicit: new, loaded, loaded_with_warnings,
              readonly, saved, failed. A failed save is never a success.
            * Remembered checks never trigger a sale; they only pre tick.

  WHEN  : load at startup; save when you press Save Selections or Confirm
          Sale.
==========================================================================]]--
--#BODY store
do
    -- Section names this version understands; anything else is preserved.
    local KNOWN_SECTIONS = { Meta = true, Settings = true, SelectedItems = true, ItemNames = true }
    local MAX_ITEM_ID = 2147483647   -- largest 32 bit signed ID; above is corrupt
    local MAX_LINES = 50000          -- stop reading a runaway file here

    --[[--------------------------------------------------------------------
      store.encodeName(s)

      WHAT  : Percent encodes everything that is not a letter or digit.
      WHY   : Server and character names become part of a file name; a
              space or symbol must not break the path on Windows.
      WHERE : init.lua when it builds the INI and log file names.
      HOW   : gsub every non alphanumeric character to %XX (hex byte).
      WHEN  : Startup.
    ----------------------------------------------------------------------]]
    --- Percent-encode anything that is not a letter or digit.
    function store.encodeName(s)
        -- Outer parentheses keep only the string, not gsub's match count.
        return (tostring(s):gsub('[^%w]', function(c) return ('%%%02X'):format(c:byte()) end))
    end

    --[[--------------------------------------------------------------------
      trim(s)  (private)

      WHAT  : Removes leading and trailing white space.
      WHY   : Hand edited INI lines often carry stray spaces.
      WHERE : Throughout this section.
      HOW   : Two anchored gsub calls.
      WHEN  : While parsing.
    ----------------------------------------------------------------------]]
    -- Strip leading then trailing white space; parentheses drop the count.
    local function trim(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end

    --[[--------------------------------------------------------------------
      store.parseProtectedBags(text)

      WHAT  : Parses a ProtectedBags value such as "1, 2" into a sorted list
              of unique pack numbers. Returns list, or nil and an error.
      WHY   : A typo here must block selling rather than quietly protect
              nothing, so invalid text is an error, not "no bags".
      WHERE : store:protectedBags below.
      HOW   : Splits on commas, requires each token to be digits only and
              1 to 12, drops duplicates, sorts. Empty text is an empty list.
      WHEN  : Startup, after the INI loads.
    ----------------------------------------------------------------------]]
    --- Parse a ProtectedBags value. Returns list or nil,error.
    function store.parseProtectedBags(text)
        local list, seen = {}, {}                    -- result and duplicate guard
        text = trim(text or '')                      -- tolerate nil and spaces
        if text == '' then return list end           -- nothing protected
        for token in text:gmatch('[^,]+') do         -- each comma separated part
            local t = trim(token)
            local n = tonumber(t)
            -- Digits only and within pack1..pack12, otherwise refuse.
            if not t:match('^%d+$') or not n or n < 1 or n > 12 then
                return nil, ('invalid pack number %q (allowed 1-12)'):format(t)
            end
            if not seen[n] then list[#list + 1] = n; seen[n] = true end  -- unique
        end
        table.sort(list)                             -- stable order for display
        return list
    end

    --[[--------------------------------------------------------------------
      store.parse(text, opts)

      WHAT  : Parses INI text into a record {schema, tool, protectedBagsText,
              selected, names, extra} and a list of warnings. Never raises.
      WHY   : The file may be hand edited, truncated or from a future
              version. Bad lines are skipped with a warning instead of
              crashing or guessing.
      WHERE : store:load and the read back check in store:save.
      HOW   : Line by line: comments and blanks skipped (kept inside unknown
              sections), [Section] headers switch context, key=value lines
              are applied per section. Item IDs must be 1..MAX_ITEM_ID;
              SelectedItems values must be 0 or 1. Unknown sections are kept
              verbatim in rec.extra. Reading stops after MAX_LINES.
      WHEN  : Startup, and during every save.
    ----------------------------------------------------------------------]]
    --- Parse INI text into a structured record. Never raises.
    --- @return table record, string[] warnings
    function store.parse(text, opts)
        opts = opts or {}                                   -- allow nil
        local maxName = opts.maxNameLength or 128           -- name length cap
        -- Empty record; filled as lines are read.
        local rec = {
            schema = nil, tool = nil,
            protectedBagsText = nil,
            selected = {},     -- [id:number] = true
            names = {},        -- [id:number] = string
            extra = {},        -- preserved unknown sections: array of {name=, lines={}}
        }
        local warnings = {}                                 -- human readable notes
        local section, extraSection = nil, nil              -- current context
        local lineNo = 0                                    -- for warning text

        -- Appending a newline guarantees the last line is matched too.
        for raw in (text .. '\n'):gmatch('([^\n]*)\n') do
            lineNo = lineNo + 1
            if lineNo > MAX_LINES then
                -- Runaway file: keep what was read, say where it stopped.
                warnings[#warnings + 1] = ('stopped reading after %d lines'):format(MAX_LINES)
                break
            end
            local line = trim(raw:gsub('\r$', ''))          -- drop Windows CR
            -- Blank lines and ; or # comments carry no data.
            if line == '' or line:sub(1, 1) == ';' or line:sub(1, 1) == '#' then
                -- Inside an unknown section keep them so the rewrite is faithful.
                if extraSection then extraSection.lines[#extraSection.lines + 1] = raw:gsub('\r$', '') end
            else
                local name = line:match('^%[([^%]]+)%]$')    -- [Section] header?
                if name then
                    name = trim(name)
                    if KNOWN_SECTIONS[name] then
                        section, extraSection = name, nil    -- one we understand
                    elseif name:match('^[%w_%.%-]+$') then
                        -- Valid but unknown: preserve the whole section.
                        section = nil
                        extraSection = { name = name, lines = {} }
                        rec.extra[#rec.extra + 1] = extraSection
                    else
                        -- Malformed header: ignore it and everything under it.
                        section, extraSection = nil, nil
                        warnings[#warnings + 1] = ('line %d: ignored invalid section name'):format(lineNo)
                    end
                elseif extraSection then   -- line belongs to an unknown section
                    -- Data line inside an unknown section: keep word for word.
                    extraSection.lines[#extraSection.lines + 1] = (raw:gsub('\r$', ''))
                else
                    local key, value = line:match('^([^=]+)=(.*)$')   -- key=value
                    if not key then
                        warnings[#warnings + 1] = ('line %d: ignored (expected key=value)'):format(lineNo)
                    else
                        key, value = trim(key), trim(value)   -- ignore spaces around both sides
                        if section == 'Meta' then   -- [Meta] keys
                            -- Schema decides whether the file may be written.
                            if key == 'Schema' then rec.schema = tonumber(value)
                            elseif key == 'Tool' then rec.tool = value end
                        elseif section == 'Settings' then
                            -- Kept as text; parsed later so errors block selling.
                            if key == 'ProtectedBags' then rec.protectedBagsText = value end
                        elseif section == 'SelectedItems' or section == 'ItemNames' then
                            -- Both sections are keyed by a positive item ID.
                            local id = key:match('^%d+$') and tonumber(key)
                            if not id or id < 1 or id > MAX_ITEM_ID then
                                warnings[#warnings + 1] = ('line %d: ignored invalid item ID %q'):format(lineNo, key)
                            elseif section == 'SelectedItems' then   -- [SelectedItems] line
                                -- Only 1 checks; 0 is allowed; anything else warns.
                                if value == '1' then rec.selected[id] = true
                                elseif value ~= '0' then
                                    warnings[#warnings + 1] = ('line %d: item %d value must be 0 or 1; left unchecked'):format(lineNo, id)
                                end
                            else
                                -- Display name only: strip control characters, cap.
                                local clean = value:gsub('%c', '')
                                rec.names[id] = clean:sub(1, maxName)
                            end
                        else
                            -- key=value before any section header.
                            warnings[#warnings + 1] = ('line %d: key outside a known section ignored'):format(lineNo)
                        end
                    end
                end
            end
        end
        return rec, warnings   -- parsed record plus ignored line notes
    end

    --[[--------------------------------------------------------------------
      store.serialize(rec, opts)

      WHAT  : Turns a record back into schema 1 INI text.
      WHY   : One writer that always produces the same layout makes saved
              files predictable and diff friendly.
      WHERE : store:save.
      HOW   : Writes two comment lines, [Meta], [Settings], the checked IDs
              in ascending order under [SelectedItems], the same IDs with
              cleaned names under [ItemNames], then any preserved unknown
              sections exactly as read.
      WHEN  : Every save.
    ----------------------------------------------------------------------]]
    --- Serialize a record to INI text (schema 1).
    function store.serialize(rec, opts)
        opts = opts or {}                                   -- allow nil
        local maxName = opts.maxNameLength or 128           -- name length cap
        local out = {}                                      -- output lines
        -- Append one line to the output.
        local function add(s) out[#out + 1] = s end
        add('; Farm Vendor selections. Data only; edit with care.')
        add('; Item IDs are authoritative. [ItemNames] is for readability only.')
        add('[Meta]')   -- section header
        add('Schema=' .. tostring(opts.schema or 1))        -- version guard
        add('Tool=Farm_Vendor')
        add('[Settings]')
        -- Always write the key so users can see where to set it.
        if rec.protectedBagsText and rec.protectedBagsText ~= '' then
            add('ProtectedBags=' .. rec.protectedBagsText)
        else
            add('ProtectedBags=')   -- empty value: use config default
        end
        local ids = {}                                      -- checked IDs
        for id in pairs(rec.selected) do ids[#ids + 1] = id end
        table.sort(ids)                                     -- ascending order
        add('[SelectedItems]')
        for _, id in ipairs(ids) do add(('%d=1'):format(id)) end
        add('[ItemNames]')
        for _, id in ipairs(ids) do   -- one name line per checked ID
            -- Same cleaning as parse, so a save then load is lossless.
            local n = (rec.names[id] or ''):gsub('%c', ''):sub(1, maxName)
            add(('%d=%s'):format(id, n))
        end
        -- Unknown sections go back exactly as they were read.
        for _, sec in ipairs(rec.extra or {}) do
            add('[' .. sec.name .. ']')
            for _, l in ipairs(sec.lines) do add(l) end
        end
        return table.concat(out, '\n') .. '\n'              -- trailing newline
    end

    --[[--------------------------------------------------------------------
      readAll(path, maxBytes)  (private)

      WHAT  : Reads a whole file. Returns the text, or nil and 'missing' or
              a size error.
      WHY   : A missing file is normal (first run); an oversized one is a
              sign of corruption and must not be loaded.
      WHERE : store:load and store:save.
      HOW   : Opens in binary, seeks to the end for the size, refuses above
              maxBytes, rewinds and reads everything.
      WHEN  : Load, and twice during each save.
    ----------------------------------------------------------------------]]
    local function readAll(path, maxBytes)
        local f = io.open(path, 'rb')                       -- binary keeps CRs
        if not f then return nil, 'missing' end             -- first run
        local size = f:seek('end')                          -- size in bytes
        if size and maxBytes and size > maxBytes then
            f:close()                                       -- refuse oversized
            return nil, ('file is %d bytes, above the %d byte limit'):format(size, maxBytes)
        end
        f:seek('set', 0)                                    -- back to the start
        local data = f:read('*a')                           -- whole file
        f:close()
        return data or ''
    end

    --[[--------------------------------------------------------------------
      writeAll(path, data)  (private)

      WHAT  : Writes a whole file. Returns true, or false and an error.
      WHY   : A save must know for certain whether every byte reached disk;
              write and close can each fail separately.
      WHERE : store:save.
      HOW   : Opens in binary, writes, closes, checks both results.
      WHEN  : During each save (temp file, backup, restore).
    ----------------------------------------------------------------------]]
    local function writeAll(path, data)
        local f, err = io.open(path, 'wb')                  -- truncate or create
        if not f then return false, err or 'open failed' end
        local ok, werr = f:write(data)                      -- all bytes
        local cok, cerr = f:close()                         -- flush
        if not ok then return false, werr or 'write failed' end
        if not cok then return false, cerr or 'close failed' end
        return true
    end

    -- -----------------------------------------------------------------------
    -- Store object
    -- -----------------------------------------------------------------------

    --[[--------------------------------------------------------------------
      store.new(path, opts)

      WHAT  : Creates a store object bound to one INI file.
      WHY   : An object keeps the path, options, record and status together
              so the UI can show status without touching the file.
      WHERE : init.lua, once.
      HOW   : Builds the table with an empty record and status 'new', and
              sets store as its metatable index so store:load and the rest
              work as methods.
      WHEN  : Startup, after the file name is known.
    ----------------------------------------------------------------------]]
    --- Create a store bound to one file.
    --- @param path string full path
    --- @param opts table {schema, maxBytes, maxNameLength}
    function store.new(path, opts)
        local self = {
            path = path,                                    -- INI file
            opts = opts or {},                              -- limits from config
            record = { selected = {}, names = {}, extra = {}, protectedBagsText = nil },
            status = 'new',          -- see header for allowed values
            statusDetail = '',                              -- human text for the UI
            warnings = {},                                  -- from the last parse
            readonly = false,                               -- true blocks saving
            lastSavedAt = nil,                              -- timestamp text
            saveCount = 0,           -- session-local counter, not an audit record
        }
        return setmetatable(self, { __index = store })      -- methods
    end

    --[[--------------------------------------------------------------------
      store:load()

      WHAT  : Loads the INI. Returns true, or false and a reason.
      WHY   : Remembered checks must come back exactly, and a file this
              version cannot understand must be protected from overwrite.
      WHERE : init.lua at startup.
      HOW   : Missing file means status 'new' (not an error). Unreadable or
              oversized means read only. A schema other than the configured
              one means read only with the data kept for display. Otherwise
              the record is taken and status is loaded or
              loaded_with_warnings.
      WHEN  : Startup.
    ----------------------------------------------------------------------]]
    --- Load from disk. Missing file => empty 'new' store (not an error).
    function store:load()
        local text, err = readAll(self.path, self.opts.maxBytes)
        if not text then
            if err == 'missing' then   -- no file yet is normal
                -- First run for this character: nothing saved yet.
                self.status, self.statusDetail = 'new', 'No saved selections yet'
                return true
            end
            -- Exists but cannot be read safely: never overwrite it.
            self.status, self.statusDetail, self.readonly = 'readonly', 'Unreadable: ' .. tostring(err), true
            return false, self.statusDetail
        end
        local rec, warnings = store.parse(text, { maxNameLength = self.opts.maxNameLength })   -- parse what was read
        self.warnings = warnings                            -- shown in the log
        local expected = self.opts.schema or 1
        if rec.schema ~= nil and rec.schema ~= expected then
            -- Unsupported schema: keep the user's data untouched, never overwrite.
            self.record = rec
            self.readonly = true
            self.status = 'readonly'
            self.statusDetail = ('Schema %s is not supported (expected %d). File preserved; saving disabled.')   -- explain why saving is off
                :format(tostring(rec.schema), expected)   -- fill in the schema numbers
            return false, self.statusDetail   -- load refused
        end
        self.record = rec                                   -- accept the data
        if #warnings > 0 then
            self.status = 'loaded_with_warnings'
            self.statusDetail = ('%d line(s) ignored; see log'):format(#warnings)
        else
            self.status, self.statusDetail = 'loaded', 'Selections loaded'   -- clean load
        end
        return true   -- loaded (possibly with warnings)
    end

    --[[--------------------------------------------------------------------
      store:setSelections(selected, names)

      WHAT  : Replaces the in memory checked set and names. Does not save.
      WHY   : Saving is a separate, verified step; this only prepares what
              the next save will write.
      WHERE : init.lua save().
      HOW   : Copies only true entries with numeric IDs, taking each name
              from the given table, then the old record, then ''.
      WHEN  : Right before each save.
    ----------------------------------------------------------------------]]
    --- Replace the checked set (in memory only). names: [id]=name
    function store:setSelections(selected, names)
        local sel, nm = {}, {}                              -- fresh tables
        for id, on in pairs(selected) do
            if on and type(id) == 'number' then
                sel[id] = true
                nm[id] = names[id] or self.record.names[id] or ''   -- best known name
            end
        end
        self.record.selected, self.record.names = sel, nm
    end

    --[[--------------------------------------------------------------------
      store:save()

      WHAT  : Atomic save with read back verification and backup. Returns
              true, or false and a reason.
      WHY   : A crash or full disk mid save must never leave a half written
              selections file, and a save that did not happen must never be
              reported as done (Confirm Sale depends on it).
      WHERE : init.lua save(), for Save Selections and before every run.
      HOW   : 1. Refuse when read only.
              2. Serialize and write <file>.tmp.
              3. Read the temp file back, parse it, and compare the checked
                 set both ways.
              4. Copy the current file to <file>.bak.
              5. Remove the current file (Windows os.rename will not
                 overwrite) and rename the temp file into place; on failure
                 write the original back.
              6. Record the time and status 'saved'.
      WHEN  : Save Selections, and Confirm Sale before any selling.
    ----------------------------------------------------------------------]]
    --- Atomic save with read-back verification and backup restore.
    --- @return boolean ok, string|nil error
    function store:save()
        if self.readonly then
            return false, 'Store is read-only: ' .. self.statusDetail
        end
        local data = store.serialize(self.record, self.opts)          -- new text
        local tmp, bak = self.path .. '.tmp', self.path .. '.bak'

        -- Step 2: write the temp file.
        local ok, err = writeAll(tmp, data)
        if not ok then
            os.remove(tmp)   -- clean up partial temp file
            self.status, self.statusDetail = 'failed', 'Temp write failed: ' .. tostring(err)   -- record why
            return false, self.statusDetail   -- nothing was replaced
        end
        -- Read back and verify the temp file parses to the same selection set.
        local back = readAll(tmp, self.opts.maxBytes)
        local verify = back and store.parse(back, { maxNameLength = self.opts.maxNameLength })
        local same = verify ~= nil
        if same then   -- temp file parsed: compare sets
            -- Every checked ID must be in the file and nothing extra.
            for id in pairs(self.record.selected) do if not verify.selected[id] then same = false end end
            for id in pairs(verify.selected) do if not self.record.selected[id] then same = false end end
        end
        if not same then   -- mismatch: discard temp file
            os.remove(tmp)   -- remove unverified temp
            self.status, self.statusDetail = 'failed', 'Verification of temp file failed'   -- record why
            return false, self.statusDetail   -- original file untouched
        end
        -- Backup current file (if any).
        local current = readAll(self.path, self.opts.maxBytes)
        if current then
            local bok, berr = writeAll(bak, current)
            if not bok then   -- backup failed
                os.remove(tmp)   -- discard temp file
                self.status, self.statusDetail = 'failed', 'Backup write failed: ' .. tostring(berr)   -- record why
                return false, self.statusDetail   -- original file untouched
            end
            os.remove(self.path)     -- Windows os.rename will not overwrite
        end
        -- Step 5: move the verified temp file into place.
        local rok, rerr = os.rename(tmp, self.path)
        if not rok then
            if current then writeAll(self.path, current) end   -- restore original
            os.remove(tmp)
            self.status, self.statusDetail = 'failed', 'Replace failed: ' .. tostring(rerr)
            return false, self.statusDetail
        end
        -- Step 6: record success for the UI and log.
        self.saveCount = self.saveCount + 1
        self.lastSavedAt = os.date('%Y-%m-%d %H:%M:%S')
        self.status, self.statusDetail = 'saved', ('Saved %s'):format(self.lastSavedAt)
        return true   -- saved and verified
    end

    --[[--------------------------------------------------------------------
      store:protectedBags(defaultList)

      WHAT  : Returns the protected pack list: the INI ProtectedBags value
              when set, otherwise a copy of the config default. Returns nil
              and an error when the INI value is malformed.
      WHY   : A per character override lets one character protect a bag of
              tradeskill items without changing config.lua for everyone. A
              malformed value must block selling, never mean "none".
      WHERE : init.lua refreshProtected().
      HOW   : Blank or missing text gives a copy of defaultList; otherwise
              store.parseProtectedBags.
      WHEN  : Startup.
    ----------------------------------------------------------------------]]
    --- Protected bag list from INI override, or the config default.
    --- @return number[]|nil list, string|nil error (error => selling must be blocked)
    function store:protectedBags(defaultList)
        local text = self.record.protectedBagsText
        if text == nil or trim(text) == '' then
            -- No override: copy so callers cannot change config by accident.
            local copy = {}
            for i, v in ipairs(defaultList or {}) do copy[i] = v end
            return copy
        end
        return store.parseProtectedBags(text)                 -- may return nil, err
    end
end
--#END store
--[[==========================================================================
  END OF SECTION : store
  PUBLIC : encodeName, parseProtectedBags, parse, serialize, new,
           store:load, store:setSelections, store:save, store:protectedBags
==========================================================================]]--

-- Hand both section tables to init.lua.
return { log = log, store = store }

--[[==========================================================================
  END OF FILE : Farm_Vendor/core.lua

  PUBLIC  (returned table)
    log    configure, event, debug, info, warn, error, ring, ringVersion,
           filePath
    store  encodeName, parseProtectedBags, parse, serialize, new, and the
           methods load, setSelections, save, protectedBags

  DEPENDENCIES : standard Lua io, os, string, table only. No mq.

  HOW TO EDIT SAFELY
    - Never add a require of another Farm_Vendor file here.
    - Never send a game command from this file.
    - A change to the INI format needs a new INI_SCHEMA number in config.lua
      so older files are protected, plus a test in dev/run_tests.py.
    - Run python dev/run_tests.py and python dev/doc_audit.py afterwards.
==========================================================================]]--
