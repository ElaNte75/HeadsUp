-- HeadsUp: a list of "auras" (indicators), each driven by its own saved settings.
--
-- Every indicator is made of three frames:
--   A (invisible): alpha follows player health (1 if below the chosen %, else 0).
--   C (invisible): child of A, alpha follows the resource the ability costs (1 if enough, else 0).
--   ... more invisible frames in a chain (enemy, cooldown, charges, glow, alive, available,
--   resource, second resource), each one the child of the one before;
--   B (ability icon): child of the last one -> visible only when every enabled condition is true.
-- The addon never branches on secret values; it only wires values to displays.
--
-- Editing: the settings window edits a working copy ("draft") of one aura. The draft is
-- previewed live, but only written to the saved list when Save is pressed.
-- Positioning: an aura that is being edited, or selected in the list, shows its placeholder
-- and can be dragged with the left mouse button (a selected one is saved immediately).

-- Error log: every Lua error that mentions HeadsUp is kept (with the time) in
-- HeadsUpDB.errors, so it can be read from the SavedVariables file after /reload.
local pendingErrors = {}
local function LogError(text)
    local entry = date("%Y-%m-%d %H:%M:%S  ") .. text:sub(1, 800)
    if HeadsUpDB then
        local list = HeadsUpDB.errors or {}
        HeadsUpDB.errors = list
        list[#list + 1] = entry
        while #list > 20 do table.remove(list, 1) end
    else
        pendingErrors[#pendingErrors + 1] = entry
    end
end
local previousHandler = geterrorhandler()
seterrorhandler(function(err)
    local text = tostring(err)
    if text:find("HeadsUp") then LogError(text) end
    return previousHandler(err)
end)

-- Display priority 1..5 = the frame strata used (3 = the usual one).
local STRATA = { "BACKGROUND", "LOW", "MEDIUM", "HIGH", "DIALOG" }
-- The glow / pulse ring always sits one strata above its own icon.
local EFFECT_STRATA = { "LOW", "MEDIUM", "HIGH", "DIALOG", "FULLSCREEN" }
-- How small the icon gets during "Pulse" (1 = not at all).
local PULSE_SHRINK = 0.92

local KEYS = { "class", "specs", "name", "hidden", "spellID", "healthEnabled", "healthOp", "healthPct", "enemyEnabled", "enemyOp", "enemyPct", "cdEnabled", "cdState", "chargesEnabled", "chargesState", "enemyAliveEnabled", "enemyAlive", "buffEnabled", "buffID", "buffState", "suppressEnabled", "suppressSeconds", "suppressReset", "uid", "trackerOf", "trackerCue", "kind", "trackShow", "barDrain", "barIcon", "barColor", "barTime", "barTimeOn", "barIconOn", "otherAuras", "crowdEnabled", "crowdOp", "crowdN", "crowdMetric", "group", "effect", "icon", "showWhenEnabled", "showRules", "lingerEnabled", "lingerSeconds", "layer", "availEnabled", "pos", "width", "height", "sizeLinked", "powerEnabled", "powerOp", "powerValue", "secEnabled", "secOp", "secValue", "buffAlways", "empowerFx", "soundEnabled", "soundKey", "soundVolume", "formEnabled", "formSpell", "tgtHostileEnabled", "tgtHostile", "tgtTypeEnabled", "tgtType", "tgtClassEnabled", "tgtClass", "threatEnabled", "threatState", "shape", "empowerLight", "itemID", "ctIcon", "ctName", "ctNum", "ctColor", "ctSize", "ctBg", "ctBgAlpha", "ctWho", "ctChar", "ctType", "currencyID", "ctBank" }

local auras = {}        -- saved list (HeadsUpDB.auras)
local pool = {}         -- pool[i] = indicator for auras[i]
local newInd            -- indicator used for a draft that is not saved yet
local draft, editIndex, editInd
local currentSpec     -- id of the specialization being played (Blood, Frost, ...)
local function RefreshCurrentSpec()
    local index = GetSpecialization()
    currentSpec = index and (GetSpecializationInfo(index)) or nil
end

-- The sounds for "Play a sound when it shows". file = our own sounds (HeadsUp/Sounds, made by
-- tools/make_sounds.py: three files for each, 1 = soft, 2 = normal, 3 = loud). id = a sound of the game
-- (ids of its sound kits, from its own code); the game has no volume for those, so a louder level
-- plays the same sound two or three times at once.
HeadsUpSounds = {
    { key = "ding", text = "Ding", file = "ding" },
    { key = "dingdong", text = "Ding-dong", file = "dingdong" },
    { key = "double", text = "Double ding", file = "double" },
    { key = "chime", text = "Chime", file = "chime" },
    { key = "ping", text = "Ping", file = "ping" },
    { key = "gong", text = "Gong", file = "gong" },
    { key = "bell", text = "Game: Alarm bell", id = 12889 },
    { key = "bell2", text = "Game: Alarm bell 2", id = 12867 },
    { key = "warning", text = "Game: Raid warning", id = 8959 },
    { key = "auction", text = "Game: Auction bell", id = 5274 },
    { key = "auction2", text = "Game: Auction bell 2", id = 5275 },
    { key = "ready", text = "Game: Ready check", id = 8960 },
    { key = "role", text = "Game: Role check", id = 17317 },
    { key = "alert", text = "Game: Alert", id = 15273 },
}

-- every sound that is played is written to HeadsUpDB.soundLog (the answer of the game: did it play?),
-- so that a silent sound can be examined from the log file
local function LogSound(text)
    if not HeadsUpDB then return end
    local list = HeadsUpDB.soundLog or {}
    HeadsUpDB.soundLog = list
    list[#list + 1] = date("%H:%M:%S ") .. text
    while #list > 20 do table.remove(list, 1) end
end

-- volume: 1 = soft, 2 = normal, 3 = loud
function HeadsUp_PlaySound(key, volume)
    volume = math.max(1, math.min(3, volume or 2))
    for _, sound in ipairs(HeadsUpSounds) do
        if sound.key == key then
            if sound.file then
                local path = "Interface\\AddOns\\HeadsUp\\Sounds\\" .. sound.file .. "_" .. volume .. ".ogg"
                local ok, willPlay, handle = pcall(PlaySoundFile, path, "Master")
                LogSound(key .. " file " .. path .. " -> " .. tostring(ok) .. " willPlay=" .. tostring(willPlay)
                    .. " handle=" .. tostring(handle))
            else
                for n = 1, volume do
                    local ok, willPlay, handle = pcall(PlaySound, sound.id, "Master")
                    LogSound(key .. " game id " .. sound.id .. " #" .. n .. " -> " .. tostring(ok)
                        .. " willPlay=" .. tostring(willPlay) .. " handle=" .. tostring(handle))
                end
            end
            return
        end
    end
    LogSound("unknown sound " .. tostring(key))
end

local errorShown = false
local inCombat = false   -- kept up to date by PLAYER_REGEN_DISABLED / PLAYER_REGEN_ENABLED
local playerClass

local function NewConfig()
    return {
        class = playerClass,
        -- the specializations (ids) this aura belongs to; nil = all of them.
        -- A new aura starts with the spec being played now.
        specs = currentSpec and { [currentSpec] = true } or nil,
        spellID = nil,
        healthEnabled = false,   -- a new aura starts with every condition off
        healthOp = "<",          -- "<", "=" or ">"
        healthPct = 80,
        enemyEnabled = false,    -- the enemy = your current target, if you can attack it
        enemyOp = "<",
        enemyPct = 80,
        availEnabled = false,    -- "the ability is available": not on cooldown and enough resource
        powerEnabled = false,    -- the main resource (runic power, mana, rage, ...) compared with a value ...
        powerOp = "<",           -- ... "<", "=" or ">"
        powerValue = 40,         -- ... in the resource's own units (a percent for mana)
        secEnabled = false,      -- the second resource (runes, holy power, combo points, ...) ...
        secOp = ">=",            -- ... ">=" (at least), "<=" (at most) or "=" (exactly)
        secValue = 1,            -- ... this many
        cdEnabled = false,       -- cooldown condition ...
        cdState = "cooling",     -- ... "cooling" = on cooldown, "ready" = not on cooldown
        chargesEnabled = false,  -- charges condition (only for abilities with several charges) ...
        chargesState = "any",    -- ... "any" = 1 or more charges, "full" = all charges ready
        enemyAliveEnabled = false, -- the target is alive / dead ...
        enemyAlive = "yes",        -- ... "yes" = alive, "no" = dead
        formEnabled = false,       -- your form (druid forms...) is this one ...
        formSpell = 0,             -- ... the spell id of the form (0 = no form)
        tgtHostileEnabled = false, -- the hostility of the target ...
        tgtHostile = "enemy",      -- ... "enemy", "friend" or "neutral"
        crowdEnabled = false,      -- how many enemies are around (counted from the nameplates): the number compared ...
        crowdOp = ">=",            -- ... with this operator ...
        crowdN = 2,                -- ... and this number (typed by the player) ...
        crowdMetric = "combat",    -- ... counting the enemies "combat" (in combat) or "me" (attacking the player)
        tgtTypeEnabled = false,    -- the target is a player / an NPC ...
        tgtType = "npc",           -- ... "npc" or "player"
        tgtClassEnabled = false,   -- the target is a boss / rare / elite / normal mob (any ticked one) ...
        tgtClass = { boss = true, rare = true },
        empowerLight = "on",       -- the soft light of a themed Empowered effect: "on" or "off" (the Show effect ring is separate)
        shape = "square",          -- the icon is a "square" or "round" (a circle with a rim, made to match the effect)
        threatEnabled = false,     -- the target is attacking me (has aggro on me) ...
        threatState = "yes",       -- ... "yes" or "no"
        -- "Buff" (e.g. Dark Succor): the ability is lit up by it. The game hides buffs in combat
        -- but not the glow, so the glow of the aura's ability is what is checked.
        buffEnabled = false,
        buffID = nil,            -- the buff chosen by the player (for the label; the glow is checked)
        buffState = "active",    -- "active" = the ability is lit up, "gone" = it is not
        soundEnabled = false,    -- play a sound when the aura shows (only when its conditions can be known) ...
        soundKey = "ding",       -- ... this one (see HeadsUpSounds) ...
        soundVolume = 2,         -- ... 1 = soft, 2 = normal, 3 = loud
        empowerFx = "auto",      -- the effect shown while the icon is on because its ability is empowered:
                                 -- "auto" (by specialization), "sunburst", "flame", "burst", "frost", "blood", "poison"
        buffAlways = false,      -- with "Empowered: active": also show it whenever it is lit up, ignoring the other
                                 -- conditions (the "Show it only" rules, specs and hide-timer still apply)
        showWhenEnabled = false, -- off = the aura may always show; on = only as chosen below
        -- the ticked situations: combat / out, mounted / unmounted, vehicle / novehicle, never
        showRules = { always = true },   -- ticking "Show it only" starts from "Always"
        lingerEnabled = false,   -- with "In combat": keep counting as "in combat" a while after it ends ...
        lingerSeconds = 5,       -- ... this many seconds
        effect = "none",         -- "none", "glow" (pulsing ring) or "pulse" (ring + icon shrinks/grows)
        icon = nil,              -- a picture chosen by the player; nil = the ability's own icon
        suppressEnabled = false, -- after the player casts the ability, hide it for a while ...
        suppressSeconds = 10,    -- ... this many seconds (the length of its effect)
        suppressReset = false,   -- ... and start over (show it again) when the player changes target
        trackerCue = true,       -- a debuff tracker: its aura shows again when the tracker's timer ends
        kind = "ability",        -- what the aura is: "ability" (press it now), "buff" or "debuff" (follow an effect with our own timer)
        trackShow = "hide",      -- with the timer: "hide" = hidden while it runs, "while" = shown only while it runs
        barDrain = "left",       -- a bar empties toward this side ("left" or "right")
        barIcon = "left",        -- a bar's small icon: "left", "right" or "none"
        barColor = { 1, 0.56, 0.12 },   -- the colour of the bar
        barTime = "right",       -- where the seconds left are written on the bar: "left", "center" or "right"
        barTimeOn = true,        -- ... and whether they are written at all
        barIconOn = true,        -- whether the bar has its small icon (at the side barIcon)
        -- a Counter (kind "counter", shape "text"): how many of an item are in the bags, written as text without any frame.
        -- spellID is 0 once an item is chosen (so the rest of the addon treats it as an aura with a subject).
        ctType = "item",         -- what is counted: an "item" (in the bags, optionally in the bank too) or a "currency" ...
        itemID = nil,            -- ... the item that is counted ...
        currencyID = nil,        -- ... or the currency (crests, coins, keys...: they are not in the bags) ...
        ctBank = false,          -- ... and, for an item, whether the bank and the reagent bank count too
        ctIcon = "left",         -- where the item's picture is written: "off", "left", "center" or "right" ...
        ctName = "left",         -- ... the item's name ...
        ctNum = "right",         -- ... and the number (the pieces that are written in the same place go side by side)
        ctColor = { 1, 1, 1 },   -- the colour of the letters
        ctSize = 12,             -- the size of the letters, in pixels (typed by the player)
        ctBg = { 0, 0, 0 },      -- the colour of the box behind the text of a counter (text or bar): black ...
        ctWho = "spec",          -- who sees a counter: "all" (every character), "char" (only the one that made it), "spec" (its class
                                 -- and specializations, as an ability) or "prof" (the characters with the profession of the item)
        ctChar = nil,            -- the character that made it ("Name-Realm"), for "char"
        ctBgAlpha = 20,          -- ... and how solid it is, in percent (0 = no box at all, 100 = solid): 20
        layer = 3,        -- display priority 1..5 (3 = normal); higher is drawn on top
        pos = nil,        -- { point, relPoint, x, y }
        width = 50,       -- the icon is width x height pixels ...
        height = 50,
        sizeLinked = true, -- ... and while linked, changing one makes the other the same (a square)
    }
end

local function CopyConfig(src)
    local copy = {}
    for _, k in ipairs(KEYS) do
        if k == "pos" and src.pos then
            copy.pos = { unpack(src.pos) }
        elseif (k == "showRules" or k == "tgtClass") and src[k] then
            copy[k] = {}
            for rule, on in pairs(src[k]) do copy[k][rule] = on end
        elseif k == "otherAuras" and src.otherAuras then
            copy.otherAuras = {}
            for i, row in ipairs(src.otherAuras) do copy.otherAuras[i] = { uid = row.uid, state = row.state } end
        elseif k == "barColor" and src.barColor then
            copy.barColor = { src.barColor[1], src.barColor[2], src.barColor[3] }
        elseif k == "ctColor" and src.ctColor then
            copy.ctColor = { src.ctColor[1], src.ctColor[2], src.ctColor[3] }
        elseif k == "ctBg" and src.ctBg then
            copy.ctBg = { src.ctBg[1], src.ctBg[2], src.ctBg[3] }
        elseif k == "specs" and src.specs then
            copy.specs = {}
            for id, on in pairs(src.specs) do copy.specs[id] = on end
        else
            copy[k] = src[k]
        end
    end
    return copy
end

-- Every saved aura has an id of its own that survives renaming: other auras link to it ("Timer of ...").
local uidCount = 0
local function NewUid()
    uidCount = uidCount + 1
    return string.format("%x%x%x", time(), math.random(0, 0xfffff), uidCount)
end

local function FillDefaults(cfg)
    local d = NewConfig()
    -- (a counter that is a bar had a dark box before the background could be chosen)
    if cfg.ctBgAlpha == nil and cfg.kind == "counter" and cfg.shape == "bar" then cfg.ctBgAlpha = 80 end
    for _, k in ipairs(KEYS) do
        -- (specs stays nil for older auras: they belong to every specialization)
        if cfg[k] == nil and k ~= "spellID" and k ~= "pos" and k ~= "specs" then cfg[k] = d[k] end
    end
    if cfg.ctNum == "off" then cfg.ctNum = "right" end   -- (a counter always writes its number)
end

local function MakeStepCurve(threshold, belowValue, aboveValue)
    local c = C_CurveUtil.CreateCurve()
    c:SetType(Enum.LuaCurveType.Step)
    c:AddPoint(0, belowValue)
    c:AddPoint(math.min(math.max(threshold, 0.001), 1), aboveValue)
    c:AddPoint(1, aboveValue)
    return c
end

-- Curve over the cooldown's remaining seconds: 1 when the condition holds, else 0.
-- "ready"   : nothing remaining (not on cooldown)
-- "cooling" : anything remaining (on cooldown)
local function MakeCooldownCurve(state)
    local c = C_CurveUtil.CreateCurve()
    c:SetType(Enum.LuaCurveType.Step)
    if state == "ready" then
        c:AddPoint(0, 1)
        c:AddPoint(0.001, 0)
    else
        c:AddPoint(0, 0)
        c:AddPoint(0.001, 1)
    end
    return c
end

-- Curve that outputs 1 while the health fraction x satisfies the comparison, else 0.
-- A point (x, v) means "value v from x up to the next point".
--   "<" : below pct        ">" : above pct        "=" : rounds to pct (pct +/- 0.5%)
--   "<=" : below or equal  ">=" : above or equal
local function MakeHealthCurve(op, pct, invert)
    local inside, outside = 1, 0
    if invert then inside, outside = 0, 1 end   -- the opposite: 1 where the comparison does NOT hold
    local lo, hi
    if op == ">" then
        lo, hi = pct + 0.0001, 2
    elseif op == ">=" then
        lo, hi = pct - 0.005, 2
    elseif op == "<=" then
        lo, hi = 0, pct + 0.005
    elseif op == "=" then
        lo, hi = pct - 0.005, pct + 0.005
    else
        lo, hi = 0, pct
    end
    local c = C_CurveUtil.CreateCurve()
    c:SetType(Enum.LuaCurveType.Step)
    if lo <= 0 then
        c:AddPoint(0, inside)
    else
        c:AddPoint(0, outside)
        if lo <= 1 then c:AddPoint(lo, inside) end
    end
    if lo <= 1 and hi <= 1 then c:AddPoint(hi, outside) end
    return c
end

---------------------------------------------------------------------------
-- Resources of the player's class
---------------------------------------------------------------------------

-- The second resource of each class: { power type id, label }.
-- (4 combo points, 5 runes, 7 soul shards, 9 holy power, 12 chi, 16 arcane charges, 19 essence)
local SECONDARY_BY_CLASS = {
    DEATHKNIGHT = { 5, "Runes ready" },
    PALADIN = { 9, "Holy Power" },
    ROGUE = { 4, "Combo Points" },
    DRUID = { 4, "Combo Points" },
    WARLOCK = { 7, "Soul Shards" },
    MONK = { 12, "Chi" },
    MAGE = { 16, "Arcane Charges" },
    EVOKER = { 19, "Essence" },
}

-- What the settings window offers for this class right now:
--   primary   = { type, name, max, percent }  the main resource (percent: mana is compared in %)
--   secondary = { type, name, max }           runes, holy power, combo points ... (nil if none)
local function GetResources()
    local out = {}
    local powerType, token = UnitPowerType("player")
    if powerType then
        local max = UnitPowerMax("player", powerType)
        if type(max) ~= "number" or issecretvalue(max) or max <= 0 then max = 100 end
        out.primary = {
            type = powerType,
            name = (token and _G[token]) or "Resource",
            max = max,
            percent = (powerType == 0),   -- 0 = mana
        }
    end
    local second = SECONDARY_BY_CLASS[playerClass]
    if second then
        local max = UnitPowerMax("player", second[1])
        if type(max) ~= "number" or issecretvalue(max) or max <= 0 then
            max = (second[1] == 5) and 6 or 5
        end
        out.secondary = { type = second[1], name = second[2], max = max }
    end
    return out
end

local function Compare(a, op, b)
    if op == "<" then return a < b end
    if op == ">" then return a > b end
    if op == "<=" then return a <= b end
    if op == ">=" then return a >= b end
    return a == b
end

-- How many of the second resource the player has now (ready runes, holy power, ...).
-- nil when the game does not let us read it. Every reading is counted in HeadsUpDB.resourceStats
-- (in combat / out of combat, readable / hidden), so the log file shows how reliable it is.
local function SecondaryCount(powerType)
    local count
    local ok = pcall(function()
        if powerType == 5 then
            local ready = 0
            for i = 1, 6 do
                local _, _, isReady = GetRuneCooldown(i)
                if issecretvalue(isReady) then error("secret") end
                if isReady then ready = ready + 1 end
            end
            count = ready
        else
            local value = UnitPower("player", powerType)
            if issecretvalue(value) then error("secret") end
            count = value
        end
    end)
    if HeadsUpDB then
        local stats = HeadsUpDB.resourceStats or {}
        HeadsUpDB.resourceStats = stats
        local key = (inCombat and "combat_" or "ooc_") .. (ok and "readable" or "hidden")
        stats[key] = (stats[key] or 0) + 1
    end
    if ok then return count end
    return nil
end

---------------------------------------------------------------------------
-- Indicator (one per aura)
---------------------------------------------------------------------------

local RefreshMouse, Update

-- The "Empowered effect": a show-off effect on an icon that is shown because its ability is
-- empowered. Three styles, built once from the game's own light textures. Every style has a layer
-- BEHIND the icon (stars, rings) and a layer ON the icon (a light tint and a glint that sweeps over
-- the picture, so it shines).
--   sunburst : three golden stars that turn in opposite ways, and a pulsing ring
--   flame    : three flickering orange stars (the flames, far out of the icon), and two rings
--   burst    : a flash and three waves of light the moment it is empowered, then a soft glow with
--              a wave that goes out again and again
local FX_STAR = "Interface\\Cooldown\\star4"
local FX_PING = "Interface\\Cooldown\\ping4"
local FX_RING = "Interface\\Buttons\\UI-ActionButton-Border"
local FX_WHITE = "Interface\\Buttons\\WHITE8x8"
-- our own pictures of the themed effects (made by tools/make_fx.py)
local FX_DIR = "Interface\\AddOns\\HeadsUp\\Media\\fx\\"
local FX_GLOW, FX_SHARD, FX_FLAKE = FX_DIR .. "glow.tga", FX_DIR .. "shard.tga", FX_DIR .. "flake.tga"
local FX_SPLAT, FX_DROP, FX_BUBBLE = FX_DIR .. "splat.tga", FX_DIR .. "drop.tga", FX_DIR .. "bubble.tga"

local FX_MASK, FX_RINGGLOW = FX_DIR .. "mask.tga", FX_DIR .. "ringglow.tga"
-- the rim of a round icon follows the effect (gold for the classic ones)
local RIM_BY_STYLE = { frost = FX_DIR .. "rim_frost.tga", blood = FX_DIR .. "rim_blood.tga", poison = FX_DIR .. "rim_poison.tga" }
local RIM_GOLD = FX_DIR .. "rim_gold.tga"

-- The theme of the "Auto" effect: by the specialization (ids). Unlisted specs use the sunburst.
local SPEC_FX = {
    [250] = "blood",    -- Death Knight Blood
    [251] = "frost",    -- Death Knight Frost
    [252] = "poison",   -- Death Knight Unholy
    [64] = "frost",     -- Mage Frost
    [259] = "poison",   -- Rogue Assassination
}

local function MakeFx(parent)
    local fx = CreateFrame("Frame", nil, parent)
    fx:SetAllPoints(parent)
    fx:SetFrameLevel(parent:GetFrameLevel())   -- one level under the icon: it glows from behind
    fx:SetAlpha(0)
    fx.styles = {}

    -- small helpers: a texture, and the animations
    local function texture(path, r, g, b, parentFrame, blend, alpha)
        local t = (parentFrame or fx):CreateTexture(nil, "BACKGROUND")
        t:SetTexture(path)
        t:SetBlendMode(blend or "ADD")
        t:SetVertexColor(r, g, b, alpha or 1)
        t:SetPoint("CENTER", parentFrame or fx, "CENTER")
        t:Hide()
        return t
    end
    local function pulse(region, from, to, seconds)
        local group = region:CreateAnimationGroup()
        group:SetLooping("BOUNCE")
        local a = group:CreateAnimation("Alpha")
        a:SetFromAlpha(from)
        a:SetToAlpha(to)
        a:SetDuration(seconds)
        a:SetSmoothing("IN_OUT")
        return group
    end
    local function spin(region, degrees, seconds)
        local group = region:CreateAnimationGroup()
        group:SetLooping("REPEAT")
        local r = group:CreateAnimation("Rotation")
        r:SetDegrees(degrees)
        r:SetDuration(seconds)
        return group
    end
    local function scaleStep(group, from, to, seconds)
        local s = group:CreateAnimation("Scale")
        if s.SetScaleFrom then
            s:SetScaleFrom(from, from)
            s:SetScaleTo(to, to)
        else
            s:SetScale(to / from, to / from)
        end
        s:SetDuration(seconds)
        return s
    end
    -- breathing: the region grows and shrinks (a flame that flickers)
    local function breathe(region, from, to, seconds)
        local group = region:CreateAnimationGroup()
        group:SetLooping("BOUNCE")
        local s = scaleStep(group, from, to, seconds)
        s:SetSmoothing("IN_OUT")
        return group
    end
    -- a wave: grows from..to while fading away. repeating: it starts again after a pause
    local function wave(region, from, to, seconds, repeating, pause)
        local group = region:CreateAnimationGroup()
        local s = scaleStep(group, from, to, seconds)
        s:SetSmoothing("OUT")
        local a = group:CreateAnimation("Alpha")
        a:SetFromAlpha(1)
        a:SetToAlpha(0)
        a:SetDuration(seconds)
        if repeating then
            group:SetLooping("REPEAT")
            if a.SetEndDelay then a:SetEndDelay(pause or 1) end
        else
            group:SetScript("OnFinished", function() region:Hide() end)
        end
        return group
    end

    -- a drop that falls (or a bubble that rises: the offset decides) while fading out; then it starts again
    local function fall(region, seconds, delay, pause)
        local group = region:CreateAnimationGroup()
        group:SetLooping("REPEAT")
        local move = group:CreateAnimation("Translation")
        move:SetDuration(seconds)
        move:SetSmoothing("IN")
        if move.SetStartDelay then move:SetStartDelay(delay or 0) end
        local fade = group:CreateAnimation("Alpha")
        fade:SetFromAlpha(1)
        fade:SetToAlpha(0)
        fade:SetDuration(seconds)
        if fade.SetStartDelay then fade:SetStartDelay(delay or 0) end
        if pause and move.SetEndDelay then
            move:SetEndDelay(pause)
            fade:SetEndDelay(pause)
        end
        return group, move
    end
    -- appears: grows from small while fading in (plays once)
    local function pop(region, seconds)
        local group = region:CreateAnimationGroup()
        local grow = scaleStep(group, 0.35, 1, seconds)
        grow:SetSmoothing("OUT")
        local fade = group:CreateAnimation("Alpha")
        fade:SetFromAlpha(0)
        fade:SetToAlpha(1)
        fade:SetDuration(seconds)
        return group
    end

    ------------------------------------------------------------
    -- the layer ON the icon: a light tint and a glint
    ------------------------------------------------------------
    local top = CreateFrame("Frame", nil, fx)
    top:SetAllPoints(parent)
    top:SetFrameLevel(parent:GetFrameLevel() + 6)
    top:SetClipsChildren(true)   -- nothing of it leaves the picture
    fx.top = top

    local tint = top:CreateTexture(nil, "OVERLAY")
    tint:SetAllPoints(top)
    tint:SetColorTexture(1, 1, 1, 1)
    tint:SetBlendMode("ADD")
    local tintPulse = pulse(tint, 0.03, 0.26, 0.5)

    -- the glint: a soft vertical stripe of light that crosses the icon every second or so
    local glint = CreateFrame("Frame", nil, top)
    local g1 = glint:CreateTexture(nil, "OVERLAY")
    g1:SetColorTexture(1, 1, 1, 1)
    g1:SetBlendMode("ADD")
    g1:SetPoint("TOPLEFT", glint, "TOPLEFT")
    g1:SetPoint("BOTTOMRIGHT", glint, "BOTTOM")
    local g2 = glint:CreateTexture(nil, "OVERLAY")
    g2:SetColorTexture(1, 1, 1, 1)
    g2:SetBlendMode("ADD")
    g2:SetPoint("TOPLEFT", glint, "TOP")
    g2:SetPoint("BOTTOMRIGHT", glint, "BOTTOMRIGHT")
    local okGradient = pcall(function()
        g1:SetGradient("HORIZONTAL", CreateColor(1, 1, 1, 0), CreateColor(1, 1, 1, 0.65))
        g2:SetGradient("HORIZONTAL", CreateColor(1, 1, 1, 0.65), CreateColor(1, 1, 1, 0))
    end)
    if not okGradient then
        g1:SetColorTexture(1, 1, 1, 0.3)
        g2:SetColorTexture(1, 1, 1, 0.3)
    end
    local glintGroup = glint:CreateAnimationGroup()
    glintGroup:SetLooping("REPEAT")
    local glintMove = glintGroup:CreateAnimation("Translation")
    glintMove:SetDuration(0.7)
    if glintMove.SetEndDelay then glintMove:SetEndDelay(1.3) end
    glintMove:SetSmoothing("IN_OUT")

    ------------------------------------------------------------
    -- the styles
    -- items = { texture, size as a multiple of the icon }; steady = shown all the time; loops = running
    -- animations; once = { texture, animation, delay } played by Trigger(); tint = the colour of the
    -- tint on the icon
    ------------------------------------------------------------
    local s1 = texture(FX_STAR, 1.00, 0.85, 0.30)
    local s2 = texture(FX_STAR, 1.00, 1.00, 0.75)
    local s3 = texture(FX_STAR, 1.00, 0.70, 0.15)
    local sr = texture(FX_RING, 1.00, 0.80, 0.25)
    fx.styles.sunburst = {
        tint = { 1.0, 0.85, 0.3 },
        items = { { s1, 3.6 }, { s2, 2.4 }, { s3, 3.0 }, { sr, 1.9 } },
        steady = { s1, s2, s3, sr },
        loops = { spin(s1, -360, 12), spin(s2, 360, 8), spin(s3, 360, 18), pulse(sr, 1, 0.3, 0.6) },
    }

    local f1 = texture(FX_STAR, 1.00, 0.45, 0.10)
    local f2 = texture(FX_STAR, 1.00, 0.25, 0.05)
    local f3 = texture(FX_STAR, 1.00, 0.70, 0.20)
    local fr1 = texture(FX_RING, 1.00, 0.40, 0.08)
    local fr2 = texture(FX_RING, 1.00, 0.20, 0.05)
    fx.styles.flame = {
        tint = { 1.0, 0.45, 0.1 },
        items = { { f1, 3.8 }, { f2, 3.0 }, { f3, 2.3 }, { fr1, 2.4 }, { fr2, 2.0 } },
        steady = { f1, f2, f3, fr1, fr2 },
        loops = {
            spin(f1, -360, 10), pulse(f1, 1, 0.45, 0.22), breathe(f1, 0.85, 1.12, 0.3),
            spin(f2, 360, 7), pulse(f2, 0.4, 1, 0.3), breathe(f2, 1.1, 0.88, 0.25),
            spin(f3, -360, 5), pulse(f3, 1, 0.5, 0.18),
            pulse(fr1, 1, 0.3, 0.35), pulse(fr2, 0.3, 1, 0.5),
        },
    }

    local b1 = texture(FX_PING, 1.0, 0.85, 0.30)
    local b2 = texture(FX_PING, 1.0, 0.85, 0.30)
    local b3 = texture(FX_PING, 1.0, 0.85, 0.30)
    local bs = texture(FX_STAR, 1.0, 1.0, 0.80)
    local bf = texture(FX_WHITE, 1, 1, 1, top)     -- a white flash over the icon itself
    bf:SetAllPoints(top)
    local bg = texture(FX_STAR, 1.0, 0.8, 0.25)    -- a slow star behind, once it has settled
    local br = texture(FX_RING, 1.0, 0.8, 0.25)
    local bw = texture(FX_PING, 1.0, 0.85, 0.30)   -- the wave that keeps going out
    fx.styles.burst = {
        tint = { 1.0, 0.9, 0.4 },
        items = { { b1, 1 }, { b2, 1 }, { b3, 1 }, { bs, 1 }, { bg, 3.0 }, { br, 1.9 }, { bw, 1 } },
        steady = { bg, br, bw },
        loops = { spin(bg, 360, 14), pulse(br, 1, 0.35, 0.9), wave(bw, 1.0, 3.0, 1.0, true, 1.2) },
        once = {
            { b1, wave(b1, 0.8, 4.6, 0.8), 0 },
            { b2, wave(b2, 0.8, 4.6, 0.8), 0.15 },
            { b3, wave(b3, 0.8, 4.6, 0.8), 0.30 },
            { bs, wave(bs, 0.6, 4.2, 0.6), 0 },
            { bf, wave(bf, 1, 1, 0.4), 0 },
        },
    }


    ------------------------------------------------------------
    -- the themed styles. Their items are tables: tex, w and h (times the icon size), x and y (the
    -- place of the centre: times the icon width / height from the centre), dy (more, times the icon
    -- size), dist (an animation that moves: how far, times the icon size; negative = down), anim
    ------------------------------------------------------------
    local function themed(tint)
        return { tint = tint, items = {}, steady = {}, loops = {}, once = {}, lights = {} }
    end
    local function add(style, item, loop)
        style.items[#style.items + 1] = item
        style.steady[#style.steady + 1] = item.tex
        if loop then style.loops[#style.loops + 1] = loop end
        return item
    end
    -- a falling drop / a rising bubble: the animation is kept in the item so that Apply can set how far
    local function mover(style, item, seconds, delay, pause)
        local group, move = fall(item.tex, seconds, delay, pause)
        item.anim = move
        add(style, item, group)
    end

    -- a splash that keeps coming back: it grows on, stays, fades away, and then comes again somewhere else
    -- around the icon (turned another way)
    local function splatCycle(region, hold, fadeTime, pause)
        local group = region:CreateAnimationGroup()
        group:SetLooping("REPEAT")
        local grow = scaleStep(group, 0.3, 1, 0.22)
        grow:SetSmoothing("OUT")
        grow:SetOrder(1)
        local fadeIn = group:CreateAnimation("Alpha")
        fadeIn:SetFromAlpha(0)
        fadeIn:SetToAlpha(1)
        fadeIn:SetDuration(0.22)
        fadeIn:SetOrder(1)
        local stay = group:CreateAnimation("Alpha")
        stay:SetFromAlpha(1)
        stay:SetToAlpha(1)
        stay:SetDuration(hold)
        stay:SetOrder(2)
        local out = group:CreateAnimation("Alpha")
        out:SetFromAlpha(1)
        out:SetToAlpha(0)
        out:SetDuration(fadeTime)
        out:SetOrder(3)
        if pause and out.SetEndDelay then out:SetEndDelay(pause) end
        group:SetScript("OnLoop", function()
            local w, h = fx.cw or 50, fx.ch or 50
            local angle = math.random() * 2 * math.pi
            local reach = 0.5 + math.random() * 0.35
            region:ClearAllPoints()
            region:SetPoint("CENTER", fx, "CENTER", math.cos(angle) * reach * w * 1.15, math.sin(angle) * reach * h * 1.15)
            if region.SetRotation then region:SetRotation(math.random() * 2 * math.pi) end
        end)
        return group
    end

    -- FROST: a cold light, ice crystals turning slowly, icicles all around (hanging, standing, pointing out),
    -- drops falling from them, snow drifting down, stars that twinkle, a ring of frost when it turns on
    local frost = themed({ 0.45, 0.8, 1.0 })
    local fg1 = texture(FX_GLOW, 0.3, 0.7, 1.0)
    local fg2 = texture(FX_GLOW, 0.7, 0.95, 1.0)
    add(frost, { tex = fg1, w = 3.6, h = 3.6 }, pulse(fg1, 0.55, 1.0, 1.3))
    add(frost, { tex = fg2, w = 2.2, h = 2.2 }, pulse(fg2, 1.0, 0.4, 0.9))
    frost.lights = { fg1, fg2 }   -- the soft light: it can be switched off
    local crystal1 = texture(FX_STAR, 0.55, 0.85, 1.0)
    local crystal2 = texture(FX_STAR, 0.85, 0.97, 1.0)
    add(frost, { tex = crystal1, w = 4.0, h = 4.0 }, spin(crystal1, 360, 20))
    add(frost, { tex = crystal2, w = 2.8, h = 2.8 }, spin(crystal2, -360, 13))
    -- an icicle with a darker blue one behind it (so that it can be seen on any ground)
    local function icicle(x, y, len, dy, rot, flip, dx)
        local back = texture(FX_SHARD, 0.15, 0.4, 0.8, nil, "BLEND")
        local t = texture(FX_SHARD, 0.85, 0.96, 1.0, nil, "BLEND")
        add(frost, { tex = back, w = len * 0.46, h = len * 1.08, x = x, y = y, dy = dy, dx = dx, rot = rot, flip = flip, radial = true })
        add(frost, { tex = t, w = len * 0.36, h = len, x = x, y = y, dy = dy, dx = dx, rot = rot, flip = flip, radial = true })
    end
    local hang = { { -0.52, 0.5 }, { -0.4, 0.85 }, { -0.28, 0.6 }, { -0.14, 1.05 }, { 0, 0.7 }, { 0.14, 1.2 },
                   { 0.28, 0.65 }, { 0.4, 0.95 }, { 0.52, 0.55 } }
    for _, h in ipairs(hang) do icicle(h[1], -0.5, h[2], -h[2] / 2 + 0.06) end
    local standing = { { -0.5, 0.55 }, { -0.3, 0.8 }, { -0.1, 0.5 }, { 0.12, 0.9 }, { 0.32, 0.6 }, { 0.5, 0.75 } }
    for _, h in ipairs(standing) do icicle(h[1], 0.5, h[2], h[2] / 2 - 0.06, nil, true) end
    for _, side in ipairs({ -1, 1 }) do   -- pointing out to the left and to the right
        for _, h in ipairs({ { 0.22, 0.7 }, { -0.22, 0.55 } }) do
            icicle(side * 0.5, h[1], h[2], 0, side * math.pi / 2, false, side * (h[2] / 2 - 0.06))
        end
    end
    for i, delay in ipairs({ 0, 0.35, 0.7, 1.05, 1.4 }) do   -- drops from the hanging icicles
        local t = texture(FX_DROP, 0.75, 0.93, 1.0, nil, "BLEND")
        local h = hang[i * 2 - 1]
        mover(frost, { tex = t, w = 0.14, h = 0.28, x = h[1], y = -0.5, dy = -h[2] - 0.05, dist = -0.9 }, 1.2, delay, 0.2)
    end
    for i = 1, 6 do   -- snow drifting down
        local t = texture(FX_FLAKE, 0.9, 0.97, 1.0)
        local x = -0.6 + (i - 1) * 0.24
        mover(frost, { tex = t, w = 0.32, h = 0.32, x = x, y = 0.55, dist = -1.7 }, 2.6 + (i % 3) * 0.5, i * 0.4, 0.1)
    end
    local corners = { { -0.66, 0.6 }, { 0.68, 0.55 }, { 0.7, -0.6 }, { -0.68, -0.62 } }
    for i, c in ipairs(corners) do   -- big stars that twinkle
        local t = texture(FX_FLAKE, 0.85, 0.96, 1.0)
        add(frost, { tex = t, w = 0.62, h = 0.62, x = c[1], y = c[2] }, pulse(t, 0.25, 1, 0.45 + i * 0.17))
        frost.loops[#frost.loops + 1] = spin(t, (i % 2 == 0) and 360 or -360, 12 + i * 3)
    end
    local ring = texture(FX_PING, 0.5, 0.85, 1.0)
    frost.items[#frost.items + 1] = { tex = ring, w = 1, h = 1 }
    frost.once[#frost.once + 1] = { ring, wave(ring, 0.8, 4.4, 0.8), 0 }
    fx.styles.frost = frost

    -- BLOOD: a red glow, splashes that keep splatting on around the icon (each one grows on, stays, fades,
    -- and comes again somewhere else), wet drops running off the bottom
    local blood = themed({ 0.85, 0.05, 0.05 })
    local bg1 = texture(FX_GLOW, 0.85, 0.05, 0.05)
    local bg2 = texture(FX_GLOW, 1.0, 0.2, 0.1)
    add(blood, { tex = bg1, w = 3.4, h = 3.4 }, pulse(bg1, 0.5, 1.0, 1.1))
    add(blood, { tex = bg2, w = 2.0, h = 2.0 }, pulse(bg2, 0.9, 0.35, 0.8))
    blood.lights = { bg1, bg2 }
    local splats = {   -- x, y, size, red, hold, fade
        { -0.4, -0.25, 1.9, 0.7, 1.4, 0.9 },
        { 0.45, 0.3, 1.6, 0.8, 1.9, 0.8 },
        { 0.5, -0.45, 1.2, 0.6, 1.1, 0.7 },
        { -0.5, 0.45, 1.1, 0.65, 1.7, 0.9 },
        { 0.0, 0.6, 1.4, 0.75, 1.3, 0.8 },
        { -0.1, -0.65, 1.3, 0.55, 2.1, 0.9 },
    }
    for i, sp in ipairs(splats) do
        local t = texture(FX_SPLAT, sp[4], 0.02, 0.03, nil, "BLEND")
        add(blood, { tex = t, w = sp[3], h = sp[3], x = sp[1], y = sp[2] }, splatCycle(t, sp[5], sp[6], 0.1 * i))
    end
    for i, x in ipairs({ -0.4, -0.22, -0.04, 0.16, 0.34, 0.5 }) do
        local t = texture(FX_DROP, 0.8, 0.03, 0.04, nil, "BLEND")
        mover(blood, { tex = t, w = 0.17, h = 0.34, x = x, y = -0.5, dy = -0.05, dist = -1.0 }, 1.2 + (i % 3) * 0.2, i * 0.25, 0.15)
    end
    local flash = texture(FX_PING, 0.9, 0.1, 0.1)
    blood.items[#blood.items + 1] = { tex = flash, w = 1, h = 1 }
    blood.once[#blood.once + 1] = { flash, wave(flash, 0.8, 4.2, 0.7), 0 }
    fx.styles.blood = blood

    -- POISON: a strong toxic light, green smoke turning slowly, a puddle of poison behind, many bubbles
    -- rising, drops falling, and a wave of poison when it turns on
    local poison = themed({ 0.4, 0.95, 0.2 })
    local pg1 = texture(FX_GLOW, 0.3, 1.0, 0.1)
    local pg2 = texture(FX_GLOW, 0.8, 1.0, 0.4)
    add(poison, { tex = pg1, w = 3.6, h = 3.6 }, pulse(pg1, 0.55, 1.0, 0.9))
    add(poison, { tex = pg2, w = 2.0, h = 2.0 }, pulse(pg2, 1.0, 0.35, 0.7))
    poison.lights = { pg1, pg2 }
    local smoke1 = texture(FX_STAR, 0.4, 1.0, 0.15)
    local smoke2 = texture(FX_STAR, 0.6, 1.0, 0.3)
    add(poison, { tex = smoke1, w = 4.2, h = 4.2 }, spin(smoke1, 360, 22))
    add(poison, { tex = smoke2, w = 3.0, h = 3.0 }, spin(smoke2, -360, 15))
    local dark = texture(FX_SPLAT, 0.08, 0.35, 0.04, nil, "BLEND", 0.85)
    local puddle = texture(FX_SPLAT, 0.4, 0.95, 0.15, nil, "BLEND", 0.8)
    add(poison, { tex = dark, w = 2.8, h = 2.8, y = -0.05 }, breathe(dark, 0.95, 1.07, 1.9))
    add(poison, { tex = puddle, w = 2.2, h = 2.2, y = -0.1 }, breathe(puddle, 1.05, 0.93, 1.5))
    local bubbles = { { -0.5, 0.3, 0.0 }, { -0.3, 0.42, 0.4 }, { -0.1, 0.26, 0.8 }, { 0.12, 0.38, 0.2 },
                      { 0.32, 0.3, 0.6 }, { 0.5, 0.4, 1.0 }, { -0.4, 0.22, 1.2 }, { 0.0, 0.34, 1.5 },
                      { 0.22, 0.24, 1.8 }, { 0.42, 0.28, 0.9 } }
    for _, b in ipairs(bubbles) do
        local t = texture(FX_BUBBLE, 0.6, 1.0, 0.3)
        mover(poison, { tex = t, w = b[2], h = b[2], x = b[1], y = -0.4, dist = 1.5 }, 1.9, b[3], 0.05)
    end
    for i, x in ipairs({ -0.4, -0.2, 0.0, 0.2, 0.4 }) do
        local t = texture(FX_DROP, 0.5, 1.0, 0.2)
        mover(poison, { tex = t, w = 0.15, h = 0.3, x = x, y = -0.5, dy = -0.05, dist = -0.95 }, 1.2, i * 0.3, 0.15)
    end
    local ping = texture(FX_PING, 0.4, 1.0, 0.2)
    poison.items[#poison.items + 1] = { tex = ping, w = 1, h = 1 }
    poison.once[#poison.once + 1] = { ping, wave(ping, 0.8, 4.4, 0.8), 0 }
    fx.styles.poison = poison


    -- choose the style and size (the effect itself is switched on and off with the alpha of the frame)
    function fx:Apply(style, size, width, height, round, noLight)
        width, height = width or size, height or size
        self.round = round and true or false
        self.cw, self.ch = width, height   -- (the splashes of the blood style jump around the icon: they need them)
        if style ~= "none" and not self.styles[style] then style = "sunburst" end
        self.style = style
        for _, st in pairs(self.styles) do
            for _, item in ipairs(st.items) do (item.tex or item[1]):Hide() end
            for _, group in ipairs(st.loops) do group:Stop() end
            for _, o in ipairs(st.once or {}) do o[2]:Stop() end
        end
        if style == "none" then   -- no Empowered effect at all
            tintPulse:Stop()
            glintGroup:Stop()
            top:Hide()
            return
        end
        top:Show()
        local st = self.styles[style]
        for _, item in ipairs(st.items) do
            if item.tex then
                local t = item.tex
                t:SetSize(item.w * size, (item.h or item.w) * size)
                t:ClearAllPoints()
                local px = (item.x or 0) * width + (item.dx or 0) * size
                local py = (item.y or 0) * height + (item.dy or 0) * size
                local rot, flip = item.rot or 0, item.flip
                if self.round then
                    -- what stood on the edge of the rectangle now stands on the rim of the circle (icicles turn to point out)
                    local rx, ry = item.x or 0, item.y or 0
                    local m = math.max(math.abs(rx), math.abs(ry))
                    if m >= 0.49 then
                        local len = math.sqrt(rx * rx + ry * ry)
                        local ux, uy = rx / len, ry / len
                        px, py = ux * m * size, uy * m * size
                        if item.radial then
                            local out = (item.h or item.w) / 2 - 0.06
                            px, py = px + ux * out * size, py + uy * out * size
                            rot = math.atan2(ux, -uy)
                            flip = false
                        elseif item.dist and item.dist < 0 then
                            px, py = px + ux * 0.08 * size, py + uy * 0.08 * size   -- a drop starts just outside the rim
                        end
                    end
                end
                if flip ~= nil then
                    if flip then t:SetTexCoord(0, 1, 1, 0) else t:SetTexCoord(0, 1, 0, 1) end
                end
                if t.SetRotation then t:SetRotation(rot) end
                t:SetPoint("CENTER", self, "CENTER", px, py)
                if item.anim then item.anim:SetOffset(0, (item.dist or 0) * size) end
            elseif item[1] ~= bf then
                item[1]:SetSize(size * item[2], size * item[2])
            end
        end
        for _, t in ipairs(st.steady) do t:Show() end
        if noLight then
            for _, t in ipairs(st.lights or {}) do t:Hide() end   -- the soft light of a themed effect is off
        end
        for _, group in ipairs(st.loops) do group:Play() end
        -- the layer on the icon
        tint:SetVertexColor(st.tint[1], st.tint[2], st.tint[3], 1)
        tintPulse:Stop()
        tintPulse:Play()
        glint:SetSize(width * 0.5, height * 1.5)
        glint:ClearAllPoints()
        glint:SetPoint("CENTER", top, "CENTER", -width * 0.95, 0)
        glintMove:SetOffset(width * 1.9, 0)
        glintGroup:Stop()
        glintGroup:Play()
    end
    -- the moment it turns on: the styles with a one-time flash play it
    function fx:Trigger()
        local st = self.styles[self.style or "sunburst"]
        if not st then return end
        for _, o in ipairs(st.once or {}) do
            local region, group, delay = o[1], o[2], o[3] or 0
            local function go()
                region:Show()
                group:Stop()
                group:Play()
            end
            if delay > 0 then C_Timer.After(delay, go) else go() end
        end
    end
    -- a round icon: the tint, the glint and the flash on the icon are cut to the circle as well
    local roundMask = top:CreateMaskTexture()
    roundMask:SetTexture(FX_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    roundMask:SetAllPoints(top)
    function fx:SetRound(on)
        for _, region in ipairs({ tint, g1, g2, bf }) do
            if on then region:AddMaskTexture(roundMask) else region:RemoveMaskTexture(roundMask) end
        end
    end
    return fx
end

-- A second, independent face for the "always show when empowered" option: the same icon, glow
-- ring and pulse as the main one, on a frame of its own (so it is not held back by the chain of
-- conditions). Same pieces as the main face, built the same way.
local function MakeExtraFace(parent)
    local B2 = CreateFrame("Frame", nil, parent)
    B2:SetAllPoints(parent)
    local I2 = CreateFrame("Frame", nil, B2)
    I2:SetAllPoints(B2)
    local tex = I2:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints(I2)
    local mask = I2:CreateMaskTexture()
    mask:SetTexture(FX_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(I2)
    local cd = CreateFrame("Cooldown", nil, I2, "CooldownFrameTemplate")
    cd:SetAllPoints(I2)
    local RIM = CreateFrame("Frame", nil, B2)   -- the rim of a round icon, above the picture
    RIM:SetAllPoints(B2)
    RIM:SetFrameLevel(I2:GetFrameLevel() + 3)
    local rim = RIM:CreateTexture(nil, "ARTWORK")
    rim:SetPoint("CENTER", RIM, "CENTER")
    rim:Hide()
    local GL = CreateFrame("Frame", nil, B2)
    GL:SetAllPoints(B2)
    local glow = GL:CreateTexture(nil, "OVERLAY")
    glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    glow:SetBlendMode("ADD")
    glow:SetVertexColor(1, 0.85, 0.3, 1)
    glow:SetPoint("CENTER", GL, "CENTER")
    glow:Hide()
    local pulse = glow:CreateAnimationGroup()
    pulse:SetLooping("BOUNCE")
    local fade = pulse:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0.25)
    fade:SetDuration(0.5)
    fade:SetSmoothing("IN_OUT")
    local iconPulse = I2:CreateAnimationGroup()
    iconPulse:SetLooping("BOUNCE")
    local squeeze = iconPulse:CreateAnimation("Scale")
    if squeeze.SetScaleFrom then
        squeeze:SetScaleFrom(1, 1)
        squeeze:SetScaleTo(PULSE_SHRINK, PULSE_SHRINK)
    else
        squeeze:SetScale(PULSE_SHRINK, PULSE_SHRINK)
    end
    squeeze:SetDuration(0.5)
    squeeze:SetSmoothing("IN_OUT")
    return { B = B2, I = I2, tex = tex, cd = cd, GL = GL, glow = glow, pulse = pulse, iconPulse = iconPulse,
        fx = MakeFx(B2), mask = mask, RIM = RIM, rim = rim }
end

local function CreateIndicator()
    -- editing: its settings are open in the window. preview: selected in the list, so its
    -- placeholder is shown and can be dragged. Either one counts as "placing".
    local ind = { editing = false, preview = false, dragging = false }

    local A = CreateFrame("Frame", nil, UIParent)
    A:SetSize(64, 64)
    A:SetPoint("CENTER", UIParent, "CENTER", 0, 150)
    A:SetAlpha(0)
    A:SetMovable(true)
    A:SetClampedToScreen(true)
    A:RegisterForDrag("LeftButton")

    local C = CreateFrame("Frame", nil, A)
    C:SetAllPoints(A)
    C:SetAlpha(0)

    -- E: enemy (target) health driver, child of C
    local E = CreateFrame("Frame", nil, C)
    E:SetAllPoints(A)

    -- F: cooldown driver, child of E
    local F = CreateFrame("Frame", nil, E)
    F:SetAllPoints(A)

    -- G: charges driver, child of F
    local G = CreateFrame("Frame", nil, F)
    G:SetAllPoints(A)

    -- H: buff driver, child of G
    local H = CreateFrame("Frame", nil, G)
    H:SetAllPoints(A)

    -- J: "enemy is alive / dead" driver, child of H
    local J = CreateFrame("Frame", nil, H)
    J:SetAllPoints(A)

    -- M: "the ability is available" (not on cooldown), child of J
    local M = CreateFrame("Frame", nil, J)
    M:SetAllPoints(A)

    -- P: main resource driver, child of M
    local P = CreateFrame("Frame", nil, M)
    P:SetAllPoints(A)

    -- S: second resource driver (runes, holy power ...), child of P
    local S = CreateFrame("Frame", nil, P)
    S:SetAllPoints(A)

    -- K1..K3: "not while another aura shows" (up to three auras), children of S, parents of B
    local K1 = CreateFrame("Frame", nil, S)
    K1:SetAllPoints(A)
    local K2 = CreateFrame("Frame", nil, K1)
    K2:SetAllPoints(A)
    local K3 = CreateFrame("Frame", nil, K2)
    K3:SetAllPoints(A)
    ind.K = { K1, K2, K3 }

    local B = CreateFrame("Frame", nil, K3)
    B:SetAllPoints(A)

    -- I: holds the icon picture and its cooldown swipe, so the "pulse" effect can scale
    -- just the icon while the glow ring and the text stay put.
    local I = CreateFrame("Frame", nil, B)
    I:SetAllPoints(B)

    local tex = I:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints(I)

    local mask = I:CreateMaskTexture()
    mask:SetTexture(FX_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(I)
    local cd = CreateFrame("Cooldown", nil, I, "CooldownFrameTemplate")
    cd:SetAllPoints(I)
    local RIM = CreateFrame("Frame", nil, B)   -- the rim of a round icon, above the picture
    RIM:SetAllPoints(B)
    RIM:SetFrameLevel(I:GetFrameLevel() + 3)
    local rim = RIM:CreateTexture(nil, "ARTWORK")
    rim:SetPoint("CENTER", RIM, "CENTER")
    rim:Hide()

    -- Glow: a pulsing golden ring around the icon. It is part of B, so it appears and
    -- disappears together with the icon (no extra condition needed).
    -- GL: its own frame, so the ring can sit one strata above the icon (never behind it,
    -- whatever display priority the aura has).
    local GL = CreateFrame("Frame", nil, B)
    GL:SetAllPoints(B)
    ind.GL = GL
    local glow = GL:CreateTexture(nil, "OVERLAY")
    glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    glow:SetBlendMode("ADD")
    glow:SetVertexColor(1, 0.85, 0.3, 1)
    glow:SetPoint("CENTER", GL, "CENTER")
    glow:Hide()
    local pulse = glow:CreateAnimationGroup()
    pulse:SetLooping("BOUNCE")
    local fade = pulse:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0.25)
    fade:SetDuration(0.5)
    fade:SetSmoothing("IN_OUT")
    ind.glow, ind.pulse = glow, pulse

    -- Pulse: the icon shrinks and grows in the same rhythm as the glow (both bounce over 0.5 s)
    local iconPulse = I:CreateAnimationGroup()
    iconPulse:SetLooping("BOUNCE")
    local squeeze = iconPulse:CreateAnimation("Scale")
    if squeeze.SetScaleFrom then
        squeeze:SetScaleFrom(1, 1)
        squeeze:SetScaleTo(PULSE_SHRINK, PULSE_SHRINK)
    else
        squeeze:SetScale(PULSE_SHRINK, PULSE_SHRINK)
    end
    squeeze:SetDuration(0.5)
    squeeze:SetSmoothing("IN_OUT")
    ind.iconPulse = iconPulse

    -- R: the second path ("always show when empowered"). Not a child of A, so the conditions
    -- of A do not hold it back; it follows A's position and size.
    local R = CreateFrame("Frame", nil, UIParent)
    R:SetAllPoints(A)
    R:SetAlpha(0)
    ind.R = R
    ind.faces = {
        { B = B, I = I, tex = tex, cd = cd, GL = GL, glow = glow, pulse = pulse, iconPulse = iconPulse,
            fx = MakeFx(B), mask = mask, RIM = RIM, rim = rim },
        MakeExtraFace(R),
    }

    -- BAR: a progress bar that empties while our own timer runs (shape "bar"), part of B like the icon
    local BAR = CreateFrame("Frame", nil, B)
    BAR:SetAllPoints(B)
    BAR:Hide()
    BAR.track = CreateFrame("Frame", nil, BAR)
    BAR.track.bg = BAR.track:CreateTexture(nil, "BACKGROUND")
    BAR.track.bg:SetAllPoints()
    BAR.track.bg:SetColorTexture(0.05, 0.055, 0.075, 0.85)
    BAR.fill = BAR.track:CreateTexture(nil, "ARTWORK")
    BAR.fill:SetColorTexture(1, 0.56, 0.12, 1)
    BAR.time = BAR.track:CreateFontString(nil, "OVERLAY")
    BAR.time:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
    BAR.icon = BAR:CreateTexture(nil, "ARTWORK")
    BAR.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    ind.bar = BAR
    BAR:SetScript("OnUpdate", function(self)
        local cfg = ind.cfg
        if not cfg or cfg.shape ~= "bar" or cfg.kind == "counter" then return end
        local total = math.max(cfg.suppressSeconds or 10, 1)
        local fraction
        if ind.editing or ind.preview or ind.dragging then
            fraction = 1 - ((GetTime() % 4) / 4)   -- a sample that loops, to judge the direction and the look
        else
            local left = ind.suppressUntil and (ind.suppressUntil - GetTime()) or 0
            fraction = left > 0 and math.min(left / total, 1) or 0
            if fraction == 0 and cfg.trackShow ~= "while" then fraction = 1 end   -- shown when it is gone: a full bar
        end
        -- the seconds left, written on the bar (whole seconds)
        local shown = ""
        if cfg.barTimeOn ~= false and cfg.barTime ~= "none" and fraction > 0.001 then shown = tostring(math.ceil(fraction * total - 0.001)) end
        if shown ~= self.timeShown then
            self.timeShown = shown
            self.time:SetText(shown)
        end
        if fraction <= 0.001 then
            self.fill:Hide()
        else
            self.fill:SetWidth(math.max(1, (self.trackWidth or 1) * fraction))
            self.fill:Show()
        end
    end)

    -- COUNTER: three pieces of text (left, centre, right) with no frame and no background; they hold the item's picture, name
    -- and number (HeadsUp_UpdateCounter). Part of B like the icon.
    local CT = CreateFrame("Frame", nil, B)
    CT:SetAllPoints(B)
    CT:Hide()
    CT.panel = CT:CreateTexture(nil, "BACKGROUND")   -- the dark box of a counter that is a bar
    CT.panel:SetAllPoints()
    CT.panel:SetColorTexture(0.05, 0.055, 0.075, 0.85)
    CT.panel:Hide()
    CT.bg = CT:CreateTexture(nil, "BACKGROUND", nil, 1)   -- a faint box, only while the aura is placed, to show where it is
    CT.bg:SetAllPoints()
    CT.bg:SetColorTexture(1, 1, 1, 0.12)
    CT.bg:Hide()
    CT.icon = CT:CreateTexture(nil, "ARTWORK")   -- the picture at one end of a counter that is a bar (as high as the bar)
    CT.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    CT.icon:Hide()
    -- the name and the number: two pieces of text, placed by HeadsUp_UpdateCounter so that they never overlap
    CT.slot = {}
    for _, key in ipairs({ "name", "num" }) do
        local fs = CT:CreateFontString(nil, "OVERLAY")
        fs:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
        fs:SetWordWrap(false)
        fs:SetMaxLines(1)
        CT.slot[key] = fs
    end
    ind.CT = CT

    local hint = B:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("TOP", B, "BOTTOM", 0, -2)
    hint:SetJustifyH("CENTER")
    hint:SetText("Drag to move")
    hint:Hide()

    ind.A, ind.C, ind.E, ind.F, ind.tex, ind.cd, ind.hint = A, C, E, F, tex, cd, hint
    ind.I = I   -- the icon's own frame: its effective alpha tells whether the icon is visible
    ind.G, ind.H, ind.J = G, H, J
    ind.M, ind.P, ind.S = M, P, S
    ind.parts = { A, C, E, F, G, H, J, M, P, S, K1, K2, K3, B, I, cd, R, ind.faces[2].B, ind.faces[2].I, ind.faces[2].cd,
        ind.faces[1].fx, ind.faces[2].fx, ind.faces[1].fx.top, ind.faces[2].fx.top,
        ind.faces[1].RIM, ind.faces[2].RIM, BAR, BAR.track, CT }   -- every frame of the indicator (for the layer setting)

    A:SetScript("OnDragStart", function(self)
        if not (ind.editing or ind.preview) then return end
        ind.dragging = true
        -- a group of auras moves as one: the others follow the one that is dragged (same distance, same direction)
        if ind.groupMove then
            local startX, startY = self:GetCenter()
            local others = {}
            for _, other in ipairs(ind.groupMove) do
                if other ~= ind then
                    local ox, oy = other.A:GetCenter()
                    if ox then others[#others + 1] = { other, ox, oy } end
                end
            end
            self:SetScript("OnUpdate", function(frame)
                local cx, cy = frame:GetCenter()
                if not (cx and startX) then return end
                for _, o in ipairs(others) do
                    o[1].A:ClearAllPoints()
                    o[1].A:SetPoint("CENTER", UIParent, "BOTTOMLEFT", o[2] + cx - startX, o[3] + cy - startY)
                end
            end)
        end
        self:StartMoving()
    end)
    A:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        self:SetScript("OnUpdate", nil)
        ind.dragging = false
        if ind.cfg then
            -- saved as the distance of the icon's centre from the centre of the screen (X right, Y up)
            local cx, cy = self:GetCenter()
            local ux, uy = UIParent:GetCenter()
            if cx and ux then
                ind.cfg.pos = { "CENTER", "CENTER", math.floor(cx - ux + 0.5), math.floor(cy - uy + 0.5) }
            else
                local point, _, relPoint, x, y = self:GetPoint(1)
                ind.cfg.pos = { point, relPoint, x, y }
            end
            if HeadsUp_PositionChanged then HeadsUp_PositionChanged() end   -- the window shows the new X and Y
        end
        -- the others of a group stop where they were carried: their new places are saved too
        if ind.groupMove then
            local ux, uy = UIParent:GetCenter()
            for _, other in ipairs(ind.groupMove) do
                if other ~= ind and other.cfg and ux then
                    local cx, cy = other.A:GetCenter()
                    if cx then
                        local x, y = math.floor(cx - ux + 0.5), math.floor(cy - uy + 0.5)
                        other.cfg.pos = { "CENTER", "CENTER", x, y }
                        other.A:ClearAllPoints()
                        other.A:SetPoint("CENTER", UIParent, "CENTER", x, y)
                    end
                end
            end
            if HeadsUp_GroupCommit then HeadsUp_GroupCommit() end   -- a dragged place is kept
        end
        RefreshMouse(ind)
        Update(ind)
    end)

    return ind
end

function RefreshMouse(ind)
    ind.A:EnableMouse(ind.editing or ind.preview or ind.dragging)
end

local function ApplyPosition(ind)
    local cfg = ind.cfg
    ind.A:ClearAllPoints()
    if cfg and cfg.pos then
        ind.A:SetPoint(cfg.pos[1], UIParent, cfg.pos[2], cfg.pos[3], cfg.pos[4])
    else
        ind.A:SetPoint("CENTER", UIParent, "CENTER", 0, 150)
    end
end

local function UpdateCooldown(ind)
    local cfg = ind.cfg
    if not cfg or not cfg.spellID or cfg.kind == "counter" then return end
    local duration = C_Spell.GetSpellCooldownDuration(cfg.spellID)
    if duration then
        for _, face in ipairs(ind.faces) do
            face.cd:SetCooldownFromDurationObject(duration)
        end
    end
    -- for the cooldown condition: ignore the 1.5 s global cooldown (true = ignoreGCD)
    ind.cdDuration = C_Spell.GetSpellCooldownDuration(cfg.spellID, true)
    -- recharge of a charge-based ability: running = not all charges are ready
    ind.chargeDuration = C_Spell.GetSpellChargeDuration(cfg.spellID)
end

-- Do the ticked situations (combat, mount, vehicle) allow the aura to show right now?
-- Inside each pair, ticking only one restricts to it; ticking both or neither means "either".
-- The three pairs combine with AND. "always" ticked = no restriction at all.
local function ShowRulesAllow(cfg, ind)
    local rules = cfg.showRules
    if not cfg.showWhenEnabled or not rules then return true end
    if rules.always then return true end   -- "Always" ticked: no restriction at all

    local mounted = IsMounted() and true or false
    local inVehicle = (UnitInVehicle("player") or UnitHasVehicleUI("player")) and true or false

    local function pair(a, b, state)
        if rules[a] and not rules[b] then return state end
        if rules[b] and not rules[a] then return not state end
        return true
    end
    -- "keep showing after combat": for a while after combat ends it still counts as combat
    local combatNow = inCombat
    if not combatNow and cfg.lingerEnabled and ind and ind.lingerUntil and GetTime() < ind.lingerUntil then
        combatNow = true
    end
    -- the group and the place work as lists: any ticked one allows; none ticked = no restriction
    local groupOk = true
    if rules.solo or rules.inparty or rules.inraid then
        local group = IsInRaid() and "inraid" or (IsInGroup() and "inparty" or "solo")
        groupOk = rules[group] and true or false
    end
    local placeOk = true
    if rules.world or rules.dungeon or rules.raidinst or rules.delve or rules.pvp then
        local _, instanceType = IsInInstance()
        local place = ({ none = "world", party = "dungeon", raid = "raidinst", scenario = "delve",
                         pvp = "pvp", arena = "pvp" })[instanceType or "none"] or "world"
        placeOk = rules[place] and true or false
    end
    return pair("combat", "out", combatNow)
        and pair("mounted", "unmounted", mounted)
        and pair("vehicle", "novehicle", inVehicle)
        and pair("stealth", "nostealth", IsStealthed() and true or false)
        and groupOk and placeOk
end

-- The conditions about you (form) and your target (enemy / friendly, player / NPC, boss / rare / elite /
-- normal, alive / dead, attacking me) are all plain readable facts of the game, so they are checked here
-- with ordinary ifs. A reading the game hides counts as "not met". While "keep it after combat" runs, the
-- conditions about the target are ignored (the target is gone), like the enemy health.
local function TargetKinds()
    local ok, class = pcall(UnitClassification, "target")
    if not ok or class == nil or issecretvalue(class) then return nil end
    local okL, level = pcall(UnitLevel, "target")
    if class == "worldboss" or (okL and not issecretvalue(level) and level == -1) then
        return { boss = true }
    end
    if class == "rare" then return { rare = true } end
    if class == "rareelite" then return { rare = true, elite = true } end
    if class == "elite" then return { elite = true } end
    return { normal = true }
end

-- A debuff tracker lets its aura (the one it was made from) know when the effect has ended: while the
-- timer of such a tracker runs, the aura waits. It is our own clock, so it can be read in combat.
local function CueWaiting(cfg)
    if not cfg.uid then return false end
    for _, ind in pairs(pool) do
        local c = ind.cfg
        if c and c.trackerOf == cfg.uid and c.trackerCue and not c.hidden and c.suppressEnabled
            and ind.suppressUntil and GetTime() < ind.suppressUntil then
            return true
        end
    end
    return false
end

local function HasCue(cfg)
    if not cfg.uid then return false end
    for _, ind in pairs(pool) do
        local c = ind.cfg
        if c and c.trackerOf == cfg.uid and c.trackerCue then return true end
    end
    return false
end

-- How many enemies are around? Counted from the nameplates of the enemies, a few times a second (RefreshCrowd).
-- The test of 22 Oct 2026 (HeadsUpDB.crowdProbe) found it all readable in the open world. Where the game hides it
-- (dungeons, probably) crowd.ok stays false and the condition is ignored.
local crowd = { ok = false, fighting = 0, onMe = 0 }

local function RefreshCrowd()
    crowd.ok, crowd.fighting, crowd.onMe, crowd.why = false, 0, 0, ""
    if not (C_NamePlate and C_NamePlate.GetNamePlates) then crowd.why = "no nameplate api" return end
    local okP, plates = pcall(C_NamePlate.GetNamePlates)
    if not okP or type(plates) ~= "table" then crowd.why = "nameplates not readable" return end
    local fighting, onMe, known = 0, 0, 0
    for _, plate in ipairs(plates) do
        -- the unit of the nameplate: its token, or what the frame says (the same ways the test of 22 Oct 2026 used)
        local okU, unit = pcall(function()
            return plate.namePlateUnitToken or (plate.GetUnit and plate:GetUnit()) or (plate.UnitFrame and plate.UnitFrame.unit)
        end)
        if okU and unit ~= nil then
            if issecretvalue(unit) then crowd.why = "unit token hidden" return end
            known = known + 1
            local okA, canAttack = pcall(UnitCanAttack, "player", unit)
            if not okA or issecretvalue(canAttack) then crowd.why = "attackable hidden" return end
            if canAttack then
                local okD, dead = pcall(UnitIsDead, unit)
                if not (okD and not issecretvalue(dead) and dead) then
                    local okC, fightingNow = pcall(UnitAffectingCombat, unit)
                    if not okC or issecretvalue(fightingNow) then crowd.why = "combat state hidden" return end
                    if fightingNow then fighting = fighting + 1 end
                    local okT, threat = pcall(UnitThreatSituation, "player", unit)
                    if okT and not issecretvalue(threat) and threat and threat >= 2 then onMe = onMe + 1 end
                end
            end
        end
    end
    if #plates > 0 and known == 0 then crowd.why = "no unit on the nameplates" return end
    crowd.ok, crowd.fighting, crowd.onMe, crowd.why = true, fighting, onMe, "ok"
end

local function ReadableConditionsMet(cfg, lingering)
    if CueWaiting(cfg) then return false end
    if cfg.formEnabled then
        local form = GetShapeshiftForm() or 0
        local spell = 0
        if form > 0 then
            local _, _, _, id = GetShapeshiftFormInfo(form)
            spell = id or 0
        end
        if spell ~= (cfg.formSpell or 0) then return false end
    end
    if lingering then return true end
    -- how many enemies are around (needs no target)
    if cfg.crowdEnabled and crowd.ok then
        local n = (cfg.crowdMetric == "me") and crowd.onMe or crowd.fighting
        local met = Compare(n, cfg.crowdOp or ">=", cfg.crowdN or 2)
        if not met then return false end
    end
    if not (cfg.enemyAliveEnabled or cfg.tgtHostileEnabled or cfg.tgtTypeEnabled
        or cfg.tgtClassEnabled or cfg.threatEnabled) then
        return true
    end
    if not UnitExists("target") then return false end
    if cfg.tgtHostileEnabled then
        -- hostility: friend (cannot be attacked), neutral (can be attacked, reaction 4), enemy (the others)
        local kind = "friend"
        if UnitCanAttack("player", "target") then
            local okR, reaction = pcall(UnitReaction, "player", "target")
            kind = (okR and not issecretvalue(reaction) and reaction == 4) and "neutral" or "enemy"
        end
        if kind ~= (cfg.tgtHostile or "enemy") then return false end
    end
    if cfg.tgtTypeEnabled then
        local ok, isPlayer = pcall(UnitIsPlayer, "target")
        if not ok or issecretvalue(isPlayer) then return false end
        if (isPlayer and true or false) ~= (cfg.tgtType == "player") then return false end
    end
    if cfg.enemyAliveEnabled then
        local ok, dead = pcall(UnitIsDead, "target")
        if not ok or issecretvalue(dead) then return false end
        if (cfg.enemyAlive == "no") ~= (dead and true or false) then return false end
    end
    if cfg.tgtClassEnabled then
        local kinds = TargetKinds()
        local rules = cfg.tgtClass or {}
        local hit = false
        for kind in pairs(kinds or {}) do
            if rules[kind] then hit = true end
        end
        if not hit then return false end
    end
    if cfg.threatEnabled then
        local ok, status = pcall(UnitThreatSituation, "player", "target")
        if not ok or issecretvalue(status) then return false end
        local attacking = status ~= nil and status >= 2
        if (cfg.threatState ~= "no") ~= attacking then return false end
    end
    return true
end

-- Switch the "Empowered effect" of a face on or off. Turning it on plays the one-time flash of the
-- styles that have one (the moment it is empowered).
-- Does the ability have a cooldown of its own (or several charges)? These are fixed facts of the spell.
-- If the game does not tell us, we assume yes.
local function AbilityHasCooldown(spellID)
    local hasCooldown, maxCharges = true, 1
    local charges = C_Spell.GetSpellCharges(spellID)
    local most = charges and charges.maxCharges
    if most and not issecretvalue(most) and most > 1 then maxCharges = most end
    local baseCooldown = C_Spell.GetSpellBaseCooldown or GetSpellBaseCooldown
    if baseCooldown then
        local ok, ms = pcall(baseCooldown, spellID)
        if ok and type(ms) == "number" and not issecretvalue(ms) then
            hasCooldown = ms > 0 or maxCharges > 1
        end
    end
    return hasCooldown
end

-- Sound when the aura shows. The addon cannot know whether the icon is visible when it depends on values the game
-- hides in combat (health, the main resource, cooldown, charges, "available"). So the sound is only made
-- for conditions that can be read: the ability lighting up, the second resource, the enemy alive, the
-- "Show it only" rules. With "Ignore the other conditions" it sounds when the ability lights up.
-- ("The ability is available" can be read when the ability has no cooldown of its own: the game does
-- tell whether there is enough resource to use it. With a cooldown it cannot be known.)
local function HasHiddenCondition(cfg, ind)
    return cfg.healthEnabled or cfg.enemyEnabled or cfg.powerEnabled or cfg.cdEnabled or cfg.chargesEnabled
        or (cfg.availEnabled and ind.hasCooldown ~= false) or (cfg.otherAuras and cfg.otherAuras[1])
end

-- true: the aura shows now. false: it does not. nil: it cannot be known (no sound).
local function SoundConditionsMet(cfg, ind)
    local overrides = cfg.buffEnabled and cfg.buffAlways and cfg.buffState ~= "gone"
    local lit = false
    if cfg.buffEnabled then
        local okL, isLit = pcall(function()
            return C_SpellActivationOverlay.IsSpellOverlayed(cfg.spellID) and true or false
        end)
        lit = okL and isLit
    end
    -- "Ignore the resources": while it is lit the resource conditions do not count (the others do)
    local free = overrides and lit
    local hidden
    if free then
        hidden = cfg.healthEnabled or cfg.enemyEnabled or cfg.cdEnabled or cfg.chargesEnabled
            or (cfg.availEnabled and ind.hasCooldown ~= false)
    else
        hidden = HasHiddenCondition(cfg, ind)
    end
    if hidden then return nil end
    if not ShowRulesAllow(cfg, ind) then return false end
    if cfg.suppressEnabled then
        local running = ind.suppressUntil and GetTime() < ind.suppressUntil and true or false
        if running == (cfg.trackShow ~= "while") then return false end
    end
    if cfg.buffEnabled and not overrides and lit ~= (cfg.buffState ~= "gone") then return false end
    if cfg.availEnabled and not free then   -- (only here when the ability has no cooldown): enough resource to use it?
        local okU, usable = pcall(C_Spell.IsSpellUsable, cfg.spellID)
        if not okU or issecretvalue(usable) or not usable then return false end
    end
    local lingering = cfg.lingerEnabled and not inCombat and ind.lingerUntil and GetTime() < ind.lingerUntil
    if not ReadableConditionsMet(cfg, lingering) then return false end
    if cfg.secEnabled and ind.secType and not free then
        local count = SecondaryCount(ind.secType)
        if count == nil or not Compare(count, cfg.secOp, cfg.secValue or 1) then return false end
    end
    return true
end

-- plays the sound the moment the aura starts to show (not again and again while it shows)
local function UpdateSound(ind)
    local cfg = ind.cfg
    if not cfg or not cfg.soundEnabled or not cfg.spellID or cfg.class ~= playerClass or cfg.hidden
        or (cfg.specs and not cfg.specs[currentSpec]) or ind.editing or ind.preview or ind.dragging then
        ind.soundOn = nil
        return
    end
    local met = SoundConditionsMet(cfg, ind)
    if met == nil then
        ind.soundOn = nil
        return
    end
    if ind.soundOn == nil then   -- the first look (login, reload, closing the window): quiet
        ind.soundOn = met
        return
    end
    if met and not ind.soundOn then
        local now = GetTime()
        if not ind.lastSound or now - ind.lastSound > 0.5 then
            ind.lastSound = now
            HeadsUp_PlaySound(cfg.soundKey, cfg.soundVolume)
        end
    end
    ind.soundOn = met
end

local function SetFx(face, on)
    face.fx:SetAlpha(on and 1 or 0)
    if on and not face.fxOn then face.fx:Trigger() end
    face.fxOn = on and true or false
end

local function ResetFx(ind)
    ind.faces[1].fxOn = false
    ind.faces[2].fxOn = false
end

---------------------------------------------------------------------------
-- "Only if aura X is active / not active" (otherAuras = { { uid, state = "active" | "inactive" }, ... }, up to three)
--
-- Whether another aura X shows is not readable in combat (its icon depends on hidden values). But X shows when ALL of its
-- conditions hold. The readable conditions of X are checked directly. Each hidden condition of X is wired to a frame
-- (K1..K3, between the chain and the icon):
--   "active":     X's hidden conditions are multiplied into the chain (one frame each), so this aura shows only if all hold;
--   "not active": the OPPOSITE of X's single hidden condition (X does not show when ANY of its conditions fails). With
--                 several hidden conditions it would need an "or" of frames: not supported yet.
-- The three frames are shared by all the rows; a row that does not fit is ignored (the settings window says so).
---------------------------------------------------------------------------
local function FindIndicatorByUid(uid)
    for _, ind in pairs(pool) do
        local c = ind.cfg
        if c and c.uid == uid then return ind end
    end
    return nil
end

local function IsLingering(c, x)
    return (c.lingerEnabled and not inCombat and x.lingerUntil and GetTime() < x.lingerUntil) and true or false
end

-- Do all the READABLE conditions of the aura x hold right now? (false: it does not show, whatever the hidden ones say)
local function ReadablePartMet(c, x)
    if not c.spellID or c.class ~= playerClass or c.hidden then return false end
    if c.specs and not c.specs[currentSpec] then return false end
    if not ShowRulesAllow(c, x) then return false end
    if c.suppressEnabled then
        local running = x.suppressUntil and GetTime() < x.suppressUntil and true or false
        if running == (c.trackShow ~= "while") then return false end
    end
    local lingering = IsLingering(c, x)
    if c.buffEnabled then
        local ok, lit = pcall(function() return C_SpellActivationOverlay.IsSpellOverlayed(c.spellID) and true or false end)
        if ((ok and lit) and true or false) ~= (c.buffState ~= "gone") then return false end
    end
    if not ReadableConditionsMet(c, lingering) then return false end
    if c.enemyEnabled and not lingering then
        if not (UnitExists("target") and UnitCanAttack("player", "target")) then return false end
    end
    if c.secEnabled and x.secType then
        local count = SecondaryCount(x.secType)
        if not (count ~= nil and Compare(count, c.secOp, c.secValue or 1)) then return false end
    end
    if c.availEnabled and x.hasCooldown == false then   -- (no cooldown of its own: "usable" tells about the resource)
        local ok, usable = pcall(C_Spell.IsSpellUsable, c.spellID)
        if not ok or issecretvalue(usable) or not usable then return false end
    end
    return true
end

-- the hidden (secret) conditions of the aura x, as a list of names
local function SecretFactors(c, x)
    local list = {}
    if c.healthEnabled then list[#list + 1] = "health" end
    if c.enemyEnabled and not IsLingering(c, x) then list[#list + 1] = "enemy" end
    if c.cdEnabled and x.cdDuration then list[#list + 1] = "cd" end
    if c.chargesEnabled and (x.chargeDuration or x.cdDuration) then list[#list + 1] = "charges" end
    if c.powerEnabled and x.primaryType and x.primaryCurve then list[#list + 1] = "power" end
    if c.availEnabled and x.hasCooldown ~= false then   -- the cost and the cooldown
        if x.powerType then list[#list + 1] = "cost" end
        if x.cdDuration then list[#list + 1] = "available" end
    end
    return list
end

-- How many frames the row needs, or nil when it is not supported.
local function CrossNeeds(c, x, state)
    if c.buffAlways and c.buffEnabled and c.buffState ~= "gone" then return nil end
    local n = #SecretFactors(c, x)
    if state == "active" then return math.max(1, n) end
    if n > 1 then return nil end
    return 1
end

-- The settings window asks: how many of the three frames does a row for this aura need? nil = not supported
function HeadsUp_CrossNeeds(uid, state)
    local x = FindIndicatorByUid(uid)
    if not x or not x.cfg then return 0 end
    return CrossNeeds(x.cfg, x, state == "active" and "active" or "inactive")
end

-- the alpha of one hidden condition of X: 1 where it holds (positive) or where it does NOT hold (inverse)
local function FactorAlpha(name, x, inverse)
    local c = x.cfg
    if name == "health" then
        return UnitHealthPercent("player", true, inverse and x.healthInvCurve or x.healthCurve)
    elseif name == "enemy" then
        return UnitHealthPercent("target", true, inverse and x.enemyInvCurve or x.enemyCurve)
    elseif name == "power" then
        return UnitPowerPercent("player", x.primaryType, false, inverse and x.primaryInvCurve or x.primaryCurve)
    elseif name == "cost" then
        return UnitPowerPercent("player", x.powerType, false, inverse and x.powerInvCurve or x.powerCurve)
    elseif name == "cd" then
        return x.cdDuration:EvaluateRemainingDuration(inverse and x.cdInvCurve or x.cdCurve)
    elseif name == "available" then
        return x.cdDuration:EvaluateRemainingDuration(inverse and x.coolCurve or x.readyCurve)
    elseif name == "charges" then
        local source = (c.chargesState == "full") and x.chargeDuration or x.cdDuration
        if source then return source:EvaluateRemainingDuration(inverse and x.coolCurve or x.readyCurve) end
    end
    return 1
end

-- Sets the frames K[first ...] for one row; returns the next free frame.
local function ApplyCrossRow(ind, row, first)
    local x = FindIndicatorByUid(row.uid)
    if not x or not x.cfg then return first end   -- (deleted: ignored)
    local c = x.cfg
    local state = (row.state == "active") and "active" or "inactive"
    local needs = CrossNeeds(c, x, state)
    if not needs or first + needs - 1 > 3 then return first end   -- not supported: ignored
    local K = ind.K
    local readable = ReadablePartMet(c, x)
    local factors = SecretFactors(c, x)
    if state == "inactive" then
        local alpha = 1   -- (if its readable part fails it cannot show: nothing to wait for)
        if readable then alpha = (#factors == 0) and 0 or FactorAlpha(factors[1], x, true) end
        K[first]:SetAlpha(alpha)
    else
        for j = 1, needs do K[first + j - 1]:SetAlpha(1) end
        if not readable then
            K[first]:SetAlpha(0)   -- it cannot show now: "active" is not met
        else
            for j, name in ipairs(factors) do K[first + j - 1]:SetAlpha(FactorAlpha(name, x, false)) end
        end
    end
    return first + needs
end

local function UpdateVisual(ind)
    local cfg = ind.cfg
    local A, C, E, F, G, H, J = ind.A, ind.C, ind.E, ind.F, ind.G, ind.H, ind.J
    local M, P, S = ind.M, ind.P, ind.S
    local placingNow = ind.editing or ind.preview
    local notForMe
    if cfg and cfg.kind == "counter" then
        notForMe = not HeadsUp_CounterAllowed(cfg, placingNow)   -- (a counter may be for every character, or by profession)
    else
        notForMe = cfg and (cfg.class ~= playerClass or (cfg.specs and not cfg.specs[currentSpec] and not placingNow))
    end
    if not cfg or not cfg.spellID or notForMe
        or (cfg.hidden and not ind.editing and not ind.preview) then
        A:Hide()
        ind.R:Hide()
        ResetFx(ind)
        return
    end
    A:Show()
    ind.R:Show()
    if cfg.kind == "counter" then HeadsUp_UpdateCounter(ind) end
    local placing = ind.editing or ind.preview or ind.dragging
    ind.hint:SetShown(placing)
    if placing then
        -- the aura's name (gold) above the "Drag to move" line: tells identical-looking icons apart
        local info = not cfg.name and C_Spell.GetSpellInfo(cfg.spellID)
        ind.hint:SetText("|cffffd100" .. (cfg.name or (info and info.name) or "") .. "|r\nDrag to move")
        A:SetAlpha(1)
        C:SetAlpha(1)
        E:SetAlpha(1)
        F:SetAlpha(1)
        G:SetAlpha(1)
        H:SetAlpha(1)
        J:SetAlpha(1)
        M:SetAlpha(1)
        P:SetAlpha(1)
        S:SetAlpha(1)
        for _, k in ipairs(ind.K) do k:SetAlpha(1) end
        ind.R:SetAlpha(0)   -- the second path stays off while placing: one icon only
        -- show the chosen Empowered effect while editing, so it can be judged
        if ind.plain then
            -- placing a group: clean icons, no effects (ApplyConfig brings them back afterwards)
            SetFx(ind.faces[1], false)
            for _, face in ipairs(ind.faces) do
                face.glow:Hide()
                face.pulse:Stop()
                face.iconPulse:Stop()
            end
        else
            SetFx(ind.faces[1], cfg.buffEnabled and cfg.buffState ~= "gone" and true or false)
        end
        SetFx(ind.faces[2], false)
        return
    end
    -- the second path ("always show when empowered") starts off; it is turned on further down
    ind.R:SetAlpha(0)
    -- when the aura may show at all (combat state is known to addons, not a secret value)
    if not ShowRulesAllow(cfg, ind) then
        A:SetAlpha(0)
        ResetFx(ind)
        return
    end
    -- "after casting, hide for N seconds": our own clock, no secret value involved
    if cfg.suppressEnabled then
        local running = ind.suppressUntil and GetTime() < ind.suppressUntil and true or false
        -- "hide": hidden while it runs. "while": shown only while it runs (a bar that empties)
        if running == (cfg.trackShow ~= "while") then
            A:SetAlpha(0)
            ResetFx(ind)
            return
        end
    end
    local ok, err = pcall(function()
        -- "Ignore the resources" (Empowered + buffAlways): while the ability is lit up it costs nothing (or is stronger), so the
        -- conditions about resources (the cost, the main resource, the second resource) do not count. Every other
        -- condition (health, enemies, target, cooldown, charges...) still counts. The rows of "Combine with auras" (auras that compete for
        -- the same resources) are ignored too while it is free.
        local free = false
        if cfg.buffEnabled and cfg.buffAlways and cfg.buffState ~= "gone" and cfg.spellID then
            local okF, litF = pcall(function() return C_SpellActivationOverlay.IsSpellOverlayed(cfg.spellID) and true or false end)
            free = (okF and litF) and true or false
        end
        if cfg.healthEnabled then
            A:SetAlpha(UnitHealthPercent("player", true, ind.healthCurve))
        else
            A:SetAlpha(1)
        end
        if cfg.availEnabled and ind.powerType and not free then
            C:SetAlpha(UnitPowerPercent("player", ind.powerType, false, ind.powerCurve))
        else
            C:SetAlpha(1)
        end
        -- While "keep it after combat" is running, the conditions about the enemy are ignored:
        -- the target is gone (it just died) and we are walking to the next one.
        local lingering = cfg.lingerEnabled and not inCombat and ind.lingerUntil
            and GetTime() < ind.lingerUntil
        if cfg.enemyEnabled and not lingering then
            -- no hostile target selected -> the condition is simply not met
            if UnitExists("target") and UnitCanAttack("player", "target") then
                E:SetAlpha(UnitHealthPercent("target", true, ind.enemyCurve))
            else
                E:SetAlpha(0)
            end
        else
            E:SetAlpha(1)
        end
        if cfg.cdEnabled and ind.cdDuration then
            -- re-evaluated about 10x a second: a cooldown ending fires no event
            F:SetAlpha(ind.cdDuration:EvaluateRemainingDuration(ind.cdCurve))
        else
            F:SetAlpha(1)
        end
        -- "any": a charge is ready (the ability is not on cooldown); "full": nothing is recharging
        local chargeSource = (cfg.chargesState == "full") and ind.chargeDuration or ind.cdDuration
        if cfg.chargesEnabled and chargeSource then
            G:SetAlpha(chargeSource:EvaluateRemainingDuration(ind.readyCurve))
        else
            G:SetAlpha(1)
        end
        -- "Buff" (e.g. Dark Succor, which empowers Death Strike). The game hides the player's
        -- buffs from addons in combat, but it does show whether an ability is "lit up" (the
        -- yellow proc glow on its button). So this condition looks at the glow of THIS aura's
        -- ability. It does not matter which action bar the ability is on: the glow belongs to
        -- the ability itself. "active" = lit up, "gone" = not lit up.
        local glowSpell = cfg.spellID   -- always this aura's own ability
        -- "Ignore the other conditions" (buffAlways) only counts with "Empowered: active" ticked
        local overrides = cfg.buffEnabled and cfg.buffAlways and cfg.buffState ~= "gone"
        if cfg.buffEnabled and not overrides and glowSpell then
            local okL, lit = pcall(function()
                return C_SpellActivationOverlay.IsSpellOverlayed(glowSpell) and true or false
            end)
            if not okL then lit = false end
            local want = (cfg.buffState ~= "gone")
            H:SetAlpha((lit == want) and 1 or 0)
            -- the Empowered effect: only while the ability is lit up and "active" was chosen
            SetFx(ind.faces[1], lit and want and true or false)
            if HeadsUpDB then   -- log: lets us see how reliable the reading is, in and out of combat
                local key = (inCombat and "combat_" or "ooc_") .. (not okL and "blocked" or (lit and "lit" or "unlit"))
                local stats = HeadsUpDB.litStats or {}
                HeadsUpDB.litStats = stats
                stats[key] = (stats[key] or 0) + 1
            end
        else
            H:SetAlpha(1)
            SetFx(ind.faces[1], free)   -- (with "ignore the resources" the effect shows while it is lit)
        end
        -- (the second icon of the older "Ignore the other conditions" is not used any more)
        ind.R:SetAlpha(0)
        SetFx(ind.faces[2], false)
        -- "the enemy (my target) is alive / dead": needs a hostile target; none = not met
        J:SetAlpha(ReadableConditionsMet(cfg, lingering) and 1 or 0)
        -- "the ability is available": the cost part is the C frame above; here the cooldown part
        -- (the global cooldown is ignored, a charge left counts as available)
        if cfg.availEnabled and ind.cdDuration then
            M:SetAlpha(ind.cdDuration:EvaluateRemainingDuration(ind.readyCurve))
        else
            M:SetAlpha(1)
        end
        -- the main resource (runic power, mana, ...): a value wired to a display, never compared
        if cfg.powerEnabled and ind.primaryType and ind.primaryCurve and not free then
            P:SetAlpha(UnitPowerPercent("player", ind.primaryType, false, ind.primaryCurve))
        else
            P:SetAlpha(1)
        end
        -- the second resource (runes, holy power, ...): a plain number, so we can compare it
        if cfg.secEnabled and ind.secType and not free then
            local count = SecondaryCount(ind.secType)
            local met = count ~= nil and Compare(count, cfg.secOp, cfg.secValue or 1)
            S:SetAlpha(met and 1 or 0)
        else
            S:SetAlpha(1)
        end
        -- "only if another aura is active / not active": the frames K1..K3
        -- (these rows are about auras that compete for the same resources: while the ability is free they are ignored)
        local nextFrame = 1
        if not free then
            for _, row in ipairs(cfg.otherAuras or {}) do
                nextFrame = ApplyCrossRow(ind, row, nextFrame)
            end
        end
        for i = nextFrame, 3 do ind.K[i]:SetAlpha(1) end
    end)
    if not ok and not errorShown then
        errorShown = true
        LogError("HeadsUp Update: " .. tostring(err))
        print("|cffff8800HeadsUp:|r error: " .. tostring(err))
    end
end

function Update(ind)
    UpdateVisual(ind)
    UpdateSound(ind)
end

-- Rebuild everything that depends on the aura's settings.
-- the Empowered effect an aura really has: "auto" follows the specialization of the aura (the one it belongs
-- to, or else the one played now)
function HeadsUp_ResolveFx(cfg)
    local style = cfg.empowerFx
    if style == "auto" then
        local spec = currentSpec
        if cfg.specs then
            local only, count = nil, 0
            for id, on in pairs(cfg.specs) do
                if on then only, count = id, count + 1 end
            end
            if count == 1 then spec = only end
        end
        style = SPEC_FX[spec] or "sunburst"
    end
    return style
end

-- The counter: how many of an item are in the bags (not the bank), written as text. Every reading is counted in
-- HeadsUpDB.itemProbe (combat_readable / combat_secret ...), so the log file shows whether the game lets us read it in combat.
-- Each piece (picture, name, number) goes where the aura says; pieces in the same place go side by side.
function HeadsUp_UpdateCounter(ind)
    local cfg, CT = ind.cfg, ind.CT
    if not cfg or cfg.kind ~= "counter" or not CT then return end
    local id = HeadsUp_SubjectID(cfg)
    local count
    if id then
        local ok, n = pcall(HeadsUp_ReadCount, cfg)
        local kind = (not ok and "error") or (n == nil and "nil") or (issecretvalue(n) and "secret") or "readable"
        if HeadsUpDB then
            local stats = HeadsUpDB.itemProbe or {}
            HeadsUpDB.itemProbe = stats
            local key = (inCombat and "combat_" or "ooc_") .. kind
            stats[key] = (stats[key] or 0) + 1
        end
        if kind == "readable" then count = n end
    end
    local size = ind.ctSize or 12
    local shape = ind.counterShape or "text"
    -- the number is written as the game writes it (20,224): with a separator between the thousands
    local number = "0"
    if count then
        local okF, text = pcall(BreakUpLargeNumbers, count)
        number = okF and text or tostring(count)
    elseif id then
        number = "?"
    end
    local numFs, nameFs = CT.slot.num, CT.slot.name
    numFs:SetText(number)
    nameFs:SetText("")
    CT.icon:Hide()
    if shape ~= "bar" then
        -- text and icon: only the number, in the middle
        numFs:ClearAllPoints()
        numFs:SetPoint("CENTER", CT, "CENTER", 0, 0)
        numFs:SetJustifyH("CENTER")
    else
        -- A bar: the picture at one end (as high as the bar, a pixel less), then the name and the number where they are put.
        -- Nothing may overlap: the room that is left is measured, and a name that is too long is cut short (with "...").
        local W, height = cfg.width or 200, cfg.height or 24
        local padLeft, padRight = 2, 2
        local iconAt = (cfg.ctIcon == "right") and "right" or ((cfg.ctIcon ~= "off") and "left" or nil)
        if iconAt and id then
            local _, picture = HeadsUp_SubjectFacts(cfg)
            if picture then
                local px = math.max(8, height - 1)
                CT.icon:SetTexture(picture)
                CT.icon:SetSize(px, px)
                CT.icon:ClearAllPoints()
                CT.icon:SetPoint(iconAt == "left" and "LEFT" or "RIGHT", CT, iconAt == "left" and "LEFT" or "RIGHT",
                    iconAt == "left" and 1 or -1, 0)
                CT.icon:Show()
                if iconAt == "left" then padLeft = px + 6 else padRight = px + 6 end
            end
        end
        local gap = 6
        local avail = W - padLeft - padRight
        local center = padLeft + avail / 2               -- (the middle of what is left, measured from the left edge)
        local numAt = (cfg.ctNum == "left" or cfg.ctNum == "center") and cfg.ctNum or "right"
        local wu = numFs:GetStringWidth() or 0
        -- where a piece of text of this width starts (measured from the left edge of the bar), for the place it is put
        local function startOf(at, width)
            if at == "left" then return padLeft end
            if at == "right" then return W - padRight - width end
            return center - width / 2
        end
        local nameAt = cfg.ctName
        local wn, wnMax = 0, 0
        if nameAt and nameAt ~= "off" then
            -- the name that was typed for the aura (by default the real name of the item)
            local name = cfg.name
            if not name or name == "" then name = HeadsUp_SubjectFacts(cfg) end
            nameFs:SetWidth(0)
            nameFs:SetText(name or (id and ("Item " .. id)) or "Item")
            wn = nameFs:GetStringWidth() or 0
            -- how wide the name may be: it must stay clear of the number (and keep a gap)
            if nameAt == numAt then
                wnMax = avail - wu - gap
            elseif nameAt == "left" then
                wnMax = (numAt == "right") and (avail - wu - gap) or ((center - wu / 2) - padLeft - gap)
            elseif nameAt == "right" then
                wnMax = (numAt == "left") and (avail - wu - gap) or ((W - padRight) - (center + wu / 2) - gap)
            else   -- the name is centred: it grows on both sides, so the nearer limit counts
                if numAt == "right" then
                    wnMax = 2 * ((W - padRight - wu - gap) - center)
                else
                    wnMax = 2 * (center - (padLeft + wu + gap))
                end
            end
            wnMax = math.max(0, math.floor(wnMax))
            if wnMax < wn then wn = wnMax end
            if wn < 4 then
                nameFs:SetText("")   -- no room at all: only the number is written
                wn = 0
            else
                nameFs:SetWidth(wn)
            end
        end
        -- the places: the number, and the name next to it when they share the same place
        local numStart, nameStart
        if wn > 0 and nameAt == numAt then
            local total = wn + gap + wu
            if nameAt == "left" then
                nameStart = padLeft
            elseif nameAt == "right" then
                nameStart = W - padRight - total
            else
                nameStart = center - total / 2
            end
            numStart = nameStart + wn + gap
        else
            numStart = startOf(numAt, wu)
            nameStart = startOf(nameAt, wn)
        end
        numFs:ClearAllPoints()
        numFs:SetPoint("LEFT", CT, "LEFT", numStart, 0)
        numFs:SetJustifyH("LEFT")
        nameFs:ClearAllPoints()
        nameFs:SetPoint("LEFT", CT, "LEFT", nameStart, 0)
        nameFs:SetJustifyH("LEFT")
    end
    if shape == "text" then
        -- text only: the box is as wide as the number and as high as the letters (a little more), nothing to set by hand
        local w = math.max(8, math.ceil(numFs:GetStringWidth() or 0) + 4)
        local h = size + 4
        if math.abs(ind.A:GetWidth() - w) > 0.5 or math.abs(ind.A:GetHeight() - h) > 0.5 then ind.A:SetSize(w, h) end
    end
    -- a faint box while the aura is placed, so that letters without a frame can be found (a bar and an icon show themselves)
    CT.bg:SetShown(shape == "text" and not ind.CT.hasBg and (ind.editing or ind.preview or ind.dragging) and true or false)
end

-- the progress bar: where the track, the fill and the small icon sit
local function ApplyBar(ind, cfg, width, height)
    local bar = ind.bar
    if cfg.shape ~= "bar" or cfg.kind == "counter" then   -- (the bar of a counter is made by its own text, see HeadsUp_UpdateCounter)
        bar:Hide()
        return
    end
    bar:Show()
    local side = (cfg.barIconOn ~= false) and cfg.barIcon or "none"
    if side ~= "left" and side ~= "right" then side = "none" end
    local iconW = (side == "none") and 0 or height
    local gap = (side == "none") and 0 or 2
    local left = (side == "left") and (iconW + gap) or 0
    local right = (side == "right") and (iconW + gap) or 0
    bar.track:ClearAllPoints()
    bar.track:SetPoint("TOPLEFT", bar, "TOPLEFT", left, 0)
    bar.track:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -right, 0)
    bar.trackWidth = math.max(1, width - left - right - 2)
    local color = cfg.barColor or { 1, 0.56, 0.12 }
    bar.fill:SetColorTexture(color[1], color[2], color[3], 1)
    -- the seconds: at the left end, in the middle or at the right end of the bar
    bar.time:SetFont(STANDARD_TEXT_FONT, math.max(9, math.min(16, height - 8)), "OUTLINE")
    bar.time:ClearAllPoints()
    local timeAt = cfg.barTime or "right"
    if timeAt == "left" then
        bar.time:SetPoint("LEFT", bar.track, "LEFT", 4, 0)
    elseif timeAt == "center" then
        bar.time:SetPoint("CENTER", bar.track, "CENTER", 0, 0)
    else
        bar.time:SetPoint("RIGHT", bar.track, "RIGHT", -4, 0)
    end
    bar.timeShown = nil
    local anchor = (cfg.barDrain == "right") and "RIGHT" or "LEFT"
    bar.fill:ClearAllPoints()
    bar.fill:SetPoint(anchor, bar.track, anchor, (anchor == "LEFT") and 1 or -1, 0)
    bar.fill:SetHeight(math.max(1, height - 2))
    bar.icon:ClearAllPoints()
    if side == "none" then
        bar.icon:Hide()
    else
        bar.icon:SetPoint(side == "left" and "LEFT" or "RIGHT", bar, side == "left" and "LEFT" or "RIGHT", 0, 0)
        bar.icon:SetSize(iconW, height)
        bar.icon:Show()
    end
end

-- the name of a spell (nil if unknown)
local function SpellNameOf(spellID)
    local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
    return ok and info and info.name or nil
end

-- Does casting the spell with this name also start the timer of this aura? Some abilities put the same effect
-- on the enemy as another one (Divine Toll casts Judgment): KnownDurations.lua lists them.
local function AlsoStartedBy(cfg, castName)
    if not castName or not cfg.spellID or not HeadsUpAlsoStartedBy then return false end
    local byClass = HeadsUpAlsoStartedBy[playerClass]
    local own = SpellNameOf(cfg.spellID)
    local others = byClass and own and byClass[own]
    if not others then return false end
    for _, name in ipairs(others) do
        if name == castName then return true end
    end
    return false
end

local function ApplyConfig(ind)
    local cfg = ind.cfg
    if not cfg then
        ind.A:Hide()
        ind.R:Hide()
        return
    end
    local width, height = cfg.width, cfg.height
    local big = math.max(width, height)   -- rings and effects are round: they follow the longer side
    local round = cfg.shape == "round"
    if round then width, height = big, big end   -- a circle: as wide as high
    ind.A:SetSize(width, height)
    ApplyPosition(ind)
    local effect = cfg.effect or "none"
    local strata = STRATA[cfg.layer] or STRATA[3]
    -- the look of the effect: "auto" follows the specialization of the aura (the one it belongs to, else the one played now)
    local fxStyle = HeadsUp_ResolveFx(cfg)
    for _, face in ipairs(ind.faces) do   -- the main icon and the "always when empowered" one look the same
        -- the shape: a round icon is the picture cut to a circle, a round cooldown, a rim of the style of the effect
        if round then
            face.tex:AddMaskTexture(face.mask)
            face.cd:SetUseCircularEdge(true)
            face.cd:SetSwipeTexture(FX_MASK)
            face.rim:SetTexture(RIM_BY_STYLE[fxStyle] or RIM_GOLD)
            face.rim:SetSize(big * 1.3, big * 1.3)
            face.rim:Show()
            face.glow:SetTexture(FX_RINGGLOW)
        else
            face.tex:RemoveMaskTexture(face.mask)
            face.cd:SetUseCircularEdge(false)
            face.cd:SetSwipeTexture(FX_WHITE)
            face.rim:Hide()
            face.glow:SetTexture(FX_RING)
        end
        -- glow ring (the artwork of the square one is about 1.75x the size of the icon it surrounds)
        local ringSize = round and 1.5 or 1.75
        face.glow:SetSize(big * ringSize, big * ringSize)
        if effect == "none" then
            face.pulse:Stop()
            face.iconPulse:Stop()
            face.glow:Hide()
        else
            face.glow:Show()
            if ind.effectApplied ~= effect then
                -- effect changed: restart both animations together so they stay in step
                face.pulse:Stop()
                face.iconPulse:Stop()
            end
            if not face.pulse:IsPlaying() then face.pulse:Play() end
            if effect == "pulse" then
                if not face.iconPulse:IsPlaying() then face.iconPulse:Play() end
            else
                face.iconPulse:Stop()
            end
        end
        face.GL:SetFrameStrata(EFFECT_STRATA[cfg.layer] or EFFECT_STRATA[3])
    end
    ind.effectApplied = effect
    -- a progress bar replaces the picture; no rim, ring or pulse around it
    local isCounter = cfg.kind == "counter"
    -- a counter is: "text" (letters only), "icon" (the item's picture with the number on it, square or round) or "bar"
    -- (a long box with the picture, the name and the number written in it); only an icon has the picture frame
    local counterShape = isCounter and ((cfg.shape == "square" or cfg.shape == "round") and "icon"
        or (cfg.shape == "bar" and "bar" or "text")) or nil
    local isBar = cfg.shape == "bar" and not isCounter
    for _, face in ipairs(ind.faces) do
        face.I:SetShown(not isBar and (not isCounter or counterShape == "icon"))
        if isBar or isCounter then
            face.rim:Hide()
            face.glow:Hide()
            face.pulse:Stop()
            face.iconPulse:Stop()
        end
    end
    ApplyBar(ind, cfg, width, height)
    -- a counter: the size of the letters and their colour are the chosen ones
    ind.CT:SetShown(isCounter)
    if isCounter then
        local size = math.max(8, math.min(64, math.floor(cfg.ctSize or 12)))
        ind.ctSize = size
        ind.counterShape = counterShape
        local color = cfg.ctColor or { 1, 1, 1 }
        for _, fs in pairs(ind.CT.slot) do
            fs:SetFont(STANDARD_TEXT_FONT, size, "OUTLINE")
            fs:SetTextColor(color[1], color[2], color[3], 1)
        end
        local bg = cfg.ctBg or { 0, 0, 0 }
        local bgAlpha = (cfg.ctBgAlpha or 20) / 100
        ind.CT.panel:SetColorTexture(bg[1], bg[2], bg[3], bgAlpha)
        ind.CT.panel:SetShown(counterShape ~= "icon" and bgAlpha > 0)   -- (an icon has no box behind it)
        ind.CT.hasBg = bgAlpha > 0
        if counterShape == "icon" then
            -- the picture of the item, cut to fit (like an ability's picture)
            local picture = select(2, HeadsUp_SubjectFacts(cfg)) or cfg.icon
            local left, right, top, bottom = 0, 1, 0, 1
            if width > height then
                top = (1 - height / width) / 2
                bottom = 1 - top
            elseif height > width then
                left = (1 - width / height) / 2
                right = 1 - left
            end
            for _, face in ipairs(ind.faces) do
                face.tex:SetTexture(picture)
                face.tex:SetTexCoord(left, right, top, bottom)
            end
        end
        HeadsUp_UpdateCounter(ind)
    end
    -- display priority: a higher layer is drawn above the lower ones
    for _, part in ipairs(ind.parts) do part:SetFrameStrata(strata) end
    for _, face in ipairs(ind.faces) do
        face.GL:SetFrameStrata(EFFECT_STRATA[cfg.layer] or EFFECT_STRATA[3])
    end
    ind.healthCurve = MakeHealthCurve(cfg.healthOp, cfg.healthPct / 100)
    -- the opposite curves: another aura that waits for this one not to show uses them
    ind.healthInvCurve = MakeHealthCurve(cfg.healthOp, cfg.healthPct / 100, true)
    ind.enemyInvCurve = MakeHealthCurve(cfg.enemyOp, cfg.enemyPct / 100, true)
    ind.cdInvCurve = MakeCooldownCurve(cfg.cdState == "ready" and "cooling" or "ready")
    ind.coolCurve = MakeCooldownCurve("cooling")
    ind.enemyCurve = MakeHealthCurve(cfg.enemyOp, cfg.enemyPct / 100)
    ind.cdCurve = MakeCooldownCurve(cfg.cdState)
    ind.readyCurve = MakeCooldownCurve("ready")

    -- the player's resources: the main one is read through a curve, the second one as a number
    ind.primaryType, ind.primaryCurve, ind.primaryInvCurve, ind.secType = nil, nil, nil, nil
    local resources = GetResources()
    if resources.primary then
        local primary = resources.primary
        local fraction = primary.percent and (cfg.powerValue / 100) or (cfg.powerValue / primary.max)
        ind.primaryType = primary.type
        ind.primaryCurve = MakeHealthCurve(cfg.powerOp, math.min(math.max(fraction, 0), 1))
        ind.primaryInvCurve = MakeHealthCurve(cfg.powerOp, math.min(math.max(fraction, 0), 1), true)
    end
    if resources.secondary then
        ind.secType = resources.secondary.type
    end

    if cfg.spellID and cfg.kind ~= "counter" then
        ind.hasCooldown = AbilityHasCooldown(cfg.spellID)   -- (false must stay false)
    else
        ind.hasCooldown = nil
    end

    ind.powerType = nil
    if cfg.spellID and cfg.kind ~= "counter" then
        local picture = cfg.icon or C_Spell.GetSpellTexture(cfg.spellID)
        -- a picture that is not square is cut, not stretched: the middle of it is shown
        local left, right, top, bottom = 0, 1, 0, 1
        if width > height then
            top = (1 - height / width) / 2
            bottom = 1 - top
        elseif height > width then
            left = (1 - width / height) / 2
            right = 1 - left
        end
        for _, face in ipairs(ind.faces) do
            face.tex:SetTexture(picture)
            face.tex:SetTexCoord(left, right, top, bottom)
        end
        ind.bar.icon:SetTexture(picture)
        for _, face in ipairs(ind.faces) do
            face.fx:Apply(fxStyle, big, width, height, round, cfg.empowerLight == "off")
            face.fx:SetRound(round)
        end
        ResetFx(ind)
        local costs = C_Spell.GetSpellPowerCost(cfg.spellID)
        if costs then
            for _, info in ipairs(costs) do
                local cost = info.cost
                if cost and not issecretvalue(cost) and cost > 0 then
                    local max = UnitPowerMax("player", info.type)
                    if max and not issecretvalue(max) and max > 0 then
                        ind.powerType = info.type
                        ind.powerCurve = MakeStepCurve(math.min(cost / max, 1), 0, 1)
                        ind.powerInvCurve = MakeStepCurve(math.min(cost / max, 1), 1, 0)
                        break
                    end
                end
            end
        end
    end
    UpdateCooldown(ind)
    Update(ind)
end

local spare = {}   -- indicators freed by deleting an aura

local function GetPooled(i)
    if not pool[i] then pool[i] = table.remove(spare) or CreateIndicator() end
    return pool[i]
end

local function ForEachIndicator(fn)
    for _, ind in pairs(pool) do fn(ind) end
    if newInd then fn(newInd) end
end

---------------------------------------------------------------------------
-- API used by the settings window
---------------------------------------------------------------------------

function HeadsUp_GetAuras() return auras end

-- An item from what the player typed or dragged: an item id, an item link, or a name (a name works only for an item the
-- game already knows, like one in the bags). Returns the item id, or nil.
function HeadsUp_ResolveItem(text)
    text = strtrim(tostring(text or ""))
    if text == "" then return nil end
    local ok, id = pcall(C_Item.GetItemInfoInstant, tonumber(text) or text)
    if ok and id then return id end
    return nil
end

-- Who sees a counter, and who has it in the list. The character is known by its name and realm.
function HeadsUp_CharKey()
    return (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?")
end

-- The professions an item belongs to, from its kind in the game (trade goods): { [skillLine] = "Name" }, or nil when
-- the kind says nothing (then the choice "by profession" is not offered). Cloth is Tailoring, leather is Skinning or Leatherworking,
-- ore and stone is Mining, herbs are Herbalism, fish and meat are Fishing or Cooking.
local PROFESSION_BY_SUBCLASS = {
    [5] = { [197] = "Tailoring" },
    [6] = { [393] = "Skinning", [165] = "Leatherworking" },
    [7] = { [186] = "Mining" },
    [9] = { [182] = "Herbalism" },
    [8] = { [356] = "Fishing", [185] = "Cooking" },
}
function HeadsUp_ItemProfessions(itemID)
    if not itemID then return nil end
    local ok, _, _, _, _, _, classID, subclassID = pcall(C_Item.GetItemInfoInstant, itemID)
    if ok and classID == 7 then return PROFESSION_BY_SUBCLASS[subclassID] end
    return nil
end

local function HasProfession(lines)
    local ok, list = pcall(function() return { GetProfessions() } end)
    if not ok then return false end
    for i = 1, 5 do
        local index = list[i]
        if index then
            local okI, _, _, _, _, _, _, skillLine = pcall(GetProfessionInfo, index)
            if okI and skillLine and lines[skillLine] then return true end
        end
    end
    return false
end

-- may this character show the counter? (placing: while it is being placed it shows for every choice but another class)
function HeadsUp_CounterAllowed(cfg, placing)
    local who = cfg.ctWho or "spec"
    if who == "all" then return true end
    if who == "char" then return cfg.ctChar == nil or cfg.ctChar == HeadsUp_CharKey() end
    if who == "prof" then
        local lines = HeadsUp_ItemProfessions(cfg.itemID)
        return placing or lines == nil or HasProfession(lines)
    end
    return cfg.class == playerClass and (placing or not cfg.specs or cfg.specs[currentSpec] and true or false)
end

-- is the aura in the list of this character? (an ability: of its class; a counter: by who it is for)
function HeadsUp_AuraListed(a)
    if a.kind == "counter" then
        local who = a.ctWho or "spec"
        if who == "all" or who == "prof" then return true end
        if who == "char" then return a.ctChar == nil or a.ctChar == HeadsUp_CharKey() end
    end
    return a.class == playerClass
end

-- What a counter counts: its id (an item or a currency), how many there are, and its name and picture.
function HeadsUp_SubjectID(cfg)
    if cfg.ctType == "currency" then return cfg.currencyID end
    return cfg.itemID
end

function HeadsUp_ReadCount(cfg)
    if cfg.ctType == "currency" then
        local info = C_CurrencyInfo.GetCurrencyInfo(cfg.currencyID)
        return info and info.quantity
    end
    -- an item: the bags, and with ctBank also the bank and the reagent bank
    local bank = cfg.ctBank and true or false
    return C_Item.GetItemCount(cfg.itemID, bank, false, bank, false)
end

-- name, picture (nil for what is not known yet: the name of an item arrives a moment after the first request)
function HeadsUp_SubjectFacts(cfg)
    if cfg.ctType == "currency" then
        local info = cfg.currencyID and C_CurrencyInfo.GetCurrencyInfo(cfg.currencyID)
        return info and info.name, info and info.iconFileID
    end
    return HeadsUp_ItemFacts(cfg.itemID)
end

-- Every currency of the character: { { id, name, icon, quantity }, ... } sorted by name. The list of the currency window has
-- collapsed headers: they are opened for a moment and closed again, so the window looks as it did.
function HeadsUp_ListCurrencies()
    local out = {}
    pcall(function()
        local opened = {}
        local i = 1
        while i <= C_CurrencyInfo.GetCurrencyListSize() do
            local info = C_CurrencyInfo.GetCurrencyListInfo(i)
            if info and info.isHeader and not info.isHeaderExpanded then
                C_CurrencyInfo.ExpandCurrencyList(i, true)
                opened[info.name] = true
            end
            i = i + 1
        end
        local seen = {}
        for j = 1, C_CurrencyInfo.GetCurrencyListSize() do
            local info = C_CurrencyInfo.GetCurrencyListInfo(j)
            if info and not info.isHeader then
                local link = C_CurrencyInfo.GetCurrencyListLink(j)
                local id = link and tonumber(link:match("currency:(%d+)"))
                if id and not seen[id] then
                    seen[id] = true
                    out[#out + 1] = { id = id, name = info.name, icon = info.iconFileID, quantity = info.quantity }
                end
            end
        end
        for j = C_CurrencyInfo.GetCurrencyListSize(), 1, -1 do   -- close again what was opened (from the end: the places do not move)
            local info = C_CurrencyInfo.GetCurrencyListInfo(j)
            if info and info.isHeader and opened[info.name] then
                C_CurrencyInfo.ExpandCurrencyList(j, false)
            end
        end
    end)
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- What the player typed, pasted (a link) or dropped: an item or a currency. Returns "item" or "currency", and the id; nil if it
-- is not known. A name is looked for among the items the game knows, then among the currencies of the character.
function HeadsUp_ResolveSubject(text)
    text = strtrim(tostring(text or ""))
    if text == "" then return nil end
    local cid = text:match("currency:(%d+)")
    if cid then return "currency", tonumber(cid) end
    local iid = text:match("item:(%d+)")
    if iid then return "item", tonumber(iid) end
    local function currencyName(id)
        local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, id)
        return ok and info and info.name and info.name ~= "" and info.name or nil
    end
    local n = tonumber(text)
    if n then
        -- (the ids of currencies are small numbers: a small id that is a currency is taken as one)
        if n < 10000 and currencyName(n) then return "currency", n end
        local id = HeadsUp_ResolveItem(text)
        if id then return "item", id end
        if currencyName(n) then return "currency", n end
        return nil
    end
    local id = HeadsUp_ResolveItem(text)
    if id then return "item", id end
    local wanted = text:lower()
    local partial
    for _, c in ipairs(HeadsUp_ListCurrencies()) do
        local name = c.name:lower()
        if name == wanted then return "currency", c.id end
        if not partial and name:find(wanted, 1, true) then partial = c.id end
    end
    if partial then return "currency", partial end
    return nil
end

-- the name and the picture of an item: nil for what is not known yet (the name arrives a moment after the first request)
function HeadsUp_ItemFacts(id)
    if not id then return nil, nil end
    local name = C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
    if not name then C_Item.RequestLoadItemDataByID(id) end
    return name, C_Item.GetItemIconByID(id)
end

-- Abilities seen lighting up for the current class + specialization: { [spellID] = times seen }
function HeadsUp_GetLearned()
    local learned = HeadsUpDB and HeadsUpDB.learned
    local forClass = learned and learned[playerClass]
    return (forClass and currentSpec and forClass[currentSpec]) or {}
end
function HeadsUp_GetPlayerClass() return playerClass end
function HeadsUp_GetResources() return GetResources() end
function HeadsUp_GetDraft() return draft end
function HeadsUp_GetEditIndex() return editIndex end

local function SpellName(spellID)
    local info = spellID and C_Spell.GetSpellInfo(spellID)
    return info and info.name
end

-- No two saved auras may share a name: "Death Strike", "Death Strike 2", "Death Strike 3"...
local function UniqueName(name, exceptIndex)
    local function taken(n)
        for i, a in ipairs(auras) do
            local other = a.name or SpellName(a.spellID)
            if i ~= exceptIndex and other and other:lower() == n:lower() then return true end
        end
        return false
    end
    if not taken(name) then return name end
    local base = name:gsub("%s+%d+$", "")
    local n = 2
    while taken(base .. " " .. n) do n = n + 1 end
    return base .. " " .. n
end

function HeadsUp_UniqueName(name, exceptIndex)
    return UniqueName(name, exceptIndex)
end

-- Give every saved aura a name and fix duplicates (the first one keeps its name).
local function NormalizeNames()
    local seen = {}
    for _, a in ipairs(auras) do
        local name = a.name or SpellName(a.spellID)
        if name then
            local base = name:gsub("%s+%d+$", "")
            local final, n = name, 2
            while seen[final:lower()] do
                final = base .. " " .. n
                n = n + 1
            end
            seen[final:lower()] = true
            a.name = final
        end
    end
end

-- Rename a saved aura right away (also updates the draft if it is being edited).
function HeadsUp_RenameAura(index, name)
    if not auras[index] then return end
    if not name or name == "" then name = SpellName(auras[index].spellID) or "Aura" end
    name = UniqueName(name, index)
    auras[index].name = name
    if editIndex == index and draft then draft.name = name end
end

-- True when the draft has changes that were not saved yet. For a brand-new aura that means
-- an ability was already chosen; for an existing one, any setting differs from the saved copy.
function HeadsUp_IsDirty()
    if not draft then return false end
    if not editIndex then return draft.spellID ~= nil end
    local saved = auras[editIndex]
    if not saved then return false end
    for _, k in ipairs(KEYS) do
        if k == "pos" then
            local a, b = draft.pos, saved.pos
            if (a == nil) ~= (b == nil) then return true end
            if a then
                for i = 1, 4 do
                    if a[i] ~= b[i] then return true end
                end
            end
        elseif k == "specs" then
            local a, b = draft.specs, saved.specs
            if (a == nil) ~= (b == nil) then return true end
            if a then
                for id, on in pairs(a) do
                    if (b[id] and true or false) ~= (on and true or false) then return true end
                end
                for id, on in pairs(b) do
                    if (a[id] and true or false) ~= (on and true or false) then return true end
                end
            end
        elseif k == "otherAuras" then
            local a, b = draft.otherAuras or {}, saved.otherAuras or {}
            if #a ~= #b then return true end
            for i = 1, #a do
                if a[i].uid ~= b[i].uid or a[i].state ~= b[i].state then return true end
            end
        elseif k == "barColor" or k == "ctColor" or k == "ctBg" then
            local a, b = draft[k] or {}, saved[k] or {}
            for i = 1, 3 do
                if a[i] ~= b[i] then return true end
            end
        elseif k == "showRules" or k == "tgtClass" then
            local a, b = draft[k] or {}, saved[k] or {}
            for rule, on in pairs(a) do
                if (b[rule] and true or false) ~= (on and true or false) then return true end
            end
            for rule, on in pairs(b) do
                if (a[rule] and true or false) ~= (on and true or false) then return true end
            end
        elseif k == "name" then
            if (draft.name or "") ~= (saved.name or SpellName(saved.spellID) or "") then return true end
        elseif draft[k] ~= saved[k] then
            return true
        end
    end
    return false
end

-- Snapshot of every aura's live state, for the log file (what the add-on sees right now).
function HeadsUp_DebugState()
    local out = {}
    local function Safe(fn, ...)
        local ok, v = pcall(fn, ...)
        if not ok then return "err" end
        if issecretvalue(v) then return "secret" end
        if type(v) == "number" then return string.format("%.2f", v) end
        return tostring(v)
    end
    local function Alpha(f) return Safe(f.GetAlpha, f) end
    local function YesNo(v) return v and "yes" or "no" end

    local target = "none"
    if UnitExists("target") then target = UnitCanAttack("player", "target") and "hostile" or "friendly" end
    out[1] = "NOW: combat=" .. YesNo(inCombat) .. " spec=" .. tostring(currentSpec)
        .. " target=" .. target .. " mounted=" .. YesNo(IsMounted())
        .. " vehicle=" .. YesNo(UnitInVehicle("player") or UnitHasVehicleUI("player"))

    -- the count of enemies and what the glow of each ability says (so a confusing moment can be examined)
    out[#out + 1] = "CROWD: ok=" .. YesNo(crowd.ok) .. " (" .. tostring(crowd.why or "never read") .. ") inCombat=" .. tostring(crowd.fighting)
        .. " attackingMe=" .. tostring(crowd.onMe)

    local now = GetTime()
    for i, a in ipairs(auras) do
        local ind = pool[i]
        if ind and a.class == playerClass then
            local lit = Safe(function() return C_SpellActivationOverlay.IsSpellOverlayed(a.spellID) and "yes" or "no" end)
            local on = {}
            if a.healthEnabled then on[#on + 1] = "health" end
            if a.enemyEnabled then on[#on + 1] = "enemyHealth" end
            if a.enemyAliveEnabled then on[#on + 1] = "targetAlive" end
            if a.formEnabled then on[#on + 1] = "form" end
            if a.tgtHostileEnabled then on[#on + 1] = "targetEnemyFriendly" end
            if a.tgtTypeEnabled then on[#on + 1] = "targetPlayerNpc" end
            if a.tgtClassEnabled then on[#on + 1] = "targetCategory" end
            if a.threatEnabled then on[#on + 1] = "targetAttackingMe" end
            if a.availEnabled then on[#on + 1] = "available" end
            if a.powerEnabled then on[#on + 1] = "resource" end
            if a.secEnabled then on[#on + 1] = "secondResource" end
            if a.cdEnabled then on[#on + 1] = "cooldown" end
            if a.chargesEnabled then on[#on + 1] = "charges" end
            if a.suppressEnabled then on[#on + 1] = "hideTimer" end
            if a.buffEnabled then on[#on + 1] = "empowered" end
            if a.buffEnabled and a.buffAlways then on[#on + 1] = "empoweredIgnoresOthers" end
            if a.showWhenEnabled then
                local rules = {}
                for rule, v in pairs(a.showRules or {}) do if v then rules[#rules + 1] = rule end end
                on[#on + 1] = "showOnly(" .. table.concat(rules, ",") .. ")"
            end
            local specOk = (not a.specs) or a.specs[currentSpec]
            local lingerLeft = (ind.lingerUntil and a.lingerEnabled) and math.max(0, ind.lingerUntil - now) or 0
            local hideLeft = (ind.suppressUntil and a.suppressEnabled) and math.max(0, ind.suppressUntil - now) or 0
            out[#out + 1] = "[" .. i .. "] " .. tostring(a.name)
                .. " | conditions: " .. (#on > 0 and table.concat(on, ", ") or "none")
                .. " | hidden=" .. YesNo(a.hidden) .. " specOk=" .. YesNo(specOk)
                .. " showRulesOk=" .. YesNo(ShowRulesAllow(a, ind))
                .. " lingerLeft=" .. string.format("%.1f", lingerLeft)
                .. " hideTimerLeft=" .. string.format("%.1f", hideLeft)
                .. " | frameShown=" .. YesNo(ind.A:IsShown())
                .. " alpha health/cost/enemy/cd/charges/empowered/alive/available/resource/secondResource="
                .. Alpha(ind.A) .. "/" .. Alpha(ind.C) .. "/" .. Alpha(ind.E) .. "/" .. Alpha(ind.F)
                .. "/" .. Alpha(ind.G) .. "/" .. Alpha(ind.H) .. "/" .. Alpha(ind.J)
                .. "/" .. Alpha(ind.M) .. "/" .. Alpha(ind.P) .. "/" .. Alpha(ind.S)
                .. " lit=" .. lit .. " secondIconAlpha=" .. Alpha(ind.R)
                .. " crowdRule=" .. (a.crowdEnabled and ((a.crowdMetric or "combat") .. " " .. (a.crowdOp or ">=") .. " " .. tostring(a.crowdN or 2)) or "off")
                .. " iconVisible=" .. Safe(ind.I.GetEffectiveAlpha, ind.I)
                .. " editing=" .. YesNo(ind.editing) .. " selected=" .. YesNo(ind.preview)
        end
    end
    return out
end
-- Preview = selected in the list: the placeholder is shown (and draggable) so several
-- auras can be arranged together on screen. Selection lives on the indicators themselves,
-- so it stays correct when an aura is deleted and the list shifts.
function HeadsUp_IsPreview(index)
    return pool[index] and pool[index].preview or false
end

function HeadsUp_PreviewCount()
    local n = 0
    for i = 1, #auras do
        if pool[i] and pool[i].preview then n = n + 1 end
    end
    return n
end

function HeadsUp_SetPreview(index, on)
    if not auras[index] then return end
    local ind = GetPooled(index)
    ind.preview = on and true or false
    RefreshMouse(ind)
    Update(ind)
end

local groupMoveId   -- the group that is shown on the screen to be moved as one (see HeadsUp_SetGroupMove)
local groupMoveList -- the indicators of that group
local groupAnchor = "C"   -- the dot of the box of the group that places it: TL, TR, BL, BR (corners) or C (centre)
local groupBox      -- the box with the five dots, drawn on the screen around the group (made when needed)
local groupSnap     -- the places the auras of the group had before a typed move (nil = nothing to put back)

function HeadsUp_ClearPreviews()
    for _, ind in pairs(pool) do
        ind.groupMove = nil
        if ind.plain then
            ind.plain = nil
            if ind.cfg then ApplyConfig(ind) end   -- the effects come back
        end
        if ind.preview then
            ind.preview = false
            RefreshMouse(ind)
            Update(ind)
        end
    end
    HeadsUp_GroupRestore()   -- a typed move that was not kept goes back
    groupMoveId = nil
    groupMoveList = nil
    if groupBox then groupBox:Hide() end
end

-- Hide / show a saved aura right away (hidden = kept, but it never appears in game).
function HeadsUp_SetHidden(index, hidden)
    if not auras[index] then return end
    hidden = hidden and true or nil
    auras[index].hidden = hidden
    if editIndex == index and draft then draft.hidden = hidden end
    ApplyConfig(GetPooled(index))
    -- the debuff trackers of an aura go with it
    local uid = auras[index].uid
    for j, t in ipairs(auras) do
        if uid and t.trackerOf == uid then
            t.hidden = hidden
            if editIndex == j and draft then draft.hidden = hidden end
            ApplyConfig(GetPooled(j))
        end
    end
end

-- Make an exact copy of a saved aura (same settings, same place). It gets a free name ("Death Strike 2")
-- and is active, even if the original is hidden. Returns the index of the copy.
function HeadsUp_DuplicateAura(index)
    local source = auras[index]
    if not source then return nil end
    local copy = CopyConfig(source)
    copy.uid = NewUid()   -- a copy is another aura: links must not mix them up
    copy.hidden = nil
    copy.name = UniqueName(source.name or SpellName(source.spellID) or "Aura", nil)
    auras[#auras + 1] = copy
    local ind = GetPooled(#auras)
    ind.cfg = copy
    ApplyConfig(ind)
    return #auras
end

-- Make a "debuff tracker" of a saved aura: a new aura for the effect the ability leaves on the enemy.
-- It copies only what is about the target and the situation (enemy, alive, health, category, "Show it only",
-- specializations...), not what is about the ability or the player's resources. Its timer starts when the
-- ability is cast, and it shows while the timer is NOT running (the enemy has lost the effect). The original
-- aura waits for the effect to end (the tracker's option "trackerCue").
-- seconds = how long the effect lasts (a suggestion from the description of the ability). Returns the new index.
function HeadsUp_CreateTracker(index, seconds)
    local source = auras[index]
    if not source or source.trackerOf then return nil end
    local t = CopyConfig(source)
    t.uid = NewUid()
    t.trackerOf = source.uid
    t.hidden = nil
        t.name = UniqueName((source.name or SpellName(source.spellID) or "Aura") .. " Tracker", nil)
    for _, k in ipairs({ "healthEnabled", "powerEnabled", "secEnabled", "cdEnabled", "chargesEnabled",
        "availEnabled", "buffEnabled", "buffAlways", "soundEnabled" }) do
        t[k] = false
    end
    t.kind, t.trackShow = "ability", "hide"
    if t.shape == "bar" then t.shape = "square" end
    t.suppressEnabled = true
    t.suppressSeconds = (source.suppressEnabled and source.suppressSeconds) or seconds or 10
    t.suppressReset = true
    t.trackerCue = true
    t.effect = "none"
    -- smaller than the original and tucked against its top right corner, so the two look like one package
    local px, py = 0, 150
    if source.pos and source.pos[1] == "CENTER" and source.pos[2] == "CENTER" then
        px, py = source.pos[3], source.pos[4]
    end
    local sw, sh = source.width or 50, source.height or 50
    local tw, th = math.max(16, math.floor(sw * 0.7 + 0.5)), math.max(16, math.floor(sh * 0.7 + 0.5))
    t.width, t.height, t.sizeLinked = tw, th, (tw == th)
    t.pos = { "CENTER", "CENTER", px + sw / 2 + tw / 2 + 4, py + sh / 2 - th / 2 }
    auras[#auras + 1] = t
    local ind = GetPooled(#auras)
    ind.cfg = t
    ApplyConfig(ind)
    ForEachIndicator(Update)
    return #auras
end

---------------------------------------------------------------------------
-- Groups of auras: a group is { id, name } in HeadsUpDB.groups. An aura belongs to at most one group (its `group` field is
-- the id of the group). A group is moved with the mouse as one, and deactivated and activated together.
---------------------------------------------------------------------------
local function GroupList()
    HeadsUpDB.groups = HeadsUpDB.groups or {}
    return HeadsUpDB.groups
end

function HeadsUp_GetGroups()
    if not HeadsUpDB then return {} end
    return GroupList()
end

-- a group needs at least two auras: with fewer it goes away (the aura that is left is free); an aura of a group that does not exist is free
function HeadsUp_PruneGroups()
    if not HeadsUpDB then return end
    local groups = GroupList()
    local used = {}
    for _, a in ipairs(auras) do
        if a.group then used[a.group] = (used[a.group] or 0) + 1 end
    end
    for i = #groups, 1, -1 do
        if (used[groups[i].id] or 0) < 2 then table.remove(groups, i) end
    end
    local known = {}
    for _, g in ipairs(groups) do known[g.id] = true end
    for _, a in ipairs(auras) do
        if a.group and not known[a.group] then a.group = nil end
    end
end

-- the auras of the list uids are the members of the group id (the ones that were in it before and are not in the list leave)
function HeadsUp_SetGroupMembers(id, uids)
    local want = {}
    for _, uid in ipairs(uids) do want[uid] = true end
    for _, a in ipairs(auras) do
        if a.uid and want[a.uid] then
            a.group = id
        elseif a.group == id then
            a.group = nil
        end
    end
    HeadsUp_PruneGroups()
end

-- put the saved aura (its position in the list) into the group id
function HeadsUp_AddToGroup(index, id)
    if auras[index] then auras[index].group = id end
end

function HeadsUp_CreateGroup(name, uids)
    local id = NewUid()
    table.insert(GroupList(), { id = id, name = name })
    HeadsUp_SetGroupMembers(id, uids)
    return id
end

function HeadsUp_RenameGroup(id, name)
    for _, g in ipairs(GroupList()) do
        if g.id == id then g.name = name end
    end
end

-- open / close a group in the list (closed: only its header is shown)
function HeadsUp_ToggleGroupCollapsed(id)
    for _, g in ipairs(GroupList()) do
        if g.id == id then g.collapsed = (not g.collapsed) or nil end
    end
end

-- the colour of the header of a group in the list: { r, g, b } (nil = the usual one)
function HeadsUp_SetGroupColor(id, rgb)
    for _, g in ipairs(GroupList()) do
        if g.id == id then g.color = rgb end
    end
end

function HeadsUp_Ungroup(id)
    for _, a in ipairs(auras) do
        if a.group == id then a.group = nil end
    end
    HeadsUp_PruneGroups()
end

-- the positions (in the list of the saved auras) of the members of a group
function HeadsUp_GroupMembers(id)
    local list = {}
    for i, a in ipairs(auras) do
        if a.group == id then list[#list + 1] = i end
    end
    return list
end

-- deactivate / activate all the auras of a group
function HeadsUp_SetGroupHidden(id, hidden)
    for _, i in ipairs(HeadsUp_GroupMembers(id)) do
        HeadsUp_SetHidden(i, hidden)
    end
end

-- The box of a group on the screen: a frame around all the auras of the group, with a dot in each of the four corners, one in the
-- middle of each of the four edges, and one in the centre. The dot that is chosen (red) is the one that places the group (HeadsUp_GroupMoveTo).
local ANCHOR_NAMES = {
    TL = "top left corner", TR = "top right corner", BL = "bottom left corner", BR = "bottom right corner",
    T = "middle of the top edge", B = "middle of the bottom edge", L = "middle of the left edge", R = "middle of the right edge",
    C = "centre",
}

-- the box around the auras of the group: left, bottom, right, top (nil if there is none)
local function GroupRect()
    if not groupMoveList then return nil end
    local l, b, r, t
    for _, ind in ipairs(groupMoveList) do
        local fl, fb, fr, ft = ind.A:GetLeft(), ind.A:GetBottom(), ind.A:GetRight(), ind.A:GetTop()
        if fl then
            l = l and math.min(l, fl) or fl
            b = b and math.min(b, fb) or fb
            r = r and math.max(r, fr) or fr
            t = t and math.max(t, ft) or ft
        end
    end
    return l, b, r, t
end

local function EnsureGroupBox()
    if groupBox then return groupBox end
    local box = CreateFrame("Frame", nil, UIParent)
    box:SetFrameStrata("FULLSCREEN")
    box:SetFrameLevel(1)
    box:Hide()
    local function line(p1, p2, horizontal)
        local t = box:CreateTexture(nil, "OVERLAY")
        t:SetColorTexture(1, 0.82, 0, 0.9)
        t:SetPoint(p1)
        t:SetPoint(p2)
        if horizontal then t:SetHeight(2) else t:SetWidth(2) end
    end
    line("TOPLEFT", "TOPRIGHT", true)
    line("BOTTOMLEFT", "BOTTOMRIGHT", true)
    line("TOPLEFT", "BOTTOMLEFT", false)
    line("TOPRIGHT", "BOTTOMRIGHT", false)
    box.dots = {}
    for _, key in ipairs({ "TL", "TR", "BL", "BR", "T", "B", "L", "R", "C" }) do
        local d = CreateFrame("Button", nil, box)
        d:SetSize(16, 16)
        d.key = key
        d.back = d:CreateTexture(nil, "ARTWORK")
        d.back:SetAllPoints()
        d.back:SetColorTexture(0, 0, 0, 1)
        d.tex = d:CreateTexture(nil, "OVERLAY")
        d.tex:SetPoint("CENTER")
        d.tex:SetSize(12, 12)
        -- round dots (the same mask as a round icon)
        for _, t in ipairs({ d.back, d.tex }) do
            local mask = d:CreateMaskTexture()
            mask:SetTexture(FX_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            mask:SetAllPoints(t)
            t:AddMaskTexture(mask)
        end
        if key == "TL" then d:SetPoint("CENTER", box, "TOPLEFT")
        elseif key == "TR" then d:SetPoint("CENTER", box, "TOPRIGHT")
        elseif key == "BL" then d:SetPoint("CENTER", box, "BOTTOMLEFT")
        elseif key == "BR" then d:SetPoint("CENTER", box, "BOTTOMRIGHT")
        elseif key == "T" then d:SetPoint("CENTER", box, "TOP")
        elseif key == "B" then d:SetPoint("CENTER", box, "BOTTOM")
        elseif key == "L" then d:SetPoint("CENTER", box, "LEFT")
        elseif key == "R" then d:SetPoint("CENTER", box, "RIGHT")
        else d:SetPoint("CENTER", box, "CENTER") end
        d:SetScript("OnClick", function(self)
            HeadsUp_SetGroupAnchor(self.key)
            if HeadsUp_OnGroupDotClicked then HeadsUp_OnGroupDotClicked() end   -- opens the Position window (Settings.lua)
        end)
        d:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("Anchor: " .. ANCHOR_NAMES[self.key], 1, 0.82, 0)
            GameTooltip:AddLine("Click to choose it and open the Position window, where this dot can be put at coordinates.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        d:SetScript("OnLeave", function() GameTooltip:Hide() end)
        box.dots[key] = d
    end
    box:SetScript("OnUpdate", function(self)
        local l, b, r, t = GroupRect()
        if not l then
            self:Hide()
            return
        end
        local pad = 8
        self:ClearAllPoints()
        self:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", l - pad, b - pad)
        self:SetSize(math.max(r - l + 2 * pad, 4), math.max(t - b + 2 * pad, 4))
        for key, d in pairs(self.dots) do
            local chosen = (key == groupAnchor)
            if d.chosen ~= chosen then
                d.chosen = chosen
                if chosen then d.tex:SetColorTexture(1, 0.1, 0.1, 1) else d.tex:SetColorTexture(1, 0.82, 0, 1) end
            end
        end
    end)
    groupBox = box
    return box
end

function HeadsUp_SetGroupAnchor(key)
    if ANCHOR_NAMES[key] then groupAnchor = key end
end

function HeadsUp_GetGroupAnchor()
    return groupAnchor
end

-- where the chosen dot is now: X and Y from the centre of the screen (X to the right, Y upwards); nil if no group is shown
function HeadsUp_GroupAnchorPos()
    local l, b, r, t = GroupRect()
    local ux, uy = UIParent:GetCenter()
    if not l or not ux then return nil end
    -- the left side for TL, BL, L; the right side for TR, BR, R; the middle for T, B, C
    local x = (groupAnchor == "TL" or groupAnchor == "BL" or groupAnchor == "L") and l
        or ((groupAnchor == "TR" or groupAnchor == "BR" or groupAnchor == "R") and r or (l + r) / 2)
    -- the top for TL, TR, T; the bottom for BL, BR, B; the middle for L, R, C
    local y = (groupAnchor == "TL" or groupAnchor == "TR" or groupAnchor == "T") and t
        or ((groupAnchor == "BL" or groupAnchor == "BR" or groupAnchor == "B") and b or (b + t) / 2)
    return math.floor(x - ux + 0.5), math.floor(y - uy + 0.5)
end

-- put the chosen dot at X, Y (from the centre of the screen): every aura of the group moves by the same distance
function HeadsUp_GroupMoveTo(x, y)
    local cx, cy = HeadsUp_GroupAnchorPos()
    local ux, uy = UIParent:GetCenter()
    if not cx or not groupMoveList then return end
    local dx, dy = x - cx, y - cy
    if dx == 0 and dy == 0 then return end
    if not groupSnap then   -- remember where they were, to put them back if the move is not kept (HeadsUp_GroupRestore)
        groupSnap = {}
        for _, ind in ipairs(groupMoveList) do
            if ind.cfg and ind.cfg.pos then
                groupSnap[ind] = { ind.cfg.pos[1], ind.cfg.pos[2], ind.cfg.pos[3], ind.cfg.pos[4] }
            end
        end
    end
    for _, ind in ipairs(groupMoveList) do
        local fx, fy = ind.A:GetCenter()
        if fx and ind.cfg then
            local nx, ny = math.floor(fx - ux + 0.5) + dx, math.floor(fy - uy + 0.5) + dy
            ind.cfg.pos = { "CENTER", "CENTER", nx, ny }
            ind.A:ClearAllPoints()
            ind.A:SetPoint("CENTER", UIParent, "CENTER", nx, ny)
        end
    end
end

-- The group id is shown on the screen (its auras are selected: HeadsUp_SetPreview), with its box and dots; dragging one of its
-- auras moves all of them. nil ends it.
function HeadsUp_SetGroupMove(id)
    HeadsUp_GroupRestore()   -- a typed move that was not kept goes back
    for _, ind in pairs(pool) do ind.groupMove = nil end
    groupMoveId, groupMoveList = nil, nil
    if groupBox then groupBox:Hide() end
    if not id then return end
    local list = {}
    for _, i in ipairs(HeadsUp_GroupMembers(id)) do list[#list + 1] = GetPooled(i) end
    if #list == 0 then return end
    if #list >= 2 then
        for _, ind in ipairs(list) do ind.groupMove = list end   -- (a group of one aura moves like any aura)
    end
    for _, ind in ipairs(list) do ind.plain = true end   -- clean icons, no effects, while the group is placed
    groupMoveId, groupMoveList = id, list
    EnsureGroupBox():Show()
end

-- the typed move is kept (Place it, Save, or a drag with the mouse)
function HeadsUp_GroupCommit()
    groupSnap = nil
end

-- the typed move is not kept: the auras go back to where they were
function HeadsUp_GroupRestore()
    if not groupSnap then return end
    for ind, p in pairs(groupSnap) do
        if ind.cfg then
            ind.cfg.pos = p
            ApplyPosition(ind)
        end
    end
    groupSnap = nil
end

-- the group that is shown on the screen now (nil if none)
function HeadsUp_GetMovingGroup()
    return groupMoveId
end

function HeadsUp_GroupMoving(id)
    return groupMoveId ~= nil and groupMoveId == id
end

-- Delete a saved aura. Returns true if it was the aura being edited.
function HeadsUp_DeleteAura(index)
    if not auras[index] then return false end
    local wasEditing = (editIndex == index)
    if wasEditing then
        HeadsUp_EndEdit()
    elseif editIndex and editIndex > index then
        editIndex = editIndex - 1
    end
    local goneUid = auras[index].uid
    table.remove(auras, index)
    local function forget(cfg)
        if cfg and cfg.otherAuras and goneUid then
            for i = #cfg.otherAuras, 1, -1 do
                if cfg.otherAuras[i].uid == goneUid then table.remove(cfg.otherAuras, i) end
            end
            if #cfg.otherAuras == 0 then cfg.otherAuras = nil end
        end
    end
    for _, a in ipairs(auras) do forget(a) end
    forget(draft)
    HeadsUp_PruneGroups()
    local ind = table.remove(pool, index)
    if ind then
        ind.editing = false
        ind.preview = false
        ind.cfg = nil
        RefreshMouse(ind)
        ApplyConfig(ind)
        spare[#spare + 1] = ind
    end
    return wasEditing
end

function HeadsUp_EndEdit()
    if not editInd then return end
    editInd.editing = false
    editInd.cfg = editIndex and auras[editIndex] or nil
    RefreshMouse(editInd)
    ApplyConfig(editInd)
    editInd, draft, editIndex = nil, nil, nil
end

-- index = position in the saved list, or nil for a brand-new aura.
function HeadsUp_BeginEdit(index)
    HeadsUp_EndEdit()
    editIndex = index
    if index then
        draft = CopyConfig(auras[index])
        draft.name = draft.name or SpellName(draft.spellID)
        editInd = GetPooled(index)
    else
        draft = NewConfig()
        newInd = newInd or CreateIndicator()
        editInd = newInd
    end
    editInd.cfg = draft
    editInd.editing = true
    RefreshMouse(editInd)
    ApplyConfig(editInd)
    return draft
end

-- Where the draft's icon is: the distance of its centre from the centre of the screen
-- (X to the right, Y upwards). A new aura starts at 0, 150.
function HeadsUp_GetPosition()
    if not draft then return 0, 150 end
    local pos = draft.pos
    if not pos then return 0, 150 end
    if pos[1] == "CENTER" and pos[2] == "CENTER" then return pos[3], pos[4] end
    -- an older position, anchored at another point: measure where the icon is now
    local frame = editInd and editInd.A
    local cx, cy
    if frame then cx, cy = frame:GetCenter() end
    local ux, uy = UIParent:GetCenter()
    if cx and ux then return cx - ux, cy - uy end
    return 0, 150
end

-- Put the draft's icon at X, Y (see above). The window applies the draft afterwards.
function HeadsUp_SetPosition(x, y)
    if not draft then return end
    draft.pos = { "CENTER", "CENTER", x, y }
end

-- Re-apply the draft after the settings window changed it.
function HeadsUp_ApplyDraft()
    if editInd then ApplyConfig(editInd) end
end

-- Write the draft into the saved list. Returns the aura's index, or nil if no ability yet.
function HeadsUp_Save()
    if not draft or not draft.spellID then return nil end
    draft.name = UniqueName(draft.name or SpellName(draft.spellID) or "Aura", editIndex)
    draft.uid = draft.uid or NewUid()
    if editIndex then
        auras[editIndex] = CopyConfig(draft)
    else
        auras[#auras + 1] = CopyConfig(draft)
        editIndex = #auras
        -- the draft now belongs to the new pooled indicator; free the "new" one
        local old = editInd
        old.editing = false
        old.cfg = nil
        RefreshMouse(old)
        ApplyConfig(old)
        editInd = GetPooled(editIndex)
        editInd.cfg = draft
        editInd.editing = true
        RefreshMouse(editInd)
        ApplyConfig(editInd)
    end
    return editIndex
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local driver = CreateFrame("Frame")

-- The id (GUID) of the current target, or nil when there is none or it cannot be read. The test of 21 Oct 2026
-- (HeadsUpDB.targetProbe) found it readable in combat, so it tells one enemy from another.
local function TargetGuid()
    if not UnitExists("target") then return nil end
    local ok, guid = pcall(UnitGUID, "target")
    if not ok or type(guid) ~= "string" or issecretvalue(guid) then return nil end
    return guid
end

-- A silent test (HeadsUpDB.targetProbe, read from the log file): can the addon tell one enemy from another in
-- combat? On every target change and every cast of the player it writes what can be read about the target
-- (readable / secret): its id (GUID), name, level, type, and the nameplate frame it has. Nothing goes to the chat.
local function RecordTargetProbe(event, spellID)
    if not HeadsUpDB then return end
    local probe = HeadsUpDB.targetProbe or {}
    probe.samples = probe.samples or {}
    probe.counts = probe.counts or {}
    HeadsUpDB.targetProbe = probe
    local where = inCombat and "combat" or "ooc"
    local function kind(v)
        if v == nil then return "nil" end
        local ok, secret = pcall(issecretvalue, v)
        return (ok and secret) and "secret" or "readable"
    end
    local entry = { t = date("%H:%M:%S"), event = event, combat = inCombat and true or false }
    if spellID ~= nil and kind(spellID) == "readable" then entry.spell = spellID end
    local exists = UnitExists("target")
    entry.exists = exists and true or false
    if exists then
        local function look(name, fn)
            local ok, v = pcall(fn, "target")
            local k = not ok and "error" or kind(v)
            entry[name] = k
            local key = name .. "_" .. where .. "_" .. k
            probe.counts[key] = (probe.counts[key] or 0) + 1
            if ok and k == "readable" then return v end
            return nil
        end
        local guid = look("guid", UnitGUID)
        if guid then entry.guidTail = tostring(guid):sub(-12) end
        local name = look("name", UnitName)
        if name then entry.nameText = tostring(name) end
        -- the distance to the target (yards, squared): a spell with travel time takes distance / speed to arrive
        local dist = look("distSq", function(unit) return UnitDistanceSquared and UnitDistanceSquared(unit) end)
        if dist then entry.yards = math.floor(math.sqrt(dist) + 0.5) end
        look("level", UnitLevel)
        look("classification", UnitClassification)
        look("creatureType", UnitCreatureType)
        local okP, plate = pcall(C_NamePlate.GetNamePlateForUnit, "target")
        entry.plate = (okP and plate) and tostring(plate):sub(-8) or (okP and "none" or "error")
        if okP and plate and plate.GetUnit then
            -- (the unit token of the nameplate: readable?)
            local okU, token = pcall(function() return plate:GetUnit() end)
            entry.plateToken = okU and kind(token) or "error"
        end
    end
    table.insert(probe.samples, entry)
    while #probe.samples > 100 do table.remove(probe.samples, 1) end
end

-- A second silent test (HeadsUpDB.crowdProbe): how many enemies are around and how many of them have aggro on the
-- player? Every 3 seconds in combat it walks the nameplates and writes what can be read (readable / secret), with
-- the kind of place (none = open world, party, raid, scenario...). Nothing goes to the chat.
local function RecordCrowdProbe()
    if not HeadsUpDB or not (C_NamePlate and C_NamePlate.GetNamePlates) then return end
    local probe = HeadsUpDB.crowdProbe or {}
    probe.samples = probe.samples or {}
    probe.counts = probe.counts or {}
    HeadsUpDB.crowdProbe = probe
    local _, place = IsInInstance()
    place = place or "none"
    local entry = { t = date("%H:%M:%S"), place = place, plates = 0, hostile = 0, fighting = 0, onMe = 0 }
    local function kind(v)
        if v == nil then return "nil" end
        local ok, secret = pcall(issecretvalue, v)
        return (ok and secret) and "secret" or "readable"
    end
    local function count(name, k)
        local key = name .. "_" .. place .. "_" .. k
        probe.counts[key] = (probe.counts[key] or 0) + 1
    end
    local okPlates, plates = pcall(C_NamePlate.GetNamePlates)
    if not okPlates or type(plates) ~= "table" then
        entry.error = "GetNamePlates"
        count("plates", "error")
    else
        for _, plate in ipairs(plates) do
            local okU, unit = pcall(function() return plate.namePlateUnitToken or plate:GetUnit() end)
            local unitKind = okU and kind(unit) or "error"
            count("unitToken", unitKind)
            if okU and unitKind == "readable" then
                entry.plates = entry.plates + 1
                local function look(name, fn)
                    local ok, v = pcall(fn, unit)
                    local k = not ok and "error" or kind(v)
                    count(name, k)
                    if ok and k == "readable" then return v end
                    return nil
                end
                if look("canAttack", function(u) return UnitCanAttack("player", u) end) then
                    entry.hostile = entry.hostile + 1
                    if look("inCombat", UnitAffectingCombat) then entry.fighting = entry.fighting + 1 end
                    local threat = look("threat", function(u) return UnitThreatSituation("player", u) end)
                    if threat and threat >= 2 then entry.onMe = entry.onMe + 1 end
                end
            end
        end
    end
    table.insert(probe.samples, entry)
    while #probe.samples > 60 do table.remove(probe.samples, 1) end
end

local function OnEvent(_, event, arg1, arg2, arg3)
    if event == "PLAYER_TARGET_CHANGED" then
        pcall(RecordTargetProbe, event)
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        pcall(RecordTargetProbe, "cast", arg3)
    end
    if event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" then
        -- Self-learning: remember which abilities light up (are "empowered"), for this class
        -- and specialization. The "Buff" condition offers exactly these.
        if HeadsUpDB and currentSpec and type(arg1) == "number" and not issecretvalue(arg1) then
            local learned = HeadsUpDB.learned or {}
            HeadsUpDB.learned = learned
            local forClass = learned[playerClass] or {}
            learned[playerClass] = forClass
            local forSpec = forClass[currentSpec] or {}
            forClass[currentSpec] = forSpec
            forSpec[arg1] = (forSpec[arg1] or 0) + 1
        end
    end
    if event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        -- combat just ended: start each aura's "keep showing after combat" timer
        local now = GetTime()
        ForEachIndicator(function(ind)
            local c = ind.cfg
            ind.lingerUntil = (c and c.lingerEnabled) and (now + (c.lingerSeconds or 5)) or nil
            -- the journal of the targets is cleared with the fight
            if ind.targetTimers then
                ind.targetTimers = nil
                if c and c.suppressEnabled and c.suppressReset then ind.suppressUntil = nil end
            end
        end)
    end
    if event == "PLAYER_TARGET_CHANGED" then
        -- "Start over on a new target": the timer belongs to the target it was started on. Each target has its own
        -- timer in a journal (ind.targetTimers[guid]); a new target has none, and one you hit before continues.
        local guid = TargetGuid()
        local now = GetTime()
        ForEachIndicator(function(ind)
            local c = ind.cfg
            if c and c.suppressEnabled and c.suppressReset then
                local expires = guid and ind.targetTimers and ind.targetTimers[guid]
                ind.suppressUntil = (expires and expires > now) and expires or nil
            end
        end)
    end
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- arg3 = the spell the player just cast. Start the hide-timer of every aura for it.
        local spellID = arg3
        if spellID and not issecretvalue(spellID) then
            local now = GetTime()
            local started = false
            local guid = TargetGuid()
            local castName = SpellNameOf(spellID)
            ForEachIndicator(function(ind)
                local c = ind.cfg
                if c and c.suppressEnabled and (c.spellID == spellID or AlsoStartedBy(c, castName)) then
                    local expires = now + (c.suppressSeconds or 10)
                    ind.suppressUntil = expires
                    if c.suppressReset and guid then
                        -- the journal: this target has the effect until then (old entries are dropped)
                        local journal = ind.targetTimers or {}
                        for id, t in pairs(journal) do
                            if t <= now then journal[id] = nil end
                        end
                        journal[guid] = expires
                        ind.targetTimers = journal
                    end
                    started = true
                end
            end)
            -- (the auras that look at a timer of another aura change too, so all are updated)
            if started then ForEachIndicator(Update) end
        end
        return
    end
    if event == "ADDON_LOADED" then
        if arg1 ~= "HeadsUp" then return end
        playerClass = select(2, UnitClass("player"))
        inCombat = UnitAffectingCombat("player") and true or false
        RefreshCurrentSpec()
        HeadsUpDB = HeadsUpDB or {}
        HeadsUpDB.soundStats = nil   -- left over from the sound experiment (removed)
        for _, e in ipairs(pendingErrors) do
            HeadsUpDB.errors = HeadsUpDB.errors or {}
            table.insert(HeadsUpDB.errors, e)
        end
        pendingErrors = {}
        if not HeadsUpDB.auras then
            HeadsUpDB.auras = {}
            -- migrate the old single-aura format
            if HeadsUpDB.spellID then
                local old = { class = playerClass }
                for _, k in ipairs(KEYS) do
                    if k ~= "class" then old[k] = HeadsUpDB[k] end
                end
                HeadsUpDB.auras[1] = old
            end
        end
        for _, k in ipairs(KEYS) do
            if k ~= "auras" then HeadsUpDB[k] = nil end
        end
        auras = HeadsUpDB.auras
        NormalizeNames()
        for i, a in ipairs(auras) do
            -- migrate the older single "Show it" dropdown (always / combat / out / never)
            if a.showWhenEnabled == nil then
                a.showWhenEnabled = (a.showWhen ~= nil and a.showWhen ~= "always")
            end
            -- while "Show it only" is off its list means nothing: show "Always" if it is ticked later
            if a.showWhenEnabled == false then
                a.showRules = { always = true }
            end
            -- older "Glow around the icon" checkbox became the "Show effect" dropdown
            if a.effect == nil then
                a.effect = a.glow and "glow" or "none"
            end
            if a.showRules == nil then
                if a.showWhen == "out" then
                    a.showRules = { out = true }
                elseif a.showWhen == "never" then
                    a.showRules = { never = true }
                else
                    a.showRules = { combat = true }
                end
            end
            -- "Buff" used to hold a buff's spell id; it now holds an ability that lights up
            a.buffID = nil   -- no longer used: the aura always looks at its own ability
            -- the separate "Ability is lit up" row was merged into "Buff"
            if a.litEnabled then
                a.buffEnabled = true
                a.buffState = (a.lit == "no") and "gone" or "active"
            end
            a.litEnabled, a.lit = nil, nil
            -- the first version of "Always show when empowered" was a row of its own: it is now
            -- the "Ignore the other conditions" sub-option of "Empowered: active"
            if a.buffAlways and not a.buffEnabled then
                a.buffEnabled = true
                a.buffState = "active"
            end
            -- "Never" was removed (Hide does the same): such an aura becomes a hidden one
            if a.showRules and a.showRules.never then
                a.showRules.never = nil
                a.hidden = true
                if next(a.showRules) == nil then a.showRules = { always = true } end
            end
            -- the icon used to be a square with one size; it now has a width and a height
            if a.width == nil then
                a.width = a.size or 50
                a.height = a.size or 50
            end
            a.size = nil
            -- a sound that is no longer in the list becomes the default one
            -- the sound was first an option of "Empowered" (buffSound...): now it belongs to the whole aura
            if a.buffSound ~= nil then
                if a.soundEnabled == nil then
                    a.soundEnabled = a.buffSound
                    a.soundKey = a.buffSoundKey
                    a.soundVolume = a.buffSoundVolume
                end
                a.buffSound, a.buffSoundKey, a.buffSoundVolume = nil, nil, nil
            end
            local known = false
            for _, sound in ipairs(HeadsUpSounds) do
                if sound.key == a.soundKey then known = true end
            end
            if not known then a.soundKey = "ding" end
            -- "Enemy is alive" used to need a hostile target by itself: it is now the separate row "Target is an enemy"
            if a.enemyAliveEnabled and a.tgtHostileEnabled == nil then
                a.tgtHostileEnabled = true
                a.tgtHostile = "enemy"
            end
            FillDefaults(a)
            a.uid = a.uid or NewUid()
            a.links = nil   -- (an older way to link auras: no longer used)
            if a.kind == "buff" or a.kind == "debuff" then a.kind = "tracker" end
            -- "None" used to be a choice of the bar's time and icon: now a tick box each
            if a.barTime == "none" then a.barTimeOn, a.barTime = false, "right" end
            if a.barIcon == "none" then a.barIconOn, a.barIcon = false, "left" end   -- one kind: the side comes from the ability
            local ind = GetPooled(i)
            ind.cfg = a
            ApplyConfig(ind)
        end
        HeadsUp_PruneGroups()
        HeadsUpDB.glowChoice = true   -- the migration above is done
        return
    end
    if event == "PLAYER_ENTERING_WORLD" then
        inCombat = UnitAffectingCombat("player") and true or false
        RefreshCurrentSpec()   -- the spec may not be known yet when the addon file loads
    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        RefreshCurrentSpec()
    end
    if event == "PLAYER_ENTERING_WORLD" or event == "UNIT_MAXPOWER" or event == "PLAYER_TALENT_UPDATE"
        or event == "UNIT_DISPLAYPOWER" or event == "PLAYER_SPECIALIZATION_CHANGED" then
        ForEachIndicator(ApplyConfig)
        return
    end
    if event == "SPELL_UPDATE_COOLDOWN" then
        ForEachIndicator(UpdateCooldown)
    end
    ForEachIndicator(Update)
end

driver:RegisterEvent("ADDON_LOADED")
driver:RegisterEvent("PLAYER_ENTERING_WORLD")
driver:RegisterEvent("SPELL_UPDATE_COOLDOWN")
driver:RegisterEvent("PLAYER_TALENT_UPDATE")
driver:RegisterEvent("PLAYER_MOUNT_DISPLAY_CHANGED")
driver:RegisterUnitEvent("UNIT_AURA", "player")
driver:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW")
driver:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE")
driver:RegisterUnitEvent("UNIT_ENTERED_VEHICLE", "player")
driver:RegisterUnitEvent("UNIT_EXITED_VEHICLE", "player")
driver:RegisterUnitEvent("PLAYER_SPECIALIZATION_CHANGED", "player")
driver:RegisterEvent("PLAYER_REGEN_DISABLED")
driver:RegisterEvent("PLAYER_REGEN_ENABLED")
driver:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
driver:RegisterEvent("PLAYER_TARGET_CHANGED")
driver:RegisterUnitEvent("UNIT_HEALTH", "player", "target")
driver:RegisterUnitEvent("UNIT_MAXHEALTH", "player", "target")
driver:RegisterUnitEvent("UNIT_POWER_UPDATE", "player")
driver:RegisterUnitEvent("UNIT_MAXPOWER", "player")
driver:RegisterUnitEvent("UNIT_DISPLAYPOWER", "player")   -- the main resource changed (druid forms)
driver:RegisterEvent("RUNE_POWER_UPDATE")
driver:RegisterEvent("UPDATE_SHAPESHIFT_FORM")   -- the form changed (druid...)
driver:RegisterEvent("GROUP_ROSTER_UPDATE")      -- solo / party / raid changed
driver:RegisterEvent("UPDATE_STEALTH")
driver:RegisterEvent("ZONE_CHANGED_NEW_AREA")
driver:RegisterEvent("CURRENCY_DISPLAY_UPDATE")     -- a currency changed: the counters are written again
driver:RegisterEvent("BAG_UPDATE_DELAYED")        -- the bags changed: the counters are written again
driver:RegisterEvent("ITEM_DATA_LOAD_RESULT")     -- the name of an item has arrived
driver:SetScript("OnEvent", OnEvent)

-- A cooldown running out fires no event, so auras with a cooldown condition are
-- re-checked a few times a second.
-- A silent probe: once a second while in combat it asks the game for a few values and counts, in
-- HeadsUpDB.probe, whether each one is readable or hidden ("secret") in combat. It writes nothing
-- in the chat. It tells us what the addon may use for sounds and conditions.
local sinceProbe = 0
local function Probe()
    if not HeadsUpDB then return end
    local stats = HeadsUpDB.probe or {}
    HeadsUpDB.probe = stats
    local function check(name, fn, ...)
        local ok, value = pcall(fn, ...)
        local kind = (not ok and "error") or (value == nil and "nil") or (issecretvalue(value) and "secret") or "readable"
        local key = "combat_" .. name .. "_" .. kind
        stats[key] = (stats[key] or 0) + 1
    end
    check("UnitHealth_player", UnitHealth, "player")
    check("UnitHealthMax_player", UnitHealthMax, "player")
    check("UnitPower_player_main", function() return UnitPower("player") end)
    check("UnitPowerMax_player_main", function() return UnitPowerMax("player") end)
    if UnitExists("target") then
        check("UnitHealth_target", UnitHealth, "target")
    end
    local spellID
    for _, a in ipairs(auras) do
        if a.class == playerClass and a.spellID then spellID = a.spellID break end
    end
    if spellID then
        check("cooldown_duration", function()
            local cd = C_Spell.GetSpellCooldown(spellID)
            return cd and cd.duration
        end)
        check("cooldown_start", function()
            local cd = C_Spell.GetSpellCooldown(spellID)
            return cd and cd.startTime
        end)
        check("charges_current", function()
            local ch = C_Spell.GetSpellCharges(spellID)
            return ch and ch.currentCharges
        end)
        check("IsSpellUsable", function() return (C_Spell.IsSpellUsable(spellID)) end)
        check("IsSpellOverlayed", function() return C_SpellActivationOverlay.IsSpellOverlayed(spellID) end)
    end
end

local sinceCheck = 0
local sinceCrowd = 0
local sinceCrowdRead = 0
driver:SetScript("OnUpdate", function(_, elapsed)
    if inCombat then
        sinceCrowd = (sinceCrowd or 0) + elapsed
        if sinceCrowd >= 3 then
            sinceCrowd = 0
            pcall(RecordCrowdProbe)
        end
        sinceProbe = sinceProbe + elapsed
        if sinceProbe >= 1 then
            sinceProbe = 0
            Probe()
        end
    end
    sinceCheck = sinceCheck + elapsed
    if sinceCheck < 0.1 then return end
    sinceCheck = 0
    local needCrowd = false
    ForEachIndicator(function(ind)
        if ind.cfg and ind.cfg.crowdEnabled then needCrowd = true end
    end)
    if needCrowd then
        sinceCrowdRead = sinceCrowdRead + 0.1
        if sinceCrowdRead >= 0.2 then
            sinceCrowdRead = 0
            RefreshCrowd()
        end
    end
    ForEachIndicator(function(ind)
        local cfg = ind.cfg
        if cfg and (cfg.kind == "counter" or cfg.cdEnabled or cfg.chargesEnabled or cfg.suppressEnabled or cfg.buffEnabled
            or cfg.lingerEnabled or cfg.availEnabled or cfg.secEnabled or cfg.soundEnabled
            or cfg.formEnabled or cfg.tgtHostileEnabled or cfg.tgtTypeEnabled or cfg.tgtClassEnabled
            or cfg.threatEnabled or cfg.showWhenEnabled or HasCue(cfg) or (cfg.otherAuras and cfg.otherAuras[1]) or cfg.crowdEnabled)
            and ind.A:IsShown() then
            Update(ind)
        end
    end)
end)

-- /headsup : open settings
-- /headsup why : save to the log what every aura is doing right now, so a confusing moment
-- can be examined exactly. Works in combat. It never writes to the chat: the lines are
-- kept (the last 30 snapshots, newest last) in HeadsUpDB.why and read from the log file.
function HeadsUp_Why()
    if not HeadsUpDB then return end
    local history = HeadsUpDB.why
    if type(history) ~= "table" or type(history[1]) ~= "table" then history = {} end
    local lines = HeadsUp_DebugState()
    table.insert(lines, 1, "== snapshot " .. date("%H:%M:%S"))
    history[#history + 1] = lines
    while #history > 30 do table.remove(history, 1) end
    HeadsUpDB.why = history
end
-- /headsup soundtest : plays four sounds, two seconds apart, to find out which ones are heard:
--   1 a sound of the game, 2 a sound file of another addon (GTFO, if it is installed),
--   3 and 4 two of our own files. The answer of the game is written to HeadsUpDB.soundLog (nothing in the chat).
function HeadsUp_SoundTest()
    local tests = {
        { "1 game sound 12889", function() return PlaySound(12889, "Master") end },
        { "2 GTFO file", function() return PlaySoundFile("Interface\\AddOns\\GTFO\\Sounds\\alarmbeep.ogg", "Master") end },
        { "3 our ding_3", function() return PlaySoundFile("Interface\\AddOns\\HeadsUp\\Sounds\\ding_3.ogg", "Master") end },
        { "4 our chime_3", function() return PlaySoundFile("Interface\\AddOns\\HeadsUp\\Sounds\\chime_3.ogg", "Master") end },
    }
    for i, test in ipairs(tests) do
        C_Timer.After((i - 1) * 2.5, function()
            local ok, willPlay, handle = pcall(test[2])
            LogSound("soundtest " .. test[1] .. " -> " .. tostring(ok) .. " willPlay=" .. tostring(willPlay)
                .. " handle=" .. tostring(handle))
        end)
    end
end

SLASH_HEADSUP1 = "/headsup"
SlashCmdList.HEADSUP = function(msg)
    if msg == "why" then
        HeadsUp_Why()
    elseif msg == "soundtest" then
        HeadsUp_SoundTest()
    elseif msg == "survey off" or msg == "survey on" then
        -- the recorders (Survey.lua, Survey2.lua) start at the next /reload only when this is "on"
        HeadsUpDB.surveyOff = (msg == "survey off") or nil
    elseif msg == "scan" then
        if HeadsUp_ScanCatalog then HeadsUp_ScanCatalog(true) end
    elseif msg == "minimap" then
        if HeadsUp_ToggleMinimapButton then HeadsUp_ToggleMinimapButton() end
    else
        HeadsUp_ToggleSettings()
    end
end

print("|cffff8800HeadsUp|r loaded")
