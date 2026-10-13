--[[
Farm_Vendor/ui.lua
==================

ImGui windows for Farm Vendor.

  Main window     Inventory checklist, readiness, buttons, progress, report,
                  Activity Log.
  Confirm window  Opens after "Sell All Checked Items". Lists exactly what will
                  be processed. "Confirm Sale" or "Cancel".

Rules
  * The UI NEVER issues game commands and NEVER calls mq.delay. Buttons only
    set request flags in app.requests; init.lua's main loop performs the work
    (MacroQuest: mq.delay cannot run inside an ImGui callback).
  * Every Begin/BeginChild/BeginTable/PushID/PushStyleColor/BeginDisabled is
    matched by its End/Pop call even if drawing fails: each paired region's
    body runs inside pcall, so a rendering error is logged (UI error) instead
    of leaving the ImGui stack unbalanced.
  * Text that may contain '%' (paths, item names, log lines) is drawn with
    TextUnformatted so it is never treated as a format string.
  * Status rows always render (reserved space) so controls do not jump when a
    message appears or disappears (MagFarm preview-row lesson).

ImGui calls used are all present in the MacroQuest mq-definitions ImGui
bindings (see INTERFACES.md).
]]

local inventory = require('Farm_Vendor.inventory')

local ui = {}

-- ImGui bindings: require('ImGui') is the documented form (mq-definitions,
-- RedGuides "MQ VS Code Lua Autocomplete Definition Library"). Loaded with
-- pcall so a missing binding is reported at startup instead of crashing.
local okImGui, ImGui = pcall(require, 'ImGui')
if not okImGui or type(ImGui) ~= 'table' then ImGui = rawget(_G, 'ImGui') end
ui.available = type(ImGui) == 'table'

-- Bit operations for combining ImGui flags: bit32 is documented by
-- mq-definitions (_Bit32.lua). LuaJIT's built-in 'bit' (MQ2Lua runs on LuaJIT
-- 2.1) provides the same bor and is used only if bit32 is absent.
local bit32 = rawget(_G, 'bit32') or require('bit')

local COLOR = {
    ok    = { 0.35, 0.85, 0.35, 1.0 },
    warn  = { 0.95, 0.80, 0.25, 1.0 },
    bad   = { 0.95, 0.35, 0.35, 1.0 },
    dim   = { 0.65, 0.65, 0.65, 1.0 },
    live  = { 1.00, 0.45, 0.20, 1.0 },
}

local function colored(c, text)
    ImGui.PushStyleColor(ImGuiCol.Text, c[1], c[2], c[3], c[4])
    local ok, err = pcall(ImGui.TextUnformatted, tostring(text))
    ImGui.PopStyleColor(1)                  -- always paired with the Push above
    if not ok then error(err, 0) end
end

local function tooltip(text)
    if ImGui.IsItemHovered() then
        ImGui.BeginTooltip()
        local ok, err = pcall(ImGui.TextUnformatted, tostring(text))
        ImGui.EndTooltip()                  -- always paired with BeginTooltip
        if not ok then error(err, 0) end
    end
end

local function modeLabel(mode)
    if mode == 'live' then return 'LIVE SELLING', COLOR.live end
    if mode == 'select_test' then return 'SELECTION TEST (no sales)', COLOR.warn end
    return 'PREVIEW (no game commands)', COLOR.ok
end

local function coin(c) return inventory.formatCoin(c) end

-- ---------------------------------------------------------------------------
-- Main window sections
-- ---------------------------------------------------------------------------

