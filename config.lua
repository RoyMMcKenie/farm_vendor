--[[
Farm_Vendor/config.lua
=========================

Purpose
-------
Every tunable parameter for Farm Vendor lives in this file, with a comment
explaining what it does, its allowed range, and why the default was chosen.
At startup, init.lua calls config.validate(); if ANY value is out of range or
the wrong type, the script refuses to start (fail closed) and prints exactly
which parameter is wrong.

Editing rules
-------------
* Change values only on the right-hand side of the `=` sign.
* Keep the quotes on text values ('preview', 'stop', etc.).
* Times are in milliseconds (1000 ms = 1 second).
* After editing, restart the script:  /lua stop Farm_Vendor
                                      /lua run Farm_Vendor

MagFarm engineering rules applied
---------------------------------
1. Documentation first: no command, TLO, member, or ImGui call is used unless it
   appears in MacroQuest or RedGuides documentation (see INTERFACES.md).
2. Documented -> tested -> enabled: live selling is OFF by default. You move
   through SELL_MODE 'preview' -> 'select_test' -> 'live' as each stage passes
   in your own client (see TESTING.md).
3. Fail closed: unknown readings, invalid settings, or failed checks block the
   action. Nothing is guessed or silently substituted.
]]

local config = {}

-- ---------------------------------------------------------------------------
-- Identity
-- ---------------------------------------------------------------------------

-- Script/package name. Used for the ImGui window IDs, the INI/log file names,
-- and console prefixes. Must match the folder name under your MacroQuest lua
-- directory so `/lua run Farm_Vendor` finds init.lua.
config.SCRIPT_NAME = 'Farm_Vendor'

-- Earlier name of this package (v1.0.0 to v1.1.1). On first run, if no
-- Farm_Vendor INI exists yet, the selections file saved under this old name is
-- COPIED (never moved or changed) so your remembered checks carry over.
-- Set to '' to disable the one-time copy. Letters, digits, underscore only.
config.LEGACY_SCRIPT_NAME = 'magfarm_vendor'

-- Version string shown in the window title and written to every log line set.
config.VERSION = '1.2.1'

-- Slash command registered with mq.bind for emergency control:
--   /fvendor stop   -> stop selling before the next item
--   /fvendor quit   -> stop selling (if active) and exit
--   /fvendor show   -> re-open the main window if it was hidden
-- Must start with '/' and contain only letters/digits after it.
config.BIND_COMMAND = '/fvendor'

-- ---------------------------------------------------------------------------
-- Selling mode (the most important safety setting)
-- ---------------------------------------------------------------------------

