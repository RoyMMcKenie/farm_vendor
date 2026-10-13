# MagFarm Vendor: Documented Interface Ledger

MagFarm rule: every command, TLO, datatype member, plugin interface and ImGui call must be documented by MacroQuest or RedGuides before it appears in executable code. This ledger lists every external interface the package uses and where it is documented. Anything not listed here is not used.

Documentation establishes that an interface exists. The client checks in TESTING.md establish that it behaves as this package expects.

## Commands

| Interface | Used in | Purpose | Documentation |
|---|---|---|---|
| `/itemnotify in packN <slot#> leftmouseup` | seller.lua | Select an item inside a bag in the merchant window | [MacroQuest /itemnotify](https://docs.macroquest.org/reference/commands/itemnotify/) |
| `/itemnotify <slot#> leftmouseup` | seller.lua | Select a loose item sitting directly in a pack slot (23 to 34) | [MacroQuest /itemnotify](https://docs.macroquest.org/reference/commands/itemnotify/) ("any slot number") |
| `/sellitem <qty>` | seller.lua | Sell that quantity of the selected item | [MacroQuest /sellitem](https://docs.macroquest.org/reference/commands/sellitem/) |
| `/lua run`, `/lua stop` | operator | Start and stop the script | [MacroQuest Lua command reference](https://docs.macroquest.org/lua/) |

The `/itemnotify in` form for pack9 and above, and the conversion from the 0-based `ItemSlot2` to the 1-based `/itemnotify` slot number (`ItemSlot2 + 1`, pack number `ItemSlot - 22`), come from the [MacroQuest Slot Names reference](https://docs.macroquest.org/reference/general/slot-names/), which gives that exact calculation for pack10.

Not used on purpose: `/autoinventory` (the script never moves cursor items for you), `/nav` and vendor finding, `/selectitem` (name based, cannot target an exact bag slot), `Merchant.Sell[n]` method (the `/sellitem` command is the unambiguous documented equivalent), Find Item window parsing, `MQ2AutoLoot /autoloot sell` (sells its own Loot.ini list, not your confirmed selection).

## Top Level Objects and members

| Interface | Purpose | Documentation |
|---|---|---|
| `EverQuest.GameState` | Must be `INGAME` | [EverQuest TLO](https://docs.macroquest.org/reference/top-level-objects/tlo-everquest/) |
| `EverQuest.Server` | Per server file name | [EverQuest TLO](https://docs.macroquest.org/reference/top-level-objects/tlo-everquest/) |
| `Me.Name` | Per character file name | [character datatype](https://docs.macroquest.org/reference/data-types/datatype-character/) |
| `Me.Inventory[#]` | Read pack slots 23 to 34 | [character datatype](https://docs.macroquest.org/reference/data-types/datatype-character/), [Slot Names](https://docs.macroquest.org/reference/general/slot-names/) |
| `Me.Platinum`, `Gold`, `Silver`, `Copper` | Measure actual coin change | [character datatype](https://docs.macroquest.org/reference/data-types/datatype-character/) |
| `item.ID`, `Name`, `Stack`, `Value`, `SellPrice`, `NoDrop`, `Lore`, `Container`, `Item[N]`, `ItemSlot`, `ItemSlot2` | Inventory scan, eligibility, exact location | [item datatype](https://docs.macroquest.org/reference/data-types/datatype-item/) |
| `Merchant.Open` | Merchant window open | [merchant datatype](https://docs.macroquest.org/reference/data-types/datatype-merchant/) |
| `Merchant.ItemsReceived` | Merchant list populated | [merchant datatype](https://docs.macroquest.org/reference/data-types/datatype-merchant/) |
| `Merchant.SelectedItem` (`ID`, `ItemSlot`, `ItemSlot2`) | Verify the exact selection before selling | [merchant datatype](https://docs.macroquest.org/reference/data-types/datatype-merchant/) |
| `Merchant.ID`, `Merchant.CleanName` | Detect a merchant change; show the name. The merchant type inherits spawn members while a merchant is active | [merchant datatype](https://docs.macroquest.org/reference/data-types/datatype-merchant/), [Merchant TLO](https://docs.macroquest.org/reference/top-level-objects/tlo-merchant/) |
| `Cursor.ID` | Cursor must be empty | [Cursor TLO](https://docs.macroquest.org/reference/top-level-objects/tlo-cursor/) |
| `Macro.Name` | Block selling while a macro owns the client | [Macro TLO](https://docs.macroquest.org/reference/top-level-objects/tlo-macro/) |

TLO access follows the documented Lua conversion rules (remove `${}`, prefix `mq.TLO.`, brackets become parentheses, finish with `()`), from [Lua Scripting in MacroQuest](https://docs.macroquest.org/lua/).

## Lua bindings

| Interface | Purpose | Documentation |
|---|---|---|
| `require('mq')`, `print` (redirected to MQ chat) | Core binding, console output | [Lua Scripting in MacroQuest](https://docs.macroquest.org/lua/) |
| `mq.delay(ms, condition)` | Bounded waits that end early | [Lua Scripting in MacroQuest](https://docs.macroquest.org/lua/), [mq-definitions mq.lua](https://github.com/macroquest/mq-definitions/blob/master/mq/mq.lua) |
| `mq.cmdf` | Issue the two documented commands | same |
| `mq.bind`, `mq.unbind` | `/mfvendor stop`, `quit`, `show` | same |
| `mq.imgui.init`, `mq.imgui.destroy` | Register and remove the UI | same |
| `mq.configDir` | Folder for INI and log (no hardcoded install path) | [mq-definitions mq.lua](https://github.com/macroquest/mq-definitions/blob/master/mq/mq.lua) |
| `bit.bor` | Combine ImGui table flags | LuaJIT built-in `bit` library (MQ2Lua is built on LuaJIT 2.1 per the MacroQuest Lua page) |
| `io.open`, `os.rename`, `os.remove`, `os.date`, `os.time` | INI and log files | Standard Lua library |

## ImGui calls

All are declared in the [MacroQuest mq-definitions ImGui bindings](https://github.com/macroquest/mq-definitions/blob/master/imgui/imgui.lua), which the MacroQuest Lua page names as the full listing:

`Begin`, `End`, `BeginChild`, `EndChild`, `BeginTable`, `EndTable`, `TableSetupColumn`, `TableSetupScrollFreeze`, `TableHeadersRow`, `TableNextRow`, `TableNextColumn`, `Checkbox`, `Button`, `InputText`, `TextUnformatted`, `SameLine`, `Separator`, `PushID`, `PopID`, `BeginDisabled`, `EndDisabled`, `PushStyleColor`, `PopStyleColor`, `IsItemHovered`, `BeginTooltip`, `EndTooltip`, `SetNextWindowSize`, `SetNextWindowFocus`, `SetNextItemWidth`, `GetContentRegionAvail`, `SetScrollHereY`.

Enums from [imgui_enums.lua](https://github.com/macroquest/mq-definitions/blob/master/imgui/imgui_enums.lua): `ImGuiCol.Text`, `ImGuiCol.Button`, `ImGuiCond.FirstUseEver`, `ImGuiCond.Appearing`, `ImGuiWindowFlags.NoCollapse`, `ImGuiChildFlags.Borders`, `ImGuiTableFlags.RowBg / Borders / ScrollY / Resizable / SizingStretchProp`, `ImGuiTableColumnFlags.WidthFixed / WidthStretch`.

## Behaviors that documentation alone does not settle

These are confirmed only by the staged client tests in TESTING.md. Until each passes, the related mode stays off.

1. Whether `/itemnotify` with a merchant open selects the item (the expected EverQuest behavior) rather than lifting it to the cursor, including with bags closed. The script checks the cursor after every selection and stops if anything lands there.
2. The exact `ItemSlot` and `ItemSlot2` values that `Merchant.SelectedItem` reports for a selected bag item and a selected loose item. If they differ from the scan values, the selection test fails closed.
3. That `/sellitem <qty>` with the full stack count sells the whole stack without an extra quantity prompt.
4. That `Merchant.ID` stays constant while one merchant is open.
5. That `Macro.Name` reads as empty or NULL when no macro is running.
