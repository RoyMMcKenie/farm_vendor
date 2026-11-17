--[[==========================================================================
  FILE        : Farm_Vendor/init.lua   (entry point)
  PACKAGE     : Farm Vendor  (MacroQuest Lua / EverQuest)
  VERSION     : 1.4.0
  CHANGES     : 1.4.0  Never Sell: app.neverSell loaded from the INI, saved
                       on its own the moment a box changes (saveNeverSell,
                       request saveNeverSell), and passed to every
                       buildProposal call so those items are never sold.
                1.3.0  Loads the consolidated files: core (log, store) and
                       engine (inventory, seller), plus config and ui. The
                       local names log, store, inventory and sellerMod are
                       unchanged, so no other line of logic changed. Header,
                       footer, function documentation and line comments
                       brought to the project standard.
                1.2.2  No change.
                1.2.1  No change.
                1.2.0  Renamed from magfarm_vendor to Farm_Vendor; one time
                       copy of saved selections from the old file name.
                1.1.1  No change.
                1.1.0  Merchant chat events registered and flushed every
                       loop; re-scan when the merchant opens or closes.
                1.0.0  First release.

  CREDITS     : Original to Farm Vendor. Workflow based on two community
                macros (no code copied):
                  Sellitem.mac   by Cannonballdex (RedGuides)
                  AutoVendor 3.6 by Ionis (RedGuides)
                Links and details: README.md, Credits.

  WHAT  : Startup checks, the shared app state, the actions the buttons
          ask for, the /fvendor command, the main loop and shutdown.

  WHY   : One owner for everything that changes state or talks to the game
          outside the selling worker. The UI only sets request flags; this
          file acts on them between frames, where mq.delay is allowed.

  WHERE : <MacroQuest>/lua/Farm_Vendor/init.lua
          Launch : /lua run Farm_Vendor              (mode from config.lua)
                   /lua run Farm_Vendor preview      (force preview)
                   /lua run Farm_Vendor selecttest   (force selection test)
          Stop   : Cancel button, window X, /fvendor quit, or
                   /lua stop Farm_Vendor
          Pause  : Stop Selling button or /fvendor stop (stops selling
                   before the next item)

  HOW   : 1. Load modules; validate config.lua (fail closed).
          2. Read the launch argument (it may only lower the mode).
          3. Check the game session; build per server and per character
             file names; one time copy of selections from the old name.
          4. Build app (the state shared with the UI) and load selections.
          5. Actions: rescan, save, prepare (opens Confirm), confirm
             (re-scan, compare, save, then run the worker).
          6. Bind /fvendor and register merchant chat events.
          7. Register the UI and run the main loop.
          8. Shut down: unbind, unregister, destroy the UI.
          Name history: released as magfarm_vendor (1.0.0 to 1.1.1),
          renamed Farm_Vendor in 1.2.0 because the tool is not magician
          specific (see config.LEGACY_SCRIPT_NAME).
          Package resolution: the folder sits in the active MacroQuest lua
          folder and modules load with require('Farm_Vendor.<file>'). No
          EverQuest or MacroQuest install path is hardcoded.

  WHEN  : Runs once per /lua run Farm_Vendor and stays in the main loop
          until the player exits.
==========================================================================]]--

-- MacroQuest Lua API (TLOs, bind, delay, imgui, configDir).
local mq = require('mq')

-- Every console line starts with this.
local PREFIX = '[FarmVendor]'

--[[------------------------------------------------------------------------
  need(name)  (private)

  WHAT  : require('Farm_Vendor.' .. name), returning nil and printing a
          clear message if the file is missing or has an error.
  WHY   : A missing or broken file must produce a readable message, not a
          Lua stack trace, and must stop startup.
  WHERE : The four need() calls just below.
  HOW   : pcall around require.
  WHEN  : Startup only.
--------------------------------------------------------------------------]]
-- Load modules defensively so a missing file produces a clear message.
local function need(name)
    local ok, mod = pcall(require, 'Farm_Vendor.' .. name)
    if not ok then
        print(('%s ERROR startup.module_missing module=%s error=%s'):format(PREFIX, name, tostring(mod)))   -- name the file and the error
        return nil                                       -- caller aborts
    end
    return mod
