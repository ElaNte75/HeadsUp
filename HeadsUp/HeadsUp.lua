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

local KEYS = { "class", "specs", "name", "hidden", "spellID", "healthEnabled", "healthOp", "healthPct", "enemyEnabled", "enemyOp", "enemyPct", "cdEnabled", "cdState", "chargesEnabled", "chargesState", "enemyAliveEnabled", "enemyAlive", "buffEnabled", "buffID", "buffState", "suppressEnabled", "suppressSeconds", "effect", "icon", "showWhenEnabled", "showRules", "lingerEnabled", "lingerSeconds", "layer", "availEnabled", "pos", "width", "height", "sizeLinked", "powerEnabled", "powerOp", "powerValue", "secEnabled", "secOp", "secValue", "buffAlways", "empowerFx" }

local auras = {}        -- saved list (HeadsUpDB.auras)
local pool = {}         -- pool[i] = indicator for auras[i]
local newInd            -- indicator used for a draft that is not saved yet
local draft, editIndex, editInd
local currentSpec     -- id of the specialization being played (Blood, Frost, ...)
local function RefreshCurrentSpec()
    local index = GetSpecialization()
    currentSpec = index and (GetSpecializationInfo(index)) or nil
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
        enemyAliveEnabled = false, -- the target (a hostile one) is alive / dead ...
        enemyAlive = "yes",        -- ... "yes" = alive, "no" = dead
        -- "Buff" (e.g. Dark Succor): the ability is lit up by it. The game hides buffs in combat
        -- but not the glow, so the glow of the aura's ability is what is checked.
        buffEnabled = false,
        buffID = nil,            -- the buff chosen by the player (for the label; the glow is checked)
        buffState = "active",    -- "active" = the ability is lit up, "gone" = it is not
        empowerFx = "sunburst",  -- the effect shown while the icon is on because its ability is empowered:
                                 -- "sunburst", "flame" or "burst" (there is always one)
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
        elseif k == "showRules" and src.showRules then
            copy.showRules = {}
            for rule, on in pairs(src.showRules) do copy.showRules[rule] = on end
        elseif k == "specs" and src.specs then
            copy.specs = {}
            for id, on in pairs(src.specs) do copy.specs[id] = on end
        else
            copy[k] = src[k]
        end
    end
    return copy
end

local function FillDefaults(cfg)
    local d = NewConfig()
    for _, k in ipairs(KEYS) do
        -- (specs stays nil for older auras: they belong to every specialization)
        if cfg[k] == nil and k ~= "spellID" and k ~= "pos" and k ~= "specs" then cfg[k] = d[k] end
    end
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
local function MakeHealthCurve(op, pct)
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
        c:AddPoint(0, 1)
    else
        c:AddPoint(0, 0)
        if lo <= 1 then c:AddPoint(lo, 1) end
    end
    if lo <= 1 and hi <= 1 then c:AddPoint(hi, 0) end
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

local function MakeFx(parent)
    local fx = CreateFrame("Frame", nil, parent)
    fx:SetAllPoints(parent)
    fx:SetFrameLevel(parent:GetFrameLevel())   -- one level under the icon: it glows from behind
    fx:SetAlpha(0)
    fx.styles = {}

    -- small helpers: a texture, and the animations
    local function texture(path, r, g, b, parentFrame)
        local t = (parentFrame or fx):CreateTexture(nil, "BACKGROUND")
        t:SetTexture(path)
        t:SetBlendMode("ADD")
        t:SetVertexColor(r, g, b, 1)
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

    -- choose the style and size (the effect itself is switched on and off with the alpha of the frame)
    function fx:Apply(style, size, width, height)
        width, height = width or size, height or size
        if not self.styles[style] then style = "sunburst" end
        self.style = style
        for _, st in pairs(self.styles) do
            for _, item in ipairs(st.items) do item[1]:Hide() end
            for _, group in ipairs(st.loops) do group:Stop() end
            for _, o in ipairs(st.once or {}) do o[2]:Stop() end
        end
        local st = self.styles[style]
        for _, item in ipairs(st.items) do
            if item[1] ~= bf then item[1]:SetSize(size * item[2], size * item[2]) end
        end
        for _, t in ipairs(st.steady) do t:Show() end
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
    local cd = CreateFrame("Cooldown", nil, I2, "CooldownFrameTemplate")
    cd:SetAllPoints(I2)
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
        fx = MakeFx(B2) }
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

    local B = CreateFrame("Frame", nil, S)
    B:SetAllPoints(A)

    -- I: holds the icon picture and its cooldown swipe, so the "pulse" effect can scale
    -- just the icon while the glow ring and the text stay put.
    local I = CreateFrame("Frame", nil, B)
    I:SetAllPoints(B)

    local tex = I:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints(I)

    local cd = CreateFrame("Cooldown", nil, I, "CooldownFrameTemplate")
    cd:SetAllPoints(I)

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
            fx = MakeFx(B) },
        MakeExtraFace(R),
    }

    local hint = B:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("TOP", B, "BOTTOM", 0, -2)
    hint:SetJustifyH("CENTER")
    hint:SetText("Drag to move")
    hint:Hide()

    ind.A, ind.C, ind.E, ind.F, ind.tex, ind.cd, ind.hint = A, C, E, F, tex, cd, hint
    ind.I = I   -- the icon's own frame: its effective alpha tells whether the icon is visible
    ind.G, ind.H, ind.J = G, H, J
    ind.M, ind.P, ind.S = M, P, S
    ind.parts = { A, C, E, F, G, H, J, M, P, S, B, I, cd, R, ind.faces[2].B, ind.faces[2].I, ind.faces[2].cd,
        ind.faces[1].fx, ind.faces[2].fx, ind.faces[1].fx.top, ind.faces[2].fx.top }   -- every frame of the indicator (for the layer setting)

    A:SetScript("OnDragStart", function(self)
        if not (ind.editing or ind.preview) then return end
        ind.dragging = true
        self:StartMoving()
    end)
    A:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
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
    if not cfg or not cfg.spellID then return end
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
    return pair("combat", "out", combatNow)
        and pair("mounted", "unmounted", mounted)
        and pair("vehicle", "novehicle", inVehicle)
