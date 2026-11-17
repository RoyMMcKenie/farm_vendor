--[[==========================================================================
  FILE        : Farm_Vendor/ui.lua
  PACKAGE     : Farm Vendor  (MacroQuest Lua / EverQuest)
  VERSION     : 1.4.0
  CHANGES     : 1.4.0  Never Sell column: a per item checkbox that blocks
                       the Sell checkbox, removes an existing check, and is
                       saved at once (request saveNeverSell). Only a manual
                       untick removes it. Select All button checks every
                       listed, eligible item that is not Never Sell. Clear
                       Checks and Select All never change Never Sell.
                1.3.0  Loads the inventory helpers from Farm_Vendor.engine
                       (inventory now lives there). No drawing or behaviour
                       change. Header, footer, function documentation and
                       line comments brought to the project standard.
                1.2.2  No change.
                1.2.1  ImGui loaded with require('ImGui'); flags combined
                       with bit32.bor (LuaJIT bit as fallback); every
                       Begin/End and Push/Pop pair kept balanced even when
                       drawing raises an error.
                1.2.0  Renamed from magfarm_vendor; ImGui IDs use fv_.
                1.1.1  No change.
                1.1.0  Selection test report mentions the merchant quote;
                       estimate notes unpriced item types.
                1.0.0  First release.

  CREDITS     : Original to Farm Vendor. Workflow from Sellitem.mac by
                Cannonballdex and AutoVendor 3.6 by Ionis (no code copied;
                links in README.md, Credits).

  WHAT  : The two ImGui windows.
            Main window     Character and merchant status, readiness line,
                            search and filters, the item checklist with Sell
                            and Never Sell columns, buttons (Select All,
                            Clear Checks, Save Selections, Sell All
                            Checked Items, Cancel), progress with the Stop
                            Selling button, the last run report, and the
                            Activity Log.
            Confirm window  Opens after Sell All Checked Items. Lists
                            exactly what will be processed, with Confirm
                            Sale and Cancel.

  WHY   : The player must see and approve every sale. Keeping all drawing
          here, and all game actions in init.lua and engine.lua, means a
          drawing bug can never sell anything.

  WHERE : <MacroQuest>/lua/Farm_Vendor/ui.lua
          init.lua registers ui.render with mq.imgui.init. ui.available
          tells init.lua whether the ImGui bindings loaded.

  HOW   : Rules every function here follows
            * The UI never issues game commands and never calls mq.delay.
              Buttons only set flags in app.requests; the init.lua main loop
              does the work (mq.delay cannot run inside an ImGui callback).
            * Every Begin, BeginChild, BeginTable, BeginTooltip, PushID,
              PushStyleColor and BeginDisabled is matched by its End or Pop
              even if drawing fails: each paired region's body runs inside
              pcall, so an error is logged (UI error) instead of leaving
              the ImGui stack unbalanced.
            * Text that may contain % (paths, item names, log lines) is
              drawn with TextUnformatted so it is never a format string.
            * Status rows always draw (reserved space) so buttons do not
              jump when a message appears or goes away.
          Every ImGui call and enum is in mq-definitions (AUDIT.md).

  WHEN  : ui.render runs every frame while the script is running.
==========================================================================]]--

-- Coin formatting lives in the inventory section of engine.lua.
local inventory = require('Farm_Vendor.engine').inventory

-- The module table returned at the bottom of this file.
local ui = {}

-- ImGui bindings: require('ImGui') is the documented form (mq-definitions,
-- RedGuides "MQ VS Code Lua Autocomplete Definition Library"). Loaded with
-- pcall so a missing binding is reported at startup instead of crashing.
local okImGui, ImGui = pcall(require, 'ImGui')
if not okImGui or type(ImGui) ~= 'table' then ImGui = rawget(_G, 'ImGui') end   -- older global form
ui.available = type(ImGui) == 'table'                      -- init.lua refuses to start if false

-- Bit operations for combining ImGui flags: bit32 is documented by
-- mq-definitions (_Bit32.lua). LuaJIT's built-in 'bit' (MQ2Lua runs on LuaJIT
-- 2.1) provides the same bor and is used only if bit32 is absent.
local bit32 = rawget(_G, 'bit32') or require('bit')

-- Text colours as red, green, blue, alpha from 0 to 1.
local COLOR = {
    ok    = { 0.35, 0.85, 0.35, 1.0 },   -- green: good
    warn  = { 0.95, 0.80, 0.25, 1.0 },   -- yellow: attention
    bad   = { 0.95, 0.35, 0.35, 1.0 },   -- red: blocked or failed
    dim   = { 0.65, 0.65, 0.65, 1.0 },   -- grey: information
    live  = { 1.00, 0.45, 0.20, 1.0 },   -- orange: live selling
}

