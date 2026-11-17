<!--
  FILE    : Farm_Vendor/AUDIT.md
  PACKAGE : Farm Vendor Lua (MacroQuest / EverQuest)
  VERSION : 1.4.0
  WHAT    : Line by line source audit of Farm Vendor 1.3.0, and the interface
            ledger that replaces the 1.2.x INTERFACES.md. Every game data call
            (TLO), MacroQuest Lua function, ImGui call, enum, slash command and
            chat event in the five Lua files is matched to the definition,
            documentation page or MacroQuest source that defines it.
  WHY     : To show that no command or interface in this package was made up,
            and to record what the client itself has and has not confirmed.
  WHERE   : Package root, beside README.md and ARCHITECTURE.md.
  WHEN    : Performed 2026-11-17 against the commits pinned in "Reference
            sources". Repeat it whenever a command, TLO member or ImGui call
            is added or changed.
-->
# Farm Vendor source audit (1.3.0)

1.4.0 addendum: Select All and Never Sell add no new interface. They use `ImGui.Checkbox`, `ImGui.Button` and `ImGui.TableSetupColumn`, already listed in section 3, with the same argument forms. No TLO member, command or event was added. The audit below was performed for 1.3.0 and still holds.

Result: nothing invented. Every interface the code touches is defined by MacroQuest, the MacroQuest Lua and ImGui definitions, or the MacroQuest source. One documentation discrepancy and one corrected test expectation were found (see "Findings"); no code changed.

Code comments were stripped before every check, so only executable code was audited. Anything not listed here is not used.

## Reference sources

