# MagFarm Vendor

A MacroQuest Lua inventory seller built under the MagFarm engineering rules. It lists the items you carry, remembers the ones you check in a per character INI, and sells only what you confirm, one verified stack at a time.

Version 1.1.0. Live selling is off by default; see TESTING.md before enabling it.

## Install

Copy the `magfarm_vendor` folder into your active MacroQuest `lua` folder so you have `lua/magfarm_vendor/init.lua`. If you already have the folder, replace the `.lua` files only; your INI and log live in the MacroQuest config folder, not here.

Run it with:

```text
/lua run magfarm_vendor
```

No plugins are required beyond MQ2Lua, which provides Lua and ImGui.

## Use

1. Open a merchant yourself and empty your cursor.
2. Check the items you want to sell. Previously saved checks are already ticked; new items always start unchecked.
3. Optional: Save Selections to remember the checks without selling.
4. Sell All Checked Items opens the confirmation window with the exact item list, quantities and estimated proceeds.
5. Confirm Sale saves your checks, then processes each stack. Cancel in the confirmation window returns to the list with nothing saved or sold.
6. Stop Selling (or `/mfvendor stop`) stops before the next item. Completed sales cannot be undone.
7. Cancel in the main window, or the window X, exits with no action and discards unsaved changes.

Checking an item means all eligible carried copies of that item, across every bag that is not protected.

## Modes

| `config.SELL_MODE` | What happens on Confirm Sale |
|---|---|
| `preview` (default) | Logs what would be sold. No game commands. |
| `select_test` | Selects each stack in the merchant window and verifies the selection. Never sells. |
| `live` | Selects, verifies, sells with `/sellitem`, and verifies the stack left the bag. |

A launch argument can lower the mode for one session (`preview` or `selecttest`). It can never raise it to live.

## Safeguards

* Never sells on launch. Remembered checks never replace confirmation.
* Never navigates, targets, opens merchants, or moves cursor items.
* Only pack slots are read. Equipped gear, bank, shared bank and the cursor are never touched.
* Bags, protected packs, zero value items and unreadable items are excluded. NO DROP and Lore exclusions are optional settings.
* Readiness must pass before selling: in game, cursor empty, no macro running, merchant open and loaded, selections file writable, protected bag list valid.
* If inventory changed after you clicked Sell, the list is rebuilt and you confirm again.
* Before each stack: exact slot reread, same item and quantity required. Selection verified by `Merchant.SelectedItem`, then the merchant's price quote must arrive before selling. "Not interested" fails that item immediately. Sale counted only when the stack is verified gone.
* Items the open merchant gives no price for are excluded for that merchant (setting `EXCLUDE_UNPRICED_AT_MERCHANT`).
* Every wait is bounded. Failures stop the run by default; a hard cap applies in skip mode. Cursor, merchant change or close, and a macro starting always stop the run.
* The report shows measured coin change next to the estimate. Coin change includes anything else that changed your coin during the run.

## Files

| Location | Contents |
|---|---|
| `<MQ config>/magfarm_vendor_<server>_<character>.ini` | Your checks, optional `ProtectedBags=1,2`, `.bak` from the previous save |
| `<MQ config>/magfarm_vendor_<server>_<character>.log` | Structured event log, rotated to `.log.1` at the size limit |

Server and character names are percent encoded in file names. An INI with a different schema is kept read only and never overwritten.

## Configuration

All settings are in `config.lua`, each with a comment giving its purpose, range and default. Invalid values stop the script at startup with a list of what to fix.

## Commands

| Command | Effect |
|---|---|
| `/mfvendor stop` | Stop selling before the next item |
| `/mfvendor quit` | Stop if selling, then exit |
| `/mfvendor show` | Show the main window again |

## Package layout

| File | Responsibility |
|---|---|
| `init.lua` | Startup checks, request handling, main loop, shutdown |
| `config.lua` | Commented parameters and validation |
| `log.lua` | Structured console, file and Activity Log events |
| `store.lua` | INI parsing and atomic saves |
| `inventory.lua` | Read only inventory scan and coin reading |
| `seller.lua` | Readiness checks, sale proposal, guarded worker |
| `ui.lua` | ImGui windows; sets request flags only |
| `INTERFACES.md` | Every external interface and its documentation |
| `TESTING.md` | Offline results and staged client checks |

## Credit

Rewritten from the workflow of two community macros, `sellitem.mac` and `AutoVendor.mac`. Their authors retain credit for the original macros. None of their unverified commands or default sell behavior was carried over.
