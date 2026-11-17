--[[==========================================================================
  FILE        : Farm_Vendor/dev/harness.lua
  PACKAGE     : Farm Vendor  (MacroQuest Lua / EverQuest)
  VERSION     : 1.4.0
  CHANGES     : 1.4.0  Checkbox clicks are queued per column: H.checks for
                       the Sell box (##sell), H.never for the Never Sell
                       box (##never). The table now has 8 columns.
                1.3.0  Moved from tests/ to dev/. Header, footer and function
                       documentation added. No behaviour change.
                1.2.1  ImGui stack balance tracking; failText injection;
                       ImGui provided through require('ImGui').
                1.1.1  refuseOnce, strayQuote, quoteName.
                1.1.0  Merchant chat lines, quote timing, noQuote.
                1.0.0  First version.

  CREDITS     : Original to Farm Vendor.

  WHAT  : A fake MacroQuest for offline tests: TLOs, mq functions, an
          ImGui stub that checks every Begin has its End, and a fake
          merchant that answers /itemnotify and /sellitem like the client.

  WHY   : The selling logic can be exercised thousands of times on a PC
          with no game running. This proves program logic only; it does NOT
          prove client behaviour. Live checks are in TESTING.md.

  WHERE : Loaded by dev/run_tests.py with dofile before init.lua runs.
          Never shipped to or loaded by MacroQuest.

  HOW   : Sets package.loaded['mq'] and package.preload['ImGui'] so the
          real files load these fakes through their normal require calls.
          H.world holds the fake game; scenarios change it and queue
          button presses with H.press and steps with H.on.

  WHEN  : Once per test scenario.
==========================================================================]]--

-- Shared test state, also reachable as the global HARNESS.
local H = { log = {}, cmds = {}, presses = {}, checks = {}, never = {}, frame = 0, steps = {}, now = 0 }
_G.HARNESS = H

-- ---------------- world model ----------------
H.world = {
  gameState = 'INGAME', name = 'TestMag', server = 'test server',
  merchantOpen = true, itemsReceived = true, merchantId = 999,
  cursor = nil, macro = nil, coin = 0, selected = nil,
  refuse = {},        -- [id]=true merchant refuses
  noSelect = {},      -- [id]=true selection never registers
  cursorOnSelect = {},-- [id]=true item jumps to cursor
  packs = {},         -- [slot] = {bag=n, items={[sub]=item}} or {item=item}
  quoteDelay = 300,   -- ms until the merchant quote line arrives after a selection
  noQuote = false,    -- merchant never sends a quote
  quoteAt = nil,      -- time the current selection's quote is delivered
}
H.lines = {}          -- pending chat lines {at=ms, text=}
H.events = {}         -- name -> {phrase=, cb=, queue={}}
--[[------------------------------------------------------------------------
  say(text, delay)

  WHAT  : Queues a merchant chat line to arrive delay ms from now.
  WHY   : The real client delivers chat lines some time after a click; the
          tests need the same timing to prove the script waits for them.
  WHERE : H.exec (selection and /sellitem responses) and test scenarios.
  HOW   : Appends to H.lines; H.tickFrame delivers due lines to events.
  WHEN  : Whenever the fake merchant answers.
--------------------------------------------------------------------------]]
local function say(text, delay) H.lines[#H.lines+1] = { at = H.now + (delay or 0), text = text } end
H.say = say
--[[------------------------------------------------------------------------
  mkItem(id, name, stack, value, opts)

  WHAT  : Builds one fake item record.
  WHY   : Scenarios describe bags with plain tables.
  WHERE : H.std in run_tests.py and individual scenarios.
  HOW   : Copies the fields; opts may set nodrop, lore, container, sellPrice.
  WHEN  : While building a scenario's bags.
--------------------------------------------------------------------------]]
local function mkItem(id, name, stack, value, opts)
  opts = opts or {}
  return { id=id, name=name, stack=stack, value=value, nodrop=opts.nodrop or false, lore=opts.lore or false, container=opts.container or 0, sellPrice=opts.sellPrice }
end
H.mkItem = mkItem

--[[------------------------------------------------------------------------
  itemProxy(rec, slot, sub)

  WHAT  : Wraps an item record so it answers like a MacroQuest item TLO
          (ID(), Name(), Stack(), Value(), SellPrice(), NoDrop(), Lore(),
          Container(), ItemSlot(), ItemSlot2(), Item(n)).
  WHY   : engine.lua reads items only through these members; the fake must
          answer the same calls, including nil for an empty slot.
  WHERE : TLO.Me.Inventory and Item(n) below.
  HOW   : Each member is a function closed over the record; g() returns nil
          when the slot is empty. SellPrice is nil unless a merchant is open,
          as in the client.
  WHEN  : Every inventory read during a test.
--------------------------------------------------------------------------]]
local function itemProxy(rec, slot, sub)
  local p = {}
  -- Member that returns nil when the slot is empty.
  local function g(f) return function() if rec == nil then return nil end return f(rec) end end
  p.ID = g(function(r) return r.id end)
  p.Name = g(function(r) return r.name end)
  p.Stack = g(function(r) return r.stack end)
  p.Value = g(function(r) return r.value end)
  p.SellPrice = g(function(r) if not H.world.merchantOpen then return nil end; if r.sellPrice ~= nil then return r.sellPrice end; return math.floor(r.value*0.9) end)
  p.NoDrop = g(function(r) return r.nodrop end)
  p.Lore = g(function(r) return r.lore end)
  p.Container = g(function(r) return r.container end)
  p.ItemSlot = function() return rec and slot or nil end
  p.ItemSlot2 = function() return rec and (sub or -1) or nil end
  p.Item = function(n)
    local pk = H.world.packs[slot]
    local child = pk and pk.items and pk.items[n-1]
    return itemProxy(child, slot, n-1)
  end
  return p
end

--[[------------------------------------------------------------------------
  locate(slot, sub)

  WHAT  : Returns the item record at a pack slot (sub nil) or bag sub slot.
  WHY   : Commands and Merchant.SelectedItem need the record at a location.
  WHERE : H.exec and TLO.Merchant.SelectedItem.
  HOW   : Looks up H.world.packs.
  WHEN  : Every fake click and selection read.
--------------------------------------------------------------------------]]
local function locate(slot, sub)
  local pk = H.world.packs[slot]; if not pk then return nil end
  if sub == nil then return pk.item end
  return pk.items and pk.items[sub]
end

-- ---------------- fake TLOs (only the members engine.lua and init.lua read) ----------------
local TLO = {}
TLO.EverQuest = { GameState=function() return H.world.gameState end, Server=function() return H.world.server end }
TLO.Me = {
  Name=function() return H.world.name end,
  Inventory=function(slot)
    local pk = H.world.packs[slot]
    local rec = pk and (pk.item or pk.bag)
    return itemProxy(rec, slot, nil)
  end,
  Platinum=function() return math.floor(H.world.coin/1000) end,
  Gold=function() return math.floor(H.world.coin%1000/100) end,
  Silver=function() return math.floor(H.world.coin%100/10) end,
  Copper=function() return H.world.coin%10 end,
}
TLO.Cursor = { ID=function() return H.world.cursor end }
TLO.Macro = { Name=function() return H.world.macro end }
TLO.Merchant = {
  Open=function() return H.world.merchantOpen end,
  ItemsReceived=function() return H.world.itemsReceived end,
  ID=function() return H.world.merchantOpen and H.world.merchantId or nil end,
  CleanName=function() return H.world.merchantOpen and 'Test Merchant' or nil end,
  SelectedItem = {
    ID=function() local s=H.world.selected; return s and locate(s.slot,s.sub) and locate(s.slot,s.sub).id or nil end,
    ItemSlot=function() local s=H.world.selected; return s and s.slot or nil end,
    ItemSlot2=function() local s=H.world.selected; return s and (s.sub or -1) or nil end,
  },
}

-- ---------------- fake mq module ----------------
-- Each function below mirrors the documented mq function of the same name,
-- recording what the script did so the tests can check it.
local mq = { TLO = TLO, configDir = HARNESS_DIR, imgui = {} }
-- mq.cmd: record the command and let the fake world react.
function mq.cmd(c) H.cmds[#H.cmds+1]=c; H.exec(c) end
-- mq.cmdf: format, then mq.cmd.
function mq.cmdf(f, ...) mq.cmd(string.format(f, ...)) end
-- mq.bind: keep the callback so tests can type /fvendor stop.
function mq.bind(c, cb) H.bind = cb end
-- mq.gettime: the fake clock in ms.
function mq.gettime() return H.now end
-- mq.event: register a chat phrase; #*# wildcards are removed for a plain find.
function mq.event(name, matcher, cb)
  local phrase = matcher:gsub('#%*#', '')
  H.events[name] = { phrase = phrase, cb = cb, queue = {} }
end
-- mq.unevent: remove a chat event.
function mq.unevent(name) H.events[name] = nil end
-- mq.flushevents: drop queued lines for one event or all.
function mq.flushevents(name) if name then if H.events[name] then H.events[name].queue = {} end else for _, e in pairs(H.events) do e.queue = {} end end end
-- mq.doevents: run callbacks for queued lines.
function mq.doevents()
  for _, e in pairs(H.events) do local q = e.queue; e.queue = {}; for _, l in ipairs(q) do e.cb(l) end end
end
-- mq.unbind: record that shutdown unbound the command.
function mq.unbind() H.unbound = true end
-- mq.imgui.init: keep the render callback.
function mq.imgui.init(n, cb) H.render = cb end
-- mq.imgui.destroy: record that shutdown removed the window.
function mq.imgui.destroy() H.destroyed = true end
--[[------------------------------------------------------------------------
  mq.delay(ms, cond)

  WHAT  : Advances the fake clock in 50 ms steps, drawing a frame each step,
          until ms has passed or cond() is true.
  WHY   : Everything time based in the script (quote waits, sell waits,
          pacing, the main loop) runs through mq.delay, so this is what
          moves the whole simulation forward.
  WHERE : Called by the script exactly where the client would wait.
  HOW   : Loop of H.now += 50 and H.tickFrame().
  WHEN  : Every wait.
--------------------------------------------------------------------------]]
function mq.delay(ms, cond)
  if type(ms) ~= 'number' then ms = 100 end
  local t = 0
  repeat
    H.now = H.now + 50; t = t + 50
    H.tickFrame()
    if cond and cond() then return end
  until t >= ms
end
package.loaded['mq'] = mq

--[[------------------------------------------------------------------------
  H.exec(c)

  WHAT  : The fake merchant: reacts to /itemnotify (select) and /sellitem.
  WHY   : Lets the tests prove the script selects the exact slot, waits for
          the quote, sells only after it, and handles refusals, partial
          sales and cursor pickups.
  WHERE : mq.cmd.
  HOW   : Parses the two documented command forms. A select sets
          world.selected and queues a quote or refusal line. A sell before
          the quote, or for a refused item, is refused and counted in
          H.premature. Anything else raises an error so an unexpected
          command fails the test.
  WHEN  : Every command the script sends.
--------------------------------------------------------------------------]]
function H.exec(c)
  -- /itemnotify in packN M leftmouseup (bag) or /itemnotify N leftmouseup (loose).
  local pack, sub = c:match('^/itemnotify in pack(%d+) (%d+) leftmouseup$')
  local loose = c:match('^/itemnotify (%d+) leftmouseup$')
  local slot, s2
  if pack then slot, s2 = tonumber(pack)+22, tonumber(sub)-1 elseif loose then slot = tonumber(loose) end
  if slot then
    local it = locate(slot, s2)
    if it and H.world.cursorOnSelect[it.id] then H.world.cursor = it.id; return end
    if it and not H.world.noSelect[it.id] then
      H.world.selected = {slot=slot, sub=s2}
      if H.world.refuse[it.id] then
        H.world.quoteAt = nil
        say("Merchant Wyn'las told you, 'I am not interested in buying that.'", 200)
      elseif not H.world.noQuote then
        H.world.quoteAt = H.now + H.world.quoteDelay
        if H.world.strayQuote then say("Merchant Wyn'las told you, 'I'll give you 9 silver per Some Other Thing'", 50) end
        say(("Merchant Wyn'las told you, 'I'll give you 1 gold 9 silver per %s'"):format(H.world.quoteName or it.name), H.world.quoteDelay)
      end
    end
    return
  end
  -- /sellitem <quantity>.
  local q = c:match('^/sellitem (%d+)$')
  if q then
    q = tonumber(q); local s = H.world.selected; if not s then return end
    local it = locate(s.slot, s.sub)
    local once = H.world.refuseOnce and H.world.refuseOnce[it and it.id or 0]
    if once then H.world.refuseOnce[it.id] = nil end
    if not it or once or H.world.refuse[it.id] or (H.world.refuseAtSell and H.world.refuseAtSell[it.id]) or not H.world.quoteAt or H.now < H.world.quoteAt then
      H.premature = (H.premature or 0) + 1
      say("Merchant Wyn'las told you, 'I am not interested in buying that.'", 100); return
    end
    local n = math.min(q, it.stack, H.world.partialCap or 1e9)
    it.stack = it.stack - n; H.world.coin = H.world.coin + n*math.floor(it.value*0.9)
    if it.stack <= 0 then
      local pk = H.world.packs[s.slot]
      if s.sub == nil then pk.item = nil else pk.items[s.sub] = nil end
    end
    return
  end
  -- Any other command is a test failure.
  error('harness: unexpected command '..c)
end

-- ---------------- ImGui stub ----------------
local ImGui = {}
setmetatable(ImGui, { __index = function(_, k) return function() return nil end end })
H.texts = {}
-- Stack balance tracking: every Begin/Push must be closed within the frame.
H.imstack = {}
-- push: record an opened ImGui region.
local function push(k) H.imstack[#H.imstack+1] = k end
-- pop: close a region; a mismatch is recorded as an imbalance.
local function pop(k)
  local top = H.imstack[#H.imstack]
  if top ~= k then H.imbalance = ('pop %s but top is %s'):format(k, tostring(top)) end
  H.imstack[#H.imstack] = nil
end
-- Paired Begin/End style stubs: each push must be matched by its pop.
function ImGui.Begin(name) H.windows[name]=true; push('Window'); return true, true end
function ImGui.End() pop('Window') end
function ImGui.BeginTable() push('Table'); return true end
function ImGui.EndTable() pop('Table') end
function ImGui.BeginChild() push('Child'); return true end
function ImGui.EndChild() pop('Child') end
function ImGui.BeginDisabled() push('Disabled') end
function ImGui.EndDisabled() pop('Disabled') end
function ImGui.BeginTooltip() push('Tooltip') end
function ImGui.EndTooltip() pop('Tooltip') end
function ImGui.PushStyleColor() push('Color') end
function ImGui.PopStyleColor() pop('Color') end
function ImGui.GetContentRegionAvail() return 700, 500 end
-- TextUnformatted: must get a string; may inject a draw error (H.failText).
function ImGui.TextUnformatted(t)
  if type(t) ~= 'string' then error('TextUnformatted needs a string') end
  if H.failText and t:find(H.failText, 1, true) then error('injected draw error for '..t) end
  H.texts[#H.texts+1]=t
end
-- Input and hover stubs: the search box never changes, nothing is hovered.
function ImGui.InputText(l, t) return t, false end
function ImGui.IsItemHovered() return false end
local curId
-- PushID/PopID: remember the current row so Checkbox can find its click.
function ImGui.PushID(id) curId = id; push('ID') end
function ImGui.PopID() curId = nil; pop('ID') end
-- Button: true once when a test queued a press whose label starts the same.
function ImGui.Button(label)
  for i, p in ipairs(H.presses) do if label:find(p, 1, true) == 1 then table.remove(H.presses, i); H.pressed[#H.pressed+1]=label; return true end end
  return false
end
-- Checkbox: returns a queued click once, from H.checks[row id] for the Sell
-- box or H.never[row id] for the Never Sell box. H.drawn records the value
-- each row checkbox was drawn with, so tests can see what the player sees.
H.drawn = {}
function ImGui.Checkbox(label, v)
  local q = (label == '##never') and H.never or H.checks     -- which column
  if curId then H.drawn[label .. ':' .. tostring(curId)] = v end
  if curId and q[curId] ~= nil then local nv = q[curId]; q[curId] = nil; return nv, true end
  return v, false
end
-- MQ2Lua provides ImGui via require('ImGui'); the harness does the same so the
-- documented load path is exercised. bit32 is provided as in MQ2Lua.
package.preload['ImGui'] = function() H.imguiRequired = true; return ImGui end
_G.ImGui = nil
_G.bit32 = _G.bit32 or require('bit')
_G.ImGuiCol = { Text=0, Button=21 }
_G.ImGuiCond = { FirstUseEver=4, Appearing=8 }
_G.ImGuiWindowFlags = { NoCollapse=32 }
_G.ImGuiChildFlags = { Borders=1 }
_G.ImGuiTableFlags = { RowBg=64, Borders=1920, ScrollY=0x2000000, Resizable=1, SizingStretchProp=0x6000 }
_G.ImGuiTableColumnFlags = { WidthFixed=16, WidthStretch=8 }

H.pressed = {}
--[[------------------------------------------------------------------------
  H.tickFrame()

  WHAT  : One simulated frame: deliver due chat lines, draw the UI, check the
          ImGui stack is balanced, and run the next scripted step.
  WHY   : Stands in for the client's frame loop.
  WHERE : mq.delay.
  HOW   : Moves due lines into event queues, calls the render callback,
          raises on any imbalance, then runs H.steps[1] if its condition
          is true. Stops at 20000 frames so a hung test fails.
  WHEN  : Every 50 ms of fake time.
--------------------------------------------------------------------------]]
function H.tickFrame()
  H.frame = H.frame + 1
  local keep = {}
  for _, l in ipairs(H.lines) do
    if l.at <= H.now then
      for _, e in pairs(H.events) do if l.text:find(e.phrase, 1, true) then e.queue[#e.queue+1] = l.text end end
    else keep[#keep+1] = l end
  end
  H.lines = keep
  H.windows = {}; H.texts = {}
  if H.render then
    H.imstack = {}
    H.render()
    if #H.imstack > 0 then H.imbalance = 'unclosed: ' .. table.concat(H.imstack, ',') end
    if H.imbalance then error('harness: ImGui stack imbalance: ' .. H.imbalance) end
  end
  local st = H.steps[1]
  if st and st.when() then table.remove(H.steps, 1); st.act() end
  if H.frame > 20000 then error('harness: frame limit') end
end

-- quiet print capture
H.out = {}
-- print: capture console output for the checks.
_G.print = function(s) H.out[#H.out+1] = s end
return H

--[[==========================================================================
  END OF FILE : Farm_Vendor/dev/harness.lua

  PUBLIC  HARNESS (H): world, out, cmds, texts, windows, press queue,
          checks, steps, say, mkItem, exec, tickFrame, bind, render.

  HOW TO EDIT SAFELY
    - Fake only TLO members and mq functions the package really uses, with
      the same names and nil behaviour as the documented ones.
    - Keep H.exec strict: unknown commands must raise an error.
    - Run dev/run_tests.py after any change.
==========================================================================]]--
