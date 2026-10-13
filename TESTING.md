# MagFarm Vendor: Test Plan

MagFarm rule: documented, then tested, then enabled. Live selling stays off (`config.SELL_MODE = 'preview'`) until Stages 1 and 2 pass in your client. Run the stages in order and keep the results of passed checks; a later failure does not invalidate earlier passes unless the related code changed.

## Offline logic tests (already run)

`tests/run_tests.py` runs the real package under LuaJIT with a mock MacroQuest client (`tests/harness.lua`). Result at release: 17 of 17 passed.

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
| 12 | `/mfvendor stop`: halts before the next item |
| 13 | Cancel with an unsaved checkbox change: nothing saved, nothing sold |
| 14 | `live` launch argument rejected |
| 15 | Partial stack sale reported as a failure, not a success |
| 16 | Running macro blocks selling |
| 17 | Explicit Save: atomic write, `.bak` created, malformed lines ignored with warnings |

To rerun: `pip install lupa`, then `python tests/run_tests.py` from the release folder that contains both `magfarm_vendor` and `tests`. These prove program logic only, not client behavior.

## Stage 1: Preview in the client (no game commands)

Setup: `SELL_MODE = 'preview'`. Use a low value test item, for example a stack of Bone Chips, plus one loose item in a pack slot.

| Check | Expected |
|---|---|
| 1.1 `/lua run magfarm_vendor` | Window opens, mode reads PREVIEW, Activity Log shows `startup.ready` |
| 1.2 Inventory list | Bags themselves absent; quantities and stack counts match your bags |
| 1.3 Protected bag | Add `ProtectedBags=` with one pack number to the INI, restart: items in that pack are hidden and counted as protected |
| 1.4 Check two items, Save Selections | Status shows saved; restart: both still checked |
| 1.5 Cancel with an unsaved change | Restart: that change is gone |
| 1.6 Sell All Checked Items, Confirm Sale | Confirm window lists exact items; Activity Log shows `preview.would_sell` lines; inventory unchanged |
| 1.7 Merchant open | Est. each column shows prices; closed shows Unavailable |

## Stage 2: Selection test (selects, never sells)

Setup: run `/lua run magfarm_vendor selecttest` (or set `SELL_MODE = 'select_test'`). Open a merchant yourself, empty cursor.

| Check | Expected |
|---|---|
| 2.1 Bag item, bags open | Merchant window highlights the item; `item.selected` in the log file; nothing on cursor |
| 2.2 Bag item, bags closed | Same as 2.1. If it fails, note it: open bags before selling is then a required step |
| 2.3 Loose item in a pack slot | Same as 2.1 |
| 2.4 Item in pack9 or higher (if you have the slots) | Same as 2.1 |
| 2.5 Close the merchant mid run | Run stops with "Merchant window closed" |
| 2.6 `/mfvendor stop` mid run | Stops before the next item |

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