local function drawHeader(app)
    local label, col = modeLabel(app.seller.mode)
    ImGui.TextUnformatted(('Character: %s   Server: %s'):format(app.identity.name, app.identity.server))
    ImGui.TextUnformatted('Mode: '); ImGui.SameLine(); colored(col, label)

    local open = app.seller.probe.merchantOpen()
    ImGui.TextUnformatted('Merchant: '); ImGui.SameLine()
    if open == true then
        colored(COLOR.ok, 'Open - ' .. (app.seller.probe.merchantName() or 'unknown name'))
    elseif open == false then
        colored(COLOR.dim, 'Closed (open one yourself before selling)')
    else
        colored(COLOR.bad, 'Unknown')
    end

    local st = app.store
    local stCol = (st.status == 'failed' or st.status == 'readonly') and COLOR.bad
        or (st.status == 'loaded_with_warnings' and COLOR.warn or COLOR.dim)
    ImGui.TextUnformatted('Selections file: '); ImGui.SameLine()
    colored(stCol, ('%s - %s'):format(st.status, st.statusDetail))
    tooltip(st.path)
    ImGui.SameLine()
    if app.dirty then colored(COLOR.warn, '  [Unsaved changes]') else colored(COLOR.dim, '  [No unsaved changes]') end
end

local function drawReadiness(app)
    local checks = app.readiness or {}
    local blocked = {}
    for _, c in ipairs(checks) do if not c.ok then blocked[#blocked + 1] = c end end
    if #blocked == 0 then
        colored(COLOR.ok, 'Readiness: all checks passed')
    else
        colored(COLOR.bad, ('Readiness: %d check(s) blocking selling'):format(#blocked))
    end
    if ImGui.IsItemHovered() then
        ImGui.BeginTooltip()
        local ok, err = pcall(function()
            for _, c in ipairs(checks) do
                colored(c.ok and COLOR.ok or COLOR.bad, ('[%s] %s - %s'):format(c.ok and 'OK' or 'BLOCKED',
                    tostring(c.name), tostring(c.detail)))
            end
        end)
        ImGui.EndTooltip()
        if not ok then error(err, 0) end
    end
    -- Reserved line: always drawn so layout does not shift.
    if #blocked > 0 then
        colored(COLOR.bad, ('%s: %s'):format(blocked[1].name, blocked[1].detail))
    else
        colored(COLOR.dim, ' ')
    end
end

local function drawFilters(app)
    ImGui.SetNextItemWidth(260)
    local text, changed = ImGui.InputText('Search##fv_search', app.filter.search)
    if changed and type(text) == 'string' then
        -- Input validation: strip control characters and cap length.
        app.filter.search = text:gsub('%c', ''):sub(1, app.cfg.SEARCH_MAX_LENGTH)
    end
    ImGui.SameLine()
    local v, p = ImGui.Checkbox('Checked only##fv_checked', app.filter.checkedOnly)
    if p then app.filter.checkedOnly = v end
    ImGui.SameLine()
    v, p = ImGui.Checkbox('Show excluded##fv_excl', app.filter.showExcluded)
    if p then app.filter.showExcluded = v end
    ImGui.SameLine()
    ImGui.BeginDisabled(app.seller.running)
    if ImGui.Button('Refresh Inventory##fv_refresh') then app.requests.rescan = true end
    ImGui.EndDisabled()
end

local function rowVisible(app, row)
    if not row.eligible and not app.filter.showExcluded then return false end
    if app.filter.checkedOnly and not app.checked[row.id] then return false end
    local s = app.filter.search
    if s ~= '' and not row.name:lower():find(s:lower(), 1, true) then return false end
    return true
end

local function drawTable(app)
    local scan = app.scan
    if not scan then colored(COLOR.dim, 'Scanning inventory...'); return end
    local flags = bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.Borders,
        ImGuiTableFlags.ScrollY, ImGuiTableFlags.Resizable, ImGuiTableFlags.SizingStretchProp)
    local _, availY = ImGui.GetContentRegionAvail()
    local reserved = app.cfg.ACTIVITY_LOG_HEIGHT + 190      -- room for buttons, progress, log
    local height = math.max(120, (availY or 400) - reserved)
    if ImGui.BeginTable('##fv_items', 7, flags, 0, height) then
        local ok, err = pcall(function()
            ImGui.TableSetupScrollFreeze(0, 1)
            ImGui.TableSetupColumn('Sell', ImGuiTableColumnFlags.WidthFixed, 36)
            ImGui.TableSetupColumn('Item', ImGuiTableColumnFlags.WidthStretch, 3)
            ImGui.TableSetupColumn('Qty', ImGuiTableColumnFlags.WidthFixed, 50)
            ImGui.TableSetupColumn('Stacks', ImGuiTableColumnFlags.WidthFixed, 50)
            ImGui.TableSetupColumn('Est. each', ImGuiTableColumnFlags.WidthFixed, 90)
            ImGui.TableSetupColumn('Flags', ImGuiTableColumnFlags.WidthFixed, 45)
            ImGui.TableSetupColumn('Notes', ImGuiTableColumnFlags.WidthStretch, 2)
            ImGui.TableHeadersRow()
            local merchantOpen = app.seller.probe.merchantOpen() == true
            for _, row in ipairs(scan.rows) do
                if rowVisible(app, row) then
                    ImGui.PushID(row.id)
                    local rowOk, rowErr = pcall(function()
                    ImGui.TableNextRow()
                    ImGui.TableNextColumn()
                    ImGui.BeginDisabled(app.seller.running or not row.eligible)
                    local val, pressed = ImGui.Checkbox('##sell', app.checked[row.id] == true)
                    ImGui.EndDisabled()
                    if pressed and row.eligible and not app.seller.running then
                        app.checked[row.id] = val or nil
                        app.names[row.id] = row.name
                        app.dirty = true
                    end
                    ImGui.TableNextColumn(); ImGui.TextUnformatted(row.name)
                    tooltip(('Item ID %d'):format(row.id))
                    ImGui.TableNextColumn(); ImGui.TextUnformatted(tostring(row.qty))
                    ImGui.TableNextColumn(); ImGui.TextUnformatted(tostring(row.stacks))
                    ImGui.TableNextColumn()
                    if merchantOpen and type(row.sellPrice) == 'number' and row.sellPrice > 0 then
                        ImGui.TextUnformatted(coin(row.sellPrice))
                        tooltip('Merchant SellPrice estimate. Actual coin is measured after the run.')
                    else
                        colored(COLOR.dim, 'Unavailable')
                        tooltip('Shown only while a merchant is open (Item.SellPrice).')
                    end
                    ImGui.TableNextColumn()
                    local f = (row.noDrop and 'ND ' or '') .. (row.lore and 'L' or '')
                    ImGui.TextUnformatted(f)
                    if f ~= '' then tooltip('ND = NO DROP / NO TRADE, L = Lore') end
                    ImGui.TableNextColumn()
                    if not row.eligible then
                        colored(COLOR.dim, 'Excluded: ' .. row.reasonText)
                    elseif row.reasonText ~= '' then
                        colored(COLOR.warn, ('%d of %d stacks eligible (%s)'):format(row.eligibleStacks, row.stacks, row.reasonText))
                    else
                        ImGui.TextUnformatted(' ')
                    end
                    end)
                    ImGui.PopID()
                    if not rowOk then error(rowErr, 0) end
                end
            end
        end)
        ImGui.EndTable()
        if not ok then app.reportUiError(err) end
    end
end

local function selectionSummary(app)
    local types, qty, missing = 0, 0, 0
    for id in pairs(app.checked) do
        local row = app.scan and app.scan.rowsById[id]
        if row and row.eligible then
            types = types + 1; qty = qty + row.eligibleQty
        else
            missing = missing + 1
        end
    end
    return types, qty, missing
end

local function drawButtons(app)
    local types, qty, missing = selectionSummary(app)
    ImGui.TextUnformatted(('Selected: %d item type(s) / %d item(s) carried'):format(types, qty))
    if missing > 0 then
        ImGui.SameLine()
        colored(COLOR.dim, ('  (%d remembered item(s) not currently carried)'):format(missing))
    end
    if app.scan and app.scan.protectedCount > 0 then
        ImGui.SameLine()
        colored(COLOR.dim, ('  %d item(s) hidden in protected bags'):format(app.scan.protectedCount))
    end

    local running = app.seller.running
    ImGui.BeginDisabled(running)
    local ok, err = pcall(function()
    if ImGui.Button('Clear Checks##fv_clear') then
        -- Clears only currently listed items; remembered items not carried stay remembered.
        for _, row in ipairs(app.scan and app.scan.rows or {}) do
            if app.checked[row.id] then app.checked[row.id] = nil; app.dirty = true end
        end
    end
    tooltip('Unchecks listed items. Remembered items you are not carrying are kept.')
    ImGui.SameLine()
    ImGui.BeginDisabled(app.store.readonly or not app.dirty)
    local save = ImGui.Button('Save Selections##fv_save')
    ImGui.EndDisabled()
    if save then app.requests.save = true end
    ImGui.SameLine()
    ImGui.BeginDisabled(types == 0 or not app.readyToSell)
    local sell = ImGui.Button('Sell All Checked Items##fv_sell')
    ImGui.EndDisabled()
    if sell then app.requests.prepare = true end
    if types == 0 then tooltip('Check at least one item first.')
    elseif not app.readyToSell then tooltip('Blocked: hover the Readiness line for details.') end
    ImGui.SameLine()
    if ImGui.Button('Cancel##fv_cancel') then app.requests.quit = true end
    tooltip('Exit with no action. Unsaved checkbox changes are discarded.')
    end)
    ImGui.EndDisabled()
    if not ok then error(err, 0) end
end

local function drawProgress(app)
    local s = app.seller
    if s.running then
        colored(COLOR.warn, ('Processing %d of %d: %s'):format(s.progress.index, s.progress.total, s.progress.current))
        ImGui.PushStyleColor(ImGuiCol.Button, 0.70, 0.15, 0.15, 1.0)
        local stop = ImGui.Button('Stop Selling##fv_stop', 160, 0)
        ImGui.PopStyleColor(1)
        if stop then s:requestStop() end
        ImGui.SameLine()
        colored(COLOR.dim, s.stopRequested and 'Stopping before the next item...' or 'Stops before the next item. Completed sales cannot be undone.')
    elseif s.lastReport then
        local r = s.lastReport
        local col = r.stopReason == 'Completed' and COLOR.ok or COLOR.warn
        colored(col, ('Last run (%s): %s'):format(r.mode, r.stopReason))
        local detail
        if r.mode == 'live' then
            detail = ('Sold %d of %d planned item(s); %d failure(s). Coin change: %s (estimate was %s)')
                :format(r.soldQty, r.planned, #r.failures,
                    r.coinDelta and coin(r.coinDelta) or 'unavailable',
                    r.estCopper and (coin(r.estCopper) .. ((r.unpricedTypes or 0) > 0
                        and (' for priced items; %d unpriced'):format(r.unpricedTypes) or '')) or 'unavailable')
        elseif r.mode == 'select_test' then
            detail = ('Selection and merchant quote verified for %d of %d stack(s); %d failure(s). Nothing was sold.')
                :format(r.selectedOk, r.plannedStacks, #r.failures)
        else
            detail = ('Preview listed %d stack(s) / %d item(s). No game commands were issued.')
                :format(r.stacksDone, r.planned)
        end
        ImGui.TextUnformatted(detail)
        if #r.failures > 0 and ImGui.IsItemHovered() then
            ImGui.BeginTooltip()
            local ok, err = pcall(function()
                for _, f in ipairs(r.failures) do
                    ImGui.TextUnformatted(('%s (pack%s %s): %s'):format(tostring(f.name), tostring(f.pack),
                        f.sub and ('slot ' .. (f.sub + 1)) or 'loose', tostring(f.reason)))
                end
            end)
            ImGui.EndTooltip()
            if not ok then error(err, 0) end
        end
    else
        colored(COLOR.dim, ' '); ImGui.TextUnformatted(' ')   -- reserved rows
    end
end

local function drawActivity(app)
    ImGui.TextUnformatted('Activity Log')
    if ImGui.BeginChild('##fv_log', 0, app.cfg.ACTIVITY_LOG_HEIGHT, ImGuiChildFlags.Borders) then
        local ok, err = pcall(function()
            for _, e in ipairs(app.log.ring()) do
                local col = e.level == 'ERROR' and COLOR.bad or (e.level == 'WARN' and COLOR.warn or COLOR.dim)
                colored(col, e.text)
            end
            if app.logVersionSeen ~= app.log.ringVersion() then
                ImGui.SetScrollHereY(1.0)
                app.logVersionSeen = app.log.ringVersion()
            end
        end)
        if not ok then app.reportUiError(err) end
    end
    ImGui.EndChild()
end

-- ---------------------------------------------------------------------------
-- Confirmation window
-- ---------------------------------------------------------------------------

local function drawConfirm(app)
    local p = app.proposal
    if not p or not app.showConfirm then return end
    ImGui.SetNextWindowSize(520, 420, ImGuiCond.Appearing)
    if app.focusConfirm then ImGui.SetNextWindowFocus(); app.focusConfirm = false end
    local open, draw = ImGui.Begin('Confirm Sale##fv_confirm', true, ImGuiWindowFlags.NoCollapse)
    if draw then
        local ok, err = pcall(function()
            local label, col = modeLabel(p.mode)
            colored(col, 'Mode: ' .. label)
            if app.confirmNotice then colored(COLOR.warn, app.confirmNotice) else colored(COLOR.dim, ' ') end
            ImGui.TextUnformatted(('You are about to process %d item type(s), %d stack(s), %d individual item(s).')
                :format(#p.items, p.totalStacks, p.totalQty))
            local est = p.estCopper and coin(p.estCopper) or 'Unavailable'
            if p.estCopper and (p.unpricedTypes or 0) > 0 then
                est = est .. ('  (excludes %d unpriced item type(s))'):format(p.unpricedTypes)
            end
            ImGui.TextUnformatted('Estimated proceeds: ' .. est)
            ImGui.TextUnformatted('All eligible copies of each listed item will be processed.')
            ImGui.TextUnformatted('Protected bags and excluded stacks are never touched.')
            ImGui.Separator()
            local listOk, listErr = true, nil
            if ImGui.BeginChild('##fv_confirm_list', 0, -40, ImGuiChildFlags.Borders) then
                listOk, listErr = pcall(function()
                    for _, it in ipairs(p.items) do
                        ImGui.TextUnformatted(('%-40s x%d  (%d stack%s)  %s'):format(
                            it.name, it.qty, it.stacks, it.stacks == 1 and '' or 's',
                            it.unitEst and ('~' .. coin(it.unitEst * it.qty)) or ''))
                    end
                end)
            end
            ImGui.EndChild()
            if not listOk then error(listErr, 0) end
            ImGui.PushStyleColor(ImGuiCol.Button, 0.15, 0.50, 0.15, 1.0)
            local confirm = ImGui.Button('Confirm Sale##fv_confirm_btn', 140, 0)
            ImGui.PopStyleColor(1)
            if confirm then app.requests.confirm = true end
            ImGui.SameLine()
            if ImGui.Button('Cancel##fv_confirm_cancel', 100, 0) then app.requests.cancelConfirm = true end
        end)
        if not ok then app.reportUiError(err) end
    end
    ImGui.End()
    if open == false then app.requests.cancelConfirm = true end   -- X closes like Cancel
end

-- ---------------------------------------------------------------------------
-- Entry point registered with mq.imgui.init
-- ---------------------------------------------------------------------------

function ui.render(app)
    if not app.showMain then return end
    ImGui.SetNextWindowSize(app.cfg.WINDOW_WIDTH, app.cfg.WINDOW_HEIGHT, ImGuiCond.FirstUseEver)
    local title = ('Farm Vendor v%s##fv_main'):format(app.cfg.VERSION)
    local open, draw = ImGui.Begin(title, true)
    if draw then
        local ok, err = pcall(function()
            drawHeader(app)
            drawReadiness(app)
            ImGui.Separator()
            drawFilters(app)
            drawTable(app)
            drawButtons(app)
            ImGui.Separator()
            drawProgress(app)
            ImGui.Separator()
            drawActivity(app)
        end)
        if not ok then app.reportUiError(err) end
    end
    ImGui.End()
    if open == false then
        -- Window X: same as Cancel when idle; when selling, stop first, then exit.
        if app.seller.running then app.seller:requestStop() end
        app.requests.quit = true
    end
    drawConfirm(app)
end

return ui