--[[------------------------------------------------------------------------
  colored(c, text)  (private)

  WHAT  : Draws one line of text in colour c.
  WHY   : Status lines are coloured so problems stand out.
  WHERE : Almost every draw function below.
  HOW   : PushStyleColor, TextUnformatted inside pcall, PopStyleColor, then
          rethrow any error so the caller's pcall logs it.
  WHEN  : Every frame, for every coloured line.
--------------------------------------------------------------------------]]
local function colored(c, text)
    ImGui.PushStyleColor(ImGuiCol.Text, c[1], c[2], c[3], c[4])
    local ok, err = pcall(ImGui.TextUnformatted, tostring(text))
    ImGui.PopStyleColor(1)                  -- always paired with the Push above
    if not ok then error(err, 0) end        -- pass the error to the caller
end

--[[------------------------------------------------------------------------
  tooltip(text)  (private)

  WHAT  : Shows text in a tooltip when the mouse is over the last item.
  WHY   : Explains buttons and columns without crowding the window.
  WHERE : After buttons, item names, prices and flags.
  HOW   : IsItemHovered, then BeginTooltip, TextUnformatted in pcall,
          EndTooltip, rethrow any error.
  WHEN  : Every frame, right after the item it describes.
--------------------------------------------------------------------------]]
local function tooltip(text)
    if ImGui.IsItemHovered() then
        ImGui.BeginTooltip()
        local ok, err = pcall(ImGui.TextUnformatted, tostring(text))   -- draw safely, then close
        ImGui.EndTooltip()                  -- always paired with BeginTooltip
        if not ok then error(err, 0) end    -- pass the error to the caller
    end
end

--[[------------------------------------------------------------------------
  modeLabel(mode)  (private)

  WHAT  : Returns the display text and colour for a sell mode.
  WHY   : The player must always see whether clicks will really sell.
  WHERE : drawHeader and drawConfirm.
  HOW   : live is orange, select_test yellow, preview green.
  WHEN  : Every frame.
--------------------------------------------------------------------------]]
local function modeLabel(mode)
    if mode == 'live' then return 'LIVE SELLING', COLOR.live end                   -- really sells
    if mode == 'select_test' then return 'SELECTION TEST (no sales)', COLOR.warn end   -- clicks, no sale
    return 'PREVIEW (no game commands)', COLOR.ok                                    -- read only
end

--[[------------------------------------------------------------------------
  coin(c)  (private)

  WHAT  : Short name for inventory.formatCoin.
  WHY   : Coin is drawn in many places; this keeps the lines short.
  WHERE : drawTable, drawProgress, drawConfirm.
  HOW   : Calls inventory.formatCoin.
  WHEN  : Whenever a price or total is drawn.
--------------------------------------------------------------------------]]
local function coin(c) return inventory.formatCoin(c) end

-- ---------------------------------------------------------------------------
-- Main window sections
-- ---------------------------------------------------------------------------

--[[------------------------------------------------------------------------
  drawHeader(app)  (private)

  WHAT  : Character, server, mode, merchant status and selections file
          status, plus an Unsaved changes marker.
  WHY   : Shows at a glance who, where, which mode, and whether checks are
          saved.
  WHERE : Top of the main window (ui.render).
  HOW   : Reads app.identity, app.seller.mode, the merchant probe and
          app.store; the file path is in a tooltip.
  WHEN  : Every frame.
--------------------------------------------------------------------------]]
local function drawHeader(app)
    local label, col = modeLabel(app.seller.mode)
    ImGui.TextUnformatted(('Character: %s   Server: %s'):format(app.identity.name, app.identity.server))
    ImGui.TextUnformatted('Mode: '); ImGui.SameLine(); colored(col, label)   -- mode on the same line

    -- Merchant: open (with name), closed, or unknown.
    local open = app.seller.probe.merchantOpen()
    ImGui.TextUnformatted('Merchant: '); ImGui.SameLine()
    if open == true then
        colored(COLOR.ok, 'Open - ' .. (app.seller.probe.merchantName() or 'unknown name'))   -- green with merchant name
    elseif open == false then   -- reading says closed
        colored(COLOR.dim, 'Closed (open one yourself before selling)')   -- grey hint
    else
        colored(COLOR.bad, 'Unknown')   -- reading failed
    end

    -- Selections file: red when it cannot be saved, yellow with warnings.
    local st = app.store
    local stCol = (st.status == 'failed' or st.status == 'readonly') and COLOR.bad
        or (st.status == 'loaded_with_warnings' and COLOR.warn or COLOR.dim)
    ImGui.TextUnformatted('Selections file: '); ImGui.SameLine()   -- label, then status on the same line
    colored(stCol, ('%s - %s'):format(st.status, st.statusDetail))   -- status and detail
    tooltip(st.path)                                         -- full file path
    ImGui.SameLine()
    if app.dirty then colored(COLOR.warn, '  [Unsaved changes]') else colored(COLOR.dim, '  [No unsaved changes]') end
end

