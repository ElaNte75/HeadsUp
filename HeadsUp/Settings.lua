-- HeadsUp: settings window.
-- A wizard: the list of saved auras on the left, and on the right one step at a time
-- (Aura -> Conditions -> Ability -> Situation). The pieces (cards, rows, controls) are in UI.lua.
--
-- To add an option: find the card it belongs to in one of the Build...Page functions and add a line
-- (card:Condition or card:Field). A new group of options = a new card. A new step = a new entry in STEPS.

local UI = HeadsUpUI
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
    return spellID ~= nil and HeadsUp_GetLearned()[spellID] ~= nil
end

-- The buffs that can make an ability light up (KnownGlows.lua: made from the game's own data by
-- tools/make_glows.py). nil when the ability is not in the list. The addon cannot see buffs in combat,
-- so it cannot tell which of them lit the ability: the names are information.
local function KnownSources(spellID)
    local forClass = HeadsUpGlows and HeadsUpGlows[HeadsUp_GetPlayerClass()]
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
for v = 10, 100, 5 do PCT_LIST[#PCT_LIST + 1] = { value = v, text = v .. "%" } end

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
    { value = "sunburst", text = "Sunburst" },
    { value = "flame", text = "Flame" },
    { value = "burst", text = "Burst" },
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
local WHEN_ORDER = { "always", "combat", "out", "mounted", "unmounted", "vehicle", "novehicle" }
local WHEN_LABELS = {
    always = "Always",
    combat = "In combat", out = "Out of combat",
    mounted = "Mounted", unmounted = "Not mounted",
    vehicle = "In a vehicle", novehicle = "Not in a vehicle",
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
local HEADER_H, FOOTER_H, LIST_W, TAB_H = 48, 52, 200, 36
local WIN_W, WIN_H = 700, 520
-- the page (its width follows from the grid, UI.lua) sits in the middle of the right side
local PADDING = math.floor((WIN_W - LIST_W - 1 - L.PAGE_W) / 2)
local MAIN_W = WIN_W - LIST_W - 1

local frame = UI.Box(UIParent, C.window, C.borderHi, "Frame", "HeadsUpSettings")
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
tinsert(UISpecialFrames, "HeadsUpSettings")   -- Esc closes it

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

-- the version is the one written in HeadsUp.toc (by hand: for example "1.0 beta")
local VERSION = (C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata)("HeadsUp", "Version") or "1.0 beta"
-- where the players are asked to send their feedback: the CurseForge page of the addon.
-- (It works once the project exists with the name HeadsUp on CurseForge: change the address if it differs.)
local FEEDBACK_URL = "https://www.curseforge.com/wow/addons/headsup"

local titleText = UI.Text(header, 18, C.accent)
titleText:SetPoint("LEFT", header, "LEFT", 18, 0)
titleText:SetText("HeadsUp")

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
    local seen = HeadsUpDB and HeadsUpDB.feedbackSeen
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
feedbackPanel:SetSize(340, 206)
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
feedbackBody:SetWidth(308)
feedbackBody:SetText("HeadsUp is in beta, and your feedback is very important to us. Tell us what problem you ran into, what you need, or which ability did not work well, so that we can make it better.")

local feedbackWhere = UI.Text(feedbackPanel, 11, C.muted)
feedbackWhere:SetPoint("BOTTOMLEFT", feedbackPanel, "BOTTOMLEFT", 16, 82)
feedbackWhere:SetText("Leave a comment on our CurseForge page (click the address, Ctrl+C):")

-- the address: it can be selected and copied, but not changed
local feedbackAddress = UI.Input(feedbackPanel, 308, { maxLetters = 200 })
feedbackAddress:SetPoint("BOTTOMLEFT", feedbackPanel, "BOTTOMLEFT", 16, 54)
feedbackAddress.edit:SetText(FEEDBACK_URL)
feedbackAddress.edit:SetScript("OnTextChanged", function(self, byPlayer)
    if byPlayer then
        self:SetText(FEEDBACK_URL)
        self:HighlightText()
    end
end)
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
    if HeadsUpDB then HeadsUpDB.feedbackSeen = true end   -- from now on a small, plain button
    UpdateFeedbackButton()
end)

-- left: the saved auras
local listPanel = CreateFrame("Frame", nil, frame)
listPanel:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -HEADER_H)
listPanel:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 1, 1)
listPanel:SetWidth(LIST_W)
local listBg = listPanel:CreateTexture(nil, "BACKGROUND")
listBg:SetAllPoints()
listBg:SetColorTexture(unpack(C.panel))
local listLine = listPanel:CreateTexture(nil, "ARTWORK")
listLine:SetPoint("TOPRIGHT")
listLine:SetPoint("BOTTOMRIGHT")
listLine:SetWidth(1)
listLine:SetColorTexture(unpack(C.border))

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

