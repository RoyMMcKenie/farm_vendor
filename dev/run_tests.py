"""
=============================================================================
  FILE        : Farm_Vendor/dev/run_tests.py
  PACKAGE     : Farm Vendor  (MacroQuest Lua / EverQuest)
  VERSION     : 1.3.0
  CHANGES     : 1.3.0  Moved from tests/ to dev/. Works from any clone
                       folder name: a temporary folder with a link (or copy)
                       named Farm_Vendor points at the package, so
                       require('Farm_Vendor.<file>') resolves exactly as in
                       MacroQuest. The sample output shows <configDir> instead of a
                       temp path. Scenario 28 reads the version from
                       config.lua instead of a fixed number. Documentation
                       added. No scenario logic changed.
                1.2.2  Title check uses 1.2.2. 31 scenarios.
                1.2.1  Scenarios 29 to 31 (ImGui load and stack balance).
                1.2.0  Rename scenarios 26 to 28. 28 scenarios.
                1.1.1  Scenarios 23 to 25 (retry, quote matching).
                1.1.0  Scenarios 18 to 22 (quote waits, refusals, unpriced).
                1.0.0  First version, 17 scenarios.

  CREDITS     : Original to Farm Vendor.

  WHAT  : Runs 31 offline scenarios against the real package files, using
          the fake MacroQuest in dev/harness.lua, and prints PASS or FAIL
          for each.

  WHY   : Proves the safety logic (preview never sends commands, only
          confirmed stacks are sold, refusals and partial sales are
          reported, files are never corrupted) after every change. It does
          NOT prove client behaviour; TESTING.md covers live checks.

  WHERE : Farm_Vendor/dev/. Needs Python 3 and the lupa package
          (pip install lupa), which embeds LuaJIT 2.1 like MQ2Lua.

  HOW   : Each scenario gets a fresh LuaJIT runtime and temp config folder,
          loads the harness, optionally writes an INI, sets config values,
          queues scripted presses, runs init.lua, then calls its check
          function. The live happy path writes dev/sample_console_output.txt.

  WHEN  : After every code change, before committing or packaging.

  USAGE : python dev/run_tests.py     (from the Farm_Vendor folder)
=============================================================================
"""
import atexit     # remove the temporary package link at exit
import os         # paths
import shutil     # temp folder cleanup and copy fallback
import sys        # exit code
import tempfile   # per scenario config folders
from lupa import luajit21   # LuaJIT 2.1 runtime, as MQ2Lua uses

# The package folder is the parent of dev/, whatever the clone is called.
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def make_lua_root():
    """
    WHAT  : Builds a temporary folder holding Farm_Vendor -> ROOT.
    WHY   : The package loads its files with require('Farm_Vendor.<file>'),
            which needs a folder named Farm_Vendor on the Lua path. A clone
            named farm_vendor or anything else would otherwise fail.
    WHERE : Called once below to set LUA_ROOT.
    HOW   : Tries a symbolic link; if the system does not allow one
            (Windows without developer mode), copies the .lua files.
    WHEN  : At start up of the test run.
    """
    base = tempfile.mkdtemp(prefix='fv_lua_')                 # holder folder
    atexit.register(shutil.rmtree, base, True)                # cleaned at exit
    link = os.path.join(base, 'Farm_Vendor')
    try:
        os.symlink(ROOT, link, target_is_directory=True)      # preferred
    except (OSError, NotImplementedError):
        os.mkdir(link)                                        # fallback: copy
        for name in os.listdir(ROOT):
            if name.endswith('.lua'):
                shutil.copy(os.path.join(ROOT, name), link)
    return base


LUA_ROOT = make_lua_root()        # folder that contains Farm_Vendor/
PKG = os.path.join(LUA_ROOT, 'Farm_Vendor')   # package as Lua sees it
results = []      # (name, passed, message) per scenario

# Lua helpers shared by every scenario: a standard bag layout and small
# helpers to queue presses and inspect output.
COMMON = r'''
H = HARNESS
W = H.world
local function bag(slot, n, items) W.packs[slot] = { bag = H.mkItem(9000+slot, 'Backpack', 1, 5, {container=n}), items = items } end
function H.std()
  bag(23, 4, { [0]=H.mkItem(13073,'Bone Chips',20,10), [1]=H.mkItem(13073,'Bone Chips',5,10),
              [2]=H.mkItem(5021,'Rusty Sword',1,50), [3]=H.mkItem(7777,'Torn Note',1,0) })
  W.packs[24] = { item = H.mkItem(10037,'Diamond',3,2000) }
  bag(25, 2, { [0]=H.mkItem(13073,'Bone Chips',10,10), [1]=H.mkItem(4444,'Quest Gem',1,100,{nodrop=true}) })
end
function H.on(when, act) H.steps[#H.steps+1] = { when = when, act = act } end
function H.press(label) H.presses[#H.presses+1] = label end
function H.textHas(s) for _, t in ipairs(H.texts) do if t:find(s,1,true) then return true end end return false end
function H.outHas(s) for _, t in ipairs(H.out) do if t:find(s,1,true) then return true end end return false end
function H.countCmd(p) local c=0 for _, x in ipairs(H.cmds) do if x:find(p,1,true)==1 then c=c+1 end end return c end
function H.stack(slot, sub) local pk=W.packs[slot]; local it = sub and pk.items[sub] or pk.item; return it and it.stack or 0 end
'''

