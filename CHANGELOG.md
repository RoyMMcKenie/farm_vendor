# Changelog

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
