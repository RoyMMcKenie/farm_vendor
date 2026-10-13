-- Mock MacroQuest environment for offline logic tests (NOT a client test).
local H = { log = {}, cmds = {}, presses = {}, checks = {}, frame = 0, steps = {}, now = 0 }
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
local function say(text, delay) H.lines[#H.lines+1] = { at = H.now + (delay or 0), text = text } end
H.say = say
local function mkItem(id, name, stack, value, opts)
  opts = opts or {}
  return { id=id, name=name, stack=stack, value=value, nodrop=opts.nodrop or false, lore=opts.lore or false, container=opts.container or 0, sellPrice=opts.sellPrice }
end
H.mkItem = mkItem

local function itemProxy(rec, slot, sub)
  local p = {}
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

local function locate(slot, sub)
  local pk = H.world.packs[slot]; if not pk then return nil end
  if sub == nil then return pk.item end
  return pk.items and pk.items[sub]
end

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

local mq = { TLO = TLO, configDir = HARNESS_DIR, imgui = {} }
function mq.cmd(c) H.cmds[#H.cmds+1]=c; H.exec(c) end
function mq.cmdf(f, ...) mq.cmd(string.format(f, ...)) end
function mq.bind(c, cb) H.bind = cb end
function mq.gettime() return H.now end
function mq.event(name, matcher, cb)
  local phrase = matcher:gsub('#%*#', '')
  H.events[name] = { phrase = phrase, cb = cb, queue = {} }
end
function mq.unevent(name) H.events[name] = nil end
function mq.flushevents(name) if name then if H.events[name] then H.events[name].queue = {} end else for _, e in pairs(H.events) do e.queue = {} end end end
function mq.doevents()
  for _, e in pairs(H.events) do local q = e.queue; e.queue = {}; for _, l in ipairs(q) do e.cb(l) end end
end
function mq.unbind() H.unbound = true end
function mq.imgui.init(n, cb) H.render = cb end
function mq.imgui.destroy() H.destroyed = true end
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

function H.exec(c)
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
  error('harness: unexpected command '..c)
end

-- ---------------- ImGui stub ----------------
local ImGui = {}
setmetatable(ImGui, { __index = function(_, k) return function() return nil end end })
H.texts = {}
function ImGui.Begin(name) H.windows[name]=true; return true, true end
function ImGui.BeginTable() return true end
function ImGui.BeginChild() return true end
function ImGui.GetContentRegionAvail() return 700, 500 end
function ImGui.TextUnformatted(t) H.texts[#H.texts+1]=t end
function ImGui.InputText(l, t) return t, false end
function ImGui.IsItemHovered() return false end
local curId
function ImGui.PushID(id) curId = id end
function ImGui.PopID() curId = nil end
function ImGui.Button(label)
  for i, p in ipairs(H.presses) do if label:find(p, 1, true) == 1 then table.remove(H.presses, i); H.pressed[#H.pressed+1]=label; return true end end
  return false
end
function ImGui.Checkbox(label, v)
  if curId and H.checks[curId] ~= nil then local nv = H.checks[curId]; H.checks[curId] = nil; return nv, true end
  return v, false
end
_G.ImGui = ImGui
_G.ImGuiCol = { Text=0, Button=21 }
_G.ImGuiCond = { FirstUseEver=4, Appearing=8 }
_G.ImGuiWindowFlags = { NoCollapse=32 }
_G.ImGuiChildFlags = { Borders=1 }
_G.ImGuiTableFlags = { RowBg=64, Borders=1920, ScrollY=0x2000000, Resizable=1, SizingStretchProp=0x6000 }
_G.ImGuiTableColumnFlags = { WidthFixed=16, WidthStretch=8 }

H.pressed = {}
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
  if H.render then H.render() end
  local st = H.steps[1]
  if st and st.when() then table.remove(H.steps, 1); st.act() end
  if H.frame > 20000 then error('harness: frame limit') end
end

-- quiet print capture
H.out = {}
_G.print = function(s) H.out[#H.out+1] = s end
return H
