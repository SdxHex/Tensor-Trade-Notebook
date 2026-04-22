## Warlock rotation patch (Affliction, 12.0.x)

This repo now includes `WarlockSpells_lookahead.lua`, a drop-in logic module for:
- reaction-time + GCD look-ahead ordering (refresh DoTs before UA when needed),
- macro-lane support for `Haunt -> Agony -> Corruption`,
- safer shard/proc spending priorities for single target.

Intended use: integrate `NextSpell_SingleTarget_LookAhead(ctx)` into the existing addon loop and map `LABEL_MACRO_1` to your key-1 macro indicator.


## Original user code archive

For completeness, the original user-supplied Affliction addon scaffold is archived in:
- `WarlockSpells_original_user.lua`

The look-ahead enhancements remain in:
- `WarlockSpells_lookahead.lua`


## Canonical working file

- `WarlockSpells.lua` is now committed as the baseline full-file workspace for ongoing edits.
- `WarlockSpells_lookahead.lua` keeps the isolated look-ahead logic (reaction time default now 250ms).
