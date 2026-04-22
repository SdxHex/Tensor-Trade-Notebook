-- WarlockSpells_lookahead.lua
-- Drop-in rotation improvements focused on Affliction macro flow + look-ahead.

-- =========================================================
-- LOOK-AHEAD TUNING (user reaction + next GCD planning)
-- Human average reaction often ~150-300ms; defaulting to 250ms.
-- =========================================================

local REACTION_TIME = 0.25
local GCD_SECONDS   = 1.5
local LOOKAHEAD     = REACTION_TIME + GCD_SECONDS

-- User macro on key 1 is castsequence-like priority:
-- Haunt -> Agony -> Corruption
-- We model this as one "macro lane" suggestion label.
local LABEL_MACRO_1 = "Haunt/Agony/Corruption"

local function WillNeedRefreshSoon(rem, refreshWindow)
  return rem <= (refreshWindow + LOOKAHEAD)
end

local function InPandemic(rem, pandemicWindow)
  return rem <= pandemicWindow
end

-- Optional proc helpers (safe no-op if aura APIs fail).
local function HasHelpfulBuffByName(name)
  if not (C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName) then
    return false
  end
  return C_UnitAuras.GetAuraDataBySpellName("player", name, "HELPFUL") ~= nil
end

local function HasNightfallProc()
  return HasHelpfulBuffByName("Nightfall")
end

local function HasShardInstabilityProc()
  return HasHelpfulBuffByName("Shard Instability")
end

-- Keep this tiny utility local to avoid nil-comparison edge cases.
local function SafeBool(v)
  return v and true or false
end

-- =========================================================
-- ST PRIORITY (drop-in replacement idea for NextSpell ST branch)
-- =========================================================
-- This function expects the same surrounding helpers/locals used by your
-- current addon (DotRemaining, IsHauntReady, GetDHCD, GetDGCD, GetShards, etc.).
--
-- Return values are LABELS.* style labels plus LABEL_MACRO_1 for key-1 macro.
-- =========================================================

local function NextSpell_SingleTarget_LookAhead(ctx)
  -- ctx fields expected:
  -- hauntRem, agonyRem, corrRem, uaRem
  -- hauntReady, dgReady, dgCD, dhReady, shards, maxShards
  -- hasCoreDots, hasAnyDot
  -- DOT_REFRESH, AGONY_REFRESH, CORR_REFRESH
  -- PANDEMIC_HAUNT, PANDEMIC_AGONY, PANDEMIC_CORR, PANDEMIC_UA

  local hauntSoon = WillNeedRefreshSoon(ctx.hauntRem, ctx.DOT_REFRESH)
  local agonySoon = WillNeedRefreshSoon(ctx.agonyRem, ctx.AGONY_REFRESH)
  local corrSoon  = WillNeedRefreshSoon(ctx.corrRem,  ctx.CORR_REFRESH)

  local hauntPandemic = InPandemic(ctx.hauntRem, ctx.PANDEMIC_HAUNT)
  local agonyPandemic = InPandemic(ctx.agonyRem, ctx.PANDEMIC_AGONY)
  local corrPandemic  = InPandemic(ctx.corrRem,  ctx.PANDEMIC_CORR)
  local uaPandemic    = InPandemic(ctx.uaRem,    ctx.PANDEMIC_UA)

  local atShardCap = ctx.shards >= ctx.maxShards
  local hasShards  = ctx.shards >= 1
  local dgSoon     = (not ctx.dgReady) and ctx.dgCD <= 15
  local burstReady = ctx.shards <= 2

  -- 1) Macro lane first when Haunt is available and Haunt is in pandemic/soon.
  -- This keeps your bound key #1 useful and front-loads amp.
  if SafeBool(ctx.hauntReady) and (hauntPandemic or hauntSoon) then
    return LABEL_MACRO_1
  end

  -- 2) Look-ahead DoT protection:
  -- If UA would push Corruption/Agony/Haunt beyond safe refresh, refresh first.
  -- This is exactly the "Corr then UA" behavior you requested.
  if (corrPandemic or corrSoon or agonyPandemic or agonySoon or hauntSoon) and not ctx.hauntReady then
    if agonyPandemic or agonySoon then
      return "Agony"
    end
    if corrPandemic or corrSoon then
      return "Corruption"
    end
  end

  -- 3) Free damage proc spenders first.
  if HasShardInstabilityProc() then
    return "Unstable Affliction"
  end

  -- 4) Never cap shards.
  if atShardCap then
    return "Unstable Affliction"
  end

  -- 5) Dark Harvest on dots.
  if ctx.dhReady and ctx.hasAnyDot then
    return "Dark Harvest"
  end

  -- 6) Pre-Darkglare drain to <=2 shards.
  if dgSoon and not burstReady and hasShards then
    return "Unstable Affliction"
  end

  -- 7) Fire Darkglare when setup is ready.
  if ctx.dgReady and ctx.hasCoreDots and burstReady then
    return "Summon Darkglare"
  end

  -- 8) Nightfall proc converts filler into instant pressure.
  if HasNightfallProc() then
    return "Shadow Bolt"
  end

  -- 9) Baseline spender / filler.
  if hasShards and uaPandemic then
    return "Unstable Affliction"
  end

  return "Shadow Bolt"
end

return {
  LOOKAHEAD = LOOKAHEAD,
  REACTION_TIME = REACTION_TIME,
  GCD_SECONDS = GCD_SECONDS,
  LABEL_MACRO_1 = LABEL_MACRO_1,
  NextSpell_SingleTarget_LookAhead = NextSpell_SingleTarget_LookAhead,
}
