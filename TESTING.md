# Farm Vendor: Test Plan

MagFarm rule: documented, then tested, then enabled. All stages passed in the client on 2026-10-13, so v1.2.0 ships in live mode. After any change to selling code, return to `preview` or `select_test` and repeat the stages before going live again. Run the stages in order and keep the results of passed checks; a later failure does not invalidate earlier passes unless the related code changed.

## Offline logic tests (already run)

`tests/run_tests.py` runs the real package under LuaJIT with a mock MacroQuest client (`tests/harness.lua`). Result for v1.2.0: 28 of 28 passed.

| # | Scenario |
|---|---|
| 1 | Live: sells only checked eligible stacks, protected bag untouched, coin change measured, unknown INI section preserved |
| 2 | Merchant refusal stops the run (`ON_FAILURE = 'stop'`); later items untouched |
| 3 | `skip_item` skips remaining stacks of the failed item and continues |
| 4 | Inventory changed between Sell and Confirm: proposal rebuilt, second confirmation required |
| 5 | Item lands on the cursor: run stops before any sale |
| 6 | Preview: full workflow with zero game commands |
| 7 | Selection test: three selections verified, no `/sellitem` |
| 8 | Unsupported INI schema: read only, file unchanged, selling blocked |
| 9 | Invalid config value: script refuses to start |
| 10 | Merchant closes mid run: immediate stop |
| 11 | Malformed `ProtectedBags`: selling blocked |
| 12 | `/fvendor stop`: halts before the next item |
| 13 | Cancel with an unsaved checkbox change: nothing saved, nothing sold |
| 14 | `live` launch argument rejected |
| 15 | Partial stack sale reported as a failure, not a success |
| 16 | Running macro blocks selling |
| 17 | Explicit Save: atomic write, `.bak` created, malformed lines ignored with warnings |
| 18 | Regression for the v1.0.0 live failure: a 2 second merchant quote is waited for; no early `/sellitem` |
| 19 | "Not interested" at selection fails the item at once, no `/sellitem` |
| 20 | No quote arrives: sale blocked (fail closed) |
| 21 | Item with no merchant price excluded while the merchant is open; remembered check kept; run completes |
| 22 | Refusal after the quote reported as a refusal; stack untouched |
| 23 | One refusal after a valid quote is retried once and then sells (Rune of Impetus case) |
| 24 | A quote naming a different item is ignored |
| 25 | Backtick item names match apostrophes in chat |
| 26 | Rename: saved checks copied from the `magfarm_vendor` INI; old file unchanged |
| 27 | Rename: an existing `Farm_Vendor` INI is never overwritten |
| 28 | Rename: new console prefix and window title |

The mock merchant now behaves like the client did on 2026-10-13: the quote arrives after a delay, and a sale sent before the quote is answered "I am not interested in buying that."

## v1.2.0 rename check (one run)

| Check | Expected |
|---|---|
| R.1 `/lua run Farm_Vendor` | Window titled Farm Vendor v1.2.0; Activity Log shows `startup.selections_migrated` on the first run only |
| R.2 Checks | The same remembered items are checked as before |
| R.3 `/fvendor show` | Window reappears; `/mfvendor` no longer exists |

## Client results so far

| Date | Version | Result |
|---|---|---|
| 2026-10-13 | 1.0.0 | Stage 1 preview passed (1.1, 1.2, 1.4, 1.6, 1.7) on Merchant Wyn\`las: 43 stacks, 168 items, no commands |
| 2026-10-13 | 1.0.0 | Live: Peridot selected and sold, coin matched estimate within 1c. Nodding Blue Lily selected, then refused ("not interested") because the sale was sent before the quote; run stopped safely |
| 2026-10-13 | manual | `/sellitem 1` then `/sellitem 41` on the selected lily sold all 42 after the quote |
| 2026-10-13 | 1.1.1 | Live: full checked list sold; reported working by Roy |
| 2026-10-13 | 1.1.0 | Live: Wax Flower, Words of Incarceration, Words of Burnishing sold and verified (13p 5g 1s). Rune of Impetus quoted, refused once, quoted again; run stopped safely |

To rerun: `pip install lupa`, then `python tests/run_tests.py` from the release folder that contains both `Farm_Vendor` and `tests`. These prove program logic only, not client behavior.

## Stage 1: Preview in the client (no game commands)

Setup: `SELL_MODE = 'preview'`. Use a low value test item, for example a stack of Bone Chips, plus one loose item in a pack slot.

| Check | Expected |
|---|---|
| 1.1 `/lua run Farm_Vendor` | Window opens, mode reads PREVIEW, Activity Log shows `startup.ready` |
| 1.2 Inventory list | Bags themselves absent; quantities and stack counts match your bags |
| 1.3 Protected bag | Add `ProtectedBags=` with one pack number to the INI, restart: items in that pack are hidden and counted as protected |
| 1.4 Check two items, Save Selections | Status shows saved; restart: both still checked |
| 1.5 Cancel with an unsaved change | Restart: that change is gone |
| 1.6 Sell All Checked Items, Confirm Sale | Confirm window lists exact items; Activity Log shows `preview.would_sell` lines; inventory unchanged |
| 1.7 Merchant open | Est. each column shows prices; closed shows Unavailable |

## Stage 2: Selection test (selects, never sells)

Setup: run `/lua run Farm_Vendor selecttest` (or set `SELL_MODE = 'select_test'`). Open a merchant yourself, empty cursor.

| Check | Expected |
|---|---|
| 2.1 Bag item, bags open | Merchant window highlights the item; merchant says "I'll give you ..."; `item.selected` and `item.quoted` in the log file; nothing on cursor |
| 2.2 Bag item, bags closed | Same as 2.1. If it fails, note it: open bags before selling is then a required step |
| 2.3 Loose item in a pack slot | Same as 2.1 |
| 2.4 Item in pack9 or higher (if you have the slots) | Same as 2.1 |
| 2.5 Close the merchant mid run | Run stops with "Merchant window closed" |
| 2.6 `/fvendor stop` mid run | Stops before the next item |

If any selection reports "Merchant did not report the expected selection", copy the `item.failed` line from the log file. That indicates the slot values reported by `Merchant.SelectedItem` differ from the scan and need a reviewed fix, not a guessed one.

## Stage 3: Live selling (enable only after Stages 1 and 2 pass)

Setup: set `SELL_MODE = 'live'` in config.lua. Start with one cheap stack.

| Check | Expected |
|---|---|
| 3.1 One full stack | Stack leaves the bag; `sale.verified` with the right quantity; coin change about equal to the estimate |
| 3.2 Two stacks of one item plus one other item | All three verified; report shows sold equals planned |
| 3.3 An item the merchant refuses | Times out, "Sale not confirmed", run stops (default policy) |
| 3.4 Non stackable item | Sold with quantity 1 |
| 3.5 Hand an item to the cursor mid run | Stops for manual handling; script never moves it |

Record pass or fail for each check with the date and the log file excerpt.