local picker = UI.Box(frame, C.window, C.borderHi, "Frame", "HeadsUpIconPicker")
picker:SetSize(ICON_COLS * ICON_CELL + 28, 36 + ICON_ROWS * ICON_CELL + 56)
picker:SetPoint("TOPRIGHT", frame, "TOPLEFT", -6, 0)
picker:EnableMouse(true)
picker:EnableMouseWheel(true)
picker:Hide()
tinsert(UISpecialFrames, "HeadsUpIconPicker")

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
        local d = HeadsUp_GetDraft()
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
    local d = HeadsUp_GetDraft()
    if d then
        d.icon = nil
        UI.Changed()
    end
    picker:Hide()
end)

local function TogglePicker()
    if picker:IsShown() then
        picker:Hide()
    else
        iconList = BuildIconList()
        ShowIconPage(1)
        picker:Show()
    end
end

------------------------------------------------------------
-- STEP 1: Aura (what we make, and how it looks)
------------------------------------------------------------
local function SelectAbility(d, a)
    -- keep a custom name; replace an empty or automatic one
    local prev = d.spellID and C_Spell.GetSpellInfo(d.spellID)
    local isAuto = not d.name or (prev and (d.name == prev.name
        or (d.name:gsub("%s+%d+$", "")) == prev.name))
    if isAuto then
        -- suggest a name that is not used yet: "Death Strike 2" if needed
        d.name = HeadsUp_UniqueName(a.name, HeadsUp_GetEditIndex())
    end
    d.spellID = a.id
    -- a condition that makes no sense for this ability is switched off
    local hasCost, hasCooldown, maxCharges = SpellFacts(a.id)
    if not (hasCost or hasCooldown) then d.availEnabled = false end
    if not hasCooldown then d.cdEnabled = false end
    if maxCharges <= 1 then
        d.chargesEnabled = false
        d.suppressEnabled = false
    end
    d.icon = nil   -- a new ability starts with its own icon
    -- suggest the hide-timer length from the ability's description
    local seconds = SuggestedDuration(a.id)
    if seconds then d.suppressSeconds = seconds end
    UI.Changed()
end

-- the ability, the name and the icon buttons start this many pixels to the left of the half row,
-- so that the long names of abilities fit
local WIDE_EXTRA = 20
-- the width of those fields, and of half of it (width and height, X and Y, the two icon buttons):
-- two halves with SPLIT_GAP between them (the width / height link sits in that gap)
local SPLIT_GAP = 16
local WIDE_W = L.COL_W * 3 + L.GAP * 2 + WIDE_EXTRA
local HALF_W = (WIDE_W - SPLIT_GAP) / 2

