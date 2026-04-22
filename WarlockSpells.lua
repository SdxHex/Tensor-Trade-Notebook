-- WarlockSpells.lua
-- Affliction core (WoW 12.0.5-safe):
-- - spellID-first aura/cooldown lookups
-- - safe cooldown floor logic
-- - target switch reset guards
-- - Nightfall/Shard Instability proc tracking
-- - GCD + reaction-time + look-ahead DoT refresh logic

local SPELL_IDS = {
  HAUNT = 48181,
  AGONY = 980,
  CORRUPTION = 172,
  UA = 316099,
  SHADOW_BOLT = 686,
  DRAIN_SOUL = 198590,
  DARK_HARVEST = 387016,
  DARKGLARE = 205180,
  NIGHTFALL_BUFF = 264571,
  SHARD_INSTABILITY_BUFF = 1260269,
}

local LABELS = {
  HAUNT = "Haunt",
  AGONY = "Agony",
  CORRUPTION = "Corruption",
  UA = "Unstable Affliction",
  SHADOW_BOLT = "Shadow Bolt",
  DARK_HARVEST = "Dark Harvest",
  DARKGLARE = "Summon Darkglare",
}

-- Your requested human reaction target: 250ms.
local REACTION_TIME = 0.25
local GCD_SPELL_ID = 61304

-- Pandemic windows per request:
-- Haunt/Agony = 3s, Corruption = no pandemic extension behavior.
local PANDEMIC_WINDOW = {
  [SPELL_IDS.HAUNT] = 3.0,
  [SPELL_IDS.AGONY] = 3.0,
  [SPELL_IDS.CORRUPTION] = 0.0,
  [SPELL_IDS.UA] = 4.8, -- optional default (30% of 16s)
}

local STATE = {
  lastTargetGUID = nil,
  lastHauntCastAt = 0,
  lastDHCastAt = 0,
  lastDGCastAt = 0,
  darkglareUntil = 0,
}

local function Now()
  return GetTime()
end

local function SafeNumber(v, default)
  if v == nil then return default or 0 end
  local n = tonumber(tostring(v))
  if n == nil then return default or 0 end
  return n
end

local function GetSpellCDRemainingByID(spellID)
  if not spellID then return 0 end

  if C_Spell and C_Spell.GetSpellCooldownRemaining then
    local rem = SafeNumber(C_Spell.GetSpellCooldownRemaining(spellID), 0)
    if rem > 0 then return rem end
  end

  if C_Spell and C_Spell.GetSpellCooldown then
    local cd = C_Spell.GetSpellCooldown(spellID)
    if cd then
      local startTime = SafeNumber(cd.startTime, 0)
      local duration = SafeNumber(cd.duration, 0)
      if startTime > 0 and duration > 0 then
        return math.max(0, (startTime + duration) - Now())
      end
    end
  end

  return 0
end

local function SafeCDRemaining(spellID, lastCastAt, fullCD)
  local live = GetSpellCDRemainingByID(spellID)
  local floor = math.max(0, SafeNumber(fullCD, 0) - (Now() - SafeNumber(lastCastAt, 0)))
  return math.max(live, floor)
end

local function GetAuraRemainingByID(unit, spellID, filter)
  if not (C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName) then
    return 0
  end
  if not (C_Spell and C_Spell.GetSpellName) then
    return 0
  end
  local spellName = C_Spell.GetSpellName(spellID)
  if not spellName then return 0 end

  local aura = C_UnitAuras.GetAuraDataBySpellName(unit, spellName, filter or "HARMFUL|PLAYER")
  if not aura then return 0 end
  if not aura.expirationTime or aura.expirationTime == 0 then return math.huge end

  return math.max(0, aura.expirationTime - Now())
end

local function DotRemaining(spellID)
  return GetAuraRemainingByID("target", spellID, "HARMFUL|PLAYER")
end

local function HasBuffByID(spellID)
  return GetAuraRemainingByID("player", spellID, "HELPFUL") > 0
end

local function IsNightfallUp()
  return HasBuffByID(SPELL_IDS.NIGHTFALL_BUFF)
end

local function IsShardInstabilityUp()
  return HasBuffByID(SPELL_IDS.SHARD_INSTABILITY_BUFF)
end

