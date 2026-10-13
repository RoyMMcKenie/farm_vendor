--[[
Farm_Vendor/inventory.lua
============================

Reads carried inventory and builds the checklist rows.

Documented interfaces used (see INTERFACES.md for links)
  mq.TLO.Me.Inventory(slot)     character.Inventory[#]       item in slot #
  item.ID / Name / Stack / Value / NoDrop / Lore / Container / Item(n)
  item.ItemSlot / ItemSlot2     Slot Names reference: work without opening bags
  item.SellPrice                price to sell this item at the active merchant

Scope (fail closed)
  * Only top-level inventory slots config.FIRST_PACK_SLOT..LAST_PACK_SLOT
    (23 = pack1 ... 34 = pack12). Equipped gear, bank, shared bank and cursor
    are never read for selling.
  * Bags themselves are never candidates. Items in protected packs are counted
    but never listed as sellable.
  * Any reading that is missing or not a positive whole number makes that
    entry ineligible with a visible reason. Nothing is guessed.

This module only READS. It issues no commands.
]]

local mq = require('mq')

local inventory = {}

--- Safely evaluate a TLO accessor. Returns nil on error or nil value.
local function read(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

local function posInt(v)
    return type(v) == 'number' and v >= 1 and v == math.floor(v)
end

--- Convert a TLO item to a plain Lua entry table, or nil if the slot is empty.
--- @param item any MQ item userdata
--- @param topSlot number top-level slot (23-34)
--- @param subIndex number|nil 0-based sub slot inside a bag (nil for loose)
local function readEntry(item, topSlot, subIndex)
    local id = read(function() return item.ID() end)
    if not posInt(id) then return nil end           -- empty slot
    local e = {
        id        = id,
        name      = read(function() return item.Name() end),
        stack     = read(function() return item.Stack() end),
        value     = read(function() return item.Value() end),
        sellPrice = read(function() return item.SellPrice() end),
        noDrop    = read(function() return item.NoDrop() end),
        lore      = read(function() return item.Lore() end),
        container = read(function() return item.Container() end),
        itemSlot  = read(function() return item.ItemSlot() end),
        itemSlot2 = read(function() return item.ItemSlot2() end),
        topSlot   = topSlot,
        pack      = topSlot - 22,                    -- pack1 = slot 23
        sub       = subIndex,                        -- 0-based, nil if loose
    }
    return e
end

--- Decide whether an entry can be offered for sale; returns nil or a reason.
local function exclusionReason(e, cfg, protected, merchantOpen)
    if protected[e.pack] then return 'Protected bag' end
    if type(e.name) ~= 'string' or e.name == '' then return 'Unknown name' end
    if type(e.container) == 'number' and e.container > 0 then return 'Container' end
    if not posInt(e.stack) then return 'Unknown quantity' end
    if type(e.value) ~= 'number' then return 'Unknown value' end
    if cfg.EXCLUDE_ZERO_VALUE and e.value <= 0 then return 'No merchant value' end
    if e.noDrop == nil then return 'Unknown NO DROP flag' end
    if cfg.EXCLUDE_NO_DROP and e.noDrop then return 'NO DROP excluded' end
    if cfg.EXCLUDE_LORE and e.lore then return 'Lore excluded' end
    if merchantOpen and cfg.EXCLUDE_UNPRICED_AT_MERCHANT
        and not (type(e.sellPrice) == 'number' and e.sellPrice > 0) then
        return 'Merchant offers no price'
    end
    -- Location must be confirmed by the documented ItemSlot/ItemSlot2 members.
    if e.itemSlot ~= e.topSlot then return 'Location unconfirmed' end
    if e.sub ~= nil and e.itemSlot2 ~= e.sub then return 'Location unconfirmed' end
    return nil
end

--- Scan carried inventory.
--- @param cfg table config module
--- @param protectedList number[] pack numbers to protect
--- @return table result {entries=, rows=, rowsById=, protectedCount=, scannedAt=}
function inventory.scan(cfg, protectedList)
    local merchantOpen = read(function() return mq.TLO.Merchant.Open() end) == true
    local protected = {}
    for _, p in ipairs(protectedList or {}) do protected[p] = true end

    local entries = {}
    local protectedCount = 0

    for slot = cfg.FIRST_PACK_SLOT, cfg.LAST_PACK_SLOT do
        local top = mq.TLO.Me.Inventory(slot)
        local topEntry = readEntry(top, slot, nil)
        if topEntry then
            local slots = topEntry.container
            if type(slots) == 'number' and slots > 0 then
                -- A bag: read its contents. Item(n) is 1-based per the item
                -- datatype; ItemSlot2 is the 0-based sub slot.
                for n = 1, slots do
                    local sub = top.Item(n)
                    local e = readEntry(sub, slot, n - 1)
                    if e then entries[#entries + 1] = e end
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
        if e.excluded == 'Protected bag' then protectedCount = protectedCount + 1 end
        if e.excluded ~= 'Protected bag' then            -- protected items are hidden entirely
            local row = rowsById[e.id]
            if not row then
                row = {
                    id = e.id, name = e.name or ('Item ' .. e.id),
                    qty = 0, stacks = 0, eligibleQty = 0, eligibleStacks = 0,
                    value = e.value, sellPrice = e.sellPrice,
                    noDrop = e.noDrop, lore = e.lore,
                    entries = {}, reasons = {},
                }
                rowsById[e.id] = row
                rows[#rows + 1] = row
            end
            row.qty = row.qty + (posInt(e.stack) and e.stack or 0)
            row.stacks = row.stacks + 1
            if e.excluded then
                row.reasons[e.excluded] = true
            else
                row.eligibleQty = row.eligibleQty + e.stack
                row.eligibleStacks = row.eligibleStacks + 1
                row.entries[#row.entries + 1] = e
            end
        end
    end
    for _, row in ipairs(rows) do
        local list = {}
        for r in pairs(row.reasons) do list[#list + 1] = r end
        table.sort(list)
        row.reasonText = table.concat(list, ', ')
        row.eligible = row.eligibleStacks > 0
    end
    table.sort(rows, function(a, b)
        local an, bn = a.name:lower(), b.name:lower()
        if an == bn then return a.id < b.id end
        return an < bn
    end)

    return {
        entries = entries, rows = rows, rowsById = rowsById,
        protectedCount = protectedCount, scannedAt = os.time(), merchantOpen = merchantOpen,
    }
end

--- Re-read one exact location and return a fresh entry (or nil if empty).
--- Used by the seller immediately before and after each action.
function inventory.readLocation(topSlot, subIndex)
    local top = mq.TLO.Me.Inventory(topSlot)
    if subIndex == nil then return readEntry(top, topSlot, nil) end
    return readEntry(top.Item(subIndex + 1), topSlot, subIndex)
end

--- Total carried coin in copper using documented character members.
--- Returns nil if any reading is unavailable (caller reports "unknown").
function inventory.coinCopper()
    local me = mq.TLO.Me
    local p = read(function() return me.Platinum() end)
    local g = read(function() return me.Gold() end)
    local s = read(function() return me.Silver() end)
    local c = read(function() return me.Copper() end)
    if type(p) ~= 'number' or type(g) ~= 'number' or type(s) ~= 'number' or type(c) ~= 'number' then
        return nil
    end
    return p * 1000 + g * 100 + s * 10 + c
end

--- Format copper as "1p 2g 3s 4c" (omits zero units; "0c" for zero).
function inventory.formatCoin(copper)
    if type(copper) ~= 'number' then return 'Unavailable' end
    local neg = copper < 0
    copper = math.floor(math.abs(copper))
    local p = math.floor(copper / 1000); copper = copper % 1000
    local g = math.floor(copper / 100);  copper = copper % 100
    local s = math.floor(copper / 10);   local c = copper % 10
    local parts = {}
    if p > 0 then parts[#parts + 1] = p .. 'p' end
    if g > 0 then parts[#parts + 1] = g .. 'g' end
    if s > 0 then parts[#parts + 1] = s .. 's' end
    if c > 0 or #parts == 0 then parts[#parts + 1] = c .. 'c' end
    return (neg and '-' or '') .. table.concat(parts, ' ')
end

return inventory
