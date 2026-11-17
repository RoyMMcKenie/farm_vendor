--[[==========================================================================
  FILE        : Farm_Vendor/engine.lua
  PACKAGE     : Farm Vendor  (MacroQuest Lua / EverQuest)
  VERSION     : 1.4.0
  CHANGES     : 1.4.0  seller section: buildProposal takes the Never Sell
                       set and leaves those items out even if checked.
                       inventory section unchanged.
                1.3.0  Consolidation. inventory.lua and seller.lua were
                       merged into this one file as two sections. Code is
                       unchanged (token comparison against 1.2.2); the
                       seller section now uses the inventory section
                       directly instead of require('Farm_Vendor.inventory').
                       Every function has a WHAT, WHY, WHERE, HOW and WHEN
                       block and every code line is explained.
                1.0.0 to 1.2.2  See the HISTORY line of each section and
                       CHANGELOG.md.

  CREDITS     : The select then sell each stack workflow comes from
                Sellitem.mac by Cannonballdex (RedGuides) and the sell list
                built from your inventory from AutoVendor 3.6 by Ionis
                (RedGuides resource 1930). No code was copied: every command
                and TLO member here was chosen from the MacroQuest
                documentation (see AUDIT.md). Full lineage in README.md.

  WHAT  : Everything that reads the game or acts in it:
            inventory  read only scan of your pack slots and bags, exact
                       location re reads, coin reading and formatting
            seller     readiness checks, the confirmed sale proposal, and the
                       guarded worker that selects, waits for the merchant
                       quote, sells and verifies one stack at a time

  WHY   : The seller depends on the inventory reader and nothing else in the
          package does the same job. Together they are "the engine": every
          TLO read and every slash command Farm Vendor can send lives in this
          one file, which makes it the single place to audit.

  WHERE : <MacroQuest>/lua/Farm_Vendor/engine.lua
          Required by init.lua (both sections) and ui.lua (inventory, for
          coin formatting only).

  HOW   : local engine = require('Farm_Vendor.engine')
          local inventory, seller = engine.inventory, engine.seller
          The inventory section runs first so the seller section can use it
          as a plain local.

  WHEN  : Loaded once at /lua run Farm_Vendor. Nothing here runs at load
          time except table setup; work happens when init.lua calls in.

  READING GUIDE
    - Nothing in this file may run from the ImGui callback: mq.delay is not
      allowed there. ui.lua only sets request flags; init.lua's main loop
      calls the seller.
    - Every TLO read is wrapped in pcall. nil always means "unknown", and
      unknown always fails closed.
==========================================================================]]--

local mq = require('mq')   -- MacroQuest Lua API: TLO, cmdf, delay, gettime, event

-- Section tables, declared up front so each section and the return at the
-- bottom can see them. Each is filled inside its own do ... end block.
local inventory = {}   -- inventory section, see its block below
local seller    = {}   -- seller section, see its block below

