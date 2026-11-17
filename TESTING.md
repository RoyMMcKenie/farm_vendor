<!--
  FILE    : Farm_Vendor/TESTING.md
  PACKAGE : Farm Vendor Lua (MacroQuest / EverQuest)
  VERSION : 1.4.0
  WHAT    : Offline tests, the client results so far, and the staged client
            checks to repeat after any change to selling code.
  WHY     : Program logic is proven offline; client behaviour only in game.
  WHERE   : Package root; the tests themselves are in dev/.
  WHEN    : Run the offline tests before every commit; repeat the client
            stages after any change to engine.lua/seller.
-->
# Farm Vendor testing

Rule: documented, then tested, then enabled. Passed checks stay passed unless the related code changes. After any change to selling code, return to `preview` or `select_test` and repeat Stages 2 and 3 before going live again.

## Offline tests

`python3 dev/run_tests.py` (needs `pip install lupa`) runs the real package under LuaJIT against a mock MacroQuest client (`dev/harness.lua`). It works from any folder name. `python3 dev/doc_audit.py` checks the documentation standard (headers, footers, function blocks, line comments, versions). `dev/sample_console_output.txt` shows a passing run. The mock merchant quotes after a delay and refuses a sale sent before the quote, as the client did. The harness also fails any frame that leaves an ImGui begin/end or push/pop pair open. These tests prove program logic, not client behavior.

Result for v1.4.0: 37 of 37 passed. doc_audit: all five Lua files pass. Each of the new scenarios 32 to 37 was also run against a copy with its guard removed, and failed as it should.

| Area | Scenarios |
|---|---|
| Selling | Only checked eligible stacks sold, protected bag untouched, coin measured (1); partial stack is a failure (15); waits for a slow quote (18); refusal at selection (19), no quote (20), refusal after quote (22); one retry then sells (23) |
| Failure policy | Stop (2), skip item (3), cursor item (5), merchant closes (10), `/fvendor stop` (12), macro running (16) |
| Confirmation | Inventory change forces reconfirm (4); Cancel discards changes (13) |
| Modes | Preview issues no commands (6); select test never sells (7); `live` launch argument rejected (14) |
| Files and config | Unsupported INI schema read only (8); invalid config refuses to start (9); bad `ProtectedBags` blocks selling (11); atomic save with backup (17) |
| Quotes | Unpriced item excluded (21); quote for another item ignored (24); backtick matches apostrophe (25) |
| Rename | Old INI copied once, unchanged (26); existing new INI never overwritten (27); new prefix and title (28) |
| Standards | `require('ImGui')` path and balanced pairs (29); draw error in a table row (30) or the confirm list (31) logged with stacks balanced |
| Never Sell, Select All (1.4.0) | Ticking saves at once, drops the check, item not sold (32); loaded from the INI, wins over a check in the file, survives Select All and a click on Sell (33); Select All checks listed eligible rows only and neither Select All nor Clear Checks changes Never Sell (34); manual untick removes it at once without saving unsaved checks (35); sale list guard (36); read only file fails safely (37) |

## Client results

| Date | Version | Result |
|---|---|---|
| 2026-10-13 | 1.0.0 | Preview: 43 stacks, 168 items, no commands |
| 2026-10-13 | 1.0.0 | Live: Peridot sold, coin within 1c. Nodding Blue Lily refused because the sale preceded the quote; stopped safely |
| 2026-10-13 | manual | `/sellitem` after the quote sold the lily |
| 2026-10-13 | 1.1.0 | Live: three items sold (13p 5g 1s). Rune of Impetus refused once right after its quote; stopped safely |
| 2026-10-13 | 1.1.1 | Live: full checked list sold |

## Client stages

Use a cheap test item plus one loose item in a pack slot. Record the date and the log line for each check.

Stage 1, preview (`SELL_MODE = 'preview'`):

| Check | Expected |
|---|---|
| 1.1 Start | Window opens in PREVIEW; log shows `startup.ready` |
| 1.2 List | No bags listed; quantities match your bags |
| 1.3 `ProtectedBags=` one pack, restart | That pack's items hidden and counted as protected |
| 1.4 Save two checks, restart | Both still checked; an unsaved change is gone |
| 1.5 Sell, Confirm | `preview.would_sell` lines; inventory unchanged; prices shown only with a merchant open |

Stage 2, selection test (`/lua run Farm_Vendor selecttest`):

| Check | Expected |
|---|---|
| 2.1 Bag item, loose item | Highlighted in the merchant window, merchant quotes, `item.quoted` logged, cursor empty |
| 2.2 Bags closed | MacroQuest picks the item up onto the cursor instead of clicking the slot (MQ2Windows.cpp, see AUDIT.md). Expected: run stops with "Item went to the cursor"; put the item back yourself. Not yet observed |
| 2.3 Item in pack9 or above | Same as 2.1. Supported by the MacroQuest source; not yet observed |
| 2.4 Close merchant; `/fvendor stop` | Stops at once; stops before the next item |

If "Merchant did not report the expected selection" appears, save the `item.failed` log line for a reviewed fix.

Stage 3, live:

| Check | Expected |
|---|---|
| 3.1 One stack, then several items | Each `sale.verified`; coin change near the estimate |
| 3.2 Item the merchant will not buy | Fails at once ("not interested"); run stops by default |
| 3.3 Item onto the cursor mid run | Stops; the script never moves it |

## v1.4.0 check (Never Sell and Select All)

Selling code is unchanged, but the window and the INI changed, so run these in `preview`, then `selecttest`, before live.

| Check | Expected |
|---|---|
| N.1 Start | Title "Farm Vendor v1.4.0"; table shows a Never Sell column |
| N.2 Tick Never Sell on a checked item | Its Sell box unticks and greys out; Notes says Never Sell; log `neversell.saved` |
| N.3 Cancel, start again | That item is still Never Sell; the INI has it under `[NeverSell]` |
| N.4 Select All | Every listed sellable item checked except Never Sell items |
| N.5 Clear Checks | Checks removed; Never Sell boxes unchanged |
| N.6 Sell All Checked Items, Confirm (preview, then selecttest) | Never Sell items are not in the Confirm list and are never selected |
| N.7 Untick Never Sell | Sell box usable again; log `neversell.saved` |

## v1.3.0 check (one run)

1.3.0 changes no selling logic, so passed checks stay passed. One run confirms the new files load.

| Check | Expected |
|---|---|
| C.1 Remove the old 1.2.x files, then `/lua run Farm_Vendor` | Title "Farm Vendor v1.3.0"; `startup.ready` logged; no load errors |
| C.2 Checks | Same remembered items ticked as before |
| C.3 `/fvendor show`, `/fvendor stop` | Window reappears; stop works while selling |
| C.4 Normal live run | Same results as 1.2.2; no `ui.render_error` lines |

<!-- END OF FILE: Farm_Vendor/TESTING.md -->
