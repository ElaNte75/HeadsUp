## HeadsUp Auras 1.2 beta

### New name: HeadsUp Auras

The add-on was called **HeadsUp**. That name was too close to another add-on (*Heads Up*, which speaks tank busters), and the two cannot be installed together, so it is now **HeadsUp Auras**. The command is now **/hua** (or /headsupauras).

**If you had the old version:** close the game, delete the old `HeadsUp` folder from `Interface/AddOns`, put the new `HeadsUpAuras` folder there, and run `Migrate-HeadsUp-settings.ps1` once (it is in the `release` folder of the GitHub page): it brings your auras, groups and counters with you. Your old settings file is not touched.

A big step forward: you can now put your auras in **groups**, follow effects with **trackers** and **bars**, and count items and currencies with the new **Counter**. More changes are on the way, so please keep the feedback coming (the *Feedback* button in the HeadsUp Auras window shows where to send it).

### New: Counter

- Choose **Counter** in *What to make* to show how many of an **item** you have in your bags (optionally the bank too) or how much of a **currency** you have (crests, coins, keys...), without opening anything.
- One box for both: type a name or an id, or drag an item from your bags onto it. A confirmation line shows the picture, the name and the number you have right now.
- Four looks: **Text** (just the number, as big as the number), **Square icon** and **Round icon** (the item's picture with the number on it) and **Bar** (a long box with the icon, the name and the number, placed where you want and never overlapping).
- Choose the text size and color, and the background color and opacity.
- Numbers are written with thousands separators, as the game writes them (20,224).
- Crafting materials and crafted items show their **quality** (Q1, Q2...), because each quality is a different item.
- **Who sees it:** all your characters, only the character that made it, only this class (with its specializations), or only the characters that have the profession of the item (cloth: Tailoring, ore: Mining, herbs: Herbalism, and so on).

### New: Groups of auras

- Select auras that belong together and make a **group**: move, activate, deactivate and rename them as one. A group has at least two auras.
- Click a group to show all its auras on the screen, inside a box with nine dots. Drag them with the mouse, or open the **Position** window and type coordinates: press Enter to see the group move right away, *Save* to keep it, *Close* to put it back.
- **Edit group** opens the Position window together with the list of auras, so you can change who is in the group and where it is in one go.
- **Add to group** in the right-click menu puts a free aura into a group. Each group has its own color, and can be opened or closed in the list.
- While you place a group, the icons are shown clean, without glows and effects.

### New: Trackers, bars and conditions

- **Debuff / effect trackers** follow the effect of an ability with a timer of their own. The addon knows the length of more than 3,000 effects and whether they are on the enemy or on you.
- A tracker can be an icon or a **Progress bar** (with time, icon and color of your choice), and each enemy can have its own timer.
- **Combine with auras:** show an aura only while another aura of yours is, or is not, showing.
- **Enemies:** a condition on how many enemies are around you (in combat, or attacking you).
- **Ignore while it lights up:** for an Empowered ability, choose which of its conditions (your health, resources, cooldown, target...) stop counting while it glows. Every other condition still counts, and the sound works when the ones the game hides are ignored.
- New conditions about you and your target: stance, hostility (including neutral), player or NPC, boss / rare / elite, alive, health, aggro.
- More places to show: stealthed, group (solo, party, raid) and place (open world, dungeon, raid, delve, PvP).

### Looks and effects

- Themed **Empowered effects** (frost, blood, poison, sunburst, flame, burst) and **round icons** with a rim that matches the effect.
- Width and height of every aura, and the position as X / Y numbers from the center of the screen.
- A minimap button, and an *Important info* panel that explains what the game hides in combat.

### The list and the window

- One list with one scroll bar. Several auras can stay on the screen while you edit one of them, so you can see how it sits next to the others.
- The green square shows what is on the screen; the highlight shows what you are working on. The right-click menu highlights its row while it is open, so you always know which aura it acts on.
- **Save** lights up only when something has really changed.
- The addon knows which abilities light up (from the game's own data) and offers *Empowered* for them.

### Good to know

- This is a **beta**. Inside combat the game hides some values from addons (buffs, health of enemies and so on). HeadsUp Auras only uses what the game lets it read; the *Important info* button explains it.
- Currencies are chosen by typing their name or id. Dragging them from the currency window is not possible in the game.
- For game versions 12.1.7, 12.1.5 and 12.1.0.

*Author: Gchris*

## 1.1 beta

- **Status page in two cards:** Player (health, main and second resource, stance) and Target (hostile or friendly, player or NPC, boss / rare / elite / normal, alive or dead, enemy health, aggro on me).
- "Show it only" has more choices: stealthed, group (solo, party, raid) and place (open world, dungeon, raid, Delve or scenario, PvP).
- **New themed Empowered effects:** Frost, Blood and Poison, and "Auto (by spec)" that picks one from your specialization. You can also choose None, and switch off the soft light of the themed effects.
- **Round icon shape:** the picture and the cooldown cut to a circle, with a rim that follows the effect.
- Dropdowns are all the same width and show a tooltip with the full choice when something does not fit, or when several choices are ticked.
- Works with game versions 12.1.0, 12.1.5 and 12.1.7.

## 1.0 beta

First public version.

- Build your own icons ("auras") in a four-step window: Aura, Status, Ability, Situation.
- Conditions: your health, enemy health, enemy alive, main and second resource of your class, ability available, cooldown, charges, empowered (proc glow).
- Knows which abilities can light up, for every class.
- "Always show when empowered" and three effects for empowered abilities: Sunburst, Flame, Burst.
- Place the icon with the mouse or with X and Y; width and height; display priority.
- Show only in combat, out of combat, mounted, in a vehicle, for chosen specializations; keep it after combat; hide after a cast.
- Deactivate auras you do not need now, without deleting them (they move to an Inactive list), and duplicate any aura.
- A button on the minimap (and an entry in the add-on menu) to open and close the window.
- Sounds: six of our own and eight of the game, in three volumes, for empowered abilities.
- Tooltips on every option, and a Send feedback button.
- Tested on a Death Knight. Other classes are not tested yet.
