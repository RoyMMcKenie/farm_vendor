<!--
  FILE    : Farm_Vendor/README.md
  PACKAGE : Farm Vendor Lua (MacroQuest / EverQuest)
  VERSION : 1.4.0
  WHAT    : What Farm Vendor does, how to install and run it, the modes,
            commands and safeguards, the package layout and the credits.
  WHY     : First thing to read before running or editing the package.
  WHERE   : Package root. ARCHITECTURE.md covers the code, AUDIT.md every
            external interface, TESTING.md the tests, CHANGELOG.md versions.
  WHEN    : Read before first use; update when behaviour or commands change.
-->
# Farm Vendor 1.4.0

A MacroQuest Lua inventory seller. It lists what you carry, remembers the items you check in a per character INI, and sells only what you confirm, one verified stack at a time. It uses documented interfaces only, fails closed, and is tested in stages.

Version 1.4.0 adds Select All and a persistent Never Sell checkbox. The selling, selection and quote code is unchanged from 1.2.2, which was validated live in the client on 2026-10-13. Run 1.4.0 in `preview` and `selecttest` before live (TESTING.md, v1.4.0 check). It ships in live mode.

## Install and run

Copy this folder into your MacroQuest `lua` folder as `lua/Farm_Vendor` (so the entry point is `lua/Farm_Vendor/init.lua`), then:

```text
/lua run Farm_Vendor
```

If you clone the repository, the folder is named `farm_vendor`. Windows ignores case, so that works as is; on any other system rename it to `Farm_Vendor`. The `dev/` folder is only for offline testing and can be left out of the game install.

Only MQ2Lua is required (it provides Lua and ImGui).

Upgrading from `magfarm_vendor`: the first run copies your saved checks from the old INI (log line `startup.selections_migrated`). The old file is never changed. Once your checks appear, you can delete `lua/magfarm_vendor`. Upgrading from 1.2.x: delete the old `log.lua`, `store.lua`, `inventory.lua` and `seller.lua` files, which are now sections inside `core.lua` and `engine.lua`. Your INI is unchanged.

## Use

1. Open a merchant yourself, open your bags, and empty your cursor.
2. Check the items to sell, or press Select All to check every listed item that can be sold. Saved checks are pre ticked; new items start unchecked.
3. Tick Never Sell on anything you want to keep. See "Never Sell" below.
4. Sell All Checked Items opens a confirmation window with the exact items, quantities and estimate.
5. Confirm Sale saves your checks and sells each stack. Cancel there returns with nothing saved or sold.
6. Stop Selling or `/fvendor stop` stops before the next item. Completed sales cannot be undone.
7. Cancel or the window X exits and discards unsaved changes.

A checked item means every eligible carried copy, in every unprotected bag.

## Never Sell

* A Never Sell item cannot be checked or sold. Its Sell box is greyed out and the Notes column says Never Sell.
* It is saved to the INI the moment you tick it, so it stays after Cancel or a restart.
* Only unticking the box yourself removes it. Select All and Clear Checks never change it.
* The sale list leaves Never Sell items out even if one is checked by hand in the INI.
* To remove Never Sell from an item you no longer carry, carry it again and untick the box, or delete its line under `[NeverSell]` in the INI while the script is not running.

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
| `/fvendor stop` | Pause control: stop before the next item |
| `/fvendor quit` | Stop if selling, then exit |
| `/fvendor show` | Show the window again |

## Safeguards

* Never Sell items are never checked or sold, and only a manual untick removes the protection.
* Never sells on launch, never navigates, targets, opens merchants or moves cursor items.
* Reads pack slots only. Bags, protected packs, zero value and unreadable items are excluded; NO DROP and Lore exclusions are optional. Items the open merchant will not price are skipped for that merchant.
* Selling requires: in game, empty cursor, no macro running, merchant open and loaded, writable selections file, valid protected bag list.
* Inventory changed after Sell: the list is rebuilt and you confirm again.
* Per stack: slot reread, selection verified by `Merchant.SelectedItem`, merchant quote for that item required, sale counted only when the stack is gone. One retry if the merchant refuses right after a valid quote.
* If a selection puts the item on the cursor (MacroQuest does this when the bag is closed), the run stops and the item is left for you.
* All waits are bounded. Failures stop the run by default. Cursor items, merchant change or close, and a macro starting always stop it.
* The report shows measured coin change beside the estimate.

## Files written

| Location | Contents |
|---|---|
| `<MQ config>/Farm_Vendor_<server>_<character>.ini` | Checks, Never Sell items, optional `ProtectedBags=1,2`, `.bak` of the previous save |
| `<MQ config>/Farm_Vendor_<server>_<character>.log` | Structured log, rotated to `.log.1` |

All settings are in `config.lua`, each commented with purpose, range and default. Invalid values stop startup with a list of what to fix.

## Package

| File | Role |
|---|---|
| `init.lua` | Startup, request handling, main loop, shutdown |
| `config.lua` | Parameters and validation |
| `core.lua` | `log` section (console, file and Activity Log events) and `store` section (INI parsing and atomic saves) |
| `engine.lua` | `inventory` section (read only inventory and coin scan) and `seller` section (readiness, proposal, guarded selling worker) |
| `ui.lua` | ImGui windows; sets request flags only |
| `dev/` | Offline tests (`run_tests.py`, `harness.lua`), documentation checker (`doc_audit.py`), sample output |
| `ARCHITECTURE.md` | How the code is organised and the documentation standard |
| `AUDIT.md` | Every external interface and the source that defines it |
| `TESTING.md` | Offline tests and client stages |
| `CHANGELOG.md` | Version history |
| `LICENSE` | MIT license and third party credits |

## Credits

Farm Vendor is a new Lua program, but its workflow comes from two community macros. Thanks to their authors:

* **[Sellitem.mac by Cannonballdex](https://www.redguides.com/community/resources/authors/cannonballdex.233812/)** (RedGuides): bulk selling of one named item.
* **[AutoVendor 3.6 by Ionis](https://www.redguides.com/community/resources/autovendor.1930/)** (RedGuides, [release thread](https://www.redguides.com/community/threads/autovendor.75143/)): an INI sell list built from your inventory.

No code was copied. Farm Vendor reuses their ideas (a remembered sell list, then select and sell each stack) and replaces the commands with documented MacroQuest interfaces.

Also thanks to the [MacroQuest](https://docs.macroquest.org/) developers, the [mq-definitions](https://github.com/macroquest/mq-definitions) project used to verify every Lua and ImGui call, and [RedGuides](https://www.redguides.com/docs/) for its command reference.

Author: Roy M. McKenzie.

<!-- END OF FILE: Farm_Vendor/README.md -->