def scenario(name, setup, check, mode=None, ini=None, cfg=None, args=(), legacy=None, expect_ui_error=False):
    """
    WHAT  : Runs one scenario and records PASS or FAIL in results.
    WHY   : Every scenario needs the same fresh, isolated set up.
    WHERE : Called once per scenario below.
    HOW   : New LuaJIT runtime, temp config folder, harness, optional INI
            files, fast timeouts, optional mode and config overrides, the
            scenario's setup Lua, then init.lua with args, then check().
            Any UI or internal error fails the scenario unless expected.
    WHEN  : 31 times per run.
    """
    d = tempfile.mkdtemp()
    lua = luajit21.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(f"package.path = [[{LUA_ROOT}/?.lua;{LUA_ROOT}/?/init.lua;]] .. package.path")
    lua.globals().HARNESS_DIR = d
    lua.execute(f"dofile([[{ROOT}/dev/harness.lua]])")
    lua.execute(COMMON)
    if ini is not None:
        open(os.path.join(d, 'Farm_Vendor_test%20server_TestMag.ini'), 'w').write(ini)
    if legacy is not None:
        open(os.path.join(d, 'magfarm_vendor_test%20server_TestMag.ini'), 'w').write(legacy)
    lua.execute("local c = require('Farm_Vendor.config'); c.SELL_TIMEOUT_MS=500; c.SELECT_TIMEOUT_MS=300; c.BETWEEN_ITEMS_DELAY_MS=0; c.COIN_SETTLE_DELAY_MS=0" )
    if mode: lua.execute(f"require('Farm_Vendor.config').SELL_MODE = '{mode}'")
    if cfg: lua.execute(cfg)
    lua.execute(setup)
    err = None
    try:
        f = lua.eval(f"loadfile([[{PKG}/init.lua]])")
        f(*args)
    except Exception as e:
        err = str(e)
    try:
        ok, msg = check(lua, d, err)
    except Exception as e:
        ok, msg = False, f'check raised {e}'
    if ok and not expect_ui_error and lua.eval("HARNESS.outHas('ui.render_error') or HARNESS.outHas('internal_error')"):
        ok, msg = False, 'UI or internal error logged'
    if not ok:
        out = '\n'.join(list(lua.globals().HARNESS.out.values())[-25:])
        msg += f"\n  err={err}\n  ---- last output ----\n{out}"
    results.append((name, ok, msg))
    if name.startswith('live: sells only'):
        # Temp folder names change every run; show a stable placeholder instead.
        open(os.path.join(ROOT,'dev','sample_console_output.txt'),'w').write('\n'.join(lua.globals().HARNESS.out.values()).replace(d, '<configDir>')+'\n')
    shutil.rmtree(d, ignore_errors=True)

def G(lua, expr):
    """
    WHAT  : Evaluates a Lua expression in the scenario's runtime.
    WHY   : Keeps the check functions short.
    WHERE : Check functions.
    HOW   : lua.eval.
    WHEN  : After each scenario ran.
    """
    return lua.eval(expr)


# A valid schema 1 INI: two checks, bag 3 protected, plus an unknown
# section that must survive every save.
INI_OK = "[Meta]\nSchema=1\n[Settings]\nProtectedBags=3\n[SelectedItems]\n13073=1\n10037=1\n[ItemNames]\n13073=Bone Chips\n10037=Diamond\n[Custom]\nKeep=me\n"

# 1 live happy path
def c1(lua, d, err):
    """
    WHAT  : Check for scenario: live: sells only checked eligible stacks, protects bag 3, verifies coin, preserves INI
    WHY   : Proves that behaviour after every change.
    WHERE : Passed to scenario() just below.
    HOW   : Reads the fake world, console output and INI after the run.
    WHEN  : Once, after its scenario finishes.
    """
    sold_bc = G(lua, "HARNESS.stack(23,0)+HARNESS.stack(23,1)")
    prot = G(lua, "HARNESS.stack(25,0)")
    dia = G(lua, "HARNESS.stack(24,nil)")
    coin = G(lua, "HARNESS.world.coin")
    ini = open(os.path.join(d,'Farm_Vendor_test%20server_TestMag.ini')).read()
    ok = err is None and sold_bc==0 and prot==10 and dia==0 and coin==25*9+3*1800 \
        and '[Custom]' in ini and 'Keep=me' in ini and '13073=1' in ini and G(lua,"HARNESS.outHas('sale.verified')") \
        and G(lua,"HARNESS.outHas('reason=Completed')") and G(lua,"HARNESS.unbound==true and HARNESS.destroyed==true")
    return ok, f"bc={sold_bc} prot={prot} dia={dia} coin={coin}"
scenario('live: sells only checked eligible stacks, protects bag 3, verifies coin, preserves INI', r'''
H.std()
H.on(function() return HARNESS.frame>2 end, function() H.press('Sell All Checked Items') end)
H.on(function() return HARNESS.windows['Confirm Sale##fv_confirm'] end, function() H.press('Confirm Sale') end)
H.on(function() return H.outHas('run.end') end, function() H.press('Cancel##fv_cancel') end)
''', c1, mode='live', ini=INI_OK)

# 2 merchant refuses -> stop policy
def c2(lua, d, err):
    """
    WHAT  : Check for scenario: live: merchant refusal stops run (ON_FAILURE=stop), later items untouched
    WHY   : Proves that behaviour after every change.
    WHERE : Passed to scenario() just below.
    HOW   : Reads the fake world, console output and INI after the run.
    WHEN  : Once, after its scenario finishes.
    """
    return (err is None and G(lua,"HARNESS.outHas('Stopped on failure')") and G(lua,"HARNESS.stack(24,nil)")==3
            and G(lua,"HARNESS.countCmd('/sellitem')")==0), 'refusal handled'
