# Changelog

## 1.2.0 (2026-10-13)

Renamed from MagFarm Vendor (`magfarm_vendor`) to Farm Vendor (`Farm_Vendor`); the tool is not magician specific. It is still built under the MagFarm engineering rules. No selling logic changed.

* Folder `lua/Farm_Vendor`, launched with `/lua run Farm_Vendor`; modules load as `Farm_Vendor.<module>`.
* Emergency command `/fvendor stop | quit | show` (was `/mfvendor`).
* Console prefix `[FarmVendor]`; window title "Farm Vendor".
* Files are now `Farm_Vendor_<server>_<character>.ini` and `.log`. On first run the old `magfarm_vendor_...ini` is copied once if no new file exists; the old file is never changed. Controlled by `config.LEGACY_SCRIPT_NAME`.
* `SELL_MODE` ships as `live` because v1.1.1 completed a full live run in the client. Return to `preview` or `select_test` after any change to selling code.
* Offline tests: 28 of 28, including three rename tests.

History below uses the old name.


## 1.1.1 (2026-10-13)

Second live test (v1.1.0): Wax Flower x28, Words of Incarceration x4 and Words of Burnishing x2 sold and verified; coin change 13p 5g 1s matched. Rune of Impetus was quoted ("2p 5g 7s 1c per Rune of Impetus"), refused once, then quoted again, while the merchant window still showed it for sale.

* `POST_QUOTE_DELAY_MS` default raised from 150 to 500.
* New `SELL_REFUSAL_RETRIES` (default 1) and `RETRY_DELAY_MS` (default 1000): a refusal that follows a valid quote for that exact item is retried once, after re-selecting and getting a new quote. Refusals with no quote are never retried. Partial sales are never retried.
* A quote of the form "per <item>" must name the selected item; quotes for another item are logged and ignored. Backtick and apostrophe are treated as equal (Ap`Sagor and Ap'Sagor).
* Select, quote and sell are now separate functions (`selectAndQuote`, `sellOnce`) for easier review.
* Offline tests: 25 of 25.


## 1.1.0 (2026-10-13)

Fixes the first live test failure, where Nodding Blue Lily was refused with "I am not interested in buying that." The sale was sent before the merchant's price quote arrived. Selling the same item by hand after the quote worked.

* After a verified selection the worker now waits for the merchant quote chat line (`QUOTE_TIMEOUT_MS`, default 3 s), then a short `POST_QUOTE_DELAY_MS`, before `/sellitem`.
* "Not interested" at selection or at sale fails that item at once instead of waiting out the timeout. No quote at all fails closed.
* Selection test mode also verifies the quote, so it catches merchant refusals without selling.
* New `EXCLUDE_UNPRICED_AT_MERCHANT` (default on): items the open merchant gives no price for are excluded for that merchant, and your remembered check is kept.
* The list rescans automatically when a merchant window opens or closes.
* The estimate now totals priced items and names how many item types are unpriced, instead of showing "unavailable".
* Waits now poll with `mq.doevents()`; idle merchant chat is flushed so old lines never count.
* Offline tests: 22 of 22, including a regression test that reproduces the v1.0.0 failure.


## 1.0.0 (2026-10-13)

Initial release of MagFarm Vendor, a Lua rewrite of the `sellitem.mac` and `AutoVendor.mac` logic under the MagFarm rules.

* Inventory checklist covering pack1 to pack12, with search, checked only and excluded filters.
* Per server and per character INI selections with schema protection, atomic saves, backups and preservation of unknown sections.
* Separate confirmation window; inventory changes force a new confirmation.
* Guarded selling worker with exact slot revalidation, verified selection, verified sale, bounded waits, failure policy and a failure cap.
* Three staged modes: preview (default), select_test, live.
* Readiness panel, Stop Selling control, `/mfvendor` emergency commands.
* Structured logging to console, rotating file and the in window Activity Log.
* Measured coin change reported beside the SellPrice estimate.
* Offline test harness: 17 of 17 scenarios passing. Client stages pending.
