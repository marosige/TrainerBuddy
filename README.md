<p align="center"><img src="icon/TrainerBuddy_icon_512.png" width="160" alt="Trainer Buddy icon"></p>

# Trainer Buddy

A World of Warcraft: Forever addon that makes trainer visits less tedious.

## Features

- **Hide trainer entries**: right-click an entry in a class, pet or profession trainer window to hide just that rank or every rank of the spell/recipe. Hidden entries disappear from the list.
- **Train All**: a button left of *Train* that buys every available, non-hidden entry you can afford and shows the total cost. Profession unlocks still use the normal Train button.
- **Hidden list**: *Settings > AddOns > Trainer Buddy*, `/tb`, or the trainer's Filter menu. Restore entries one by one or all at once.
- **Action bar auto-upgrade** (toggle): after learning a new rank, replaces the old rank on your action bars.
- **New spells popup** (toggle): a small bar listing newly learned spells that are not on any action bar yet. Drag them onto your bars; it stays until you close it with the X.

## Install

Copy this folder into `_forever_/Interface/AddOns/` and name it `TrainerBuddy`, so that `TrainerBuddy/TrainerBuddy.toc` exists. Then `/reload`.

## Commands

| Command | Action |
| --- | --- |
| `/tb`, `/trainerbuddy` | open the settings / hidden list |
| `/tb auto` | toggle action bar auto-upgrade |
| `/tb popup` | toggle the new-spells popup |

## Notes

- Targets the Forever client (retail-based, `## Interface: 16001`). If the game flags it as out of date, check your build with `/dump (select(4, GetBuildInfo()))` and adjust the TOC.
- Druid form upgrades use Classic spell IDs (see `UPGRADES` in `TrainerBuddy.lua`); add pairs there if Forever differs.
- Settings are saved per character. The Forever beta may not reload addon settings at login.