scenario('live: merchant refusal stops run (ON_FAILURE=stop), later items untouched', r'''
H.std(); HARNESS.world.refuse[13073]=true
H.on(function() return HARNESS.frame>2 end, function() H.press('Sell All Checked Items') end)
H.on(function() return HARNESS.windows['Confirm Sale##fv_confirm'] end, function() H.press('Confirm Sale') end)
H.on(function() return H.outHas('run.end') end, function() H.press('Cancel##fv_cancel') end)
''', c2, mode='live', ini=INI_OK)

# 3 skip_item policy continues with other IDs
def c3(lua, d, err):
    """
    WHAT  : Check for scenario: live: skip_item skips remaining stacks of failed ID and continues
    WHY   : Proves that behaviour after every change.
    WHERE : Passed to scenario() just below.
    HOW   : Reads the fake world, console output and INI after the run.
    WHEN  : Once, after its scenario finishes.
    """
    return (err is None and G(lua,"HARNESS.stack(24,nil)")==0 and G(lua,"HARNESS.stack(23,0)")==20
            and G(lua,"HARNESS.countCmd('/sellitem')")==1), f"sellcmds={G(lua,'HARNESS.countCmd(\"/sellitem\")')}"
scenario('live: skip_item skips remaining stacks of failed ID and continues', r'''
H.std(); HARNESS.world.refuse[13073]=true
H.on(function() return HARNESS.frame>2 end, function() H.press('Sell All Checked Items') end)
H.on(function() return HARNESS.windows['Confirm Sale##fv_confirm'] end, function() H.press('Confirm Sale') end)
H.on(function() return H.outHas('run.end') end, function() H.press('Cancel##fv_cancel') end)
''', c3, mode='live', ini=INI_OK, cfg="require('Farm_Vendor.config').ON_FAILURE='skip_item'")

# 4 inventory changed between prepare and confirm
def c4(lua, d, err):
    """
    WHAT  : Check for scenario: confirm: changed inventory rebuilds proposal and requires a second confirm
    WHY   : Proves that behaviour after every change.
    WHERE : Passed to scenario() just below.
    HOW   : Reads the fake world, console output and INI after the run.
    WHEN  : Once, after its scenario finishes.
    """
    return (err is None and G(lua,"HARNESS.outHas('sale.proposal_changed')") and G(lua,"HARNESS.stack(23,0)")==0
            and G(lua,"HARNESS.countCmd('/sellitem')")==2), 'reconfirm required'
scenario('confirm: changed inventory rebuilds proposal and requires a second confirm', r'''
H.std()
H.on(function() return HARNESS.frame>2 end, function() H.press('Sell All Checked Items') end)
H.on(function() return HARNESS.windows['Confirm Sale##fv_confirm'] end, function()
  HARNESS.world.packs[24].item = nil  -- diamonds disappear (traded away)
  H.press('Confirm Sale') end)
H.on(function() return H.outHas('sale.proposal_changed') and HARNESS.windows['Confirm Sale##fv_confirm'] end, function() H.press('Confirm Sale') end)
H.on(function() return H.outHas('run.end') end, function() H.press('Cancel##fv_cancel') end)
''', c4, mode='live', ini=INI_OK)

# 5 cursor on select -> hard stop, no sell
def c5(lua, d, err):
    """
    WHAT  : Check for scenario: live: item landing on cursor stops run before any sale
    WHY   : Proves that behaviour after every change.
    WHERE : Passed to scenario() just below.
    HOW   : Reads the fake world, console output and INI after the run.
    WHEN  : Once, after its scenario finishes.
    """
    return (err is None and G(lua,"HARNESS.countCmd('/sellitem')")==0 and G(lua,"HARNESS.outHas('cursor')")), 'cursor stop'
scenario('live: item landing on cursor stops run before any sale', r'''
H.std(); HARNESS.world.cursorOnSelect[13073]=true
H.on(function() return HARNESS.frame>2 end, function() H.press('Sell All Checked Items') end)
H.on(function() return HARNESS.windows['Confirm Sale##fv_confirm'] end, function() H.press('Confirm Sale') end)
H.on(function() return H.outHas('run.end') end, function() HARNESS.world.cursor=nil; H.press('Cancel##fv_cancel') end)
''', c5, mode='live', ini=INI_OK)

# 6 preview issues no commands
def c6(lua, d, err):
    """
    WHAT  : Check for scenario: preview (default): full workflow, zero game commands
    WHY   : Proves that behaviour after every change.
    WHERE : Passed to scenario() just below.
    HOW   : Reads the fake world, console output and INI after the run.
    WHEN  : Once, after its scenario finishes.
    """
    return (err is None and G(lua,"#HARNESS.cmds")==0 and G(lua,"HARNESS.outHas('preview.would_sell')")), f"cmds={G(lua,'#HARNESS.cmds')}"
scenario('preview (default): full workflow, zero game commands', r'''
H.std()
H.on(function() return HARNESS.frame>2 end, function() H.press('Sell All Checked Items') end)
H.on(function() return HARNESS.windows['Confirm Sale##fv_confirm'] end, function() H.press('Confirm Sale') end)
H.on(function() return H.outHas('run.end') end, function() H.press('Cancel##fv_cancel') end)
''', c6, mode='preview', ini=INI_OK)