local function GCDRemaining()
  return GetSpellCDRemainingByID(GCD_SPELL_ID)
end

local function CurrentCastOrChannelRemaining()
  local _, _, _, startMS, endMS = UnitCastingInfo("player")
  if endMS and startMS then
    local rem = (endMS / 1000) - Now()
    return math.max(0, rem)
  end

  local _, _, _, cStartMS, cEndMS = UnitChannelInfo("player")
  if cEndMS and cStartMS then
    local rem = (cEndMS / 1000) - Now()
    return math.max(0, rem)
  end

  return 0
end

-- Look-ahead lock horizon = what you are currently locked in + next GCD + reaction.
local function LookAheadLockWindow()
  return CurrentCastOrChannelRemaining() + GCDRemaining() + REACTION_TIME
end

local function ShouldRefreshForLookAhead(spellID, remaining)
  local pandemic = PANDEMIC_WINDOW[spellID] or 0
  local lockHorizon = LookAheadLockWindow()

  -- If spell expires before you can realistically act, refresh now.
  if remaining <= lockHorizon then
    return true
  end

  -- For spells with pandemic behavior, also refresh inside that configured window.
  if pandemic > 0 and remaining <= pandemic then
    return true
  end

  return false
end

local function HasValidTarget()
  return UnitExists("target")
    and UnitCanAttack("player", "target")
    and not UnitIsDead("target")
end

local function GetShards()
  return UnitPower("player", Enum.PowerType.SoulShards) or 0
end

local function OnTargetChanged()
  local guid = UnitGUID("target")
  if guid ~= STATE.lastTargetGUID then
    STATE.lastTargetGUID = guid
    -- Target swap bug fix: invalidate stale assumptions by forcing fresh aura reads.
    return true
  end
  return false
end

local function NextSpell()
  if not HasValidTarget() then return "NO TARGET" end

  OnTargetChanged()

  local hauntRem = DotRemaining(SPELL_IDS.HAUNT)
  local agonyRem = DotRemaining(SPELL_IDS.AGONY)
  local corrRem = DotRemaining(SPELL_IDS.CORRUPTION)

  local shards = GetShards()
  local atShardCap = shards >= 5

  local hauntCD = SafeCDRemaining(SPELL_IDS.HAUNT, STATE.lastHauntCastAt, 15)
  local dhCD = SafeCDRemaining(SPELL_IDS.DARK_HARVEST, STATE.lastDHCastAt, 60)
  local dgCD = SafeCDRemaining(SPELL_IDS.DARKGLARE, STATE.lastDGCastAt, 120)

  local hauntReady = hauntCD <= 0.05
  local dhReady = dhCD <= 0.05
  local dgReady = dgCD <= 0.05

  -- Highest value proc spenders first.
  if IsShardInstabilityUp() and shards < 5 then
    return LABELS.UA
  end

  -- Requested behavior: Nightfall proc => prioritize Shadow Bolt immediately.
  if IsNightfallUp() then
    return LABELS.SHADOW_BOLT
  end

  -- DoT look-ahead refresh logic.
  if hauntReady and ShouldRefreshForLookAhead(SPELL_IDS.HAUNT, hauntRem) then
    return LABELS.HAUNT
  end
  if ShouldRefreshForLookAhead(SPELL_IDS.AGONY, agonyRem) then
    return LABELS.AGONY
  end
  if ShouldRefreshForLookAhead(SPELL_IDS.CORRUPTION, corrRem) then
    return LABELS.CORRUPTION
  end

  if atShardCap then
    return LABELS.UA
  end

  if dhReady and (agonyRem > 0 or corrRem > 0 or hauntRem > 0) then
    return LABELS.DARK_HARVEST
  end

  if dgReady and agonyRem > 0 and corrRem > 0 and shards <= 2 then
    return LABELS.DARKGLARE
  end

  if shards >= 1 then
    return LABELS.UA
  end

  return LABELS.SHADOW_BOLT
end

