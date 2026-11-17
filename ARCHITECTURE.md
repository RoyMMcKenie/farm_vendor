<!--
  FILE    : Farm_Vendor/ARCHITECTURE.md
  PACKAGE : Farm Vendor Lua (MacroQuest / EverQuest)
  VERSION : 1.3.0
  WHAT    : How the package is built: file and section map, the request
            flag pattern, one sale step by step, the documentation standard,
            the selections file and testing.
  WHY     : So the next person can change one section without breaking the
            others, and so no command is ever added without a source.
  WHERE   : Package root, next to README.md and AUDIT.md.
  WHEN    : Read before editing code. Update when a file, section, setting
            or command is added or changed.
-->
# Farm Vendor architecture

## File and section map

Five Lua files. The two layer files hold two sections each; a section is one former 1.2.x module, kept whole inside a `do ... end` block with its own doc block, CHANGES history and END OF SECTION footer. Comments name a section as `file.lua/section`.

| File | Section | Job | Uses |
|---|---|---|---|
| `config.lua` | | Every setting with purpose, range and default; validation that stops startup with a list of what to fix | none |
| `core.lua` | log | Console, file and Activity Log events; log rotation | mq |
| | store | Per character INI: parsing, schema check, unknown sections kept word for word, atomic save with `.bak`, one time copy from the old `magfarm_vendor` file | log |
| `engine.lua` | inventory | Read only pack scan, eligibility, coin reading | mq |
| | seller | Readiness checks, the sale proposal, the guarded selling worker, merchant chat events | inventory, log |
| `ui.lua` | | ImGui main window and Confirm Sale window | engine.inventory |
| `init.lua` | | Entry point: startup, shared `app` state, request handling, `/fvendor`, main loop, shutdown | all above |

Why these groups: each file is one layer. core never reads the game; engine reads the game and is the only place a game command is sent; ui only draws and sets flags; init owns state and ties the layers together. A file only requires files above it in this list.

## Request flag pattern

ImGui draws from a callback where `mq.delay` must not be called and commands should not be sent. So the window never acts. A button only sets a flag in `app.requests` (`rescan`, `save`, `prepare`, `confirm`, `cancelConfirm`, `quit`), and the main loop in `init.lua`, which runs every `LOOP_DELAY_MS` (100 ms), takes the whole table each pass and acts on it. Stop Selling is the one exception that matters while a run is in progress: it calls `seller:requestStop()`, which only sets `stopRequested`; the worker checks it before every item.

The main loop also rescans when the merchant window opens or closes, discards merchant chat lines that arrive while idle, and refreshes readiness for the window. Any error inside the loop is caught, logged as `loop.internal_error`, and blocks selling until restart.

## One sale, step by step (engine.lua/seller)

1. Sell All Checked Items: `buildProposal` lists every checked, eligible stack. The Confirm Sale window shows it.
2. Confirm Sale: the inventory is scanned again. If it changed, the list is rebuilt and you confirm again.
3. For each stack: stop requested? Hard stop reasons (cursor, merchant change or close, macro, game state)? Then the slot is reread.
4. `/itemnotify` selects the exact slot. `Merchant.SelectedItem` must report the same slot, and the cursor must stay empty.
5. The merchant quote for that item must arrive within `QUOTE_TIMEOUT_MS`. A refusal fails at once.
6. Live mode only: `/sellitem <qty>`, then the sale counts only when the stack has left the slot. One retry after reselecting if refused right after a valid quote.
7. The report shows items sold, failures and the measured coin change beside the estimate.

## Documentation standard

Enforced by `dev/doc_audit.py`, which must PASS before a release:

- Header in the first 60 lines: FILE, PACKAGE, VERSION, CHANGES (lists the current version), CREDITS, WHAT, WHY, WHERE, HOW, WHEN.
- Every function: a WHAT / WHY / WHERE / HOW / WHEN block above it, or a comment directly above for a one line helper documented in a shared block (the `probe` readers).
- Every line of code: a comment on the line or within the three lines above.
- Footer in the last 80 lines: END OF FILE.
- In the layer files, every SECTION block has WHAT / WHY / WHERE / HOW / WHEN and a matching END OF SECTION footer.
- VERSION in every file matches the newest heading in CHANGELOG.md.
- Markdown files use an HTML comment header and footer.

## Selections file (core.lua/store)

`<MQ config>/Farm_Vendor_<server>_<character>.ini`, schema 1:

| Section | Holds |
|---|---|
| `[Meta]` | `Schema=1`, `Tool=Farm_Vendor` |
| `[Settings]` | `ProtectedBags=1,2` (optional) |
| `[SelectedItems]` | `<itemID>=1` for each checked item |
| `[ItemNames]` | `<itemID>=<name>`, for reading by hand only; never matched |

A file with a different schema is opened read only: you can look but not save, so nothing is ever overwritten by a version that does not understand it. Unknown sections are kept word for word.

## Commands and interfaces

The only game commands are `/itemnotify` and `/sellitem`, both sent from `engine.lua/seller`. AUDIT.md lists every command, TLO member, Lua function and ImGui call with the source that defines it. Do not add one without adding it there first.

## Testing

`dev/run_tests.py` runs the real package under LuaJIT against `dev/harness.lua`, a mock MacroQuest client with a merchant that quotes after a delay and refuses a sale sent before the quote. TESTING.md lists the 31 scenarios and the client stages.

<!-- END OF FILE: Farm_Vendor/ARCHITECTURE.md -->
