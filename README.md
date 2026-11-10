# Rest and Resume

Project Zomboid Build 42 mod. When a repeating job stops because the character is out of breath, they sit on the ground, rest until endurance is back and start the same work again.

| Stopped work | What happens after resting |
|---|---|
| Exercise (`ISFitnessAction`, stops above the 2nd endurance moodle level) | Same exercise again, for the minutes that were left. Uses the fitness window's own OK path when the window is open |
| Chopping a tree (`ISChopTreeAction`, stops at the last endurance level) | Same tree again (vanilla walk/equip/chop). Damage already done stays on the tree |
| [Area Tasks](https://steamcommunity.com/sharedfiles/filedetails/?id=3793163745) job blocked with "Not enough endurance" | Same task on the same area (and destination) again |
| Any other action that ends at the last endurance level | Rest only, nothing restarted |

Resting is cancelled (and the character stands up) when a visible zombie comes within range (or any zombie within 5 tiles, seen or not), the player moves, stands up or queues another action, a hunger/thirst/tired/pain/injured moodle goes above the set level, or the same work was resumed too many times in a row. Exercise that stopped while the pain moodle is above 3 (where vanilla refuses to start exercise) is not resumed.

Options (Options > Mods, per player): on/off, endurance to rest to (default 95%), zombie distance (12), max repeats (5), moodle level (2), text above the character, rest after other actions.

## Install

- Steam Workshop: https://steamcommunity.com/sharedfiles/filedetails/?id=3836875981
- Manual: copy `Contents/mods/RestAndResume` into `%USERPROFILE%\Zomboid\mods\`.

## Compatibility

Client only, no server files. Single player and multiplayer; tested in single player on B42.21 (dedicated server not tested yet). Safe to add or remove mid-save. Resuming queues the same vanilla actions a player would queue, so the server validates them as usual. Vanilla hooks are listed in [`vanilla-deps.txt`](vanilla-deps.txt).

## Test

`pzt live` from this folder (PZTestHarness, one client, all scenarios in `tests/RestAndResume_Test.lua`). `tools/wait_and_run.sh` waits for free memory first.

## Support

If this mod helps you, you can support it via [Ko-fi](https://ko-fi.com/talkinghands2285) or [PayPal](https://www.paypal.com/paypalme/TalkingHands619/3). It's optional; every feature stays free.

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/talkinghands2285)
