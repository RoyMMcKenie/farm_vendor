# Farm Vendor: Testing

MagFarm rule: documented, then tested, then enabled. Passed checks stay passed unless the related code changes. After any change to selling code, return to `preview` or `select_test` and repeat Stages 2 and 3 before going live again.

## Offline tests

`python tests/run_tests.py` (needs `pip install lupa`) runs the real package under LuaJIT against a mock MacroQuest client (`tests/harness.lua`). The mock merchant quotes after a delay and refuses a sale sent before the quote, as the client did. The harness also fails any frame that leaves an ImGui begin/end or push/pop pair open. These tests prove program logic, not client behavior.

Result for v1.2.2: 31 of 31 passed.

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
| 2.2 Bags closed; pack9 or above | Same as 2.1 (not yet observed) |
| 2.3 Close merchant; `/fvendor stop` | Stops at once; stops before the next item |

If "Merchant did not report the expected selection" appears, save the `item.failed` log line for a reviewed fix.

Stage 3, live:

| Check | Expected |
|---|---|
| 3.1 One stack, then several items | Each `sale.verified`; coin change near the estimate |
| 3.2 Item the merchant will not buy | Fails at once ("not interested"); run stops by default |
| 3.3 Item onto the cursor mid run | Stops; the script never moves it |

## v1.2.x check (one run)

| Check | Expected |
|---|---|
| R.1 First `/lua run Farm_Vendor` | Title "Farm Vendor v1.2.2"; `startup.selections_migrated` logged on the first run only |
| R.2 Checks | Same remembered items ticked as before |
| R.3 `/fvendor show` | Window reappears |
| R.4 Normal live run | Same results as 1.1.1; no `ui.render_error` lines |
