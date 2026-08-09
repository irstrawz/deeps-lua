# Deeps (Lua) — damage meter for Ashita v4

A pure-Lua damage meter for FFXI on Ashita v4, written as a replacement for
the Deeps C++ plugin.

## Why this exists

Two separate projects share the name Deeps:

- **kjLotus's Deeps** — an Ashita **v2** C++ plugin. Its source is in this
  repository (`main.cpp`, `Deeps.h`, the Visual Studio project). It uses the
  v2/v3 `GetDataManager()` API and cannot load on v4 at all.
- **relliko/Deeps** — an Ashita v4 C++ plugin, and the version HorizonXI
  approves. Its newest build targets Ashita interface **4.16**.

Ashita 4.3 reports `ASHITA_INTERFACE_VERSION = 4.30` and requires plugins to
export `expCreatePlugin`, `expDestroyPlugin` and `expGetInterfaceVersion`. The
i4.16 build exports only two of the three, which produces:

```
Failed to load plugin 'deeps'. Reason: Plugin is missing required exports.
```

Both problems are fixed by recompiling against the current SDK, which needs
Visual Studio. `Deeps.lua` sidesteps the issue entirely: an addon has no
compiled component, so it cannot break on an interface version bump.

## Usage

```
/addon load deeps
```

| Command | Effect |
| --- | --- |
| `/dps` | Toggle the window |
| `/dps reset` | Clear all data |
| `/dps party` | Party only vs whole alliance |
| `/dps acc` | Show or hide the accuracy column |
| `/dps width <px>` | Window width |
| `/dps idle <sec>` | Auto-clear after inactivity (0 = never) |
| `/dps debug` | Log every parsed action to chat |

Click a bar to expand accuracy, best hit, combat time and a damage breakdown
by source. Drag the window body to move it.

## How it works

Reads the 0x28 action packet directly. Bit offsets from the start of the
packet, header included:

```
bit  40   actor id        (32)
bit  72   target count    (10)
bit  82   category         (4)
bit  86   param           (10)
bit 150   first target block

per target:  id (32), action count (4)
per action:  reaction (5), animation (12), effect (4), stagger (6),
             param (17), message (10), unknown (31),
             has additional effect (1) -> animation (10), param (17), message (10)
             has spike effect (1)      -> animation (10), param (14), message (10)
```

This layout reproduces both facts known from the working Ashita v3
RollTracker — the first action's param sits at bit 213, and a single-action
target block is 123 bits wide — and round-trips synthetic multi-target,
multi-hit packets including the conditional effect blocks.

**Damage is identified without a message-id table.** The usual approach is a
lookup of FFXI message ids to separate damage from healing, which is fragile
across servers. Instead: if the *target* is a party or alliance member the
action is a cure or a buff and is ignored; otherwise positive param counts as
damage. Cures and buffs land on members by definition, so they filter
themselves out.

**DPS uses active combat time, not wall clock.** Gaps longer than ten seconds
between a player's actions count as downtime and do not advance their clock.
Players who act less frequently than that window fall back to the party's
clock rather than reading as a flat zero.

**Accuracy** is derived from melee and ranged attacks only, where one action
equals one attempt. A "miss" means the action dealt no damage, so it also
captures parries, guards and shadows.

**Pet damage is credited to the owner.** A pet acts under its own server id,
so it is mapped back to its owner by chaining `GetMemberTargetIndex` →
`GetPetTargetIndex` → `GetServerId`, rebuilt per packet so resummons and BST
charms are picked up without stale state. Pet output is tracked under its own
`Pet` label rather than merged into the owner's melee, and pet swings are
excluded from the owner's accuracy. Blood pacts, ready moves and automaton
attacks arrive as monster ability categories (11 and 13), which are accepted
only once the actor has been confirmed as a party member's pet.

## Known gaps

- Non-party players are not tracked.
- Weaponskills, spells and abilities are excluded from accuracy, as they do
  not map cleanly onto an attempt count.

## Licence

`Deeps.lua` is original work. The C++ sources in this repository are
kjLotus's Deeps and remain under their original terms.
