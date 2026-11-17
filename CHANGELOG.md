<!--
  FILE    : Farm_Vendor/CHANGELOG.md
  PACKAGE : Farm Vendor Lua (MacroQuest / EverQuest)
  WHAT    : Version history, newest first. dev/doc_audit.py reads the first
            "## x.y.z" heading and checks every Lua file's VERSION against it.
  WHY     : So every change can be traced to a version and a reason.
  WHERE   : Package root.
  WHEN    : Add an entry with every release, before tagging it.
-->
# Farm Vendor changelog

## 1.4.0 (2026-11-17)

Select All and a persistent Never Sell checkbox, as requested by Roy.

- Never Sell column: a checkbox on every row. A Never Sell item cannot be checked or sold. Ticking it removes any existing check on that item.
- Never Sell is saved the moment you tick or untick it, so it survives Cancel and restarts. That save writes only the Never Sell list; unsaved Sell checks still wait for Save Selections or Confirm Sale.
- Only a manual untick removes Never Sell. Select All and Clear Checks never change it.
- Select All button: checks every item the filters currently show that has a sellable stack and is not Never Sell.
- Second guard: the sale list (`buildProposal`) leaves Never Sell items out even if one is somehow checked, for example in a hand edited INI. An ID listed in both `[SelectedItems]` and `[NeverSell]` loads as Never Sell only.
- INI: new `[NeverSell]` section; the schema stays 1. Version 1.3.0 and older keep the section word for word, so going back a version loses nothing (they just do not enforce it).
- If the file is read only, Never Sell still applies for the session and `neversell.save_failed` is logged.
- No new MacroQuest or ImGui interface: the column and button use `Checkbox`, `Button` and `TableSetupColumn`, already audited. No selling, selection or quote code changed.
- Offline tests: 37 of 37 (new 32 to 37). Each new test was checked by breaking the guard it covers and confirming it fails.
- `dev/doc_audit.py` looks for the header in the first 90 lines (was 60).

## 1.3.0 (2026-11-17)

Consolidation and documentation release for publishing on GitHub. No selling logic changed: the code is token for token the 1.2.2 code, in fewer files.

- Seven Lua files became five. Modules that always load together and sit at the same layer are now sections of one file:

  | New file | Sections (old files) | Layer |
  |---|---|---|
  | `config.lua` | config | Parameters and validation (unchanged) |
  | `core.lua` | log, store | Foundation: logging and the selections file |
  | `engine.lua` | inventory, seller | Decision and action: scan, readiness, guarded worker |
  | `ui.lua` | ui | Window (unchanged apart from where it loads the inventory) |
  | `init.lua` | init | Entry point (MacroQuest needs it) |

- Each section keeps its own doc block, its own CHANGES history (corrected against the real diffs between versions) and an END OF SECTION footer. Its locals stay private inside a `do ... end` block.
- Every file has a documentation header and footer, and every function a WHAT, WHY, WHERE, HOW and WHEN block. Every code line carries a comment. `dev/doc_audit.py` checks all of this.
- Credits: every Lua header has a CREDITS line naming Sellitem.mac by Cannonballdex and AutoVendor 3.6 by Ionis where their workflow is used. LICENSE carries the same notice and states that no code was copied.
- AUDIT.md replaces INTERFACES.md: a line by line audit of every TLO member, Lua function, ImGui call, enum, command and chat event against mq-definitions `67f2248`, the MacroQuest docs `d6b9550` and the MacroQuest source `3eb3297`. Nothing invented. Two findings, both documentation only: the /itemnotify page lists pack1 to pack8 while the source accepts every available pack, and with a bag closed MacroQuest picks the item up onto the cursor, which Farm Vendor already stops on.
- Tests moved to `dev/`. `run_tests.py` now works from any folder name. Offline tests: 31 of 31.
- New ARCHITECTURE.md, LICENSE (MIT) and .gitignore. The README drops the old MagFarm wording.
- Upgrading from 1.2.x: delete `log.lua`, `store.lua`, `inventory.lua` and `seller.lua`. The INI is unchanged.

## 1.2.2 (2026-10-13)

Documentation only. Credits confirmed by Roy: Sellitem.mac by Cannonballdex and AutoVendor 3.6 by Ionis. Removed the unconfirmed sl968 reference and the "most likely match" caveat.

## 1.2.1 (2026-10-13)

Documentation and standards review. No selling logic changed.

* Credits: original macro authors added to README.md and init.lua.
* ImGui loaded with the documented `require('ImGui')`; flags combined with `bit32.bor` (mq-definitions), LuaJIT `bit` as fallback.
* UI: every ImGui begin/end and push/pop pair now stays balanced even if drawing raises an error (table rows, tooltips, colored text, confirm list, buttons).
* All Lua, TLO and ImGui calls rechecked against docs.macroquest.org, RedGuides docs and mq-definitions; INTERFACES.md updated.
* README, INTERFACES, TESTING and CHANGELOG shortened.
* Offline tests: 31 of 31 (new: ImGui load path and stack balance under draw errors).

## 1.2.0 (2026-10-13)

Renamed from MagFarm Vendor (`magfarm_vendor`) to Farm Vendor (`Farm_Vendor`); the tool is not magician specific.

* Folder `lua/Farm_Vendor`; command `/fvendor` (was `/mfvendor`); prefix `[FarmVendor]`.
* Files `Farm_Vendor_<server>_<character>.ini/.log`. The old INI is copied once if no new one exists and is never changed (`config.LEGACY_SCRIPT_NAME`).
* Ships in `live` mode after the v1.1.1 client run.
* Offline tests: 28 of 28.

## 1.1.1 (2026-10-13)

Live test: three items sold; Rune of Impetus was quoted, refused once, then quoted again.

* `POST_QUOTE_DELAY_MS` raised from 150 to 500.
* `SELL_REFUSAL_RETRIES` (1) and `RETRY_DELAY_MS` (1000): a refusal right after a valid quote is retried once after reselecting. Refusals with no quote and partial sales are never retried.
* Quotes must name the selected item; backtick and apostrophe match.
* Offline tests: 25 of 25.

## 1.1.0 (2026-10-13)

Live test: Nodding Blue Lily was refused because the sale was sent before the merchant quote.

* Waits for the quote line (`QUOTE_TIMEOUT_MS`, 3 s) before `/sellitem`. "Not interested" fails the item at once; no quote fails closed.
* Selection test mode also waits for the quote.
* `EXCLUDE_UNPRICED_AT_MERCHANT` (on): unpriced items skipped for that merchant, check kept.
* Rescans when a merchant opens or closes; estimate totals priced items only.
* Offline tests: 22 of 22.

## 1.0.0 (2026-10-13)

First release as MagFarm Vendor: a Lua rewrite of the sellitem.mac and AutoVendor.mac workflow under the MagFarm rules. Checklist UI, per character INI, confirmation window, guarded worker with verified selection and sale, three modes, `/mfvendor` commands, structured logging, measured coin change. Offline tests: 17 of 17.

<!-- END OF FILE: Farm_Vendor/CHANGELOG.md -->