--[[------------------------------------------------------------------------
  drawReadiness(app)  (private)

  WHAT  : One summary line (all passed, or how many block selling), a
          tooltip listing every check, and a reserved line naming the first
          blocking check.
  WHY   : Sell All Checked Items is disabled while anything blocks it; the
          player needs to know why.
  WHERE : Under the header (ui.render).
  HOW   : Reads app.readiness, built by seller:readiness in init.lua.
  WHEN  : Every frame.
--------------------------------------------------------------------------]]
local function drawReadiness(app)
    local checks = app.readiness or {}
    local blocked = {}                                       -- failed checks only
    for _, c in ipairs(checks) do if not c.ok then blocked[#blocked + 1] = c end end
    if #blocked == 0 then
        colored(COLOR.ok, 'Readiness: all checks passed')
    else
        colored(COLOR.bad, ('Readiness: %d check(s) blocking selling'):format(#blocked))   -- count of blockers
    end
    -- Hover: every check with OK or BLOCKED and its detail.
    if ImGui.IsItemHovered() then
        ImGui.BeginTooltip()
        local ok, err = pcall(function()
            for _, c in ipairs(checks) do   -- every check, passed or not
                colored(c.ok and COLOR.ok or COLOR.bad, ('[%s] %s - %s'):format(c.ok and 'OK' or 'BLOCKED',   -- one coloured line per check
                    tostring(c.name), tostring(c.detail)))   -- check name and detail
            end
        end)
        ImGui.EndTooltip()                   -- always paired with BeginTooltip
        if not ok then error(err, 0) end     -- pass the error to the caller
    end
    -- Reserved line: always drawn so layout does not shift.
    if #blocked > 0 then
        colored(COLOR.bad, ('%s: %s'):format(blocked[1].name, blocked[1].detail))
    else
        colored(COLOR.dim, ' ')              -- blank placeholder
    end
end

--[[------------------------------------------------------------------------
  drawFilters(app)  (private)

  WHAT  : Search box, Checked only and Show excluded checkboxes, and the
          Refresh Inventory button.
  WHY   : Long inventories need narrowing down; Refresh reads bags again
          after the player moves things.
  WHERE : Above the table (ui.render).
  HOW   : Changes app.filter directly (display only). Refresh sets
          app.requests.rescan for the main loop. Search text is cleaned of
          control characters and capped at SEARCH_MAX_LENGTH.
  WHEN  : Every frame.
--------------------------------------------------------------------------]]
local function drawFilters(app)
    ImGui.SetNextItemWidth(260)                              -- search box width
    local text, changed = ImGui.InputText('Search##fv_search', app.filter.search)
    if changed and type(text) == 'string' then
        -- Input validation: strip control characters and cap length.
        app.filter.search = text:gsub('%c', ''):sub(1, app.cfg.SEARCH_MAX_LENGTH)
    end
    ImGui.SameLine()
    local v, p = ImGui.Checkbox('Checked only##fv_checked', app.filter.checkedOnly)   -- Checked only filter
    if p then app.filter.checkedOnly = v end                 -- only rows you checked
    ImGui.SameLine()
    v, p = ImGui.Checkbox('Show excluded##fv_excl', app.filter.showExcluded)
    if p then app.filter.showExcluded = v end                -- include rows that cannot be sold
    ImGui.SameLine()
    ImGui.BeginDisabled(app.seller.running)                  -- no rescans mid run
    if ImGui.Button('Refresh Inventory##fv_refresh') then app.requests.rescan = true end
    ImGui.EndDisabled()                                      -- pairs with BeginDisabled
end

--[[------------------------------------------------------------------------
  rowVisible(app, row)  (private)

  WHAT  : True when a row passes the current filters.
  WHY   : Keeps the filter rules in one place.
  WHERE : drawTable.
  HOW   : Hides excluded rows unless Show excluded, unchecked rows when
          Checked only, and rows whose name does not contain the search
          text (plain, case insensitive find).
  WHEN  : Every frame, once per row.
--------------------------------------------------------------------------]]
local function rowVisible(app, row)
    if not row.eligible and not app.filter.showExcluded then return false end   -- excluded hidden
    if app.filter.checkedOnly and not app.checked[row.id] then return false end -- unchecked hidden
    local s = app.filter.search
    if s ~= '' and not row.name:lower():find(s:lower(), 1, true) then return false end   -- plain find, no patterns
    return true
end

--[[------------------------------------------------------------------------
  drawTable(app)  (private)

  WHAT  : The item checklist: Sell checkbox, Never Sell checkbox, Item,
          Qty, Stacks, Est. each, Flags and Notes columns.
  WHY   : This is where the player chooses what to sell, and what must
          never be sold. Checks are kept in app.checked and saved only on
          Save Selections or Confirm Sale. Never Sell is kept in
          app.neverSell and saved the moment it changes, because it is a
          standing protection that must survive Cancel.
  WHERE : Middle of the main window (ui.render).
  HOW   : One table row per visible scan row, each inside PushID(row.id)
          so checkbox IDs are unique. The Sell checkbox is disabled for
          rows with no eligible stack, for Never Sell rows and during a
          run. The Never Sell checkbox is disabled only during a run; it is
          the only way to set or remove Never Sell. Ticking it unticks the
          Sell box. Height leaves room for the buttons, progress and log.
  WHEN  : Every frame after the first scan.
--------------------------------------------------------------------------]]
local function drawTable(app)
    local scan = app.scan
    if not scan then colored(COLOR.dim, 'Scanning inventory...'); return end   -- before the first scan
    -- Striped rows, borders, scrolling, resizable stretch columns.
    local flags = bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.Borders,
        ImGuiTableFlags.ScrollY, ImGuiTableFlags.Resizable, ImGuiTableFlags.SizingStretchProp)
    local _, availY = ImGui.GetContentRegionAvail()
    local reserved = app.cfg.ACTIVITY_LOG_HEIGHT + 190      -- room for buttons, progress, log
    local height = math.max(120, (availY or 400) - reserved)
    if ImGui.BeginTable('##fv_items', 8, flags, 0, height) then
        local ok, err = pcall(function()
            -- Header row stays visible while scrolling.
            ImGui.TableSetupScrollFreeze(0, 1)
            ImGui.TableSetupColumn('Sell', ImGuiTableColumnFlags.WidthFixed, 36)
            ImGui.TableSetupColumn('Never Sell', ImGuiTableColumnFlags.WidthFixed, 70)   -- 1.4.0
            ImGui.TableSetupColumn('Item', ImGuiTableColumnFlags.WidthStretch, 3)
            -- (columns continued)
            ImGui.TableSetupColumn('Qty', ImGuiTableColumnFlags.WidthFixed, 50)
            ImGui.TableSetupColumn('Stacks', ImGuiTableColumnFlags.WidthFixed, 50)
            ImGui.TableSetupColumn('Est. each', ImGuiTableColumnFlags.WidthFixed, 90)
            -- (columns continued)
            ImGui.TableSetupColumn('Flags', ImGuiTableColumnFlags.WidthFixed, 45)
            ImGui.TableSetupColumn('Notes', ImGuiTableColumnFlags.WidthStretch, 2)
            ImGui.TableHeadersRow()
            local merchantOpen = app.seller.probe.merchantOpen() == true   -- prices only with a merchant
            for _, row in ipairs(scan.rows) do
                if rowVisible(app, row) then
                    ImGui.PushID(row.id)             -- unique widget IDs per row
                    local rowOk, rowErr = pcall(function()
                    ImGui.TableNextRow()
                    -- Sell checkbox.
                    ImGui.TableNextColumn()
                    local never = app.neverSell[row.id] == true   -- Never Sell blocks the Sell box
                    ImGui.BeginDisabled(app.seller.running or not row.eligible or never)
                    local val, pressed = ImGui.Checkbox('##sell', app.checked[row.id] == true)
                    ImGui.EndDisabled()              -- pairs with BeginDisabled
                    -- Record a click; re-checked here as well as by BeginDisabled.
                    if pressed and row.eligible and not never and not app.seller.running then
                        app.checked[row.id] = val or nil
                        app.names[row.id] = row.name     -- for [ItemNames] in the INI
                        app.dirty = true                 -- shows Unsaved changes
                    end
                    -- Never Sell checkbox (1.4.0): only a manual click sets or removes it.
                    ImGui.TableNextColumn()
                    ImGui.BeginDisabled(app.seller.running)   -- no changes mid run
                    local nval, npressed = ImGui.Checkbox('##never', never)
                    ImGui.EndDisabled()              -- pairs with BeginDisabled
                    tooltip('Never Sell: this item can never be checked or sold until you untick this box. Saved at once.')   -- explain the column
                    if npressed and not app.seller.running then
                        if nval then   -- ticked: protect it
                            app.neverSell[row.id] = true
                            if app.checked[row.id] then app.checked[row.id] = nil; app.dirty = true end   -- drop any check
                        else   -- unticked by hand: the only way to remove it
                            app.neverSell[row.id] = nil
                        end
                        app.names[row.id] = row.name     -- for [ItemNames] in the INI
                        app.requests.saveNeverSell = true   -- main loop saves it now
                    end
                    -- Item name, with its ID on hover.
                    ImGui.TableNextColumn(); ImGui.TextUnformatted(row.name)
                    tooltip(('Item ID %d'):format(row.id))
                    ImGui.TableNextColumn(); ImGui.TextUnformatted(tostring(row.qty))      -- Qty
                    ImGui.TableNextColumn(); ImGui.TextUnformatted(tostring(row.stacks))   -- Stacks
                    -- Est. each: merchant price, only while a merchant is open.
                    ImGui.TableNextColumn()
                    if merchantOpen and type(row.sellPrice) == 'number' and row.sellPrice > 0 then
                        ImGui.TextUnformatted(coin(row.sellPrice))
                        tooltip('Merchant SellPrice estimate. Actual coin is measured after the run.')   -- explain it is an estimate
                    else
                        colored(COLOR.dim, 'Unavailable')   -- no merchant open
                        tooltip('Shown only while a merchant is open (Item.SellPrice).')   -- explain when it shows
                    end
                    -- Flags: ND for NO DROP, L for Lore.
                    ImGui.TableNextColumn()
                    local f = (row.noDrop and 'ND ' or '') .. (row.lore and 'L' or '')
                    ImGui.TextUnformatted(f)
                    if f ~= '' then tooltip('ND = NO DROP / NO TRADE, L = Lore') end   -- explain the letters
                    -- Notes: why a row, or some of its stacks, cannot be sold.
                    ImGui.TableNextColumn()
                    if never then   -- protection note comes first
                        colored(COLOR.ok, 'Never Sell')
                    elseif not row.eligible then
                        colored(COLOR.dim, 'Excluded: ' .. row.reasonText)
                    elseif row.reasonText ~= '' then   -- some stacks excluded
                        colored(COLOR.warn, ('%d of %d stacks eligible (%s)'):format(row.eligibleStacks, row.stacks, row.reasonText))   -- e.g. 2 of 3 stacks eligible
                    else
                        ImGui.TextUnformatted(' ')       -- nothing to note
                    end
                    end)
                    ImGui.PopID()                    -- always paired with PushID
                    if not rowOk then error(rowErr, 0) end   -- pass to the table pcall
                end
            end
        end)
        ImGui.EndTable()                             -- always paired with BeginTable
        if not ok then app.reportUiError(err) end    -- log and fault the session
    end
end

--[[------------------------------------------------------------------------
  selectionSummary(app)  (private)

  WHAT  : Returns how many checked item types are carried and eligible,
          their total eligible quantity, how many remembered checks are
          not currently carried, and how many items are Never Sell.
  WHY   : Feeds the Selected line and enables Sell All Checked Items only
          when there is something to sell.
  WHERE : drawButtons.
  HOW   : Looks each checked ID up in app.scan.rowsById, skipping Never
          Sell IDs, then counts app.neverSell.
  WHEN  : Every frame.
--------------------------------------------------------------------------]]
local function selectionSummary(app)
    local types, qty, missing, never = 0, 0, 0, 0
    for _ in pairs(app.neverSell) do never = never + 1 end   -- protected items (1.4.0)
    -- Count every remembered check against the current scan.
    for id in pairs(app.checked) do
        local row = app.scan and app.scan.rowsById[id]
        if app.neverSell[id] then
            -- Never Sell wins; such a check cannot be sold, so it is not counted.
        elseif row and row.eligible then
            types = types + 1; qty = qty + row.eligibleQty   -- carried and sellable
        else
            missing = missing + 1                            -- remembered, not carried
        end
    end
    return types, qty, missing, never
end

--[[------------------------------------------------------------------------
  drawButtons(app)  (private)

  WHAT  : The Selected summary line and the Select All, Clear Checks,
          Save Selections, Sell All Checked Items and Cancel buttons.
  WHY   : These are the player's actions. None of them sells directly:
          Sell All Checked Items only opens the Confirm window.
  WHERE : Under the table (ui.render).
  HOW   : Select All ticks every row the filters currently show that has
          an eligible stack and is not Never Sell (1.4.0). Clear Checks
          unticks listed rows only. Neither touches app.neverSell. Save,
          Sell and Cancel set app.requests flags for the main loop.
          Everything is disabled during a run.
  WHEN  : Every frame.
--------------------------------------------------------------------------]]
local function drawButtons(app)
    local types, qty, missing, never = selectionSummary(app)
    ImGui.TextUnformatted(('Selected: %d item type(s) / %d item(s) carried'):format(types, qty))
    if missing > 0 then   -- checks for items not in bags
        ImGui.SameLine()   -- same line
        colored(COLOR.dim, ('  (%d remembered item(s) not currently carried)'):format(missing))   -- grey note
    end
    if never > 0 then   -- Never Sell count (1.4.0)
        ImGui.SameLine()
        colored(COLOR.dim, ('  %d Never Sell item(s)'):format(never))
    end
    -- Count of items hidden because they are in a protected bag.
    if app.scan and app.scan.protectedCount > 0 then
        ImGui.SameLine()
        colored(COLOR.dim, ('  %d item(s) hidden in protected bags'):format(app.scan.protectedCount))
    end

    local running = app.seller.running   -- true while the worker runs
    ImGui.BeginDisabled(running)                             -- no changes mid run
    local ok, err = pcall(function()
    if ImGui.Button('Select All##fv_select_all') then
        -- Ticks listed, sellable rows only. Never Sell rows are skipped and keep Never Sell.
        for _, row in ipairs(app.scan and app.scan.rows or {}) do
            if rowVisible(app, row) and row.eligible and not app.neverSell[row.id] and not app.checked[row.id] then
                app.checked[row.id] = true
                app.names[row.id] = row.name     -- for [ItemNames] in the INI
                app.dirty = true                 -- shows Unsaved changes
            end
        end
    end
    tooltip('Checks every listed item that can be sold. Never Sell items are skipped and stay Never Sell.')   -- explain Select All
    ImGui.SameLine()   -- next button on the same line
    if ImGui.Button('Clear Checks##fv_clear') then
        -- Clears only currently listed items; remembered items not carried stay remembered.
        for _, row in ipairs(app.scan and app.scan.rows or {}) do
            if app.checked[row.id] then app.checked[row.id] = nil; app.dirty = true end
        end
    end
    tooltip('Unchecks listed items. Remembered items you are not carrying are kept. Never Sell is not changed.')   -- explain Clear Checks
    ImGui.SameLine()   -- next button on the same line
    -- Save only when there is something to save and the file is writable.
    ImGui.BeginDisabled(app.store.readonly or not app.dirty)
    local save = ImGui.Button('Save Selections##fv_save')
    ImGui.EndDisabled()                                      -- pairs with BeginDisabled
    if save then app.requests.save = true end
    ImGui.SameLine()
    -- Sell needs at least one checked item and all readiness checks passed.
    ImGui.BeginDisabled(types == 0 or not app.readyToSell)
    local sell = ImGui.Button('Sell All Checked Items##fv_sell')
    ImGui.EndDisabled()                                      -- pairs with BeginDisabled
    if sell then app.requests.prepare = true end             -- opens the Confirm window
    if types == 0 then tooltip('Check at least one item first.')
    elseif not app.readyToSell then tooltip('Blocked: hover the Readiness line for details.') end
    ImGui.SameLine()
    if ImGui.Button('Cancel##fv_cancel') then app.requests.quit = true end   -- exit, no action
    tooltip('Exit with no action. Unsaved checkbox changes are discarded.')
    end)
    ImGui.EndDisabled()                                      -- pairs with BeginDisabled(running)
    if not ok then error(err, 0) end                         -- pass to ui.render's pcall
end

--[[------------------------------------------------------------------------
  drawProgress(app)  (private)

  WHAT  : During a run: which stack is being processed and the red Stop
          Selling button (the pause control). After a run: the last report.
          Otherwise two reserved blank rows.
  WHY   : The player must be able to stop at any time, and must see what
          actually happened, including measured coin change.
  WHERE : Under the buttons (ui.render).
  HOW   : Stop Selling calls seller:requestStop, which only sets a flag;
          the worker stops before the next item. The report text depends on
          the mode; failures are listed in a tooltip.
  WHEN  : Every frame.
--------------------------------------------------------------------------]]
local function drawProgress(app)
    local s = app.seller
    if s.running then
        -- Running: progress line and the Stop Selling button.
        colored(COLOR.warn, ('Processing %d of %d: %s'):format(s.progress.index, s.progress.total, s.progress.current))
        ImGui.PushStyleColor(ImGuiCol.Button, 0.70, 0.15, 0.15, 1.0)   -- red button
        local stop = ImGui.Button('Stop Selling##fv_stop', 160, 0)
        ImGui.PopStyleColor(1)                               -- pairs with PushStyleColor
        if stop then s:requestStop() end                     -- flag only; safe here
        ImGui.SameLine()
        colored(COLOR.dim, s.stopRequested and 'Stopping before the next item...' or 'Stops before the next item. Completed sales cannot be undone.')
    elseif s.lastReport then
        -- Finished: summary of the last run.
        local r = s.lastReport
        local col = r.stopReason == 'Completed' and COLOR.ok or COLOR.warn
        colored(col, ('Last run (%s): %s'):format(r.mode, r.stopReason))
        local detail   -- report text built below
        if r.mode == 'live' then   -- live run
            -- Live: sold count, failures, measured coin and the estimate.
            detail = ('Sold %d of %d planned item(s); %d failure(s). Coin change: %s (estimate was %s)')
                :format(r.soldQty, r.planned, #r.failures,
                    r.coinDelta and coin(r.coinDelta) or 'unavailable',
                    r.estCopper and (coin(r.estCopper) .. ((r.unpricedTypes or 0) > 0   -- estimate for priced items
                        and (' for priced items; %d unpriced'):format(r.unpricedTypes) or '')) or 'unavailable')   -- note unpriced types
        elseif r.mode == 'select_test' then   -- selection test run
            -- Selection test: how many selections and quotes verified.
            detail = ('Selection and merchant quote verified for %d of %d stack(s); %d failure(s). Nothing was sold.')
                :format(r.selectedOk, r.plannedStacks, #r.failures)
        else
            -- Preview: what would have been processed.
            detail = ('Preview listed %d stack(s) / %d item(s). No game commands were issued.')
                :format(r.stacksDone, r.planned)
        end
        ImGui.TextUnformatted(detail)   -- the report line
        -- Hover the detail line to see each failure and where it was.
        if #r.failures > 0 and ImGui.IsItemHovered() then
            ImGui.BeginTooltip()
            local ok, err = pcall(function()
                for _, f in ipairs(r.failures) do   -- each failure
                    ImGui.TextUnformatted(('%s (pack%s %s): %s'):format(tostring(f.name), tostring(f.pack),   -- name and pack
                        f.sub and ('slot ' .. (f.sub + 1)) or 'loose', tostring(f.reason)))   -- slot and reason
                end
            end)
            ImGui.EndTooltip()                   -- always paired with BeginTooltip
            if not ok then error(err, 0) end     -- pass to ui.render's pcall
        end
    else
        colored(COLOR.dim, ' '); ImGui.TextUnformatted(' ')   -- reserved rows
    end
end

--[[------------------------------------------------------------------------
  drawActivity(app)  (private)

  WHAT  : The Activity Log: a bordered, scrolling list of recent log lines,
          coloured by level.
  WHY   : Shows what the script did without opening the log file.
  WHERE : Bottom of the main window (ui.render).
  HOW   : Reads app.log.ring(); scrolls to the bottom only when the ring
          has new lines (ringVersion changed), so reading older lines is
          not interrupted.
  WHEN  : Every frame.
--------------------------------------------------------------------------]]
local function drawActivity(app)
    ImGui.TextUnformatted('Activity Log')
    if ImGui.BeginChild('##fv_log', 0, app.cfg.ACTIVITY_LOG_HEIGHT, ImGuiChildFlags.Borders) then
        local ok, err = pcall(function()   -- keep the ImGui stack balanced
            -- One coloured line per entry.
            for _, e in ipairs(app.log.ring()) do
                local col = e.level == 'ERROR' and COLOR.bad or (e.level == 'WARN' and COLOR.warn or COLOR.dim)
                colored(col, e.text)
            end
            -- New lines arrived: scroll to the newest once.
            if app.logVersionSeen ~= app.log.ringVersion() then
                ImGui.SetScrollHereY(1.0)
                app.logVersionSeen = app.log.ringVersion()
            end
        end)
        if not ok then app.reportUiError(err) end    -- log and fault the session
    end
    ImGui.EndChild()                                 -- always called, per ImGui rules
end

-- ---------------------------------------------------------------------------
-- Confirmation window
-- ---------------------------------------------------------------------------

--[[------------------------------------------------------------------------
  drawConfirm(app)  (private)

  WHAT  : The Confirm Sale window: mode, any notice, totals, estimate, the
          list of items, and the Confirm Sale and Cancel buttons.
  WHY   : Nothing is sold until the player has seen this exact list and
          pressed Confirm Sale. If the bags change, init.lua rebuilds the
          list and shows a notice, and the player must confirm again.
  WHERE : Drawn by ui.render after the main window, only while
          app.showConfirm is set.
  HOW   : Confirm sets app.requests.confirm; Cancel or the window X sets
          app.requests.cancelConfirm. Focus is taken once when it opens.
  WHEN  : Every frame while a proposal is waiting.
--------------------------------------------------------------------------]]
local function drawConfirm(app)
    local p = app.proposal
    if not p or not app.showConfirm then return end           -- nothing to confirm
    ImGui.SetNextWindowSize(520, 420, ImGuiCond.Appearing)
    if app.focusConfirm then ImGui.SetNextWindowFocus(); app.focusConfirm = false end   -- focus once
    local open, draw = ImGui.Begin('Confirm Sale##fv_confirm', true, ImGuiWindowFlags.NoCollapse)
    if draw then
        local ok, err = pcall(function()
            -- Mode and the reserved notice line.
            local label, col = modeLabel(p.mode)
            colored(col, 'Mode: ' .. label)
            if app.confirmNotice then colored(COLOR.warn, app.confirmNotice) else colored(COLOR.dim, ' ') end
            ImGui.TextUnformatted(('You are about to process %d item type(s), %d stack(s), %d individual item(s).')   -- totals
                :format(#p.items, p.totalStacks, p.totalQty))   -- types, stacks, items
            -- Estimate covers priced items only; say how many are unpriced.
            local est = p.estCopper and coin(p.estCopper) or 'Unavailable'
            if p.estCopper and (p.unpricedTypes or 0) > 0 then
                est = est .. ('  (excludes %d unpriced item type(s))'):format(p.unpricedTypes)
            end
            ImGui.TextUnformatted('Estimated proceeds: ' .. est)   -- estimate line
            ImGui.TextUnformatted('All eligible copies of each listed item will be processed.')   -- whole quantity of each item
            ImGui.TextUnformatted('Protected bags and excluded stacks are never touched.')   -- safety reminder
            ImGui.Separator()   -- line above the list
            -- Scrolling list, leaving 40 pixels for the buttons.
            local listOk, listErr = true, nil
            if ImGui.BeginChild('##fv_confirm_list', 0, -40, ImGuiChildFlags.Borders) then
                listOk, listErr = pcall(function()
                    -- One line per item: name, quantity, stacks, estimate.
                    for _, it in ipairs(p.items) do
                        ImGui.TextUnformatted(('%-40s x%d  (%d stack%s)  %s'):format(
                            it.name, it.qty, it.stacks, it.stacks == 1 and '' or 's',
                            it.unitEst and ('~' .. coin(it.unitEst * it.qty)) or ''))   -- estimated coin for this line
                    end
                end)
            end
            ImGui.EndChild()                         -- always called, per ImGui rules
            if not listOk then error(listErr, 0) end -- pass to the window pcall
            -- Green Confirm Sale button.
            ImGui.PushStyleColor(ImGuiCol.Button, 0.15, 0.50, 0.15, 1.0)
            local confirm = ImGui.Button('Confirm Sale##fv_confirm_btn', 140, 0)
            ImGui.PopStyleColor(1)                   -- pairs with PushStyleColor
            if confirm then app.requests.confirm = true end
            ImGui.SameLine()
            if ImGui.Button('Cancel##fv_confirm_cancel', 100, 0) then app.requests.cancelConfirm = true end
        end)
        if not ok then app.reportUiError(err) end    -- log and fault the session
    end
    ImGui.End()                                      -- always called, per ImGui rules
    if open == false then app.requests.cancelConfirm = true end   -- X closes like Cancel
end

-- ---------------------------------------------------------------------------
-- Entry point registered with mq.imgui.init
-- ---------------------------------------------------------------------------

--[[------------------------------------------------------------------------
  ui.render(app)  (public)

  WHAT  : Draws the main window, then the Confirm window if one is open.
  WHY   : The single function MacroQuest calls each frame.
  WHERE : Registered by init.lua: mq.imgui.init(SCRIPT_NAME, ...).
  HOW   : Begin the main window, draw each section inside one pcall, End.
          The window X behaves like Cancel; during a run it requests a stop
          first, and the main loop exits once the worker has stopped.
  WHEN  : Every frame while the script runs and app.showMain is set
          (/fvendor show sets it again).
--------------------------------------------------------------------------]]
function ui.render(app)
    if not app.showMain then return end                      -- hidden
    ImGui.SetNextWindowSize(app.cfg.WINDOW_WIDTH, app.cfg.WINDOW_HEIGHT, ImGuiCond.FirstUseEver)
    local title = ('Farm Vendor v%s##fv_main'):format(app.cfg.VERSION)
    local open, draw = ImGui.Begin(title, true)
    if draw then   -- window is visible
        local ok, err = pcall(function()   -- errors are caught and logged
            -- Top to bottom: status, filters and table, actions, log.
            drawHeader(app)
            drawReadiness(app)
            ImGui.Separator()
            drawFilters(app)   -- search and filters
            drawTable(app)   -- item checklist
            drawButtons(app)   -- action buttons
            -- (sections continued)
            ImGui.Separator()
            drawProgress(app)
            ImGui.Separator()
            drawActivity(app)   -- log
        end)
        if not ok then app.reportUiError(err) end    -- log and fault the session
    end
    ImGui.End()                                      -- always called, per ImGui rules
    if open == false then
        -- Window X: same as Cancel when idle; when selling, stop first, then exit.
        if app.seller.running then app.seller:requestStop() end
        app.requests.quit = true
    end
    drawConfirm(app)                                 -- separate window
end

-- Hand the module to init.lua.
return ui

--[[==========================================================================
  END OF FILE : Farm_Vendor/ui.lua

  PUBLIC  ui.available   true when the ImGui bindings loaded
          ui.render(app) per frame draw function

  DEPENDENCIES : ImGui bindings (MacroQuest), bit32 or LuaJIT bit,
                 Farm_Vendor.engine (inventory.formatCoin). Reads, but never
                 calls game commands through, app.seller.probe.

  HOW TO EDIT SAFELY
    - Never send a game command or call mq.delay here. Set a flag in
      app.requests and handle it in init.lua's main loop.
    - Every Begin, BeginChild, BeginTable, BeginTooltip, PushID,
      PushStyleColor and BeginDisabled needs its End or Pop outside the
      pcall that wraps the body.
    - Draw player supplied text with TextUnformatted, never Text.
    - Check any new ImGui call or enum against mq-definitions and add it to
      AUDIT.md before using it.
    - Run dev/doc_audit.py and dev/run_tests.py after editing.
==========================================================================]]--
