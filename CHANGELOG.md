# Changelog

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
