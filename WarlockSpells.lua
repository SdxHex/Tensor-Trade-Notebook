-- WarlockSpells.lua
-- 12.0.x API safe
-- C_UnitAuras for live DoT tracking (no haste/pandemic drift)
-- UNIT_AURA event-driven updates
-- SPELL_UPDATE_COOLDOWN subscription
-- SafeCDRemaining floor for DG/DH
-- Pandemic-aware local fallback in ApplyCast


-- =========================================================
-- WarlockSpells TODO Roadmap
-- =========================================================

-- 🔴 CORE STABILITY (do first)
-- [ ] Remove all leftover health logic (avoid taint / crashes)
-- [ ] Ensure all helper functions exist (no globals like GetDHCD, etc.)
-- [ ] Standardize helpers:
--     [ ] GetSpellCDRemainingByID
--     [ ] DotRemaining
--     [ ] IsSpellReadyByID
-- [ ] Remove unused STATE fields:
--     [ ] lastSuggestion
--     [ ] lastSuggestionAt
--     [ ] lastHealthPct
--     [ ] lastHealthRaw
-- [ ] Add nil guards where needed (no nil comparisons)

-- 🟡 ROTATION ENGINE (current focus)
-- [ ] Fix target switching:
--     - If Haunt on CD + fresh target → fallback (filler or safe option)
-- [ ] Finalize DoT logic:
--     - Haunt = priority
--     - DoTs not gated incorrectly
--     - Macro-aware behavior (skip impossible suggestions)
-- [ ] Ensure IsLabelUsable() filters ALL candidates correctly
-- [ ] Add debug mode:
--     - /wsdebug → print chosen spell + reason

-- 🟢 SPEC SYSTEM (future flexibility)
-- [ ] Add spec selector:
--     local SPEC = "AFFLICTION"
-- [ ] Split rotation logic:
--     [ ] NextSpell_Affliction()
--     [ ] NextSpell_Demonology()
--     [ ] NextSpell_Destruction()
-- [ ] Add dispatcher in NextSpell()

-- 🔵 UI / UX IMPROVEMENTS
-- [ ] Hide UI when no target
-- [ ] Add "opener blocked" visual state
-- [ ] Optional: show reason for suggestion (debug text)
-- [ ] Optional: lightweight sound cues

-- 🟣 SMART COMBAT FEATURES
-- [ ] Detect enemy casts (via combat log):
--     - knockbacks
--     - big damage abilities
-- [ ] React to mechanics:
--     - pause casts
--     - suggest movement-safe spells
-- [ ] Add simple combat awareness system

-- ⚔️ BURST WINDOW INTELLIGENCE
-- [ ] Detect Darkglare window
-- [ ] Detect Dark Harvest timing
-- [ ] Pre-align:
--     - refresh DoTs before DG
--     - spend shards before DH

-- 🧩 MACRO-AWARE LOGIC (your system)
-- [ ] Treat Haunt/Agony/Corruption as one macro flow
-- [ ] Avoid recommending spells macro cannot execute
-- [ ] Ensure smooth fallback when Haunt is on CD

-- 🟠 PERFORMANCE / CLEANUP
-- [ ] Remove duplicate forward declarations
-- [ ] Group helper functions together
-- [ ] Organize file sections:
--     [ ] core
--     [ ] rotation
--     [ ] UI
-- [ ] Consider splitting file later if needed

-- 🟤 INTEGRATIONS
-- [ ] Evaluate DBM / BigWigs integration (optional)
-- [ ] Prefer combat log tracking over addon dependency
-- [ ] Optional WeakAura-style triggers
-- [ ] Optional Plater integration (enemy casts / priority targets)

-- 🔥 EXPERIMENTAL / NEXT LEVEL
-- [ ] Replace priority system with scoring system:
--     score["HAUNT"] = 110
--     score["UA"] = 85
-- [ ] Dynamically pick highest score instead of hard priority
-- [ ] Improve decision transparency

-- 🧭 NEXT STEPS
-- [ ] Stabilize (no errors)
-- [ ] Lock rotation behavior
-- [ ] Add spec system
-- [ ] Add combat awareness
-- [ ] Refactor / clean

-- =========================================================
-- END TODO
-- =========================================================

-- =========================================================
-- CONSTANTS
-- =========================================================

local DOT_REFRESH    = 1.5
local AGONY_REFRESH  = 1.5
local CORR_REFRESH   = 1.5

local DG_SOON_WINDOW  = 10
local RECOVER_WINDOW  = 4
local DH_COOLDOWN     = 60
local DH_READY_BUFFER = 5
local DG_COOLDOWN     = 120
local DARKGLARE_DURATION = 20

local LABELS = {
  HAUNT      = "Haunt",
  AGONY      = "Agony",
  CORRUPTION = "Corruption",
  UA         = "Unstable Affliction",
  FILLER     = "Shadow Bolt",
  HARVEST    = "Dark Harvest",
  GLARE      = "Summon Darkglare",
  SEED       = "Seed of Corruption",
}

local SPELLS = {
  HAUNT        = "Haunt",
  AGONY        = "Agony",
  CORRUPTION   = "Corruption",
  UA           = "Unstable Affliction",
  SHADOW_BOLT  = "Shadow Bolt",
  DRAIN_SOUL   = "Drain Soul",
  DARK_HARVEST = "Dark Harvest",
  DARKGLARE    = "Summon Darkglare",
  SEED         = "Seed of Corruption",
}

local DURATIONS = {
  [SPELLS.HAUNT]      = 18,
  [SPELLS.AGONY]      = 18,
  [SPELLS.CORRUPTION] = 14,
  [SPELLS.UA]         = 16,
}

