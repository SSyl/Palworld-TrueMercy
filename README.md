# True Mercy

Stops burn and poison from killing a pal when you have the Mercy ring on or your pal has the Mercy Hit passive.

## The problem

Mercy stops you knocking a pal below 1 HP so you can weaken it and throw a sphere. But burn keeps ticking after that and kills it at 1 HP anyway. Poison does the same.

## What it changes

Burn and poison can't take a pal's last point of health while Mercy applies. They still hurt normally the whole way down. Nothing else is touched.

## Where to install it

Health is decided by whoever hosts, so it has to run there.

| How you play | Where it goes |
|---|---|
| Singleplayer | Your own game |
| Hosting co-op | Your own game, friends need nothing |
| Dedicated server | The server, clients need nothing |

A client-only install does nothing and says so:

```
[TrueMercy] not the authority - install this on the host or dedicated server. Nothing will be protected here.
```

## Install

Copy this folder into `.../UE4SS/Mods/TrueMercy`. `enabled.txt` is what tells UE4SS to load it.

## Settings

`Scripts/config.lua`. Anything missing or mistyped falls back to its default and says so.

| Setting | Default | What it does |
|---|---|---|
| `ProtectFromBurn` | `true` | Burn can't take a protected pal's last HP |
| `ProtectFromPoison` | `true` | Same for poison |
| `DebugLogging` | `false` | Logs each pal it protects or skips. Noisy in play. Never hides errors |

## What's protected

A pal survives at 1 HP if it was burned or poisoned by:

- you, wearing the Mercy Ring
- a pal you're riding, while you wear the ring
- any pal with the Mercy Hit passive, ridden or not

## What isn't

- **Your pal fighting on foot, with only the ring.** A pal inherits your ring only while you ride it. That's base game behavior. Ride it, or use one with Mercy Hit.
- **Lava, campfires, environmental fire.** Nothing attacked the pal, so there's nothing to inherit.
- **Wild pals fighting each other**, unless one has Mercy Hit.

## Checking it works

Set `DebugLogging = true`, reload, and weaken a pal with fire or poison while Mercy is active:

```
[TrueMercy] loaded - burn and poison will respect Mercy on the authority (debug logging on)
[TrueMercy] held BP_PinkCat_C_... at 1 HP - poison from BP_DarkAlien_C_... (own Mercy), tick 6 -> 0 (hp was 1)
```

One line per pal, not per tick. Skips are logged with a reason. Turn it back off when you're done.
