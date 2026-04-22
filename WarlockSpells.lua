-- Clean core version for WarlockSpells.lua
-- This version includes a simplified rotation engine with deterministic logic
-- focusing on proper application of DoTs, cooldown handling, and shard spending
-- for Affliction warlock with Soul Harvester. 

local addon = CreateFrame("Frame")

-- =========================
-- CONFIG
-- =========================
local DOT_REFRESH   = 3
local AGONY_REFRESH = 4
local CORR_REFRESH  = 4

-- CD durations (seconds)
local DH_COOLDOWN = 45
local DG_COOLDOWN = 120

-- =========================
-- STATE
-- =========================
local STATE = {
  agony = 0,
  corruption = 0,
  haunt = 0,
  ua = 0,
  uaStacks = 0,
  lastDHCastAt = 0,
  lastDGCastAt = 0,
  targetChangedAt = 0,
}

-- =========================
-- SPELLS & LABELS
-- =========================
local SPELLS = {
  AGONY = "Agony",
  CORR = "Corruption",
  HAUNT = "Haunt",
  UA = "Unstable Affliction",
  SEED = "Seed of Corruption",
  SHADOW_BOLT = "Shadow Bolt",
  DARK_HARVEST = "Dark Harvest",
  DARKGLARE = "Summon Darkglare",
}

local LABELS = {
  AGONY = SPELLS.AGONY,
  CORR = SPELLS.CORR,
  HAUNT = SPELLS.HAUNT,
  UA = SPELLS.UA,
  SEED = SPELLS.SEED,
  FILLER = SPELLS.SHADOW_BOLT,
  HARVEST = SPELLS.DARK_HARVEST,
  GLARE = SPELLS.DARKGLARE,
}

local SPELL_IDS = {}

-- =========================
-- HELPERS
-- =========================
local function Now()
  return GetTime()
end

local function ResolveSpellID(name)
  local info = C_Spell.GetSpellInfo(name)
  return info and info.spellID
end

local function ResolveAllSpellIDs()
  for key, name in pairs(SPELLS) do
    SPELL_IDS[key] = ResolveSpellID(name)
  end
end

-- Compute safe cooldown remaining by combining actual cooldown with local fallback
local function SafeCDRemaining(spellID, lastCastAt, fallbackCD)
  local start, duration = GetSpellCooldown(spellID)
  if start and duration and duration > 1.5 then
    return math.max(0, (start + duration) - Now())
  end
  if lastCastAt and lastCastAt > 0 then
    return math.max(0, (lastCastAt + fallbackCD) - Now())
  end
  return 0
end

local function GetDHCD()
  return SafeCDRemaining(SPELL_IDS.DARK_HARVEST, STATE.lastDHCastAt, DH_COOLDOWN)
end

local function GetDGCD()
  return SafeCDRemaining(SPELL_IDS.DARKGLARE, STATE.lastDGCastAt, DG_COOLDOWN)
end

local function GetHauntCD()
  local start, duration = GetSpellCooldown(SPELL_IDS.HAUNT)
  if start and duration then
    return math.max(0, (start + duration) - Now())
  end
  return 0
end

local function IsReady(spellID)
  return GetSpellCooldown(spellID) == 0
end

-- =========================
-- DOT TRACKING
-- =========================
local function GetAuraRemaining(spellID)
  local aura = C_UnitAuras.GetAuraDataBySpellID("target", spellID, "HARMFUL|PLAYER")
  if not aura then return 0 end
  return math.max(0, aura.expirationTime - Now())
end

local function DotRemaining(spellID, stateField)
  local live = GetAuraRemaining(spellID)
  local localRem = math.max(0, STATE[stateField] - Now())
  return math.max(live, localRem)
end

-- =========================
-- CANDIDATE SYSTEM
-- =========================
local function AddCandidate(list, label, score, condition)
  if condition then
    table.insert(list, {label = label, score = score})
  end
end

-- Check if a label is usable (off cooldown)
local function IsLabelUsable(label)
  if label == LABELS.HARVEST then
    return GetDHCD() <= 0.05
  end
  if label == LABELS.GLARE then
    return GetDGCD() <= 0.05
  end
  if label == LABELS.HAUNT then
    return IsReady(SPELL_IDS.HAUNT)
  end
  return true
end

-- Pick the best candidate by highest score among usable labels
local function PickBest(list)
  local best = nil
  for _, c in ipairs(list) do
    if IsLabelUsable(c.label) then
      if not best or c.score > best.score then
        best = c
      end
    end
  end
  return best and best.label or LABELS.FILLER
end