# 7 select_test issues itemnotify only
def c7(lua, d, err):
    """
    WHAT  : Check for scenario: select_test: selects and verifies 3 stacks, never sells
    WHY   : Proves that behaviour after every change.
    WHERE : Passed to scenario() just below.
    HOW   : Reads the fake world, console output and INI after the run.
    WHEN  : Once, after its scenario finishes.
    """
    return (err is None and G(lua,"HARNESS.countCmd('/sellitem')")==0 and G(lua,"HARNESS.countCmd('/itemnotify')")==3
            and G(lua,"HARNESS.stack(23,0)")==20), f"notify={G(lua,'HARNESS.countCmd(\"/itemnotify\")')}"
scenario('select_test: selects and verifies 3 stacks, never sells', r'''
H.std()
H.on(function() return HARNESS.frame>2 end, function() H.press('Sell All Checked Items') end)
H.on(function() return HARNESS.windows['Confirm Sale##fv_confirm'] end, function() H.press('Confirm Sale') end)
H.on(function() return H.outHas('run.end') end, function() H.press('Cancel##fv_cancel') end)
''', c7, mode='select_test', ini=INI_OK)

# 8 unsupported schema -> readonly, cannot sell, file preserved
BAD = "[Meta]\nSchema=7\n[SelectedItems]\n13073=1\n"
def c8(lua, d, err):
    """
    WHAT  : Check for scenario: store: unsupported schema is read-only, preserved, and blocks selling
    WHY   : Proves that behaviour after every change.
    WHERE : Passed to scenario() just below.
    HOW   : Reads the fake world, console output and INI after the run.
    WHEN  : Once, after its scenario finishes.
    """
    ini = open(os.path.join(d,'Farm_Vendor_test%20server_TestMag.ini')).read()
    return (err is None and ini==BAD and G(lua,"#HARNESS.cmds")==0 and G(lua,"HARNESS.outHas('store.load_failed')")), 'readonly'
scenario('store: unsupported schema is read-only, preserved, and blocks selling', r'''
H.std()
H.on(function() return HARNESS.frame>2 end, function() H.press('Sell All Checked Items') end)
H.on(function() return HARNESS.frame>8 end, function() H.press('Cancel##fv_cancel') end)
''', c8, mode='live', ini=BAD)

# 9 invalid config refuses start
def c9(lua, d, err):
    """
    WHAT  : Check for scenario: config: invalid value refuses to start
    WHY   : Proves that behaviour after every change.
    WHERE : Passed to scenario() just below.
    HOW   : Reads the fake world, console output and INI after the run.
    WHEN  : Once, after its scenario finishes.
    """
    return (err is None and G(lua,"HARNESS.outHas('startup.config_invalid')") and G(lua,"HARNESS.render==nil")), 'refused'
scenario('config: invalid value refuses to start', "H.std()", c9, cfg="require('Farm_Vendor.config').SELL_TIMEOUT_MS=-5")

# 10 merchant closes mid run
def c10(lua, d, err):
    """
    WHAT  : Check for scenario: live: merchant closing mid-run stops immediately
    WHY   : Proves that behaviour after every change.
    WHERE : Passed to scenario() just below.
    HOW   : Reads the fake world, console output and INI after the run.
    WHEN  : Once, after its scenario finishes.
    """
    return (err is None and G(lua,"HARNESS.outHas('Merchant window closed')") and G(lua,"HARNESS.stack(24,nil)")==3), 'closed'
scenario('live: merchant closing mid-run stops immediately', r'''
H.std()
H.on(function() return HARNESS.frame>2 end, function() H.press('Sell All Checked Items') end)
H.on(function() return HARNESS.windows['Confirm Sale##fv_confirm'] end, function() H.press('Confirm Sale') end)
H.on(function() return H.outHas('sale.verified') end, function() HARNESS.world.merchantOpen=false end)
H.on(function() return H.outHas('run.end') end, function() H.press('Cancel##fv_cancel') end)
''', c10, mode='live', ini=INI_OK)

# 11 malformed ProtectedBags blocks selling
def c11(lua, d, err):
    """
    WHAT  : Check for scenario: settings: malformed ProtectedBags blocks selling (fail closed)
    WHY   : Proves that behaviour after every change.
    WHERE : Passed to scenario() just below.
    HOW   : Reads the fake world, console output and INI after the run.
    WHEN  : Once, after its scenario finishes.
    """
    return (err is None and G(lua,"#HARNESS.cmds")==0 and G(lua,"HARNESS.outHas('settings.protected_bags_invalid')")), 'blocked'
scenario('settings: malformed ProtectedBags blocks selling (fail closed)', r'''
H.std()
H.on(function() return HARNESS.frame>2 end, function() H.press('Sell All Checked Items') end)
H.on(function() return HARNESS.frame>8 end, function() H.press('Cancel##fv_cancel') end)
''', c11, mode='live', ini="[Meta]\nSchema=1\n[Settings]\nProtectedBags=3,x\n[SelectedItems]\n13073=1\n")

# 12 stop via bind mid-run
def c12(lua, d, err):
    """
    WHAT  : Check for scenario: live: /fvendor stop halts before the next item
    WHY   : Proves that behaviour after every change.
    WHERE : Passed to scenario() just below.
    HOW   : Reads the fake world, console output and INI after the run.
    WHEN  : Once, after its scenario finishes.
    """
    return (err is None and G(lua,"HARNESS.outHas('Stopped by operator')") and G(lua,"HARNESS.stack(24,nil)")==3), 'stopped'