-- 30% pandemic windows per spell
local PANDEMIC = {
  [SPELLS.AGONY]      = DURATIONS[SPELLS.AGONY]      * 0.3,
  [SPELLS.CORRUPTION] = DURATIONS[SPELLS.CORRUPTION] * 0.3,
  [SPELLS.UA]         = DURATIONS[SPELLS.UA]          * 0.3,
  [SPELLS.HAUNT]      = DURATIONS[SPELLS.HAUNT]       * 0.3,
}

-- =========================================================
-- STATE
-- =========================================================

local STATE = {
  -- Local DoT fallback timestamps (used only when C_UnitAuras unavailable)
  haunt            = 0,
  agony            = 0,
  corruption       = 0,
  ua               = 0,
  uaStacks         = 0,
  lastHauntCastAt = 0,
  -- DG window tracking
  darkglareUntil   = 0,
  darkglareEndedAt = 0,
  darkglareReadyAt = 0,

  -- Local cast timestamps (hard floor against API glitches)
  lastDHCastAt     = 0,
  lastDGCastAt     = 0,
  lastCastAt       = 0,

  -- Target/swap tracking
  targetChangedAt  = 0,

  -- Damage flash
  damageFlashUntil = 0,

  -- Suggestion lock (anti-flicker during GCD)
  lastSuggestion   = nil,
  lastSuggestionAt = 0,

  -- debug
  lastPhase        = "",
}

-- =========================================================
-- FORWARD DECLARATIONS
-- =========================================================

local Now
local FindSpellKeybindByName
local display
local SaveSettings
local BuildOptionsPanel

-- =========================================================
-- VISUAL SETTINGS
-- =========================================================

WarlockSpellsDB = WarlockSpellsDB or {}

local DEFAULT_ICON_SIZE         = 64
local DEFAULT_KEYBIND_FONT_SIZE = 18
local BORDER_SIZE               = 3
local UPDATE_INTERVAL           = 0.10

local FRAME_X           = nil
local FRAME_Y           = nil
local FRAME_LOCKED      = false
local BORDER_HIDDEN     = false
local DISPLAY_ALPHA     = 1.0
local ICON_SIZE_SETTING = DEFAULT_ICON_SIZE
local KEYBIND_FONT_SIZE = DEFAULT_KEYBIND_FONT_SIZE
local BORDER_COLOR      = { r = 0, g = 0.8, b = 1 }

local optionsCategory = nil

-- =========================================================
-- DISPLAY FRAME
-- =========================================================

display = CreateFrame("Frame", "WarlockSpellsDisplay", UIParent)
Now = function() return GetTime() end

display:SetSize(DEFAULT_ICON_SIZE + BORDER_SIZE * 2, DEFAULT_ICON_SIZE + BORDER_SIZE * 2)
display:SetPoint("CENTER", 0, -180)
display:SetMovable(true)
display:EnableMouse(true)
display:RegisterForDrag("LeftButton")
display:SetScript("OnDragStart", display.StartMoving)
display:SetScript("OnDragStop", function(self)
  self:StopMovingOrSizing()
  FRAME_X = math.floor(self:GetLeft()   or FRAME_X or 0)
  FRAME_Y = math.floor(self:GetBottom() or FRAME_Y or 0)
  if SaveSettings then SaveSettings() end
end)

-- Outer glow
display.glowOuter = display:CreateTexture(nil, "BACKGROUND")
display.glowOuter:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
display.glowOuter:SetBlendMode("ADD")
display.glowOuter:SetVertexColor(BORDER_COLOR.r, BORDER_COLOR.g, BORDER_COLOR.b)
display.glowOuter:SetSize(DEFAULT_ICON_SIZE + 40, DEFAULT_ICON_SIZE + 40)
display.glowOuter:SetPoint("CENTER", 0, 0)
display.glowOuter:SetAlpha(0.25)

-- Idle glow pulse
local glowPulse = display.glowOuter:CreateAnimationGroup()
glowPulse:SetLooping("BOUNCE")
local glowFade = glowPulse:CreateAnimation("Alpha")
glowFade:SetFromAlpha(0.1)
glowFade:SetToAlpha(0.4)
glowFade:SetDuration(1.2)
glowFade:SetSmoothing("IN_OUT")
glowPulse:Play()

-- Damage flash animation
local damagePulse = display.glowOuter:CreateAnimationGroup()
local pulseIn  = damagePulse:CreateAnimation("Alpha")
pulseIn:SetFromAlpha(0.25)
pulseIn:SetToAlpha(1.0)
pulseIn:SetDuration(0.08)
pulseIn:SetOrder(1)
local pulseOut = damagePulse:CreateAnimation("Alpha")
pulseOut:SetFromAlpha(1.0)
pulseOut:SetToAlpha(0.25)
pulseOut:SetDuration(0.35)
pulseOut:SetOrder(2)

-- Border
display.border = display:CreateTexture(nil, "BORDER")
display.border:SetSize(DEFAULT_ICON_SIZE + BORDER_SIZE * 2, DEFAULT_ICON_SIZE + BORDER_SIZE * 2)
display.border:SetPoint("CENTER", 0, 0)
display.border:SetColorTexture(BORDER_COLOR.r, BORDER_COLOR.g, BORDER_COLOR.b, 1)

-- Spell icon
display.icon = display:CreateTexture(nil, "ARTWORK")
display.icon:SetSize(DEFAULT_ICON_SIZE, DEFAULT_ICON_SIZE)
display.icon:SetPoint("CENTER", 0, 0)
display.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
display.icon:SetDrawLayer("ARTWORK", 2)

