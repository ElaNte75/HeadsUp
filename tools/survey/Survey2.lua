-- HeadsUp survey 2: the "tricks" survey. Survey.lua found that in combat the game blocks the normal ways
-- of reading buffs and debuffs. This file tries every other door we can think of, in one go, and records
-- the answers in HeadsUpDB.survey2 (silent: nothing is written in the chat):
--   catalog       the game's own secrecy class for every spell id (runs by itself, out of combat, once per build)
--   events        what the UNIT_AURA / cast / combat-log events carry in combat (readable or hidden)
--   tracked       auras whose instance id we got BEFORE combat (or from an event), asked again in combat:
--                 does the data / the duration object / "has expiry" / the stack text still answer?
--   cdm           the Blizzard Cooldown Manager icons (is the icon shown? stacks? texture?)
--   frames        the Blizzard buff / debuff / target / nameplate aura buttons
--   log           a rolling list of timed lines (changes), to compare with what really happened
-- "readable" = the addon may branch on it, "secret" = it can only be passed on to the screen.

local s2
local started = false

local function Kind(ok, value)
    if not ok then return "error" end
    if value == nil then return "nil" end
    if issecretvalue(value) then return "secret" end
    return "readable"
end

local function Tally(group, name, kind)
    local g = s2[group]
    if not g then g = {} s2[group] = g end
    local e = g[name]
    if not e then e = {} g[name] = e end
    e[kind] = (e[kind] or 0) + 1
end

local function Ctx()
    local _, instanceType = IsInInstance()
    return (UnitAffectingCombat("player") and "combat" or "ooc") .. "_" .. tostring(instanceType or "none")
end

