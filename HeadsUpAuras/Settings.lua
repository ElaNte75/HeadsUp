-- HeadsUp Auras: settings window.
-- A wizard: the list of saved auras on the left, and on the right one step at a time
-- (Aura -> Conditions -> Ability -> Situation). The pieces (cards, rows, controls) are in UI.lua.
--
-- To add an option: find the card it belongs to in one of the Build...Page functions and add a line
-- (card:Condition or card:Field). A new group of options = a new card. A new step = a new entry in STEPS.

local UI = HeadsUpAurasUI
local C, L = UI.C, UI.L

------------------------------------------------------------
-- facts about the game (unchanged)
------------------------------------------------------------
local function GetAbilities()
    local list, seen = {}, {}
    local numLines = C_SpellBook.GetNumSpellBookSkillLines()
    for line = 2, numLines do   -- line 1 is "General", skipped
        local lineInfo = C_SpellBook.GetSpellBookSkillLineInfo(line)
        if lineInfo and not lineInfo.offSpecID then
            local first = lineInfo.itemIndexOffset + 1
            local last = lineInfo.itemIndexOffset + lineInfo.numSpellBookItems
            for i = first, last do
                local info = C_SpellBook.GetSpellBookItemInfo(i, Enum.SpellBookSpellBank.Player)
                if info and info.itemType == Enum.SpellBookItemType.Spell
                    and not info.isPassive and not info.isOffSpec
                    and info.spellID and not seen[info.spellID] then
                    seen[info.spellID] = true
                    list[#list + 1] = { id = info.spellID, name = info.name, icon = info.iconID }
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

-- What an ability can be checked for. These are fixed facts about the spell (not secret):
--   hasCost     : it costs a resource (runic power, mana, ...)
--   hasCooldown : it has a cooldown of its own (or charges)
-- If the game does not tell us, we assume yes so nothing is wrongly disabled.
local function SpellFacts(spellID)
    local hasCost, hasCooldown, maxCharges = true, true, 1
    if not spellID then return hasCost, hasCooldown, maxCharges end

    local costs = C_Spell.GetSpellPowerCost(spellID)
    if costs then
        hasCost = false
        for _, info in ipairs(costs) do
            if info.cost and (issecretvalue(info.cost) or info.cost > 0) then hasCost = true end
        end
    end

    -- charges: the maximum is never secret, so the add-on can see it by itself
    local charges = C_Spell.GetSpellCharges(spellID)
    if charges and charges.maxCharges and charges.maxCharges > 1 then
        maxCharges = charges.maxCharges
    end

    local baseCooldown = C_Spell.GetSpellBaseCooldown or GetSpellBaseCooldown
    if baseCooldown then
        local ok, ms = pcall(baseCooldown, spellID)
        if ok and type(ms) == "number" and not issecretvalue(ms) then
            hasCooldown = ms > 0 or maxCharges > 1
        end
    end
    return hasCost, hasCooldown, maxCharges
end

-- How long the effect of an ability lasts, read from its description in the spell book
-- (the description already has the player's talents worked in). Returns whole seconds,
-- or nil when the text has no duration. It is only a suggestion: the player can correct it.
local function SuggestedDuration(spellID)
    -- the game's own data first (KnownDurations.lua, made by tools/make_durations.py): the effect the ability leaves on an enemy
    local info = C_Spell.GetSpellInfo(spellID)
    local known = info and HeadsUpAurasDurations and HeadsUpAurasDurations[select(2, UnitClass("player"))]
    known = known and known[info.name]
    if known then return math.min(math.max(math.floor(known[1] + 0.5), 1), 300), true end
    local desc = C_Spell.GetSpellDescription(spellID)
    if type(desc) ~= "string" or issecretvalue(desc) or desc == "" then return nil end
    desc = desc:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):lower()
    -- best guess first: "for 10 sec", then "lasts 10 sec", then any "10 sec"
    local n = desc:match("for (%d+%.?%d*) sec")
        or desc:match("lasts? (%d+%.?%d*) sec")
        or desc:match("(%d+%.?%d*) sec")
    n = n and tonumber(n)
    if not n then return nil end
    return math.min(math.max(math.floor(n + 0.5), 1), 300)
end

-- the facts of the draft's ability, remembered until the spell book changes
local factsCache = {}
local function Facts(d)
    local id = d and d.spellID
    if not id then return true, true, 1 end
    local f = factsCache[id]
    if not f then
        local hasCost, hasCooldown, maxCharges = SpellFacts(id)
        f = { hasCost, hasCooldown, maxCharges }
        factsCache[id] = f
    end
    return f[1], f[2], f[3]
end

local function HasAbility(d) return d ~= nil and d.spellID ~= nil end
-- a debuff tracker (made with "Create debuff tracker") has no conditions about the ability or about you:
-- those rows are grey for it
-- (and so has an aura made as a "Tracker": it only follows an effect with a timer)
local function ForAbility(d)
    return d ~= nil and d.spellID ~= nil and not d.trackerOf and (d.kind or "ability") == "ability"
end

-- a tooltip: a title, a text, and (optional) a second text in grey
local function Tip(title, text, more)
    return function(tt)
        tt:AddLine(title, 1, 0.82, 0)
        tt:AddLine(text, 1, 1, 1, true)
        if more then
            tt:AddLine(" ")
            tt:AddLine(more, 0.7, 0.7, 0.7, true)
        end
    end
end

-- Has the addon seen this aura's ability light up (for the current class + spec)?
local function AbilityLearned(spellID)
    return spellID ~= nil and HeadsUpAuras_GetLearned()[spellID] ~= nil
end

-- The buffs that can make an ability light up (KnownGlows.lua: made from the game's own data by
-- tools/make_glows.py). nil when the ability is not in the list. The addon cannot see buffs in combat,
-- so it cannot tell which of them lit the ability: the names are information.
local function KnownSources(spellID)
    local forClass = HeadsUpAurasGlows and HeadsUpAurasGlows[HeadsUpAuras_GetPlayerClass()]
    return forClass and spellID and forClass[spellID] or nil
end

-- the names of those buffs, each one once, oldest first
local function SourceNames(spellID)
    local names, seen = {}, {}
    for _, buffID in ipairs(KnownSources(spellID) or {}) do
        local info = C_Spell.GetSpellInfo(buffID)
        local name = info and info.name
        if name and not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end
    return names
end

------------------------------------------------------------
-- the choices (labels)
------------------------------------------------------------
local OP_LIST = {
    { value = "<", text = "below" },
    { value = "<=", text = "equal or below" },
    { value = "=", text = "equal" },
    { value = ">=", text = "equal or above" },
    { value = ">", text = "above" },
}
local PCT_LIST = {}
for v = 1, 5 do PCT_LIST[#PCT_LIST + 1] = { value = v, text = v .. "%" } end   -- (small values: a big enemy at 5% is still a lot)
for v = 10, 100, 10 do PCT_LIST[#PCT_LIST + 1] = { value = v, text = v .. "%" } end

-- the kinds of enemy for "Target category" (several can be ticked)
local TARGET_KINDS = {
    { value = "boss", text = "Boss" },
    { value = "rare", text = "Rare" },
    { value = "elite", text = "Elite" },
    { value = "normal", text = "Normal" },
}
local YESNO_LIST = { { value = "yes", text = "Yes" }, { value = "no", text = "No" } }
local CD_LIST = { { value = "cooling", text = "on cooldown" }, { value = "ready", text = "not on cooldown" } }
local BUFF_LIST = { { value = "active", text = "active" }, { value = "gone", text = "not active" } }
local EFFECT_LIST = {
    { value = "none", text = "None" },
    { value = "glow", text = "Glow" },
    { value = "pulse", text = "Pulse" },
}
-- the effect of an icon shown because its ability is empowered (there is always one chosen)
local EMPOWER_FX_LIST = {
    { value = "auto", text = "Auto (by spec)" },
    { value = "frost", text = "Frost" },
    { value = "blood", text = "Blood" },
    { value = "poison", text = "Poison" },
    { value = "sunburst", text = "Sunburst" },
    { value = "flame", text = "Flame" },
    { value = "burst", text = "Burst" },
    { value = "none", text = "None" },
}
local LAYER_LIST = {
    { value = 5, text = "Highest" },
    { value = 4, text = "High" },
    { value = 3, text = "Normal" },
    { value = 2, text = "Low" },
    { value = 1, text = "Lowest" },
}

local function ChargesList(d)
    local _, _, maxCharges = Facts(d)
    return {
        { value = "any", text = "at least 1" },
        { value = "full", text = "all " .. maxCharges .. " (none used)" },
    }
end

-- "Show it only": in which situation the aura may show at all (the conditions then apply).
-- Several can be ticked. Inside a pair (combat / mount / vehicle) ticking only one restricts to it.
local WHEN_ORDER = { "always", "combat", "out", "mounted", "unmounted", "vehicle", "novehicle",
    "stealth", "nostealth", "solo", "inparty", "inraid", "world", "dungeon", "raidinst", "delve", "pvp" }
local WHEN_LABELS = {
    always = "Always",
    combat = "In combat", out = "Out of combat",
    mounted = "Mounted", unmounted = "Not mounted",
    vehicle = "In a vehicle", novehicle = "Not in a vehicle",
    stealth = "Stealthed", nostealth = "Not stealthed",
    solo = "Group: Solo", inparty = "Group: Party", inraid = "Group: Raid",
    world = "Place: Open world", dungeon = "Place: Dungeon", raidinst = "Place: Raid",
    delve = "Place: Delve or scenario", pvp = "Place: PvP",
}

-- Text shown on the closed dropdown: the one chosen, or how many are chosen.
local function WhenSummary(cfg)
    local count, last = 0, nil
    for _, key in ipairs(WHEN_ORDER) do
        if cfg.showRules and cfg.showRules[key] then
            count = count + 1
            last = key
        end
    end
    if count == 0 then return "Choose..." end
    if count == 1 then return WHEN_LABELS[last] end
    return count .. " selected"
end

-- Specializations: the specs of your class this aura belongs to. It only shows while you
-- play one of the ticked ones. (specs = nil on an older aura means "every spec".)
local function ClassSpecs()
    local list = {}
    local count = (GetNumSpecializations or C_SpecializationInfo.GetNumSpecializations)()
    for i = 1, count do
        local id, name = GetSpecializationInfo(i)
        if id then list[#list + 1] = { id = id, name = name } end
    end
    return list
end

local function SpecTable(cfg)   -- the draft's spec set; nil is turned into "all ticked"
    if not cfg.specs then
        cfg.specs = {}
        for _, spec in ipairs(ClassSpecs()) do cfg.specs[spec.id] = true end
    end
    return cfg.specs
end

local function SpecSummary(cfg)
    local specs = ClassSpecs()
    if not cfg.specs then return "All specs" end
    local count, last = 0, nil
    for _, spec in ipairs(specs) do
        if cfg.specs[spec.id] then
            count = count + 1
            last = spec.name
        end
    end
    if count == #specs then return "All specs" end
    if count == 0 then return "None" end
    if count == 1 then return last end
    return count .. " specs"
end

------------------------------------------------------------
-- control definitions (used by the pages below)
------------------------------------------------------------
local function Resolve(list, d)
    if type(list) == "function" then return list(d) end
    return list
end

local function LabelOf(list, value)
    for _, o in ipairs(list) do
        if o.value == value then return o.text end
    end
    return ""
end

-- a dropdown that picks one value of a list and stores it in d[key]
local function Choice(key, list, default, extra)
    local function get(d)
        local v = d[key]
        if v == nil then v = default end
        return v
    end
    local def = {
        type = "dropdown",
        text = function(d)
            local label = LabelOf(Resolve(list, d), get(d))
            return label ~= "" and label or tostring(get(d))
        end,
        items = function(d)
            local items = {}
            for _, o in ipairs(Resolve(list, d)) do
                items[#items + 1] = {
                    text = o.text,
                    selected = function() return get(d) == o.value end,
                    onClick = function()
                        d[key] = o.value
                        UI.Changed()
                        if extra and extra.onPick then extra.onPick(o.value) end
                    end,
                }
            end
            return items
        end,
    }
    for k, v in pairs(extra or {}) do def[k] = v end
    return def
end

-- a number box that stores a whole number between lo and hi in d[key]
local function Number(key, lo, hi, default, unit)
    return {
        type = "input", numeric = true, maxLetters = 3, unit = unit,
        get = function(d) return d[key] or default end,
        set = function(d, v) d[key] = UI.Clamp(math.floor(v + 0.5), lo, hi) end,
    }
end

------------------------------------------------------------
-- the window
------------------------------------------------------------
local HEADER_H, FOOTER_H, LIST_W, TAB_H = 48, 52, 230, 36
local WIN_W, WIN_H = 730, 520
-- the page (its width follows from the grid, UI.lua) sits in the middle of the right side
local PADDING = math.floor((WIN_W - LIST_W - 1 - L.PAGE_W) / 2)
local MAIN_W = WIN_W - LIST_W - 1

local frame = UI.Box(UIParent, C.window, C.borderHi, "Frame", "HeadsUpAurasSettings")
frame:SetSize(WIN_W, WIN_H)
frame:SetPoint("CENTER")
frame:SetMovable(true)
frame:SetClampedToScreen(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
frame:SetFrameStrata("DIALOG")
frame:Hide()
tinsert(UISpecialFrames, "HeadsUpAurasSettings")   -- Esc closes it

function UI.IsOpen() return frame:IsShown() end

-- header
local header = CreateFrame("Frame", nil, frame)
header:SetPoint("TOPLEFT", 1, -1)
header:SetPoint("TOPRIGHT", -1, -1)
header:SetHeight(HEADER_H - 1)
local headerBg = header:CreateTexture(nil, "BACKGROUND")
headerBg:SetAllPoints()
headerBg:SetColorTexture(unpack(C.panel))
local headerLine = header:CreateTexture(nil, "ARTWORK")
headerLine:SetPoint("BOTTOMLEFT")
headerLine:SetPoint("BOTTOMRIGHT")
headerLine:SetHeight(1)
headerLine:SetColorTexture(unpack(C.border))

-- the version is the one written in HeadsUpAuras.toc (by hand: for example "1.2 beta")
local VERSION = (C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata)("HeadsUpAuras", "Version") or "1.2 beta"
-- where the players are asked to send their feedback: the CurseForge page of the addon.
-- (It works once the project exists with the name HeadsUp Auras on CurseForge: change the address if it differs.)
local FEEDBACK_URL = "https://www.curseforge.com/wow/addons/headsup-auras"

local titleText = UI.Text(header, 18, C.accent)
titleText:SetPoint("LEFT", header, "LEFT", 18, 0)
titleText:SetText("HeadsUp Auras")

local versionText = UI.Text(header, 11, C.muted)
versionText:SetPoint("LEFT", titleText, "RIGHT", 6, -2)
versionText:SetText(VERSION)

local whoText = UI.Text(header, 12, C.muted)
whoText:SetPoint("LEFT", versionText, "RIGHT", 18, 1)

local closeButton = UI.Button(header, "X", 26)
closeButton:SetPoint("RIGHT", header, "RIGHT", -12, 0)
closeButton:SetScript("OnClick", function() frame:Hide() end)
UI.Tip(closeButton, Tip("Close", "Closes the window (Esc does the same).", "An aura you have not saved is lost."))

------------------------------------------------------------
-- feedback: an indicator next to the X, and a message that opens when it is clicked.
-- Until it has been opened once it is bright and pulses; after that it stays as a small plain button.
------------------------------------------------------------
local feedbackButton = UI.Button(header, "Send feedback", 116, true)
feedbackButton:SetPoint("RIGHT", closeButton, "LEFT", -10, 0)
UI.Tip(feedbackButton, Tip("Feedback", "Tell us what went wrong or what you need. It helps a lot."))

local feedbackPulse = feedbackButton:CreateAnimationGroup()
feedbackPulse:SetLooping("BOUNCE")
local feedbackFade = feedbackPulse:CreateAnimation("Alpha")
feedbackFade:SetFromAlpha(1)
feedbackFade:SetToAlpha(0.55)
feedbackFade:SetDuration(0.8)
feedbackFade:SetSmoothing("IN_OUT")

local function UpdateFeedbackButton()
    local seen = HeadsUpAurasDB and HeadsUpAurasDB.feedbackSeen
    feedbackButton.primary = not seen
    feedbackButton.label:SetText(seen and "Feedback" or "Send feedback")
    feedbackButton:SetWidth(seen and 90 or 116)
    feedbackButton:Paint()
    if seen then
        feedbackPulse:Stop()
        feedbackButton:SetAlpha(1)
    else
        feedbackPulse:Play()
    end
end

local feedbackPanel = UI.Box(frame, C.window, C.accent)
feedbackPanel:SetSize(420, 196)
feedbackPanel:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", -12, -6)
feedbackPanel:SetFrameLevel(frame:GetFrameLevel() + 40)
feedbackPanel:EnableMouse(true)
feedbackPanel:Hide()

local feedbackTitle = UI.Text(feedbackPanel, 14, C.accent)
feedbackTitle:SetPoint("TOPLEFT", 16, -14)
feedbackTitle:SetText("Your feedback matters")

local feedbackBody = UI.Text(feedbackPanel, 12, C.text)
feedbackBody:SetWordWrap(true)
feedbackBody:SetJustifyV("TOP")
feedbackBody:SetPoint("TOPLEFT", feedbackTitle, "BOTTOMLEFT", 0, -10)
feedbackBody:SetWidth(388)
feedbackBody:SetText("HeadsUp Auras is in beta, and your feedback is very important to us. Tell us what problem you ran into, what you need, or which ability did not work well, so that we can make it better.")

local feedbackWhere = UI.Text(feedbackPanel, 11, C.muted)
feedbackWhere:SetPoint("BOTTOMLEFT", feedbackPanel, "BOTTOMLEFT", 16, 82)
feedbackWhere:SetText("Leave a comment on our CurseForge page (click the address, Ctrl+C):")

-- the address: it can be selected and copied, but not changed
local feedbackAddress = UI.Input(feedbackPanel, 388, { maxLetters = 200 })
feedbackAddress:SetPoint("BOTTOMLEFT", feedbackPanel, "BOTTOMLEFT", 16, 54)
feedbackAddress.edit:SetText(FEEDBACK_URL)
feedbackAddress.edit:SetCursorPosition(0)   -- show the beginning of the address, not the end
feedbackAddress.edit:SetScript("OnTextChanged", function(self, byPlayer)
    if byPlayer then
        self:SetText(FEEDBACK_URL)
        self:HighlightText()
    end
end)
feedbackPanel:SetScript("OnShow", function() feedbackAddress.edit:SetCursorPosition(0) end)
feedbackAddress.edit:HookScript("OnEditFocusGained", function(self) self:HighlightText() end)
feedbackAddress.edit:HookScript("OnMouseUp", function(self) self:HighlightText() end)

local feedbackClose = UI.Button(feedbackPanel, "Got it", 90, true)
feedbackClose:SetPoint("BOTTOMRIGHT", feedbackPanel, "BOTTOMRIGHT", -16, 14)
feedbackClose:SetScript("OnClick", function() feedbackPanel:Hide() end)

feedbackButton:SetScript("OnClick", function()
    if feedbackPanel:IsShown() then
        feedbackPanel:Hide()
        return
    end
    feedbackPanel:Show()
    if HeadsUpAurasDB then HeadsUpAurasDB.feedbackSeen = true end   -- from now on a small, plain button
    UpdateFeedbackButton()
end)

-- "Important info": why the game hides things in combat, and what HeadsUp Auras does about it (left of Feedback)
local infoButton = UI.Button(header, "Important info", 108)
infoButton:SetPoint("RIGHT", feedbackButton, "LEFT", -8, 0)
UI.Tip(infoButton, Tip("Important info", "Why some things work differently in combat, and what HeadsUp Auras does about it."))

local infoPanel = UI.Box(frame, C.window, C.accent)
infoPanel:SetSize(470, 236)
infoPanel:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", -12, -6)
infoPanel:SetFrameLevel(frame:GetFrameLevel() + 40)
infoPanel:EnableMouse(true)
infoPanel:Hide()

local infoTitle = UI.Text(infoPanel, 14, C.accent)
infoTitle:SetPoint("TOPLEFT", 16, -14)
infoTitle:SetText("Why some things work differently in combat")

local INFO_PARAGRAPHS = {
    "Since patch 12.0 (Midnight), Blizzard hides a lot of information from add-ons while you are in combat, for example the buffs and debuffs on you and on your enemy.",
    "HeadsUp Auras does its best to make things work anyway, and keeps looking for smarter ways around these limits. But the limits are real, so in some cases the result can be inaccurate.",
    "If something does not look right, please tell us with the Feedback button: it helps us find better ways.",
}
local infoBody = UI.Text(infoPanel, 12, C.text)
infoBody:SetWordWrap(true)
infoBody:SetJustifyV("TOP")
infoBody:SetSpacing(4)
infoBody:SetPoint("TOPLEFT", infoTitle, "BOTTOMLEFT", 0, -12)
infoBody:SetWidth(438)
infoBody:SetText(table.concat(INFO_PARAGRAPHS, string.char(10, 10)))

local infoClose = UI.Button(infoPanel, "Got it", 90, true)
infoClose:SetPoint("BOTTOMRIGHT", infoPanel, "BOTTOMRIGHT", -16, 14)
infoClose:SetScript("OnClick", function() infoPanel:Hide() end)

infoButton:SetScript("OnClick", function()
    if infoPanel:IsShown() then
        infoPanel:Hide()
        return
    end
    feedbackPanel:Hide()
    infoPanel:Show()
end)
feedbackButton:HookScript("OnClick", function()
    if feedbackPanel:IsShown() then infoPanel:Hide() end
end)

-- left: the saved auras
local listPanel = CreateFrame("Frame", nil, frame)
listPanel:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -HEADER_H)
listPanel:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 1, FOOTER_H + 1)   -- (the bar of the group buttons is under it)
listPanel:SetWidth(LIST_W)
local listBg = listPanel:CreateTexture(nil, "BACKGROUND")
listBg:SetAllPoints()
listBg:SetColorTexture(unpack(C.panel))
local listLine = listPanel:CreateTexture(nil, "ARTWORK")
listLine:SetPoint("TOPRIGHT")
listLine:SetPoint("BOTTOMRIGHT")
listLine:SetWidth(1)
listLine:SetColorTexture(unpack(C.border))

-- the bar under the list: it continues the line of the footer of the wizard (the buttons for the groups are in it)
local listFooter = CreateFrame("Frame", nil, frame)
listFooter:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 1, 1)
listFooter:SetSize(LIST_W, FOOTER_H)
local listFooterBg = listFooter:CreateTexture(nil, "BACKGROUND")
listFooterBg:SetAllPoints()
listFooterBg:SetColorTexture(unpack(C.panel))
local listFooterLine = listFooter:CreateTexture(nil, "ARTWORK")
listFooterLine:SetPoint("TOPLEFT")
listFooterLine:SetPoint("TOPRIGHT")
listFooterLine:SetHeight(1)
listFooterLine:SetColorTexture(unpack(C.border))
local listFooterEdge = listFooter:CreateTexture(nil, "ARTWORK")
listFooterEdge:SetPoint("TOPRIGHT")
listFooterEdge:SetPoint("BOTTOMRIGHT")
listFooterEdge:SetWidth(1)
listFooterEdge:SetColorTexture(unpack(C.border))

-- right: the wizard
local main = CreateFrame("Frame", nil, frame)
main:SetPoint("TOPLEFT", listPanel, "TOPRIGHT", 0, 0)
main:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)

local content = CreateFrame("Frame", nil, main)
content:SetPoint("TOPLEFT", main, "TOPLEFT", PADDING, -(TAB_H + 12))
content:SetPoint("BOTTOMRIGHT", main, "BOTTOMRIGHT", -PADDING, FOOTER_H + 8)

------------------------------------------------------------
-- the icon picker (pages of icons, docked to the left of the window)
------------------------------------------------------------
local ICON_COLS, ICON_ROWS, ICON_CELL = 8, 6, 38
local ICONS_PER_PAGE = ICON_COLS * ICON_ROWS
local iconList, iconPage = {}, 1
local pickerButtons = {}

local picker = UI.Box(frame, C.window, C.borderHi, "Frame", "HeadsUpAurasIconPicker")
picker:SetSize(ICON_COLS * ICON_CELL + 28, 36 + ICON_ROWS * ICON_CELL + 56)
picker:SetPoint("TOPRIGHT", frame, "TOPLEFT", -6, 0)
picker:EnableMouse(true)
picker:EnableMouseWheel(true)
picker:Hide()
tinsert(UISpecialFrames, "HeadsUpAurasIconPicker")

local pickerTitle = UI.Text(picker, 13, C.accent)
pickerTitle:SetPoint("TOPLEFT", 14, -11)
pickerTitle:SetText("Choose icon")

local pickerClose = UI.Button(picker, "X", 26)
pickerClose:SetPoint("TOPRIGHT", -8, -7)
pickerClose:SetScript("OnClick", function() picker:Hide() end)

local pageText = UI.Text(picker, 11, C.muted, "CENTER")
pageText:SetPoint("BOTTOM", picker, "BOTTOM", 0, 44)
pageText:SetWidth(200)

-- The player's own abilities first, then every icon the game offers for macros.
local function BuildIconList()
    local list, seen = {}, {}
    local function add(icon)
        if type(icon) == "string" and not icon:find("\\") then icon = "Interface\\Icons\\" .. icon end
        if icon and not seen[icon] then
            seen[icon] = true
            list[#list + 1] = icon
        end
    end
    for _, a in ipairs(GetAbilities()) do add(a.icon) end

    local found = false
    if IconDataProviderMixin and CreateAndInitFromMixin then
        local extra = IconDataProviderExtraType and IconDataProviderExtraType.Spell
        local ok, provider = pcall(CreateAndInitFromMixin, IconDataProviderMixin, extra)
        if ok and provider then
            local n = provider:GetNumIcons() or 0
            for i = 1, n do add(provider:GetIconByIndex(i)) end
            if provider.Release then provider:Release() end
            found = n > 0
        end
    end
    if not found and GetMacroIcons then
        local t = {}
        pcall(GetMacroIcons, t)
        if GetLooseMacroIcons then pcall(GetLooseMacroIcons, t) end
        for _, v in ipairs(t) do add(v) end
    end
    return list
end

local function ShowIconPage(page)
    local pages = math.max(1, math.ceil(#iconList / ICONS_PER_PAGE))
    iconPage = math.min(math.max(page, 1), pages)
    for i = 1, ICONS_PER_PAGE do
        local btn = pickerButtons[i]
        local icon = iconList[(iconPage - 1) * ICONS_PER_PAGE + i]
        if icon then
            btn.icon = icon
            btn.tex:SetTexture(icon)
            btn:Show()
        else
            btn:Hide()
        end
    end
    pageText:SetText("Page " .. iconPage .. " / " .. pages)
end

local function PickerWheel(_, delta) ShowIconPage(iconPage - delta) end
picker:SetScript("OnMouseWheel", PickerWheel)

for i = 1, ICONS_PER_PAGE do
    local col, row = (i - 1) % ICON_COLS, math.floor((i - 1) / ICON_COLS)
    local btn = CreateFrame("Button", nil, picker)
    btn:SetSize(ICON_CELL - 4, ICON_CELL - 4)
    btn:SetPoint("TOPLEFT", 14 + col * ICON_CELL, -38 - row * ICON_CELL)
    btn.tex = btn:CreateTexture(nil, "ARTWORK")
    btn.tex:SetAllPoints()
    btn.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    btn.hl = btn:CreateTexture(nil, "OVERLAY")
    btn.hl:SetAllPoints()
    btn.hl:SetColorTexture(1, 1, 1, 0.28)
    btn.hl:Hide()
    btn:EnableMouseWheel(true)
    btn:SetScript("OnMouseWheel", PickerWheel)
    btn:SetScript("OnEnter", function(self) self.hl:Show() end)
    btn:SetScript("OnLeave", function(self) self.hl:Hide() end)
    btn:SetScript("OnClick", function(self)
        local d = HeadsUpAuras_GetDraft()
        if d then
            d.icon = self.icon
            UI.Changed()
        end
        picker:Hide()
    end)
    pickerButtons[i] = btn
end

local function PickerNav(label, x, delta)
    local b = UI.Button(picker, label, 38)
    b:SetPoint("BOTTOMLEFT", picker, "BOTTOMLEFT", x, 14)
    b:SetScript("OnClick", function() ShowIconPage(iconPage + delta) end)
end
PickerNav("<<", 14, -10)
PickerNav("<", 56, -1)
PickerNav(">", 98, 1)
PickerNav(">>", 140, 10)

local useOwnIcon = UI.Button(picker, "Ability icon", 110)
useOwnIcon:SetPoint("BOTTOMRIGHT", picker, "BOTTOMRIGHT", -14, 14)
useOwnIcon:SetScript("OnClick", function()
    local d = HeadsUpAuras_GetDraft()
    if d then
        d.icon = nil
        UI.Changed()
    end
    picker:Hide()
end)

-- dock the picker on the side of the window that has room: the left (as always), else the right, else over the window.
-- It is checked all the time while the picker is open, so it changes side while the window is still being dragged.
local function DockPicker()
    local room = picker:GetWidth() + 6
    local left, right = frame:GetLeft() or 0, frame:GetRight() or 0
    local side = "inside"
    if left >= room then
        side = "left"
    elseif UIParent:GetRight() - right >= room then
        side = "right"
    end
    if side == picker.side then return end
    picker.side = side
    picker:ClearAllPoints()
    if side == "left" then
        picker:SetPoint("TOPRIGHT", frame, "TOPLEFT", -6, 0)
    elseif side == "right" then
        picker:SetPoint("TOPLEFT", frame, "TOPRIGHT", 6, 0)
    else
        picker:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -HEADER_H)
    end
    picker:SetClampedToScreen(true)
end
picker:SetScript("OnUpdate", DockPicker)

local function TogglePicker()
    if picker:IsShown() then
        picker:Hide()
    else
        iconList = BuildIconList()
        ShowIconPage(1)
        DockPicker()
        picker:Show()
    end
end

------------------------------------------------------------
-- STEP 1: Aura (what we make, and how it looks)
------------------------------------------------------------
-- What the aura is: an Ability (press it now), or a Tracker (follow an effect with our own timer: a debuff
-- on the enemy, or a buff on you; the game data says which one the ability gives).
local KIND_LIST = {
    { value = "ability", text = "Ability" },
    { value = "tracker", text = "Tracker" },
    { value = "counter", text = "Counter" },
}
local KIND_SUFFIX = { ability = "", tracker = " Tracker", counter = "" }

-- { seconds, "enemy" or "self" } for an ability whose effect we know (KnownDurations.lua), else nil
local function KnownDuration(name)
    local byClass = HeadsUpAurasDurations and HeadsUpAurasDurations[select(2, UnitClass("player"))]
    return byClass and byClass[name]
end

-- the abilities offered for the kind: all of the spell book, or (Tracker) the ones whose effect we know
local function KindAbilities(d)
    local all = GetAbilities()
    if (d.kind or "ability") ~= "tracker" then return all end
    local list = {}
    for _, a in ipairs(all) do
        if KnownDuration(a.name) then list[#list + 1] = a end
    end
    return list
end

-- where the effect sits decides what the tracker looks at: an effect on the enemy needs a living enemy as target
-- (and starts over with a new target); an effect on you has no condition about the target
local function ApplySide(d, side)
    if side == "enemy" then
        d.tgtHostileEnabled, d.tgtHostile = true, "enemy"
        d.enemyAliveEnabled, d.enemyAlive = true, "yes"
        d.suppressReset = true
    else
        d.tgtHostileEnabled, d.enemyAliveEnabled = false, false
        d.suppressReset = false
    end
end

-- a bar and an icon do not start with the same size: icons 50x50, a bar 200x16 (a custom size is kept)
local function ApplyShapeSize(d, shape)
    local square = (d.width == d.height)
    if shape == "bar" then
        if square then d.width, d.height, d.sizeLinked = 200, 16, false end
    elseif not square and d.width >= 150 then
        d.width, d.height, d.sizeLinked = 50, 50, true
    end
end

local function SetKind(d, kind)
    if (d.kind or "ability") == kind then return end
    local wasCounter = (d.kind == "counter")
    d.kind = kind
    if kind == "counter" then
        -- a counter is text: every condition about abilities and the target is off, and it starts as a long, low box
        for _, key in ipairs({ "healthEnabled", "powerEnabled", "secEnabled", "cdEnabled", "chargesEnabled",
            "availEnabled", "buffEnabled", "buffAlways", "soundEnabled", "tgtHostileEnabled", "enemyAliveEnabled",
            "enemyEnabled", "tgtTypeEnabled", "tgtClassEnabled", "threatEnabled", "crowdEnabled", "formEnabled",
            "suppressEnabled", "suppressReset" }) do
            d[key] = false
        end
        d.otherAuras, d.trackShow, d.buffIgnore = nil, "hide", {}
        d.shape, d.effect = "text", "none"
        d.width, d.height, d.sizeLinked = 200, 24, false   -- (the size of a bar; the text of a counter sizes itself)
        d.ctBg, d.ctBgAlpha, d.ctSize, d.ctColor = { 0, 0, 0 }, 20, 12, { 1, 1, 1 }
        d.ctWho, d.ctChar = "all", HeadsUpAuras_CharKey()   -- (a counter is for every character, until it is set otherwise)
        d.spellID, d.itemID, d.currencyID, d.icon, d.name = nil, nil, nil, nil, nil
        d.ctType, d.ctBank = "item", false
        UI.Changed()
        return
    end
    if wasCounter then
        -- leaving a counter: it has no ability yet; the text shape goes back to an icon
        d.spellID, d.itemID, d.currencyID, d.icon, d.name = nil, nil, nil, nil, nil
        d.shape = "square"
        d.width, d.height, d.sizeLinked = 50, 50, true
    end
    if kind == "ability" then
        d.suppressEnabled, d.trackShow = false, "hide"
        d.tgtHostileEnabled, d.enemyAliveEnabled, d.suppressReset = false, false, false
        if d.shape == "bar" then d.shape = "square" end
        d.width, d.height, d.sizeLinked = 50, 50, true
    else
        -- a tracker follows an effect: only its timer and what is about the target count
        for _, key in ipairs({ "healthEnabled", "powerEnabled", "secEnabled", "cdEnabled", "chargesEnabled",
            "availEnabled", "buffEnabled", "buffAlways", "soundEnabled" }) do
            d[key] = false
        end
        d.buffIgnore = {}
        d.suppressEnabled, d.trackShow = true, "while"
        d.shape, d.effect = "square", "none"
        d.width, d.height, d.sizeLinked = 50, 50, true
    end
    -- the chosen ability may not be offered for the new kind
    if d.spellID then
        local found = false
        for _, a in ipairs(KindAbilities(d)) do
            if a.id == d.spellID then
                found = true
                if kind == "tracker" then ApplySide(d, KnownDuration(a.name)[2]) end
            end
        end
        if not found then
            d.spellID, d.icon = nil, nil
        end
    end
    UI.Changed()
end

local function SelectAbility(d, a)
    -- keep a custom name; replace an empty or automatic one
    local prev = d.spellID and C_Spell.GetSpellInfo(d.spellID)
    local current = d.name and (d.name:gsub("%s+%d+$", ""))
    local isAuto = not d.name or (prev and (current == prev.name or current == prev.name .. " Tracker"))
    if isAuto then
        -- suggest a name that is not used yet: "Death Strike 2" if needed
        d.name = HeadsUpAuras_UniqueName(a.name .. (KIND_SUFFIX[d.kind or "ability"] or ""), HeadsUpAuras_GetEditIndex())
    end
    d.spellID = a.id
    -- a condition that makes no sense for this ability is switched off
    local hasCost, hasCooldown, maxCharges = SpellFacts(a.id)
    if not (hasCost or hasCooldown) then d.availEnabled = false end
    if not hasCooldown then d.cdEnabled = false end
    if maxCharges <= 1 then d.chargesEnabled = false end
    d.icon = nil   -- a new ability starts with its own icon
    if d.kind == "tracker" then
        local known = KnownDuration(a.name)
        if known then ApplySide(d, known[2]) end
    end
    -- suggest the length of the timer: from the game's data, or from the description of the ability
    local seconds = SuggestedDuration(a.id)
    if seconds then d.suppressSeconds = seconds end
    UI.Changed()
end

-- the ability, the name and the icon buttons start this many pixels to the left of the half row,
-- so that the long names of abilities fit
local WIDE_EXTRA = 20
-- the width of those fields, and of half of it (width and height, X and Y, the two icon buttons):
-- two halves with SPLIT_GAP between them (the width / height link sits in that gap)
local SPLIT_GAP = L.PAIR_GAP   -- (the gap between two boxes is the same on every page)
local WIDE_W = L.COL_W * 3 + L.GAP * 2 + WIDE_EXTRA
local HALF_W = (WIDE_W - SPLIT_GAP) / 2

-- the first row of the Aura step: what to make (an ability, a tracker or a counter)
local function AddKindField(card)
    card:Field({
        label = "What to make",
        usable = function(d) return not d.trackerOf end,
        tip = Tip("What to make", "Ability: an icon that tells you when to press the ability. Tracker: a bar or an icon that follows the effect of an ability with a timer that starts when you cast it, and empties while the effect lasts. The effect can be on the enemy (a debuff) or on you (a buff): the addon knows which. Counter: how many of an item (cloth, ore...) you have in your bags, written on the screen.", "A tracker is an estimate: the addon cannot see the effect itself in combat."),
        controls = {
            {
                type = "dropdown", span = 3, extra = WIDE_EXTRA,
                text = function(d)
                    for _, k in ipairs(KIND_LIST) do
                        if k.value == (d.kind or "ability") then return k.text end
                    end
                    return "Ability"
                end,
                items = function(d)
                    local items = {}
                    for _, k in ipairs(KIND_LIST) do
                        items[#items + 1] = {
                            text = k.text,
                            selected = function() return (d.kind or "ability") == k.value end,
                            onClick = function() SetKind(d, k.value) end,
                        }
                    end
                    return items
                end,
            },
        },
    })
end

-- what a counter counts: the name and the picture of what is chosen (nil name = nothing chosen yet)
local function CounterItem(d)
    local id = d and HeadsUpAuras_SubjectID(d)
    if not id then return nil end
    local name, icon = HeadsUpAuras_SubjectFacts(d)
    return name or ((d.ctType == "currency" and "Currency " or "Item ") .. id), icon
end

-- the name an aura gets from its item: the name of the item, and its quality ("Imbued Bright Linen Bolt Q2"), because the
-- same name can be several items, one for each quality
local function ItemAutoName(id)
    local name = id and HeadsUpAuras_ItemFacts(id)
    if not name then return nil end
    local q = HeadsUpAuras_ItemQuality(id)
    return q and (name .. " Q" .. q) or name
end

-- choose the item of a counter: its name and its picture become the name and the picture of the aura
local function SelectItem(d, id)
    local prevName = (d.ctType ~= "currency") and d.itemID and ItemAutoName(d.itemID)
    local current = d.name and (d.name:gsub("%s+%d+$", ""))
    local isAuto = not d.name or (prevName and current == prevName)
    d.ctType, d.currencyID = "item", nil
    d.itemID = id
    d.itemUnknown = nil
    d.spellID = 0   -- (a counter has no spell: 0 only says that the aura has its subject)
    local name, icon = HeadsUpAuras_ItemFacts(id)
    d.icon = icon
    if isAuto then
        local auto = ItemAutoName(id)
        d.name = auto and HeadsUpAuras_UniqueName(auto, HeadsUpAuras_GetEditIndex()) or nil
    end
    -- the name of an item that the game does not know yet arrives a moment later
    if not name and Item and Item.CreateFromItemID then
        Item:CreateFromItemID(id):ContinueOnItemLoad(function()
            local draft = HeadsUpAuras_GetDraft()
            if draft and draft.itemID == id then
                if not draft.name then
                    draft.name = HeadsUpAuras_UniqueName(ItemAutoName(id) or ("Item " .. id), HeadsUpAuras_GetEditIndex())
                end
                draft.icon = select(2, HeadsUpAuras_ItemFacts(id)) or draft.icon
                UI.Changed()
            end
        end)
    end
    UI.Changed()
end

-- choose the currency of a counter (c = { id, name, icon })
local function SelectCurrency(d, c)
    local prevName = (d.ctType == "currency") and d.currencyID and HeadsUpAuras_SubjectFacts(d) or nil
    local current = d.name and (d.name:gsub("%s+%d+$", ""))
    local isAuto = not d.name or (prevName and current == prevName)
    d.ctType, d.itemID = "currency", nil
    d.currencyID = c.id
    d.itemUnknown = nil
    d.spellID = 0
    d.icon = c.icon
    if isAuto then d.name = HeadsUpAuras_UniqueName(c.name, HeadsUpAuras_GetEditIndex()) end
    UI.Changed()
end

-- the currency with this id, as SelectCurrency wants it
local function CurrencyOf(id)
    local info = C_CurrencyInfo.GetCurrencyInfo(id)
    return { id = id, name = info and info.name or ("Currency " .. id), icon = info and info.iconFileID }
end

-- the Aura step of a counter: what to make, what to count (an item or a currency: typed, pasted, or dragged), and its name
local function BuildCounterAuraPage(page)
    local card = page:Card("Counter")
    AddKindField(card)
    card:Field({
        label = "What to count",
        tip = Tip("What to count", "What is counted: an item or a currency. Type its name or its id, or drag it onto the box: an item from your bags, or a currency from the currency window. You can also select the box and shift+click the item or the currency.", "A name works for an item the game already knows (one in your bags) and for the currencies of this character. The row below confirms what was chosen."),
        controls = {
            {
                type = "input", span = 3, extra = WIDE_EXTRA, maxLetters = 80, noApply = true,
                get = function(d)
                    local name = CounterItem(d)
                    return name or ""
                end,
                set = function(d, text)
                    text = strtrim(text)
                    if text == "" then return end
                    local kind, id = HeadsUpAuras_ResolveSubject(text)
                    if kind == "item" then
                        if d.ctType == "currency" or id ~= d.itemID then SelectItem(d, id) end
                    elseif kind == "currency" then
                        if d.ctType ~= "currency" or id ~= d.currencyID then SelectCurrency(d, CurrencyOf(id)) end
                    else
                        d.itemUnknown = text   -- (the row below says it was not found)
                    end
                end,
                onItemDrop = function(d, id, kind)
                    if kind == "currency" then SelectCurrency(d, CurrencyOf(id)) else SelectItem(d, id) end
                end,
            },
        },
    })
    card:Condition({
        label = "Count the bank too",
        key = "ctBank",
        usable = function(d) return d.ctType ~= "currency" end,
        tip = Tip("Count the bank too", "Counts what is in your bank and your reagent bank as well as your bags.", "Only for an item. The game knows the bank only after it has been opened at least once."),
    })
    card:Field({
        label = "Counting",
        tip = Tip("Counting", "What is counted now: its picture and its name. Check that it is the one you meant.", "Right now you have this many of it: the number is shown on the right."),
        controls = {
            {
                type = "icon", text = "", w = WIDE_W, gap = 0, inert = true,
                icon = function(d)
                    local _, icon = CounterItem(d)
                    return icon
                end,
                label = function(d)
                    if d.itemUnknown then return "Not found: " .. d.itemUnknown .. " (type its id, or drag it onto the box)" end
                    local name = CounterItem(d)
                    if not name then return "Nothing chosen yet" end
                    local ok, n = pcall(HeadsUpAuras_ReadCount, d)
                    local count = "?"
                    if ok and type(n) == "number" and not issecretvalue(n) then
                        local okF, text = pcall(BreakUpLargeNumbers, n)
                        count = okF and text or n
                    end
                    local mark = ""
                    if d.ctType ~= "currency" then
                        local q = HeadsUpAuras_ItemQuality(d.itemID)
                        if q then mark = " " .. HeadsUpAuras_QualityMark(q, 14) end
                    end
                    return name .. mark .. "  (" .. count .. ")"
                end,
                onClick = function() end,
            },
        },
    })
    card:Field({
        label = "Name",
        tip = Tip("Name", "The name of the aura in the list on the left (and, in a bar, the name that is written in it).", "Two auras cannot have the same name: a number is added to the second one."),
        controls = {
            {
                type = "input", span = 3, extra = WIDE_EXTRA, maxLetters = 40, noApply = true,
                get = function(d) return d.name or "" end,
                set = function(d, text)
                    text = strtrim(text)
                    d.name = (text ~= "") and text or nil
                end,
            },
        },
    })
end

local function BuildAuraPage(page, tracker, part, counter)
    -- part: "identity" (what it is), "look" (how it looks), or nil (both, for a debuff tracker)
    -- counter: the look of a counter (text), which has fields of its own and none of the icon's
    if part ~= "look" then
        local card = page:Card(tracker and "Debuff tracker" or "Aura")

        if not tracker then
            AddKindField(card)
            card:Field({
                label = function(d)
                    local kind = d and d.kind or "ability"
                    return kind == "tracker" and "Tracker of" or "Ability"
                end,
                usable = function(d) return not d.trackerOf end,
                tip = Tip("Ability", "The ability this aura is about. The icon shows its picture. For a Tracker only the abilities whose effect we know are listed, with the length of the effect.", "Only abilities of your spellbook are listed."),
                controls = {
                    {
                        type = "dropdown", span = 3, extra = WIDE_EXTRA,
                        text = function(d)
                            local info = d.spellID and C_Spell.GetSpellInfo(d.spellID)
                            local name = info and info.name or "Choose ability"
                            return d.trackerOf and (name .. " (debuff)") or name
                        end,
                        items = function(d)
                            local items = {}
                            for _, a in ipairs(KindAbilities(d)) do
                                local known = (d.kind == "tracker") and KnownDuration(a.name)
                                items[#items + 1] = {
                                    text = known and (a.name .. " (" .. math.floor(known[1] + 0.5) .. " s)") or a.name, icon = a.icon,
                                    selected = function() return d.spellID == a.id end,
                                    onClick = function() SelectAbility(d, a) end,
                                }
                            end
                            if #items == 0 then
                                items[1] = { text = "No known abilities for this class", disabled = true }
                            end
                            return items
                        end,
                    },
                },
            })
        end

        card:Field({
            label = "Name",
            tip = Tip("Name", "The name of the aura in the list on the left.", "Two auras cannot have the same name: a number is added to the second one."),
            controls = {
                {
                    type = "input", span = 3, extra = WIDE_EXTRA, maxLetters = 40, noApply = true,
                    get = function(d) return d.name or "" end,
                    set = function(d, text)
                        text = strtrim(text)
                        d.name = (text ~= "") and text or nil
                    end,
                },
            },
        })

        card:Field({
            label = "Icon",
            tip = Tip("Icon", "The picture of the icon. It is the picture of the ability, unless you choose another one."),
            usable = HasAbility,
            controls = {
                {
                    type = "icon", text = "Choose", w = HALF_W, gap = SPLIT_GAP,
                    tip = Tip("Choose", "Pick a different picture for the icon, from the pictures of the game."),
                    icon = function(d) return d.icon or (d.spellID and C_Spell.GetSpellTexture(d.spellID)) end,
                    onClick = function() TogglePicker() end,
                },
                {
                    type = "button", text = "Ability icon", w = HALF_W,
                    tip = Tip("Ability icon", "Go back to the picture of the ability itself.", "Grey while you have not chosen another picture."),
                    enabled = function(d) return d.icon ~= nil end,
                    onClick = function(d)
                        d.icon = nil
                        UI.Changed()
                    end,
                },
            },
        })
    end

    if part ~= "identity" then
        local look = page:Card("Appearance")
        if counter then
            -- first what the counter is (text, an icon with the number on it, or a bar), then what is written in it
            local SHAPES = { { value = "text", text = "Text" }, { value = "square", text = "Square icon" },
                { value = "round", text = "Round icon" }, { value = "bar", text = "Bar" } }
            local PLACES = { { value = "off", text = "Off" }, { value = "left", text = "Left" },
                { value = "center", text = "Middle" }, { value = "right", text = "Right" } }
            local function isBar(d) return d.shape == "bar" end   -- (only a bar has room for the picture and the name)
            look:Field({
                label = "Shape",
                usable = HasAbility,
                tip = Tip("Shape", "Text: only the number, in a box that is as big as the number (its background can be changed or taken away). Square icon / Round icon: the picture of the item with the number written on it. Bar: a long box in which the picture, the name and the number are written.", "An icon has no room for the name: it shows the picture and the number only."),
                controls = { Choice("shape", SHAPES, "text", {
                    -- an icon starts at 40x40 and a bar at 200x24 (a size that was chosen is kept)
                    onPick = function(value)
                        local d = HeadsUpAuras_GetDraft()
                        if not d then return end
                        if value == "square" or value == "round" then
                            if d.width ~= d.height then d.width, d.height, d.sizeLinked = 40, 40, true end
                        elseif value == "bar" and d.width == d.height then
                            d.width, d.height, d.sizeLinked = 200, 24, false
                        end
                        UI.Changed()
                    end,
                }) },
            })
            look:Field({
                label = "Icon",
                usable = isBar,
                tip = Tip("Icon", "The icon of the item, at one end of the bar: as high as the bar. Choose the end, or Off to leave it out.", "Only for a bar. Grey for Text (only the number) and for an icon (the icon is the picture)."),
                controls = { Choice("ctIcon", { PLACES[1], PLACES[2], PLACES[4] }, "left") },
            })
            look:Field({
                label = "Name",
                usable = isBar,
                tip = Tip("Name", "The name written in the bar: the Name you gave the aura on the Aura step (by default the real name of the item, so you can change it). Choose where it is written, or Off to write only the number.", "Only for a bar. The addon measures the room: the name never covers the number, and a name that is too long is cut short with dots."),
                controls = { Choice("ctName", PLACES, "left") },
            })
            look:Field({
                label = "Number",
                usable = isBar,
                tip = Tip("Number", "How many you have in your bags. Choose where it is written in the bar: left, in the middle or on the right.", "A counter always writes its number. In Text and on an icon it is in the middle."),
                controls = { Choice("ctNum", { PLACES[2], PLACES[3], PLACES[4] }, "right") },   -- (no Off: a counter always writes its number)
            })
            look:Field({
                label = "Background",
                usable = function(d) return d.shape == "text" or d.shape == "bar" end,
                tip = Tip("Background", "The color of the box behind the text or the bar. Click the square to choose any color from a small palette.", "How solid it is, you choose below (Background opacity). Grey for an icon: the picture is its background."),
                controls = {
                    {
                        type = "color", w = UI.DropdownWidth(), gap = 0,
                        get = function(d) return d.ctBg or { 0, 0, 0 } end,
                        set = function(d, rgb) d.ctBg = rgb end,
                    },
                },
            })
            local OPACITIES = {}
            for pct = 0, 100, 10 do OPACITIES[#OPACITIES + 1] = { value = pct, text = pct .. "%" } end
            look:Field({
                label = "Background opacity",
                usable = function(d) return d.shape == "text" or d.shape == "bar" end,
                tip = Tip("Background opacity", "How solid the background is, in percent: 0% is no background at all (only the text shows), 100% is a solid box, in between you see through it.", "Grey for an icon."),
                controls = { Choice("ctBgAlpha", OPACITIES, 20) },
            })
            look:Field({
                label = "Text size",
                tip = Tip("Text size", "The size of the text, in pixels (from 8 to 64).", "The box (Size below) must be big enough for the text."),
                controls = { Number("ctSize", 8, 64, 12, "px") },
            })
            look:Field({
                label = "Text color",
                tip = Tip("Text color", "The color of the text. Click the square to choose any color from a small palette."),
                controls = {
                    {
                        type = "color", w = UI.DropdownWidth(), gap = 0,
                        get = function(d) return d.ctColor or { 1, 1, 1 } end,
                        set = function(d, rgb) d.ctColor = rgb end,
                    },
                },
            })
        end
        if not counter then look:Field({
            label = "Shape",
            usable = HasAbility,
            tip = Tip("Shape", "Square: the icon as it is. Round: the picture cut to a circle, with a rim that follows the Empowered effect (frost, blood, poison...), so that icon and effect look like one thing. Bar: a progress bar that empties while the effect lasts (Tracker).", "A round icon is as wide as it is high (the larger of the two sizes)."),
            controls = { Choice("shape", function(d)
                local list = { { value = "square", text = "Square icon" }, { value = "round", text = "Round icon" } }
                -- any tracker can be a bar (an old aura sees new options too, nothing is changed for it)
                if (d.kind or "ability") ~= "ability" or d.trackerOf then
                    list[#list + 1] = { value = "bar", text = "Progress bar" }
                end
                return list
            end, "square", {
                -- a bar and an icon do not start with the same size
                onPick = function(value)
                    local d = HeadsUpAuras_GetDraft()
                    if d then
                        ApplyShapeSize(d, value)
                        UI.Changed()
                    end
                end,
            }) },
        }) end
        -- width x height; while they are linked (the default), changing one changes the other.
        -- Every box of this page is as wide as a standard dropdown (SLOT_W), and the gap between two boxes is always L.GAP.
        local SLOT_W = UI.DropdownWidth()
        -- two boxes side by side (width and height, X and Y) are each as wide as a standard dropdown, and the
        -- gap between them is always the same: just wide enough for the "=" button that sits in it
        local LINK_PAD = (L.PAIR_GAP - L.CTRL_H) / 2
        local PAIR_GAP = L.PAIR_GAP
        local BOX_W = SLOT_W   -- the right box is exactly as wide as a dropdown, so their edges line up
        local function dimension(key, other, unit, gap)
            return {
                type = "input", numeric = true, maxLetters = 3, unit = unit, w = BOX_W, gap = gap,
                get = function(d) return d[key] end,
                set = function(d, v)
                    v = UI.Clamp(v, 16, 256)
                    d[key] = v
                    if d.sizeLinked then d[other] = v end
                end,
            }
        end
        look:Field({
            label = "Size",
            usable = function(d) return not (d.kind == "counter" and d.shape == "text") end,   -- (a text box is as big as its number)
            tip = Tip("Size", "The width and the height of the icon, the bar or the box, in pixels (W and H).", "Click the = between them to set them separately. Grey for the Text of a counter: its box is as big as the number."),
            controls = {
                dimension("width", "height", "W", LINK_PAD),
                {
                    type = "link", textOn = "=", textOff = "x", w = L.CTRL_H, gap = LINK_PAD,   -- "=": linked, "x": separate
                    active = function(d) return d.sizeLinked end,
                    onClick = function(d)
                        d.sizeLinked = not d.sizeLinked
                        if d.sizeLinked then d.height = d.width end   -- linked again: back to a square
                        UI.Changed()
                    end,
                    tip = function(tt, d)
                        tt:AddLine("Width x height, in pixels", 1, 0.82, 0)
                        if d and d.sizeLinked then
                            tt:AddLine("Linked: changing one changes the other, so the icon stays square.", 1, 1, 1, true)
                            tt:AddLine("Click the = to set them separately (it becomes an x).", 0.7, 0.7, 0.7, true)
                        else
                            tt:AddLine("Separate: width and height are set on their own. A picture that is not square is cut, not stretched.", 1, 1, 1, true)
                            tt:AddLine("Click the x to link them again (it becomes an =, and the height becomes the width).", 0.7, 0.7, 0.7, true)
                        end
                    end,
                },
                dimension("height", "width", "H", 0),
            },
        })

        -- where it is on the screen: the distance of the icon's centre from the centre of the screen.
        -- Dragging the icon with the mouse changes these numbers too (HeadsUpAuras_PositionChanged below).
        -- X and Y share the width of the wide fields above (ability, name): half each
        -- how far the centre may go so that the whole icon stays on the screen
        local function limits(d)
            local x = math.floor(UIParent:GetWidth() / 2 - (d.width or 50) / 2)
            local y = math.floor(UIParent:GetHeight() / 2 - (d.height or 50) / 2)
            return math.max(x, 0), math.max(y, 0)
        end
        local function positionTip(tt, d)
            tt:AddLine("Position", 1, 0.82, 0)
            tt:AddLine("Where the icon is: the distance of its centre from the centre of the screen, in pixels (0 and 0 is the centre).", 1, 1, 1, true)
            tt:AddLine(" ")
            tt:AddLine("X: to the right. A minus number (like -200) moves it to the left.", 1, 1, 1, true)
            tt:AddLine("Y: upwards. A minus number (like -200) moves it down.", 1, 1, 1, true)
            if d then
                local lx, ly = limits(d)
                tt:AddLine(" ")
                tt:AddLine("On your screen, with this size: X from -" .. lx .. " to " .. lx .. ", Y from -" .. ly .. " to " .. ly .. ". Beyond that the icon would leave the screen.", 0.4, 1, 0.4, true)
            end
            tt:AddLine(" ")
            tt:AddLine("You can also drag the icon with the mouse while this window is open: the numbers follow.", 0.7, 0.7, 0.7, true)
        end
        local function coordinate(index, unit)
            return {
                type = "input", signed = true, maxLetters = 5, unit = unit, w = BOX_W, gap = (index == 1) and PAIR_GAP or 0,
                tip = positionTip,
                get = function() return math.floor((select(index, HeadsUpAuras_GetPosition())) + 0.5) end,
                set = function(d, v)
                    local x, y = HeadsUpAuras_GetPosition()
                    local lx, ly = limits(d)
                    if index == 1 then
                        x = UI.Clamp(math.floor(v + 0.5), -lx, lx)
                    else
                        y = UI.Clamp(math.floor(v + 0.5), -ly, ly)
                    end
                    HeadsUpAuras_SetPosition(x, y)
                end,
            }
        end
        look:Field({
            label = "Position",
            tip = positionTip,
            usable = HasAbility,
            controls = { coordinate(1, "X"), coordinate(2, "Y") },
        })

        if not counter then look:Field({
            label = "Bar empties toward",
            usable = function(d) return HasAbility(d) and d.shape == "bar" end,
            tip = Tip("Bar direction", "Left: the bar shrinks toward the left side. Right: it shrinks toward the right side."),
            controls = { Choice("barDrain", { { value = "left", text = "Left" }, { value = "right", text = "Right" } }, "left") },
        })
        look:Field({
            label = "Bar color",
            usable = function(d) return HasAbility(d) and d.shape == "bar" end,
            tip = Tip("Bar color", "The color of the bar. Click the square to choose any color from a small palette."),
            controls = {
                {
                    type = "color", w = SLOT_W, gap = 0,
                    get = function(d) return d.barColor or { 1, 0.56, 0.12 } end,
                    set = function(d, rgb) d.barColor = rgb end,
                },
            },
        })
        local function barUsable(d) return HasAbility(d) and d.shape == "bar" end
        look:Condition({
            label = "Show the time", key = "barTimeOn", usable = barUsable,
            tip = Tip("Show the time", "Writes the seconds that are left on the bar. Choose where: at the left end, in the middle or at the right end."),
            controls = { Choice("barTime", { { value = "left", text = "Left" }, { value = "center", text = "Middle" }, { value = "right", text = "Right" } }, "right") },
        })
        look:Condition({
            label = "Show the icon", key = "barIconOn", usable = barUsable,
            tip = Tip("Show the icon", "A small picture of the ability at one end of the bar. Choose the side."),
            controls = { Choice("barIcon", { { value = "left", text = "Left" }, { value = "right", text = "Right" } }, "left") },
        })
        look:Field({
            label = "Show effect",
            tip = Tip("Show effect", "A ring around the icon, whenever the icon shows. It works on its own: the Empowered effect below is a separate thing and can be used together with it, or instead of it.", "None: nothing.  Glow: a pulsing ring.  Pulse: a pulsing ring, and the icon breathes."),
            usable = function(d) return HasAbility(d) and d.shape ~= "bar" end,
            controls = { Choice("effect", EFFECT_LIST, "none") },
        }) end
        if not tracker and not counter then
            look:Field({
                label = "Empowered effect",
                usable = ForAbility,
                tip = function(tt)
                    tt:AddLine("Empowered effect", 1, 0.82, 0)
                    tt:AddLine("The effect behind the icon while it is shown because its ability is empowered (the Empowered row, on the Ability page). The icon looks plain the rest of the time.", 1, 1, 1, true)
                    tt:AddLine(" ")
                    tt:AddLine("Sunburst: turning golden stars.", 0.7, 0.7, 0.7)
                    tt:AddLine("Flame: flickering orange rings.", 0.7, 0.7, 0.7)
                    tt:AddLine("Burst: a flash when it lights up, then a soft glow.", 0.7, 0.7, 0.7)
                end,
                controls = { Choice("empowerFx", EMPOWER_FX_LIST, "auto") },
            })
            -- the soft light of the themed effects (frost, blood, poison); the Show effect ring above is separate
            look:Field({
                label = "Empowered light",
                usable = function(d)
                    local style = HeadsUpAuras_ResolveFx(d)
                    return ForAbility(d) and (style == "frost" or style == "blood" or style == "poison")
                end,
                tip = Tip("Empowered light", "The soft coloured light behind a themed Empowered effect (Frost, Blood, Poison). Off: the effect keeps its icicles, splashes and bubbles but not the light, so the Show effect ring above can be the only glow.", "Show effect (the ring) and Empowered effect work independently: use both, one of them, or none."),
                controls = { Choice("empowerLight", { { value = "on", text = "On" }, { value = "off", text = "Off" } }, "on") },
            })
        end
        look:Field({
            label = "Display priority",
            usable = HasAbility,
            tip = function(tt)
                tt:AddLine("Display priority", 1, 0.82, 0)
                tt:AddLine("When two auras overlap, the one with the higher priority is drawn on top.", 1, 1, 1, true)
            end,
            controls = { Choice("layer", LAYER_LIST, 3) },
        })
    end
end

------------------------------------------------------------
-- STEP 2: Conditions (what the aura looks at)
------------------------------------------------------------
local function BuildConditionsPage(page)
    ---------------------------------------------------------------
    -- You: the player
    ---------------------------------------------------------------
    local you = page:Card("Player")
    you:Condition({
        label = "Health is:", key = "healthEnabled", usable = ForAbility,
        tip = Tip("Player health", "Shows the icon only while your health compares like this with the percent you choose.", "Example: below 85%."),
        controls = { Choice("healthOp", OP_LIST, "<"), Choice("healthPct", PCT_LIST, 80) },
    })

    -- the resources of your class: they change with the class (runic power and runes for a
    -- Death Knight, mana and holy power for a Paladin, ...)
    you:Condition({
        label = function()
            local primary = HeadsUpAuras_GetResources().primary
            return (primary and primary.name or "Resource") .. " is:"
        end,
        key = "powerEnabled",
        tip = Tip("Main resource", "Your main resource (Runic Power, Mana, Rage...): it follows your class.", "Mana is compared in percent, the others in points."),
        usable = function(d) return ForAbility(d) and HeadsUpAuras_GetResources().primary ~= nil end,
        controls = {
            Choice("powerOp", OP_LIST, "<"),
            Choice("powerValue", function()
                local primary = HeadsUpAuras_GetResources().primary
                local list = {}
                if primary and primary.percent then   -- mana: a percent
                    for v = 10, 100, 5 do list[#list + 1] = { value = v, text = v .. "%" } end
                else
                    for v = 5, primary and primary.max or 100, 5 do
                        list[#list + 1] = { value = v, text = tostring(v) }
                    end
                end
                return list
            end, 40),
        },
    })
    you:Condition({
        label = function()
            local second = HeadsUpAuras_GetResources().secondary
            return second and (second.name .. ":") or "No second resource for your class"
        end,
        key = "secEnabled",
        tip = Tip("Second resource", "Your second resource, if your class has one: ready Runes, Holy Power, Combo Points, Soul Shards, Chi...", "It follows your class. The points you have right now are compared with the number you choose."),
        usable = function(d) return ForAbility(d) and HeadsUpAuras_GetResources().secondary ~= nil end,
        controls = {
            Choice("secOp", OP_LIST, ">="),
            Choice("secValue", function()
                local second = HeadsUpAuras_GetResources().secondary
                local list = {}
                for v = 0, second and second.max or 5 do list[#list + 1] = { value = v, text = tostring(v) } end
                return list
            end, 1),
        },
    })

    -- the forms of your class (druid: Bear, Cat, Moonkin...). A class without forms has none to choose.
    local function FormList()
        local list = { { value = 0, text = "No stance" } }
        for i = 1, GetNumShapeshiftForms() or 0 do
            local _, _, _, id = GetShapeshiftFormInfo(i)
            local name = id and C_Spell.GetSpellName(id)
            if id and name then list[#list + 1] = { value = id, text = name } end
        end
        return list
    end
    you:Condition({
        label = function()
            return "Stance is:"
        end,
        key = "formEnabled",
        tip = Tip("Stance", "Shows the icon only while you are in the stance you choose (Bear, Cat, Moonkin...), or in no stance.", "Only classes that have stances can use it; for the others it stays grey."),
        usable = function(d) return ForAbility(d) and (GetNumShapeshiftForms() or 0) > 0 end,
        controls = { Choice("formSpell", FormList, 0) },
    })

    ---------------------------------------------------------------
    -- Target: the enemy (or friend) you have selected
    ---------------------------------------------------------------
    local target = page:Card("Target")
    local NOTARGET = "With no target selected, a condition about the target is not met."
    target:Condition({
        label = "Target is a:", key = "tgtTypeEnabled", usable = HasAbility,
        tip = Tip("Player or NPC", "Shows the icon only while your target is another player, or only while it is a creature (NPC).", NOTARGET),
        controls = { Choice("tgtType", { { value = "npc", text = "NPC" }, { value = "player", text = "player" } }, "npc") },
    })
    target:Condition({
        label = "Hostility:", key = "tgtHostileEnabled", usable = HasAbility,
        tip = Tip("Hostility of the target", "Shows the icon only while your target is hostile (an enemy you can attack), friendly (one you cannot attack), or neutral (a creature that does not attack until you do, but that you can attack).", NOTARGET),
        controls = { Choice("tgtHostile", { { value = "enemy", text = "hostile" }, { value = "friend", text = "friendly" }, { value = "neutral", text = "neutral" } }, "enemy") },
    })
    target:Condition({
        label = "Enemies:", key = "crowdEnabled", usable = HasAbility,
        tip = Tip("Number of enemies", "How many enemies are around you right now, compared with the number you type: for example 'equal or above 2' is two or more. Under it you choose which enemies count.", "They are counted from the nameplates of the enemies, so those must be on (they are by default) and in view. Where the game hides them (some dungeons) the condition is ignored. It needs no target."),
        controls = { Choice("crowdOp", OP_LIST, ">="), Number("crowdN", 0, 99, 2) },
    })
    target:Field({
        label = "Enemies counted:",
        usable = function(d) return HasAbility(d) and d.crowdEnabled and true or false end,
        tip = Tip("Which enemies count", "In combat: every enemy around you that is fighting. Attacking me: only the enemies that have aggro on you (the ones that are attacking you).", "Choose 'attacking me' for what you tank or what is on you, and 'in combat' for everything that is in the fight."),
        controls = { Choice("crowdMetric", { { value = "combat", text = "in combat" }, { value = "me", text = "attacking me" } }, "combat") },
    })
    target:Condition({
        label = "Target category:",
        key = "tgtClassEnabled", usable = HasAbility,
        tip = Tip("Boss, rare, elite, normal", "Shows the icon only while your target is one of the kinds you tick. A boss is a world boss or a creature with a skull level. A rare elite counts as Rare and as Elite.", "Example: tick Rare and Boss, so it does not show on ordinary mobs. " .. NOTARGET),
        controls = {
            {
                type = "dropdown",
                text = function(d)
                    local count, last = 0, nil
                    for _, o in ipairs(TARGET_KINDS) do
                        if d.tgtClass and d.tgtClass[o.value] then count = count + 1 last = o.text end
                    end
                    if count == 0 then return "Choose..." end
                    if count == 1 then return last end
                    return count .. " selected"
                end,
                items = function(d)
                    d.tgtClass = d.tgtClass or {}
                    local items = {}
                    for _, o in ipairs(TARGET_KINDS) do
                        items[#items + 1] = {
                            text = o.text, keepOpen = true,
                            selected = function() return d.tgtClass[o.value] and true or false end,
                            onClick = function()
                                d.tgtClass[o.value] = (not d.tgtClass[o.value]) or nil
                                UI.Changed()
                            end,
                        }
                    end
                    return items
                end,
            },
        },
    })
    target:Condition({
        label = "Target is alive:", key = "enemyAliveEnabled", usable = HasAbility,
        tip = Tip("Alive or dead", "Shows the icon only while your target is alive (Yes) or dead (No).", NOTARGET),
        controls = { Choice("enemyAlive", YESNO_LIST, "yes") },
    })
    target:Condition({
        label = "Enemy health is:", key = "enemyEnabled", usable = HasAbility,
        tip = Tip("Enemy health", "Same as your health, for the enemy: your target, when you can attack it.", NOTARGET),
        controls = { Choice("enemyOp", OP_LIST, "<"), Choice("enemyPct", PCT_LIST, 80) },
    })
    target:Condition({
        label = "Aggro on me:", key = "threatEnabled", usable = HasAbility,
        tip = Tip("Aggro on me", "Yes: your target has aggro on you (it is attacking you). No: it is not attacking you. Useful for tanks, to see that an enemy is loose, and for others, to see that it turned on them.", "Only enemies you are fighting have it. " .. NOTARGET),
        controls = { Choice("threatState", YESNO_LIST, "yes") },
    })
end

local function BuildAfterCastCard(page)
    local afterCast = page:Card("After a cast")
    local hideTimer = Number("suppressSeconds", 1, 300, 10, "sec")
    afterCast:Condition({
        label = function(d) return d and d.trackerOf and "The effect lasts" or "After I cast it, hide for" end,
        key = "suppressEnabled", usable = HasAbility,
        tip = function(tt, d)
            if d and d.trackerOf then
                tt:AddLine("How long the effect lasts", 1, 0.82, 0)
                tt:AddLine("The tracker counts this many seconds from the moment you cast the ability, and shows again when they are over (the enemy has lost the effect).", 1, 1, 1, true)
                tt:AddLine("It is an estimate: the addon cannot see the debuff itself. A talent, a miss or haste can change it, so correct it if the tracker is early or late.", 0.7, 0.7, 0.7, true)
            else
                tt:AddLine("Hide after a cast", 1, 0.82, 0)
                tt:AddLine("After you cast the ability, the icon hides for this many seconds. Use it for the effect or debuff the ability leaves on the enemy: the icon comes back when it should wear off, so you cast it again.", 1, 1, 1, true)
                tt:AddLine("The time is suggested from the game's data or from the description of the ability: you can change it. It is an estimate: the addon cannot see the debuff itself.", 0.7, 0.7, 0.7, true)
            end
        end,
        controls = { hideTimer },
    })
    afterCast:Condition({
        label = "Start over on a new target", key = "suppressReset", indent = true,
        usable = function(d) return HasAbility(d) and d.suppressEnabled and true or false end,
        tip = Tip("New target", "Each enemy has its own timer. When you change target, the timer of the new enemy is shown: none if you did not hit it yet (the effect is not on it), or the time that is left if you did. Going back to an enemy you hit before continues its timer.", "The addon recognizes an enemy by its id, which it can read in combat. The timers are forgotten when the fight ends."),
    })
    afterCast:Note({
        text = function(d)
            if d and d.trackerOf then
                return "The time is suggested from the game's data: correct it if it is not right for you."
            end
            return "The hide time is suggested from the game's data or the ability's description."
        end,
    })
end

------------------------------------------------------------
-- STEP 3: Ability (cooldown, charges, empowered)
------------------------------------------------------------
local function BuildAbilityPage(page)
    local cooldown = page:Card("Availability")
    cooldown:Condition({
        label = "The ability is available", key = "availEnabled",
        usable = function(d)
            local hasCost, hasCooldown = Facts(d)
            return ForAbility(d) and (hasCost or hasCooldown)
        end,
        tip = function(tt)
            tt:AddLine("The ability is available", 1, 0.82, 0)
            tt:AddLine("You can press it right now: it is not on cooldown (the global cooldown does not count) and you have enough resource.", 1, 1, 1, true)
        end,
    })
    cooldown:Condition({
        label = "The ability is", key = "cdEnabled",
        tip = Tip("Cooldown", "Looks at the cooldown of the ability itself: on cooldown, or not.", "The short global cooldown after any ability is ignored."),
        usable = function(d)
            local _, hasCooldown = Facts(d)
            return ForAbility(d) and hasCooldown
        end,
        controls = { Choice("cdState", CD_LIST, "cooling") },
    })

    local charges = page:Card("Charges")
    local function chargesUsable(d)
        local _, _, maxCharges = Facts(d)
        return ForAbility(d) and maxCharges > 1
    end
    charges:Condition({
        label = "Charges ready", key = "chargesEnabled", usable = chargesUsable,
        tip = Tip("Charges", "For abilities that have several charges (like Death and Decay).", "At least 1: a charge is ready.  All: none of the charges is recharging."),
        controls = { Choice("chargesState", ChargesList, "any") },
    })
    charges:Note({
        text = function(d)
            if ForAbility(d) and not chargesUsable(d) then
                return "This ability has only one charge, so this row is not used."
            end
            return "For abilities with several charges."
        end,
    })

    BuildAfterCastCard(page)

    local empowered = page:Card("Empowered")
    -- needs an ability that the addon has seen light up (or one that already uses the row)
    local function empoweredUsable(d)
        return ForAbility(d)
            and (KnownSources(d.spellID) ~= nil or AbilityLearned(d.spellID) or d.buffEnabled) and true or false
    end
    empowered:Condition({
        -- once ticked, the name of what empowers the ability is added (in yellow), e.g. "Empowered: Dark Succor"
        label = function(d)
            local names = SourceNames(d.spellID)
            if d.buffEnabled and #names > 0 then
                return "Empowered: |cffffd100" .. names[1] .. "|r" .. (#names > 1 and (" +" .. (#names - 1)) or "")
            end
            return "Empowered"
        end,
        key = "buffEnabled",
        usable = empoweredUsable,
        tip = function(tt, d)
            local seen = d and d.spellID and HeadsUpAuras_GetLearned()[d.spellID]
            tt:AddLine("Empowered ability: active / not active", 1, 0.82, 0)
            tt:AddLine("Some buffs (like Dark Succor) empower an ability and make it glow.", 1, 1, 1, true)
            tt:AddLine("The aura looks at that glow on its own ability (works in combat).", 1, 1, 1, true)
            tt:AddLine(" ")
            tt:AddLine(" ")
            local names = d and SourceNames(d.spellID) or {}
            if #names > 0 then
                tt:AddLine("It can light up with: " .. table.concat(names, ", ") .. ".", 0.4, 1, 0.4, true)
                tt:AddLine("(The game does not tell which one lit it, so any of them counts.)", 0.7, 0.7, 0.7, true)
            elseif seen then
                tt:AddLine("This ability has lit up " .. seen .. " time(s) while you played: ready to use.", 0.4, 1, 0.4, true)
            else
                tt:AddLine("This ability is not known to light up, and has not been seen lighting up. Play until it is empowered once; then this row becomes available.", 1, 0.5, 0.5, true)
            end
        end,
        controls = { Choice("buffState", BUFF_LIST, "active") },
    })
    -- "Ignore while it lights up": one tick for each condition that the aura uses. While the ability is lit up the ticked conditions
    -- do not count (the others do). Only the conditions the aura really has are listed.
    local function ignoreUsable(d)
        return empoweredUsable(d) and d.buffEnabled and d.buffState ~= "gone" and true or false
    end
    empowered:Field({
        label = "Ignore while it lights up",
        usable = ignoreUsable,
        tip = function(tt, d)
            tt:AddLine("Ignore while it lights up", 1, 0.82, 0)
            tt:AddLine("When the ability lights up (empowered), tick the conditions that should not count any more. While it glows, the icon shows even if those conditions are not true. Every other condition still counts.", 1, 1, 1, true)
            tt:AddLine(" ")
            tt:AddLine("Only the conditions this aura uses are listed. \"Show it only\" (combat, mounted...) and the specializations always count.", 1, 1, 1, true)
            tt:AddLine(" ")
            tt:AddLine("Example: Death Strike with \"Your health below 80%\": tick \"Your health\" and it shows whenever it glows, even if your health is high. Leave it unticked and it shows only when it glows and your health is low.", 0.7, 0.7, 0.7, true)
        end,
        controls = {
            {
                type = "dropdown",
                text = function(d)
                    local active = HeadsUpAuras_IgnoreActive(d)
                    local n = 0
                    for _ in pairs(active or {}) do n = n + 1 end
                    return n == 0 and "Nothing" or (n .. " ticked")
                end,
                items = function(d)
                    d.buffIgnore = d.buffIgnore or {}
                    local items = {}
                    for _, item in ipairs(HeadsUpAuras_IgnoreKeys) do
                        if item.on(d) then
                            items[#items + 1] = {
                                text = item.label, keepOpen = true,
                                selected = function() return d.buffIgnore[item.key] and true or false end,
                                onClick = function()
                                    d.buffIgnore[item.key] = (not d.buffIgnore[item.key]) or nil
                                    UI.Changed()
                                end,
                            }
                        end
                    end
                    if #items == 0 then items[1] = { text = "This aura has no other conditions", disabled = true } end
                    return items
                end,
            },
        },
    })

    -- A sound the moment the icon appears. It is an option of Empowered: the lighting up of the ability is one of the
    -- few things the game lets the addon read in combat. The game hides health, the main resource, cooldown and
    -- charges, so with those conditions the addon cannot know when the icon shows (unless the second icon of
    -- "Ignore the other conditions" does it).
    local function hiddenConditions(d)
        local active = HeadsUpAuras_IgnoreActive(d)
        local function ig(key) return active and active[key] end
        local names = {}
        if d.healthEnabled and not ig("health") then names[#names + 1] = "your health" end
        if d.enemyEnabled and not ig("enemy") then names[#names + 1] = "enemy health" end
        if d.powerEnabled and not ig("power") then names[#names + 1] = "the main resource" end
        local _, hasCooldown = Facts(d)
        if d.availEnabled and hasCooldown and not ig("avail") then names[#names + 1] = "available (this ability has a cooldown)" end
        if d.cdEnabled and not ig("cooldown") then names[#names + 1] = "cooldown" end
        if d.chargesEnabled and not ig("charges") then names[#names + 1] = "charges" end
        if d.otherAuras and d.otherAuras[1] and not ig("others") then names[#names + 1] = "the other auras it is combined with" end
        return names
    end
    local function overrides(d) return HeadsUpAuras_IgnoreActive(d) ~= nil end
    local function soundUsable(d)
        if not (ForAbility(d) and d.buffEnabled and d.buffState ~= "gone") then return false end
        return #hiddenConditions(d) == 0 and true or false
    end
    local soundList = {}
    for _, item in ipairs(HeadsUpAurasSounds) do soundList[#soundList + 1] = { value = item.key, text = item.text } end

    empowered:Condition({
        label = "Play a sound when it shows",
        key = "soundEnabled",
        indent = true,
        usable = soundUsable,
        tip = function(tt, d)
            tt:AddLine("Play a sound when it shows", 1, 0.82, 0)
            tt:AddLine("A short sound the moment the icon appears because the ability is empowered. Choose the sound in the list: it plays once so you can hear it.", 1, 1, 1, true)
            tt:AddLine(" ")
            tt:AddLine("With conditions ticked in \"Ignore while it lights up\" it sounds when the ability lights up and the other conditions hold. Otherwise it works only if the other conditions can be read in combat (the second resource, the enemy alive, \"available\" for an ability without a cooldown).", 0.7, 0.7, 0.7, true)
            if d and d.buffEnabled and d.buffState ~= "gone" then
                local names = hiddenConditions(d, overrides(d))
                if #names > 0 then
                    tt:AddLine(" ")
                    tt:AddLine("Not available now: the game hides " .. table.concat(names, ", ") .. " in combat. Remove them, or tick them in \"Ignore while it lights up\".", 1, 0.5, 0.5, true)
                end
            end
        end,
        controls = { Choice("soundKey", soundList, "ding", {
            onPick = function(key)
                local d = HeadsUpAuras_GetDraft()
                HeadsUpAuras_PlaySound(key, d and d.soundVolume or 2)
            end,
        }) },
    })
    empowered:Field({
        label = "Sound volume",
        usable = function(d) return soundUsable(d) and d.soundEnabled end,
        tip = Tip("Sound volume", "Soft, normal or loud. Our own sounds have a file for each level. The sounds of the game (Game: ...) have no volume, so a higher level plays them two or three times at once.", "The overall volume still follows the Master volume of the game."),
        controls = { Choice("soundVolume", {
            { value = 1, text = "Soft" },
            { value = 2, text = "Normal" },
            { value = 3, text = "Loud" },
        }, 2, {
            onPick = function(volume)
                local d = HeadsUpAuras_GetDraft()
                if d then HeadsUpAuras_PlaySound(d.soundKey, volume) end
            end,
        }) },
    })
end

-- the page of a debuff tracker: only the timer
local function BuildTimerPage(page, withCue)
    BuildAfterCastCard(page)
    local showing = page:Card("When it shows")
    showing:Field({
        label = "Show it",
        usable = HasAbility,
        tip = Tip("When the effect is shown", "While it lasts: it shows from the moment you cast the ability until the timer ends (a bar that empties). When it is gone: it shows after the timer ended, to remind you that the enemy lost the effect.", "A bar is usually shown while the effect lasts."),
        controls = { Choice("trackShow", { { value = "while", text = "while it lasts" }, { value = "hide", text = "when it is gone" } }, "hide") },
    })
    if not withCue then return end
    local cue = page:Card("The ability")
    cue:Condition({
        label = function(d)
            local name = "the ability"
            for _, a in ipairs(HeadsUpAuras_GetAuras()) do
                if d and a.uid and a.uid == d.trackerOf then name = a.name or name end
            end
            return "When it ends, show |cffffd100" .. name .. "|r"
        end,
        key = "trackerCue", usable = function(d) return d ~= nil and d.trackerOf ~= nil end,
        tip = Tip("Show the ability again", "While the timer of this tracker runs, the aura this tracker was made from waits. When the timer ends (the effect is gone), that aura shows again, so you cast it again. The two tell each other when to show.", "Untick it if the aura should not wait for the tracker."),
    })
end

------------------------------------------------------------
-- STEP 4: Situation (when and for whom it shows)
------------------------------------------------------------
local function BuildSituationPage(page, counter)
    local when = page:Card("When it shows")
    when:Condition({
        label = "Show it only",
        get = function(d) return d.showWhenEnabled end,
        set = function(d, v)
            d.showWhenEnabled = v and true or false
            if not d.showWhenEnabled then
                d.showRules = { always = true }   -- unticking forgets the choices: back to "Always"
            end
        end,
        usable = HasAbility,
        tip = function(tt, d)
            tt:AddLine("Shown only when:", 1, 0.82, 0)
            local any = false
            for _, key in ipairs(WHEN_ORDER) do
                if d and d.showWhenEnabled and d.showRules and d.showRules[key] then
                    tt:AddLine(WHEN_LABELS[key], 1, 1, 1)
                    any = true
                end
            end
            if not any then tt:AddLine("Always", 0.6, 0.6, 0.6) end
        end,
        controls = {
            {
                type = "dropdown",
                text = function(d) return d.showWhenEnabled and WhenSummary(d) or "Always" end,
                items = function(d)
                    d.showRules = d.showRules or {}
                    local items = {}
                    for _, key in ipairs(WHEN_ORDER) do
                        items[#items + 1] = {
                            text = WHEN_LABELS[key], keepOpen = true,
                            selected = function() return d.showRules[key] and true or false end,
                            onClick = function()
                                local rules = d.showRules
                                if not rules[key] then
                                    -- "Always" excludes every other choice, and any other choice excludes "Always"
                                    if key == "always" then
                                        for k in pairs(rules) do rules[k] = nil end
                                    else
                                        rules.always = nil
                                    end
                                    rules[key] = true
                                else
                                    rules[key] = nil
                                end
                                if next(rules) == nil then rules.always = true end   -- nothing left = "Always"
                                UI.Changed()
                            end,
                        }
                    end
                    return items
                end,
            },
        },
    })

    local function lingerUsable(d)
        local rules = d and d.showWhenEnabled and d.showRules or {}
        return HasAbility(d) and rules.combat and true or false   -- needs "In combat" ticked
    end
    when:Condition({
        label = "Keep it after combat for", key = "lingerEnabled", usable = lingerUsable,
        tip = Tip("Keep it after combat", "After the fight ends, the aura still counts as being in combat for this many seconds. Conditions about the enemy are ignored meanwhile.", "Works only with In combat ticked in Show it only."),
        controls = { Number("lingerSeconds", 1, 120, 5, "sec") },
    })
    when:Note({
        text = function(d)
            if lingerUsable(d) then
                return "After the fight the aura still counts as in combat for this long."
            end
            return "Tick Show it only, then In combat, to use this."
        end,
    })

    local who = page:Card(counter and "Characters" or "Specializations")
    if counter then
        -- who sees a counter: it has nothing to do with the spec that is played, but with who has (or collects) the item
        who:Field({
            label = "Show it for",
            usable = HasAbility,
            tip = Tip("Show it for", "Which of your characters see this counter. All my characters: every one of them. Only this character: the one that made the counter. This class: as an ability, for this class and the specializations you choose below. Characters with the profession: only those that have the profession of the item (cloth: Tailoring, ore: Mining, herbs: Herbalism...).", "The profession is taken from the kind of the item. A character that has the profession sees the counter even if it did not collect the item itself."),
            controls = { Choice("ctWho", function(d)
                local list = {
                    { value = "all", text = "All my characters" },
                    { value = "char", text = "Only this character" },
                    { value = "spec", text = "This class" },
                }
                local lines = HeadsUpAuras_ItemProfessions(d.itemID)
                if lines then
                    local names = {}
                    for _, name in pairs(lines) do names[#names + 1] = name end
                    table.sort(names)
                    list[#list + 1] = { value = "prof", text = "With " .. table.concat(names, " / ") }
                end
                return list
            end, "all") },
        })
    end
    who:Field({
        label = counter and "Specializations" or "Show it for",
        tip = Tip("Specializations", "The specializations of your class this aura belongs to. It shows only while you play one of them."),
        usable = counter and function(d) return HasAbility(d) and d.ctWho == "spec" end or HasAbility,
        controls = {
            {
                type = "dropdown",
                text = function(d) return SpecSummary(d) end,
                items = function(d)
                    local items = {}
                    for _, spec in ipairs(ClassSpecs()) do
                        items[#items + 1] = {
                            text = spec.name, keepOpen = true,
                            selected = function() return d.specs == nil or d.specs[spec.id] and true or false end,
                            onClick = function()
                                local set = SpecTable(d)
                                set[spec.id] = (not set[spec.id]) or nil
                                UI.Changed()
                            end,
                        }
                    end
                    return items
                end,
            },
        },
    })

end

------------------------------------------------------------
-- the steps (tabs) and the footer
------------------------------------------------------------
------------------------------------------------------------
-- STEP 3: Trigger (everything that decides when the aura shows, apart from the place and the group)
------------------------------------------------------------
-- this aura shows only if other auras of yours are showing / not showing (the last card of the page: it grows)
local function BuildOtherAurasCard(page)
    ---------------------------------------------------------------
    -- Other auras: this aura shows only if another aura is active / not active
    ---------------------------------------------------------------
    local others = page:Card("Combine with auras")
    local MAX_OTHERS = 3
    local function FindAuraByUid(uid)
        for _, a in ipairs(HeadsUpAuras_GetAuras()) do
            if a.uid == uid then return a end
        end
        return nil
    end
    -- put an aura into row i (the state of the row stays); the list has no holes
    local function SetOther(d, i, uid)
        d.otherAuras = d.otherAuras or {}
        local old = d.otherAuras[i]
        for n = #d.otherAuras, 1, -1 do   -- the same aura is not listed twice
            if d.otherAuras[n].uid == uid and n ~= i then
                table.remove(d.otherAuras, n)
                if n < i then i = i - 1 end
            end
        end
        d.otherAuras[math.min(i, #d.otherAuras + 1)] = { uid = uid, state = old and old.state or "inactive" }
        d._otherExtra = nil
    end
    local function ClearOther(d, i)
        if d.otherAuras and d.otherAuras[i] then
            table.remove(d.otherAuras, i)
            if #d.otherAuras == 0 then d.otherAuras = nil end
        end
    end
    -- what is wrong with row i, if anything (the three frames are shared by the rows above it)
    local function RowProblem(d, i)
        local rows = d.otherAuras or {}
        local used = 0
        for n = 1, i do
            local row = rows[n]
            if not row then return nil end
            local a = FindAuraByUid(row.uid)
            if not a then return "This aura was deleted: the row is ignored. Right-click to empty it." end
            local needs = HeadsUpAuras_CrossNeeds(row.uid, row.state)
            if not needs then
                return "This aura has several conditions about hidden values (health, cooldown, resource...): it cannot be used as 'Not active' yet."
            end
            used = used + needs
            if n == i and used > 3 then
                return "The rows above use all the room for conditions of other auras: this row is ignored."
            end
        end
        return nil
    end
    local STATES = {
        { value = "inactive", text = "Not active",
          tip = function(tt)
              tt:AddLine("Not active", 1, 0.82, 0)
              tt:AddLine("This aura shows only while the aura in the box is NOT on the screen. It waits its turn: when the other one shows, this one hides.", 1, 1, 1, true)
              tt:AddLine("Example: show the attack only while the heal is not showing.", 0.7, 0.7, 0.7, true)
          end },
        { value = "active", text = "Active",
          tip = function(tt)
              tt:AddLine("Active", 1, 0.82, 0)
              tt:AddLine("This aura shows only while the aura in the box IS on the screen right now.", 1, 1, 1, true)
              tt:AddLine("Active here means shown now. It is not the Active / Inactive of the list on the left.", 0.7, 0.7, 0.7, true)
          end },
    }
    local otherRows = {}
    for i = 1, MAX_OTHERS do
        otherRows[i] = others:Field({
            label = (i == 1) and "Only if aura:" or "And if aura:",
            usable = ForAbility,
            tip = Tip("Only if another aura is active or not", "Shows this aura only if the aura you choose is active (it is shown now) or not active. Drag an aura from the list on the left into the box, or click the box. Use it when two abilities spend the same resource and one has priority: for example, show the attack only if the heal is not active.", "Right-click the box to empty it. Click the + under the last row to add another aura."),
            controls = {
                {
                    type = "slot", span = 2,
                    info = function(d)
                        local row = d.otherAuras and d.otherAuras[i]
                        if not row then return nil end
                        local a = FindAuraByUid(row.uid)
                        if not a then return "(deleted aura)", nil, "deleted" end
                        return a.name or "Aura", a.icon or C_Spell.GetSpellTexture(a.spellID), RowProblem(d, i)
                    end,
                    items = function(d)
                        local items = {
                            { text = "None", onClick = function() ClearOther(d, i) UI.Changed() end,
                              selected = function() return not (d.otherAuras and d.otherAuras[i]) end },
                        }
                        for _, a in ipairs(HeadsUpAuras_GetAuras()) do
                            if a.uid and a.uid ~= d.uid and a.class == HeadsUpAuras_GetPlayerClass() then
                                items[#items + 1] = {
                                    text = a.name or "Aura", icon = a.icon or C_Spell.GetSpellTexture(a.spellID),
                                    selected = function() return d.otherAuras and d.otherAuras[i] and d.otherAuras[i].uid == a.uid end,
                                    onClick = function() SetOther(d, i, a.uid) UI.Changed() end,
                                }
                            end
                        end
                        return items
                    end,
                    onClear = function(d) ClearOther(d, i) end,
                    onDrop = function(d, uid) if uid ~= d.uid then SetOther(d, i, uid) end end,
                    tip = function(tt, d)
                        local row = d.otherAuras and d.otherAuras[i]
                        tt:AddLine("Aura " .. i, 1, 0.82, 0)
                        if not row then
                            tt:AddLine("Drop an aura here, or click to pick one.", 1, 1, 1, true)
                        else
                            local problem = RowProblem(d, i)
                            if problem then tt:AddLine(problem, 1, 0.5, 0.45, true) end
                            tt:AddLine("Right-click to empty the box.", 0.7, 0.7, 0.7, true)
                        end
                    end,
                },
                {
                    type = "dropdown", span = 2,
                    tip = function(tt, d)
                        local row = d and d.otherAuras and d.otherAuras[i]
                        for _, st in ipairs(STATES) do
                            if not row or (row.state or "inactive") == st.value then
                                st.tip(tt)
                                tt:AddLine("Click to choose.", 0.7, 0.7, 0.7)
                                return
                            end
                        end
                    end,
                    text = function(d)
                        local row = d.otherAuras and d.otherAuras[i]
                        if not row then return "" end
                        return row.state == "active" and "Active" or "Not active"
                    end,
                    items = function(d)
                        local row = d.otherAuras and d.otherAuras[i]
                        if not row then return { { text = "Put an aura in the box first", disabled = true } } end
                        local items = {}
                        for _, st in ipairs(STATES) do
                            items[#items + 1] = {
                                text = st.text, tip = st.tip,
                                selected = function() return (row.state or "inactive") == st.value end,
                                onClick = function() row.state = st.value UI.Changed() end,
                            }
                        end
                        return items
                    end,
                },
            },
        })
    end
    -- the "+": under the last row; it adds a row
    local plus = UI.Button(others, "+", L.CTRL_H)
    UI.Tip(plus, Tip("Add another aura", "Adds a row: this aura will also wait for another aura."))
    plus:SetScript("OnClick", function()
        local d = HeadsUpAuras_GetDraft()
        if d then
            d._otherExtra = true
            UI.Changed()
        end
    end)
    -- one row to begin with; a new row appears when the last one is filled and + is pressed. The card grows with them.
    UI.Register(function(d)
        local filled = d and d.otherAuras and #d.otherAuras or 0
        local extra = (d and d._otherExtra and filled < MAX_OTHERS) and 1 or 0
        local shown = math.min(math.max(1, filled + extra), MAX_OTHERS)
        for i = 1, MAX_OTHERS do otherRows[i]:SetShown(i <= shown) end
        local showPlus = d ~= nil and filled == shown and shown < MAX_OTHERS
        plus:SetShown(showPlus)
        local rowsHigh = shown + (showPlus and 1 or 0)
        plus:ClearAllPoints()
        plus:SetPoint("TOPLEFT", others, "TOPLEFT", L.PAD, -(L.TITLE_H + shown * L.ROW_H + (L.ROW_H - L.CTRL_H) / 2))
        local height = L.TITLE_H + rowsHigh * L.ROW_H + 8
        others:SetHeight(height)
        page.child:SetHeight(math.max(others.top + height, 10))
    end)
end

local function BuildTriggerPage(page)
    BuildConditionsPage(page)    -- you and your target
    BuildAbilityPage(page)       -- availability, cooldown, charges, empowered
    BuildOtherAurasCard(page)    -- combined with other auras (always the last card)
end

local STEPS = {
    { label = "Aura", build = function(page) BuildAuraPage(page, false, "identity") end, modes = { aura = true, follow = true },
        tip = "What the aura is: what to make (ability or tracker), the ability, its name and its picture." },
    { label = "Appearance", build = function(page) BuildAuraPage(page, false, "look") end, modes = { aura = true, follow = true },
        tip = "How it looks: the shape (icon, round icon or progress bar), the size, the place on the screen, the effects and the bar." },
    -- a Counter (text that says how many of an item are in the bags) has its own Aura and Appearance steps
    { label = "Aura", build = BuildCounterAuraPage, modes = { counter = true },
        tip = "What the counter is: what to make, the item that is counted (its id, its name, or dragged from your bags) and the name of the aura." },
    { label = "Appearance", build = function(page) BuildAuraPage(page, false, "look", true) end, modes = { counter = true },
        tip = "How it looks: where the picture, the name and the number are written, the color of the letters, the size of the letters and of the box and the place on the screen." },
    { label = "Trigger", build = BuildTriggerPage, modes = { aura = true },
        tip = "When the aura shows: you (health, resources, form), your target (enemy or friendly, category, alive, health, attacking you), the ability (available, cooldown, charges, empowered) and the other auras of yours it is combined with." },
    -- a Tracker follows an effect with a timer of its own
    { label = "Tracking", build = function(page) BuildTimerPage(page, false) end, modes = { follow = true },
        tip = "What the aura follows: how long the effect lasts, when it shows, and what starts it over." },
    { label = "Situation", build = BuildSituationPage, modes = { aura = true, follow = true },
        tip = "Where and for whom it shows: in combat, mounted, in a vehicle, stealthed, in a group, in a dungeon or raid, and for which specializations." },
    { label = "Situation", build = function(page) BuildSituationPage(page, true) end, modes = { counter = true },
        tip = "Where and for whom it shows: in combat, mounted, in a vehicle, stealthed, in a group, in a dungeon or raid, and which of your characters see the counter." },
    -- a debuff tracker has only these two steps (everything about the target is copied from its aura)
    { label = "Display", build = function(page) BuildAuraPage(page, true) end, modes = { tracker = true },
        tip = "How the tracker is shown: its name, the picture, the size, the place on the screen and the look." },
    { label = "Tracking", build = function(page) BuildTimerPage(page, true) end, modes = { tracker = true },
        tip = "What the tracker follows: how long the effect lasts on the enemy, what starts it over, and what it tells its aura." },
}
local mode = "aura"      -- "aura", "follow" (a buff or a debuff) or "tracker" (a debuff tracker of an aura)
local visible = {}       -- the steps of the current mode, in order
local currentStep = 1

local tabStrip = CreateFrame("Frame", nil, main)
tabStrip:SetPoint("TOPLEFT", main, "TOPLEFT", 0, 0)
tabStrip:SetPoint("TOPRIGHT", main, "TOPRIGHT", 0, 0)
tabStrip:SetHeight(TAB_H)
local tabLine = tabStrip:CreateTexture(nil, "ARTWORK")
tabLine:SetPoint("BOTTOMLEFT")
tabLine:SetPoint("BOTTOMRIGHT")
tabLine:SetHeight(1)
tabLine:SetColorTexture(unpack(C.border))

local SetStep   -- defined below

for _, step in ipairs(STEPS) do
    local tab = CreateFrame("Button", nil, tabStrip)
    tab.text = UI.Text(tab, 13, C.muted, "CENTER")
    tab.text:SetPoint("CENTER", 0, 1)
    tab.bar = tab:CreateTexture(nil, "OVERLAY")
    tab.bar:SetPoint("BOTTOMLEFT", 0, 0)
    tab.bar:SetPoint("BOTTOMRIGHT", 0, 0)
    tab.bar:SetHeight(2)
    tab.bar:SetColorTexture(unpack(C.accent))
    function tab:Paint()
        local selected = visible[currentStep] == step
        self.bar:SetShown(selected)
        local color = selected and C.accent or (self.hover and C.text or C.muted)
        self.text:SetTextColor(unpack(color))
    end
    tab:SetScript("OnEnter", function(self) self.hover = true; self:Paint() end)
    tab:SetScript("OnLeave", function(self) self.hover = false; self:Paint() end)
    tab:SetScript("OnClick", function()
        if not HeadsUpAuras_GetDraft() then return end   -- no aura open: nothing to change
        for i, v in ipairs(visible) do if v == step then SetStep(i) end end
    end)
    UI.Tip(tab, Tip(step.label, step.tip))
    step.tab = tab
end

-- show the tabs of the current mode, side by side
local function LayoutTabs()
    visible = {}
    for _, step in ipairs(STEPS) do
        if step.modes[mode] then visible[#visible + 1] = step end
    end
    local width = math.floor(MAIN_W / #visible)
    for i, step in ipairs(visible) do
        step.tab:ClearAllPoints()
        step.tab:SetSize(width, TAB_H)
        step.tab:SetPoint("TOPLEFT", tabStrip, "TOPLEFT", (i - 1) * width, 0)
        step.tab.text:SetText(i .. " " .. step.label)
        step.tab:Show()
    end
    for _, step in ipairs(STEPS) do
        if not step.modes[mode] then
            step.tab:Hide()
            if step.page then step.page.frame:Hide() end
        end
    end
end

for _, step in ipairs(STEPS) do
    step.page = UI.NewPage(content)
    step.build(step.page)
    step.page:Finish()
end
LayoutTabs()

-- footer: Back / Next on the left, Save on the right
local footer = CreateFrame("Frame", nil, main)
footer:SetPoint("BOTTOMLEFT", main, "BOTTOMLEFT", 0, 0)
footer:SetPoint("BOTTOMRIGHT", main, "BOTTOMRIGHT", 0, 0)
footer:SetHeight(FOOTER_H)
local footerLine = footer:CreateTexture(nil, "ARTWORK")
footerLine:SetPoint("TOPLEFT")
footerLine:SetPoint("TOPRIGHT")
footerLine:SetHeight(1)
footerLine:SetColorTexture(unpack(C.border))

-- five buttons of the same width, side by side with the same gap, across the whole width of the footer:
-- Back, Next, Cancel, Save aura, New
local FOOTER_PAD = 16
local BUTTON_W = math.floor((MAIN_W - 2 * FOOTER_PAD - 4 * L.GAP) / 5)

local backButton = UI.Button(footer, "Back", BUTTON_W)
backButton:SetPoint("LEFT", footer, "LEFT", FOOTER_PAD, 0)
backButton:SetScript("OnClick", function() SetStep(currentStep - 1) end)
UI.Tip(backButton, Tip("Back", "Goes to the previous step."))

local nextButton = UI.Button(footer, "Next", BUTTON_W)
nextButton:SetPoint("LEFT", backButton, "RIGHT", L.GAP, 0)
nextButton:SetScript("OnClick", function() SetStep(currentStep + 1) end)
UI.Tip(nextButton, Tip("Next", "Goes to the next step."))

local cancelButton = UI.Button(footer, "Cancel", BUTTON_W)
cancelButton:SetPoint("LEFT", nextButton, "RIGHT", L.GAP, 0)

local saveButton = UI.Button(footer, "Save aura", BUTTON_W, true)
saveButton:SetPoint("LEFT", cancelButton, "RIGHT", L.GAP, 0)
UI.Tip(saveButton, Tip("Save aura", "Saves the aura and adds it to the list on the left.", "If you close the window without saving, the changes are lost. Needs an ability."))

local newButton = UI.Button(footer, "New", BUTTON_W, true)
newButton:SetPoint("LEFT", saveButton, "RIGHT", L.GAP, 0)
UI.Tip(newButton, Tip("New", "Starts a new aura. Until you press New (or choose Edit on an aura of the list) nothing can be changed here.", "Grey while an aura is open: Save or Cancel it first."))
UI.Tip(cancelButton, Tip("Cancel", "Throws away everything you changed in this aura since you opened it, without saving, and closes it.", "Grey when no aura is open."))

local Refresh, RefreshList

-- Groups: "Create group" puts a tick box in front of every aura of the list; "Save", in the bar under the list, saves the ticked
-- ones as a group (see the list code below).
local groupMode, groupEditId = false, nil
local groupSel = {}             -- uid -> true: the auras that are ticked
local groupButton, groupSave    -- the two buttons under the list
local OpenGroupPosition         -- (the window that places a group: made further down)

-- how many auras of this class are in no group (a group needs at least two of them)
local function FreeAuraCount()
    local class, n = HeadsUpAuras_GetPlayerClass(), 0
    for _, a in ipairs(HeadsUpAuras_GetAuras()) do
        if HeadsUpAuras_AuraListed(a) and a.spellID and not a.group then n = n + 1 end
    end
    return n
end

-- the top of the window and the buttons that depend on the draft
-- Back and Next work only while an aura is open
local function UpdateNav()
    local open = HeadsUpAuras_GetDraft() ~= nil
    backButton:SetOn(open and currentStep > 1)
    nextButton:SetOn(open and currentStep < #visible)
end

local function UpdateChrome()
    local d = HeadsUpAuras_GetDraft()
    newButton:SetOn(d == nil and not groupMode)
    if groupButton then
        -- it says Cancel in the group mode, Edit group while a group is selected, else Create group
        local selected = (not groupMode) and HeadsUpAuras_GetMovingGroup() or nil
        groupButton.label:SetText(groupMode and "Cancel" or (selected and "Edit group" or "Create group"))
        -- a new group needs two free auras; a selected group can always be edited
        groupButton:SetOn(groupMode or (d == nil and (selected ~= nil or FreeAuraCount() >= 2)))
        local ticked = 0
        for _ in pairs(groupSel) do ticked = ticked + 1 end
        if groupMode then
            groupSave:SetOn(ticked >= 2)   -- a group has at least two auras
        else
            groupSave:SetOn(false)   -- it works only while a group is created or edited
        end
    end
    -- Save lights up only when something has changed (a new aura counts as changed once it has an ability)
    saveButton:SetOn(d ~= nil and d.spellID ~= nil and HeadsUpAuras_IsDirty())
    -- Cancel works while an aura is being edited, or a new one has something in it
    cancelButton:SetOn(d ~= nil and (HeadsUpAuras_GetEditIndex() ~= nil or HeadsUpAuras_IsDirty()))
    -- a debuff tracker has its own two steps
    local wanted = "aura"
    if d and d.trackerOf then
        wanted = "tracker"
    elseif d and d.kind == "tracker" then
        wanted = "follow"
    elseif d and d.kind == "counter" then
        wanted = "counter"
    end
    if wanted ~= mode then
        mode = wanted
        LayoutTabs()
        SetStep(1)
    end
    local specIndex = GetSpecialization()
    local specName = specIndex and select(2, GetSpecializationInfo(specIndex)) or "?"
    whoText:SetText(UnitClass("player") .. " - " .. specName)
    UpdateNav()
end

function SetStep(index)
    index = UI.Clamp(index, 1, #visible)
    UI.ClearFocus()
    UI.ClosePopup()
    currentStep = index
    for _, step in ipairs(STEPS) do
        step.page.frame:SetShown(visible[index] == step)
        step.tab:Paint()
    end
    visible[index].page.frame:SetVerticalScroll(0)
    UpdateNav()
end

UI.onChange = function()
    HeadsUpAuras_ApplyDraft()
    UI.SyncAll()
    UpdateChrome()
end

newButton:SetScript("OnClick", function()
    UI.ClearFocus()
    HeadsUpAuras_ClearPreviews()
    HeadsUpAuras_BeginEdit(nil)   -- a blank new aura
    SetStep(1)
    Refresh()
    RefreshList()
end)

cancelButton:SetScript("OnClick", function()
    UI.ClearFocus()
    picker:Hide()
    HeadsUpAuras_ClearPreviews()
    HeadsUpAuras_EndEdit()   -- (the draft is dropped: an aura being edited goes back to what was saved)
    SetStep(1)
    Refresh()
    RefreshList()
end)

saveButton:SetScript("OnClick", function()
    UI.ClearFocus()
    if HeadsUpAuras_Save() then
        print("|cffff8800HeadsUp Auras:|r aura saved")
        -- saving finishes the edit: unselect everything, nothing is open any more
        HeadsUpAuras_ClearPreviews()
        HeadsUpAuras_EndEdit()
        SetStep(1)
        Refresh()
        RefreshList()
    else
        print("|cffff8800HeadsUp Auras:|r choose an ability first")
    end
end)

function Refresh()
    UI.SyncAll()   -- (with no aura open every row is grey)
    UpdateChrome()
end

------------------------------------------------------------
-- the list of saved auras (left)
------------------------------------------------------------
local listTitle = UI.Text(listPanel, 13, C.accent)
listTitle:SetPoint("TOPLEFT", listPanel, "TOPLEFT", 14, -14)
listTitle:SetText("Active auras")

local emptyText = UI.Text(listPanel, 11, C.muted)
emptyText:SetPoint("TOPLEFT", listPanel, "TOPLEFT", 14, -46)
emptyText:SetText("No saved auras yet.")

-- Rename popup (right-click an aura in the list). Rename is saved right away.
StaticPopupDialogs["HEADSUPAURAS_RENAME"] = {
    text = "Rename aura:",
    button1 = ACCEPT,
    button2 = CANCEL,
    hasEditBox = true,
    maxLetters = 40,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnShow = function(self, data)
        local eb = self.EditBox or self.editBox
        eb:SetText(data.name or "")
        eb:HighlightText()
    end,
    OnAccept = function(self, data)
        local eb = self.EditBox or self.editBox
        HeadsUpAuras_RenameAura(data.index, strtrim(eb:GetText()))
        Refresh()
        RefreshList()
    end,
}

StaticPopupDialogs["HEADSUPAURAS_DELETE"] = {
    text = "Delete the aura \"%s\"? This cannot be undone.",
    button1 = "Delete",
    button2 = CANCEL,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnAccept = function(_, data)
        if HeadsUpAuras_DeleteAura(data.index) then
            HeadsUpAuras_EndEdit()
        end
        Refresh()
        RefreshList()
    end,
}

-- the group mode: tick boxes in the list
local function EnterGroupMode(editId)
    HeadsUpAuras_ClearPreviews()
    groupMode, groupEditId = true, editId
    wipe(groupSel)
    if editId then
        for _, i in ipairs(HeadsUpAuras_GroupMembers(editId)) do
            local a = HeadsUpAuras_GetAuras()[i]
            if a and a.uid then groupSel[a.uid] = true end
        end
    end
    groupButton.label:SetText("Cancel")
    -- editing a group: it is shown on the screen with its box and dots, and the window that places it opens too
    if editId then
        for _, i in ipairs(HeadsUpAuras_GroupMembers(editId)) do HeadsUpAuras_SetPreview(i, true) end
        HeadsUpAuras_SetGroupMove(editId)
        for _, g in ipairs(HeadsUpAuras_GetGroups()) do
            if g.id == editId then OpenGroupPosition(editId, g.name) end
        end
    end
    Refresh()
    RefreshList()
end

local function ExitGroupMode()
    HeadsUpAuras_ClearPreviews()   -- (a place that was typed and not saved goes back; the Position window closes by itself)
    groupMode, groupEditId = false, nil
    wipe(groupSel)
    groupButton.label:SetText("Create group")
    Refresh()
    RefreshList()
end

-- the buttons in the bar under the list
local GROUP_BUTTON_W = math.floor((LIST_W - 2 * 16 - L.GAP) / 2)
groupButton = UI.Button(listFooter, "Create group", GROUP_BUTTON_W)
groupButton:SetPoint("LEFT", listFooter, "LEFT", 16, 0)
UI.Tip(groupButton, Tip("Create group", "Puts a tick box in front of each aura of the list. Tick the auras that belong together and press Save: they become a group that you can move, deactivate and activate as one.", "A group needs at least two auras that are not in a group yet: the button is grey when there are fewer. While a group is selected it says Edit group and lets you change which auras belong to it. Press it again (it says Cancel) to leave. It works when no aura is open."))
groupSave = UI.Button(listFooter, "Save", GROUP_BUTTON_W, true)
groupSave:SetPoint("LEFT", groupButton, "RIGHT", L.GAP, 0)
UI.Tip(groupSave, Tip("Save the group", "Saves the ticked auras as a group (it asks for a name). If you are editing a group, it saves the auras that are ticked and the place where you put the group.", "Grey until at least two auras are ticked: a group has at least two auras. To dissolve a group use Ungroup (right-click it). It works only while you create or edit a group."))
groupButton:SetScript("OnClick", function()
    UI.ClearFocus()
    if groupMode then
        ExitGroupMode()
    elseif HeadsUpAuras_GetDraft() == nil then
        EnterGroupMode(HeadsUpAuras_GetMovingGroup())   -- (a selected group is edited; else a new one is made)
    end
end)

StaticPopupDialogs["HEADSUPAURAS_NEW_GROUP"] = {
    text = "Name of the group:",
    button1 = ACCEPT,
    button2 = CANCEL,
    hasEditBox = true,
    maxLetters = 40,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnShow = function(self)
        local eb = self.EditBox or self.editBox
        eb:SetText("Group " .. (#HeadsUpAuras_GetGroups() + 1))
        eb:HighlightText()
    end,
    OnAccept = function(self, data)
        local eb = self.EditBox or self.editBox
        local name = strtrim(eb:GetText())
        if name == "" then name = "Group " .. (#HeadsUpAuras_GetGroups() + 1) end
        HeadsUpAuras_CreateGroup(name, data.uids)
        ExitGroupMode()
    end,
}

StaticPopupDialogs["HEADSUPAURAS_RENAME_GROUP"] = {
    text = "Rename the group:",
    button1 = ACCEPT,
    button2 = CANCEL,
    hasEditBox = true,
    maxLetters = 40,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnShow = function(self, data)
        local eb = self.EditBox or self.editBox
        eb:SetText(data.name or "")
        eb:HighlightText()
    end,
    OnAccept = function(self, data)
        local eb = self.EditBox or self.editBox
        local name = strtrim(eb:GetText())
        if name ~= "" then HeadsUpAuras_RenameGroup(data.id, name) end
        RefreshList()
    end,
}

groupSave:SetScript("OnClick", function()
    UI.ClearFocus()
    local uids = {}
    for uid in pairs(groupSel) do uids[#uids + 1] = uid end
    if not groupMode or #uids < 2 then return end
    if groupEditId then
        HeadsUpAuras_GroupCommit()   -- the place of the group is kept too
        HeadsUpAuras_SetGroupMembers(groupEditId, uids)
        ExitGroupMode()
    else
        StaticPopup_Show("HEADSUPAURAS_NEW_GROUP", nil, nil, { uids = uids })
    end
end)

local ROW_HEIGHT = 30
local LIST_TOP = 44
local rows = {}
-- the list has two parts that scroll on their own: the active auras, and (under a line) the hidden ones
local activeOffset, hiddenOffset = 0, 0
local HIDDEN_SHARE = 0.4   -- the inactive part never takes more than this share of the list
local listBars = {}        -- the thin scroll bars of the two parts (made below)
local listState = {}       -- what RefreshList last showed: how many rows each part has and how many fit

local function VisibleRows()
    local room = frame:GetHeight() - HEADER_H - LIST_TOP - FOOTER_H - 8   -- (the help is in the tooltip of each row)
    return math.max(1, math.floor(room / ROW_HEIGHT))
end

-- does this class have a group (a group with auras of this class)? Only those are offered by "Add to group"
local function HasGroupOfClass()
    local class = HeadsUpAuras_GetPlayerClass()
    for _, a in ipairs(HeadsUpAuras_GetAuras()) do
        if a.group and HeadsUpAuras_AuraListed(a) then return true end
    end
    return false
end

local function AuraMenu(row)
    local index = row.index
    local a = HeadsUpAuras_GetAuras()[index]
    if not a then return end
    -- one aura at a time: while another aura is open for editing (until Save, or until
    -- it is unselected / the window is closed) or a new one has unsaved work, no Edit
    local editing = HeadsUpAuras_GetEditIndex()
    local blocked = (editing ~= nil and editing ~= index) or HeadsUpAuras_IsDirty()
    if editing == index then blocked = false end
    local items = {
        { text = "Rename", onClick = function()
            StaticPopup_Show("HEADSUPAURAS_RENAME", nil, nil, { index = index, name = a.name })
        end },
        { text = "Edit", disabled = blocked,
            tip = Tip("Edit", "Opens this aura for editing.", "The other auras that you are showing on the screen (shift+click) stay there, so you can see how this one sits next to them. Shift+click an aura to remove it from the screen."),
            onClick = function()
            HeadsUpAuras_BeginEdit(index)
            HeadsUpAuras_SetPreview(index, true)
            SetStep(1)
            Refresh()
            RefreshList()
        end },
        { text = "Create debuff tracker", disabled = (a.trackerOf ~= nil or (a.kind or "ability") ~= "ability" or HeadsUpAuras_PreviewCount() > 1 or blocked), onClick = function()
            local made = HeadsUpAuras_CreateTracker(index, SuggestedDuration(a.spellID))
            if made then
                HeadsUpAuras_ClearPreviews()
                HeadsUpAuras_BeginEdit(made)
                HeadsUpAuras_SetPreview(made, true)
                SetStep(1)
                Refresh()
                RefreshList()
            end
        end },
        { text = "Duplicate", onClick = function()
            HeadsUpAuras_DuplicateAura(index)
            RefreshList()
        end },
        { text = a.hidden and "Activate" or "Deactivate", onClick = function()
            HeadsUpAuras_SetHidden(index, not a.hidden)
            RefreshList()
        end },
        { text = "Add to group", disabled = (a.group ~= nil or not HasGroupOfClass()),
            tip = Tip("Add to group", "Puts this aura into a group you already have.", "Grey when the aura is already in a group, or when there is no group yet (make one with Create group)."),
            onClick = function()
                -- only the groups of this class (a group of another class is not shown in the list either)
                local groups = {}
                local class = HeadsUpAuras_GetPlayerClass()
                for _, g in ipairs(HeadsUpAuras_GetGroups()) do
                    for _, m in ipairs(HeadsUpAuras_GetAuras()) do
                        if m.group == g.id and HeadsUpAuras_AuraListed(m) then
                            groups[#groups + 1] = g
                            break
                        end
                    end
                end
                if #groups == 0 then return end
                local function add(id)
                    HeadsUpAuras_ClearPreviews()
                    HeadsUpAuras_AddToGroup(index, id)
                    RefreshList()
                end
                if #groups == 1 then   -- only one group: the aura goes straight into it
                    add(groups[1].id)
                    return
                end
                local choices = {}
                for _, g in ipairs(groups) do
                    choices[#choices + 1] = { text = g.name or "Group", onClick = function() add(g.id) end }
                end
                UI.OpenPopup(row, choices, 150)
            end },
        { text = "Remove from group", disabled = (a.group == nil), onClick = function()
            HeadsUpAuras_ClearPreviews()
            a.group = nil
            HeadsUpAuras_PruneGroups()
            RefreshList()
        end },
        { text = "Delete", onClick = function()
            StaticPopup_Show("HEADSUPAURAS_DELETE", a.name or "this aura", nil, { index = index })
        end },
    }
    UI.OpenPopup(row, items, 150)
end

-- the small window that places a group by coordinates: the dot chosen on the screen goes to X, Y
local ANCHOR_TEXT = {
    TL = "top left corner", TR = "top right corner", BL = "bottom left corner", BR = "bottom right corner",
    T = "middle of the top edge", B = "middle of the bottom edge", L = "middle of the left edge", R = "middle of the right edge",
    C = "centre",
}
local posWindow = UI.Box(UIParent, C.window, C.borderHi, "Frame", "HeadsUpAurasGroupPosition")
posWindow:SetSize(310, 252)
posWindow:SetPoint("CENTER", UIParent, "CENTER", 0, -160)
posWindow:SetFrameStrata("FULLSCREEN_DIALOG")
posWindow:SetClampedToScreen(true)
posWindow:SetMovable(true)
posWindow:EnableMouse(true)
posWindow:RegisterForDrag("LeftButton")
posWindow:SetScript("OnDragStart", posWindow.StartMoving)
posWindow:SetScript("OnDragStop", posWindow.StopMovingOrSizing)
posWindow:Hide()

local posTitle = UI.Text(posWindow, 14, C.accent)
posTitle:SetPoint("TOPLEFT", 16, -14)
posTitle:SetText("HeadsUp Auras: place a group")
local posName = UI.Text(posWindow, 12, C.text)
posName:SetPoint("TOPLEFT", posTitle, "BOTTOMLEFT", 0, -8)
posName:SetWidth(278)
local posDot = UI.Text(posWindow, 11, C.muted)
posDot:SetPoint("TOPLEFT", posName, "BOTTOMLEFT", 0, -4)
posDot:SetWidth(278)

local posX, posY
local FillPosition   -- (below)
-- Enter (or leaving the box): the group goes to the typed coordinates right away. It is kept only with "Save".
local function MoveToTyped()
    local x, y = tonumber(posX.edit:GetText()), tonumber(posY.edit:GetText())
    if x and y then HeadsUpAuras_GroupMoveTo(math.floor(x + 0.5), math.floor(y + 0.5)) end
    FillPosition()
end
-- Esc: forget what was typed (an empty box moves nothing; the numbers are filled in again from the real place)
local function RevertTyped(eb) eb:SetText("") end
posX = UI.Input(posWindow, 130, { maxLetters = 6, unit = "X", commit = MoveToTyped, revert = RevertTyped })
posX:SetPoint("TOPLEFT", posDot, "BOTTOMLEFT", 0, -14)
posY = UI.Input(posWindow, 130, { maxLetters = 6, unit = "Y", commit = MoveToTyped, revert = RevertTyped })
posY:SetPoint("LEFT", posX, "RIGHT", L.PAIR_GAP, 0)

local posHint = UI.Text(posWindow, 11, C.muted)
posHint:SetWordWrap(true)
posHint:SetJustifyV("TOP")
posHint:SetPoint("TOPLEFT", posX, "BOTTOMLEFT", 0, -12)
posHint:SetWidth(278)
posHint:SetText("Type X and Y and press Enter: the group goes there right away. 0 and 0 is the centre of the screen: X to the right, Y upwards. Press Save to keep the place; Close puts the group back. Click another dot of the box on the screen to place by it (the corners, the middle of each edge, the centre).")

local posPlace = UI.Button(posWindow, "Save", 110, true)
posPlace:SetPoint("BOTTOMLEFT", posWindow, "BOTTOMLEFT", 16, 14)
UI.Tip(posPlace, Tip("Save", "Keeps the place where the group is now.", "Close, instead, puts the group back where it was."))
local posClose = UI.Button(posWindow, "Close", 110)
posClose:SetPoint("LEFT", posPlace, "RIGHT", L.GAP, 0)
posClose:SetScript("OnClick", function() posWindow:Hide() end)

-- the numbers follow the group while it is dragged or the dot is changed (not while one is typing)
function FillPosition()
    posDot:SetText("Dot: " .. (ANCHOR_TEXT[HeadsUpAuras_GetGroupAnchor()] or "centre"))
    if posX.edit:HasFocus() or posY.edit:HasFocus() then return end
    local x, y = HeadsUpAuras_GroupAnchorPos()
    if x then
        posX.edit:SetText(tostring(x))
        posY.edit:SetText(tostring(y))
    end
end
posPlace:SetScript("OnClick", function()
    UI.ClearFocus()   -- (leaving a box moves the group to what was typed)
    HeadsUpAuras_GroupCommit()
    posWindow:Hide()   -- saved: the window is done
end)
local posSince = 0
posWindow:SetScript("OnUpdate", function(self, elapsed)
    posSince = posSince + elapsed
    if posSince < 0.2 then return end
    posSince = 0
    if not self.groupId or not HeadsUpAuras_GroupMoving(self.groupId) then   -- the group is not on the screen any more
        self:Hide()
        return
    end
    FillPosition()
end)
posWindow:SetScript("OnShow", function() posSince = 1 end)
posWindow:SetScript("OnHide", function() HeadsUpAuras_GroupRestore() end)   -- closed without Save: the group goes back
tinsert(UISpecialFrames, "HeadsUpAurasGroupPosition")

function OpenGroupPosition(id, name)
    posWindow.groupId = id
    posName:SetText(name or "Group")
    posWindow:Show()
    FillPosition()
end

-- a click on a dot of the box on the screen also opens the window
function HeadsUpAuras_OnGroupDotClicked()
    local id = HeadsUpAuras_GetMovingGroup()
    if not id or HeadsUpAuras_GetDraft() ~= nil then return end
    for _, g in ipairs(HeadsUpAuras_GetGroups()) do
        if g.id == id then OpenGroupPosition(id, g.name) end
    end
end

-- the right-click menu of a group
local function GroupMenu(row)
    local id = row.groupId
    local g
    for _, x in ipairs(HeadsUpAuras_GetGroups()) do
        if x.id == id then g = x end
    end
    if not g then return end
    local allHidden = true
    for _, i in ipairs(HeadsUpAuras_GroupMembers(id)) do
        local a = HeadsUpAuras_GetAuras()[i]
        if a and not a.hidden then allHidden = false end
    end
    local items = {
        { text = "Rename", onClick = function()
            StaticPopup_Show("HEADSUPAURAS_RENAME_GROUP", nil, nil, { id = id, name = g.name })
        end },
        { text = allHidden and "Activate" or "Deactivate", onClick = function()
            HeadsUpAuras_SetGroupHidden(id, not allHidden)
            RefreshList()
        end },
        { text = "Position", disabled = (HeadsUpAuras_GetDraft() ~= nil), onClick = function()
            -- the group is shown on the screen (with its box and dots) and the small window opens
            HeadsUpAuras_ClearPreviews()
            for _, i in ipairs(HeadsUpAuras_GroupMembers(id)) do HeadsUpAuras_SetPreview(i, true) end
            HeadsUpAuras_SetGroupMove(id)
            OpenGroupPosition(id, g.name)
            RefreshList()
        end },
        { text = "Color", onClick = function()
            UI.OpenPalette(row, g.color, function(r, gr, b)
                HeadsUpAuras_SetGroupColor(id, { r, gr, b })
                RefreshList()
            end)
        end },
        { text = "Edit group", disabled = (HeadsUpAuras_GetDraft() ~= nil), onClick = function()
            EnterGroupMode(id)
        end },
        { text = "Ungroup", onClick = function()
            HeadsUpAuras_ClearPreviews()
            HeadsUpAuras_Ungroup(id)
            RefreshList()
        end },
    }
    UI.OpenPopup(row, items, 150)
end

-- the little picture that follows the mouse while an aura is dragged from the list
local dragGhost = CreateFrame("Frame", nil, UIParent)
dragGhost:SetSize(28, 28)
dragGhost:SetFrameStrata("TOOLTIP")
dragGhost:Hide()
dragGhost.icon = dragGhost:CreateTexture(nil, "ARTWORK")
dragGhost.icon:SetAllPoints()
dragGhost.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
dragGhost:SetScript("OnUpdate", function(self)
    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    self:ClearAllPoints()
    self:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x / scale, y / scale)
end)

local function GetRow(n)
    if rows[n] then return rows[n] end
    local row = CreateFrame("Button", nil, listPanel)
    row:SetHeight(ROW_HEIGHT - 2)
    row:SetPoint("TOPLEFT", listPanel, "TOPLEFT", 8, -LIST_TOP - (n - 1) * ROW_HEIGHT)
    row:SetPoint("RIGHT", listPanel, "RIGHT", -8, 0)
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.18)   -- the aura being edited
    row.hl = row:CreateTexture(nil, "BORDER")
    row.hl:SetAllPoints()
    row.hl:SetColorTexture(1, 1, 1, 0.07)
    row.hl:Hide()
    -- while the right-click menu of this row is open the row has the same highlight as an aura that is open for editing,
    -- so you can see which aura (or group) the menu acts on: the list is drawn again when the menu opens or closes
    row:SetScript("OnUpdate", function(self)
        local on = (UI.PopupOwner() == self)
        if self.markOn ~= on then
            self.markOn = on
            RefreshList()
        end
    end)
    -- the card of a group: a fill and a frame around the header and the auras of the group
    row.cardBg = row:CreateTexture(nil, "BACKGROUND", nil, -1)
    row.cardBg:Hide()
    row.cardL = row:CreateTexture(nil, "ARTWORK")
    row.cardR = row:CreateTexture(nil, "ARTWORK")
    row.cardT = row:CreateTexture(nil, "ARTWORK")
    row.cardB = row:CreateTexture(nil, "ARTWORK")
    row.headLine = row:CreateTexture(nil, "ARTWORK")
    for _, t in ipairs({ row.cardL, row.cardR, row.cardT, row.cardB, row.headLine }) do
        t:SetColorTexture(C.borderHi[1], C.borderHi[2], C.borderHi[3], 1)
        t:Hide()
    end
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(22, 22)
    row.icon:SetPoint("LEFT", 4, 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    -- the tick box of the group mode
    row.check = UI.Box(row, C.field, C.border)
    row.check:SetSize(12, 12)
    row.check:Hide()
    row.checkFill = row.check:CreateTexture(nil, "OVERLAY")
    row.checkFill:SetSize(6, 6)
    row.checkFill:SetPoint("CENTER")
    row.checkFill:SetColorTexture(unpack(C.accent))
    row.text = UI.Text(row, 12, C.text)
    -- green square = selected: its placeholder is on screen
    row.dot = row:CreateTexture(nil, "OVERLAY")
    row.dot:SetSize(8, 8)
    row.dot:SetPoint("RIGHT", -8, 0)
    row.dot:SetColorTexture(unpack(C.good))
    -- the + / - on the right of the header of a group: it opens and closes the group
    row.toggle = CreateFrame("Button", nil, row)
    row.toggle:SetSize(20, 20)
    row.toggle:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.toggle.text = UI.Text(row.toggle, 16, C.text, "CENTER")
    row.toggle.text:SetPoint("CENTER", 0, 1)
    row.toggle:SetScript("OnClick", function(self)
        local owner = self:GetParent()
        if owner.groupId then
            HeadsUpAuras_ToggleGroupCollapsed(owner.groupId)
            RefreshList()
        end
    end)
    row.toggle:SetScript("OnEnter", function(self)
        self.text:SetTextColor(unpack(C.accent))
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Open or close the group", 1, 0.82, 0)
        GameTooltip:AddLine("Closed, only its bar is shown and the auras below move up.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    row.toggle:SetScript("OnLeave", function(self)
        self.text:SetTextColor(unpack(C.text))
        GameTooltip:Hide()
    end)
    row.toggle:Hide()
    row.text:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
    row.text:SetPoint("RIGHT", row.dot, "LEFT", -6, 0)
    row:EnableMouseWheel(true)
    row:SetScript("OnMouseWheel", function(self, delta)
        activeOffset = activeOffset - delta   -- (one scroll for the whole column)
        RefreshList()
    end)
    -- the line above the "Hidden" auras
    row.line = row:CreateTexture(nil, "ARTWORK")
    row.line:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -2)
    row.line:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, -2)
    row.line:SetHeight(1)
    row.line:SetColorTexture(unpack(C.border))
    row:SetScript("OnEnter", function(self)
        if self.header then return end
        self.hl:Show()
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if self.groupId then
            local name = "Group"
            for _, g in ipairs(HeadsUpAuras_GetGroups()) do
                if g.id == self.groupId then name = g.name or name end
            end
            GameTooltip:AddLine(name, 1, 0.82, 0)
            GameTooltip:AddLine("A group of auras: it is moved, deactivated and activated as one.", 1, 1, 1, true)
            GameTooltip:AddLine("Click: show all its auras on screen, in a box with five dots, and drag them with the mouse, together.", 0.7, 0.7, 0.7, true)
            GameTooltip:AddLine("Right-click for more: rename, deactivate, position, color, edit group, ungroup.", 1, 0.82, 0, true)
            GameTooltip:Show()
            return
        end
        local a = HeadsUpAuras_GetAuras()[self.index]
        GameTooltip:AddLine(a and a.name or "Aura", 1, 1, 1)
        if a and a.hidden then
            GameTooltip:AddLine("Inactive: it does not show in the game.", 0.8, 0.8, 0.8, true)
        end
        if groupMode then
            GameTooltip:AddLine("Click: tick it or untick it for the group.", 1, 0.82, 0, true)
        else
            GameTooltip:AddLine("Right-click for more: rename, edit, duplicate, " .. ((a and a.hidden) and "activate" or "deactivate") .. ", remove from group, delete.", 1, 0.82, 0, true)
            GameTooltip:AddLine("Click: show it on screen, to move it. Shift+click: show several at once.", 0.7, 0.7, 0.7, true)
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function(self)
        self.hl:Hide()
        GameTooltip:Hide()
    end)
    -- drag an aura onto a drop box (Trigger tab, "Combine with auras"): a small picture follows the mouse
    row:RegisterForDrag("LeftButton")
    row:SetScript("OnDragStart", function(self)
        local a = not self.header and self.index and HeadsUpAuras_GetAuras()[self.index]
        if not a or not a.uid or not HeadsUpAuras_GetDraft() then return end
        UI.dragUid = a.uid
        dragGhost.icon:SetTexture(self.icon:GetTexture())
        dragGhost:Show()
    end)
    row:SetScript("OnDragStop", function()
        dragGhost:Hide()
        local uid = UI.dragUid
        UI.dragUid = nil
        if not uid then return end
        for _, slot in ipairs(UI.drops or {}) do
            if slot.frame:IsVisible() and slot.frame:IsMouseOver() then
                slot.drop(uid)
                break
            end
        end
    end)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function(self, button)
        if self.header then return end
        -- a group
        if self.groupId then
            if groupMode then return end
            if button == "RightButton" then
                GroupMenu(self)
                return
            end
            UI.ClearFocus()
            -- click: show all its auras on the screen and move them as one (click again to hide them)
            local id = self.groupId
            local moving = HeadsUpAuras_GroupMoving(id)
            HeadsUpAuras_ClearPreviews()
            if not moving then
                for _, i in ipairs(HeadsUpAuras_GroupMembers(id)) do HeadsUpAuras_SetPreview(i, true) end
                HeadsUpAuras_SetGroupMove(id)
            elseif HeadsUpAuras_GetEditIndex() ~= nil and not HeadsUpAuras_IsDirty() then
                HeadsUpAuras_EndEdit()   -- hiding the group: the aura that was in focus is let go too (unless it has unsaved work)
                SetStep(1)
                Refresh()
            end
            RefreshList()
            return
        end
        local index = self.index
        if not index then return end
        -- the group mode: a click ticks or unticks the aura
        if groupMode then
            local a = HeadsUpAuras_GetAuras()[index]
            if a and a.uid then
                groupSel[a.uid] = (not groupSel[a.uid]) or nil
                Refresh()
                RefreshList()
            end
            return
        end
        if button == "RightButton" then
            AuraMenu(self)
            return
        end
        UI.ClearFocus()
        -- click: select this one only (click again to unselect); shift+click: add / remove
        if IsShiftKeyDown() then
            HeadsUpAuras_SetPreview(index, not HeadsUpAuras_IsPreview(index))
        elseif HeadsUpAuras_PreviewCount() >= 2 then
            -- several auras are shown (shift+click, or a group): a click picks this one to edit and the others stay on the screen
            -- Two separate things: the green square says what is shown on the screen; the highlight says which aura you work on.
            -- A click moves the highlight (or takes it away when the aura already has it); what is shown stays.
            local editing = HeadsUpAuras_GetEditIndex()
            if HeadsUpAuras_IsDirty() then return end   -- (unsaved work: Save or Cancel it first)
            if editing == index then
                HeadsUpAuras_EndEdit()
            else
                HeadsUpAuras_SetPreview(index, true)
                HeadsUpAuras_BeginEdit(index)
            end
            SetStep(1)
            Refresh()
        else
            local onlyThis = HeadsUpAuras_IsPreview(index) and HeadsUpAuras_PreviewCount() == 1
            HeadsUpAuras_ClearPreviews()
            if not onlyThis then HeadsUpAuras_SetPreview(index, true) end
        end
        -- unselecting the aura that is open for editing closes it
        if HeadsUpAuras_GetEditIndex() == index and not HeadsUpAuras_IsPreview(index) then
            HeadsUpAuras_EndEdit()
            Refresh()
        end
        RefreshList()
    end)
    rows[n] = row
    return row
end

listPanel:EnableMouseWheel(true)
listPanel:SetScript("OnMouseWheel", function(_, delta)
    activeOffset = activeOffset - delta
    RefreshList()
end)

-- a thin scroll bar for one part of the list ("active" or "hidden"): it moves the offset of that part
local function MakeListBar(which)
    local function offsetSetter(value)
        if which == "active" then activeOffset = value else hiddenOffset = value end
    end
    return UI.ScrollBar(listPanel, {
        state = function()
            local info = listState[which]
            if not info or info.total <= info.slots or info.slots <= 0 then return false end
            return true, info.slots / info.total, info.offset / (info.total - info.slots)
        end,
        setPosition = function(position)
            local info = listState[which]
            if info and info.total > info.slots then
                offsetSetter(math.floor(position * (info.total - info.slots) + 0.5))
                RefreshList()
            end
        end,
        page = function(direction)
            local info = listState[which]
            if info then
                offsetSetter(info.offset + direction * info.slots)
                RefreshList()
            end
        end,
        wheel = function(delta)
            local info = listState[which]
            if info then
                offsetSetter(info.offset - delta)
                RefreshList()
            end
        end,
    })
end
listBars.active = MakeListBar("active")
listBars.hidden = MakeListBar("hidden")

-- one row of the list shows one aura
-- The card of a group: the header and the auras of a group have one fill and one frame around them.
-- role: nil (not in a group), "head" (the header, filled with the colour of the group) or "mid" (an aura of the group);
-- last: the last row of the group (it has the bottom of the frame)
local GROUP_COLOR = { 0.20, 0.28, 0.42 }
local function StyleRow(row, role, color, last)
    if not role then
        row.cardBg:Hide()
        row.cardL:Hide()
        row.cardR:Hide()
        row.cardT:Hide()
        row.cardB:Hide()
        row.headLine:Hide()
        return
    end
    local gap = last and 0 or -2   -- (the rows are 2 pixels apart: the fill and the sides cover that gap)
    row.cardBg:ClearAllPoints()
    row.cardBg:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row.cardBg:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, gap)
    if role == "head" then
        local c = color or GROUP_COLOR
        row.cardBg:SetColorTexture(c[1], c[2], c[3], 0.9)
    else
        row.cardBg:SetColorTexture(C.card[1], C.card[2], C.card[3], 1)
    end
    row.cardBg:Show()
    row.cardL:ClearAllPoints()
    row.cardL:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row.cardL:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, gap)
    row.cardL:SetWidth(1)
    row.cardL:Show()
    row.cardR:ClearAllPoints()
    row.cardR:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
    row.cardR:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, gap)
    row.cardR:SetWidth(1)
    row.cardR:Show()
    row.cardT:ClearAllPoints()
    row.cardT:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row.cardT:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
    row.cardT:SetHeight(1)
    row.cardT:SetShown(role == "head")
    row.cardB:ClearAllPoints()
    row.cardB:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, gap)
    row.cardB:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, gap)
    row.cardB:SetHeight(1)
    row.cardB:SetShown(last and true or false)
    row.headLine:ClearAllPoints()
    row.headLine:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
    row.headLine:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
    row.headLine:SetHeight(1)
    row.headLine:SetShown(role == "head" and not last)
end

local function ShowAuraRow(row, i, section, level, inGroup, last)
    local auras = HeadsUpAuras_GetAuras()
    local a = auras[i]
    local info = C_Spell.GetSpellInfo(a.spellID)
    row.header = false
    row.groupId = nil
    row.section = section
    row.index = i
    row.line:Hide()
    StyleRow(row, inGroup and "mid" or nil, nil, last)
    row.toggle:Hide()
    row.dot:ClearAllPoints()
    row.dot:SetPoint("RIGHT", -8, 0)
    row.icon:Show()
    row.icon:SetTexture(a.icon or (info and info.iconID) or C_Spell.GetSpellTexture(a.spellID))
    -- a tracker: smaller letters, a smaller icon, and one step in (a tab), so it reads as a part of what is above it;
    -- an aura of a group is one step in too
    local tracker = (a.trackerOf ~= nil) or (a.kind == "tracker")
    local size = tracker and 14 or 22
    local x = 4 + (level or 0) * 12 + (tracker and 12 or 0)
    if groupMode then   -- the tick box of the group mode stands in front of the icon
        row.check:ClearAllPoints()
        row.check:SetPoint("LEFT", x, 0)
        row.check:Show()
        row.checkFill:SetShown(a.uid ~= nil and groupSel[a.uid] and true or false)
        x = x + 18
    else
        row.check:Hide()
    end
    row.icon:SetSize(size, size)
    row.icon:ClearAllPoints()
    row.icon:SetPoint("LEFT", x, 0)
    row.text:SetFont(STANDARD_TEXT_FONT, tracker and 10 or 12, "")
    row.text:ClearAllPoints()
    row.text:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
    row.text:SetPoint("RIGHT", row.dot, "LEFT", -6, 0)
    row.text:SetText(a.name or (info and info.name) or ("Spell " .. a.spellID))
    if a.hidden then
        row.text:SetTextColor(unpack(C.disabled))
        row.icon:SetDesaturated(true)
    else
        row.text:SetTextColor(unpack(C.text))
        row.icon:SetDesaturated(false)
    end
    -- highlighted: open for editing, or its right-click menu is open
    local open = (i == HeadsUpAuras_GetEditIndex())
    local editing = open or (UI.PopupOwner() == row)
    row.bg:SetShown(editing and not inGroup)
    -- the aura of a group that is open for editing: its card takes a lighter shade of the colour of the header of its
    -- group, so it stands out from the other auras of the group (the green dot already says which ones are shown)
    if inGroup and editing then
        local c = GROUP_COLOR
        for _, g in ipairs(HeadsUpAuras_GetGroups()) do
            if g.id == a.group and g.color then c = g.color end
        end
        local light = 0.3   -- how far the colour goes towards white
        row.cardBg:SetColorTexture(c[1] + (1 - c[1]) * light, c[2] + (1 - c[2]) * light, c[3] + (1 - c[3]) * light, 1)
    end
    row.dot:SetShown((HeadsUpAuras_IsPreview(i) or open) and not groupMode)   -- (an aura that is open for editing is always shown)
    row:Show()
end

-- the header of a group: a coloured bar with the name and how many auras the group has (no icon)
local function ShowGroupRow(row, g, section, count, allHidden, last)
    row.header = false
    row.groupId = g.id
    row.index = nil
    row.section = section
    row.line:Hide()
    row.check:Hide()
    row.icon:Hide()
    row.toggle:Show()
    row.toggle.text:SetText(g.collapsed and "+" or "-")
    row.dot:ClearAllPoints()
    row.dot:SetPoint("RIGHT", row.toggle, "LEFT", -6, 0)
    StyleRow(row, "head", g.color, last)
    row.text:SetFont(STANDARD_TEXT_FONT, 12, "")
    row.text:ClearAllPoints()
    row.text:SetPoint("LEFT", row, "LEFT", 10, 0)
    row.text:SetPoint("RIGHT", row.dot, "LEFT", -6, 0)
    row.text:SetText((g.name or "Group") .. " (" .. count .. ")")
    row.text:SetTextColor(unpack(allHidden and C.muted or C.text))
    row.bg:SetShown(groupMode and groupEditId == g.id)
    -- the menu of the group is open: its header is a lighter shade of its colour (the same highlight as for an aura)
    if UI.PopupOwner() == row then
        local c = g.color or GROUP_COLOR
        local light = 0.3
        row.cardBg:SetColorTexture(c[1] + (1 - c[1]) * light, c[2] + (1 - c[2]) * light, c[3] + (1 - c[3]) * light, 0.9)
    end
    row.dot:SetShown(HeadsUpAuras_GroupMoving(g.id) and not groupMode)
    row:Show()
end

-- the line between the two parts, with its title
local function ShowHeaderRow(row, count)
    row.header = true
    row.groupId = nil
    row.check:Hide()
    StyleRow(row, nil)
    row.toggle:Hide()
    row.dot:ClearAllPoints()
    row.dot:SetPoint("RIGHT", -8, 0)
    row.section = "hidden"
    row.index = nil
    row.icon:Hide()
    row.dot:Hide()
    row.bg:Hide()
    row.line:Show()
    row.text:ClearAllPoints()
    row.text:SetFont(STANDARD_TEXT_FONT, 12, "")
    row.text:SetPoint("LEFT", row, "LEFT", 4, -3)
    row.text:SetPoint("RIGHT", row, "RIGHT", -4, -3)
    row.text:SetText("Inactive (" .. count .. ")")
    row.text:SetTextColor(unpack(C.muted))
    row:Show()
end

function RefreshList()
    -- a selected group that has gone away (it fell below two auras) is not selected any more
    local movingId = HeadsUpAuras_GetMovingGroup()
    if movingId then
        local found = false
        for _, g in ipairs(HeadsUpAuras_GetGroups()) do
            if g.id == movingId then found = true end
        end
        if not found then HeadsUpAuras_ClearPreviews() end
    end
    UpdateChrome()   -- (the group button depends on which group is selected)
    local auras = HeadsUpAuras_GetAuras()
    local class = HeadsUpAuras_GetPlayerClass()
    local active, hidden = {}, {}
    local groups = HeadsUpAuras_GetGroups()
    local function visible(a) return HeadsUpAuras_AuraListed(a) and a.spellID end
    -- an aura and, under it, its debuff trackers that are in the same group (or in none)
    local function addAura(list, i, level)
        local a = auras[i]
        list[#list + 1] = { kind = "aura", index = i, level = level }
        if a.uid then
            for j, t in ipairs(auras) do
                if t.trackerOf == a.uid and t.group == a.group and visible(t) then
                    list[#list + 1] = { kind = "aura", index = j, level = level + 1 }
                end
            end
        end
    end
    -- does an aura have its own line (it is not a tracker listed under its aura)?
    local function ownLine(a)
        if not a.trackerOf then return true end
        for _, p in ipairs(auras) do
            if p.uid == a.trackerOf then return p.group ~= a.group end
        end
        return true
    end
    -- the groups come first, each one as a row with its auras under it; a group whose auras are all inactive is in the inactive part
    for _, g in ipairs(groups) do
        local members, count, allHidden = {}, 0, true
        for i, a in ipairs(auras) do
            if a.group == g.id and visible(a) then
                count = count + 1
                if not a.hidden then allHidden = false end
                if ownLine(a) then members[#members + 1] = i end
            end
        end
        if count > 0 then
            local list = allHidden and hidden or active
            local from = #list + 1
            list[from] = { kind = "group", group = g, count = count, allHidden = allHidden }
            if not g.collapsed or groupMode then
                for _, i in ipairs(members) do addAura(list, i, 1) end
            end
            for k = from + 1, #list do list[k].inGroup = true end
            list[#list].last = true   -- (the bottom of the card of the group)
        end
    end
    -- then the auras that are in no group
    for i, a in ipairs(auras) do
        if visible(a) and a.group == nil and ownLine(a) then
            addAura(a.hidden and hidden or active, i, 0)
        end
    end
    local function show(row, entry, section)
        if entry.kind == "group" then
            ShowGroupRow(row, entry.group, section, entry.count, entry.allHidden, entry.last)
        else
            ShowAuraRow(row, entry.index, section, entry.level, entry.inGroup, entry.last)
        end
    end

    -- one list for the whole column: the active entries, then the line "Inactive (N)" and the inactive ones.
    -- It has ONE scroll bar (the column scrolls; a group does not scroll by itself).
    local entries = {}
    for _, e in ipairs(active) do entries[#entries + 1] = e end
    if #hidden > 0 then
        -- the number on the line counts the auras, not the rows (a group is one row: its auras are counted)
        local inactiveAuras = 0
        for _, e in ipairs(hidden) do
            if e.kind == "group" then
                inactiveAuras = inactiveAuras + e.count
            elseif not e.inGroup then
                inactiveAuras = inactiveAuras + 1
            end
        end
        entries[#entries + 1] = { kind = "line", count = inactiveAuras }
        for _, e in ipairs(hidden) do entries[#entries + 1] = e end
    end
    local total = VisibleRows()
    activeOffset = UI.Clamp(activeOffset, 0, math.max(0, #entries - total))

    local n = 0
    for k = 1, math.min(#entries, total) do
        n = n + 1
        local e = entries[activeOffset + k]
        if e.kind == "line" then
            ShowHeaderRow(GetRow(n), e.count)
        else
            show(GetRow(n), e, "active")
        end
    end
    for m = n + 1, #rows do rows[m]:Hide() end
    emptyText:SetShown(#entries == 0)

    -- the scroll bar: beside the list, only when the list has more than it can show
    local shown = math.min(#entries, total)
    listState.active = { total = #entries, slots = total, offset = activeOffset }
    listState.hidden = { total = 0, slots = 0, offset = 0 }   -- (the second bar of the old list is not used)
    listBars.active:ClearAllPoints()
    listBars.active:SetPoint("TOPRIGHT", listPanel, "TOPRIGHT", -2, -LIST_TOP)
    listBars.active:SetHeight(math.max(1, shown * ROW_HEIGHT))
    listBars.active:Refresh()
    listBars.hidden:Refresh()
end

------------------------------------------------------------
-- opening, closing, events
------------------------------------------------------------
frame:SetScript("OnShow", function()
    UpdateFeedbackButton()
    HeadsUpAuras_EndEdit()   -- opens with nothing open: New or Edit starts the work
    SetStep(1)
    Refresh()
    RefreshList()
end)
frame:SetScript("OnHide", function()
    feedbackPanel:Hide()
    UI.ClearFocus()
    UI.ClosePopup()
    picker:Hide()
    HeadsUpAuras_ClearPreviews()
    HeadsUpAuras_EndEdit()        -- discards anything not saved
    groupMode, groupEditId = false, nil
    wipe(groupSel)
    if groupButton then groupButton.label:SetText("Create group") end
    posWindow:Hide()
end)
frame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
frame:RegisterEvent("SPELLS_CHANGED")
frame:SetScript("OnEvent", function(self)
    wipe(factsCache)
    if self:IsShown() then
        Refresh()
        RefreshList()
    end
end)

-- called by HeadsUpAuras.lua when an icon was dragged: the X and Y boxes show where it is now
function HeadsUpAuras_PositionChanged()
    if frame:IsShown() then
        UI.SyncAll()
        UpdateChrome()   -- (a dragged icon is a change: Save lights up)
    end
end

function HeadsUpAuras_ToggleSettings()
    frame:SetShown(not frame:IsShown())
end