-- Cooldown sweep
display.cooldown = CreateFrame("Cooldown", nil, display, "CooldownFrameTemplate")
display.cooldown:SetSize(DEFAULT_ICON_SIZE, DEFAULT_ICON_SIZE)
display.cooldown:SetPoint("CENTER", display, "CENTER", 0, 0)
display.cooldown:SetDrawEdge(true)
display.cooldown:SetDrawSwipe(true)
display.cooldown:SetReverse(false)
display.cooldown:SetHideCountdownNumbers(true)
display.cooldown:SetSwipeColor(0, 0, 0, 0.8)

-- Keybind overlay
local keybindOverlay = CreateFrame("Frame", nil, display)
keybindOverlay:SetSize(DEFAULT_ICON_SIZE, DEFAULT_ICON_SIZE)
keybindOverlay:SetPoint("CENTER", display, "CENTER", 0, 0)
display:HookScript("OnShow", function()
  keybindOverlay:SetFrameLevel(display.cooldown:GetFrameLevel() + 2)
end)

display.keybind = keybindOverlay:CreateFontString(nil, "OVERLAY")
display.keybind:SetFont("Fonts\\FRIZQT__.TTF", DEFAULT_KEYBIND_FONT_SIZE, "OUTLINE")
display.keybind:SetPoint("BOTTOM", keybindOverlay, "BOTTOM", 0, 4)
display.keybind:SetTextColor(1, 1, 1, 1)
display.keybind:SetText("")

-- =========================================================
-- DAMAGE FLASH
-- Threshold-gated: only fires on 2%+ HP loss per event.
-- Avoids noise from absorb/minor tick variance.
-- =========================================================

local function UpdateDamageFlash()
  local flashing = Now() < STATE.damageFlashUntil
  if flashing then
    display.border:SetColorTexture(1, 0.15, 0.15, 1)
    display.glowOuter:SetVertexColor(1, 0.15, 0.15)
    display.glowOuter:SetAlpha(0.9)
    if not damagePulse:IsPlaying() then damagePulse:Play() end
  else
    display.border:SetColorTexture(BORDER_COLOR.r, BORDER_COLOR.g, BORDER_COLOR.b, 1)
    display.glowOuter:SetVertexColor(BORDER_COLOR.r, BORDER_COLOR.g, BORDER_COLOR.b)
    display.glowOuter:SetAlpha(0.25)
  end
end

-- =========================================================
-- SETTINGS
-- =========================================================

local function GetCurrentSpecID()
  local specIndex = GetSpecialization()
  if not specIndex then return 0 end
  local id = GetSpecializationInfo(specIndex)
  return id or 0
end

local function LoadSettings()
  local specID = GetCurrentSpecID()
  if specID == 0 then return false end
  local db = WarlockSpellsDB[specID] or {}
  if db.keybindFontSize         then KEYBIND_FONT_SIZE  = db.keybindFontSize  end
  if db.borderColor             then BORDER_COLOR        = db.borderColor      end
  if db.frameLocked  ~= nil     then FRAME_LOCKED        = db.frameLocked      end
  if db.frameX       ~= nil     then FRAME_X             = db.frameX           end
  if db.frameY       ~= nil     then FRAME_Y             = db.frameY           end
  if db.borderHidden ~= nil     then BORDER_HIDDEN       = db.borderHidden     end
  if db.displayAlpha ~= nil     then DISPLAY_ALPHA       = db.displayAlpha     end
  if db.iconSize     ~= nil     then ICON_SIZE_SETTING   = db.iconSize         end
  return true
end

SaveSettings = function()
  local specID = GetCurrentSpecID()
  if specID == 0 then return end
  WarlockSpellsDB[specID] = WarlockSpellsDB[specID] or {}
  local db = WarlockSpellsDB[specID]
  db.keybindFontSize = KEYBIND_FONT_SIZE
  db.borderColor     = BORDER_COLOR
  db.frameLocked     = FRAME_LOCKED
  db.frameX          = FRAME_X
  db.frameY          = FRAME_Y
  db.borderHidden    = BORDER_HIDDEN
  db.displayAlpha    = DISPLAY_ALPHA
  db.iconSize        = ICON_SIZE_SETTING
end

local function ApplyKeybindFontSize()
  display.keybind:SetFont("Fonts\\FRIZQT__.TTF", KEYBIND_FONT_SIZE, "OUTLINE")
end

local function ApplyBorderColor()
  if BORDER_HIDDEN then
    display.border:SetAlpha(0)
    display.glowOuter:SetAlpha(0)
    glowPulse:Stop()
  else
    glowPulse:Play()
    display.border:SetAlpha(1)
    display.glowOuter:SetAlpha(1)
  end
end

local function ApplyFrameLock()
  if FRAME_LOCKED then
    display:SetMovable(false)
    display:RegisterForDrag()
  else
    display:SetMovable(true)
    display:RegisterForDrag("LeftButton")
  end
end

local function ApplyFramePosition()
  if FRAME_X ~= nil and FRAME_Y ~= nil then
    display:ClearAllPoints()
    display:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", FRAME_X, FRAME_Y)
  end
end

local function ApplyDisplayAlpha() display:SetAlpha(DISPLAY_ALPHA) end

local function ApplyIconSize()
  local sz  = ICON_SIZE_SETTING
  local bsz = sz + BORDER_SIZE * 2
  display:SetSize(bsz, bsz)
  display.border:SetSize(bsz, bsz)
  display.icon:SetSize(sz, sz)
  display.cooldown:SetSize(sz, sz)
  display.glowOuter:SetSize(sz + 40, sz + 40)
  keybindOverlay:SetSize(sz, sz)
end

-- =========================================================
-- SPELL ID RESOLUTION
-- Resolved once at load — never re-resolved mid-fight
-- =========================================================

