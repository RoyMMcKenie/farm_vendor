# Farm Vendor: Interface Ledger

MagFarm rule: every command, TLO member, Lua binding and ImGui call must be documented by MacroQuest or RedGuides before it is used. This is the complete list; anything not here is not used. Last audited for v1.2.1 against docs.macroquest.org, RedGuides docs and mq-definitions.

## Commands

| Command | Purpose | Documentation |
|---|---|---|
| `/itemnotify in packN <slot#> leftmouseup` | Select a bag item in the merchant window | [MacroQuest /itemnotify](https://docs.macroquest.org/reference/commands/itemnotify/) |
| `/itemnotify <slot#> leftmouseup` | Select a loose item in a pack slot (23 to 34) | same ("any slot number") |
| `/sellitem <qty>` | Sell that quantity of the selected item | [MacroQuest](https://docs.macroquest.org/reference/commands/sellitem/), [RedGuides](https://www.redguides.com/docs/projects/macroquest/reference/commands/sellitem/) |

Slot numbers: pack = `ItemSlot - 22`, bag slot = `ItemSlot2 + 1`, per the [Slot Names reference](https://docs.macroquest.org/reference/general/slot-names/).

Deliberately not used: `/selectitem` (name based, cannot target a slot), `Merchant.Sell[n]`, `/autoinventory`, `/nav`, Find Item window parsing, and `/autoloot sell` (sells its own Loot.ini list).

## TLO members

| Member | Purpose | Documentation |
|---|---|---|
| `EverQuest.GameState`, `EverQuest.Server` | In game check; file name | [EverQuest TLO](https://docs.macroquest.org/reference/top-level-objects/tlo-everquest/) |
| `Me.Name`, `Me.Inventory[#]`, `Me.Platinum/Gold/Silver/Copper` | File name; pack scan; coin change | [character](https://docs.macroquest.org/reference/data-types/datatype-character/) |
| item `ID`, `Name`, `Stack`, `Value`, `SellPrice`, `NoDrop`, `Lore`, `Container`, `Item[N]`, `ItemSlot`, `ItemSlot2` | Scan, eligibility, exact location | [item](https://docs.macroquest.org/reference/data-types/datatype-item/) |
| `Merchant.Open`, `ItemsReceived`, `SelectedItem` | Merchant ready; verify the selection | [merchant](https://docs.macroquest.org/reference/data-types/datatype-merchant/) |
| `Merchant.ID`, `Merchant.CleanName` | Detect a merchant change; display. "This type inherits members from spawn if a merchant is active." | same |
| `Cursor.ID` | Cursor must be empty | [Cursor TLO](https://docs.macroquest.org/reference/top-level-objects/tlo-cursor/) |
| `Macro.Name` | Block selling while a macro runs | [Macro TLO](https://docs.macroquest.org/reference/top-level-objects/tlo-macro/) |

Access follows the documented conversion rules (drop `${}`, prefix `mq.TLO.`, brackets become parentheses, end with `()`) from [Lua Scripting in MacroQuest](https://docs.macroquest.org/lua/). Every read is wrapped in `pcall` and type checked, so a NULL fails closed.

## Lua bindings

All are declared in [mq-definitions mq.lua](https://github.com/macroquest/mq-definitions/blob/master/mq/mq.lua) and described on the [MacroQuest Lua page](https://docs.macroquest.org/lua/) and [Events and Binds](https://docs.macroquest.org/lua/events-and-binds/).

| Binding | Purpose |
|---|---|
| `require('mq')`, `print` | Core binding; console output |
| `mq.delay(ms, condition)`, `mq.gettime` | Bounded waits. Never called in the ImGui callback or at module load, per [MacroScript to Lua](https://docs.macroquest.org/lua/macro-to-lua/) |
| `mq.cmdf` | Issue the commands above |
| `mq.bind`, `mq.unbind` | `/fvendor` |
| `mq.event`, `mq.unevent`, `mq.doevents`, `mq.flushevents` | Merchant quote and refusal lines (`#*#` wildcard) |
| `mq.imgui.init`, `mq.imgui.destroy` | Register and remove the UI |
| `mq.configDir` | INI and log folder |
| `require('ImGui')` | ImGui bindings, the form documented by mq-definitions and the [RedGuides definition library](https://www.redguides.com/community/resources/mq-vs-code-lua-autocomplete-definition-library.2583/) |
| `bit32.bor` | Combine table flags ([mq-definitions _Bit32.lua](https://github.com/macroquest/mq-definitions/blob/master/_Bit32.lua)); LuaJIT `bit` as fallback |
| `io`, `os` | Standard Lua file and time functions |

## ImGui calls

All are declared in [mq-definitions imgui.lua](https://github.com/macroquest/mq-definitions/blob/master/imgui/imgui.lua) with the argument forms used here: `Begin`, `End`, `BeginChild`, `EndChild`, `BeginTable`, `EndTable`, `TableSetupColumn`, `TableSetupScrollFreeze`, `TableHeadersRow`, `TableNextRow`, `TableNextColumn`, `Checkbox`, `Button`, `InputText`, `TextUnformatted`, `SameLine`, `Separator`, `PushID`, `PopID`, `BeginDisabled`, `EndDisabled`, `PushStyleColor`, `PopStyleColor`, `IsItemHovered`, `BeginTooltip`, `EndTooltip`, `SetNextWindowSize`, `SetNextWindowFocus`, `SetNextItemWidth`, `GetContentRegionAvail`, `SetScrollHereY`.

Enums ([imgui_enums.lua](https://github.com/macroquest/mq-definitions/blob/master/imgui/imgui_enums.lua)): `ImGuiCol.Text/Button`, `ImGuiCond.FirstUseEver/Appearing`, `ImGuiWindowFlags.NoCollapse`, `ImGuiChildFlags.Borders`, `ImGuiTableFlags.RowBg/Borders/ScrollY/Resizable/SizingStretchProp`, `ImGuiTableColumnFlags.WidthFixed/WidthStretch`.

`End` is always called after `Begin`, `EndChild` after `BeginChild`, and `EndTable` only when `BeginTable` returned true. Every push or begin pair stays balanced even when drawing raises an error (tested).

## Client behavior

Documentation shows an interface exists; the client shows how it behaves. Settled on 2026-10-13 (Merchant Wyn\`las, bristle):

* `/itemnotify` with a merchant open selects the item and leaves the cursor empty.
* `Merchant.SelectedItem` reports the same `ItemSlot`/`ItemSlot2` as the scan.
* The merchant answers each selection with "told you, 'I'll give you ... per <item>'" and refuses a sale sent before that quote. `/sellitem <qty>` works once the quote arrives.
* `Merchant.ID` stays constant and `Macro.Name` reads empty while no macro runs.

Not yet observed: selection with bags closed, and items in pack9 or above. Both fail closed if they behave differently.
