--[[
Farm Vendor - init.lua (entry point)
====================================

Launch:   /lua run Farm_Vendor              (mode from config.SELL_MODE)
          /lua run Farm_Vendor preview      (force preview this session)
          /lua run Farm_Vendor selecttest   (force selection test this session)
Stop:     Cancel button, window X, /fvendor quit, or /lua stop Farm_Vendor
Emergency:/fvendor stop  (stops selling before the next item)

What it does
  1. Validates configuration and the game session (fail closed).
  2. Loads remembered checks from a per-server/per-character INI.
  3. Scans carried inventory and shows a checklist (no sale on launch).
  4. "Sell All Checked Items" builds a proposal and opens a confirmation window.
  5. "Confirm Sale" re-scans; if anything changed, the proposal is rebuilt and
     must be confirmed again. Otherwise selections are saved (must succeed),
     then the guarded worker processes the exact confirmed stacks.
  6. A report shows verified results and measured coin change.

Name history
  Released as magfarm_vendor (v1.0.0 to v1.1.1), renamed Farm_Vendor in v1.2.0
  because the tool is not magician specific. It is still built under the
  MagFarm engineering rules. Saved selections are copied over once (see
  config.LEGACY_SCRIPT_NAME).

Credits
  Workflow based on two community macros (no code copied):
    Sellitem.mac    by Cannonballdex (RedGuides)
    AutoVendor 3.6  by Ionis (RedGuides)
  Links and details: README.md, Credits. Interfaces verified against
  docs.macroquest.org, RedGuides docs and mq-definitions (INTERFACES.md).

Architecture (one owner per responsibility)
  config.lua     commented parameters + validation
  log.lua        structured console/file/UI logging
  store.lua      INI persistence with atomic writes and schema protection
  inventory.lua  read-only inventory scan and coin reading
  seller.lua     readiness, proposals, guarded selling worker
  ui.lua         ImGui windows (sets request flags only)
  init.lua       startup checks, request processing, main loop, shutdown

Package resolution follows MagFarm: the folder sits in the active MacroQuest
Lua directory and modules load with require('Farm_Vendor.<module>'). No
EverQuest or MacroQuest install path is hardcoded.
]]

local mq = require('mq')

local PREFIX = '[FarmVendor]'

-- Load modules defensively so a missing file produces a clear message.
local function need(name)
    local ok, mod = pcall(require, 'Farm_Vendor.' .. name)
    if not ok then
        print(('%s ERROR startup.module_missing module=%s error=%s'):format(PREFIX, name, tostring(mod)))
        return nil
    end
    return mod
end

local config    = need('config')
local log       = need('log')
local store     = need('store')
local inventory = need('inventory')
local sellerMod = need('seller')
local ui        = need('ui')
if not (config and log and store and inventory and sellerMod and ui) then
    print(PREFIX .. ' ERROR startup.aborted reason="module load failed"')
    return
end