local function BuildAuraPage(page)
    local card = page:Card("Ability")

    card:Field({
        label = "Ability",
        tip = Tip("Ability", "The ability this aura is about. The icon shows its picture, and the conditions look at its cost, cooldown and charges.", "Only abilities of your spellbook are listed."),
        controls = {
            {
                type = "dropdown", span = 3, extra = WIDE_EXTRA,
                text = function(d)
                    local info = d.spellID and C_Spell.GetSpellInfo(d.spellID)
                    return info and info.name or "Choose ability"
                end,
                items = function(d)
                    local items = {}
                    for _, a in ipairs(GetAbilities()) do
                        items[#items + 1] = {
                            text = a.name, icon = a.icon,
                            selected = function() return d.spellID == a.id end,
                            onClick = function() SelectAbility(d, a) end,
                        }
                    end
                    return items
                end,
            },
        },
    })

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

    -- width x height; while they are linked (the default), changing one changes the other
    local function dimension(key, other, unit)
        return {
            type = "input", numeric = true, maxLetters = 3, unit = unit, w = HALF_W, gap = 0,
            get = function(d) return d[key] end,
            set = function(d, v)
                v = UI.Clamp(v, 16, 256)
                d[key] = v
                if d.sizeLinked then d[other] = v end
            end,
        }
    end
    card:Field({
        label = "Size",
        tip = Tip("Size", "The width and the height of the icon, in pixels (W and H).", "Click the = between them to set them separately."),
        controls = {
            dimension("width", "height", "W"),
            {
                type = "link", textOn = "=", textOff = "x", w = SPLIT_GAP, gap = 0,   -- "=": linked, "x": separate
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
            dimension("height", "width", "H"),
        },
    })

    -- where it is on the screen: the distance of the icon's centre from the centre of the screen.
    -- Dragging the icon with the mouse changes these numbers too (HeadsUp_PositionChanged below).
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
            type = "input", signed = true, maxLetters = 5, unit = unit, w = HALF_W, gap = SPLIT_GAP,
            tip = positionTip,
            get = function() return math.floor((select(index, HeadsUp_GetPosition())) + 0.5) end,
            set = function(d, v)
                local x, y = HeadsUp_GetPosition()
                local lx, ly = limits(d)
                if index == 1 then
                    x = UI.Clamp(math.floor(v + 0.5), -lx, lx)
                else
                    y = UI.Clamp(math.floor(v + 0.5), -ly, ly)
                end
                HeadsUp_SetPosition(x, y)
            end,
        }
    end
    card:Field({
        label = "Position",
        tip = positionTip,
        usable = HasAbility,
        controls = { coordinate(1, "X"), coordinate(2, "Y") },
    })

    local look = page:Card("Appearance")
    look:Field({
        label = "Show effect",
        tip = Tip("Show effect", "A ring around the icon while it shows.", "None: nothing.  Glow: a pulsing ring.  Pulse: a pulsing ring, and the icon breathes."),
        usable = HasAbility,
        controls = { Choice("effect", EFFECT_LIST, "none") },
    })
    look:Field({
        label = "Empowered effect",
        usable = HasAbility,
        tip = function(tt)
            tt:AddLine("Empowered effect", 1, 0.82, 0)
            tt:AddLine("The effect behind the icon while it is shown because its ability is empowered (the Empowered row, on the Ability page). The icon looks plain the rest of the time.", 1, 1, 1, true)
            tt:AddLine(" ")
            tt:AddLine("Sunburst: turning golden stars.", 0.7, 0.7, 0.7)
            tt:AddLine("Flame: flickering orange rings.", 0.7, 0.7, 0.7)
            tt:AddLine("Burst: a flash when it lights up, then a soft glow.", 0.7, 0.7, 0.7)
        end,
        controls = { Choice("empowerFx", EMPOWER_FX_LIST, "sunburst") },
    })
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