local function ResolveSpellID(spellName)
  if C_Spell and C_Spell.GetSpellInfo then
    local info = C_Spell.GetSpellInfo(spellName)
    if info and info.spellID then return info.spellID end
  end
  if GetSpellInfo then
    local id = select(7, GetSpellInfo(spellName))
    if id then return id end
  end
  return nil
end

local SPELL_IDS = {}
local function ResolveAllSpellIDs()
  SPELL_IDS.HAUNT        = ResolveSpellID("Haunt")               or 48181
  SPELL_IDS.AGONY        = ResolveSpellID("Agony")               or 980
  SPELL_IDS.CORRUPTION   = ResolveSpellID("Corruption")          or 172
  SPELL_IDS.UA           = ResolveSpellID("Unstable Affliction")  or 316099
  SPELL_IDS.DARK_HARVEST = ResolveSpellID("Dark Harvest")        or 387166
  SPELL_IDS.DARKGLARE    = ResolveSpellID("Summon Darkglare")     or 205180
end

-- =========================================================
-- DOT TRACKING — C_UnitAuras primary, local timestamp fallback
--
-- GetAuraRemaining: reads live from C_UnitAuras.GetAuraDataBySpellName.
-- This is haste-aware and pandemic-correct because the game itself
-- owns the expirationTime.
--
-- Local STATE timestamps (STATE.agony etc.) are kept as a fallback
-- for the rare case where C_UnitAuras is unavailable or returns nil
-- on the frame the cast fires (brief async window). The fallback
-- uses pandemic-aware math so it doesn't undercount the real expiry.
-- =========================================================

local function GetAuraRemainingBySpellID(unit, spellID)
  if not (C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName) then
    return nil
  end
  if not spellID then
    return nil
  end

  -- Fallback approach: still use name if direct ID lookup API isn't available
  local spellName = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
  if not spellName then
    return nil
  end

  local aura = C_UnitAuras.GetAuraDataBySpellName(unit, spellName, "HARMFUL|PLAYER")
  if not aura then
    return 0
  end
  if not aura.expirationTime or aura.expirationTime == 0 then
    return math.huge
  end
  return math.max(0, aura.expirationTime - Now())
end

local function DotRemaining(spellID, stateField)
  local live     = GetAuraRemainingBySpellID("target", spellID)
  local localRem = math.max(0, (STATE[stateField] or 0) - Now())
  if live == nil then return localRem end
  return math.max(live, localRem)
end



local function GetUAStacks()
  if C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName then
    local aura = C_UnitAuras.GetAuraDataBySpellName("target", SPELLS.UA, "HARMFUL|PLAYER")
    return aura and aura.applications or 0
  end
  return STATE.uaStacks  -- fallback
end



-- =========================================================
-- COOLDOWN READS
--
-- Core rule: live API when available, local cast timestamps
-- act as a hard floor. Fixes 12.0.x GetSpellCDRemainingByID = 0 bug.
-- =========================================================

local function SafeNumber(v, default)
  if v == nil then return default or 0 end
  return tonumber(tostring(v)) or default or 0
end

local function GetSpellCDRemainingByID(spellID)
  if not spellID then return 0 end

  if C_Spell and C_Spell.GetSpellCooldownRemaining then
    local rem = C_Spell.GetSpellCooldownRemaining(spellID)
    rem = SafeNumber(rem, 0)
    if rem > 0 then
      return rem
    end
  end

  if C_Spell and C_Spell.GetSpellCooldown then
    local info = C_Spell.GetSpellCooldown(spellID)
    if info then
      local startTime = SafeNumber(info.startTime, 0)
      local duration  = SafeNumber(info.duration, 0)

      if startTime > 0 and duration > 0 then
        return math.max(0, (startTime + duration) - Now())
      end
    end
  end

  return 0
end

local function SafeCDRemaining(spellID, lastCastAt, fullCD)
  local live    = GetSpellCDRemainingByID(spellID)
  local elapsed = Now() - (lastCastAt or 0)
  local floor   = math.max(0, fullCD - elapsed)
  return math.max(live, floor)
end

local function GetDHCD()
  return SafeCDRemaining(
    SPELL_IDS.DARK_HARVEST,
    STATE.lastDHCastAt,
    DH_COOLDOWN
  )
end




local function GetDGCD()
  return SafeCDRemaining(
    SPELL_IDS.DARKGLARE,
    STATE.lastDGCastAt,
    DG_COOLDOWN
  )
end

-- =========================================================
-- ROTATION UTILITIES
-- =========================================================

local function HasValidTarget()
  return UnitExists("target")
     and UnitCanAttack("player", "target")
     and not UnitIsDead("target")
end

local function GetEnemyCount()
  local count = 0
  for i = 1, 40 do
    local unit = "nameplate" .. i
    if UnitExists(unit) and UnitCanAttack("player", unit) and not UnitIsDead(unit) then
      count = count + 1
    end
  end
  if count == 0 and HasValidTarget() then count = 1 end
  return count
end

local function GetShards()
  return UnitPower("player", Enum.PowerType.SoulShards) or 0
end

local function IsSpellReadyByID(spellID)
  if not spellID then return false end
  if not (C_Spell and C_Spell.GetSpellCooldown) then return true end

  local info = C_Spell.GetSpellCooldown(spellID)
  if not info then return true end

  local duration = SafeNumber(info.duration, 0)
  local isActive = info.isActive

  if isActive == false and duration <= 0 then
    return true
  end

  return duration <= 0
end

local function ResetDebuffs()
  STATE.haunt      = 0
  STATE.agony      = 0
  STATE.corruption = 0
  STATE.ua         = 0
  STATE.uaStacks   = 0
end