end

-- Switch the "Empowered effect" of a face on or off. Turning it on plays the one-time flash of the
-- styles that have one (the moment it is empowered).
local function SetFx(face, on)
    face.fx:SetAlpha(on and 1 or 0)
    if on and not face.fxOn then face.fx:Trigger() end
    face.fxOn = on and true or false
end

local function ResetFx(ind)
    ind.faces[1].fxOn = false
    ind.faces[2].fxOn = false
end

function Update(ind)
    local cfg = ind.cfg
    local A, C, E, F, G, H, J = ind.A, ind.C, ind.E, ind.F, ind.G, ind.H, ind.J
    local M, P, S = ind.M, ind.P, ind.S
    if not cfg or not cfg.spellID or cfg.class ~= playerClass
        or (cfg.hidden and not ind.editing and not ind.preview)
        or (cfg.specs and not cfg.specs[currentSpec] and not ind.editing and not ind.preview) then
        A:Hide()
        ind.R:Hide()
        ResetFx(ind)
        return
    end
    A:Show()
    ind.R:Show()
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
        ind.R:SetAlpha(0)   -- the second path stays off while placing: one icon only
        -- show the chosen Empowered effect while editing, so it can be judged
        SetFx(ind.faces[1], cfg.buffEnabled and cfg.buffState ~= "gone" and true or false)
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
    if cfg.suppressEnabled and ind.suppressUntil and GetTime() < ind.suppressUntil then
        A:SetAlpha(0)
        ResetFx(ind)
        return
    end
    local ok, err = pcall(function()
        if cfg.healthEnabled then
            A:SetAlpha(UnitHealthPercent("player", true, ind.healthCurve))
        else
            A:SetAlpha(1)
        end
        if cfg.availEnabled and ind.powerType then
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
            SetFx(ind.faces[1], false)   -- (with "ignore", the second icon carries the effect)
        end
        -- "Always show when empowered": a second icon, outside the chain of conditions above, that
        -- shows whenever the ability is lit up (the "Show it only" rules, the specs and the
        -- hide-timer were already checked at the top of this function and still apply)
        if overrides and glowSpell then
            local okR, litR = pcall(function()
                return C_SpellActivationOverlay.IsSpellOverlayed(glowSpell) and true or false
            end)
            ind.R:SetAlpha((okR and litR) and 1 or 0)
            SetFx(ind.faces[2], okR and litR and true or false)
        else
            SetFx(ind.faces[2], false)
        end
        -- "the enemy (my target) is alive / dead": needs a hostile target; none = not met
        if cfg.enemyAliveEnabled and not lingering then
            local met = false
            if UnitExists("target") and UnitCanAttack("player", "target") then
                local okDead, dead = pcall(UnitIsDead, "target")
                if okDead and not issecretvalue(dead) then
                    met = (cfg.enemyAlive == "no") == (dead and true or false)
                end
            end
            J:SetAlpha(met and 1 or 0)
        else
            J:SetAlpha(1)
        end
        -- "the ability is available": the cost part is the C frame above; here the cooldown part
        -- (the global cooldown is ignored, a charge left counts as available)
        if cfg.availEnabled and ind.cdDuration then
            M:SetAlpha(ind.cdDuration:EvaluateRemainingDuration(ind.readyCurve))
        else
            M:SetAlpha(1)
        end
        -- the main resource (runic power, mana, ...): a value wired to a display, never compared
        if cfg.powerEnabled and ind.primaryType and ind.primaryCurve then
            P:SetAlpha(UnitPowerPercent("player", ind.primaryType, false, ind.primaryCurve))
        else
            P:SetAlpha(1)
        end
        -- the second resource (runes, holy power, ...): a plain number, so we can compare it
        if cfg.secEnabled and ind.secType then
            local count = SecondaryCount(ind.secType)
            local met = count ~= nil and Compare(count, cfg.secOp, cfg.secValue or 1)
            S:SetAlpha(met and 1 or 0)
        else
            S:SetAlpha(1)
        end
    end)
    if not ok and not errorShown then
        errorShown = true
        LogError("HeadsUp Update: " .. tostring(err))
        print("|cffff8800HeadsUp:|r error: " .. tostring(err))
    end