------------------------------------------------------------
-- STEP 2: Conditions (what the aura looks at)
------------------------------------------------------------
local function BuildConditionsPage(page)
    local health = page:Card("Health")
    health:Condition({
        label = "Player health is", key = "healthEnabled", usable = HasAbility,
        tip = Tip("Player health", "Shows the icon only while your health compares like this with the percent you choose.", "Example: below 85%."),
        controls = { Choice("healthOp", OP_LIST, "<"), Choice("healthPct", PCT_LIST, 80) },
    })
    health:Condition({
        label = "Enemy health is", key = "enemyEnabled", usable = HasAbility,
        tip = Tip("Enemy health", "Same as your health, for the enemy: your target, when you can attack it. With no hostile target selected this condition is not met."),
        controls = { Choice("enemyOp", OP_LIST, "<"), Choice("enemyPct", PCT_LIST, 80) },
    })
    health:Condition({
        label = "Enemy is alive", key = "enemyAliveEnabled", usable = HasAbility,
        tip = function(tt)
            tt:AddLine("Enemy is alive", 1, 0.82, 0)
            tt:AddLine("The enemy is your target, when you can attack it.", 1, 1, 1, true)
        end,
        controls = { Choice("enemyAlive", YESNO_LIST, "yes") },
    })

    -- the resources of your class: they change with the class (runic power and runes for a
    -- Death Knight, mana and holy power for a Paladin, ...)
    local resource = page:Card("Resources")
    resource:Condition({
        label = function()
            local primary = HeadsUp_GetResources().primary
            return (primary and primary.name or "Resource") .. " is"
        end,
        key = "powerEnabled",
        tip = Tip("Main resource", "Your main resource (Runic Power, Mana, Rage...): it follows your class.", "Mana is compared in percent, the others in points."),
        usable = function(d) return HasAbility(d) and HeadsUp_GetResources().primary ~= nil end,
        controls = {
            Choice("powerOp", OP_LIST, "<"),
            Choice("powerValue", function()
                local primary = HeadsUp_GetResources().primary
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
    resource:Condition({
        label = function()
            local second = HeadsUp_GetResources().secondary
            return second and (second.name .. ":") or "No second resource for your class"
        end,
        key = "secEnabled",
        tip = Tip("Second resource", "Your second resource, if your class has one: ready Runes, Holy Power, Combo Points, Soul Shards, Chi...", "It follows your class. The points you have right now are compared with the number you choose."),
        usable = function(d) return HasAbility(d) and HeadsUp_GetResources().secondary ~= nil end,
        controls = {
            Choice("secOp", OP_LIST, ">="),
            Choice("secValue", function()
                local second = HeadsUp_GetResources().secondary
                local list = {}
                for v = 0, second and second.max or 5 do list[#list + 1] = { value = v, text = tostring(v) } end
                return list
            end, 1),
        },
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
            return HasAbility(d) and (hasCost or hasCooldown)
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
            return HasAbility(d) and hasCooldown
        end,
        controls = { Choice("cdState", CD_LIST, "cooling") },
    })

    local charges = page:Card("Charges")
    local function chargesUsable(d)
        local _, _, maxCharges = Facts(d)
        return HasAbility(d) and maxCharges > 1
    end
    charges:Condition({
        label = "Charges ready", key = "chargesEnabled", usable = chargesUsable,
        tip = Tip("Charges", "For abilities that have several charges (like Death and Decay).", "At least 1: a charge is ready.  All: none of the charges is recharging."),
        controls = { Choice("chargesState", ChargesList, "any") },
    })
    local hideTimer = Number("suppressSeconds", 1, 300, 10, "sec")
    charges:Condition({
        label = "After I cast it, hide for", key = "suppressEnabled", usable = chargesUsable,
        tip = Tip("Hide after a cast", "After you cast the ability, the icon hides for this many seconds (for example while its effect lasts).", "The time is suggested from the description of the ability: you can change it."),
        controls = { hideTimer },
    })
    charges:Note({
        text = function(d)
            if HasAbility(d) and not chargesUsable(d) then
                return "This ability has only one charge, so these rows are not used."
            end
            return "The hide time is suggested from the ability's description."
        end,
    })

    local empowered = page:Card("Empowered")
    -- needs an ability that the addon has seen light up (or one that already uses the row)
    local function empoweredUsable(d)
        return HasAbility(d)
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
            local seen = d and d.spellID and HeadsUp_GetLearned()[d.spellID]
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
    empowered:Condition({
        label = "Ignore the other conditions",
        key = "buffAlways",
        indent = true,
        -- only with "Empowered: active" ticked
        usable = function(d)
            return empoweredUsable(d) and d.buffEnabled and d.buffState ~= "gone" and true or false
        end,
        tip = function(tt)
            tt:AddLine("Ignore the other conditions", 1, 0.82, 0)
            tt:AddLine("Show the icon when the conditions are met, or whenever the ability is empowered, whatever the other conditions say (health, resource, enemy, cooldown...).", 1, 1, 1, true)
            tt:AddLine(" ")
            tt:AddLine("Example: Death Strike shows when your health is low and you have the Runic Power. With this on, it also shows when Dark Succor makes it free, even at full health or without Runic Power.", 1, 1, 1, true)
            tt:AddLine(" ")
            tt:AddLine("The Situation card still applies: where it shows (combat, mounted...), for which specializations, and the hide time after a cast.", 0.7, 0.7, 0.7, true)
        end,
    })

    -- A sound the moment the icon appears. It is an option of Empowered: the lighting up of the ability is one of the
    -- few things the game lets the addon read in combat. The game hides health, the main resource, cooldown and
    -- charges, so with those conditions the addon cannot know when the icon shows (unless the second icon of
    -- "Ignore the other conditions" does it).
    local function hiddenConditions(d)
        local names = {}
        if d.healthEnabled then names[#names + 1] = "your health" end
        if d.enemyEnabled then names[#names + 1] = "enemy health" end
        if d.powerEnabled then names[#names + 1] = "the main resource" end
        local _, hasCooldown = Facts(d)
        if d.availEnabled and hasCooldown then names[#names + 1] = "available (this ability has a cooldown)" end
        if d.cdEnabled then names[#names + 1] = "cooldown" end
        if d.chargesEnabled then names[#names + 1] = "charges" end
        return names
    end
    local function overrides(d) return d.buffEnabled and d.buffAlways and d.buffState ~= "gone" end
    local function soundUsable(d)
        if not (HasAbility(d) and d.buffEnabled and d.buffState ~= "gone") then return false end
        return (overrides(d) or #hiddenConditions(d) == 0) and true or false
    end
    local soundList = {}
    for _, item in ipairs(HeadsUpSounds) do soundList[#soundList + 1] = { value = item.key, text = item.text } end

    empowered:Condition({
        label = "Play a sound when it shows",
        key = "soundEnabled",
        indent = true,
        usable = soundUsable,
        tip = function(tt, d)
            tt:AddLine("Play a sound when it shows", 1, 0.82, 0)
            tt:AddLine("A short sound the moment the icon appears because the ability is empowered. Choose the sound in the list: it plays once so you can hear it.", 1, 1, 1, true)
            tt:AddLine(" ")
            tt:AddLine("With \"Ignore the other conditions\" it sounds whenever the ability lights up. Without it, it works only if the other conditions can be read in combat (the second resource, the enemy alive, \"available\" for an ability without a cooldown).", 0.7, 0.7, 0.7, true)
            if d and d.buffEnabled and d.buffState ~= "gone" then
                local names = hiddenConditions(d)
                if #names > 0 and not overrides(d) then
                    tt:AddLine(" ")
                    tt:AddLine("Not available now: the game hides " .. table.concat(names, ", ") .. " in combat. Tick \"Ignore the other conditions\", or remove them.", 1, 0.5, 0.5, true)
                end
            end
        end,
        controls = { Choice("soundKey", soundList, "ding", {
            onPick = function(key)
                local d = HeadsUp_GetDraft()
                HeadsUp_PlaySound(key, d and d.soundVolume or 2)
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
                local d = HeadsUp_GetDraft()
                if d then HeadsUp_PlaySound(d.soundKey, volume) end
            end,
        }) },
    })
end

------------------------------------------------------------
-- STEP 4: Situation (when and for whom it shows)
------------------------------------------------------------
local function BuildSituationPage(page)
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
                                d.showRules[key] = (not d.showRules[key]) or nil
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

    local who = page:Card("Specializations")
    who:Field({
        label = "Show it for",
        tip = Tip("Specializations", "The specializations of your class this aura belongs to. It shows only while you play one of them."),
        usable = HasAbility,
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
local STEPS = {
    { label = "Aura", build = BuildAuraPage,
        tip = "What the aura is: the ability, its name, the picture, the size, the place on the screen and the look." },
    { label = "Status", build = BuildConditionsPage,
        tip = "When it shows, part 1: your health, the enemy's health, your resources." },
    { label = "Ability", build = BuildAbilityPage,
        tip = "When it shows, part 2: whether the ability is available, its cooldown and charges, and whether it is empowered." },
    { label = "Situation", build = BuildSituationPage,
        tip = "Where and for whom it shows: in combat, mounted, in a vehicle, and for which specializations." },
}
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

local tabWidth = math.floor(MAIN_W / #STEPS)
for index, step in ipairs(STEPS) do
    local tab = CreateFrame("Button", nil, tabStrip)
    tab:SetSize(tabWidth, TAB_H)
    tab:SetPoint("TOPLEFT", tabStrip, "TOPLEFT", (index - 1) * tabWidth, 0)
    tab.text = UI.Text(tab, 13, C.muted, "CENTER")
    tab.text:SetPoint("CENTER", 0, 1)
    tab.text:SetText(index .. "   " .. step.label)
    tab.bar = tab:CreateTexture(nil, "OVERLAY")
    tab.bar:SetPoint("BOTTOMLEFT", 0, 0)
    tab.bar:SetPoint("BOTTOMRIGHT", 0, 0)
    tab.bar:SetHeight(2)
    tab.bar:SetColorTexture(unpack(C.accent))
    function tab:Paint()
        local selected = currentStep == index
        self.bar:SetShown(selected)
        local color = selected and C.accent or (self.hover and C.text or C.muted)
        self.text:SetTextColor(unpack(color))
    end
    tab:SetScript("OnEnter", function(self) self.hover = true; self:Paint() end)
    tab:SetScript("OnLeave", function(self) self.hover = false; self:Paint() end)
    tab:SetScript("OnClick", function() SetStep(index) end)
    UI.Tip(tab, Tip(index .. "  " .. step.label, step.tip))
    step.tab = tab
end

for _, step in ipairs(STEPS) do
    step.page = UI.NewPage(content)
    step.build(step.page)
    step.page:Finish()
end

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

local backButton = UI.Button(footer, "Back", 100)
backButton:SetPoint("LEFT", footer, "LEFT", 16, 0)
backButton:SetScript("OnClick", function() SetStep(currentStep - 1) end)
UI.Tip(backButton, Tip("Back", "Goes to the previous step."))

local nextButton = UI.Button(footer, "Next", 100)
nextButton:SetPoint("LEFT", backButton, "RIGHT", L.GAP, 0)
nextButton:SetScript("OnClick", function() SetStep(currentStep + 1) end)
UI.Tip(nextButton, Tip("Next", "Goes to the next step."))

local saveButton = UI.Button(footer, "Save aura", 120, true)
saveButton:SetPoint("RIGHT", footer, "RIGHT", -16, 0)
UI.Tip(saveButton, Tip("Save aura", "Saves the aura and adds it to the list on the left.", "If you close the window without saving, the changes are lost. Needs an ability."))

local Refresh, RefreshList

-- the top of the window and the buttons that depend on the draft
local function UpdateChrome()
    local d = HeadsUp_GetDraft()
    saveButton:SetOn(d ~= nil and d.spellID ~= nil)
    local specIndex = GetSpecialization()
    local specName = specIndex and select(2, GetSpecializationInfo(specIndex)) or "?"
    whoText:SetText(UnitClass("player") .. " - " .. specName)
end

function SetStep(index)
    index = UI.Clamp(index, 1, #STEPS)
    UI.ClearFocus()
    UI.ClosePopup()
    currentStep = index
    for i, step in ipairs(STEPS) do
        step.page.frame:SetShown(i == index)
        step.tab:Paint()
    end
    STEPS[index].page.frame:SetVerticalScroll(0)
    backButton:SetOn(index > 1)
    nextButton:SetOn(index < #STEPS)
end

UI.onChange = function()
    HeadsUp_ApplyDraft()
    UI.SyncAll()
    UpdateChrome()
end

saveButton:SetScript("OnClick", function()
    UI.ClearFocus()
    if HeadsUp_Save() then
        print("|cffff8800HeadsUp:|r aura saved")
        -- saving finishes the edit: unselect everything, back to a blank new aura
        HeadsUp_ClearPreviews()
        HeadsUp_BeginEdit(nil)
        SetStep(1)
        Refresh()
        RefreshList()
    else
        print("|cffff8800HeadsUp:|r choose an ability first")
    end
end)

function Refresh()
    if not HeadsUp_GetDraft() then return end
    UI.SyncAll()
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
StaticPopupDialogs["HEADSUP_RENAME"] = {
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
        HeadsUp_RenameAura(data.index, strtrim(eb:GetText()))
        Refresh()
        RefreshList()
    end,
}

StaticPopupDialogs["HEADSUP_DELETE"] = {
    text = "Delete the aura \"%s\"? This cannot be undone.",
    button1 = "Delete",
    button2 = CANCEL,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnAccept = function(_, data)
        if HeadsUp_DeleteAura(data.index) then
            HeadsUp_BeginEdit(nil)
        end
        Refresh()
        RefreshList()
    end,
}

local ROW_HEIGHT = 30
local LIST_TOP = 44
local rows = {}
-- the list has two parts that scroll on their own: the active auras, and (under a line) the hidden ones
local activeOffset, hiddenOffset = 0, 0
local HIDDEN_SHARE = 0.4   -- the inactive part never takes more than this share of the list
local listBars = {}        -- the thin scroll bars of the two parts (made below)
local listState = {}       -- what RefreshList last showed: how many rows each part has and how many fit

local function VisibleRows()
    local room = frame:GetHeight() - HEADER_H - LIST_TOP - 14   -- (the help is in the tooltip of each row)
    return math.max(1, math.floor(room / ROW_HEIGHT))
end

local function AuraMenu(row)
    local index = row.index
    local a = HeadsUp_GetAuras()[index]
    if not a then return end
    -- one aura at a time: while another aura is open for editing (until Save, or until
    -- it is unselected / the window is closed) or a new one has unsaved work, no Edit
    local editing = HeadsUp_GetEditIndex()
    local blocked = (editing ~= nil and editing ~= index) or HeadsUp_IsDirty()
    if editing == index then blocked = false end
    local items = {
        { text = "Rename", onClick = function()
            StaticPopup_Show("HEADSUP_RENAME", nil, nil, { index = index, name = a.name })
        end },
        { text = "Edit", disabled = (HeadsUp_PreviewCount() > 1 or blocked), onClick = function()
            HeadsUp_ClearPreviews()
            HeadsUp_BeginEdit(index)
            HeadsUp_SetPreview(index, true)
            SetStep(1)
            Refresh()
            RefreshList()
        end },
        { text = "Duplicate", onClick = function()
            HeadsUp_DuplicateAura(index)
            RefreshList()
        end },
        { text = a.hidden and "Activate" or "Deactivate", onClick = function()
            HeadsUp_SetHidden(index, not a.hidden)
            RefreshList()
        end },
        { text = "Delete", onClick = function()
            StaticPopup_Show("HEADSUP_DELETE", a.name or "this aura", nil, { index = index })
        end },
    }
    UI.OpenPopup(row, items, 150)
end

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
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(22, 22)
    row.icon:SetPoint("LEFT", 4, 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    row.text = UI.Text(row, 12, C.text)
    -- green square = selected: its placeholder is on screen
    row.dot = row:CreateTexture(nil, "OVERLAY")
    row.dot:SetSize(8, 8)
    row.dot:SetPoint("RIGHT", -8, 0)
    row.dot:SetColorTexture(unpack(C.good))
    row.text:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
    row.text:SetPoint("RIGHT", row.dot, "LEFT", -6, 0)
    row:EnableMouseWheel(true)
    row:SetScript("OnMouseWheel", function(self, delta)
        if self.section == "active" then
            activeOffset = activeOffset - delta
        else
            hiddenOffset = hiddenOffset - delta
        end
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
        local a = HeadsUp_GetAuras()[self.index]
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(a and a.name or "Aura", 1, 1, 1)
        if a and a.hidden then
            GameTooltip:AddLine("Inactive: it does not show in the game.", 0.8, 0.8, 0.8, true)
        end
        GameTooltip:AddLine("Right-click for more: rename, edit, duplicate, " .. ((a and a.hidden) and "activate" or "deactivate") .. ", delete.", 1, 0.82, 0, true)
        GameTooltip:AddLine("Click: show it on screen, to move it. Shift+click: show several at once.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function(self)
        self.hl:Hide()
        GameTooltip:Hide()
    end)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function(self, button)
        local index = self.index
        if self.header or not index then return end
        if button == "RightButton" then
            AuraMenu(self)
            return
        end
        UI.ClearFocus()
        -- click: select this one only (click again to unselect); shift+click: add / remove
        if IsShiftKeyDown() then
            HeadsUp_SetPreview(index, not HeadsUp_IsPreview(index))
        else
            local onlyThis = HeadsUp_IsPreview(index) and HeadsUp_PreviewCount() == 1
            HeadsUp_ClearPreviews()
            if not onlyThis then HeadsUp_SetPreview(index, true) end
        end
        -- unselecting the aura that is open for editing closes it (back to a blank new aura)
        if HeadsUp_GetEditIndex() == index and not HeadsUp_IsPreview(index) then
            HeadsUp_BeginEdit(nil)
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
local function ShowAuraRow(row, i, section)
    local auras = HeadsUp_GetAuras()
    local a = auras[i]
    local info = C_Spell.GetSpellInfo(a.spellID)
    row.header = false
    row.section = section
    row.index = i
    row.line:Hide()
    row.icon:Show()
    row.icon:SetTexture(a.icon or (info and info.iconID) or C_Spell.GetSpellTexture(a.spellID))
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
    row.bg:SetShown(i == HeadsUp_GetEditIndex())
    row.dot:SetShown(HeadsUp_IsPreview(i))
    row:Show()
end

-- the line between the two parts, with its title
local function ShowHeaderRow(row, count)
    row.header = true
    row.section = "hidden"
    row.index = nil
    row.icon:Hide()
    row.dot:Hide()
    row.bg:Hide()
    row.line:Show()
    row.text:ClearAllPoints()
    row.text:SetPoint("LEFT", row, "LEFT", 4, -3)
    row.text:SetPoint("RIGHT", row, "RIGHT", -4, -3)
    row.text:SetText("Inactive (" .. count .. ")")
    row.text:SetTextColor(unpack(C.muted))
    row:Show()
end

function RefreshList()
    local auras = HeadsUp_GetAuras()
    local class = HeadsUp_GetPlayerClass()
    local active, hidden = {}, {}
    for i, a in ipairs(auras) do
        if a.class == class and a.spellID then
            if a.hidden then hidden[#hidden + 1] = i else active[#active + 1] = i end
        end
    end

    -- the room: the hidden part takes what it needs, up to HIDDEN_SHARE of the list; the line
    -- and the active auras take the rest. Each part scrolls on its own.
    local total = VisibleRows()
    local hiddenSlots, headerSlots = 0, 0
    if #hidden > 0 then
        headerSlots = 1
        hiddenSlots = math.min(#hidden, math.max(1, math.floor(total * HIDDEN_SHARE)))
    end
    local activeSlots = math.max(1, total - hiddenSlots - headerSlots)
    activeOffset = UI.Clamp(activeOffset, 0, math.max(0, #active - activeSlots))
    hiddenOffset = UI.Clamp(hiddenOffset, 0, math.max(0, #hidden - hiddenSlots))

    local n = 0
    for k = 1, math.min(#active, activeSlots) do
        n = n + 1
        ShowAuraRow(GetRow(n), active[activeOffset + k], "active")
    end
    if #hidden > 0 then
        n = n + 1
        ShowHeaderRow(GetRow(n), #hidden)
        for k = 1, hiddenSlots do
            n = n + 1
            ShowAuraRow(GetRow(n), hidden[hiddenOffset + k], "hidden")
        end
    end
    for m = n + 1, #rows do rows[m]:Hide() end
    emptyText:SetShown(#active == 0 and #hidden == 0)

    -- the scroll bars: each one beside its own part of the list, only when that part has more than it can show
    local shownActive = math.min(#active, activeSlots)
    listState.active = { total = #active, slots = activeSlots, offset = activeOffset }
    listState.hidden = { total = #hidden, slots = hiddenSlots, offset = hiddenOffset }
    listBars.active:ClearAllPoints()
    listBars.active:SetPoint("TOPRIGHT", listPanel, "TOPRIGHT", -2, -LIST_TOP)
    listBars.active:SetHeight(math.max(1, shownActive * ROW_HEIGHT))
    listBars.hidden:ClearAllPoints()
    listBars.hidden:SetPoint("TOPRIGHT", listPanel, "TOPRIGHT", -2, -(LIST_TOP + (shownActive + 1) * ROW_HEIGHT))
    listBars.hidden:SetHeight(math.max(1, hiddenSlots * ROW_HEIGHT))
    listBars.active:Refresh()
    listBars.hidden:Refresh()
end

------------------------------------------------------------
-- opening, closing, events
------------------------------------------------------------
frame:SetScript("OnShow", function()
    UpdateFeedbackButton()
    HeadsUp_BeginEdit(nil)   -- starts a fresh working copy
    SetStep(1)
    Refresh()
    RefreshList()
    if HeadsUpDB and HeadsUp_DebugState then
        HeadsUpDB.state = HeadsUp_DebugState()   -- silent: read from the SavedVariables file
    end
end)
frame:SetScript("OnHide", function()
    feedbackPanel:Hide()
    UI.ClearFocus()
    UI.ClosePopup()
    picker:Hide()
    HeadsUp_ClearPreviews()
    HeadsUp_EndEdit()        -- discards anything not saved
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

-- called by HeadsUp.lua when an icon was dragged: the X and Y boxes show where it is now
function HeadsUp_PositionChanged()
    if frame:IsShown() then UI.SyncAll() end
end

function HeadsUp_ToggleSettings()
    frame:SetShown(not frame:IsShown())
end