scenario('live: /fvendor stop halts before the next item', r'''
H.std()
H.on(function() return HARNESS.frame>2 end, function() H.press('Sell All Checked Items') end)
H.on(function() return HARNESS.windows['Confirm Sale##fv_confirm'] end, function() H.press('Confirm Sale') end)
H.on(function() return H.outHas('sale.verified') end, function() HARNESS.bind('stop') end)
H.on(function() return H.outHas('run.end') end, function() H.press('Cancel##fv_cancel') end)
''', c12, mode='live', ini=INI_OK)

# 13 cancel with unsaved check -> no save, no commands
def c13(lua, d, err):
    """
    WHAT  : Check for scenario: cancel: unsaved checkbox change is discarded, nothing sold
    WHY   : Proves that behaviour after every change.
    WHERE : Passed to scenario() just below.
    HOW   : Reads the fake world, console output and INI after the run.
    WHEN  : Once, after its scenario finishes.
    """
    ini = open(os.path.join(d,'Farm_Vendor_test%20server_TestMag.ini')).read()
    return (err is None and ini==INI_OK and G(lua,"#HARNESS.cmds")==0 and G(lua,"HARNESS.outHas('shutdown.discarded_unsaved')")), 'cancel'
scenario('cancel: unsaved checkbox change is discarded, nothing sold', r'''
H.std()
H.on(function() return HARNESS.frame>2 end, function() HARNESS.checks[5021]=true end)
H.on(function() return HARNESS.frame>4 end, function() H.press('Cancel##fv_cancel') end)
''', c13, mode='live', ini=INI_OK)

# 14 launch arg cannot escalate; invalid arg refused
def c14(lua, d, err):
    """
    WHAT  : Check for scenario: args: 'live' launch argument is rejected
    WHY   : Proves that behaviour after every change.
    WHERE : Passed to scenario() just below.
    HOW   : Reads the fake world, console output and INI after the run.
    WHEN  : Once, after its scenario finishes.
    """
    return (err is None and G(lua,"HARNESS.outHas('startup.arg_rejected')")), 'live arg refused'
scenario('args: "live" launch argument is rejected', "H.std()", c14, args=('live',))

# 15 partial sale -> failure reported
def c15(lua, d, err):
    """
    WHAT  : Check for scenario: live: partial stack sale is reported as failure, not success
    WHY   : Proves that behaviour after every change.
    WHERE : Passed to scenario() just below.
    HOW   : Reads the fake world, console output and INI after the run.
    WHEN  : Once, after its scenario finishes.
    """
    return (err is None and G(lua,"HARNESS.outHas('Partial sale')")), 'partial'
scenario('live: partial stack sale is reported as failure, not success', r'''
H.std(); HARNESS.world.partialCap = 7
H.on(function() return HARNESS.frame>2 end, function() H.press('Sell All Checked Items') end)
H.on(function() return HARNESS.windows['Confirm Sale##fv_confirm'] end, function() H.press('Confirm Sale') end)
H.on(function() return H.outHas('run.end') end, function() H.press('Cancel##fv_cancel') end)
''', c15, mode='live', ini=INI_OK)

# 16 macro running blocks
def c16(lua, d, err):
    """
    WHAT  : Check for scenario: ownership: running macro blocks selling
    WHY   : Proves that behaviour after every change.
    WHERE : Passed to scenario() just below.
    HOW   : Reads the fake world, console output and INI after the run.
    WHEN  : Once, after its scenario finishes.
    """
    return (err is None and G(lua,"#HARNESS.cmds")==0), 'macro block'
scenario('ownership: running macro blocks selling', r'''
H.std(); HARNESS.world.macro='roy.mac'
H.on(function() return HARNESS.frame>2 end, function() H.press('Sell All Checked Items') end)
H.on(function() return HARNESS.frame>8 end, function() H.press('Cancel##fv_cancel') end)
''', c16, mode='live', ini=INI_OK)

# 17 save button writes new selection; corrupt lines warn
def c17(lua, d, err):
    """
    WHAT  : Check for scenario: save: explicit Save writes atomically with backup; malformed lines ignored
    WHY   : Proves that behaviour after every change.
    WHERE : Passed to scenario() just below.
    HOW   : Reads the fake world, console output and INI after the run.
    WHEN  : Once, after its scenario finishes.
    """
    ini = open(os.path.join(d,'Farm_Vendor_test%20server_TestMag.ini')).read()
    return (err is None and '5021=1' in ini and '5021=Rusty Sword' in ini and 'abc' not in ini and G(lua,"HARNESS.outHas('store.parse_warning')")
            and os.path.exists(os.path.join(d,'Farm_Vendor_test%20server_TestMag.ini.bak'))), ini
scenario('save: explicit Save writes atomically with backup; malformed lines ignored', r'''
H.std()
H.on(function() return HARNESS.frame>2 end, function() HARNESS.checks[5021]=true end)
H.on(function() return HARNESS.frame>4 end, function() H.press('Save Selections') end)
H.on(function() return HARNESS.frame>6 end, function() H.press('Cancel##fv_cancel') end)
''', c17, mode='live', ini="[Meta]\nSchema=1\n[SelectedItems]\n13073=1\nabc=1\n10037=2\ngarbage line\n")


