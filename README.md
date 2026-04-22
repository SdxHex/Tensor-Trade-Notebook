# Tensor-Trade-Notebook
##### Collection of thoughts and notes about my experience trying to beat the market. 
Resources:
GITHUB Author @NotAdamKing
https://github.com/cauchyturing/UCR_Time_Series_Classification_Deep_Learning_Baseline 
https://discordapp.com/channels/592446624882491402/593538654857723909
https://towardsdatascience.com/trade-smarter-w-reinforcement-learning-a5e91163f315 

GITHUB Author @hootnuot
https://github.com/hootnot/oandapyV20-examples 
http://developer.oanda.com/rest-live-v20/instrument-ep/

GITHUB Author @philipperemy
https://github.com/philipperemy/FX-1-Minute-Data/blob/master/download_all_fx_data.py 

https://en.wikipedia.org/wiki/Sortino_ratio

https://hackernoon.com/understanding-architecture-of-lstm-cell-from-scratch-with-code-8da40f0b71f4


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
