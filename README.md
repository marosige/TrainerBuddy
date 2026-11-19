<p align="center"><img src="icon/TrainerBuddy_icon_512.png" width="160" alt="Trainer Buddy icon"></p>

# Trainer Buddy

A World of Warcraft: Forever addon that makes trainer visits less tedious.

## Features

- **Hide trainer entries**: right-click an entry in a class, pet or profession trainer window to hide the spell or recipe (all of its ranks). Hidden entries disappear from the list. Tick **Hidden** under *Settings > Filters* in the trainer window to show them again (marked, with *Unhide* in the right-click menu).
- **Train All**: a button left of *Train* that buys every available, non-hidden entry you can afford and shows the cost in its tooltip. Profession unlocks still use the normal Train button.
- **Hidden list** (grouped by class, pet and each profession, collapsible): *Settings > AddOns > Trainer Buddy*, `/trb`, or *Hidden entries...* in the trainer's Settings menu (the same menu also toggles auto-upgrade and the new-spells popup). Unhide entries one by one or all at once (*Unhide all* asks *Are you sure?* first: click it again to confirm).
- **Action bar auto-upgrade** (toggle): after learning a new rank, replaces your previous highest rank on your action bars. Lower ranks you keep on purpose (downranking) stay.
- **New spells popup** (toggle): a small bar listing newly learned spells that are not on any action bar yet. Drag them onto your bars; it stays until you close it with the X.

## Install

Copy this folder into `_forever_/Interface/AddOns/` and name it `TrainerBuddy`, so that `TrainerBuddy/TrainerBuddy.toc` exists. Then `/reload`.

## Release zip

`./make-zip.sh` (macOS, Linux or Git Bash on Windows) builds `dist/TrainerBuddy-<version>.zip` with a single `TrainerBuddy/` folder holding only the game files, ready to upload to CurseForge. The version comes from the TOC. Add new textures or Lua files to `FILES` in the script; it stops with an error if the addon references a file that is not packaged.

## Commands

| Command | Action |
| --- | --- |
| `/trb`, `/trainerbuddy` | open the settings / hidden list |
| `/trb auto` | toggle action bar auto-upgrade |
| `/trb popup` | toggle the new-spells popup |
| `/trb test [count]` | preview the popup with `count` random spells from your action bars (no number: empty popup). Calling it again replaces the preview; close it with the X |
| `/trb help` | list all commands |

## Notes

- Targets the Forever client (retail-based, `## Interface: 16001`). If the game flags it as out of date, check your build with `/dump (select(4, GetBuildInfo()))` and adjust the TOC.
- Druid form upgrades use Classic spell IDs (see `UPGRADES` in `TrainerBuddy.lua`); add pairs there if Forever differs.
- Settings are saved per character.