# 18 regression for v1.0.0 failure: slow quote must be waited for
def c18(lua, d, err):
    """
    WHAT  : Check for scenario: regression v1.0.0: waits for a 2 s merchant quote before /sellitem
    WHY   : Proves that behaviour after every change.
    WHERE : Passed to scenario() just below.
    HOW   : Reads the fake world, console output and INI after the run.
    WHEN  : Once, after its scenario finishes.
    """
    return (err is None and G(lua,"HARNESS.premature or 0")==0 and G(lua,"HARNESS.stack(24,nil)")==0
            and G(lua,"HARNESS.stack(23,0)")==0), f"premature={G(lua,'HARNESS.premature or 0')}"
scenario('regression v1.0.0: waits for a 2 s merchant quote before /sellitem', r"""
H.std(); HARNESS.world.quoteDelay = 2000
H.on(function() return HARNESS.frame>2 end, function() H.press('Sell All Checked Items') end)
H.on(function() return HARNESS.windows['Confirm Sale##fv_confirm'] end, function() H.press('Confirm Sale') end)
H.on(function() return H.outHas('run.end') end, function() H.press('Cancel##fv_cancel') end)
""", c18, mode='live', ini=INI_OK)

# 19 refusal at selection fails fast without /sellitem
def c19(lua, d, err):
    """
    WHAT  : Check for scenario: live: 'not interested' at selection fails the item immediately, no /sellitem
    WHY   : Proves that behaviour after every change.
    WHERE : Passed to scenario() just below.
    HOW   : Reads the fake world, console output and INI after the run.
    WHEN  : Once, after its scenario finishes.
    """
    return (err is None and G(lua,"HARNESS.outHas('not interested in buying this item')") and G(lua,"HARNESS.countCmd('/sellitem')")==0), 'refusal'
scenario('live: "not interested" at selection fails the item immediately, no /sellitem', r"""
H.std(); HARNESS.world.refuse[13073]=true
H.on(function() return HARNESS.frame>2 end, function() H.press('Sell All Checked Items') end)
H.on(function() return HARNESS.windows['Confirm Sale##fv_confirm'] end, function() H.press('Confirm Sale') end)
H.on(function() return H.outHas('run.end') end, function() H.press('Cancel##fv_cancel') end)
""", c19, mode='live', ini=INI_OK)

# 20 no quote -> fail closed
def c20(lua, d, err):
    """
    WHAT  : Check for scenario: live: missing merchant quote blocks the sale (fail closed)
    WHY   : Proves that behaviour after every change.
    WHERE : Passed to scenario() just below.
    HOW   : Reads the fake world, console output and INI after the run.
    WHEN  : Once, after its scenario finishes.
    """
    return (err is None and G(lua,"HARNESS.outHas('No price quote')") and G(lua,"HARNESS.countCmd('/sellitem')")==0), 'noquote'
scenario('live: missing merchant quote blocks the sale (fail closed)', r"""
H.std(); HARNESS.world.noQuote = true
H.on(function() return HARNESS.frame>2 end, function() H.press('Sell All Checked Items') end)
H.on(function() return HARNESS.windows['Confirm Sale##fv_confirm'] end, function() H.press('Confirm Sale') end)
H.on(function() return H.outHas('run.end') end, function() H.press('Cancel##fv_cancel') end)
""", c20, mode='live', ini=INI_OK)

# 21 unpriced item excluded at merchant, remembered check kept, others sell
def c21(lua, d, err):
    """
    WHAT  : Check for scenario: exclusion: item with no merchant price is skipped, check remembered, run completes
    WHY   : Proves that behaviour after every change.
    WHERE : Passed to scenario() just below.
    HOW   : Reads the fake world, console output and INI after the run.
    WHEN  : Once, after its scenario finishes.
    """
    ini = open(os.path.join(d,'Farm_Vendor_test%20server_TestMag.ini')).read()
    return (err is None and G(lua,"HARNESS.stack(26,nil)")==1 and G(lua,"HARNESS.stack(24,nil)")==0
            and '6060=1' in ini and G(lua,"HARNESS.outHas('reason=Completed')")), ini
scenario('exclusion: item with no merchant price is skipped, check remembered, run completes', r"""
H.std(); HARNESS.world.packs[26] = { item = H.mkItem(6060,'Natural Spices',1,40,{sellPrice=0}) }
H.on(function() return HARNESS.frame>2 end, function() H.press('Sell All Checked Items') end)
H.on(function() return HARNESS.windows['Confirm Sale##fv_confirm'] end, function() H.press('Confirm Sale') end)
H.on(function() return H.outHas('run.end') end, function() H.press('Cancel##fv_cancel') end)
""", c21, mode='live', ini=INI_OK.replace('10037=1\n','10037=1\n6060=1\n'))


# 22 refusal at sell time (after a quote) is detected quickly and reported
def c22(lua, d, err):
    """
    WHAT  : Check for scenario: live: refusal after the quote is reported as a refusal, stack untouched
    WHY   : Proves that behaviour after every change.
    WHERE : Passed to scenario() just below.
    HOW   : Reads the fake world, console output and INI after the run.
    WHEN  : Once, after its scenario finishes.
    """
    return (err is None and G(lua,"HARNESS.outHas('Merchant refused the sale')") and G(lua,"HARNESS.stack(23,0)")==20), 'sell-time refusal'