-- Event hooks for cooldown floor tracking.
local frame = CreateFrame("Frame")
frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:SetScript("OnEvent", function(_, event, unit, _, spellID)
  if event == "PLAYER_TARGET_CHANGED" then
    OnTargetChanged()
    return
  end

  if event == "UNIT_SPELLCAST_SUCCEEDED" and unit == "player" and spellID then
    local t = Now()
    if spellID == SPELL_IDS.HAUNT then
      STATE.lastHauntCastAt = t
    elseif spellID == SPELL_IDS.DARK_HARVEST then
      STATE.lastDHCastAt = t
    elseif spellID == SPELL_IDS.DARKGLARE then
      STATE.lastDGCastAt = t
      STATE.darkglareUntil = t + 20
    end
  end
end)

WarlockSpells = WarlockSpells or {}
WarlockSpells.NextSpell = NextSpell
WarlockSpells.State = STATE
WarlockSpells.Config = {
  REACTION_TIME = REACTION_TIME,
  PANDEMIC_WINDOW = PANDEMIC_WINDOW,
}


-- =========================================================
-- HP RING UI (square segmented health bar)
-- Segment order per request:
--   Top    = 0-25%
--   Left   = 26-50%
--   Bottom = 51-75%
--   Right  = 76-100%
-- =========================================================

local function CreateSquareHPBar(parent, size, thickness)
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(size, size)
  f:SetPoint("CENTER")

  thickness = thickness or 6
  f.size = size
  f.thickness = thickness

  f.bg = f:CreateTexture(nil, "BACKGROUND")
  f.bg:SetAllPoints()
  f.bg:SetColorTexture(1, 1, 1, 0.08)

  local function MakeBar(width, height, point, rel, x, y)
    local bar = CreateFrame("StatusBar", nil, f)
    bar:SetSize(width, height)
    bar:SetPoint(point, rel, x, y)
    bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    bar:SetStatusBarColor(1, 0, 0, 1)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    return bar
  end

  -- Top (left -> right): 0-25%
  f.top = MakeBar(size, thickness, "TOPLEFT", f, 0, 0)

  -- Left (top -> bottom): 26-50%
  f.left = MakeBar(thickness, size, "TOPLEFT", f, 0, 0)
  f.left:SetOrientation("VERTICAL")

  -- Bottom (left -> right): 51-75%
  f.bottom = MakeBar(size, thickness, "BOTTOMLEFT", f, 0, 0)

  -- Right (bottom -> top): 76-100%
  f.right = MakeBar(thickness, size, "BOTTOMRIGHT", f, 0, 0)
  f.right:SetOrientation("VERTICAL")
  f.right:SetReverseFill(true)

  function f:SetValue(pct)
    pct = math.max(0, math.min(1, pct or 0))
    local segment = pct * 4

    f.top:SetValue(0)
    f.left:SetValue(0)
    f.bottom:SetValue(0)
    f.right:SetValue(0)

    if segment <= 1 then
      f.top:SetValue(segment)
    elseif segment <= 2 then
      f.top:SetValue(1)
      f.left:SetValue(segment - 1)
    elseif segment <= 3 then
      f.top:SetValue(1)
      f.left:SetValue(1)
      f.bottom:SetValue(segment - 2)
    else
      f.top:SetValue(1)
      f.left:SetValue(1)
      f.bottom:SetValue(1)
      f.right:SetValue(segment - 3)
    end
  end

  return f
end

local function GetPlayerHealthPct()
  local hp = UnitHealth("player") or 0
  local maxHp = UnitHealthMax("player") or 0
  if maxHp <= 0 then return 0 end
  return hp / maxHp
end

local hpParent = _G.WarlockSpellsDisplay or UIParent
local hpRing = CreateSquareHPBar(hpParent, 90, 6)
if _G.WarlockSpellsDisplay then
  hpRing:SetPoint("CENTER", _G.WarlockSpellsDisplay, "CENTER")
else
  hpRing:SetPoint("CENTER", UIParent, "CENTER", 0, -180)
end
hpRing:SetValue(GetPlayerHealthPct())

frame:RegisterEvent("UNIT_HEALTH")
frame:RegisterEvent("UNIT_MAXHEALTH")

local prevOnEvent = frame:GetScript("OnEvent")
frame:SetScript("OnEvent", function(self, event, unit, ...)
  if event == "UNIT_HEALTH" or event == "UNIT_MAXHEALTH" then
    if unit == "player" then
      hpRing:SetValue(GetPlayerHealthPct())
    end
  end

  if prevOnEvent then
    prevOnEvent(self, event, unit, ...)
  end
end)
