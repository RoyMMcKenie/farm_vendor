--[[
Farm_Vendor/seller.lua
=========================

Readiness checks, sale proposals, and the guarded selling worker.

Documented interfaces used (see INTERFACES.md)
  mq.TLO.EverQuest.GameState()        'INGAME' required
  mq.TLO.Merchant.Open()              merchant window open
  mq.TLO.Merchant.ItemsReceived()     merchant list populated
  mq.TLO.Merchant.ID()                merchant inherits spawn members when active
  mq.TLO.Merchant.SelectedItem        item currently selected in merchant window
  mq.TLO.Cursor.ID()                  something on the cursor
  mq.TLO.Macro.Name()                 a macro is running (ownership conflict)
  /itemnotify in packN <slot#> leftmouseup   select an item inside a bag
  /itemnotify <slot#> leftmouseup             select a loose item in a pack slot
  /sellitem <qty>                     sell <qty> of the selected item
  mq.delay(ms), mq.gettime()          bounded polling waits
  mq.event / mq.unevent / mq.doevents / mq.flushevents
                                      merchant quote and refusal chat lines
                                      (Lua Events and Binds documentation)

Safety contract
  * Nothing here runs from an ImGui callback. The UI only sets request flags;
    init.lua's main loop calls these functions (MacroQuest: mq.delay cannot run
    inside ImGui callbacks).
  * A proposal is a snapshot of exact locations and quantities. The run sells
    only what that confirmed snapshot lists. If inventory changed between
    preparation and confirmation, the proposal is rebuilt and must be
    confirmed again.
  * Before every action the exact slot is re-read; it must still contain the
    same item ID and stack size.
  * Selection must be confirmed by Merchant.SelectedItem (ID and ItemSlot /
    ItemSlot2), AND the merchant's price quote for that selection must arrive,
    before /sellitem is issued. A refusal ("I am not interested in buying
    that.") fails the item immediately instead of waiting for a timeout.
  * A sale counts only when the stack is verified gone (or reduced) from that
    slot. A clicked button is never reported as a sale.
  * Every wait is bounded. Failures follow config.ON_FAILURE, capped by
    config.MAX_FAILURES_PER_RUN. Cursor, merchant change/close, and game-state
    problems always stop the run.
  * Stop requests are honored between items and end any in-progress wait
    early. A completed sale cannot be undone.
]]

local mq = require('mq')
local inventory = require('Farm_Vendor.inventory')

local seller = {}
seller.__index = seller