-- ---------------------------------------------------------------------------
-- 1. Configuration validation (fail closed)
-- ---------------------------------------------------------------------------
do
    local ok, errors = config.validate()
    if not ok then
        print(PREFIX .. ' ERROR startup.config_invalid count=' .. #errors)
        for _, e in ipairs(errors) do print(PREFIX .. '   ' .. e) end
        print(PREFIX .. ' Fix Farm_Vendor/config.lua and run again. Nothing was changed.')
        return
    end
end

if not ui.available then
    print(PREFIX .. ' ERROR startup.imgui_unavailable reason="ImGui bindings not found"')
    return
end

-- ---------------------------------------------------------------------------
-- 2. Launch arguments (may only DOWNGRADE the mode)
-- ---------------------------------------------------------------------------
local args = { ... }
local mode = config.SELL_MODE
local argNote = nil
if #args > 1 then
    print(PREFIX .. ' ERROR startup.args_invalid reason="at most one argument: preview or selecttest"')
    return
elseif #args == 1 then
    local a = tostring(args[1]):lower()
    local requested = config.MODE_ARGS[a]
    if not requested then
        print(('%s ERROR startup.arg_rejected arg=%q allowed="preview, selecttest" note="live is enabled only in config.lua"')
            :format(PREFIX, a))
        return
    end
    if config.MODE_RANK[requested] <= config.MODE_RANK[mode] then
        mode = requested
    else
        argNote = ('argument %s ignored: cannot raise mode above config (%s)'):format(a, mode)
    end
end

-- ---------------------------------------------------------------------------
-- 3. Session identity (needed for per-character files)
-- ---------------------------------------------------------------------------
local function read(fn) local ok, v = pcall(fn); if ok then return v end end
local gameState = read(function() return mq.TLO.EverQuest.GameState() end)
local charName  = read(function() return mq.TLO.Me.Name() end)
local server    = read(function() return mq.TLO.EverQuest.Server() end)
if gameState ~= 'INGAME' or type(charName) ~= 'string' or charName == ''
    or type(server) ~= 'string' or server == '' then
    print(('%s ERROR startup.not_in_game game_state=%s note="log in to a character first"')
        :format(PREFIX, tostring(gameState)))
    return
end
if type(mq.configDir) ~= 'string' or mq.configDir == '' then
    print(PREFIX .. ' ERROR startup.config_dir_unavailable')
    return
end

local fileBase = ('%s/%s_%s_%s'):format(mq.configDir, config.SCRIPT_NAME,
    store.encodeName(server), store.encodeName(charName))

-- One-time carry-over of selections from the previous package name.
-- The legacy file is only READ; it is never moved, renamed or modified.
local migrationNote = nil
do
    local newIni = fileBase .. '.ini'
    local legacy = config.LEGACY_SCRIPT_NAME
    if legacy ~= '' and legacy ~= config.SCRIPT_NAME then
        local legacyIni = ('%s/%s_%s_%s.ini'):format(mq.configDir, legacy,
            store.encodeName(server), store.encodeName(charName))
        local exists = io.open(newIni, 'rb')
        if exists then
            exists:close()
        else
            local src = io.open(legacyIni, 'rb')
            if src then
                local data = src:read('*a') or ''
                src:close()
                local dst, derr = io.open(newIni, 'wb')
                if dst then
                    local ok = dst:write(data)
                    dst:close()
                    migrationNote = ok and { result = 'copied', from = legacyIni, to = newIni, bytes = #data }
                        or { result = 'write_failed', from = legacyIni, to = newIni }
                    if not ok then os.remove(newIni) end
                else
                    migrationNote = { result = 'open_failed', from = legacyIni, to = newIni, error = tostring(derr) }
                end
            end
        end
    end
end

log.configure({
    prefix = PREFIX,
    consoleLevel = config.CONSOLE_LOG_LEVEL,
    fileLevel = config.FILE_LOG_LEVEL,
    filePath = config.FILE_LOG_ENABLED and (fileBase .. '.log') or nil,
    maxBytes = config.LOG_MAX_BYTES,
    ringMax = config.UI_LOG_LINES,
})
log.info('startup.begin', { version = config.VERSION, mode = mode, character = charName, server = server })
if argNote then log.warn('startup.arg_ignored', { note = argNote }) end
if migrationNote then
    if migrationNote.result == 'copied' then
        log.info('startup.selections_migrated', migrationNote)
    else
        log.error('startup.selections_migration_failed', migrationNote)
    end
end

-- ---------------------------------------------------------------------------
-- 4. Application state shared with the UI
-- ---------------------------------------------------------------------------
local app = {
    cfg = config, log = log,
    identity = { name = charName, server = server },
    store = store.new(fileBase .. '.ini', {
        schema = config.INI_SCHEMA, maxBytes = config.INI_MAX_BYTES,
        maxNameLength = config.MAX_ITEM_NAME_LENGTH,
    }),
    seller = sellerMod.new(config, log),
    scan = nil,
    checked = {},          -- [id] = true  (working copy; saved explicitly)
    names = {},            -- [id] = name  (for the INI readability section)
    dirty = false,
    protected = {}, protectedError = nil,
    readiness = {}, readyToSell = false,
    proposal = nil, showConfirm = false, focusConfirm = false, confirmNotice = nil,
    filter = { search = '', checkedOnly = false, showExcluded = false },
    showMain = true,
    faulted = nil,         -- set on internal error; blocks selling until restart
    running = true,        -- main loop flag
    requests = {},         -- set by UI/binds, consumed by main loop
    logVersionSeen = -1,
    lastUiError = nil,
}
app.seller.mode = mode

--- UI errors are logged once per distinct message and fault the session.
function app.reportUiError(err)
    local msg = tostring(err)
    if app.lastUiError ~= msg then
        app.lastUiError = msg
        log.error('ui.render_error', { error = msg })
    end
    app.faulted = 'UI error; restart the script'
end

-- Load selections.
do
    local ok, err = app.store:load()
    for _, w in ipairs(app.store.warnings) do log.warn('store.parse_warning', { detail = w }) end
    if ok then
        for id in pairs(app.store.record.selected) do app.checked[id] = true end
        for id, n in pairs(app.store.record.names) do app.names[id] = n end
        log.info('store.loaded', { status = app.store.status, selected = (function()
            local c = 0; for _ in pairs(app.checked) do c = c + 1 end; return c end)(), path = app.store.path })
    else
        log.error('store.load_failed', { detail = err, path = app.store.path })
    end
end

-- Protected bags (INI override or config default). Malformed => selling blocked.
local function refreshProtected()
    local list, err = app.store:protectedBags(config.DEFAULT_PROTECTED_BAGS)
    if list then
        app.protected, app.protectedError = list, nil
    else
        app.protected, app.protectedError = {}, 'INI ProtectedBags: ' .. tostring(err)
        log.error('settings.protected_bags_invalid', { detail = err })
    end
end
refreshProtected()

-- ---------------------------------------------------------------------------
-- 5. Actions (main loop only)
-- ---------------------------------------------------------------------------
local function rescan(reason)
    local ok, result = pcall(inventory.scan, config, app.protectedError and {} or app.protected)
    if not ok then
        log.error('inventory.scan_failed', { error = result })
        app.faulted = 'Inventory scan failed; see log'
        return false
    end
    -- If protected bags are invalid we still list items for viewing, but
    -- readiness blocks selling (protectedError is set).
    app.scan = result
    local eligible = 0
    for _, r in ipairs(result.rows) do if r.eligible then eligible = eligible + 1 end end
    for _, r in ipairs(result.rows) do if app.checked[r.id] then app.names[r.id] = r.name end end
    log.info('inventory.scanned', { reason = reason, rows = #result.rows, eligible = eligible,
        protected_hidden = result.protectedCount })
    return true
end

local function save(reason)
    app.store:setSelections(app.checked, app.names)
    local ok, err = app.store:save()
    if ok then
        app.dirty = false
        log.info('store.saved', { reason = reason, path = app.store.path, count = app.store.saveCount })
    else
        log.error('store.save_failed', { reason = reason, detail = err })
    end
    return ok
end

local function updateReadiness()
    app.readiness, app.readyToSell = app.seller:readiness({
        storeReadonly = app.store.readonly, storeDetail = app.store.statusDetail,
        protectedError = app.protectedError, faulted = app.faulted,
    })
end

local function prepare()
    updateReadiness()
    if not app.readyToSell then log.warn('sale.prepare_blocked', {}); return end
    if not rescan('prepare') then return end
    local p = app.seller:buildProposal(app.scan, app.checked)
    if p.totalStacks == 0 then
        log.warn('sale.nothing_eligible', { note = 'no checked item has an eligible stack' })
        return
    end
    app.proposal, app.showConfirm, app.focusConfirm, app.confirmNotice = p, true, true, nil
    log.info('sale.proposed', { types = #p.items, stacks = p.totalStacks, qty = p.totalQty, mode = p.mode })
end

local function confirm()
    local old = app.proposal
    if not old then return end
    updateReadiness()
    if not app.readyToSell then
        app.confirmNotice = 'Blocked: a readiness check failed. Fix it, then confirm again.'
        log.warn('sale.confirm_blocked', {})
        return
    end
    -- Re-scan and compare: a changed inventory requires a new confirmation.
    if not rescan('confirm') then return end
    local fresh = app.seller:buildProposal(app.scan, app.checked)
    if fresh.fingerprint ~= old.fingerprint then
        app.proposal = fresh
        app.confirmNotice = 'Inventory changed since this list was prepared. Review the updated list and confirm again.'
        log.warn('sale.proposal_changed', { stacks = fresh.totalStacks, qty = fresh.totalQty })
        if fresh.totalStacks == 0 then app.showConfirm, app.proposal = false, nil end
        return
    end
    -- Approved selections must persist before any action.
    if not save('confirm') then
        app.confirmNotice = 'Saving selections failed, so nothing was sold. See Activity Log.'
        return
    end
    app.showConfirm = false
    local ok, result = xpcall(function() return app.seller:run(old) end, debug.traceback)
    if not ok then
        app.seller.running, app.seller.stopRequested = false, false
        app.faulted = 'Selling worker error; restart the script'
        log.error('run.internal_error', { error = result })
    end
    app.proposal = nil
    rescan('after_run')
end

-- ---------------------------------------------------------------------------
-- 6. Command binding (documented mq.bind) - only sets flags
-- ---------------------------------------------------------------------------
local function onBind(...)
    local sub = (select(1, ...) or ''):lower()
    if sub == 'stop' then
        if app.seller.running then app.seller:requestStop() else log.info('bind.stop_idle', {}) end
    elseif sub == 'quit' then
        if app.seller.running then app.seller:requestStop() end
        app.requests.quit = true
    elseif sub == 'show' then
        app.showMain = true
    else
        print(('%s usage: %s stop | quit | show'):format(PREFIX, config.BIND_COMMAND))
    end
end
mq.bind(config.BIND_COMMAND, onBind)
app.seller:registerEvents()

-- ---------------------------------------------------------------------------
-- 7. UI registration and main loop
-- ---------------------------------------------------------------------------
mq.imgui.init(config.SCRIPT_NAME, function() ui.render(app) end)

rescan('startup')
updateReadiness()
local lastMerchantOpen = app.scan and app.scan.merchantOpen
log.info('startup.ready', { mode = mode, file = app.store.path })

while app.running do
    local ok, err = xpcall(function()
        local r = app.requests
        app.requests = {}
        if r.quit and not app.seller.running then
            app.running = false
            return
        end
        if r.rescan then rescan('operator') end
        -- Prices and "Merchant offers no price" exclusions depend on the open
        -- merchant, so re-scan whenever the merchant window opens or closes.
        local mo = app.seller.probe.merchantOpen() == true
        if mo ~= lastMerchantOpen and not r.rescan then rescan(mo and 'merchant_opened' or 'merchant_closed') end
        lastMerchantOpen = mo
        -- Discard merchant chat lines that arrive while idle; each selection
        -- also flushes before it starts, so only fresh lines are ever counted.
        app.seller:flushMerchantEvents()
        if r.save then save('operator') end
        if r.cancelConfirm then
            app.showConfirm, app.proposal, app.confirmNotice = false, nil, nil
            log.info('sale.cancelled', { note = 'confirmation cancelled; nothing sold' })
        end
        if r.prepare then prepare() end
        if r.confirm then confirm() end
        updateReadiness()
    end, debug.traceback)
    if not ok then
        app.faulted = 'Internal error; restart the script'
        log.error('loop.internal_error', { error = err })
    end
    if app.running then mq.delay(config.LOOP_DELAY_MS) end
end

-- ---------------------------------------------------------------------------
-- 8. Shutdown (unsaved changes are intentionally discarded: Cancel = no action)
-- ---------------------------------------------------------------------------
if app.dirty then log.info('shutdown.discarded_unsaved', { note = 'Cancel exits without saving' }) end
mq.unbind(config.BIND_COMMAND)
app.seller:unregisterEvents()
mq.imgui.destroy(config.SCRIPT_NAME)
log.info('shutdown.complete', {})