local function Log(line)
    local log = s2.log
    if not log then log = {} s2.log = log end
    log[#log + 1] = date("%H:%M:%S") .. " " .. line
    while #log > 500 do table.remove(log, 1) end
end

-- Readable value as text, or "S" when hidden, "-" when nil.
local function Show(ok, v)
    if not ok then return "E" end
    if v == nil then return "-" end
    if issecretvalue(v) then return "S" end
    return tostring(v)
end

---------------------------------------------------------------------------
-- 1. Catalog of the secrecy class of every spell
---------------------------------------------------------------------------

local scan = { running = false }

local function ScanStep()
    if not scan.running then return end
    if UnitAffectingCombat("player") then
        scan.running = false      -- retried after combat
        return
    end
    local deadline = debugprofilestop() + 6
    local cat = s2.catalog
    while scan.nextId <= scan.lastId do
        local id = scan.nextId
        local ok, v = pcall(C_Secrets.GetSpellAuraSecrecy, id)
        if ok and v ~= nil then
            local name = C_Spell.GetSpellName(id)
            if name then
                local key = tostring(v)
                cat.counts[key] = (cat.counts[key] or 0) + 1
                if key ~= "2" then
                    local list = cat.ids[key]
                    if not list then list = {} cat.ids[key] = list end
                    if #list < 3000 then list[#list + 1] = id .. "=" .. name end
                end
            end
        end
        scan.nextId = id + 1
        if scan.nextId % 500 == 0 and debugprofilestop() > deadline then break end
    end
    cat.progress = scan.nextId
    if scan.nextId > scan.lastId then
        scan.running = false
        cat.done = true
        Log("catalog scan finished")
        return
    end
    C_Timer.After(0, ScanStep)
end

function HeadsUp_ScanCatalog(force)
    if not s2 or scan.running or not (C_Secrets and C_Secrets.GetSpellAuraSecrecy) then return end
    if UnitAffectingCombat("player") then return end
    if s2.catalog and s2.catalog.done and not force then return end
    if not s2.catalog or force or s2.catalog.done then
        s2.catalog = { counts = {}, ids = {}, progress = 1 }
    end
    scan.nextId = s2.catalog.progress or 1
    scan.lastId = 1700000
    scan.running = true
    Log("catalog scan started at " .. scan.nextId)
    C_Timer.After(0, ScanStep)
end

---------------------------------------------------------------------------
-- 2. Tracked aura instances (asked again in combat)
---------------------------------------------------------------------------

local tracked = { player = {}, target = {} }
local trackedCount = { player = 0, target = 0 }
local feeder   -- a hidden cooldown frame that proves a duration object can be handed to the screen
local probeFrame

local function Track(unit, instID, spellId, name, src)
    local list = tracked[unit]
    if not list or list[instID] then return end
    if trackedCount[unit] >= 40 then return end
    list[instID] = { spell = spellId, name = name, src = src }
    trackedCount[unit] = trackedCount[unit] + 1
end

local function Untrack(unit, instID)
    local list = tracked[unit]
    if list and list[instID] then
        list[instID] = nil
        trackedCount[unit] = trackedCount[unit] - 1
    end
end

local function CaptureAuras(unit)
    if not C_UnitAuras or not C_UnitAuras.GetUnitAuras then return end
    for _, filter in ipairs({ "HELPFUL", "HARMFUL" }) do
        local ok, list = pcall(C_UnitAuras.GetUnitAuras, unit, filter)
        if ok and type(list) == "table" then
            for _, data in ipairs(list) do
                pcall(function()
                    local id = data.auraInstanceID
                    if id ~= nil and not issecretvalue(id) then
                        local sid, nm = data.spellId, data.name
                        if issecretvalue(sid) then sid = nil end
                        if issecretvalue(nm) then nm = nil end
                        Track(unit, id, sid, nm, "enum")
                    end
                end)
            end
        end
    end
end

local function TestTracked(unit)
    local bucketKey = "tracked|" .. unit .. "|" .. Ctx()
    local list = tracked[unit]
    for instID, info in pairs(list) do
        local label = (info.name or tostring(info.spell) or "?") .. "#" .. instID
        local entry = s2.tracked[bucketKey .. "|" .. label]
        if not entry then
            local n = 0
            for _ in pairs(s2.tracked) do n = n + 1 end
            if n >= 300 then return end
            entry = { src = info.src, n = 0 }
            s2.tracked[bucketKey .. "|" .. label] = entry
        end
        entry.n = entry.n + 1

        local ok, data = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, unit, instID)
        local dataState = ok and (data and "table" or "nil") or "error"
        if ok and data then
            local parts = {}
            for _, f in ipairs({ "name", "spellId", "duration", "expirationTime", "applications" }) do
                local okf, v = pcall(function() return data[f] end)
                parts[#parts + 1] = f .. ":" .. Show(okf, v)
            end
            entry.fields = table.concat(parts, " ")
        end
        if entry.data ~= dataState then
            if entry.data then
                Log(unit .. " " .. label .. " query data " .. entry.data .. " -> " .. dataState)
            end
            entry.data = dataState
        end

        local okD, dur = pcall(C_UnitAuras.GetAuraDuration, unit, instID)
        local durState = okD and (dur ~= nil and "object" or "nil") or "error"
        if entry.dur ~= durState then
            if entry.dur then Log(unit .. " " .. label .. " duration object " .. entry.dur .. " -> " .. durState) end
            entry.dur = durState
        end
        if okD and dur ~= nil and feeder then
            entry.feed = tostring((pcall(feeder.SetCooldownFromDurationObject, feeder, dur)))
        end

        local okE, hasExp = pcall(C_UnitAuras.DoesAuraHaveExpirationTime, unit, instID)
        entry.hasExpiry = Show(okE, hasExp)
        entry.hasExpiryKind = Kind(okE, hasExp)
        if okE and hasExp ~= nil and probeFrame and probeFrame.SetAlphaFromBoolean then
            entry.alphaFromBool = tostring((pcall(probeFrame.SetAlphaFromBoolean, probeFrame, hasExp, 1, 0)))
        end

        local okC, cnt = pcall(C_UnitAuras.GetAuraApplicationDisplayCount, unit, instID, 1, 99)
        entry.stackText = Show(okC, cnt)
        entry.stackKind = Kind(okC, cnt)

        if C_TooltipInfo and C_TooltipInfo.GetUnitAuraByAuraInstanceID then
            local okT, tip = pcall(C_TooltipInfo.GetUnitAuraByAuraInstanceID, unit, instID)
            entry.tooltip = Kind(okT, tip)
        end
    end
end

---------------------------------------------------------------------------
-- 3. Blizzard Cooldown Manager icons and Blizzard aura buttons
---------------------------------------------------------------------------

local VIEWERS = { "BuffIconCooldownViewer", "BuffBarCooldownViewer", "EssentialCooldownViewer", "UtilityCooldownViewer" }

local function Children(frame)
    local out = {}
    pcall(function()
        for _, c in ipairs({ frame:GetChildren() }) do out[#out + 1] = c end
    end)
    return out
end

local function StudyViewers()
    local ctx = Ctx()
    for _, vname in ipairs(VIEWERS) do
        local viewer = _G[vname]
        Tally("cdm", vname .. "|" .. ctx .. "|exists", viewer and "yes" or "no")
        if viewer then
            local items = {}
            if viewer.GetItemFrames then
                local ok, list = pcall(viewer.GetItemFrames, viewer)
                if ok and type(list) == "table" then items = list end
            end
            if #items == 0 then items = Children(viewer) end
            local shownCount = 0
            for i, item in ipairs(items) do
                if i > 40 then break end
                local okS, shown = pcall(item.IsShown, item)
                Tally("cdm", vname .. "|" .. ctx .. "|IsShown", Kind(okS, shown))
                local okV, vis = pcall(item.IsVisible, item)
                Tally("cdm", vname .. "|" .. ctx .. "|IsVisible", Kind(okV, vis))
                local okA, alpha = pcall(item.GetAlpha, item)
                Tally("cdm", vname .. "|" .. ctx .. "|GetAlpha", Kind(okA, alpha))
                local sid
                if item.GetSpellID then
                    local okI, v = pcall(item.GetSpellID, item)
                    Tally("cdm", vname .. "|" .. ctx .. "|GetSpellID", Kind(okI, v))
                    if okI and v ~= nil and not issecretvalue(v) then sid = v end
                end
                local okAI, ai = pcall(function() return item.auraInstanceID end)
                Tally("cdm", vname .. "|" .. ctx .. "|auraInstanceID", Kind(okAI, ai))
                local okT, tex = pcall(function() return item.Icon and item.Icon:GetTexture() end)
                Tally("cdm", vname .. "|" .. ctx .. "|Icon", Kind(okT, tex))
                local okCD, cdShown = pcall(function() return item.Cooldown and item.Cooldown:IsShown() end)
                Tally("cdm", vname .. "|" .. ctx .. "|CooldownShown", Kind(okCD, cdShown))
                local okTx, txt = pcall(function()
                    local a = item.Applications
                    if a and a.Applications then return a.Applications:GetText() end
                    return a and a:GetText()
                end)
                Tally("cdm", vname .. "|" .. ctx .. "|StackText", Kind(okTx, txt))
                local key = vname .. "|" .. tostring(sid or ("item" .. i))
                local e = s2.cdmItems[key]
                if not e then
                    local n = 0
                    for _ in pairs(s2.cdmItems) do n = n + 1 end
                    if n < 200 then e = {} s2.cdmItems[key] = e end
                end
                if e then
                    local state = Show(okS, shown) .. "/" .. Show(okCD, cdShown) .. "/" .. Show(okTx, txt)
                    if e.state ~= state then
                        if e.state then
                            Log("cdm " .. key .. " (" .. ctx .. ") shown/cooldown/stack " .. e.state .. " -> " .. state)
                        end
                        e.state = state
                    end
                    e.seen = (e.seen or 0) + 1
                end
                if okS and shown == true then shownCount = shownCount + 1 end
            end
            s2.cdmCounts = s2.cdmCounts or {}
            s2.cdmCounts[vname .. "|" .. ctx] = #items .. " items, shown " .. shownCount
        end
    end
end

local function FindAuraButtons(root, depth, out)
    if depth > 4 or #out >= 60 then return end
    for _, child in ipairs(Children(root)) do
        local ok, id = pcall(function() return child.auraInstanceID end)
        if ok and id ~= nil then
            out[#out + 1] = child
        else
            FindAuraButtons(child, depth + 1, out)
        end
    end
end

local function StudyBlizzardFrames()
    local ctx = Ctx()
    local roots = { "BuffFrame", "DebuffFrame", "TargetFrame", "FocusFrame", "PlayerFrame" }
    local np = C_NamePlate and C_NamePlate.GetNamePlateForUnit and C_NamePlate.GetNamePlateForUnit("target")
    for _, rname in ipairs(roots) do
        local root = _G[rname]
        local out = {}
        if root then FindAuraButtons(root, 1, out) end
        local label = "frames|" .. rname .. "|" .. ctx
        Tally("frames", label .. "|buttons>0", #out > 0 and "yes" or "no")
        for _, b in ipairs(out) do
            local okS, shown = pcall(b.IsShown, b)
            Tally("frames", label .. "|IsShown", Kind(okS, shown))
            local okI, id = pcall(function() return b.auraInstanceID end)
            Tally("frames", label .. "|auraInstanceID", Kind(okI, id))
            local okT, tex = pcall(function() return b.Icon and b.Icon:GetTexture() end)
            Tally("frames", label .. "|Icon", Kind(okT, tex))
        end
    end
    if np then
        local out = {}
        FindAuraButtons(np, 1, out)
        Tally("frames", "frames|targetNameplate|" .. ctx .. "|buttons>0", #out > 0 and "yes" or "no")
        local shownNow = 0
        for _, b in ipairs(out) do
            local okI, id = pcall(function() return b.auraInstanceID end)
            Tally("frames", "frames|targetNameplate|" .. ctx .. "|auraInstanceID", Kind(okI, id))
            local okS, shown = pcall(b.IsShown, b)
            Tally("frames", "frames|targetNameplate|" .. ctx .. "|IsShown", Kind(okS, shown))
            if okS and shown == true then shownNow = shownNow + 1 end
            local okT, tex = pcall(function() return b.Icon and b.Icon:GetTexture() end)
            Tally("frames", "frames|targetNameplate|" .. ctx .. "|Icon", Kind(okT, tex))
            local okC, cnt = pcall(function() return b.Count and b.Count:GetText() end)
            Tally("frames", "frames|targetNameplate|" .. ctx .. "|Count", Kind(okC, cnt))
        end
        if s2.npShown ~= shownNow then
            Log("target nameplate aura buttons shown: " .. tostring(s2.npShown) .. " -> " .. shownNow .. " (" .. ctx .. ")")
            s2.npShown = shownNow
        end
    end
end

---------------------------------------------------------------------------
-- 4. Events
---------------------------------------------------------------------------

local function OnAuraEvent(unit, info)
    local ctx = Ctx()
    local label = "UNIT_AURA|" .. unit .. "|" .. ctx
    Tally("events", label .. "|payload", info == nil and "nil" or (type(info) == "table" and "table" or "other"))
    if type(info) ~= "table" then return end
    pcall(function()
        local full = info.isFullUpdate
        Tally("events", label .. "|isFullUpdate", Kind(true, full))
        local added = info.addedAuras
        Tally("events", label .. "|addedAuras", Kind(true, added))
        if type(added) == "table" and not issecretvalue(added) then
            for _, a in ipairs(added) do
                local okI, id = pcall(function() return a.auraInstanceID end)
                local okS, sid = pcall(function() return a.spellId end)
                local okN, nm = pcall(function() return a.name end)
                Tally("events", label .. "|added.auraInstanceID", Kind(okI, id))
                Tally("events", label .. "|added.spellId", Kind(okS, sid))
                Tally("events", label .. "|added.name", Kind(okN, nm))
                if okI and id ~= nil and not issecretvalue(id) then
                    local spell = (okS and not issecretvalue(sid)) and sid or nil
                    local name = (okN and not issecretvalue(nm)) and nm or nil
                    Track(unit, id, spell, name, "event_" .. ctx)
                end
                if ctx:sub(1, 6) == "combat" then
                    Log("UNIT_AURA " .. unit .. " added spell=" .. Show(okS, sid) .. " name=" .. Show(okN, nm)
                        .. " inst=" .. Show(okI, id))
                end
            end
        end
        local removed = info.removedAuraInstanceIDs
        Tally("events", label .. "|removedIDs", Kind(true, removed))
        if type(removed) == "table" and not issecretvalue(removed) then
            for _, id in ipairs(removed) do
                if not issecretvalue(id) then
                    local t = tracked[unit] and tracked[unit][id]
                    if ctx:sub(1, 6) == "combat" then
                        Log("UNIT_AURA " .. unit .. " removed inst=" .. id .. (t and (" (" .. tostring(t.name or t.spell) .. ")") or ""))
                    end
                    Untrack(unit, id)
                end
            end
        end
        Tally("events", label .. "|updatedIDs", Kind(true, info.updatedAuraInstanceIDs))
    end)
end

local function OnCastEvent(event, unit, _, spellID)
    local ctx = Ctx()
    local label = event .. "|" .. unit .. "|" .. ctx
    local ok, v = true, spellID
    Tally("events", label .. "|spellID", Kind(ok, v))
    if unit == "player" and ctx:sub(1, 6) == "combat" and event == "UNIT_SPELLCAST_SUCCEEDED" then
        local name
        if not issecretvalue(spellID) and spellID then name = C_Spell.GetSpellName(spellID) end
        Log("cast player " .. Show(true, spellID) .. " " .. tostring(name))
    end
end

---------------------------------------------------------------------------
-- Driver
---------------------------------------------------------------------------

local frame = CreateFrame("Frame")
local since, sinceOoc = 0, 0

local function Tick(inCombat)
    pcall(StudyViewers)
    pcall(StudyBlizzardFrames)
    if UnitExists("target") then pcall(TestTracked, "target") end
    pcall(TestTracked, "player")
    if not inCombat then
        pcall(CaptureAuras, "player")
        if UnitExists("target") then pcall(CaptureAuras, "target") end
    end
end

frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterUnitEvent("UNIT_AURA", "player", "target")
frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "target")
frame:RegisterUnitEvent("UNIT_SPELLCAST_START", "target")
frame:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "target")

frame:SetScript("OnEvent", function(_, event, a1, a2, a3, a4)
    if event == "PLAYER_LOGIN" then
        if not HeadsUpDB or HeadsUpDB.surveyOff then return end
        local build = select(2, GetBuildInfo())
        local old = HeadsUpDB.survey2
        if type(old) ~= "table" or old.build ~= build then
            old = { build = build }
        end
        s2 = old
        HeadsUpDB.survey2 = s2
        s2.tracked = s2.tracked or {}
        s2.cdmItems = s2.cdmItems or {}
        s2.class = select(2, UnitClass("player"))
        feeder = CreateFrame("Cooldown", nil, UIParent, "CooldownFrameTemplate")
        feeder:SetSize(16, 16)
        feeder:SetPoint("CENTER", UIParent, "CENTER", 0, 5000)
        probeFrame = CreateFrame("Frame", nil, UIParent)
        probeFrame:SetSize(16, 16)
        probeFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 5000)
        -- is the combat log open to addons?
        -- measured 20 Oct 2026: registering COMBAT_LOG_EVENT_UNFILTERED is blocked by the game (and shows
        -- the "blocked from an action" window), so it is not tried again.
        s2.combatLogRegister = "blocked (measured 2026-10-20)"
        -- which functions exist (new ones may have come with the patch); and the game's own damage meter
        s2.api = {}
        for _, ns in ipairs({ "C_UnitAuras", "C_Secrets", "C_CooldownViewer", "C_DamageMeter", "C_AuraContainerUtil",
                              "C_CurveUtil", "C_DurationUtil", "AuraUtil" }) do
            local t = _G[ns]
            if type(t) == "table" then
                local names = {}
                for k, v in pairs(t) do
                    if type(v) == "function" then names[#names + 1] = tostring(k) end
                end
                table.sort(names)
                s2.api[ns] = table.concat(names, ",")
            else
                s2.api[ns] = "missing"
            end
        end
        s2.dmeter = {}
        if type(C_DamageMeter) == "table" then
            for k, v in pairs(C_DamageMeter) do
                if type(v) == "function" and (tostring(k):match("^Is") or tostring(k):match("^GetAvailable")) then
                    local ok, r = pcall(v)
                    s2.dmeter[k] = ok and (type(r) == "table" and ("table#" .. #r) or tostring(r)) or "error"
                end
            end
        end
        started = true
        C_Timer.After(8, function() HeadsUp_ScanCatalog(false) end)
        return
    end
    if not started then return end
    if event == "UNIT_AURA" then
        OnAuraEvent(a1, a2)
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" or event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START" then
        OnCastEvent(event, a1, a2, a3)
    elseif event == "PLAYER_REGEN_DISABLED" then
        Log("== combat started")
        Tick(true)
    elseif event == "PLAYER_REGEN_ENABLED" then
        Log("== combat ended")
        C_Timer.After(5, function() HeadsUp_ScanCatalog(false) end)
    elseif event == "PLAYER_TARGET_CHANGED" then
        for id in pairs(tracked.target) do tracked.target[id] = nil end
        trackedCount.target = 0
        if UnitExists("target") and not UnitAffectingCombat("player") then pcall(CaptureAuras, "target") end
    end
end)

frame:SetScript("OnUpdate", function(_, elapsed)
    if not started then return end
    if UnitAffectingCombat("player") then
        since = since + elapsed
        if since >= 1 then
            since = 0
            Tick(true)
        end
    else
        sinceOoc = sinceOoc + elapsed
        if sinceOoc >= 3 then
            sinceOoc = 0
            Tick(false)
        end
    end
end)