scenario('live: refusal after the quote is reported as a refusal, stack untouched', r"""
H.std(); HARNESS.world.refuseAtSell = { [13073] = true }
H.on(function() return HARNESS.frame>2 end, function() H.press('Sell All Checked Items') end)
H.on(function() return HARNESS.windows['Confirm Sale##fv_confirm'] end, function() H.press('Confirm Sale') end)
H.on(function() return H.outHas('run.end') end, function() H.press('Cancel##fv_cancel') end)
""", c22, mode='live', ini=INI_OK)


# 23 one refusal after a valid quote is retried once and succeeds
def c23(lua, d, err):
    """
    WHAT  : Check for scenario: live: single refusal after a valid quote is retried once and then sells (Rune of Impetus case)
    WHY   : Proves that behaviour after every change.
    WHERE : Passed to scenario() just below.
    HOW   : Reads the fake world, console output and INI after the run.
    WHEN  : Once, after its scenario finishes.
    """
    return (err is None and G(lua,"HARNESS.outHas('sale.retry')") and G(lua,"HARNESS.stack(23,0)")==0
            and G(lua,"HARNESS.outHas('reason=Completed')")), 'retry'
scenario('live: single refusal after a valid quote is retried once and then sells (Rune of Impetus case)', r"""
H.std(); HARNESS.world.refuseOnce = { [13073] = true }
H.on(function() return HARNESS.frame>2 end, function() H.press('Sell All Checked Items') end)
H.on(function() return HARNESS.windows['Confirm Sale##fv_confirm'] end, function() H.press('Confirm Sale') end)
H.on(function() return H.outHas('run.end') end, function() H.press('Cancel##fv_cancel') end)
""", c23, mode='live', ini=INI_OK)

# 24 quote for a different item is ignored; real quote still accepted
def c24(lua, d, err):
    """
    WHAT  : Check for scenario: quotes: a quote naming a different item is ignored
    WHY   : Proves that behaviour after every change.
    WHERE : Passed to scenario() just below.
    HOW   : Reads the fake world, console output and INI after the run.
    WHEN  : Once, after its scenario finishes.
    """
    return (err is None and G(lua,"HARNESS.outHas('item.quote_other_item')") and G(lua,"HARNESS.outHas('reason=Completed')")), 'stray'
scenario('quotes: a quote naming a different item is ignored', r"""
H.std(); HARNESS.world.strayQuote = true
H.on(function() return HARNESS.frame>2 end, function() H.press('Sell All Checked Items') end)
H.on(function() return HARNESS.windows['Confirm Sale##fv_confirm'] end, function() H.press('Confirm Sale') end)
H.on(function() return H.outHas('run.end') end, function() H.press('Cancel##fv_cancel') end)
""", c24, mode='live', ini=INI_OK)

# 25 backtick name matches apostrophe in chat
def c25(lua, d, err):
    """
    WHAT  : Check for scenario: quotes: Rune of Ap`Sagor matches chat text Rune of Ap'Sagor
    WHY   : Proves that behaviour after every change.
    WHERE : Passed to scenario() just below.
    HOW   : Reads the fake world, console output and INI after the run.
    WHEN  : Once, after its scenario finishes.
    """
    return (err is None and G(lua,"HARNESS.stack(26,nil)")==0 and not G(lua,"HARNESS.outHas('quote_other_item')")), 'backtick'
scenario("quotes: Rune of Ap`Sagor matches chat text Rune of Ap'Sagor", r"""
H.std(); HARNESS.world.packs[26] = { item = H.mkItem(6061,'Rune of Ap`Sagor',2,400) }
HARNESS.world.quoteName = nil
local orig = HARNESS.exec
HARNESS.exec = function(c) if c:find('^/itemnotify 26') then HARNESS.world.quoteName = "Rune of Ap'Sagor" else HARNESS.world.quoteName = nil end return orig(c) end
H.on(function() return HARNESS.frame>2 end, function() H.press('Sell All Checked Items') end)
H.on(function() return HARNESS.windows['Confirm Sale##fv_confirm'] end, function() H.press('Confirm Sale') end)
H.on(function() return H.outHas('run.end') end, function() H.press('Cancel##fv_cancel') end)
""", c25, mode='live', ini=INI_OK.replace('10037=1\n','10037=1\n6061=1\n'))


# 26 rename: legacy magfarm_vendor INI is copied once; legacy file untouched
def c26(lua, d, err):
    """
    WHAT  : Check for scenario: rename: selections copied from magfarm_vendor INI, legacy file unchanged
    WHY   : Proves that behaviour after every change.
    WHERE : Passed to scenario() just below.
    HOW   : Reads the fake world, console output and INI after the run.
    WHEN  : Once, after its scenario finishes.
    """
    new = open(os.path.join(d,'Farm_Vendor_test%20server_TestMag.ini')).read()
    old = open(os.path.join(d,'magfarm_vendor_test%20server_TestMag.ini')).read()
    return (err is None and old==INI_OK and '13073=1' in new and G(lua,"HARNESS.outHas('startup.selections_migrated')")
            and G(lua,"HARNESS.outHas('selected=2')")), new
scenario('rename: selections copied from magfarm_vendor INI, legacy file unchanged', r"""
H.std()
H.on(function() return HARNESS.frame>3 end, function() H.press('Cancel##fv_cancel') end)
""", c26, legacy=INI_OK)

