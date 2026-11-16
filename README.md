# Lost Soul

A short, dark pixel-art platformer about a small soul running from the darkness. Made in Godot 4.6 for the
KIT Clementine game jam.

![Forest](docs/screenshots/forest.png)

## The game

Three levels, played in order:

1. **Forest.** An easy introduction to the movement: jumps, double-jump orbs, dash and vine walls. Each
   street lamp is a checkpoint, and when you reach one the camera shows the next stretch. Watch it: twice the
   right way is something you can only know from that preview.
2. **Cave.** A living darkness spreads through the cave behind you. Hidden triggers speed it up or slow it
   down, and the chase music changes with it, so you can hear how close you are to being caught. Lamps keep
   the darkness out.
3. **Lantern cave.** You find a flashlight with a small battery. Shadows freeze and dissolve in its beam,
   walls of darkness burn away, and some guards can only be pushed back for a moment.

![Cave](docs/screenshots/cave.png)

## Controls

| Action | Keys |
|---|---|
| Move | A / D or Left / Right |
| Jump | Space |
| Dash | Shift or F |
| Flashlight (last level) | Z |
| Replay the camera preview at a lamp | W or Up |
| Fullscreen | F11 or Alt+Enter |

Orbs: gold lets you jump once more in the air, teal gives you a dash even while dash is on cooldown.

## Running it

Open the folder in **Godot 4.6** and press Play (the main scene is `scenes/main_menu.tscn`).

To build for Windows, add a "Windows Desktop" export preset in the editor (export presets are not kept in
the repository) and export from *Project → Export*.

## Repository layout

| Path | Contents |
|---|---|
| `scenes/`, `scripts/` | the game: levels in `scenes/levels/`, player in `scripts/player/`, the cave darkness in `scripts/darkness/` |
| `assets/`, `assets/blockholders/` | sprites, tilesets, fonts |
| `audio/`, `audio/jam/` | music and sound; `audio/CREDITS.md` explains how it was made |
| `tools/` | scripts that generate the audio and the orb sprites |
| `trials/` | an unfinished extra mode, hidden from the menu |

## Licence and credits

The source code is under the MIT licence (`LICENSE`). Art, music and sound are not covered by it; see
`CREDITS.md` for who made what and for the third-party assets.