end

-- Rebuild everything that depends on the aura's settings.
local function ApplyConfig(ind)
    local cfg = ind.cfg
    if not cfg then
        ind.A:Hide()
        ind.R:Hide()
        return
    end
    local width, height = cfg.width, cfg.height
    local big = math.max(width, height)   -- rings and effects are round: they follow the longer side
    ind.A:SetSize(width, height)
    ApplyPosition(ind)
    local effect = cfg.effect or "none"
    local strata = STRATA[cfg.layer] or STRATA[3]
    for _, face in ipairs(ind.faces) do   -- the main icon and the "always when empowered" one look the same
        -- glow ring (the artwork is about 1.75x the size of the icon it surrounds)
        face.glow:SetSize(big * 1.75, big * 1.75)
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
    -- display priority: a higher layer is drawn above the lower ones
    for _, part in ipairs(ind.parts) do part:SetFrameStrata(strata) end
    for _, face in ipairs(ind.faces) do
        face.GL:SetFrameStrata(EFFECT_STRATA[cfg.layer] or EFFECT_STRATA[3])
    end
    ind.healthCurve = MakeHealthCurve(cfg.healthOp, cfg.healthPct / 100)
    ind.enemyCurve = MakeHealthCurve(cfg.enemyOp, cfg.enemyPct / 100)
    ind.cdCurve = MakeCooldownCurve(cfg.cdState)
    ind.readyCurve = MakeCooldownCurve("ready")

    -- the player's resources: the main one is read through a curve, the second one as a number
    ind.primaryType, ind.primaryCurve, ind.secType = nil, nil, nil
    local resources = GetResources()
    if resources.primary then
        local primary = resources.primary
        local fraction = primary.percent and (cfg.powerValue / 100) or (cfg.powerValue / primary.max)
        ind.primaryType = primary.type
        ind.primaryCurve = MakeHealthCurve(cfg.powerOp, math.min(math.max(fraction, 0), 1))
    end
    if resources.secondary then
        ind.secType = resources.secondary.type
    end

    ind.powerType = nil
    if cfg.spellID then
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
        for _, face in ipairs(ind.faces) do face.fx:Apply(cfg.empowerFx, big, width, height) end
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
        elseif k == "showRules" then
            local a, b = draft.showRules or {}, saved.showRules or {}
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

    local now = GetTime()
    for i, a in ipairs(auras) do
        local ind = pool[i]
        if ind and a.class == playerClass then
            local on = {}
            if a.healthEnabled then on[#on + 1] = "health" end
            if a.enemyEnabled then on[#on + 1] = "enemyHealth" end
            if a.enemyAliveEnabled then on[#on + 1] = "enemyAlive" end
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

function HeadsUp_ClearPreviews()
    for _, ind in pairs(pool) do
        if ind.preview then
            ind.preview = false
            RefreshMouse(ind)
            Update(ind)
        end
    end
end

-- Hide / show a saved aura right away (hidden = kept, but it never appears in game).
function HeadsUp_SetHidden(index, hidden)
    if not auras[index] then return end
    hidden = hidden and true or nil
    auras[index].hidden = hidden
    if editIndex == index and draft then draft.hidden = hidden end
    ApplyConfig(GetPooled(index))
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
    table.remove(auras, index)
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

local function OnEvent(_, event, arg1, arg2, arg3)
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
        end)
    end
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- arg3 = the spell the player just cast. Start the hide-timer of every aura for it.
        local spellID = arg3
        if spellID and not issecretvalue(spellID) then
            local now = GetTime()
            ForEachIndicator(function(ind)
                local c = ind.cfg
                if c and c.suppressEnabled and c.spellID == spellID then
                    ind.suppressUntil = now + (c.suppressSeconds or 10)
                    Update(ind)
                end
            end)
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
            FillDefaults(a)
            local ind = GetPooled(i)
            ind.cfg = a
            ApplyConfig(ind)
        end
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
        or event == "UNIT_DISPLAYPOWER" then
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
driver:SetScript("OnEvent", OnEvent)

-- A cooldown running out fires no event, so auras with a cooldown condition are
-- re-checked a few times a second.
local sinceCheck = 0
driver:SetScript("OnUpdate", function(_, elapsed)
    sinceCheck = sinceCheck + elapsed
    if sinceCheck < 0.1 then return end
    sinceCheck = 0
    ForEachIndicator(function(ind)
        local cfg = ind.cfg
        if cfg and (cfg.cdEnabled or cfg.chargesEnabled or cfg.suppressEnabled or cfg.buffEnabled
            or cfg.lingerEnabled or cfg.availEnabled or cfg.secEnabled)
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
SLASH_HEADSUP1 = "/headsup"
SlashCmdList.HEADSUP = function(msg)
    if msg == "why" then HeadsUp_Why() else HeadsUp_ToggleSettings() end
end

print("|cffff8800HeadsUp|r loaded")