-- 'preview'     : Confirm Sale runs the full workflow and logs what WOULD be
--                 sold. No game commands are issued at all.
-- 'select_test' : For each queued stack, issues /itemnotify to select it in the
--                 merchant window and verifies Merchant.SelectedItem matches the
--                 exact item and bag slot. Never issues /sellitem.
-- 'live'        : Selects, verifies, then issues /sellitem <qty> and verifies
--                 the stack actually left your inventory.
-- Advance only after the previous stage passes in TESTING.md.
-- A launch argument can DOWNGRADE the mode for one session
-- (`/lua run Farm_Vendor preview` or `... selecttest`) but can never upgrade
-- it to live. Live is enabled only by editing this line.
-- Ships in 'live' because every stage passed in Roy's client on
-- 2026-10-13 (preview, then live runs; v1.1.1 completed a full checked list
-- on Merchant Wyn`las). Change back to 'preview' or 'select_test' after any
-- code change that touches selling, and re-test before returning to 'live'.
config.SELL_MODE = 'live'

-- ---------------------------------------------------------------------------
-- Failure policy
-- ---------------------------------------------------------------------------

-- What to do when one stack fails to select or sell (timeout, wrong selection,
-- partial sale, changed slot):
--   'stop'      : stop the whole run immediately (default, fail closed).
--   'skip_item' : skip every remaining stack of THAT item ID, continue others.
-- Any cursor problem, merchant change, or merchant close ALWAYS stops the run
-- regardless of this setting.
config.ON_FAILURE = 'stop'

-- Hard ceiling on total failures in one run, even in 'skip_item' mode.
-- When reached, the run stops. Range 1-50.
config.MAX_FAILURES_PER_RUN = 3

-- ---------------------------------------------------------------------------
-- Timing (milliseconds)
-- ---------------------------------------------------------------------------

-- Main loop sleep between ticks when idle. Lower = more responsive UI actions,
-- slightly more CPU. Range 50-1000.
config.LOOP_DELAY_MS = 100

-- Maximum wait for Merchant.SelectedItem to report the exact item after
-- /itemnotify. This is a timeout, not a fixed pause: the wait ends as soon as
-- the selection is confirmed. Range 250-10000.
config.SELECT_TIMEOUT_MS = 2000

-- Maximum wait for the stack to leave the bag slot after /sellitem.
-- Range 500-15000.
config.SELL_TIMEOUT_MS = 4000

-- Maximum wait, after the selection is verified, for the merchant's price
-- quote chat line ("<merchant> told you, 'I'll give you ...'"). The client
-- must receive this quote before a sale is accepted; selling earlier produced
-- "I am not interested in buying that." in the first live test (v1.0.0).
-- The wait ends as soon as the quote or a refusal arrives. Range 500-10000.
config.QUOTE_TIMEOUT_MS = 3000

-- Extra pause after the quote arrives and before /sellitem, so the client has
-- applied the quote. Raised from 150 to 500 after Rune of Impetus was refused
-- once right after a valid quote (v1.1.0 live test). Range 0-3000.
config.POST_QUOTE_DELAY_MS = 500

-- How many times to retry a sale the merchant refused AFTER it had sent a
-- valid quote for that exact item (the item is re-selected and re-quoted
-- first). Refusals with no quote are never retried. 0 disables. Range 0-2.
config.SELL_REFUSAL_RETRIES = 1

-- Wait before such a retry. Range 250-5000.
config.RETRY_DELAY_MS = 1000

-- Pause after each verified sale/selection before the next one. Gives the
-- client and server time to settle and keeps the pace human-like. Range 0-5000.
config.BETWEEN_ITEMS_DELAY_MS = 350

-- After the run ends, wait this long before reading coin totals so the coin
-- display has caught up with the last sale. Range 0-5000.
config.COIN_SETTLE_DELAY_MS = 750

-- ---------------------------------------------------------------------------
-- Inventory scanning and eligibility
-- ---------------------------------------------------------------------------

-- Top-level inventory slot numbers scanned (bags and loose items).
-- From the MacroQuest Slot Names reference: 23 = pack1 ... 34 = pack12.
-- Equipped slots (0-22), bank, shared bank, cursor (35) are NEVER scanned.
-- Range must stay within 23-34.
config.FIRST_PACK_SLOT = 23
config.LAST_PACK_SLOT  = 34

-- Pack numbers (1-12) whose contents are NEVER listed or sold, no matter what
-- is checked. Example: { 1, 2 } protects pack1 and pack2.
-- A per-character override can be set in the INI ([Settings] ProtectedBags=1,2).
-- If the INI value is malformed, selling is BLOCKED rather than ignored.
config.DEFAULT_PROTECTED_BAGS = { }

-- true  : items whose base Value is 0 copper are shown as excluded
--         ("No merchant value") and cannot be checked. Merchants do not pay
--         for them, so selling attempts would only fail.
-- false : such items are listed like any other.
config.EXCLUDE_ZERO_VALUE = true

-- true  : NO DROP / NO TRADE items are excluded (cannot be checked).
-- false : they are listed with an "ND" flag so you can decide per item.
-- Many NO DROP items are sellable to merchants, so the default lists them;
-- nothing is ever sold unless you check it AND confirm.
config.EXCLUDE_NO_DROP = false

-- true  : Lore items are excluded. false: listed with an "L" flag.
config.EXCLUDE_LORE = false

-- true  : while a merchant is open, items for which that merchant reports no
--         sell price (Item.SellPrice is 0 or unavailable) are excluded as
--         "Merchant offers no price". In the first live test the only item
--         showing "Unavailable" (Natural Spices) is the kind the merchant
--         refuses. Your remembered check is kept; the item is just not sold
--         to THIS merchant.
-- false : list them anyway (a refusal is then detected and handled at sale time).
config.EXCLUDE_UNPRICED_AT_MERCHANT = true

-- Chat text the merchant sends. These are the exact phrases seen in the
-- EverQuest client on 2026-10-13; they are matched with documented mq.event
-- matcher wildcards (#*#). Change only if your client shows different text.
config.QUOTE_PHRASE   = "told you, 'I'll give you "
config.REFUSAL_PHRASE = "told you, 'I am not interested in buying that.'"

-- ---------------------------------------------------------------------------
-- Persistence (INI)
-- ---------------------------------------------------------------------------

-- Schema version written to [Meta] Schema=. Files with a different schema are
-- loaded read-only and never overwritten (your data is preserved).
config.INI_SCHEMA = 1

-- Reject INI files larger than this many bytes (corruption guard).
-- Range 1024-4194304.
config.INI_MAX_BYTES = 1048576

-- Maximum stored item-name length (longer names are truncated on save).
-- Range 16-256.
config.MAX_ITEM_NAME_LENGTH = 128

-- ---------------------------------------------------------------------------
-- Logging
-- ---------------------------------------------------------------------------

-- Minimum level printed to the MacroQuest console: 'DEBUG','INFO','WARN','ERROR'
config.CONSOLE_LOG_LEVEL = 'INFO'

-- Minimum level written to the log file.
config.FILE_LOG_LEVEL = 'DEBUG'

-- true writes a structured log file next to the INI under mq.configDir:
--   Farm_Vendor_<server>_<character>.log
config.FILE_LOG_ENABLED = true

-- When the log file exceeds this size it is rotated to .log.1 (one backup).
-- Range 65536-10485760.
config.LOG_MAX_BYTES = 1048576

-- Number of recent events kept in the in-window Activity Log. Range 20-1000.
config.UI_LOG_LINES = 200

-- ---------------------------------------------------------------------------
-- User interface
-- ---------------------------------------------------------------------------

-- Initial main-window size in pixels (first use only; ImGui remembers after).
config.WINDOW_WIDTH  = 760
config.WINDOW_HEIGHT = 620

-- Maximum characters accepted in the Search box. Range 8-128.
config.SEARCH_MAX_LENGTH = 64

-- Height in pixels of the Activity Log panel. Range 60-600.
config.ACTIVITY_LOG_HEIGHT = 140

-- ===========================================================================
-- Validation (do not edit below unless you are changing the program)
-- ===========================================================================

local LEVELS = { DEBUG = true, INFO = true, WARN = true, ERROR = true }

local function isInt(v) return type(v) == 'number' and v == math.floor(v) end

--- Rules table: each entry validates one parameter and returns an error string
--- when invalid, or nil when valid.
local RULES = {
    SCRIPT_NAME = function(v)
        if type(v) ~= 'string' or not v:match('^[%w_]+$') then
            return 'must be letters, digits or underscore'
        end
    end,
    LEGACY_SCRIPT_NAME = function(v)
        if type(v) ~= 'string' or (v ~= '' and not v:match('^[%w_]+$')) then
            return "must be '' or letters, digits or underscore"
        end
    end,
    VERSION = function(v) if type(v) ~= 'string' or v == '' then return 'must be a non-empty string' end end,
    BIND_COMMAND = function(v)
        if type(v) ~= 'string' or not v:match('^/[%a][%w]*$') then
            return "must look like '/name' (letters/digits only)"
        end
    end,
    SELL_MODE = function(v)
        if v ~= 'preview' and v ~= 'select_test' and v ~= 'live' then
            return "must be 'preview', 'select_test' or 'live'"
        end
    end,
    ON_FAILURE = function(v)
        if v ~= 'stop' and v ~= 'skip_item' then return "must be 'stop' or 'skip_item'" end
    end,
    CONSOLE_LOG_LEVEL = function(v) if not LEVELS[v] then return 'must be DEBUG, INFO, WARN or ERROR' end end,
    FILE_LOG_LEVEL    = function(v) if not LEVELS[v] then return 'must be DEBUG, INFO, WARN or ERROR' end end,
    FILE_LOG_ENABLED   = function(v) if type(v) ~= 'boolean' then return 'must be true or false' end end,
    EXCLUDE_ZERO_VALUE = function(v) if type(v) ~= 'boolean' then return 'must be true or false' end end,
    EXCLUDE_NO_DROP    = function(v) if type(v) ~= 'boolean' then return 'must be true or false' end end,
    EXCLUDE_LORE       = function(v) if type(v) ~= 'boolean' then return 'must be true or false' end end,
    EXCLUDE_UNPRICED_AT_MERCHANT = function(v) if type(v) ~= 'boolean' then return 'must be true or false' end end,
    QUOTE_PHRASE = function(v)
        if type(v) ~= 'string' or #v < 8 or v:find('#', 1, true) then return 'must be text of 8+ characters without #' end
    end,
    REFUSAL_PHRASE = function(v)
        if type(v) ~= 'string' or #v < 8 or v:find('#', 1, true) then return 'must be text of 8+ characters without #' end
    end,
    DEFAULT_PROTECTED_BAGS = function(v)
        if type(v) ~= 'table' then return 'must be a list such as { 1, 2 }' end
        for i, n in ipairs(v) do
            if not isInt(n) or n < 1 or n > 12 then
                return ('entry %d must be a whole number from 1 to 12'):format(i)
            end
        end
    end,
}

--- Integer range rules: name -> {min, max}
local RANGES = {
    MAX_FAILURES_PER_RUN   = { 1, 50 },
    LOOP_DELAY_MS          = { 50, 1000 },
    SELECT_TIMEOUT_MS      = { 250, 10000 },
    SELL_TIMEOUT_MS        = { 500, 15000 },
    BETWEEN_ITEMS_DELAY_MS = { 0, 5000 },
    COIN_SETTLE_DELAY_MS   = { 0, 5000 },
    QUOTE_TIMEOUT_MS       = { 500, 10000 },
    POST_QUOTE_DELAY_MS    = { 0, 3000 },
    SELL_REFUSAL_RETRIES   = { 0, 2 },
    RETRY_DELAY_MS         = { 250, 5000 },
    FIRST_PACK_SLOT        = { 23, 34 },
    LAST_PACK_SLOT         = { 23, 34 },
    INI_SCHEMA             = { 1, 1 },
    INI_MAX_BYTES          = { 1024, 4194304 },
    MAX_ITEM_NAME_LENGTH   = { 16, 256 },
    LOG_MAX_BYTES          = { 65536, 10485760 },
    UI_LOG_LINES           = { 20, 1000 },
    WINDOW_WIDTH           = { 400, 3000 },
    WINDOW_HEIGHT          = { 300, 2000 },
    SEARCH_MAX_LENGTH      = { 8, 128 },
    ACTIVITY_LOG_HEIGHT    = { 60, 600 },
}

--- Validate every parameter.
--- @return boolean ok
--- @return string[] errors  human-readable messages, empty when ok
function config.validate()
    local errors = {}
    for name, rule in pairs(RULES) do
        local msg = rule(config[name])
        if msg then errors[#errors + 1] = ('config.%s %s (current: %s)'):format(name, msg, tostring(config[name])) end
    end
    for name, range in pairs(RANGES) do
        local v = config[name]
        if not isInt(v) or v < range[1] or v > range[2] then
            errors[#errors + 1] = ('config.%s must be a whole number from %d to %d (current: %s)')
                :format(name, range[1], range[2], tostring(v))
        end
    end
    if isInt(config.FIRST_PACK_SLOT) and isInt(config.LAST_PACK_SLOT)
        and config.FIRST_PACK_SLOT > config.LAST_PACK_SLOT then
        errors[#errors + 1] = 'config.FIRST_PACK_SLOT must not be greater than config.LAST_PACK_SLOT'
    end
    table.sort(errors)
    return #errors == 0, errors
end

--- Ordering used to decide whether a launch argument is a downgrade.
config.MODE_RANK = { preview = 1, select_test = 2, live = 3 }

--- Map accepted launch arguments to modes. 'live' is intentionally absent.
config.MODE_ARGS = { preview = 'preview', selecttest = 'select_test', select_test = 'select_test' }

return config
