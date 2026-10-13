# Farm Vendor

A MacroQuest Lua inventory seller. It lists what you carry, remembers the items you check in a per character INI, and sells only what you confirm, one verified stack at a time. Built under the MagFarm engineering rules: documented interfaces only, fail closed, staged testing.

Version 1.2.1. Validated live in the client on 2026-10-13; ships in live mode.

## Install and run

Copy the `Farm_Vendor` folder into your MacroQuest `lua` folder (`lua/Farm_Vendor/init.lua`), then:

```text
/lua run Farm_Vendor
```

Only MQ2Lua is required (it provides Lua and ImGui).

Upgrading from `magfarm_vendor`: the first run copies your saved checks from the old INI (log line `startup.selections_migrated`). The old file is never changed. Once your checks appear, you can delete `lua/magfarm_vendor`.

## Use

1. Open a merchant yourself and empty your cursor.
2. Check the items to sell. Saved checks are pre ticked; new items start unchecked.
3. Sell All Checked Items opens a confirmation window with the exact items, quantities and estimate.
4. Confirm Sale saves your checks and sells each stack. Cancel there returns with nothing saved or sold.
5. Stop Selling or `/fvendor stop` stops before the next item. Completed sales cannot be undone.
6. Cancel or the window X exits and discards unsaved changes.

A checked item means every eligible carried copy, in every unprotected bag.

## Modes

| `config.SELL_MODE` | Confirm Sale does |
|---|---|
| `preview` | Logs what would be sold. No game commands. |
| `select_test` | Selects each stack and waits for the merchant quote. Never sells. |
| `live` (shipped) | Selects, waits for the quote, sells with `/sellitem`, verifies the stack left the bag. |

A launch argument (`preview` or `selecttest`) can lower the mode for one session, never raise it.

## Commands

| Command | Effect |
|---|---|
| `/fvendor stop` | Stop before the next item |
| `/fvendor quit` | Stop if selling, then exit |
| `/fvendor show` | Show the window again |

## Safeguards

* Never sells on launch, never navigates, targets, opens merchants or moves cursor items.
* Reads pack slots only. Bags, protected packs, zero value and unreadable items are excluded; NO DROP and Lore exclusions are optional. Items the open merchant will not price are skipped for that merchant.
* Selling requires: in game, empty cursor, no macro running, merchant open and loaded, writable selections file, valid protected bag list.
* Inventory changed after Sell: the list is rebuilt and you confirm again.
* Per stack: slot reread, selection verified by `Merchant.SelectedItem`, merchant quote for that item required, sale counted only when the stack is gone. One retry if the merchant refuses right after a valid quote.
* All waits are bounded. Failures stop the run by default. Cursor items, merchant change or close, and a macro starting always stop it.
* The report shows measured coin change beside the estimate.

## Files

| Location | Contents |
|---|---|
| `<MQ config>/Farm_Vendor_<server>_<character>.ini` | Checks, optional `ProtectedBags=1,2`, `.bak` of the previous save |
| `<MQ config>/Farm_Vendor_<server>_<character>.log` | Structured log, rotated to `.log.1` |

All settings are in `config.lua`, each commented with purpose, range and default. Invalid values stop startup with a list of what to fix.

## Package

| File | Role |
|---|---|
| `init.lua` | Startup, request handling, main loop, shutdown |
| `config.lua` | Parameters and validation |
| `log.lua` | Console, file and Activity Log events |
| `store.lua` | INI parsing and atomic saves |
| `inventory.lua` | Read only inventory and coin scan |
| `seller.lua` | Readiness, proposal, guarded selling worker |
| `ui.lua` | ImGui windows; sets request flags only |
| `INTERFACES.md` | Every external interface and its documentation |
| `TESTING.md` | Offline tests and client stages |
| `CHANGELOG.md` | Version history |

## Credits

Farm Vendor is a new Lua program, but its workflow comes from two community macros. Thanks to their authors:

* **sellitem.mac**, bulk selling of one named item. Published on RedGuides as [Sellitem.mac by Cannonballdex](https://www.redguides.com/community/resources/authors/cannonballdex.233812/) (2021, updated 2023). Its select then sell loop follows the pattern in [Super Simple Sell Items Macro by sl968](https://www.redguides.com/community/threads/super-simple-sell-items-macro.70441/) (2019).
* **AutoVendor.mac**, an INI sell list built from your inventory. [AutoVendor 3.6 by Ionis](https://www.redguides.com/community/resources/autovendor.1930/) on RedGuides ([release thread](https://www.redguides.com/community/threads/autovendor.75143/)).

The macro copies used for this rewrite were not kept, so these credits point to the published versions they match. If your copy names a different author in its header, credit that author instead. No code was copied: Farm Vendor reuses the ideas (a remembered sell list, then select and sell each stack) and replaces the commands with documented MacroQuest interfaces.

Also thanks to the [MacroQuest](https://docs.macroquest.org/) developers, the [mq-definitions](https://github.com/macroquest/mq-definitions) project used to verify every Lua and ImGui call, and [RedGuides](https://www.redguides.com/docs/) for its command reference.
