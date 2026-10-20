-- HeadsUp survey: a silent recorder that finds out, by trying, what the game lets the addon read
-- about auras (buffs / debuffs) and a few other things, for the player and for the target, in and
-- out of combat. Nothing is shown and nothing is written in the chat. Everything goes to
-- HeadsUpDB.survey (read it in the SavedVariables file after /reload).
--
-- Layout of HeadsUpDB.survey:
--   build, class, spec       when it was measured (the whole survey restarts on a new game build)
--   [unit .. "|" .. context] unit = player / target, context = combat or ooc + "_" + instance type
--     calls[name]            how many times each call was readable / secret / nil / error
--     spells[spellID]        the latest result for every aura seen: its fields (R readable, S secret)
--                            and the game's own secrecy answer, and the result of asking for it by ID
-- "R" means the addon may branch on it (if), "S" means it can only be shown, never compared.

local survey
local lastRun = 0

local function Kind(ok, value)
    if not ok then return "error" end
    if value == nil then return "nil" end
    if issecretvalue(value) then return "secret" end
    return "readable"
end

local function Letter(kind)
    if kind == "readable" then return "R" end
    if kind == "secret" then return "S" end
    if kind == "nil" then return "-" end
    return "E"
end

local function Context()
    local combat = UnitAffectingCombat("player") and "combat" or "ooc"
    local _, instanceType = IsInInstance()
    return combat .. "_" .. tostring(instanceType or "none")
end

local function Bucket(unit, ctx)
    local key = unit .. "|" .. ctx
    local b = survey[key]
    if not b then
        b = { calls = {}, spells = {} }
        survey[key] = b
    end
    return b
end

local function Count(bucket, name, kind)
    local c = bucket.calls[name]
    if not c then
        c = {}
        bucket.calls[name] = c
    end
    c[kind] = (c[kind] or 0) + 1
end

-- Run a call, count how it ended, and return the value (nil when the call failed).
local function Try(bucket, name, fn, ...)
    local ok, value = pcall(fn, ...)
    Count(bucket, name, Kind(ok, value))
    if ok then return value end
    return nil
end

local FIELDS = { "name", "spellId", "icon", "duration", "expirationTime", "applications", "dispelName", "sourceUnit" }

