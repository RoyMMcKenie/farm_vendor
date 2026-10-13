--[[
magfarm_vendor/seller.lua
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
  mq.delay(ms, condition)             bounded wait that ends early on condition

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
    ItemSlot2) before /sellitem is issued.
  * A sale counts only when the stack is verified gone (or reduced) from that
    slot. A clicked button is never reported as a sale.
  * Every wait is bounded. Failures follow config.ON_FAILURE, capped by
    config.MAX_FAILURES_PER_RUN. Cursor, merchant change/close, and game-state
    problems always stop the run.
  * Stop requests are honored between items and end any in-progress wait
    early. A completed sale cannot be undone.
]]

local mq = require('mq')
local inventory = require('magfarm_vendor.inventory')

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
    local totalQty, estCopper, estKnown = 0, 0, true
    for _, row in ipairs(scan.rows) do
        if checked[row.id] and row.eligible then
            local unit = row.sellPrice
            local item = {
                id = row.id, name = row.name,
                qty = row.eligibleQty, stacks = row.eligibleStacks,
                unitEst = (type(unit) == 'number' and unit > 0) and unit or nil,
                skippedReasons = row.reasonText,
            }
            if item.unitEst then estCopper = estCopper + item.unitEst * item.qty else estKnown = false end
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
        estCopper = (#items > 0 and estKnown) and estCopper or nil,
        fingerprint = table.concat(fp, '|'),
        mode = self.mode,
        createdAt = os.date('%Y-%m-%d %H:%M:%S'),
    }
end

-- ---------------------------------------------------------------------------
-- Worker helpers
-- ---------------------------------------------------------------------------

--- Wait up to ms for cond() or a stop request. Returns true if cond() became true.
function seller:waitFor(ms, cond)
    mq.delay(ms, function() return self.stopRequested or cond() end)
    return cond() and true or false
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
        estCopper = proposal.estCopper,
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

            -- 2. Select and verify the selection.
            issueSelect(e)
            local selected = self:waitFor(cfg.SELECT_TIMEOUT_MS, function() return selectionMatches(e) end)
            local cur = probe.cursorId()
            if cur ~= nil and cur ~= 0 then
                report.stopReason = 'Item went to the cursor; stopped for manual handling'
                fail(e, report.stopReason, true); break
            end
            if self.stopRequested and not selected then report.stopReason = 'Stopped by operator'; break end
            if not selected then
                if fail(e, 'Merchant did not report the expected selection') == 'stop' then break end
                goto continue
            end
            report.byId[e.id].selected = report.byId[e.id].selected + 1
            report.selectedOk = report.selectedOk + 1
            log.debug('item.selected', { id = e.id, name = e.name, pack = e.pack, slot = e.sub and (e.sub + 1) or 'loose' })

            if self.mode == 'select_test' then
                report.stacksDone = report.stacksDone + 1
                goto pace
            end

            -- 3. Final guard immediately before the irreversible action.
            hard = self:hardStopReason(merchantId)
            if hard then report.stopReason = hard; fail(e, hard, true); break end
            if self.stopRequested then report.stopReason = 'Stopped by operator'; break end

            -- 4. Sell and verify the stack left (or reduced in) that exact slot.
            mq.cmdf('/sellitem %d', e.qty)
            do
                local gone = self:waitFor(cfg.SELL_TIMEOUT_MS, function()
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
                if gone and remaining == 0 then
                    report.stacksDone = report.stacksDone + 1
                    log.info('sale.verified', { id = e.id, name = e.name, qty = sold, pack = e.pack, slot = e.sub and (e.sub + 1) or 'loose' })
                elseif sold > 0 then
                    if fail(e, ('Partial sale: %d of %d sold'):format(sold, e.qty)) == 'stop' then break end
                    goto continue
                else
                    if self.stopRequested then report.stopReason = 'Stopped by operator (sale unconfirmed)'; break end
                    if fail(e, 'Sale not confirmed within timeout (merchant may refuse this item)') == 'stop' then break end
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