local function read(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

-- ---------------------------------------------------------------------------
-- Live client readings (all wrapped; nil means "unknown")
-- ---------------------------------------------------------------------------

-- Normalize names for quote matching: lower case, backtick/apostrophe equal.
local function norm(s) return (tostring(s or ''):lower():gsub('`', "'")) end

local probe = {}
function probe.gameState()     return read(function() return mq.TLO.EverQuest.GameState() end) end
function probe.merchantOpen()  return read(function() return mq.TLO.Merchant.Open() end) end
function probe.itemsReceived() return read(function() return mq.TLO.Merchant.ItemsReceived() end) end
function probe.merchantId()    return read(function() return mq.TLO.Merchant.ID() end) end
function probe.merchantName()  return read(function() return mq.TLO.Merchant.CleanName() end) end
function probe.cursorId()      return read(function() return mq.TLO.Cursor.ID() end) end
function probe.macroName()     return read(function() return mq.TLO.Macro.Name() end) end
function probe.selected()
    local sel = mq.TLO.Merchant.SelectedItem
    return {
        id    = read(function() return sel.ID() end),
        slot  = read(function() return sel.ItemSlot() end),
        slot2 = read(function() return sel.ItemSlot2() end),
    }
end
seller.probe = probe   -- exposed for the UI header and for tests

--- Create a seller.
--- @param cfg table config module
--- @param log table log module
function seller.new(cfg, log)
    return setmetatable({
        cfg = cfg, log = log,
        mode = cfg.SELL_MODE,
        stopRequested = false,
        running = false,
        progress = { index = 0, total = 0, current = '' },
        lastReport = nil,
        events = { quotes = 0, refusals = 0, lastQuote = nil },
    }, seller)
end

-- ---------------------------------------------------------------------------
-- Readiness
-- ---------------------------------------------------------------------------

--- Evaluate every precondition. Unknown readings are failures.
--- @param ctx table {storeReadonly=bool, storeDetail=string, protectedError=string|nil, faulted=string|nil}
--- @return table[] checks {name, ok, detail}, boolean allOk
function seller:readiness(ctx)
    local checks = {}
    local function add(name, ok, detail) checks[#checks + 1] = { name = name, ok = ok and true or false, detail = detail or '' } end
    local needsMerchant = self.mode ~= 'preview'

    add('Script healthy', not ctx.faulted, ctx.faulted or 'OK')

    local gs = probe.gameState()
    add('In game', gs == 'INGAME', gs and ('GameState ' .. gs) or 'GameState unknown')

    local cur = probe.cursorId()
    add('Cursor empty', cur == nil or cur == 0, (cur and cur ~= 0) and 'Put the cursor item away manually' or 'OK')

    local mac = probe.macroName()
    local macroRunning = type(mac) == 'string' and mac ~= '' and mac ~= 'NULL'
    add('No macro running', not macroRunning,
        macroRunning and ('Macro "' .. mac .. '" is running; end it first') or 'OK')

    if needsMerchant then
        local open = probe.merchantOpen()
        add('Merchant open', open == true, open == true and (probe.merchantName() or 'Open')
            or (open == nil and 'Merchant state unknown' or 'Open a merchant window yourself'))
        local rec = probe.itemsReceived()
        add('Merchant list loaded', rec == true, rec == true and 'OK' or 'Waiting for merchant list')
    else
        add('Merchant open', true, 'Not required in preview mode')
    end

    add('Selections can be saved', not ctx.storeReadonly, ctx.storeReadonly and ctx.storeDetail or 'OK')
    add('Protected bags valid', ctx.protectedError == nil, ctx.protectedError or 'OK')

    local all = true
    for _, c in ipairs(checks) do if not c.ok then all = false end end
    return checks, all
end

-- ---------------------------------------------------------------------------
-- Proposal
-- ---------------------------------------------------------------------------

--- Build a proposal from a fresh scan and the checked IDs.
--- @return table proposal
function seller:buildProposal(scan, checked)
    local items, entries = {}, {}
    local totalQty, estCopper, unpriced = 0, 0, 0
    for _, row in ipairs(scan.rows) do
        if checked[row.id] and row.eligible then
            local unit = row.sellPrice
            local item = {
                id = row.id, name = row.name,
                qty = row.eligibleQty, stacks = row.eligibleStacks,
                unitEst = (type(unit) == 'number' and unit > 0) and unit or nil,
                skippedReasons = row.reasonText,
            }
            if item.unitEst then estCopper = estCopper + item.unitEst * item.qty else unpriced = unpriced + 1 end
            items[#items + 1] = item
            totalQty = totalQty + item.qty
            for _, e in ipairs(row.entries) do
                entries[#entries + 1] = {
                    id = e.id, name = e.name, qty = e.stack,
                    topSlot = e.topSlot, pack = e.pack, sub = e.sub,
                }
            end
        end
    end
    table.sort(entries, function(a, b)
        if a.topSlot ~= b.topSlot then return a.topSlot < b.topSlot end
        return (a.sub or -1) < (b.sub or -1)
    end)
    local fp = {}
    for _, e in ipairs(entries) do fp[#fp + 1] = ('%d@%d:%s#%d'):format(e.id, e.topSlot, tostring(e.sub), e.qty) end
    return {
        items = items, entries = entries,
        totalQty = totalQty, totalStacks = #entries,
        estCopper = (#items > unpriced) and estCopper or nil,   -- sum of priced items only
        unpricedTypes = unpriced,
        fingerprint = table.concat(fp, '|'),
        mode = self.mode,
        createdAt = os.date('%Y-%m-%d %H:%M:%S'),
    }
end

-- ---------------------------------------------------------------------------
-- Worker helpers
-- ---------------------------------------------------------------------------

--- Wait up to ms for cond() or a stop request. Returns true if cond() became true.
--- Polls in short documented mq.delay steps and calls mq.doevents() each step
--- so merchant chat events (quote/refusal) are processed while waiting.
function seller:waitFor(ms, cond)
    local start = mq.gettime()
    while true do
        mq.doevents()
        if cond() then return true end
        if self.stopRequested then return false end
        if mq.gettime() - start >= ms then break end
        mq.delay(50)
    end
    mq.doevents()
    return cond() and true or false
end

-- ---------------------------------------------------------------------------
-- Merchant chat events (documented mq.event / mq.doevents / mq.flushevents)
-- ---------------------------------------------------------------------------
-- Seen in the client on 2026-10-13:
--   Merchant Wyn'las told you, 'I'll give you 1 gold 9 silver per Nodding Blue Lily'
--   Merchant Wyn'las told you, 'I am not interested in buying that.'
-- Counters only increase; the worker compares before/after snapshots, so an
-- old line can never satisfy a new wait.

local EVENT_QUOTE, EVENT_REFUSAL = 'fv_quote', 'fv_refusal'

function seller:registerEvents()
    self.events = { quotes = 0, refusals = 0, lastQuote = nil }
    mq.event(EVENT_QUOTE, '#*#' .. self.cfg.QUOTE_PHRASE .. '#*#', function(line)
        -- A quote of the form "... per <item>'" must name the item we selected;
        -- a quote for a different item is logged and ignored. A quote without
        -- " per " (format not yet seen) is accepted with a warning, because the
        -- selection itself is already verified by Merchant.SelectedItem.
        local l, want = norm(line), norm(self.expectName)
        if self.expectName and l:find(' per ', 1, true) and not l:find(want, 1, true) then
            self.events.otherQuotes = (self.events.otherQuotes or 0) + 1
            self.log.warn('item.quote_other_item', { expected = self.expectName, quote = line })
            return
        end
        if self.expectName and not l:find(want, 1, true) then
            self.log.warn('item.quote_unnamed', { expected = self.expectName, quote = line })
        end
        self.events.quotes = self.events.quotes + 1
        self.events.lastQuote = line
    end)
    mq.event(EVENT_REFUSAL, '#*#' .. self.cfg.REFUSAL_PHRASE .. '#*#', function(line)
        self.events.refusals = self.events.refusals + 1
    end)
end

function seller:unregisterEvents()
    mq.unevent(EVENT_QUOTE)
    mq.unevent(EVENT_REFUSAL)
end

--- Discard queued (old) merchant lines before a new selection.
function seller:flushMerchantEvents()
    mq.flushevents(EVENT_QUOTE)
    mq.flushevents(EVENT_REFUSAL)
end

--- Checks that always stop the run. Returns nil or a reason string.
function seller:hardStopReason(merchantId)
    if probe.gameState() ~= 'INGAME' then return 'Left the game world' end
    local cur = probe.cursorId()
    if cur ~= nil and cur ~= 0 then return 'Something is on the cursor; stopped for manual handling' end
    if self.mode ~= 'preview' then
        if probe.merchantOpen() ~= true then return 'Merchant window closed' end
        local mid = probe.merchantId()
        if mid == nil or mid ~= merchantId then return 'Merchant changed' end
    end
    local mac = probe.macroName()
    if type(mac) == 'string' and mac ~= '' and mac ~= 'NULL' then return 'A macro started running' end
    return nil
end

local function selectionMatches(e)
    local s = probe.selected()
    if s.id ~= e.id or s.slot ~= e.topSlot then return false end
    if e.sub ~= nil and s.slot2 ~= e.sub then return false end
    return true
end

local function issueSelect(e)
    if e.sub ~= nil then
        -- /itemnotify uses 1-based bag slots; ItemSlot2 is 0-based (Slot Names reference).
        mq.cmdf('/itemnotify in pack%d %d leftmouseup', e.pack, e.sub + 1)
    else
        mq.cmdf('/itemnotify %d leftmouseup', e.topSlot)
    end
end

--- Select one entry and wait for the merchant's quote naming that item.
--- @return string outcome 'ok'|'refused'|'noquote'|'noselect'|'cursor'|'stopped', string detail
function seller:selectAndQuote(e)
    local cfg, log = self.cfg, self.log
    self:flushMerchantEvents()
    self.expectName = e.name
    local q0, r0 = self.events.quotes, self.events.refusals
    issueSelect(e)
    local selected = self:waitFor(cfg.SELECT_TIMEOUT_MS, function() return selectionMatches(e) end)
    local cur = probe.cursorId()
    if cur ~= nil and cur ~= 0 then return 'cursor', 'Item went to the cursor; stopped for manual handling' end
    if self.stopRequested and not selected then return 'stopped' end
    if not selected then return 'noselect', 'Merchant did not report the expected selection' end
    log.debug('item.selected', { id = e.id, name = e.name, pack = e.pack, slot = e.sub and (e.sub + 1) or 'loose' })

    local answered = self:waitFor(cfg.QUOTE_TIMEOUT_MS, function()
        return self.events.quotes > q0 or self.events.refusals > r0
    end)
    if self.events.quotes > q0 then
        log.debug('item.quoted', { id = e.id, name = e.name, quote = self.events.lastQuote })
        return 'ok'
    end
    if self.events.refusals > r0 then return 'refused', 'Merchant is not interested in buying this item' end
    if self.stopRequested then return 'stopped' end
    return 'noquote', 'No price quote from merchant after selection'
end

--- Issue /sellitem for the full entry quantity and verify the result.
--- @return string outcome 'sold'|'sale_refused'|'partial'|'timeout'|'stopped', string detail
function seller:sellOnce(e, report)
    local cfg, log = self.cfg, self.log
    if cfg.POST_QUOTE_DELAY_MS > 0 then mq.delay(cfg.POST_QUOTE_DELAY_MS) end
    local r1 = self.events.refusals
    mq.cmdf('/sellitem %d', e.qty)
    local gone = self:waitFor(cfg.SELL_TIMEOUT_MS, function()
        if self.events.refusals > r1 then return true end
        local x = inventory.readLocation(e.topSlot, e.sub)
        return x == nil or x.id ~= e.id or (type(x.stack) == 'number' and x.stack < e.qty)
    end)
    local after = inventory.readLocation(e.topSlot, e.sub)
    local remaining = (after and after.id == e.id) and (after.stack or e.qty) or 0
    local sold = e.qty - remaining
    if sold > 0 then
        report.byId[e.id].sold = report.byId[e.id].sold + sold
        report.soldQty = report.soldQty + sold
    end
    if remaining == 0 then
        log.info('sale.verified', { id = e.id, name = e.name, qty = sold, pack = e.pack, slot = e.sub and (e.sub + 1) or 'loose' })
        return 'sold'
    end
    if sold > 0 then
        e.qty = remaining      -- never retry a partial; report it
        return 'partial', ('Partial sale: %d of %d sold'):format(sold, sold + remaining)
    end
    if self.events.refusals > r1 then return 'sale_refused', 'Merchant refused the sale (not interested)' end
    if self.stopRequested then return 'stopped' end
    return 'timeout', 'Sale not confirmed within timeout'
end

-- ---------------------------------------------------------------------------
-- Run
-- ---------------------------------------------------------------------------

--- Execute a confirmed proposal. Blocking; call only from the main loop.
--- @return table report
function seller:run(proposal)
    local cfg, log = self.cfg, self.log
    self.running, self.stopRequested = true, false
    local report = {
        mode = self.mode, startedAt = os.date('%Y-%m-%d %H:%M:%S'),
        planned = proposal.totalQty, plannedStacks = proposal.totalStacks,
        estCopper = proposal.estCopper, unpricedTypes = proposal.unpricedTypes or 0,
        byId = {}, order = {}, failures = {}, stopReason = 'Completed',
        stacksDone = 0, soldQty = 0, selectedOk = 0,
    }
    for _, it in ipairs(proposal.items) do
        report.byId[it.id] = { id = it.id, name = it.name, planned = it.qty, sold = 0, selected = 0, failed = 0, skipped = 0 }
        report.order[#report.order + 1] = it.id
    end
    local merchantId = probe.merchantId()
    report.merchant = probe.merchantName()
    report.coinStart = inventory.coinCopper()
    local skipIds = {}
    self.progress = { index = 0, total = #proposal.entries, current = '' }

    log.info('run.start', { mode = self.mode, stacks = proposal.totalStacks, qty = proposal.totalQty,
        merchant = report.merchant or 'none', policy = cfg.ON_FAILURE })

    local function fail(e, reason, hard)
        local r = report.byId[e.id]
        if r then r.failed = r.failed + 1 end
        report.failures[#report.failures + 1] = { id = e.id, name = e.name, pack = e.pack, sub = e.sub, reason = reason }
        log.warn('item.failed', { id = e.id, name = e.name, pack = e.pack, slot = e.sub and (e.sub + 1) or 'loose', reason = reason })
        if hard then return 'stop' end
        if #report.failures >= cfg.MAX_FAILURES_PER_RUN then
            report.stopReason = ('Failure limit reached (%d)'):format(cfg.MAX_FAILURES_PER_RUN)
            return 'stop'
        end
        if cfg.ON_FAILURE == 'stop' then report.stopReason = 'Stopped on failure: ' .. reason; return 'stop' end
        skipIds[e.id] = true
        return 'continue'
    end

    for i, e in ipairs(proposal.entries) do
        self.progress.index, self.progress.current = i, e.name
        if self.stopRequested then report.stopReason = 'Stopped by operator'; break end
        if skipIds[e.id] then
            report.byId[e.id].skipped = report.byId[e.id].skipped + 1
        else
            local hard = self:hardStopReason(merchantId)
            if hard then report.stopReason = hard; fail(e, hard, true); break end

            -- 1. Revalidate the exact location.
            local now = inventory.readLocation(e.topSlot, e.sub)
            if not now or now.id ~= e.id or now.stack ~= e.qty then
                if fail(e, 'Slot changed since confirmation') == 'stop' then break end
                goto continue
            end

            if self.mode == 'preview' then
                log.info('preview.would_sell', { id = e.id, name = e.name, qty = e.qty, pack = e.pack, slot = e.sub and (e.sub + 1) or 'loose' })
                report.byId[e.id].selected = report.byId[e.id].selected + 1
                report.stacksDone = report.stacksDone + 1
                goto continue
            end

            -- 2-4. Select, verify, wait for this item's quote, sell, verify.
            --      One sale-time refusal after a valid quote is retried up to
            --      cfg.SELL_REFUSAL_RETRIES times (bounded), re-selecting first.
            do
                local outcome, detail
                local attempt = 0
                while true do
                    attempt = attempt + 1
                    outcome, detail = self:selectAndQuote(e)
                    if outcome == 'ok' then
                        if attempt == 1 then
                            report.byId[e.id].selected = report.byId[e.id].selected + 1
                            report.selectedOk = report.selectedOk + 1
                        end
                        if self.mode == 'select_test' then break end
                        local h = self:hardStopReason(merchantId)
                        if h then outcome, detail = 'hard', h; break end
                        if self.stopRequested then outcome = 'stopped'; break end
                        outcome, detail = self:sellOnce(e, report)
                    end
                    if outcome == 'sale_refused' and attempt <= cfg.SELL_REFUSAL_RETRIES and not self.stopRequested then
                        log.warn('sale.retry', { id = e.id, name = e.name, attempt = attempt + 1,
                            wait_ms = cfg.RETRY_DELAY_MS, note = 'refused after a valid quote; re-selecting' })
                        self:waitFor(cfg.RETRY_DELAY_MS, function() return false end)
                        local h = self:hardStopReason(merchantId)
                        if h then outcome, detail = 'hard', h; break end
                    else
                        break
                    end
                end

                if outcome == 'ok' then
                    report.stacksDone = report.stacksDone + 1          -- select_test success
                elseif outcome == 'sold' then
                    report.stacksDone = report.stacksDone + 1
                elseif outcome == 'stopped' then
                    report.stopReason = 'Stopped by operator'; break
                elseif outcome == 'cursor' or outcome == 'hard' then
                    report.stopReason = detail; fail(e, detail, true); break
                else
                    if fail(e, detail) == 'stop' then break end
                    goto continue
                end
            end

            ::pace::
            if cfg.BETWEEN_ITEMS_DELAY_MS > 0 then
                mq.delay(cfg.BETWEEN_ITEMS_DELAY_MS, function() return self.stopRequested end)
            end
        end
        ::continue::
    end

    if cfg.COIN_SETTLE_DELAY_MS > 0 and self.mode == 'live' then mq.delay(cfg.COIN_SETTLE_DELAY_MS) end
    report.coinEnd = inventory.coinCopper()
    if report.coinStart and report.coinEnd then report.coinDelta = report.coinEnd - report.coinStart end
    report.endedAt = os.date('%Y-%m-%d %H:%M:%S')
    self.running, self.stopRequested = false, false
    self.lastReport = report
    log.info('run.end', { mode = report.mode, reason = report.stopReason, sold = report.soldQty,
        stacks_done = report.stacksDone, failures = #report.failures,
        coin_delta = report.coinDelta and inventory.formatCoin(report.coinDelta) or 'unknown' })
    return report
end

--- Request a stop (safe from UI callbacks and binds; only sets a flag).
function seller:requestStop()
    if self.running and not self.stopRequested then
        self.stopRequested = true
        self.log.warn('run.stop_requested', {})
    end
end

return seller