-- =========================================================
-- APPLY CAST
--
-- Pandemic-aware local timestamp update used as fallback
-- when C_UnitAuras hasn't caught up yet (same-frame async).
-- C_UnitAuras will correct the value on the next UNIT_AURA.
-- =========================================================
local HAUNT_COOLDOWN = 15  -- Haunt's CD in seconds

local function IsHauntReady()
  local live    = GetSpellCDRemainingByID(SPELL_IDS.HAUNT)
  local elapsed = Now() - (STATE.lastHauntCastAt or 0)
  local floor   = math.max(0, HAUNT_COOLDOWN - elapsed)
  local cdRem   = math.max(live, floor)
  return cdRem <= 0.05
end

local function ApplyCast(spellName)
  local t = Now()

  -- Pandemic helper: extend from current remaining, capped at pandemic window
  local function PandemicExpiry(stateField, spellKey)
    local currentRem = math.max(0, (STATE[stateField] or 0) - t)
    local maxExtend  = PANDEMIC[spellKey] or 0
    return t + DURATIONS[spellKey] + math.min(currentRem, maxExtend)
  end

  if spellName == SPELLS.HAUNT then
    STATE.haunt = PandemicExpiry("haunt", SPELLS.HAUNT)
    STATE.lastHauntCastAt = t   -- ADD THIS LINE
  elseif spellName == SPELLS.AGONY then
    STATE.agony = PandemicExpiry("agony", SPELLS.AGONY)

  elseif spellName == SPELLS.CORRUPTION then
    STATE.corruption = PandemicExpiry("corruption", SPELLS.CORRUPTION)

  elseif spellName == SPELLS.UA then
    STATE.ua = PandemicExpiry("ua", SPELLS.UA)
    STATE.uaStacks = math.min(8, STATE.uaStacks + 1)

  elseif spellName == SPELLS.DARK_HARVEST then
    STATE.lastDHCastAt = t

  elseif spellName == SPELLS.DARKGLARE then
    STATE.lastDGCastAt     = t
    STATE.darkglareReadyAt = t + DG_COOLDOWN
    STATE.darkglareUntil   = t + DARKGLARE_DURATION
  end
  
  STATE.lastCastAt = t
end

-- =========================================================
-- DG WINDOW TRACKING
-- =========================================================

local function UpdateWindows()
  local now = Now()
  if STATE.darkglareUntil > 0 and now >= STATE.darkglareUntil then
    STATE.darkglareEndedAt = now
    STATE.darkglareUntil   = 0
  end
end

local function IsDarkglareActive()
  return STATE.darkglareUntil > Now()
end

local function RecentlyLeftDG()
  return STATE.darkglareEndedAt > 0
     and (Now() - STATE.darkglareEndedAt) < RECOVER_WINDOW
end

-- =========================================================
-- DH TIMING GATE
-- =========================================================

local function DHWillBeReadyForDG(dgCD)
  if dgCD <= 0 then return true end
  if dgCD > (DH_COOLDOWN + DH_READY_BUFFER) then return true end
  return DH_COOLDOWN <= (dgCD - DH_READY_BUFFER)
end

-- =========================================================
-- CANDIDATE SYSTEM
-- =========================================================