-- =========================
-- MAIN ROTATION LOGIC
-- =========================
local function NextSpell()
  if not UnitExists("target") then
    return "NO TARGET"
  end

  local hauntRem = DotRemaining(SPELL_IDS.HAUNT,      "haunt")
  local agonyRem = DotRemaining(SPELL_IDS.AGONY,      "agony")
  local corrRem  = DotRemaining(SPELL_IDS.CORR,       "corruption")

  local shards = UnitPower("player", Enum.PowerType.SoulShards)

  local dhCD    = GetDHCD()
  local dgCD    = GetDGCD()

  local hauntCD    = GetHauntCD()
  local hauntReady = IsReady(SPELL_IDS.HAUNT)
  local hauntMissing = hauntReady and hauntRem <= 0
  local hauntUp = hauntRem > 0
  local hauntOnCD = hauntCD > 0.05

  local agonyMissing = agonyRem <= 0
  local corrMissing  = corrRem  <= 0

  local isAOE = (GetNumGroupMembers() >= 3)

  local candidates = {}

  -- DOT logic: Always attempt Haunt if ready and missing
  AddCandidate(candidates, LABELS.HAUNT, 110, hauntMissing)

  -- If Haunt is on cooldown, apply missing dots to avoid stalling rotation
  AddCandidate(candidates, LABELS.AGONY,      109, hauntOnCD and agonyMissing)
  AddCandidate(candidates, LABELS.CORR,       108, hauntOnCD and not agonyMissing and corrMissing)

  -- Apply missing dots when Haunt is active
  AddCandidate(candidates, LABELS.AGONY,      107, hauntUp and agonyMissing)
  AddCandidate(candidates, LABELS.CORR,       106, hauntUp and corrMissing)

  -- Refresh dots with pandemic windows when Haunt is up
  AddCandidate(candidates, LABELS.AGONY,      102, hauntUp and agonyRem <= AGONY_REFRESH)
  AddCandidate(candidates, LABELS.CORR,       101, hauntUp and corrRem  <= CORR_REFRESH)

  -- Cooldown usage: summon Darkglare when ready and both core dots are active
  local hasDots = (agonyRem > 0) and (corrRem > 0)
  AddCandidate(candidates, LABELS.GLARE, 100, dgCD <= 0 and hasDots)

  -- Use Dark Harvest when ready and shards are low (prevent overcapping)
  AddCandidate(candidates, LABELS.HARVEST, 99, dhCD <= 0 and shards <= 2)

  -- Shard spending: cast Seed for AOE or UA for single target when shards available
  if shards >= 1 then
    if isAOE then
      AddCandidate(candidates, LABELS.SEED, 90, true)
    else
      AddCandidate(candidates, LABELS.UA,   90, true)
    end
  end

  return PickBest(candidates)
end

-- =========================
-- EVENT HANDLERS
-- =========================
addon:RegisterEvent("PLAYER_TARGET_CHANGED")
addon:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
addon:RegisterEvent("UNIT_AURA")

addon:SetScript("OnEvent", function(_, event, ...)
  if event == "PLAYER_TARGET_CHANGED" then
    STATE.targetChangedAt = Now()
    -- Reset local dot trackers on target change
    STATE.agony = 0
    STATE.corruption = 0
    STATE.haunt = 0
  elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
    local _, subevent, _, _, _, _, _, _, _, _, _, spellID = CombatLogGetCurrentEventInfo()

    if subevent == "SPELL_CAST_SUCCESS" then
      if spellID == SPELL_IDS.DARK_HARVEST then
        STATE.lastDHCastAt = Now()
      elseif spellID == SPELL_IDS.DARKGLARE then
        STATE.lastDGCastAt = Now()
      elseif spellID == SPELL_IDS.HAUNT then
        STATE.haunt = Now() + 18 -- approximate Haunt duration
      elseif spellID == SPELL_IDS.AGONY then
        STATE.agony = Now() + 18
      elseif spellID == SPELL_IDS.CORR then
        STATE.corruption = Now() + 14
      end
    end
  elseif event == "UNIT_AURA" then
    local unit = ...
    if unit == "target" then
      -- Optionally update local dot timers based on aura expiration times
      -- but we rely on aura for primary dot detection via DotRemaining
    end
  end
end)

-- Initialize spell IDs after ADDON_LOADED
addon:RegisterEvent("ADDON_LOADED")
addon:SetScript("OnEvent", function(self, event, ...)
  if event == "ADDON_LOADED" then
    local name = ...
    if name == "WarlockSpells" then
      ResolveAllSpellIDs()
    end
  end
end)

-- Slash command for testing: print the next spell recommendation
SLASH_WARLOCKSPELLS1 = "/ws"
SlashCmdList["WARLOCKSPELLS"] = function()
  print("Next spell:", NextSpell())
end
