# Changelog

## 1.2.1 (2026-10-13)

Documentation and standards review. No selling logic changed.

* Credits: original macro authors named (Cannonballdex and sl968 for sellitem.mac, Ionis for AutoVendor.mac) in README.md and init.lua.
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