# 27 rename: existing Farm_Vendor INI is never overwritten by legacy
def c27(lua, d, err):
    """
    WHAT  : Check for scenario: rename: existing Farm_Vendor INI wins; no copy
    WHY   : Proves that behaviour after every change.
    WHERE : Passed to scenario() just below.
    HOW   : Reads the fake world, console output and INI after the run.
    WHEN  : Once, after its scenario finishes.
    """
    new = open(os.path.join(d,'Farm_Vendor_test%20server_TestMag.ini')).read()
    return (err is None and new=="[Meta]\nSchema=1\n[SelectedItems]\n5021=1\n" and not G(lua,"HARNESS.outHas('selections_migrated')")), new
scenario('rename: existing Farm_Vendor INI wins; no copy', r"""
H.std()
H.on(function() return HARNESS.frame>3 end, function() H.press('Cancel##fv_cancel') end)
""", c27, ini="[Meta]\nSchema=1\n[SelectedItems]\n5021=1\n", legacy=INI_OK)

# 28 rename: /fvendor bound and window title uses Farm Vendor
def c28(lua, d, err):
    """
    WHAT  : Check for scenario: rename: console prefix and window title use the new name
    WHY   : Proves that behaviour after every change.
    WHERE : Passed to scenario() just below.
    HOW   : Reads the fake world, console output and INI after the run.
    WHEN  : Once, after its scenario finishes.
    """
    return (err is None and G(lua,"HARNESS.outHas('[FarmVendor]')") and G(lua,"HARNESS.sawTitle==true")), 'names'
scenario('rename: console prefix and window title use the new name', r"""
H.std()
local ImGui = require('ImGui'); local B = ImGui.Begin
ImGui.Begin = function(n, ...) if n:find('Farm Vendor v' .. require('Farm_Vendor.config').VERSION,1,true)==1 then HARNESS.sawTitle=true end return B(n, ...) end
H.on(function() return HARNESS.frame>3 end, function() H.press('Cancel##fv_cancel') end)
""", c28)


# 29 ImGui loaded through the documented require('ImGui'); all pairs balanced
def c29(lua, d, err):
    """
    WHAT  : Check for scenario: standards: ImGui loaded with require('ImGui'); Begin/End pairs balanced every frame
    WHY   : Proves that behaviour after every change.
    WHERE : Passed to scenario() just below.
    HOW   : Reads the fake world, console output and INI after the run.
    WHEN  : Once, after its scenario finishes.
    """
    return (err is None and G(lua,"HARNESS.imguiRequired==true") and G(lua,"HARNESS.imbalance==nil")), 'require'
scenario("standards: ImGui loaded with require('ImGui'); Begin/End pairs balanced every frame", r"""
H.std()
H.on(function() return HARNESS.frame>3 end, function() H.press('Cancel##fv_cancel') end)
""", c29)

# 30 draw error inside a table row is logged; ImGui stack stays balanced
def c30(lua, d, err):
    """
    WHAT  : Check for scenario: standards: draw error inside a table row is logged and stacks stay balanced
    WHY   : Proves that behaviour after every change.
    WHERE : Passed to scenario() just below.
    HOW   : Reads the fake world, console output and INI after the run.
    WHEN  : Once, after its scenario finishes.
    """
    return (err is None and G(lua,"HARNESS.outHas('ui.render_error')") and G(lua,"HARNESS.imbalance==nil")), 'row error'
scenario('standards: draw error inside a table row is logged and stacks stay balanced', r"""
H.std(); HARNESS.failText = 'Bone Chips'
H.on(function() return HARNESS.frame>3 end, function() H.press('Cancel##fv_cancel') end)
""", c30, expect_ui_error=True)

# 31 draw error inside the confirm list is logged; stacks balanced
def c31(lua, d, err):
    """
    WHAT  : Check for scenario: standards: draw error inside the Confirm Sale list is logged and stacks stay balanced
    WHY   : Proves that behaviour after every change.
    WHERE : Passed to scenario() just below.
    HOW   : Reads the fake world, console output and INI after the run.
    WHEN  : Once, after its scenario finishes.
    """
    return (err is None and G(lua,"HARNESS.outHas('ui.render_error')") and G(lua,"HARNESS.imbalance==nil")), 'confirm error'
scenario('standards: draw error inside the Confirm Sale list is logged and stacks stay balanced', r"""
H.std()
H.on(function() return HARNESS.frame>2 end, function() H.press('Sell All Checked Items') end)
H.on(function() return HARNESS.windows['Confirm Sale##fv_confirm'] end, function() HARNESS.failText = '   x' end)
H.on(function() return H.outHas('ui.render_error') end, function() HARNESS.failText = nil; H.press('Cancel##fv_confirm_cancel') end)
H.on(function() return true end, function() H.press('Cancel##fv_cancel') end)
""", c31, mode='preview', ini=INI_OK, expect_ui_error=True)

p = sum(1 for r in results if r[1])
for n, ok, m in results:
    print(('PASS' if ok else 'FAIL'), n, '' if ok else '\n  '+m)
print(f"\n{p}/{len(results)} passed")
sys.exit(0 if p == len(results) else 1)

# =============================================================================
#   END OF FILE : Farm_Vendor/dev/run_tests.py
#
#   HOW TO EDIT SAFELY
#     - Add a scenario as: a check function with its doc block, then a
#       scenario(...) call. Keep scenarios independent.
#     - Never weaken a check to make it pass; fix the package instead.
#     - Update the scenario count in TESTING.md and README.md.
# =============================================================================