end

-- The five package files. core holds log and store; engine holds inventory
-- and seller. The same local names as before are kept on purpose.
local config    = need('config')
local core      = need('core')
local engine    = need('engine')
local ui        = need('ui')   -- ImGui windows
local log       = core and core.log                 -- logging
local store     = core and core.store               -- INI persistence
local inventory = engine and engine.inventory       -- bag scan and coin
local sellerMod = engine and engine.seller          -- readiness and worker
if not (config and log and store and inventory and sellerMod and ui) then
    print(PREFIX .. ' ERROR startup.aborted reason="module load failed"')
    return                                           -- nothing was changed
end

-- ---------------------------------------------------------------------------
-- 1. Configuration validation (fail closed)
-- ---------------------------------------------------------------------------
do
    local ok, errors = config.validate()
    if not ok then
        -- List every problem, then stop without touching anything.
        print(PREFIX .. ' ERROR startup.config_invalid count=' .. #errors)
        for _, e in ipairs(errors) do print(PREFIX .. '   ' .. e) end
        print(PREFIX .. ' Fix Farm_Vendor/config.lua and run again. Nothing was changed.')
        return
    end
end

-- The windows are the only way to confirm a sale; no ImGui, no start.
if not ui.available then
    print(PREFIX .. ' ERROR startup.imgui_unavailable reason="ImGui bindings not found"')
    return
end

-- ---------------------------------------------------------------------------
-- 2. Launch arguments (may only DOWNGRADE the mode)
-- ---------------------------------------------------------------------------
local args = { ... }                                 -- words after /lua run Farm_Vendor
local mode = config.SELL_MODE                        -- start from config.lua
local argNote = nil                                  -- logged once the log is ready
if #args > 1 then
    print(PREFIX .. ' ERROR startup.args_invalid reason="at most one argument: preview or selecttest"')
    return
elseif #args == 1 then   -- exactly one argument
    -- Only preview and selecttest are accepted; live never is.
    local a = tostring(args[1]):lower()
    local requested = config.MODE_ARGS[a]
    if not requested then
        print(('%s ERROR startup.arg_rejected arg=%q allowed="preview, selecttest" note="live is enabled only in config.lua"')   -- explain what is allowed
            :format(PREFIX, a))   -- show the rejected word
        return
    end
    -- Lower or equal is allowed; higher than config.lua is ignored.
    if config.MODE_RANK[requested] <= config.MODE_RANK[mode] then
        mode = requested
    else
        argNote = ('argument %s ignored: cannot raise mode above config (%s)'):format(a, mode)   -- logged as a warning below
    end
end

-- ---------------------------------------------------------------------------
-- 3. Session identity (needed for per-character files)
-- ---------------------------------------------------------------------------

--[[------------------------------------------------------------------------
  read(fn)  (private)

  WHAT  : Calls fn and returns its value, or nil if it raised an error.
  WHY   : A TLO read can fail during zoning; startup must not crash.
  WHERE : The three session reads below.
  HOW   : pcall.
  WHEN  : Startup only.
--------------------------------------------------------------------------]]
local function read(fn) local ok, v = pcall(fn); if ok then return v end end
-- Game state, character name and server name.
local gameState = read(function() return mq.TLO.EverQuest.GameState() end)
local charName  = read(function() return mq.TLO.Me.Name() end)
local server    = read(function() return mq.TLO.EverQuest.Server() end)
-- All three must be known: files are named per server and character.
if gameState ~= 'INGAME' or type(charName) ~= 'string' or charName == ''
    or type(server) ~= 'string' or server == '' then
    print(('%s ERROR startup.not_in_game game_state=%s note="log in to a character first"')
        :format(PREFIX, tostring(gameState)))   -- show the state we saw
    return
end
-- mq.configDir is the MacroQuest config folder.
if type(mq.configDir) ~= 'string' or mq.configDir == '' then
    print(PREFIX .. ' ERROR startup.config_dir_unavailable')
    return
end

-- <config>/Farm_Vendor_<server>_<character>, used for .ini and .log.
local fileBase = ('%s/%s_%s_%s'):format(mq.configDir, config.SCRIPT_NAME,
    store.encodeName(server), store.encodeName(charName))

-- One-time carry-over of selections from the previous package name.
-- The legacy file is only READ; it is never moved, renamed or modified.
local migrationNote = nil                            -- logged once the log is ready
do
    local newIni = fileBase .. '.ini'
    local legacy = config.LEGACY_SCRIPT_NAME
    if legacy ~= '' and legacy ~= config.SCRIPT_NAME then   -- copy is switched on
        local legacyIni = ('%s/%s_%s_%s.ini'):format(mq.configDir, legacy,   -- old file name
            store.encodeName(server), store.encodeName(charName))   -- same server and character parts
        -- Copy only when no new file exists yet.
        local exists = io.open(newIni, 'rb')
        if exists then
            exists:close()                           -- already migrated or new
        else
            local src = io.open(legacyIni, 'rb')
            if src then
                -- Read the old file whole.
                local data = src:read('*a') or ''
                src:close()
                local dst, derr = io.open(newIni, 'wb')
                if dst then   -- new file opened
                    -- Write it under the new name and record the result.
                    local ok = dst:write(data)
                    dst:close()
                    migrationNote = ok and { result = 'copied', from = legacyIni, to = newIni, bytes = #data }
                        or { result = 'write_failed', from = legacyIni, to = newIni }   -- record the failure
                    if not ok then os.remove(newIni) end   -- never leave a partial copy
                else
                    migrationNote = { result = 'open_failed', from = legacyIni, to = newIni, error = tostring(derr) }
                end
            end
        end
    end
end

-- Start logging with the config.lua levels and the per character log file.
log.configure({
    prefix = PREFIX,
    consoleLevel = config.CONSOLE_LOG_LEVEL,
    fileLevel = config.FILE_LOG_LEVEL,   -- file threshold
    filePath = config.FILE_LOG_ENABLED and (fileBase .. '.log') or nil,   -- nil means no file
    maxBytes = config.LOG_MAX_BYTES,
    ringMax = config.UI_LOG_LINES,
})
log.info('startup.begin', { version = config.VERSION, mode = mode, character = charName, server = server })   -- first log line of every session
if argNote then log.warn('startup.arg_ignored', { note = argNote }) end   -- explain an ignored argument
-- Report the one time copy, if it happened.
if migrationNote then
    if migrationNote.result == 'copied' then
        log.info('startup.selections_migrated', migrationNote)
    else
        log.error('startup.selections_migration_failed', migrationNote)   -- copy failed
    end
end

-- ---------------------------------------------------------------------------
-- 4. Application state shared with the UI
-- ---------------------------------------------------------------------------
local app = {
    cfg = config, log = log,                         -- settings and logger
    identity = { name = charName, server = server },
    store = store.new(fileBase .. '.ini', {          -- selections file
        schema = config.INI_SCHEMA, maxBytes = config.INI_MAX_BYTES,
        maxNameLength = config.MAX_ITEM_NAME_LENGTH,
    }),
    seller = sellerMod.new(config, log),             -- worker and probes
    scan = nil,                                      -- latest inventory scan
    checked = {},          -- [id] = true  (working copy; saved explicitly)
    names = {},            -- [id] = name  (for the INI readability section)
    neverSell = {},        -- [id] = true  (1.4.0; saved the moment it changes)
    dirty = false,                                   -- unsaved changes?
    protected = {}, protectedError = nil,            -- protected packs
    readiness = {}, readyToSell = false,             -- readiness results
    proposal = nil, showConfirm = false, focusConfirm = false, confirmNotice = nil,   -- Confirm window
    filter = { search = '', checkedOnly = false, showExcluded = false },              -- table filters
    showMain = true,                                 -- main window visible
    faulted = nil,         -- set on internal error; blocks selling until restart
    running = true,        -- main loop flag
    requests = {},         -- set by UI/binds, consumed by main loop
    logVersionSeen = -1,                             -- Activity Log autoscroll
    lastUiError = nil,                               -- de-duplicates UI errors
}
app.seller.mode = mode                               -- after the argument check

--[[------------------------------------------------------------------------
  app.reportUiError(err)  (public, used by ui.lua)

  WHAT  : Logs a drawing error once per distinct message and faults the
          session, which blocks selling until restart.
  WHY   : A drawing error repeats every frame; logging it once keeps the
          log readable, and a broken UI must not be trusted to confirm.
  WHERE : ui.lua pcall handlers.
  HOW   : Compares with app.lastUiError, logs if new, sets app.faulted.
  WHEN  : Whenever a drawing pcall fails.
--------------------------------------------------------------------------]]
--- UI errors are logged once per distinct message and fault the session.
function app.reportUiError(err)
    local msg = tostring(err)
    if app.lastUiError ~= msg then
        app.lastUiError = msg                        -- remember to avoid repeats
        log.error('ui.render_error', { error = msg })
    end
    app.faulted = 'UI error; restart the script'     -- readiness now blocks selling
end

-- Load selections.
do
    local ok, err = app.store:load()
    for _, w in ipairs(app.store.warnings) do log.warn('store.parse_warning', { detail = w }) end
    if ok then   -- loaded (maybe with warnings)
        -- Copy the saved checks and names into the working tables.
        for id in pairs(app.store.record.selected) do app.checked[id] = true end
        -- Never Sell items (1.4.0). The store already removed them from the checks.
        for id in pairs(app.store.record.neverSell or {}) do app.neverSell[id] = true end
        for id, n in pairs(app.store.record.names) do app.names[id] = n end
        log.info('store.loaded', { status = app.store.status, selected = (function()
            local c = 0; for _ in pairs(app.checked) do c = c + 1 end; return c end)(), path = app.store.path })   -- count of loaded checks
    else
        log.error('store.load_failed', { detail = err, path = app.store.path })   -- saving now disabled
    end
end

--[[------------------------------------------------------------------------
  refreshProtected()  (private)

  WHAT  : Sets app.protected from the INI ProtectedBags line, or the
          config.lua default when the line is empty.
  WHY   : Protected bags are never scanned for sale. A malformed line must
          block selling, not be guessed at.
  WHERE : Once at startup, just below.
  HOW   : store:protectedBags; on error, empty set plus app.protectedError,
          which readiness reports as blocking.
  WHEN  : Startup.
--------------------------------------------------------------------------]]
-- Protected bags (INI override or config default). Malformed => selling blocked.
local function refreshProtected()
    local list, err = app.store:protectedBags(config.DEFAULT_PROTECTED_BAGS)
    if list then
        app.protected, app.protectedError = list, nil    -- valid
    else
        app.protected, app.protectedError = {}, 'INI ProtectedBags: ' .. tostring(err)
        log.error('settings.protected_bags_invalid', { detail = err })
    end
end
refreshProtected()                                   -- run it now

-- ---------------------------------------------------------------------------
-- 5. Actions (main loop only)
-- ---------------------------------------------------------------------------

--[[------------------------------------------------------------------------
  rescan(reason)  (private)

  WHAT  : Reads the bags again into app.scan. Returns true on success.
  WHY   : The table, the proposal and the confirm comparison all need a
          fresh, read only picture of the bags.
  WHERE : Startup, Refresh Inventory, merchant open or close, prepare,
          confirm, and after each run.
  HOW   : pcall(inventory.scan). A failure faults the session. Names of
          checked items are refreshed for the INI.
  WHEN  : Main loop only, never inside a frame.
--------------------------------------------------------------------------]]
local function rescan(reason)
    local ok, result = pcall(inventory.scan, config, app.protectedError and {} or app.protected)
    if not ok then
        log.error('inventory.scan_failed', { error = result })   -- record why
        app.faulted = 'Inventory scan failed; see log'   -- blocks selling
        return false
    end
    -- If protected bags are invalid we still list items for viewing, but
    -- readiness blocks selling (protectedError is set).
    app.scan = result
    local eligible = 0                                   -- rows with a sellable stack
    for _, r in ipairs(result.rows) do if r.eligible then eligible = eligible + 1 end end
    for _, r in ipairs(result.rows) do if app.checked[r.id] or app.neverSell[r.id] then app.names[r.id] = r.name end end
    log.info('inventory.scanned', { reason = reason, rows = #result.rows, eligible = eligible,
        protected_hidden = result.protectedCount })   -- items hidden in protected bags
    return true   -- scan succeeded
end

--[[------------------------------------------------------------------------
  save(reason)  (private)

  WHAT  : Writes the checked items to the INI. Returns true on success.
  WHY   : Confirm Sale must save first; if saving fails nothing is sold.
  WHERE : Save Selections (reason operator) and confirm (reason confirm).
  HOW   : store:setSelections then store:save (atomic and verified).
          Clears app.dirty only on success.
  WHEN  : Main loop only.
--------------------------------------------------------------------------]]
local function save(reason)
    app.store:setSelections(app.checked, app.names)
    local ok, err = app.store:save()
    if ok then   -- verified save
        app.dirty = false                                -- nothing unsaved now
        log.info('store.saved', { reason = reason, path = app.store.path, count = app.store.saveCount })
    else
        log.error('store.save_failed', { reason = reason, detail = err })
    end
    return ok   -- caller decides what to do on failure
end

--[[------------------------------------------------------------------------
  saveNeverSell()  (private, 1.4.0)

  WHAT  : Writes the Never Sell set to the INI at once. Returns true on
          success.
  WHY   : Never Sell is a standing protection, so it must survive a Cancel
          or a crash without the player pressing Save Selections. Unsaved
          Sell checks are not written by this save; they still wait for
          Save Selections or Confirm Sale.
  WHERE : Main loop, when app.requests.saveNeverSell is set by a Never Sell
          checkbox click in ui.lua.
  HOW   : store:setNeverSell then store:save (atomic and verified). On
          failure (for example a read only file) the protection still
          applies for this session because app.neverSell is in memory;
          the failure is logged.
  WHEN  : Main loop only, on the pass after the click.
--------------------------------------------------------------------------]]
local function saveNeverSell()
    app.store:setNeverSell(app.neverSell, app.names)
    local ok, err = app.store:save()
    local count = 0                                      -- how many are protected
    for _ in pairs(app.neverSell) do count = count + 1 end
    if ok then   -- verified save
        log.info('neversell.saved', { count = count, path = app.store.path })
    else
        log.error('neversell.save_failed', { detail = err, note = 'still enforced for this session' })
    end
    return ok   -- logged either way
end

--[[------------------------------------------------------------------------
  updateReadiness()  (private)

  WHAT  : Re-runs every readiness check into app.readiness and
          app.readyToSell.
  WHY   : Conditions change (merchant closes, cursor item, macro starts);
          the Sell button and Confirm must reflect them.
  WHERE : Every loop, and at the start of prepare and confirm.
  HOW   : seller:readiness with the store, protected bag and fault state.
  WHEN  : Main loop only.
--------------------------------------------------------------------------]]
local function updateReadiness()
    app.readiness, app.readyToSell = app.seller:readiness({
        storeReadonly = app.store.readonly, storeDetail = app.store.statusDetail,
        protectedError = app.protectedError, faulted = app.faulted,   -- blocking inputs from init state
    })
end

--[[------------------------------------------------------------------------
  prepare()  (private)

  WHAT  : Builds the sale proposal and opens the Confirm window.
  WHY   : Sell All Checked Items never sells; it shows exactly what would
          be processed first.
  WHERE : Main loop, when app.requests.prepare is set.
  HOW   : Readiness, then a fresh scan, then seller:buildProposal. Nothing
          eligible means a warning and no window.
  WHEN  : After the player presses Sell All Checked Items.
--------------------------------------------------------------------------]]
local function prepare()
    updateReadiness()
    if not app.readyToSell then log.warn('sale.prepare_blocked', {}); return end   -- a check failed
    if not rescan('prepare') then return end
    local p = app.seller:buildProposal(app.scan, app.checked, app.neverSell)   -- Never Sell left out
    if p.totalStacks == 0 then
        log.warn('sale.nothing_eligible', { note = 'no checked item has an eligible stack' })   -- nothing to show
        return
    end
    -- Show the Confirm window with focus.
    app.proposal, app.showConfirm, app.focusConfirm, app.confirmNotice = p, true, true, nil
    log.info('sale.proposed', { types = #p.items, stacks = p.totalStacks, qty = p.totalQty, mode = p.mode })
end

--[[------------------------------------------------------------------------
  confirm()  (private)

  WHAT  : Carries out a confirmed proposal.
  WHY   : The player approved a specific list; only that exact list may be
          processed, and only after the selections are safely saved.
  WHERE : Main loop, when app.requests.confirm is set.
  HOW   : 1. Readiness must pass.
          2. Re-scan and rebuild; if the fingerprint changed, show the new
             list and require another confirm.
          3. Save; on failure sell nothing.
          4. Run the worker inside xpcall; an error faults the session.
          5. Clear the proposal and re-scan.
  WHEN  : After the player presses Confirm Sale.
--------------------------------------------------------------------------]]
local function confirm()
    local old = app.proposal
    if not old then return end                           -- nothing to confirm
    updateReadiness()
    if not app.readyToSell then
        app.confirmNotice = 'Blocked: a readiness check failed. Fix it, then confirm again.'
        log.warn('sale.confirm_blocked', {})   -- logged; window stays open
        return
    end
    -- Re-scan and compare: a changed inventory requires a new confirmation.
    if not rescan('confirm') then return end
    local fresh = app.seller:buildProposal(app.scan, app.checked, app.neverSell)   -- Never Sell left out
    if fresh.fingerprint ~= old.fingerprint then
        app.proposal = fresh                             -- show the new list
        app.confirmNotice = 'Inventory changed since this list was prepared. Review the updated list and confirm again.'
        log.warn('sale.proposal_changed', { stacks = fresh.totalStacks, qty = fresh.totalQty })
        if fresh.totalStacks == 0 then app.showConfirm, app.proposal = false, nil end   -- nothing left
        return
    end
    -- Approved selections must persist before any action.
    if not save('confirm') then
        app.confirmNotice = 'Saving selections failed, so nothing was sold. See Activity Log.'
        return
    end
    app.showConfirm = false                              -- close the window
    -- Run the worker; any error is caught and the session faulted.
    local ok, result = xpcall(function() return app.seller:run(old) end, debug.traceback)
    if not ok then
        app.seller.running, app.seller.stopRequested = false, false
        app.faulted = 'Selling worker error; restart the script'   -- blocks selling until restart
        log.error('run.internal_error', { error = result })   -- record the traceback
    end
    app.proposal = nil                                   -- done with this list
    rescan('after_run')                                  -- show what is left
end

-- ---------------------------------------------------------------------------
-- 6. Command binding (documented mq.bind) - only sets flags
-- ---------------------------------------------------------------------------

--[[------------------------------------------------------------------------
  onBind(...)  (private)

  WHAT  : Handles /fvendor stop, /fvendor quit and /fvendor show.
  WHY   : A typed command to pause selling or exit, even if the window is
          hidden.
  WHERE : Registered with mq.bind(config.BIND_COMMAND, onBind).
  HOW   : stop: request a stop if running. quit: request a stop if running,
          then ask the main loop to exit. show: show the main window.
          Anything else prints usage. Only flags are set here.
  WHEN  : Whenever the player types the command.
--------------------------------------------------------------------------]]
local function onBind(...)
    local sub = (select(1, ...) or ''):lower()           -- first word, lower case
    if sub == 'stop' then
        if app.seller.running then app.seller:requestStop() else log.info('bind.stop_idle', {}) end
    elseif sub == 'quit' then
        if app.seller.running then app.seller:requestStop() end   -- stop first
        app.requests.quit = true                         -- exit once stopped
    elseif sub == 'show' then
        app.showMain = true                              -- reopen the window
    else
        print(('%s usage: %s stop | quit | show'):format(PREFIX, config.BIND_COMMAND))
    end
end
mq.bind(config.BIND_COMMAND, onBind)                     -- /fvendor
app.seller:registerEvents()                              -- merchant quote and refusal lines

-- ---------------------------------------------------------------------------
-- 7. UI registration and main loop
-- ---------------------------------------------------------------------------
mq.imgui.init(config.SCRIPT_NAME, function() ui.render(app) end)   -- draw every frame

-- First scan and readiness before the loop starts.
rescan('startup')
updateReadiness()
local lastMerchantOpen = app.scan and app.scan.merchantOpen        -- for open/close detection
log.info('startup.ready', { mode = mode, file = app.store.path })

-- Main loop: take the requests the UI and binds set, act, then wait.
while app.running do
    local ok, err = xpcall(function()
        local r = app.requests
        app.requests = {}                                -- take this frame's requests
        if r.quit and not app.seller.running then
            app.running = false                          -- leave the loop
            return
        end
        if r.rescan then rescan('operator') end          -- Refresh Inventory
        -- Prices and "Merchant offers no price" exclusions depend on the open
        -- merchant, so re-scan whenever the merchant window opens or closes.
        local mo = app.seller.probe.merchantOpen() == true
        if mo ~= lastMerchantOpen and not r.rescan then rescan(mo and 'merchant_opened' or 'merchant_closed') end
        lastMerchantOpen = mo
        -- Discard merchant chat lines that arrive while idle; each selection
        -- also flushes before it starts, so only fresh lines are ever counted.
        app.seller:flushMerchantEvents()
        if r.saveNeverSell then saveNeverSell() end      -- a Never Sell box changed (1.4.0)
        if r.save then save('operator') end              -- Save Selections
        if r.cancelConfirm then
            -- Cancel or X on the Confirm window: nothing is sold.
            app.showConfirm, app.proposal, app.confirmNotice = false, nil, nil
            log.info('sale.cancelled', { note = 'confirmation cancelled; nothing sold' })
        end
        if r.prepare then prepare() end                  -- Sell All Checked Items
        if r.confirm then confirm() end                  -- Confirm Sale
        updateReadiness()                                -- keep the UI current
    end, debug.traceback)
    if not ok then
        app.faulted = 'Internal error; restart the script'   -- blocks selling
        log.error('loop.internal_error', { error = err })
    end
    if app.running then mq.delay(config.LOOP_DELAY_MS) end   -- yield to the game
end

-- ---------------------------------------------------------------------------
-- 8. Shutdown (unsaved changes are intentionally discarded: Cancel = no action)
-- ---------------------------------------------------------------------------
if app.dirty then log.info('shutdown.discarded_unsaved', { note = 'Cancel exits without saving' }) end
mq.unbind(config.BIND_COMMAND)                           -- remove /fvendor
app.seller:unregisterEvents()                            -- remove chat events
mq.imgui.destroy(config.SCRIPT_NAME)                     -- remove the window
log.info('shutdown.complete', {})

--[[==========================================================================
  END OF FILE : Farm_Vendor/init.lua

  PUBLIC  app.reportUiError(err) (used by ui.lua). Everything else is
          private to this file.

  DEPENDENCIES : mq (MacroQuest), Farm_Vendor.config, Farm_Vendor.core,
                 Farm_Vendor.engine, Farm_Vendor.ui.

  HOW TO EDIT SAFELY
    - New buttons: set a flag in app.requests in ui.lua and handle it in
      the main loop here, never inside the frame.
    - Anything that can sell must go through prepare and confirm so the
      player sees the list and the save happens first.
    - Keep the launch argument rule: an argument may only lower the mode.
    - Run dev/doc_audit.py and dev/run_tests.py after editing, then repeat
      the TESTING.md stages in preview and select_test before live.
==========================================================================]]--