local function AddCandidate(list, label, score, ok)
  if ok then
    list[#list + 1] = { label = label, score = score }
  end
end

local function IsLabelUsable(label)
  if label == LABELS.HARVEST then
    return GetDHCD() <= 0.05
  end
  if label == LABELS.GLARE then
    return GetDGCD() <= 0.05
  end
	if label == LABELS.HAUNT then
	  return IsHauntReady()
	end
  return true
end

local function PickBestCandidate(list)
  local best = nil

  for i = 1, #list do
    local c = list[i]
    if IsLabelUsable(c.label) then
      if not best or c.score > best.score then
        best = c
      end
    end
  end

  return best and best.label or LABELS.FILLER
end

-- =========================================================
-- NEXT SPELL
--
-- DoT remaining values come from DotRemaining() which prefers
-- C_UnitAuras (haste-correct, pandemic-correct) and falls back
-- to local timestamps only when the API is unavailable.
-- =========================================================

-- =========================================================
-- NEXT SPELL — Full priority implementation
-- Single Target and Multi Target per spec priority list
-- =========================================================

local function NextSpell()
  if not HasValidTarget() then return "NO TARGET" end

  local now = Now()
  UpdateWindows()

  local hauntRem = DotRemaining(SPELL_IDS.HAUNT,      "haunt")
  local agonyRem = DotRemaining(SPELL_IDS.AGONY,      "agony")
  local corrRem  = DotRemaining(SPELL_IDS.CORRUPTION, "corruption")

  local shards     = GetShards()
  local maxShards  = 5
  local enemyCount = GetEnemyCount()
  local isAOE      = enemyCount >= 3
  local hauntReady = IsHauntReady()
  local dhCD       = GetDHCD()
  local dhReady    = dhCD <= 0.05
  local dgCD       = GetDGCD()
  local dgReady    = dgCD <= 0.05
  local dgActive   = IsDarkglareActive()

  local agonyMissing = agonyRem <= AGONY_REFRESH
  local corrMissing  = corrRem  <= CORR_REFRESH
  local hasAnyDot    = (hauntRem > 0) or (agonyRem > 0) or (corrRem > 0)
  local hasCoreDots  = (agonyRem > 0) and (corrRem > 0)

  local atShardCap = shards >= maxShards
  local hasShards  = shards >= 1
  local burstReady = shards <= 2
  local dgSoon     = (not dgReady) and dgCD <= 15

  -- Haunt ready and needs refreshing → macro 1
  local hauntNeeded = hauntReady and hauntRem <= DOT_REFRESH
  -- Haunt on CD → show Agony (macro 2 handles Agony then catches Haunt)
  local agonyNeeded = agonyMissing and not hauntReady
  -- Corruption always last — shortest duration, apply after Agony is up
  local corrNeeded  = corrMissing and not hauntReady and not agonyMissing

  -- ── Priority tiers ────────────────────────────────────────────────
  local P_HAUNT_READY = 125  -- Haunt off CD — 18% damage amp on everything
  local P_DOTS        = 120  -- Agony or Corruption dropping
  local P_OVERCAP     = 115  -- Never waste a shard
  local P_DH          = 112  -- Dark Harvest — 60s refund engine, always fire
  local P_DG_DRAIN    = 110  -- Pre-DG urgent spend — push to ≤2 in last 15s
  local P_DG_FIRE     = 105  -- Summon Darkglare — dots up, shards ≤2
  local P_SPEND       = 80   -- Always spend shards, no conditions
  local P_FILLER      = 1    -- Last resort, genuinely empty

  local candidates = {}

  if not isAOE then
    -- ═══════════════════════════════════════════════
    -- SINGLE TARGET
    -- ═══════════════════════════════════════════════

    -- Haunt ready → macro 1 (Haunt+Agony+Corruption)
    AddCandidate(candidates, LABELS.HAUNT,      P_HAUNT_READY, hauntNeeded)
    -- Haunt on CD, Agony missing → macro 2 (Agony+Haunt)
    AddCandidate(candidates, LABELS.AGONY,      P_DOTS,        agonyNeeded)
    -- Agony up, Corruption missing → apply directly
    AddCandidate(candidates, LABELS.CORRUPTION, P_DOTS - 1,    corrNeeded)
    AddCandidate(candidates, LABELS.UA,         P_OVERCAP,     atShardCap)
    AddCandidate(candidates, LABELS.HARVEST,    P_DH,          dhReady and hasAnyDot)
    AddCandidate(candidates, LABELS.UA,         P_DG_DRAIN,    dgSoon and not burstReady)
    AddCandidate(candidates, LABELS.GLARE,      P_DG_FIRE,     dgReady and hasCoreDots and burstReady)
    AddCandidate(candidates, LABELS.UA,         P_SPEND,       hasShards)
    AddCandidate(candidates, LABELS.FILLER,     P_FILLER,      true)

  else
    -- ═══════════════════════════════════════════════
    -- MULTI TARGET
    -- ═══════════════════════════════════════════════

    AddCandidate(candidates, LABELS.HAUNT,      P_HAUNT_READY, hauntNeeded)
    AddCandidate(candidates, LABELS.AGONY,      P_DOTS,        agonyNeeded)
    AddCandidate(candidates, LABELS.CORRUPTION, P_DOTS - 1,    corrNeeded)
    AddCandidate(candidates, LABELS.SEED,       P_OVERCAP,     atShardCap)
    AddCandidate(candidates, LABELS.HARVEST,    P_DH,          dhReady and hasAnyDot)
    AddCandidate(candidates, LABELS.SEED,       P_DG_DRAIN,    dgSoon and not burstReady)
    AddCandidate(candidates, LABELS.GLARE,      P_DG_FIRE,     dgReady and hasCoreDots and burstReady)
    AddCandidate(candidates, LABELS.UA,         P_SPEND,       dgActive and enemyCount == 2 and hasShards)
    AddCandidate(candidates, LABELS.SEED,       P_SPEND,       hasShards)
    AddCandidate(candidates, LABELS.FILLER,     P_FILLER,      true)
  end

  return PickBestCandidate(candidates)
end

-- =========================================================
-- DISPLAY
-- =========================================================

local function GetSpellTextureSafe(spellName)
  if not spellName then return nil end
  if C_Spell and C_Spell.GetSpellTexture then
    return C_Spell.GetSpellTexture(spellName)
  end
end

local function GetDisplaySpellAndKey(label)
  if label == LABELS.HAUNT      then return SPELLS.HAUNT,        FindSpellKeybindByName(SPELLS.HAUNT)        end
  if label == LABELS.AGONY      then return SPELLS.AGONY,        FindSpellKeybindByName(SPELLS.AGONY)        end
  if label == LABELS.CORRUPTION then return SPELLS.CORRUPTION,   FindSpellKeybindByName(SPELLS.CORRUPTION)   end
  if label == LABELS.HARVEST    then return SPELLS.DARK_HARVEST, FindSpellKeybindByName(SPELLS.DARK_HARVEST) end
  if label == LABELS.GLARE      then return SPELLS.DARKGLARE,    FindSpellKeybindByName(SPELLS.DARKGLARE)    end
  if label == LABELS.UA         then return SPELLS.UA,           FindSpellKeybindByName(SPELLS.UA)           end
  if label == LABELS.SEED       then return SPELLS.SEED,         FindSpellKeybindByName(SPELLS.SEED)         end
  if label == LABELS.FILLER     then return SPELLS.SHADOW_BOLT,  FindSpellKeybindByName(SPELLS.SHADOW_BOLT)  end
  return nil, "?"
end

local function UpdateDisplay()
  local label = NextSpell()

  if label == "NO TARGET" then
    if not UnitAffectingCombat("player") then
      display:Hide()
    else
      display:Show()
      display.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
      display.keybind:SetText("")
    end
    return
  end

  display:Show()
  local spellName, keybind = GetDisplaySpellAndKey(label)
  display.icon:SetTexture(GetSpellTextureSafe(spellName) or "Interface\\Icons\\INV_Misc_QuestionMark")
  display.keybind:SetText(keybind or "?")
end

local elapsed = 0
display:SetScript("OnUpdate", function(_, dt)
  elapsed = elapsed + dt
  if elapsed >= UPDATE_INTERVAL then
    UpdateDisplay()
    UpdateDamageFlash()
    elapsed = 0
  end
end)

-- =========================================================
-- CAST BAR SWEEP
-- =========================================================

local function UpdateCastingSweep()
  local _, _, _, castStartMS, castEndMS, _, _, _, castSpellID = UnitCastingInfo("player")
  if castSpellID then
    local s = castStartMS / 1000
    local d = castEndMS   / 1000 - s
    if d > 0 then
      display.cooldown:Clear()
      display.cooldown:SetCooldown(s, d)
      return
    end
  end

  local _, _, _, chanStartMS, chanEndMS, _, _, chanSpellID = UnitChannelInfo("player")
  if chanSpellID then
    local s = chanStartMS / 1000
    local d = chanEndMS   / 1000 - s
    if d > 0 then
      display.cooldown:Clear()
      display.cooldown:SetCooldown(s, d)
      return
    end
  end

  display.cooldown:Clear()
end

local function ShowGCDSweep()
  if not (C_Spell and C_Spell.GetSpellCooldown) then return end
  local info = C_Spell.GetSpellCooldown(61304)
  if info and info.startTime and info.startTime > 0
         and info.duration   and info.duration  > 0
         and info.duration < 10 then
    display.cooldown:Clear()
    display.cooldown:SetCooldown(info.startTime, info.duration)
  end
end

-- =========================================================
-- KEYBIND LOOKUP
-- =========================================================

FindSpellKeybindByName = function(spellName)
  if not spellName then return nil end

  local spellID
  if C_Spell and C_Spell.GetSpellInfo then
    local info = C_Spell.GetSpellInfo(spellName)
    spellID = info and info.spellID
  end
  if not spellID then return nil end

  for slot = 1, 120 do
    local actionType, id = GetActionInfo(slot)
    if actionType == "spell" and id == spellID then
      local bindingName
      if     slot >= 1  and slot <= 12 then bindingName = "ACTIONBUTTON"          .. slot
      elseif slot >= 61 and slot <= 72 then bindingName = "MULTIACTIONBAR1BUTTON" .. (slot - 60)
      elseif slot >= 49 and slot <= 60 then bindingName = "MULTIACTIONBAR2BUTTON" .. (slot - 48)
      elseif slot >= 25 and slot <= 36 then bindingName = "MULTIACTIONBAR3BUTTON" .. (slot - 24)
      elseif slot >= 37 and slot <= 48 then bindingName = "MULTIACTIONBAR4BUTTON" .. (slot - 36)
      end
      if bindingName then
        local key = GetBindingKey(bindingName)
        if key then
          return key:upper()
            :gsub("SHIFT%-",        "S-")
            :gsub("ALT%-",          "A-")
            :gsub("CTRL%-",         "C-")
            :gsub("NUMPAD",         "N")
            :gsub("BUTTON",         "B")
            :gsub("MOUSEWHEELUP",   "MU")
            :gsub("MOUSEWHEELDOWN", "MD")
        end
      end
    end
  end
  return nil
end

-- =========================================================
-- OPTIONS PANEL
-- =========================================================

BuildOptionsPanel = function()
  local panel = CreateFrame("Frame")
  panel.name  = "WarlockSpells"

  local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 16, -16)
  title:SetText("WarlockSpells Settings")

  local sizeSlider = CreateFrame("Slider", nil, panel, "OptionsSliderTemplate")
  sizeSlider:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -40)
  sizeSlider:SetMinMaxValues(40, 100)
  sizeSlider:SetValueStep(2)
  sizeSlider:SetValue(ICON_SIZE_SETTING)
  sizeSlider:SetObeyStepOnDrag(true)
  sizeSlider.Text:SetText("Icon Size")
  sizeSlider:SetScript("OnValueChanged", function(_, val)
    ICON_SIZE_SETTING = val
    ApplyIconSize()
    SaveSettings()
  end)

  local alphaSlider = CreateFrame("Slider", nil, panel, "OptionsSliderTemplate")
  alphaSlider:SetPoint("TOPLEFT", sizeSlider, "BOTTOMLEFT", 0, -40)
  alphaSlider:SetMinMaxValues(0.2, 1)
  alphaSlider:SetValueStep(0.05)
  alphaSlider:SetValue(DISPLAY_ALPHA)
  alphaSlider:SetObeyStepOnDrag(true)
  alphaSlider.Text:SetText("Transparency")
  alphaSlider:SetScript("OnValueChanged", function(_, val)
    DISPLAY_ALPHA = val
    ApplyDisplayAlpha()
    SaveSettings()
  end)

  if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
    optionsCategory = Settings.RegisterCanvasLayoutCategory(panel, "WarlockSpells")
    Settings.RegisterAddOnCategory(optionsCategory)
  elseif InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(panel)
  end