--[[==========================================================================
  SECTION     : inventory   (was Farm_Vendor/inventory.lua up to 1.2.2)
  HISTORY     : 1.1.0  Merchant open state read once per scan, for the
                       "Merchant offers no price" exclusion
                       (EXCLUDE_UNPRICED_AT_MERCHANT).
                1.0.0  First release.

  WHAT  : Reads carried inventory and builds the checklist rows, one row per
          item ID, with every eligible stack's exact location.
            mq.TLO.Me.Inventory(slot)   character.Inventory[#]
            item.ID / Name / Stack / Value / NoDrop / Lore / Container /
              Item(n) / ItemSlot / ItemSlot2 / SellPrice

  WHY   : Selling is only safe if Farm Vendor knows exactly what is where.
          Reading here, and nowhere else, means one set of eligibility rules.

  WHERE : init.lua rescan() calls inventory.scan. The seller section calls
          readLocation and coinCopper. ui.lua calls formatCoin.

  HOW   : Scope is fail closed:
            * Only top level slots FIRST_PACK_SLOT..LAST_PACK_SLOT
              (23 = pack1 ... 34 = pack12). Equipped gear, bank, shared bank
              and cursor are never read for selling.
            * Bags themselves are never candidates. Items in protected packs
              are counted but never listed.
            * Any reading that is missing or not a positive whole number
              makes that entry ineligible with a visible reason.
          This section only reads. It sends no commands.

  WHEN  : On startup, Refresh Inventory, merchant open or close, Sell All
          Checked Items, Confirm Sale, after each run, and around each sale.
==========================================================================]]--
--#BODY inventory
do
    --[[--------------------------------------------------------------------
      read(fn)  (private)

      WHAT  : Calls fn and returns its value, or nil if it raised an error.
      WHY   : A TLO member can raise when the object behind it is gone (an
              empty slot, a merchant just closed). That must read as
              "unknown", never crash the script.
      WHERE : Every TLO read in this section.
      HOW   : pcall.
      WHEN  : Every read.
    ----------------------------------------------------------------------]]
    --- Safely evaluate a TLO accessor. Returns nil on error or nil value.
    local function read(fn)
        local ok, v = pcall(fn)          -- never let a TLO error escape
        if ok then return v end
        return nil                       -- unknown
    end

    --[[--------------------------------------------------------------------
      posInt(v)  (private)

      WHAT  : True when v is a whole number of at least 1.
      WHY   : IDs and stack sizes must be real positive counts; 0, negative,
              fractional or non numeric readings mean "unknown".
      WHERE : readEntry, exclusionReason, inventory.scan.
      HOW   : Type, range and floor checks.
      WHEN  : For every entry read.
    ----------------------------------------------------------------------]]
    local function posInt(v)
        -- Number, at least 1, and no fractional part.
        return type(v) == 'number' and v >= 1 and v == math.floor(v)
    end

    --[[--------------------------------------------------------------------
      readEntry(item, topSlot, subIndex)  (private)

      WHAT  : Converts a TLO item into a plain Lua table, or nil when the
              slot is empty.
      WHY   : Plain values can be compared later (before and after a sale)
              without touching the TLO again, and each read is guarded.
      WHERE : inventory.scan and inventory.readLocation.
      HOW   : Reads ID first; no positive ID means empty. Then reads the
              other members through read() and records the top slot, the
              pack number (slot - 22) and the 0 based sub slot.
      WHEN  : For every pack slot and bag slot scanned or re read.
    ----------------------------------------------------------------------]]
    --- Convert a TLO item to a plain Lua entry table, or nil if the slot is empty.
    --- @param item any MQ item userdata
    --- @param topSlot number top-level slot (23-34)
    --- @param subIndex number|nil 0-based sub slot inside a bag (nil for loose)
    local function readEntry(item, topSlot, subIndex)
        local id = read(function() return item.ID() end)
        if not posInt(id) then return nil end           -- empty slot
        -- Each member is read separately so one failure does not hide the rest.
        local e = {
            id        = id,
            name      = read(function() return item.Name() end),
            stack     = read(function() return item.Stack() end),   -- quantity in this stack
            value     = read(function() return item.Value() end),   -- merchant base value in copper
            sellPrice = read(function() return item.SellPrice() end),   -- price this merchant pays, if one is open
            noDrop    = read(function() return item.NoDrop() end),   -- NO DROP flag
            lore      = read(function() return item.Lore() end),   -- LORE flag
            container = read(function() return item.Container() end),   -- slot count; above 0 means a bag
            itemSlot  = read(function() return item.ItemSlot() end),   -- pack slot number as MacroQuest reports it
            itemSlot2 = read(function() return item.ItemSlot2() end),   -- 0 based slot inside the bag
            topSlot   = topSlot,   -- which pack slot (23 to 34) this came from
            pack      = topSlot - 22,                    -- pack1 = slot 23
            sub       = subIndex,                        -- 0-based, nil if loose
        }
        return e
    end

    --[[--------------------------------------------------------------------
      exclusionReason(e, cfg, protected, merchantOpen)  (private)

      WHAT  : Decides whether an entry may be offered for sale. Returns nil
              when eligible, otherwise the reason shown in the Notes column.
      WHY   : One ordered rule list means the reason you see is the first
              rule that blocked it, every time.
      WHERE : inventory.scan.
      HOW   : In order: protected bag, unknown name, is a container, unknown
              quantity, unknown value, zero value (option), unknown NO DROP,
              NO DROP (option), Lore (option), no merchant price while a
              merchant is open (option), then the location must be confirmed
              by ItemSlot and ItemSlot2.
      WHEN  : For every entry in every scan.
    ----------------------------------------------------------------------]]
    --- Decide whether an entry can be offered for sale; returns nil or a reason.
    local function exclusionReason(e, cfg, protected, merchantOpen)
        if protected[e.pack] then return 'Protected bag' end
        if type(e.name) ~= 'string' or e.name == '' then return 'Unknown name' end
        if type(e.container) == 'number' and e.container > 0 then return 'Container' end   -- bags are never sold
        if not posInt(e.stack) then return 'Unknown quantity' end   -- stack size must be readable
        if type(e.value) ~= 'number' then return 'Unknown value' end   -- value must be readable
        -- Optional exclusions from config.lua.
        if cfg.EXCLUDE_ZERO_VALUE and e.value <= 0 then return 'No merchant value' end
        if e.noDrop == nil then return 'Unknown NO DROP flag' end
        if cfg.EXCLUDE_NO_DROP and e.noDrop then return 'NO DROP excluded' end
        if cfg.EXCLUDE_LORE and e.lore then return 'Lore excluded' end   -- optional LORE exclusion
        -- With a merchant open, no price means this merchant will refuse it.
        if merchantOpen and cfg.EXCLUDE_UNPRICED_AT_MERCHANT
            and not (type(e.sellPrice) == 'number' and e.sellPrice > 0) then
            return 'Merchant offers no price'
        end
        -- Location must be confirmed by the documented ItemSlot/ItemSlot2 members.
        if e.itemSlot ~= e.topSlot then return 'Location unconfirmed' end
        if e.sub ~= nil and e.itemSlot2 ~= e.sub then return 'Location unconfirmed' end
        return nil                                        -- eligible
    end

    --[[--------------------------------------------------------------------
      inventory.scan(cfg, protectedList)

      WHAT  : Scans carried inventory. Returns {entries, rows, rowsById,
              protectedCount, scannedAt, merchantOpen}.
      WHY   : The checklist, the proposal and the change detection at
              Confirm Sale all start from one consistent snapshot.
      WHERE : init.lua rescan().
      HOW   : 1. Notes whether a merchant is open (prices depend on it).
              2. Walks each top slot; a bag's contents are read with
                 Item(n), 1 based, while ItemSlot2 is 0 based; a loose item
                 is one entry.
              3. Classifies each entry and groups by item ID into rows that
                 total quantity and stacks, list eligible entries and collect
                 reasons. Protected entries are counted and hidden.
              4. Sorts rows by name, then ID.
      WHEN  : See the section WHEN.
    ----------------------------------------------------------------------]]
    --- Scan carried inventory.
    --- @param cfg table config module
    --- @param protectedList number[] pack numbers to protect
    --- @return table result {entries=, rows=, rowsById=, protectedCount=, scannedAt=}
    function inventory.scan(cfg, protectedList)
        local merchantOpen = read(function() return mq.TLO.Merchant.Open() end) == true
        local protected = {}                              -- set of pack numbers
        for _, p in ipairs(protectedList or {}) do protected[p] = true end

        local entries = {}                                -- every stack found
        local protectedCount = 0                          -- hidden stacks

        -- Step 2: read every pack slot in range.
        for slot = cfg.FIRST_PACK_SLOT, cfg.LAST_PACK_SLOT do
            local top = mq.TLO.Me.Inventory(slot)
            local topEntry = readEntry(top, slot, nil)
            if topEntry then   -- something is in this pack slot
                local slots = topEntry.container          -- bag size, 0 if not a bag
                if type(slots) == 'number' and slots > 0 then
                    -- A bag: read its contents. Item(n) is 1-based per the item
                    -- datatype; ItemSlot2 is the 0-based sub slot.
                    for n = 1, slots do
                        local sub = top.Item(n)
                        local e = readEntry(sub, slot, n - 1)
                        if e then entries[#entries + 1] = e end   -- keep each item found inside the bag
                    end
                else
                    entries[#entries + 1] = topEntry          -- loose item in a pack slot
                end
            end
        end

        -- Classify and aggregate by item ID.
        local rows, rowsById = {}, {}
        for _, e in ipairs(entries) do
            e.excluded = exclusionReason(e, cfg, protected, merchantOpen)
            if e.excluded == 'Protected bag' then protectedCount = protectedCount + 1 end   -- count for the "hidden" note
            if e.excluded ~= 'Protected bag' then            -- protected items are hidden entirely
                local row = rowsById[e.id]
                if not row then
                    -- First stack of this ID: create its row.
                    row = {
                        id = e.id, name = e.name or ('Item ' .. e.id),
                        qty = 0, stacks = 0, eligibleQty = 0, eligibleStacks = 0,
                        value = e.value, sellPrice = e.sellPrice,   -- prices for the Price column
                        noDrop = e.noDrop, lore = e.lore,   -- flags for the Notes column
                        entries = {}, reasons = {},   -- stacks to sell, and why others are skipped
                    }
                    rowsById[e.id] = row   -- look up by ID for later stacks
                    rows[#rows + 1] = row   -- keep in display order
                end
                -- Totals include excluded stacks so Qty matches your bags.
                row.qty = row.qty + (posInt(e.stack) and e.stack or 0)
                row.stacks = row.stacks + 1
                if e.excluded then
                    row.reasons[e.excluded] = true            -- shown in Notes
                else
                    -- Eligible: count it and keep its exact location.
                    row.eligibleQty = row.eligibleQty + e.stack
                    row.eligibleStacks = row.eligibleStacks + 1
                    row.entries[#row.entries + 1] = e
                end
            end
        end
        -- Turn each row's reason set into sorted text.
        for _, row in ipairs(rows) do
            local list = {}
            for r in pairs(row.reasons) do list[#list + 1] = r end
            table.sort(list)   -- sorted so the text never reorders
            row.reasonText = table.concat(list, ', ')   -- e.g. "Lore excluded, NO DROP excluded"
            row.eligible = row.eligibleStacks > 0             -- checkbox enabled
        end
        -- Step 4: alphabetical, ties broken by ID so the order never jumps.
        table.sort(rows, function(a, b)
            local an, bn = a.name:lower(), b.name:lower()
            if an == bn then return a.id < b.id end
            return an < bn   -- alphabetical by name
        end)

        return {   -- the scan result used by the UI and seller
            entries = entries, rows = rows, rowsById = rowsById,   -- every stack, grouped rows, rows by ID
            protectedCount = protectedCount, scannedAt = os.time(), merchantOpen = merchantOpen,   -- summary values for the UI
        }
    end

    --[[--------------------------------------------------------------------
      inventory.readLocation(topSlot, subIndex)

      WHAT  : Re reads one exact location and returns a fresh entry, or nil
              when it is empty.
      WHY   : Right before and after each sale the seller must know the slot
              still holds the same item and how many remain.
      WHERE : seller:run, seller:sellOnce.
      HOW   : Loose item: readEntry on the top slot. Bag slot: readEntry on
              Item(subIndex + 1), because Item(n) is 1 based.
      WHEN  : Before each stack, and while waiting for each sale.
    ----------------------------------------------------------------------]]
    --- Re-read one exact location and return a fresh entry (or nil if empty).
    --- Used by the seller immediately before and after each action.
    function inventory.readLocation(topSlot, subIndex)
        local top = mq.TLO.Me.Inventory(topSlot)
        if subIndex == nil then return readEntry(top, topSlot, nil) end   -- loose
        return readEntry(top.Item(subIndex + 1), topSlot, subIndex)       -- in a bag
    end

    --[[--------------------------------------------------------------------
      inventory.coinCopper()

      WHAT  : Total carried coin in copper, or nil if any reading fails.
      WHY   : The report shows measured coin change beside the estimate, so
              you can see what the merchant actually paid.
      WHERE : seller:run, at the start and end of each run.
      HOW   : Reads Me.Platinum, Gold, Silver and Copper; all four must be
              numbers; total = p*1000 + g*100 + s*10 + c.
      WHEN  : Start and end of each run.
    ----------------------------------------------------------------------]]
    --- Total carried coin in copper using documented character members.
    --- Returns nil if any reading is unavailable (caller reports "unknown").
    function inventory.coinCopper()
        local me = mq.TLO.Me
        local p = read(function() return me.Platinum() end)
        local g = read(function() return me.Gold() end)   -- gold
        local s = read(function() return me.Silver() end)   -- silver
        local c = read(function() return me.Copper() end)   -- copper
        -- Any unknown reading makes the total unknown; never a partial sum.
        if type(p) ~= 'number' or type(g) ~= 'number' or type(s) ~= 'number' or type(c) ~= 'number' then
            return nil
        end
        return p * 1000 + g * 100 + s * 10 + c   -- total in copper
    end

    --[[--------------------------------------------------------------------
      inventory.formatCoin(copper)

      WHAT  : Formats copper as "1p 2g 3s 4c", omitting zero units, "0c"
              for zero, a leading "-" when negative, "Unavailable" for nil.
      WHY   : Matches how EverQuest players read coin.
      WHERE : ui.lua (prices, estimates, report) and seller:run (log).
      HOW   : Integer division by 1000, 100 and 10.
      WHEN  : Whenever coin is displayed.
    ----------------------------------------------------------------------]]
    --- Format copper as "1p 2g 3s 4c" (omits zero units; "0c" for zero).
    function inventory.formatCoin(copper)
        if type(copper) ~= 'number' then return 'Unavailable' end
        local neg = copper < 0                               -- remember the sign
        copper = math.floor(math.abs(copper))
        -- Split into units, largest first.
        local p = math.floor(copper / 1000); copper = copper % 1000
        local g = math.floor(copper / 100);  copper = copper % 100
        local s = math.floor(copper / 10);   local c = copper % 10
        local parts = {}   -- unit strings
        if p > 0 then parts[#parts + 1] = p .. 'p' end   -- platinum
        if g > 0 then parts[#parts + 1] = g .. 'g' end   -- gold
        if s > 0 then parts[#parts + 1] = s .. 's' end   -- silver
        if c > 0 or #parts == 0 then parts[#parts + 1] = c .. 'c' end   -- "0c" for zero
        return (neg and '-' or '') .. table.concat(parts, ' ')
    end
end
--#END inventory
--[[==========================================================================
  END OF SECTION : inventory
  PUBLIC : scan, readLocation, coinCopper, formatCoin
==========================================================================]]--

--[[==========================================================================
  SECTION     : seller   (was Farm_Vendor/seller.lua up to 1.2.2)
  HISTORY     : 1.4.0  buildProposal skips Never Sell items (second guard
                       behind the disabled Sell checkbox).
                1.3.0  Moved into engine.lua; no code change.
                1.1.1  POST_QUOTE_DELAY_MS raised to 500; one bounded retry
                       when the merchant refuses right after a valid quote;
                       quotes must name the selected item.
                1.2.0  Chat event names renamed fv_quote and fv_refusal.
                1.1.0  Waits for the merchant quote before /sellitem;
                       priced only estimate with an unpriced count.
                1.0.0  First release.

  WHAT  : Readiness checks, sale proposals, and the guarded selling worker.
            mq.TLO.EverQuest.GameState()     'INGAME' required
            mq.TLO.Merchant.Open / ItemsReceived / ID / CleanName /
              SelectedItem
            mq.TLO.Cursor.ID()               something on the cursor
            mq.TLO.Macro.Name()              a macro is running
            /itemnotify in packN <slot#> leftmouseup   select in a bag
            /itemnotify <slot#> leftmouseup            select a loose item
            /sellitem <qty>                  sell the selected item
            mq.delay, mq.gettime             bounded waits
            mq.event / unevent / doevents / flushevents   merchant chat

  WHY   : This is the only code that can lose you an item, so it follows a
          strict safety contract:
            * Nothing here runs from an ImGui callback.
            * A proposal is a snapshot of exact locations and quantities;
              the run sells only what that confirmed snapshot lists.
            * Before every action the exact slot is re read; it must still
              hold the same item ID and stack size.
            * Selection must be confirmed by Merchant.SelectedItem (ID,
              ItemSlot, ItemSlot2) and the merchant's quote for that item
              must arrive before /sellitem. A refusal fails at once.
            * A sale counts only when the stack is verified gone or reduced.
            * Every wait is bounded. Failures follow ON_FAILURE, capped by
              MAX_FAILURES_PER_RUN. Cursor, merchant change or close, game
              state and a macro starting always stop the run.
            * Stop is honoured between items and ends any wait early. A
              completed sale cannot be undone.

  WHERE : init.lua creates one seller with seller.new and calls readiness,
          buildProposal, run, registerEvents, unregisterEvents and
          flushMerchantEvents. ui.lua reads mode, running, progress and
          lastReport, uses probe for the header, and calls requestStop.

  HOW   : See each function.

  WHEN  : From init.lua's main loop only.
==========================================================================]]--
--#BODY seller
do
    seller.__index = seller   -- seller objects use this table for methods

    --[[--------------------------------------------------------------------
      read(fn)  (private)

      WHAT  : Calls fn and returns its value, or nil if it raised.
      WHY   : Same rule as the inventory section: unknown, never a crash.
              Kept as its own copy so each section stays self contained.
      WHERE : Every probe below.
      HOW   : pcall.
      WHEN  : Every read.
    ----------------------------------------------------------------------]]
    local function read(fn)
        local ok, v = pcall(fn)          -- never let a TLO error escape
        if ok then return v end
        return nil                       -- unknown
    end

    -- -----------------------------------------------------------------------
    -- Live client readings (all wrapped; nil means "unknown")
    -- -----------------------------------------------------------------------

    --[[--------------------------------------------------------------------
      norm(s)  (private)

      WHAT  : Lower cases text and turns backticks into apostrophes.
      WHY   : EverQuest shows names such as Wyn`las with a backtick in some
              places and an apostrophe in others; quotes must still match.
      WHERE : The quote event handler in registerEvents.
      HOW   : lower, then gsub.
      WHEN  : For each quote line.
    ----------------------------------------------------------------------]]
    -- Normalize names for quote matching: lower case, backtick/apostrophe equal.
    local function norm(s) return (tostring(s or ''):lower():gsub('`', "'")) end

    --[[--------------------------------------------------------------------
      probe.gameState / merchantOpen / itemsReceived / merchantId /
      merchantName / cursorId / macroName / selected

      WHAT  : One guarded reader per live client fact. selected() returns
              {id, slot, slot2} for Merchant.SelectedItem.
      WHY   : Naming each reading once makes the safety checks read like
              plain English and keeps every TLO path in one list.
      WHERE : readiness, hardStopReason, selectionMatches, run, and
              ui.lua's header through seller.probe.
      HOW   : Each wraps one documented TLO member in read().
      WHEN  : Every frame (header) and before every action (worker).
    ----------------------------------------------------------------------]]
    local probe = {}   -- live readings, exposed as seller.probe
    -- 'INGAME' when a character is in the world.
    function probe.gameState()     return read(function() return mq.TLO.EverQuest.GameState() end) end
    -- true while a merchant window is open.
    function probe.merchantOpen()  return read(function() return mq.TLO.Merchant.Open() end) end
    -- true once the merchant's item list has arrived.
    function probe.itemsReceived() return read(function() return mq.TLO.Merchant.ItemsReceived() end) end
    -- Spawn ID of the open merchant; a change means a different merchant.
    function probe.merchantId()    return read(function() return mq.TLO.Merchant.ID() end) end
    -- Merchant name for display and the report.
    function probe.merchantName()  return read(function() return mq.TLO.Merchant.CleanName() end) end
    -- Non zero when something is on the cursor.
    function probe.cursorId()      return read(function() return mq.TLO.Cursor.ID() end) end
    -- Name of a running macro, empty or NULL when none.
    function probe.macroName()     return read(function() return mq.TLO.Macro.Name() end) end
    -- What the merchant window reports as selected, and where it is.
    function probe.selected()
        local sel = mq.TLO.Merchant.SelectedItem
        return {
            id    = read(function() return sel.ID() end),   -- item ID the merchant has selected
            slot  = read(function() return sel.ItemSlot() end),   -- its pack slot
            slot2 = read(function() return sel.ItemSlot2() end),   -- its sub slot inside the bag
        }
    end
    seller.probe = probe   -- exposed for the UI header and for tests

    --[[--------------------------------------------------------------------
      seller.new(cfg, log)

      WHAT  : Creates the seller object.
      WHY   : Holds mode, stop flag, progress and the last report in one
              place the UI can read.
      WHERE : init.lua, once.
      HOW   : Table with defaults; methods through seller.__index.
      WHEN  : Startup.
    ----------------------------------------------------------------------]]
    --- Create a seller.
    --- @param cfg table config module
    --- @param log table log module
    function seller.new(cfg, log)
        return setmetatable({
            cfg = cfg, log = log,
            mode = cfg.SELL_MODE,                         -- may be lowered by init.lua
            stopRequested = false,                        -- set by Stop, read by worker
            running = false,                              -- true during a run
            progress = { index = 0, total = 0, current = '' },
            lastReport = nil,                             -- shown under the buttons
            events = { quotes = 0, refusals = 0, lastQuote = nil },
        }, seller)
    end

    -- -----------------------------------------------------------------------
    -- Readiness
    -- -----------------------------------------------------------------------

    --[[--------------------------------------------------------------------
      seller:readiness(ctx)

      WHAT  : Evaluates every precondition for selling. Returns a list of
              {name, ok, detail} and whether all passed.
      WHY   : The Sell button stays disabled until everything is safe, and
              the first blocking reason is shown in plain words.
      WHERE : init.lua updateReadiness(), every loop tick and before
              prepare and confirm.
      HOW   : Script healthy, in game, cursor empty, no macro running,
              merchant open and list loaded (not needed in preview),
              selections file writable, protected bag list valid. Unknown
              readings fail.
      WHEN  : About ten times a second, and at each sale step.
    ----------------------------------------------------------------------]]
    --- Evaluate every precondition. Unknown readings are failures.
    --- @param ctx table {storeReadonly=bool, storeDetail=string, protectedError=string|nil, faulted=string|nil}
    --- @return table[] checks {name, ok, detail}, boolean allOk
    function seller:readiness(ctx)
        local checks = {}
        -- Append one check result, forcing ok to a strict boolean.
        local function add(name, ok, detail) checks[#checks + 1] = { name = name, ok = ok and true or false, detail = detail or '' } end
        local needsMerchant = self.mode ~= 'preview'      -- preview needs no merchant

        add('Script healthy', not ctx.faulted, ctx.faulted or 'OK')

        local gs = probe.gameState()   -- EverQuest.GameState reading
        add('In game', gs == 'INGAME', gs and ('GameState ' .. gs) or 'GameState unknown')   -- must be in game

        -- nil (no cursor item) and 0 both mean empty.
        local cur = probe.cursorId()
        add('Cursor empty', cur == nil or cur == 0, (cur and cur ~= 0) and 'Put the cursor item away manually' or 'OK')

        -- A running macro could fight the worker over clicks.
        local mac = probe.macroName()
        local macroRunning = type(mac) == 'string' and mac ~= '' and mac ~= 'NULL'
        add('No macro running', not macroRunning,
            macroRunning and ('Macro "' .. mac .. '" is running; end it first') or 'OK')   -- tell the player which macro to end

        if needsMerchant then   -- select_test and live need a merchant
            -- Farm Vendor never opens a merchant; you do.
            local open = probe.merchantOpen()
            add('Merchant open', open == true, open == true and (probe.merchantName() or 'Open')
                or (open == nil and 'Merchant state unknown' or 'Open a merchant window yourself'))
            local rec = probe.itemsReceived()   -- merchant list finished loading?
            add('Merchant list loaded', rec == true, rec == true and 'OK' or 'Waiting for merchant list')   -- must be loaded before any click
        else
            add('Merchant open', true, 'Not required in preview mode')   -- preview never clicks
        end

        -- Confirm Sale saves first, so a read only file must block selling.
        add('Selections can be saved', not ctx.storeReadonly, ctx.storeReadonly and ctx.storeDetail or 'OK')
        add('Protected bags valid', ctx.protectedError == nil, ctx.protectedError or 'OK')

        -- All must pass.
        local all = true
        for _, c in ipairs(checks) do if not c.ok then all = false end end
        return checks, all
    end

    -- -----------------------------------------------------------------------
    -- Proposal
    -- -----------------------------------------------------------------------

    --[[--------------------------------------------------------------------
      seller:buildProposal(scan, checked, neverSell)

      WHAT  : Builds the exact sale list from a fresh scan and the checked
              IDs: item totals, every stack location, an estimate, and a
              fingerprint string. Items in neverSell are always left out.
      WHY   : The Confirm Sale window must show exactly what will be sold,
              and the fingerprint lets init.lua detect any inventory change
              between Sell All Checked Items and Confirm Sale.
      WHERE : init.lua prepare() and confirm().
      HOW   : Takes each checked, eligible row that is not Never Sell (a
              second guard: the UI already blocks checking those, and a
              hand edited INI cannot get past this); totals quantity; adds the
              estimate only for items with a merchant price; lists every
              eligible stack; sorts stacks by slot and sub slot; the
              fingerprint is id@slot:sub#qty joined with |.
      WHEN  : On Sell All Checked Items and again on Confirm Sale.
    ----------------------------------------------------------------------]]
    --- Build a proposal from a fresh scan and the checked IDs.
    --- @return table proposal
    function seller:buildProposal(scan, checked, neverSell)
        neverSell = neverSell or {}                       -- optional; nil means none
        local items, entries = {}, {}                     -- per item, per stack
        local totalQty, estCopper, unpriced = 0, 0, 0
        for _, row in ipairs(scan.rows) do
            if checked[row.id] and row.eligible and not neverSell[row.id] then   -- Never Sell is never proposed
                -- Merchant price per unit, if this merchant quoted one.
                local unit = row.sellPrice
                local item = {
                    id = row.id, name = row.name,
                    qty = row.eligibleQty, stacks = row.eligibleStacks,   -- eligible amount only
                    unitEst = (type(unit) == 'number' and unit > 0) and unit or nil,   -- unit price if known
                    skippedReasons = row.reasonText,   -- why some stacks are left out
                }
                -- Estimate counts priced items only; unpriced are counted apart.
                if item.unitEst then estCopper = estCopper + item.unitEst * item.qty else unpriced = unpriced + 1 end
                items[#items + 1] = item
                totalQty = totalQty + item.qty
                -- Every eligible stack with its exact location.
                for _, e in ipairs(row.entries) do
                    entries[#entries + 1] = {
                        id = e.id, name = e.name, qty = e.stack,
                        topSlot = e.topSlot, pack = e.pack, sub = e.sub,   -- exact bag location
                    }
                end
            end
        end
        -- Sell in bag order: pack slot, then sub slot (loose items first).
        table.sort(entries, function(a, b)
            if a.topSlot ~= b.topSlot then return a.topSlot < b.topSlot end
            return (a.sub or -1) < (b.sub or -1)
        end)
        -- Fingerprint: any change to ID, place or count changes this string.
        local fp = {}
        for _, e in ipairs(entries) do fp[#fp + 1] = ('%d@%d:%s#%d'):format(e.id, e.topSlot, tostring(e.sub), e.qty) end
        return {
            items = items, entries = entries,   -- what the confirm window lists
            totalQty = totalQty, totalStacks = #entries,   -- totals for the summary line
            estCopper = (#items > unpriced) and estCopper or nil,   -- sum of priced items only
            unpricedTypes = unpriced,
            fingerprint = table.concat(fp, '|'),
            mode = self.mode,
            createdAt = os.date('%Y-%m-%d %H:%M:%S'),   -- shown in the report
        }
    end

    -- -----------------------------------------------------------------------
    -- Worker helpers
    -- -----------------------------------------------------------------------

    --[[--------------------------------------------------------------------
      seller:waitFor(ms, cond)

      WHAT  : Waits up to ms for cond() to become true or a stop request.
              Returns true if cond() became true.
      WHY   : Every wait must be bounded, must end early on Stop, and must
              keep processing merchant chat so quotes are seen.
      WHERE : selectAndQuote, sellOnce, and the retry pause in run.
      HOW   : Loop: doevents, test cond, test stop, test elapsed time with
              mq.gettime, then mq.delay(50). One final doevents and cond
              check after the time runs out.
      WHEN  : At each select, quote and sale step.
    ----------------------------------------------------------------------]]
    --- Wait up to ms for cond() or a stop request. Returns true if cond() became true.
    --- Polls in short documented mq.delay steps and calls mq.doevents() each step
    --- so merchant chat events (quote/refusal) are processed while waiting.
    function seller:waitFor(ms, cond)
        local start = mq.gettime()                         -- milliseconds
        while true do
            mq.doevents()                                  -- run chat handlers
            if cond() then return true end
            if self.stopRequested then return false end
            if mq.gettime() - start >= ms then break end   -- bounded
            mq.delay(50)
        end
        -- Last chance: a line may have arrived during the final delay.
        mq.doevents()
        return cond() and true or false
    end

    -- -----------------------------------------------------------------------
    -- Merchant chat events (documented mq.event / mq.doevents / mq.flushevents)
    -- -----------------------------------------------------------------------
    -- Seen in the client on 2026-10-13:
    --   Merchant Wyn'las told you, 'I'll give you 1 gold 9 silver per Nodding Blue Lily'
    --   Merchant Wyn'las told you, 'I am not interested in buying that.'
    -- Counters only increase; the worker compares before/after snapshots, so an
    -- old line can never satisfy a new wait.

    local EVENT_QUOTE, EVENT_REFUSAL = 'fv_quote', 'fv_refusal'   -- event names

    --[[--------------------------------------------------------------------
      seller:registerEvents()

      WHAT  : Registers the two merchant chat events: quote and refusal.
      WHY   : The merchant refuses a sale sent before its quote (1.0.0 live
              test), so the worker must see the quote line.
      WHERE : init.lua, once at startup.
      HOW   : mq.event with #*# wildcards around the configured phrases.
              The quote handler ignores a quote that names a different item
              ("... per <item>'"), warns on a quote with no item name, and
              otherwise counts it. The refusal handler counts refusals.
      WHEN  : Startup. Handlers fire inside mq.doevents.
    ----------------------------------------------------------------------]]
    function seller:registerEvents()
        self.events = { quotes = 0, refusals = 0, lastQuote = nil }   -- reset counters
        mq.event(EVENT_QUOTE, '#*#' .. self.cfg.QUOTE_PHRASE .. '#*#', function(line)
            -- A quote of the form "... per <item>'" must name the item we selected;
            -- a quote for a different item is logged and ignored. A quote without
            -- " per " (format not yet seen) is accepted with a warning, because the
            -- selection itself is already verified by Merchant.SelectedItem.
            local l, want = norm(line), norm(self.expectName)
            if self.expectName and l:find(' per ', 1, true) and not l:find(want, 1, true) then
                self.events.otherQuotes = (self.events.otherQuotes or 0) + 1
                self.log.warn('item.quote_other_item', { expected = self.expectName, quote = line })   -- logged, not counted
                return
            end
            -- No " per <item>" at all: accept, but leave a trace.
            if self.expectName and not l:find(want, 1, true) then
                self.log.warn('item.quote_unnamed', { expected = self.expectName, quote = line })
            end
            -- Count it; the worker compares counts before and after.
            self.events.quotes = self.events.quotes + 1
            self.events.lastQuote = line
        end)
        -- Refusal: count only; the worker decides what it means.
        mq.event(EVENT_REFUSAL, '#*#' .. self.cfg.REFUSAL_PHRASE .. '#*#', function(line)
            self.events.refusals = self.events.refusals + 1
        end)
    end

    --[[--------------------------------------------------------------------
      seller:unregisterEvents()

      WHAT  : Removes both merchant chat events.
      WHY   : Events must not outlive the script.
      WHERE : init.lua shutdown.
      HOW   : mq.unevent for each name.
      WHEN  : Shutdown.
    ----------------------------------------------------------------------]]
    function seller:unregisterEvents()
        mq.unevent(EVENT_QUOTE)
        mq.unevent(EVENT_REFUSAL)
    end

    --[[--------------------------------------------------------------------
      seller:flushMerchantEvents()

      WHAT  : Discards queued, not yet processed merchant lines.
      WHY   : A quote from earlier, such as one you caused by clicking an
              item yourself, must never satisfy a new wait.
      WHERE : selectAndQuote, and init.lua's main loop while idle.
      HOW   : mq.flushevents for each event name.
      WHEN  : Before each selection and every idle loop tick.
    ----------------------------------------------------------------------]]
    --- Discard queued (old) merchant lines before a new selection.
    function seller:flushMerchantEvents()
        mq.flushevents(EVENT_QUOTE)
        mq.flushevents(EVENT_REFUSAL)
    end

    --[[--------------------------------------------------------------------
      seller:hardStopReason(merchantId)

      WHAT  : Checks the conditions that always stop a run. Returns nil or a
              reason.
      WHY   : These are never safe to continue through, whatever ON_FAILURE
              says.
      WHERE : run, before each stack, before each sale and after each retry
              pause.
      HOW   : Not in game; something on the cursor; outside preview, the
              merchant closed or its ID changed; a macro started.
      WHEN  : Before every action.
    ----------------------------------------------------------------------]]
    --- Checks that always stop the run. Returns nil or a reason string.
    function seller:hardStopReason(merchantId)
        if probe.gameState() ~= 'INGAME' then return 'Left the game world' end
        local cur = probe.cursorId()
        if cur ~= nil and cur ~= 0 then return 'Something is on the cursor; stopped for manual handling' end   -- cursor must stay empty
        if self.mode ~= 'preview' then   -- merchant checks apply to clicking modes only
            -- Same merchant, still open, as when the run started.
            if probe.merchantOpen() ~= true then return 'Merchant window closed' end
            local mid = probe.merchantId()
            if mid == nil or mid ~= merchantId then return 'Merchant changed' end
        end
        local mac = probe.macroName()   -- macros must not start mid run
        if type(mac) == 'string' and mac ~= '' and mac ~= 'NULL' then return 'A macro started running' end   -- stop if one appeared
        return nil                                         -- safe to continue
    end

    --[[--------------------------------------------------------------------
      selectionMatches(e)  (private)

      WHAT  : True when the merchant window reports exactly this entry as
              selected: same item ID, same top slot and, in a bag, same sub
              slot.
      WHY   : Two stacks of one item can sit in different bags; selling the
              wrong one would break the confirmed snapshot.
      WHERE : selectAndQuote, as the wait condition.
      HOW   : Compares probe.selected() with the entry.
      WHEN  : Polled while waiting for each selection.
    ----------------------------------------------------------------------]]
    local function selectionMatches(e)
        local s = probe.selected()
        if s.id ~= e.id or s.slot ~= e.topSlot then return false end
        if e.sub ~= nil and s.slot2 ~= e.sub then return false end   -- bag slot too
        return true
    end

    --[[--------------------------------------------------------------------
      issueSelect(e)  (private)

      WHAT  : Sends the /itemnotify command that selects this entry in the
              merchant window.
      WHY   : /itemnotify targets an exact slot, unlike name based
              selection, so the right stack is selected.
      WHERE : selectAndQuote.
      HOW   : In a bag: /itemnotify in pack<N> <sub + 1> leftmouseup (bag
              slots are 1 based, ItemSlot2 is 0 based). Loose: /itemnotify
              <slot> leftmouseup.
      WHEN  : Once per selection attempt.
    ----------------------------------------------------------------------]]
    local function issueSelect(e)
        if e.sub ~= nil then
            -- /itemnotify uses 1-based bag slots; ItemSlot2 is 0-based (Slot Names reference).
            mq.cmdf('/itemnotify in pack%d %d leftmouseup', e.pack, e.sub + 1)
        else
            mq.cmdf('/itemnotify %d leftmouseup', e.topSlot)   -- loose item, slot 23-34
        end
    end

    --[[--------------------------------------------------------------------
      seller:selectAndQuote(e)

      WHAT  : Selects one entry and waits for the merchant's quote naming
              that item. Returns 'ok', 'refused', 'noquote', 'noselect',
              'cursor' or 'stopped', plus a detail text.
      WHY   : The merchant refuses a sale sent before its quote; waiting for
              the quote was the 1.1.0 fix.
      WHERE : run.
      HOW   : Flush old lines, remember the expected name and the counters,
              send the select, wait SELECT_TIMEOUT_MS for selectionMatches,
              stop at once if the item went to the cursor, then wait
              QUOTE_TIMEOUT_MS for a new quote or refusal.
      WHEN  : Once per stack attempt, in select_test and live modes.
    ----------------------------------------------------------------------]]
    --- Select one entry and wait for the merchant's quote naming that item.
    --- @return string outcome 'ok'|'refused'|'noquote'|'noselect'|'cursor'|'stopped', string detail
    function seller:selectAndQuote(e)
        local cfg, log = self.cfg, self.log
        self:flushMerchantEvents()                         -- only fresh lines count
        self.expectName = e.name                           -- used by the quote handler
        local q0, r0 = self.events.quotes, self.events.refusals   -- before snapshot
        issueSelect(e)
        local selected = self:waitFor(cfg.SELECT_TIMEOUT_MS, function() return selectionMatches(e) end)
        -- A click that picked the item up instead of selecting it: stop.
        local cur = probe.cursorId()
        if cur ~= nil and cur ~= 0 then return 'cursor', 'Item went to the cursor; stopped for manual handling' end
        if self.stopRequested and not selected then return 'stopped' end
        if not selected then return 'noselect', 'Merchant did not report the expected selection' end   -- selection never confirmed
        log.debug('item.selected', { id = e.id, name = e.name, pack = e.pack, slot = e.sub and (e.sub + 1) or 'loose' })   -- selection verified

        -- Wait for this item's quote, or a refusal, whichever comes first.
        local answered = self:waitFor(cfg.QUOTE_TIMEOUT_MS, function()
            return self.events.quotes > q0 or self.events.refusals > r0
        end)
        if self.events.quotes > q0 then   -- got this item's price quote
            log.debug('item.quoted', { id = e.id, name = e.name, quote = self.events.lastQuote })   -- quote seen
            return 'ok'   -- ready to sell
        end
        if self.events.refusals > r0 then return 'refused', 'Merchant is not interested in buying this item' end   -- merchant will not buy it
        if self.stopRequested then return 'stopped' end   -- operator pressed Stop
        return 'noquote', 'No price quote from merchant after selection'   -- neither quote nor refusal arrived in time
    end

    --[[--------------------------------------------------------------------
      seller:sellOnce(e, report)

      WHAT  : Sends /sellitem for the entry's full quantity and verifies the
              result. Returns 'sold', 'sale_refused', 'partial', 'timeout'
              or 'stopped', plus a detail text.
      WHY   : A sale is only counted when the stack has actually left the
              slot, never because a command was sent.
      WHERE : run, after selectAndQuote returned 'ok' in live mode.
      HOW   : Pause POST_QUOTE_DELAY_MS, note the refusal count, send
              /sellitem <qty>, wait SELL_TIMEOUT_MS for a refusal or the
              slot to empty, change item or shrink, then re read the slot
              and work out how many sold. Partial sales are reported and
              never retried.
      WHEN  : Once per sale attempt.
    ----------------------------------------------------------------------]]
    --- Issue /sellitem for the full entry quantity and verify the result.
    --- @return string outcome 'sold'|'sale_refused'|'partial'|'timeout'|'stopped', string detail
    function seller:sellOnce(e, report)
        local cfg, log = self.cfg, self.log
        if cfg.POST_QUOTE_DELAY_MS > 0 then mq.delay(cfg.POST_QUOTE_DELAY_MS) end   -- let the quote apply
        local r1 = self.events.refusals                    -- before snapshot
        mq.cmdf('/sellitem %d', e.qty)
        -- Done when refused, or the slot is empty, different or smaller.
        local gone = self:waitFor(cfg.SELL_TIMEOUT_MS, function()
            if self.events.refusals > r1 then return true end
            local x = inventory.readLocation(e.topSlot, e.sub)
            return x == nil or x.id ~= e.id or (type(x.stack) == 'number' and x.stack < e.qty)   -- slot emptied, changed item, or shrank
        end)
        -- Measure what actually left the slot.
        local after = inventory.readLocation(e.topSlot, e.sub)
        local remaining = (after and after.id == e.id) and (after.stack or e.qty) or 0
        local sold = e.qty - remaining
        if sold > 0 then   -- some or all of the stack sold
            report.byId[e.id].sold = report.byId[e.id].sold + sold   -- per item total
            report.soldQty = report.soldQty + sold   -- run total
        end
        if remaining == 0 then   -- whole stack left the slot
            log.info('sale.verified', { id = e.id, name = e.name, qty = sold, pack = e.pack, slot = e.sub and (e.sub + 1) or 'loose' })   -- verified sale
            return 'sold'   -- success
        end
        if sold > 0 then   -- nothing to retry: report the partial
            e.qty = remaining      -- never retry a partial; report it
            return 'partial', ('Partial sale: %d of %d sold'):format(sold, sold + remaining)
        end
        if self.events.refusals > r1 then return 'sale_refused', 'Merchant refused the sale (not interested)' end
        if self.stopRequested then return 'stopped' end   -- operator pressed Stop
        return 'timeout', 'Sale not confirmed within timeout'   -- nothing changed in time
    end

    -- -----------------------------------------------------------------------
    -- Run
    -- -----------------------------------------------------------------------

    --[[--------------------------------------------------------------------
      seller:run(proposal)

      WHAT  : Executes a confirmed proposal and returns the report.
              Blocking; call only from the main loop.
      WHY   : This is the whole selling workflow, with every safety rule in
              the section header applied to every stack.
      WHERE : init.lua confirm(), inside xpcall.
      HOW   : 1. Builds the report, notes the merchant ID and start coin.
              2. For each stack: stop check, skip if its item was skipped,
                 hard stop check, re read the slot (same ID and stack).
              3. Preview: log preview.would_sell and move on.
              4. Otherwise select and quote; in live, hard stop check, then
                 sellOnce. A refusal after a valid quote is retried up to
                 SELL_REFUSAL_RETRIES times after RETRY_DELAY_MS.
              5. Outcomes: ok and sold count; stopped ends; cursor and hard
                 stop end with a failure; anything else goes through fail(),
                 which applies ON_FAILURE and MAX_FAILURES_PER_RUN.
              6. Pause BETWEEN_ITEMS_DELAY_MS (ends early on Stop).
              7. After the loop: settle delay in live, end coin, coin delta,
                 run.end log line.
      WHEN  : After Confirm Sale passes every check and the save succeeds.
    ----------------------------------------------------------------------]]
    --- Execute a confirmed proposal. Blocking; call only from the main loop.
    --- @return table report
    function seller:run(proposal)
        local cfg, log = self.cfg, self.log
        self.running, self.stopRequested = true, false
        -- Step 1: the report the UI shows when the run ends.
        local report = {
            mode = self.mode, startedAt = os.date('%Y-%m-%d %H:%M:%S'),
            planned = proposal.totalQty, plannedStacks = proposal.totalStacks,
            estCopper = proposal.estCopper, unpricedTypes = proposal.unpricedTypes or 0,   -- from the confirmed proposal
            byId = {}, order = {}, failures = {}, stopReason = 'Completed',   -- filled in during the run
            stacksDone = 0, soldQty = 0, selectedOk = 0,   -- counters
        }
        -- One result line per item type, in proposal order.
        for _, it in ipairs(proposal.items) do
            report.byId[it.id] = { id = it.id, name = it.name, planned = it.qty, sold = 0, selected = 0, failed = 0, skipped = 0 }
            report.order[#report.order + 1] = it.id
        end
        local merchantId = probe.merchantId()              -- must stay the same
        report.merchant = probe.merchantName()
        report.coinStart = inventory.coinCopper()
        local skipIds = {}                                 -- item IDs given up (skip_item)
        self.progress = { index = 0, total = #proposal.entries, current = '' }

        log.info('run.start', { mode = self.mode, stacks = proposal.totalStacks, qty = proposal.totalQty,
            merchant = report.merchant or 'none', policy = cfg.ON_FAILURE })   -- merchant name and failure policy

        --[[------------------------------------------------------------------
          fail(e, reason, hard)  (private, inside run)

          WHAT  : Records one failure and decides whether to stop. Returns
                  'stop' or 'continue'.
          WHY   : One place applies the failure policy.
          WHERE : The stack loop below.
          HOW   : Counts and logs the failure. Hard failures stop. Reaching
                  MAX_FAILURES_PER_RUN stops. ON_FAILURE 'stop' stops.
                  Otherwise the item ID is skipped from now on.
          WHEN  : Whenever a stack fails.
        --------------------------------------------------------------------]]
        local function fail(e, reason, hard)
            local r = report.byId[e.id]
            if r then r.failed = r.failed + 1 end
            report.failures[#report.failures + 1] = { id = e.id, name = e.name, pack = e.pack, sub = e.sub, reason = reason }   -- kept for the report window
            log.warn('item.failed', { id = e.id, name = e.name, pack = e.pack, slot = e.sub and (e.sub + 1) or 'loose', reason = reason })   -- logged with location
            if hard then return 'stop' end   -- hard stops always end the run
            -- Ceiling applies even in skip_item mode.
            if #report.failures >= cfg.MAX_FAILURES_PER_RUN then
                report.stopReason = ('Failure limit reached (%d)'):format(cfg.MAX_FAILURES_PER_RUN)
                return 'stop'
            end
            if cfg.ON_FAILURE == 'stop' then report.stopReason = 'Stopped on failure: ' .. reason; return 'stop' end   -- ON_FAILURE stop
            skipIds[e.id] = true                           -- skip_item: give up on this ID
            return 'continue'
        end

        -- Step 2: one stack at a time, in bag order.
        for i, e in ipairs(proposal.entries) do
            self.progress.index, self.progress.current = i, e.name
            if self.stopRequested then report.stopReason = 'Stopped by operator'; break end
            if skipIds[e.id] then   -- this ID already failed under skip_item
                report.byId[e.id].skipped = report.byId[e.id].skipped + 1   -- count the skipped stack
            else
                -- Conditions that always end the run.
                local hard = self:hardStopReason(merchantId)
                if hard then report.stopReason = hard; fail(e, hard, true); break end

                -- 1. Revalidate the exact location.
                local now = inventory.readLocation(e.topSlot, e.sub)
                if not now or now.id ~= e.id or now.stack ~= e.qty then
                    if fail(e, 'Slot changed since confirmation') == 'stop' then break end
                    goto continue   -- next stack
                end

                -- Step 3: preview only records what would happen.
                if self.mode == 'preview' then
                    log.info('preview.would_sell', { id = e.id, name = e.name, qty = e.qty, pack = e.pack, slot = e.sub and (e.sub + 1) or 'loose' })
                    report.byId[e.id].selected = report.byId[e.id].selected + 1
                    report.stacksDone = report.stacksDone + 1   -- counted as done
                    goto continue   -- next stack
                end

                -- 2-4. Select, verify, wait for this item's quote, sell, verify.
                --      One sale-time refusal after a valid quote is retried up to
                --      cfg.SELL_REFUSAL_RETRIES times (bounded), re-selecting first.
                do
                    local outcome, detail
                    local attempt = 0
                    while true do   -- bounded by SELL_REFUSAL_RETRIES
                        attempt = attempt + 1   -- attempt number, starting at 1
                        outcome, detail = self:selectAndQuote(e)   -- select and wait for the quote
                        if outcome == 'ok' then   -- selection and quote verified
                            -- Count the selection once, not once per retry.
                            if attempt == 1 then
                                report.byId[e.id].selected = report.byId[e.id].selected + 1
                                report.selectedOk = report.selectedOk + 1
                            end
                            if self.mode == 'select_test' then break end   -- never sells
                            local h = self:hardStopReason(merchantId)
                            if h then outcome, detail = 'hard', h; break end
                            if self.stopRequested then outcome = 'stopped'; break end
                            outcome, detail = self:sellOnce(e, report)   -- live mode: sell and verify
                        end
                        -- Retry only a refusal that followed a valid quote.
                        if outcome == 'sale_refused' and attempt <= cfg.SELL_REFUSAL_RETRIES and not self.stopRequested then
                            log.warn('sale.retry', { id = e.id, name = e.name, attempt = attempt + 1,
                                wait_ms = cfg.RETRY_DELAY_MS, note = 'refused after a valid quote; re-selecting' })
                            self:waitFor(cfg.RETRY_DELAY_MS, function() return false end)   -- stoppable pause
                            local h = self:hardStopReason(merchantId)
                            if h then outcome, detail = 'hard', h; break end
                        else
                            break
                        end
                    end

                    -- Step 5: act on the outcome.
                    if outcome == 'ok' then
                        report.stacksDone = report.stacksDone + 1          -- select_test success
                    elseif outcome == 'sold' then
                        report.stacksDone = report.stacksDone + 1
                    elseif outcome == 'stopped' then
                        report.stopReason = 'Stopped by operator'; break   -- operator pressed Stop
                    elseif outcome == 'cursor' or outcome == 'hard' then   -- conditions that end the run
                        report.stopReason = detail; fail(e, detail, true); break   -- record and end
                    else
                        if fail(e, detail) == 'stop' then break end   -- ON_FAILURE decides
                        goto continue   -- next stack
                    end
                end

                -- Step 6: pace between stacks; ends early on Stop.
                ::pace::
                if cfg.BETWEEN_ITEMS_DELAY_MS > 0 then
                    mq.delay(cfg.BETWEEN_ITEMS_DELAY_MS, function() return self.stopRequested end)
                end
            end
            ::continue::   -- jump target for "next stack"
        end

        -- Step 7: let the coin display catch up, then measure.
        if cfg.COIN_SETTLE_DELAY_MS > 0 and self.mode == 'live' then mq.delay(cfg.COIN_SETTLE_DELAY_MS) end
        report.coinEnd = inventory.coinCopper()
        if report.coinStart and report.coinEnd then report.coinDelta = report.coinEnd - report.coinStart end
        report.endedAt = os.date('%Y-%m-%d %H:%M:%S')   -- end time for the report
        self.running, self.stopRequested = false, false   -- worker finished
        self.lastReport = report                           -- shown by the UI
        log.info('run.end', { mode = report.mode, reason = report.stopReason, sold = report.soldQty,
            stacks_done = report.stacksDone, failures = #report.failures,
            coin_delta = report.coinDelta and inventory.formatCoin(report.coinDelta) or 'unknown' })
        return report   -- handed to init.lua confirm()
    end

    --[[--------------------------------------------------------------------
      seller:requestStop()

      WHAT  : Asks the running worker to stop before the next item.
      WHY   : Stop Selling, the window X and /fvendor stop must work at any
              moment without running game code from a callback.
      WHERE : ui.lua (Stop Selling, window X) and init.lua (/fvendor).
      HOW   : Sets stopRequested once and logs it; waitFor and the stack
              loop see the flag.
      WHEN  : On request, during a run.
    ----------------------------------------------------------------------]]
    --- Request a stop (safe from UI callbacks and binds; only sets a flag).
    function seller:requestStop()
        if self.running and not self.stopRequested then
            self.stopRequested = true
            self.log.warn('run.stop_requested', {})   -- confirm in the log
        end
    end
end
--#END seller
--[[==========================================================================
  END OF SECTION : seller
  PUBLIC : new, probe, and the methods readiness, buildProposal, waitFor,
           registerEvents, unregisterEvents, flushMerchantEvents,
           hardStopReason, selectAndQuote, sellOnce, run, requestStop
==========================================================================]]--

-- Hand both section tables to init.lua and ui.lua.
return { inventory = inventory, seller = seller }

--[[==========================================================================
  END OF FILE : Farm_Vendor/engine.lua

  PUBLIC  (returned table)
    inventory  scan, readLocation, coinCopper, formatCoin
    seller     new, probe, readiness, buildProposal, waitFor,
               registerEvents, unregisterEvents, flushMerchantEvents,
               hardStopReason, selectAndQuote, sellOnce, run, requestStop

  DEPENDENCIES : mq only.

  HOW TO EDIT SAFELY
    - Every new command or TLO member must be in the MacroQuest docs first;
      add it to AUDIT.md with its link before using it.
    - Any change to the seller section means: set SELL_MODE to preview or
      select_test, repeat Stages 2 and 3 in TESTING.md, then go live again.
    - Never call anything here from ui.lua except formatCoin, probe reads
      and requestStop.
    - Run python dev/run_tests.py and python dev/doc_audit.py afterwards.
==========================================================================]]--
