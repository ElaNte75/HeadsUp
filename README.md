# HeadsUp

**HeadsUp** shows the important "press this now" icon at the moment it matters, so you do not get tunnel vision in a fight. It is a World of Warcraft add-on for **Retail (Midnight, 12.x)** and works for **every class and specialization**.

You build your own icons ("auras") with a simple step-by-step window: choose an ability, tell HeadsUp *when* it should show, and place it on the screen. Each icon shows only when **all** the conditions you chose are true.

> **Beta (1.0 beta).** It was built and tested on a Death Knight. Other classes should work, but they are not tested yet: please tell us what you find (see *Feedback*).

## What you can do

- **Conditions** (combine as many as you like):
  - your health and the enemy's health (below, equal or below, equal, equal or above, above, with a percent)
  - the enemy is alive
  - your resources, matched to your class: the main one (Runic Power, Mana, Rage...) and the second one (Runes, Holy Power, Combo Points, Soul Shards, Chi...)
  - the ability is available (not on cooldown, and you have enough resource)
  - cooldown, charges, and a hide time after you cast it
  - the ability is **empowered** (lit up by a proc such as Dark Succor or Killing Machine), with an option to show the icon whenever it is empowered, whatever the other conditions say
- **Where and for whom**: only in combat, out of combat, mounted, in a vehicle, and for chosen specializations. Optionally keep the icon for a few seconds after combat.
- **Look**: any icon from the game, any size (width and height), an optional glow or pulse, a display priority when icons overlap, and three eye-catching effects (Sunburst, Flame, Burst) for empowered abilities.
- **Place it exactly**: drag it with the mouse, or type the X and Y position.
- **Many auras**: keep as many as you want, deactivate the ones you do not need now (without deleting them) and activate them again later.

HeadsUp works within the rules of the current game: it never reads hidden values in a way the game forbids.

## Install

1. Download the latest release (or the `HeadsUp` folder of this repository).
2. Put the `HeadsUp` folder in `World of Warcraft/_retail_/Interface/AddOns/`.
3. Start the game (or `/reload`).

## Use

- Type `/headsup` to open the window, or click the **HeadsUp button on the minimap** (drag it to move it; `/headsup minimap` hides or shows it). It is also in the add-on menu of the minimap.
- Step 1 **Aura**: ability, name, icon, size, position, look.
  Step 2 **Status**: health, enemy, resources.
  Step 3 **Ability**: availability, cooldown, charges, empowered.
  Step 4 **Situation**: where and for whom it shows.
- Press **Save aura**. Drag the icon where you want it (or type its position).
- Hover over any option for a short explanation. Right-click an aura in the list for more (rename, edit, duplicate, deactivate, delete).

## Feedback

Your feedback is very important: tell us what problem you ran into, what you need, or which ability did not work well. Use the **Send feedback** button in the window, or leave a comment on the CurseForge page of the add-on.

## For developers

- `HeadsUp/HeadsUp.lua`: the core (the icons and their conditions).
- `HeadsUp/UI.lua`: the small interface toolkit (grid, cards, controls).
- `HeadsUp/Settings.lua`: the settings window.
- `HeadsUp/KnownGlows.lua`: which abilities can light up, made from the game's own data by `tools/make_glows.py` (run it again after a patch). Do not edit it by hand.

## License

All Rights Reserved. See `LICENSE`.

Author: ElaNte