end

-- =========================================================
-- EVENT HANDLER
-- =========================================================

display:RegisterEvent("PLAYER_ENTERING_WORLD")
display:RegisterEvent("PLAYER_TARGET_CHANGED")
display:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
display:RegisterEvent("SPELL_UPDATE_COOLDOWN")           -- NEW: catches DH/DG CD updates immediately
display:RegisterUnitEvent("UNIT_AURA",                   "target")   -- NEW: live DoT updates
display:RegisterUnitEvent("UNIT_SPELLCAST_START",        "player")
display:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START","player")
display:RegisterUnitEvent("UNIT_SPELLCAST_STOP",         "player")
display:RegisterUnitEvent("UNIT_SPELLCAST_FAILED",       "player")
display:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED",  "player")
display:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player")
display:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_UPDATE","player")


display:SetScript("OnEvent", function(_, event, unit, _, spellID)

  -- ── World entry: full reset and settings load ───────────────────────
  if event == "PLAYER_ENTERING_WORLD" then
    ResolveAllSpellIDs()
    ResetDebuffs()
    STATE.darkglareReadyAt   = 0
    STATE.darkglareUntil     = 0
    STATE.darkglareEndedAt   = 0
    STATE.lastDHCastAt       = 0
    STATE.lastDGCastAt       = 0
    STATE.lastCastAt         = 0
    STATE.lastSuggestion     = nil

	
    LoadSettings()
    ApplyIconSize()
    ApplyBorderColor()
    ApplyFrameLock()
    ApplyFramePosition()
    ApplyDisplayAlpha()
    ApplyKeybindFontSize()
    BuildOptionsPanel()
    UpdateDisplay()
    return
  end

  -- ── Target changed: clear suggestion, reset GCD lock ───────────────
  -- Clearing lastCastAt prevents the GCD lock from carrying over to the
  -- new target, so the first suggestion is always fresh and correct.
  if event == "PLAYER_TARGET_CHANGED" then
    ResetDebuffs()
    STATE.targetChangedAt = Now()
    STATE.lastSuggestion  = nil  -- recalculate immediately for new target
    STATE.lastCastAt      = 0   -- no GCD bleed-over to new target
    UpdateDisplay()
    return
  end

  -- ── UNIT_AURA on target: DoTs changed, recalculate now ─────────────
  -- C_UnitAuras.GetAuraDataBySpellName will return the updated values
  -- on the very next call, so we just invalidate the suggestion lock
  -- and let UpdateDisplay re-evaluate.
  if event == "UNIT_AURA" and unit == "target" then
    STATE.lastSuggestion = nil
    UpdateDisplay()
    return
  end

  -- ── SPELL_UPDATE_COOLDOWN: DH/DG may have come off CD ──────────────
  -- Fired by the game engine whenever any spell cooldown changes.
  -- We don't need to know which spell — just let the rotation re-evaluate.
  if event == "SPELL_UPDATE_COOLDOWN" then
    UpdateDisplay()
    return
  end

  -- ── Player took damage ─────────────────────────────────────────────
  -- Threshold-gated: only flash on 2%+ HP loss to suppress absorb noise.


  -- ── Cast completed: update local state then refresh display ────────
  if event == "UNIT_SPELLCAST_SUCCEEDED" and unit == "player" and spellID then
    local spellName = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
    if spellName then ApplyCast(spellName) end
    ShowGCDSweep()
    UpdateDisplay()
    return
  end

  -- ── All other cast events: just update the sweep bar ───────────────
  UpdateCastingSweep()
end)