| Source | Pinned at |
|---|---|
| [macroquest/mq-definitions](https://github.com/macroquest/mq-definitions) (Lua type definitions for TLOs, `mq.*`, ImGui) | `67f2248` |
| [macroquest/docs](https://github.com/macroquest/docs) (published at [docs.macroquest.org](https://docs.macroquest.org/)) | `d6b9550` |
| [macroquest/macroquest](https://github.com/macroquest/macroquest) `src/main/MQ2Windows.cpp` (`/itemnotify`), `src/plugins/lua` | `3eb3297` |

## 1. Game data (TLO) calls

Every member was resolved against mq-definitions (`---@field public <Name>` or `function <class>.<Name>`).

| Chain | Purpose | Defined in |
|---|---|---|
| `EverQuest.GameState`, `EverQuest.Server` | In game check; INI and log file name | `mq/datatype/_everquest.lua`; [EverQuest TLO](https://docs.macroquest.org/reference/top-level-objects/tlo-everquest/) |
| `Me.Name`, `Me.Platinum`, `Me.Gold`, `Me.Silver`, `Me.Copper` | File name; coin change after a sale | `mq/datatype/_character.lua` |
| `Me.Inventory(slot)` | Pack scan, slots 23 to 34 | `_character.lua` (`function character.Inventory(slotNumber)`); [Slot Names](https://docs.macroquest.org/reference/general/slot-names/) |
| item `ID`, `Name`, `Stack`, `Value`, `SellPrice`, `NoDrop`, `Lore`, `Container`, `Item(n)`, `ItemSlot`, `ItemSlot2` | Scan, eligibility, exact location | `mq/datatype/_item.lua`; [item](https://docs.macroquest.org/reference/data-types/datatype-item/) |
| `Merchant.Open`, `Merchant.ItemsReceived`, `Merchant.SelectedItem` (`ID`, `ItemSlot`, `ItemSlot2`) | Merchant ready; verify the selection | `mq/datatype/_merchant.lua` |
| `Merchant.ID`, `Merchant.CleanName` | Detect a merchant change; display | `mq/datatype/_spawn.lua`. The [merchant page](https://docs.macroquest.org/reference/data-types/datatype-merchant/) says "This type inherits members from spawn if a merchant is active." |
| `Cursor.ID` | Cursor must be empty | `mq/mq.lua` (Cursor TLO is an item); [Cursor TLO](https://docs.macroquest.org/reference/top-level-objects/tlo-cursor/) |
| `Macro.Name` | Block selling while a macro runs | `mq/datatype/_macro.lua`; [Macro TLO](https://docs.macroquest.org/reference/top-level-objects/tlo-macro/) |

Access follows the documented conversion rules (drop `${}`, prefix `mq.TLO.`, brackets become parentheses, end with `()`) from [Lua Scripting in MacroQuest](https://docs.macroquest.org/lua/). Every read is wrapped in `pcall` and type checked, so a NULL fails closed.

## 2. MacroQuest Lua functions

All 12 are declared in mq-definitions `mq/mq.lua` and described on the [MacroQuest Lua page](https://docs.macroquest.org/lua/) and [Events and Binds](https://docs.macroquest.org/lua/events-and-binds/).

| Function | Purpose |
|---|---|
| `mq.delay(ms, condition)`, `mq.gettime()` | Bounded waits. Never called in the ImGui callback or at module load, per [MacroScript to Lua](https://docs.macroquest.org/lua/macro-to-lua/) |
| `mq.cmdf` | Issue the commands in section 4 |
| `mq.bind`, `mq.unbind` | `/fvendor` |
| `mq.event`, `mq.unevent`, `mq.doevents`, `mq.flushevents` | Merchant quote and refusal lines |
| `mq.imgui.init`, `mq.imgui.destroy` | Register and remove the window |
| `mq.configDir` | INI and log folder (a field in `mq.lua`) |

Also used: `require('mq')`; `require('ImGui')`, the form documented by mq-definitions and the [RedGuides definition library](https://www.redguides.com/community/resources/mq-vs-code-lua-autocomplete-definition-library.2583/); `bit32.bor` to combine table flags ([mq-definitions `_Bit32.lua`](https://github.com/macroquest/mq-definitions/blob/master/_Bit32.lua)) with LuaJIT `bit` as a fallback; standard Lua `io`, `os`, `string`, `table`, `pcall` and `print`.

## 3. ImGui

- All 31 functions exist in mq-definitions `imgui/imgui.lua`: `Begin`, `End`, `BeginChild`, `EndChild`, `BeginTable`, `EndTable`, `TableSetupColumn`, `TableSetupScrollFreeze`, `TableHeadersRow`, `TableNextRow`, `TableNextColumn`, `Checkbox`, `Button`, `InputText`, `TextUnformatted`, `SameLine`, `Separator`, `PushID`, `PopID`, `BeginDisabled`, `EndDisabled`, `PushStyleColor`, `PopStyleColor`, `IsItemHovered`, `BeginTooltip`, `EndTooltip`, `SetNextWindowSize`, `SetNextWindowFocus`, `SetNextItemWidth`, `GetContentRegionAvail`, `SetScrollHereY`.
- Each call was compared with its declared overloads: `Begin(name, open, flags)` returns `open, draw`; `Checkbox(label, value)` returns `value, pressed`; `InputText(label, text)` returns `text, changed`; `BeginChild(id, x, y, childFlags)`; `BeginTable(id, cols, flags, outerX, outerY)`; `TableSetupColumn(label, flags, width)`; `Button(label, x, y)`; `PushStyleColor(idx, r, g, b, a)`; `GetContentRegionAvail()` returns `x, y`.
- All 13 constants are in `imgui/imgui_enums.lua`: `ImGuiChildFlags.Borders`, `ImGuiCol.Text/Button`, `ImGuiCond.Appearing/FirstUseEver`, `ImGuiTableColumnFlags.WidthFixed/WidthStretch`, `ImGuiTableFlags.Borders/Resizable/RowBg/ScrollY/SizingStretchProp`, `ImGuiWindowFlags.NoCollapse`.
- `End` always follows `Begin`, `EndChild` follows `BeginChild`, and `EndTable` runs only when `BeginTable` returned true. Every push or begin stays balanced even when drawing raises an error (tested).
- The window callback sends no commands and never calls `mq.delay`. It only sets request flags; the main loop in `init.lua` acts on them.

## 4. Slash commands

These are all the command forms the code can send.

| Command as sent | Purpose | Defined by |
|---|---|---|
| `/itemnotify in pack<N> <slot#> leftmouseup` | Select a bag item in the merchant window | [/itemnotify](https://docs.macroquest.org/reference/commands/itemnotify/); `MQ2Windows.cpp` (`in` / `pack` branch) |
| `/itemnotify <slot#> leftmouseup` | Select a loose item in pack slot 23 to 34 | same page ("any slot number"); `MQ2Windows.cpp` (numeric branch) |
| `/sellitem <qty>` | Sell that quantity of the selected item | [MacroQuest /sellitem](https://docs.macroquest.org/reference/commands/sellitem/), [RedGuides /sellitem](https://www.redguides.com/docs/projects/macroquest/reference/commands/sellitem/) |

Slot math: pack = `ItemSlot - 22`, bag slot = `ItemSlot2 + 1`, exactly as the [Slot Names reference](https://docs.macroquest.org/reference/general/slot-names/) shows ("pack${Math.Calc[...ItemSlot-22]} ${Math.Calc[...ItemSlot2 + 1]}").

Deliberately not used: `/selectitem` (name based, cannot target a slot), `Merchant.Sell[n]`, `/autoinventory`, `/nav`, Find Item window parsing, and `/autoloot sell` (sells its own Loot.ini list).

## 5. Chat events

| Event | Pattern | Source |
|---|---|---|
| Quote | `#*#told you, 'I'll give you #*#` | Line seen in client 2026-10-13 (Merchant Wyn\`las); `#*#` wildcard per [Events and Binds](https://docs.macroquest.org/lua/events-and-binds/) |
| Refusal | `#*#told you, 'I am not interested in buying that.'#*#` | Standard EverQuest merchant refusal line; same wildcard rule |

Both phrases live in `config.lua` (`QUOTE_PHRASE`, `REFUSAL_PHRASE`) so they can be corrected without touching code.

## 6. RedGuides Lua conventions

- Folder package started with `/lua run Farm_Vendor`; `init.lua` is the entry point.
- Window registered once with `mq.imgui.init` and removed with `mq.imgui.destroy` at shutdown.
- Settings and log in `mq.configDir`, one file per server and character.
- Binds and events removed at shutdown (`mq.unbind`, `mq.unevent`).
- Pause control: Stop Selling and `/fvendor stop` end a run before the next item.

## Findings

1. Documentation discrepancy, pack9 and above. The /itemnotify page says "in bag slot#" can be "pack1-pack8". The Slot Names page shows a pack10 example, and `MQ2Windows.cpp` accepts any `pack<N>` below `GetAvailableBagSlots()`. So pack9 to pack12 are supported by the source; the client check stays open.
2. Bags closed. When the bag is closed, `MQ2Windows.cpp` does not click the slot for `in pack<N> <slot#> leftmouseup`; it picks the item up onto the cursor. Farm Vendor already checks `Cursor.ID` after every selection and stops with "item went to the cursor" for manual handling, so this fails closed and nothing is sold. TESTING.md now expects that stop instead of "same as an open bag". A loose item whose slot window cannot be found gets "Could not find slot", which Farm Vendor treats as no selection.

## Client behavior

Documentation shows an interface exists; the client shows how it behaves. Settled on 2026-10-13 (Merchant Wyn\`las, bristle):

* `/itemnotify` with a merchant open and the bag open selects the item and leaves the cursor empty.
* `Merchant.SelectedItem` reports the same `ItemSlot`/`ItemSlot2` as the scan.
* The merchant answers each selection with "told you, 'I'll give you ... per <item>'" and refuses a sale sent before that quote. `/sellitem <qty>` works once the quote arrives.
* `Merchant.ID` stays constant and `Macro.Name` reads empty while no macro runs.

Not yet observed in game: selection with bags closed (expected to stop safely, see Findings 2) and items in pack9 or above. Both fail closed if they behave differently. They are open issues on the project board.

<!-- END OF FILE: Farm_Vendor/AUDIT.md -->