local function FieldString(data)
    local parts = {}
    for _, f in ipairs(FIELDS) do
        local ok, v = pcall(function() return data[f] end)
        parts[#parts + 1] = f .. ":" .. Letter(Kind(ok, v))
    end
    return table.concat(parts, " ")
end

-- Spells (ids) that were readable out of combat, per unit: asked for again, by id and by name, in combat.
local remembered = { player = {}, target = {}, focus = {}, mouseover = {}, nameplate1 = {} }

local function Remember(unit, id, name, filter)
    local list = remembered[unit]
    if not list[id] then
        local n = 0
        for _ in pairs(list) do n = n + 1 end
        if n >= 40 then return end
        list[id] = { name = name, filter = filter }
    end
end

local function SpellEntry(bucket, id)
    local s = bucket.spells[id]
    if not s then
        local n = 0
        for _ in pairs(bucket.spells) do n = n + 1 end
        if n >= 150 then return nil end
        s = {}
        bucket.spells[id] = s
    end
    return s
end

-- Look at one aura that the enumeration gave us.
local function StudyAura(unit, bucket, data, filter, readableNow)
    local okId, id = pcall(function() return data.spellId end)
    if not okId or id == nil or issecretvalue(id) then
        Count(bucket, "aura_spellId_hidden", "secret")
        return
    end
    local s = SpellEntry(bucket, id)
    if not s then return end
    local okName, name = pcall(function() return data.name end)
    if okName and name ~= nil and not issecretvalue(name) then s.name = name end
    s.filter = filter
    s.fields = FieldString(data)
    if readableNow then Remember(unit, id, s.name, filter) end
    local instanceID = data.auraInstanceID
    if instanceID ~= nil and not issecretvalue(instanceID) and C_UnitAuras then
        local d = Try(bucket, "GetAuraDuration", C_UnitAuras.GetAuraDuration, unit, instanceID)
        s.durationObject = Letter(Kind(true, d))
        if C_UnitAuras.DoesAuraHaveExpirationTime then
            s.hasExpiry = Letter(Kind(pcall(C_UnitAuras.DoesAuraHaveExpirationTime, unit, instanceID)))
        end
        if C_UnitAuras.GetAuraApplicationDisplayCount then
            local ok, v = pcall(C_UnitAuras.GetAuraApplicationDisplayCount, unit, instanceID, 1, 99)
            s.stackText = Letter(Kind(ok, v))
        end
    end
end

-- The game's own answers about secrecy (these are plain true/false, never secret themselves).
local function StudySecrecy(unit, bucket)
    if not C_Secrets then
        Count(bucket, "C_Secrets_missing", "nil")
        return
    end
    if C_Secrets.ShouldAurasBeSecret then
        local v = Try(bucket, "ShouldAurasBeSecret", C_Secrets.ShouldAurasBeSecret)
        bucket.shouldAurasBeSecret = tostring(v)
    end
    for id, s in pairs(bucket.spells) do
        if C_Secrets.GetSpellAuraSecrecy then
            local ok, v = pcall(C_Secrets.GetSpellAuraSecrecy, id)
            s.secrecy = ok and tostring(v) or "error"
        end
        if C_Secrets.ShouldSpellAuraBeSecret then
            local ok, v = pcall(C_Secrets.ShouldSpellAuraBeSecret, id)
            s.shouldBeSecret = ok and tostring(v) or "error"
        end
    end
end

-- Enumerate the auras of one unit, in every way the game may still allow.
local function StudyEnumeration(unit, bucket, ctx)
    local readableNow = ctx:sub(1, 3) == "ooc"
    for _, filter in ipairs({ "HELPFUL", "HARMFUL" }) do
        -- way 1: the whole list at once
        if C_UnitAuras.GetUnitAuras then
            local list = Try(bucket, "GetUnitAuras_" .. filter, C_UnitAuras.GetUnitAuras, unit, filter)
            if type(list) == "table" then
                local okN, n = pcall(function() return #list end)
                if okN then bucket["count_" .. filter] = n end
                for _, data in ipairs(list) do StudyAura(unit, bucket, data, filter, readableNow) end
            end
        end
        -- way 2: one by one
        if C_UnitAuras.GetAuraDataByIndex then
            local seen = 0
            for i = 1, 40 do
                local ok, data = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, filter)
                if not ok then
                    Count(bucket, "GetAuraDataByIndex_" .. filter, "error")
                    break
                end
                if data == nil then break end
                Count(bucket, "GetAuraDataByIndex_" .. filter, "readable")
                seen = seen + 1
                StudyAura(unit, bucket, data, filter, readableNow)
            end
            bucket["byIndex_" .. filter] = seen
        end
        -- way 3: only the numbers (instance ids)
        if C_UnitAuras.GetUnitAuraInstanceIDs then
            local ids = Try(bucket, "GetUnitAuraInstanceIDs_" .. filter, C_UnitAuras.GetUnitAuraInstanceIDs, unit, filter)
            if type(ids) == "table" then bucket["ids_" .. filter] = #ids end
        end
    end
end

-- Ask again for the spells that were seen out of combat: by id and by name.
local function StudyByQuestion(unit, bucket)
    for id, info in pairs(remembered[unit]) do
        local s = SpellEntry(bucket, id)
        if s then
            s.name = s.name or info.name
            if C_UnitAuras.GetUnitAuraBySpellID then
                local ok, data = pcall(C_UnitAuras.GetUnitAuraBySpellID, unit, id)
                s.byID = ok and (data and ("found " .. FieldString(data)) or "none") or "error"
                Count(bucket, "byID", Kind(ok, data))
            end
            if unit == "player" and C_UnitAuras.GetPlayerAuraBySpellID then
                local ok, data = pcall(C_UnitAuras.GetPlayerAuraBySpellID, id)
                s.byPlayerID = ok and (data and "found" or "none") or "error"
            end
            if info.name and C_UnitAuras.GetAuraDataBySpellName then
                local ok, data = pcall(C_UnitAuras.GetAuraDataBySpellName, unit, info.name, info.filter)
                s.byName = ok and (data and "found" or "none") or "error"
            end
        end
    end
end

-- Other things about the unit that conditions may want (counted only).
local function StudyUnit(unit, bucket)
    Try(bucket, "UnitHealth", UnitHealth, unit)
    Try(bucket, "UnitHealthMax", UnitHealthMax, unit)
    Try(bucket, "UnitPower", UnitPower, unit)
    Try(bucket, "UnitPowerMax", UnitPowerMax, unit)
    Try(bucket, "UnitIsDead", UnitIsDead, unit)
    Try(bucket, "UnitName", UnitName, unit)
    Try(bucket, "UnitLevel", UnitLevel, unit)
    Try(bucket, "UnitClassification", UnitClassification, unit)
    Try(bucket, "UnitCreatureType", UnitCreatureType, unit)
    Try(bucket, "UnitCastingInfo", UnitCastingInfo, unit)
    Try(bucket, "UnitChannelInfo", UnitChannelInfo, unit)
    Try(bucket, "UnitIsPlayer", UnitIsPlayer, unit)
    Try(bucket, "UnitThreatSituation", UnitThreatSituation, "player", unit)
    Try(bucket, "UnitIsUnit_target_player", UnitIsUnit, unit, "player")
    if unit == "player" then
        Try(bucket, "GetShapeshiftForm", GetShapeshiftForm)
        Try(bucket, "IsStealthed", IsStealthed)
        Try(bucket, "IsPlayerMoving", GetUnitSpeed, "player")
    end
end

local function Run(unit)
    if not survey or not C_UnitAuras then return end
    if unit ~= "player" and not UnitExists(unit) then return end
    local ctx = Context()
    local bucket = Bucket(unit, ctx)
    bucket.samples = (bucket.samples or 0) + 1
    bucket.lastTime = date("%H:%M:%S")
    if unit ~= "player" then
        bucket.targetKind = (UnitCanAttack("player", unit) and "enemy" or "friend")
            .. (UnitIsPlayer(unit) and "_player" or "_npc")
    end
    pcall(StudyEnumeration, unit, bucket, ctx)
    pcall(StudyByQuestion, unit, bucket)
    pcall(StudySecrecy, unit, bucket)
    pcall(StudyUnit, unit, bucket)
end

local function RunAll()
    local now = GetTime()
    if now - lastRun < 1 then return end
    lastRun = now
    Run("player")
    Run("target")
    Run("focus")
    Run("mouseover")
    Run("nameplate1")
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterUnitEvent("UNIT_AURA", "player", "target")
frame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        if not HeadsUpDB or HeadsUpDB.surveyOff then return end
        local build = select(2, GetBuildInfo())
        local old = HeadsUpDB.survey
        if type(old) ~= "table" or old.build ~= build then
            old = { build = build }
        end
        survey = old
        HeadsUpDB.survey = survey
        survey.class = select(2, UnitClass("player"))
        local spec = GetSpecialization and GetSpecialization()
        survey.spec = spec and select(2, GetSpecializationInfo(spec)) or nil
        return
    end
    if survey then RunAll() end
end)

-- One reading a second while in combat (auras change without events, and the by-id questions
-- need repeating); out of combat the events above are enough.
local since = 0
frame:SetScript("OnUpdate", function(_, elapsed)
    if not survey or not UnitAffectingCombat("player") then return end
    since = since + elapsed
    if since >= 1 then
        since = 0
        RunAll()
    end
end)