-- =========================================================
-- SLASH COMMANDS
-- =========================================================

SLASH_WARLOCKSPELLS1 = "/ws"
SlashCmdList["WARLOCKSPELLS"] = function()
  if Settings and Settings.OpenToCategory and optionsCategory then
    Settings.OpenToCategory(optionsCategory:GetID())
  elseif InterfaceOptionsFrame_OpenToCategory then
    InterfaceOptionsFrame_OpenToCategory("WarlockSpells")
  end
end

-- At the bottom of /wsdebug, replace the nil prints with:
SLASH_WSDEBUG1 = "/wsdebug"
SlashCmdList["WSDEBUG"] = function()
  local now = Now()

  local function AuraInfo(spellID, stateField)
    local live = GetAuraRemainingBySpellID("target", spellID)
    local loc  = math.max(0, (STATE[stateField] or 0) - now)
    if live ~= nil then
      return string.format("%.1f (live)", live)
    else
      return string.format("%.1f (local)", loc)
    end
  end

  -- Recompute the same locals NextSpell uses
  local hauntRem     = DotRemaining(SPELL_IDS.HAUNT,      "haunt")
  local agonyRem     = DotRemaining(SPELL_IDS.AGONY,      "agony")
  local corrRem      = DotRemaining(SPELL_IDS.CORRUPTION, "corruption")
  local hauntReady   = IsSpellReadyByID(SPELL_IDS.HAUNT)
  local agonyMissing = agonyRem <= AGONY_REFRESH
  local corrMissing  = corrRem  <= CORR_REFRESH
  local agonyNeeded  = agonyMissing and not hauntReady
  local corrNeeded   = corrMissing and not hauntReady and not agonyMissing

  print("----- WarlockSpells Debug -----")
  print("C_UnitAuras available:", tostring(C_UnitAuras ~= nil and C_UnitAuras.GetAuraDataBySpellName ~= nil))
  print("SPELL_IDS: haunt=", SPELL_IDS.HAUNT, " agony=", SPELL_IDS.AGONY, " corr=", SPELL_IDS.CORRUPTION)
  print("dhCD=", string.format("%.1f", GetDHCD()), " dgCD=", string.format("%.1f", GetDGCD()))
  print("haunt=",  AuraInfo(SPELL_IDS.HAUNT,      "haunt"),
        " agony=", AuraInfo(SPELL_IDS.AGONY,      "agony"),
        " corr=",  AuraInfo(SPELL_IDS.CORRUPTION, "corruption"))
  print("hauntReady=",   tostring(hauntReady))
  print("agonyMissing=", tostring(agonyMissing))
  print("agonyNeeded=",  tostring(agonyNeeded))
  print("corrNeeded=",   tostring(corrNeeded))
  print("shards=", GetShards(), " dgActive=", tostring(IsDarkglareActive()))
  print("lastDHCastAt=", string.format("%.1f", now - STATE.lastDHCastAt), "s ago")
  print("lastDGCastAt=", string.format("%.1f", now - STATE.lastDGCastAt), "s ago")
  print("nextSpell=", NextSpell())
  print("-------------------------------")
end
