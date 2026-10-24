-- HeadsUp Auras: interface toolkit.
-- Our own look (no Blizzard frames or buttons), one set of sizes for everything.
--
-- The grid: every card is as wide as the page and has 6 columns. A control is 2 columns wide
-- (a dropdown, a number box, a button: all the same size); a wide text field takes 3 (half the row). The label of a
-- row takes the columns that are left. So every row of every page lines up the same way.
--
-- To add an option: add one Condition / Field line to a card in Settings.lua. Nothing here changes.

local UI = {}
HeadsUpAurasUI = UI

local FONT = STANDARD_TEXT_FONT

------------------------------------------------------------
-- look
------------------------------------------------------------
local C = {
    window     = { 0.045, 0.052, 0.072, 0.98 },
    panel      = { 0.070, 0.080, 0.108, 1 },
    card       = { 0.095, 0.108, 0.143, 1 },
    field      = { 0.043, 0.050, 0.068, 1 },
    fieldHover = { 0.075, 0.085, 0.115, 1 },
    popup      = { 0.060, 0.068, 0.092, 1 },
    border     = { 0.200, 0.230, 0.300, 1 },
    borderHi   = { 0.380, 0.430, 0.550, 1 },
    accent     = { 1.000, 0.560, 0.120, 1 },
    accentDim  = { 0.780, 0.420, 0.080, 1 },
    text       = { 0.920, 0.930, 0.950, 1 },
    muted      = { 0.580, 0.620, 0.700, 1 },
    disabled   = { 0.360, 0.390, 0.450, 1 },
    good       = { 0.350, 0.850, 0.450, 1 },
    warn       = { 1.000, 0.500, 0.450, 1 },
    gold       = { 1.000, 0.820, 0.000, 1 },
}
UI.C = C

-- sizes (pixels)
local L = {
    COLS = 6,
    COL_W = 67,       -- one column; the window and every control follow from it
    GAP = 8,
    CTRL_H = 22,      -- every control (dropdown, box, button, checkbox row) is this high
    ROW_H = 28,       -- one row of a card
    PAD = 14,         -- inside a card
    TITLE_H = 34,     -- the title of a card and the line under it
    CARD_GAP = 12,    -- between two cards
}
L.INNER_W = L.COLS * L.COL_W + (L.COLS - 1) * L.GAP
-- the gap between two boxes on one row (width and height, X and Y, two dropdowns...) is the same everywhere:
-- wide enough for the "=" button of the size
L.PAIR_GAP = L.CTRL_H + 4
L.PAGE_W = L.INNER_W + 2 * L.PAD
UI.L = L

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
UI.Clamp = clamp

local function rgba(c) return c[1], c[2], c[3], c[4] or 1 end

local function colX(col) return L.PAD + (col - 1) * (L.COL_W + L.GAP) end
local function spanW(span) return span * L.COL_W + (span - 1) * L.GAP end

------------------------------------------------------------
-- basic pieces
------------------------------------------------------------
function UI.Box(parent, bg, border, frameType, name)
    local f = CreateFrame(frameType or "Frame", name, parent, "BackdropTemplate")
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    f:SetBackdropColor(rgba(bg))
    f:SetBackdropBorderColor(rgba(border or C.border))
    return f
end

function UI.Text(parent, size, color, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(FONT, size or 12, "")
    local c = color or C.text
    fs:SetTextColor(rgba(c))
    fs:SetJustifyH(justify or "LEFT")
    fs:SetWordWrap(false)
    return fs
end

-- a small triangle pointing down, drawn with lines (no picture files needed)
local function Chevron(parent)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(9, 5)
    holder.lines = {}
    for i = 0, 4 do
        local t = holder:CreateTexture(nil, "OVERLAY")
        t:SetSize(9 - i * 2, 1)
        t:SetPoint("TOP", holder, "TOP", 0, -i)
        t:SetColorTexture(1, 1, 1, 1)
        holder.lines[#holder.lines + 1] = t
    end
    function holder:SetColor(c)
        for _, t in ipairs(self.lines) do t:SetVertexColor(c[1], c[2], c[3], 1) end
    end
    holder:SetColor(C.muted)
    return holder
end

-- a tooltip: fill(tooltip, draft) writes its lines
function UI.Tip(frame, fill)
    frame:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        fill(GameTooltip, HeadsUpAuras_GetDraft())
        GameTooltip:Show()
    end)
    frame:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

-- hover handling and a Paint() for anything that is clicked
local function Interactive(b, paint)
    b.Paint = paint
    b:HookScript("OnEnter", function(self) self.hover = true; self:Paint() end)
    b:HookScript("OnLeave", function(self) self.hover = false; self:Paint() end)
    function b:SetOn(on)
        self:SetEnabled(on and true or false)
        self:Paint()
    end
end

function UI.Button(parent, text, width, primary)
    local b = UI.Box(parent, C.field, C.border, "Button")
    b:SetSize(width, L.CTRL_H)
    b.label = UI.Text(b, 12, C.text, "CENTER")
    local inset = (width or 0) < 40 and 0 or 6   -- a very small button has no room for an edge
    b.label:SetPoint("LEFT", inset, 0)
    b.label:SetPoint("RIGHT", -inset, 0)
    b.label:SetText(text or "")
    Interactive(b, function(self)
        local on, hov = self:IsEnabled(), self.hover
        local bg, br, tx
        if not on then
            bg, br, tx = C.field, C.border, C.disabled
        elseif self.primary then   -- the highlighted look (can be switched: button.primary = true / false)
            bg, br, tx = hov and C.accent or C.accentDim, C.accent, C.text
        else
            bg, br, tx = hov and C.fieldHover or C.field, hov and C.borderHi or C.border, C.text
        end
        self:SetBackdropColor(rgba(bg))
        self:SetBackdropBorderColor(rgba(br))
        self.label:SetTextColor(rgba((on and self.textColor) or tx))   -- textColor: set by the owner
    end)
    b.primary = primary
    b:Paint()
    return b
end

-- a button with a small picture on its left
function UI.IconButton(parent, width, text)
    local b = UI.Button(parent, text, width)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(16, 16)
    b.icon:SetPoint("LEFT", 5, 0)
    b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    b.label:ClearAllPoints()
    b.label:SetPoint("LEFT", b.icon, "RIGHT", 6, 0)
    b.label:SetPoint("RIGHT", -6, 0)
    b.label:SetJustifyH("LEFT")
    return b
end

-- a checkbox with its label to the right
function UI.Check(parent, width, label)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(width, L.CTRL_H)
    b.box = UI.Box(b, C.field, C.border)
    b.box:SetSize(16, 16)
    b.box:SetPoint("LEFT", 0, 0)
    b.mark = b.box:CreateTexture(nil, "OVERLAY")
    b.mark:SetSize(8, 8)
    b.mark:SetPoint("CENTER")
    b.mark:SetColorTexture(rgba(C.accent))
    b.label = UI.Text(b, 12, C.text)
    b.label:SetPoint("LEFT", b.box, "RIGHT", 8, 0)
    b.label:SetPoint("RIGHT", b, "RIGHT", 0, 0)
    b.label:SetText(label or "")
    b.checked = false
    Interactive(b, function(self)
        local on, hov = self:IsEnabled(), self.hover
        self.box:SetBackdropBorderColor(rgba((on and hov) and C.borderHi or C.border))
        self.mark:SetColorTexture(rgba(on and C.accent or C.disabled))
        self.label:SetTextColor(rgba(on and C.text or C.disabled))
    end)
    function b:SetValue(v)
        self.checked = v and true or false
        self.mark:SetShown(self.checked)
    end
    b:SetValue(false)
    b:Paint()
    return b
end

-- a number / text box
local inputs = {}
function UI.Input(parent, width, o)
    o = o or {}
    local box = UI.Box(parent, C.field, C.border)
    box:SetSize(width, L.CTRL_H)
    local eb = CreateFrame("EditBox", nil, box)
    eb:SetFont(FONT, 12, "")
    eb:SetTextColor(rgba(C.text))
    eb:SetAutoFocus(false)
    if o.numeric then eb:SetNumeric(true) end
    eb:SetMaxLetters(o.maxLetters or 40)
    eb:SetPoint("TOPLEFT", box, "TOPLEFT", 8, 0)
    local rightInset = 8
    if o.unit then
        box.unit = UI.Text(box, 11, C.muted, "RIGHT")
        box.unit:SetPoint("RIGHT", box, "RIGHT", -8, 0)
        box.unit:SetText(o.unit)
        rightInset = 16 + (box.unit:GetStringWidth() or 20)
    end
    eb:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -rightInset, 0)
    eb:SetScript("OnEditFocusGained", function() box:SetBackdropBorderColor(rgba(C.accent)) end)
    eb:SetScript("OnEditFocusLost", function(self)
        box:SetBackdropBorderColor(rgba(C.border))
        if o.commit then o.commit(self) end
    end)
    eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnEscapePressed", function(self)
        if o.revert then o.revert(self) end
        self:ClearFocus()
    end)
    box.edit = eb
    function box:SetOn(on)
        eb:SetEnabled(on and true or false)
        self:SetAlpha(on and 1 or 0.45)
    end
    inputs[#inputs + 1] = eb
    return box
end

function UI.ClearFocus()
    for _, eb in ipairs(inputs) do
        if eb:HasFocus() then eb:ClearFocus() end
    end
end

------------------------------------------------------------
-- the popup list (dropdowns and menus)
------------------------------------------------------------
-- An item: { text, icon, selected = function() -> bool (draws a box; nil = no box), disabled,
--            keepOpen (stay open after the click), onClick = function() }
local MAXV, ITEM_H = 12, 22
local popup, blocker

local function renderPopup()
    local items = popup.items
    local n = #items
    local visible = math.min(n, MAXV)
    popup.offset = clamp(popup.offset, 0, math.max(0, n - visible))
    popup:SetHeight(visible * ITEM_H + 8)
    for i = 1, MAXV do
        local r = popup.rows[i]
        local item = items[popup.offset + i]
        if i <= visible and item then
            r.item = item
            local x = 8
            local isSel = item.selected and item.selected() or false
            if item.selected then
                r.mark:Show()
                r.mark:ClearAllPoints()
                r.mark:SetPoint("LEFT", 8, 0)
                r.fill:SetShown(isSel)
                x = 28
            else
                r.mark:Hide()
            end
            if item.icon then
                r.icon:Show()
                r.icon:ClearAllPoints()
                r.icon:SetPoint("LEFT", x, 0)
                r.icon:SetTexture(item.icon)
                x = x + 22
            else
                r.icon:Hide()
            end
            r.text:ClearAllPoints()
            r.text:SetPoint("LEFT", x, 0)
            r.text:SetPoint("RIGHT", -10, 0)
            r.text:SetText(item.text or "")
            r.text:SetTextColor(rgba(item.disabled and C.disabled or C.text))
            r:Show()
        else
            r.item = nil
            r:Hide()
        end
    end
    if n > MAXV then
        local trackH = popup:GetHeight() - 8
        local thumbH = math.max(14, trackH * MAXV / n)
        local travel = trackH - thumbH
        popup.thumb:SetHeight(thumbH)
        popup.thumb:ClearAllPoints()
        popup.thumb:SetPoint("TOPRIGHT", popup, "TOPRIGHT", -2, -4 - travel * popup.offset / (n - MAXV))
        popup.thumb:Show()
    else
        popup.thumb:Hide()
    end
end

local function popupWheel(_, delta)
    if not popup or not popup:IsShown() then return end
    popup.offset = popup.offset - delta
    renderPopup()
end

local function buildPopup()
    blocker = CreateFrame("Button", nil, UIParent)
    blocker:SetAllPoints(UIParent)
    blocker:SetFrameStrata("FULLSCREEN_DIALOG")
    blocker:SetFrameLevel(1)
    blocker:RegisterForClicks("AnyUp")
    blocker:Hide()
    blocker:SetScript("OnClick", function() UI.ClosePopup() end)

    popup = UI.Box(UIParent, C.popup, C.borderHi)
    _G.HeadsUpAurasPopup = popup
    popup:SetFrameStrata("FULLSCREEN_DIALOG")
    popup:SetFrameLevel(10)
    popup:EnableMouse(true)
    popup:EnableMouseWheel(true)
    popup:SetScript("OnMouseWheel", popupWheel)
    popup:SetScript("OnHide", function() blocker:Hide() end)
    popup:Hide()
    popup.offset = 0
    popup.items = {}

    popup.thumb = popup:CreateTexture(nil, "OVERLAY")
    popup.thumb:SetWidth(3)
    popup.thumb:SetColorTexture(rgba(C.borderHi))
    popup.thumb:Hide()

    popup.rows = {}
    for i = 1, MAXV do
        local r = CreateFrame("Button", nil, popup)
        r:SetHeight(ITEM_H)
        r:SetPoint("TOPLEFT", popup, "TOPLEFT", 4, -4 - (i - 1) * ITEM_H)
        r:SetPoint("RIGHT", popup, "RIGHT", -4, 0)
        r.hl = r:CreateTexture(nil, "BACKGROUND")
        r.hl:SetAllPoints()
        r.hl:SetColorTexture(1, 1, 1, 0.08)
        r.hl:Hide()
        r.mark = UI.Box(r, C.field, C.border)
        r.mark:SetSize(12, 12)
        r.fill = r.mark:CreateTexture(nil, "OVERLAY")
        r.fill:SetSize(6, 6)
        r.fill:SetPoint("CENTER")
        r.fill:SetColorTexture(rgba(C.accent))
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(16, 16)
        r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        r.text = UI.Text(r, 12, C.text)
        r:EnableMouseWheel(true)
        r:SetScript("OnMouseWheel", popupWheel)
        r:SetScript("OnEnter", function(self)
            if self.item and not self.item.disabled then self.hl:Show() end
            if self.item and self.item.tip then   -- (an item can explain itself: item.tip = function(tooltip))
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                self.item.tip(GameTooltip)
                GameTooltip:Show()
            end
        end)
        r:SetScript("OnLeave", function(self)
            self.hl:Hide()
            GameTooltip:Hide()
        end)
        r:SetScript("OnClick", function(self) UI.PopupClick(self) end)
        popup.rows[i] = r
    end
    tinsert(UISpecialFrames, "HeadsUpAurasPopup")
end

function UI.PopupOwner()
    if popup and popup:IsShown() then return popup.owner end
    return nil
end

function UI.OpenPopup(anchor, items, width)
    if not popup then buildPopup() end
    popup.items = items
    popup.owner = anchor
    popup.offset = 0
    -- start the list at the chosen item
    for index, item in ipairs(items) do
        if item.selected and item.selected() then
            popup.offset = math.max(0, index - 4)
            break
        end
    end
    -- wide enough for the longest item (a narrow dropdown may open a wider list)
    UI.measure = UI.measure or UI.Text(UIParent, 12, C.text)
    local widest = 0
    for _, item in ipairs(items) do
        UI.measure:SetText(item.text or "")
        widest = math.max(widest, UI.measure:GetStringWidth() + 34)
    end
    popup:SetWidth(math.max(width or anchor:GetWidth(), 120, widest))
    popup:ClearAllPoints()
    local height = math.min(#items, MAXV) * ITEM_H + 8
    local bottom = (anchor:GetBottom() or 0) * anchor:GetEffectiveScale()
    if bottom - height * popup:GetEffectiveScale() > 10 then
        popup:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    else
        popup:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 2)
    end
    renderPopup()
    blocker:Show()
    popup:Show()
    popup:Raise()
    if anchor.Paint then anchor:Paint() end
end

function UI.ClosePopup()
    if popup and popup:IsShown() then
        local owner = popup.owner
        popup.owner = nil
        popup:Hide()
        if owner and owner.Paint then owner:Paint() end
    end
    if blocker then blocker:Hide() end
end

function UI.PopupClick(row)
    local item = row.item
    if not item or item.disabled then return end
    if item.keepOpen then
        if item.onClick then item.onClick() end
        renderPopup()
    else
        UI.ClosePopup()
        if item.onClick then item.onClick() end
    end
end

function UI.Dropdown(parent, width, openFn)
    local b = UI.Box(parent, C.field, C.border, "Button")
    b:SetSize(width, L.CTRL_H)
    b.text = UI.Text(b, 12, C.text)
    b.text:SetPoint("LEFT", 8, 0)
    b.text:SetPoint("RIGHT", -24, 0)
    b.chev = Chevron(b)
    b.chev:SetPoint("RIGHT", -9, 0)
    Interactive(b, function(self)
        local on = self:IsEnabled()
        local hov = on and (self.hover or UI.PopupOwner() == self)
        self:SetBackdropColor(rgba(hov and C.fieldHover or C.field))
        self:SetBackdropBorderColor(rgba(hov and C.borderHi or C.border))
        self.text:SetTextColor(rgba(on and C.text or C.disabled))
        self.chev:SetColor(on and C.muted or C.disabled)
    end)
    function b:SetLabel(t) self.text:SetText(t or "") end
    b:SetScript("OnClick", function(self)
        if UI.PopupOwner() == self then UI.ClosePopup() else openFn(self) end
    end)
    b:Paint()
    return b
end

------------------------------------------------------------
-- the colour palette: a small window of swatches (rows of lighter and darker colours, and a row of greys)
------------------------------------------------------------
local PALETTE_COLS, PALETTE_SWATCH, PALETTE_GAP = 12, 18, 2
local palette, paletteBlocker

local function HsvToRgb(h, s, v)
    local c = v * s
    local x = c * (1 - math.abs((h / 60) % 2 - 1))
    local m = v - c
    local r, g, b
    if h < 60 then r, g, b = c, x, 0
    elseif h < 120 then r, g, b = x, c, 0
    elseif h < 180 then r, g, b = 0, c, x
    elseif h < 240 then r, g, b = 0, x, c
    elseif h < 300 then r, g, b = x, 0, c
    else r, g, b = c, 0, x end
    return r + m, g + m, b + m
end

local function PaletteColors()
    local list = {}
    for i = 0, PALETTE_COLS - 1 do   -- greys, white to black
        local g = 1 - i / (PALETTE_COLS - 1)
        list[#list + 1] = { g, g, g }
    end
    for _, row in ipairs({ { 0.35, 1 }, { 0.65, 1 }, { 1, 1 }, { 1, 0.7 }, { 1, 0.45 } }) do
        for i = 0, PALETTE_COLS - 1 do
            local r, g, b = HsvToRgb(i * 30, row[1], row[2])
            list[#list + 1] = { r, g, b }
        end
    end
    return list
end

function UI.ClosePalette()
    if palette then palette:Hide() end
    if paletteBlocker then paletteBlocker:Hide() end
end

-- opens the palette under anchor; onPick(r, g, b) is called when a colour is clicked
function UI.OpenPalette(anchor, current, onPick)
    if not palette then
        paletteBlocker = CreateFrame("Button", nil, UIParent)
        paletteBlocker:SetAllPoints(UIParent)
        paletteBlocker:SetFrameStrata("FULLSCREEN_DIALOG")
        paletteBlocker:SetFrameLevel(20)
        paletteBlocker:RegisterForClicks("AnyUp")
        paletteBlocker:Hide()
        paletteBlocker:SetScript("OnClick", UI.ClosePalette)
        local pad = 8
        local width = pad * 2 + PALETTE_COLS * PALETTE_SWATCH + (PALETTE_COLS - 1) * PALETTE_GAP
        local colors = PaletteColors()
        local rowsCount = math.ceil(#colors / PALETTE_COLS)
        palette = UI.Box(UIParent, C.popup, C.borderHi)
        _G.HeadsUpAurasPalette = palette
        palette:SetFrameStrata("FULLSCREEN_DIALOG")
        palette:SetFrameLevel(30)
        palette:SetClampedToScreen(true)
        palette:EnableMouse(true)
        palette:SetSize(width, pad * 2 + rowsCount * PALETTE_SWATCH + (rowsCount - 1) * PALETTE_GAP)
        palette:SetScript("OnHide", function() paletteBlocker:Hide() end)
        palette:Hide()
        palette.swatches = {}
        for i, color in ipairs(colors) do
            local col, row = (i - 1) % PALETTE_COLS, math.floor((i - 1) / PALETTE_COLS)
            local b = UI.Box(palette, { color[1], color[2], color[3], 1 }, C.border, "Button")
            b:SetSize(PALETTE_SWATCH, PALETTE_SWATCH)
            b:SetPoint("TOPLEFT", palette, "TOPLEFT", pad + col * (PALETTE_SWATCH + PALETTE_GAP), -(pad + row * (PALETTE_SWATCH + PALETTE_GAP)))
            b.rgb = color
            b:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(rgba(C.accent)) end)
            b:SetScript("OnLeave", function(self) self:SetBackdropBorderColor(rgba(C.border)) end)
            b:SetScript("OnClick", function(self)
                UI.ClosePalette()
                if palette.onPick then palette.onPick(self.rgb[1], self.rgb[2], self.rgb[3]) end
            end)
            palette.swatches[i] = b
        end
        tinsert(UISpecialFrames, "HeadsUpAurasPalette")
    end
    palette.onPick = onPick
    palette:ClearAllPoints()
    palette:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    paletteBlocker:Show()
    palette:Show()
    palette:Raise()
end

------------------------------------------------------------
-- pages, cards, rows
------------------------------------------------------------
local registry = {}

function UI.SyncAll()
    local d = HeadsUpAuras_GetDraft()
    for _, w in ipairs(registry) do w.Sync(d) end
end

-- called after the player changed something: set UI.onChange to apply it and refresh
function UI.Changed()
    if UI.onChange then UI.onChange() else UI.SyncAll() end
end

-- Binds a definition to the draft: def.key, or def.get / def.set
local function Bind(def)
    local get = def.get or function(d) return d[def.key] end
    local set = def.set or function(d, v) d[def.key] = v end
    return get, set
end

-- Builds one control of a row. def.type: dropdown | input | button | link | slot | color | icon
local function MakeControl(card, def, x, y, w)
    local c = {}
    local f
    local kind = def.type
    if kind == "dropdown" then
        f = UI.Dropdown(card, w, function(self)
            UI.OpenPopup(self, def.items(HeadsUpAuras_GetDraft()))
        end)
        function c.Sync(d, on)
            f:SetLabel(d and def.text(d) or "")
            f:SetOn(on)
        end
        -- Automatic tooltip: when the closed box cannot show everything (the text is cut, or several choices
        -- are ticked and it only says "2 selected"), pointing at it lists the choices, one under the other.
        f:HookScript("OnEnter", function(self)
            if UI.PopupOwner() == self then return end
            local d = HeadsUpAuras_GetDraft()
            if not d then return end
            local okItems, items = pcall(def.items, d)
            if not okItems or type(items) ~= "table" then return end
            local chosen, multi = {}, false
            for _, item in ipairs(items) do
                if item.keepOpen then multi = true end
                if item.selected and item.selected() then chosen[#chosen + 1] = item.text or "" end
            end
            local cut = self.text:GetStringWidth() > (self.text:GetWidth() or 0) + 0.5
            if not ((multi and #chosen >= 2) or (cut and #chosen >= 1)) then return end
            local title = def._rowLabel
            if type(title) == "function" then title = title(d) end
            title = tostring(title or "Selected"):gsub("[:%s]+$", "")
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(title, 1, 0.82, 0)
            for _, text in ipairs(chosen) do GameTooltip:AddLine(text, 1, 1, 1) end
            GameTooltip:Show()
        end)
        f:HookScript("OnLeave", function() GameTooltip:Hide() end)
    elseif kind == "input" then
        local function current(d) return tostring(def.get(d) or "") end
        f = UI.Input(card, w, {
            numeric = def.numeric, maxLetters = def.maxLetters, unit = def.unit,
            commit = function(eb)
                if not UI.IsOpen() then return end
                local d = HeadsUpAuras_GetDraft()
                if not d then return end
                local v = eb:GetText()
                if def.numeric or def.signed then   -- signed: may start with a minus sign
                    v = tonumber(v)
                    if v then def.set(d, v) end
                else
                    def.set(d, v)
                end
                if def.noApply then UI.SyncAll() else UI.Changed() end
            end,
            revert = function(eb)
                local d = HeadsUpAuras_GetDraft()
                if d then eb:SetText(current(d)) end
            end,
        })
        function c.Sync(d, on)
            if d and not f.edit:HasFocus() then f.edit:SetText(current(d)) end
            f:SetOn(on)
        end
        -- an item can be dropped on the box (dragged from the bags): def.onItemDrop(d, itemID)
        if def.onItemDrop then
            local function take()
                local kind, id = GetCursorInfo()
                if kind ~= "item" and kind ~= "currency" then return end
                local d = HeadsUpAuras_GetDraft()
                if not d then return end
                ClearCursor()
                def.onItemDrop(d, id, kind)
                UI.Changed()
            end
            -- a link shift-clicked (an item in the bags, a currency in the currency window) while the box is selected
            UI.linkBoxes = UI.linkBoxes or {}
            UI.linkBoxes[#UI.linkBoxes + 1] = f.edit
            f.edit:SetScript("OnReceiveDrag", take)
            f.edit:HookScript("OnMouseUp", take)
            f:EnableMouse(true)
            f:SetScript("OnReceiveDrag", take)
            f:SetScript("OnMouseUp", take)
        end
    elseif kind == "button" then
        f = UI.Button(card, def.text, w)
        f:SetScript("OnClick", function()
            local d = HeadsUpAuras_GetDraft()
            if d then def.onClick(d, f) end
        end)
        function c.Sync(d, on)
            f:SetOn(on and (def.enabled == nil or def.enabled(d)))
        end
    elseif kind == "link" then
        -- a small toggle between two boxes (the width / height link): def.active(d) = switched on
        f = UI.Button(card, def.text or "x", w)
        f:SetScript("OnClick", function()
            local d = HeadsUpAuras_GetDraft()
            if d then def.onClick(d) end
        end)
        function c.Sync(d, on)
            local active = d and def.active(d)
            f.textColor = active and C.accent or C.muted
            f.label:SetText(active and (def.textOn or "=") or (def.textOff or "x"))
            f:SetOn(on)
        end
    elseif kind == "slot" then
        -- a box that holds one aura: drop an aura from the list on it (UI.dragUid is set while one is dragged), click it
        -- to pick from a list, right-click to empty it.
        -- def.info(d) -> name, icon, problem (text or nil); nil name = empty; def.items(d); def.onClear(d); def.onDrop(d, uid)
        f = UI.Box(card, C.field, C.border, "Button")
        f:SetSize(w, L.CTRL_H)
        f.icon = f:CreateTexture(nil, "ARTWORK")
        f.icon:SetSize(16, 16)
        f.icon:SetPoint("LEFT", 4, 0)
        f.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        f.text = UI.Text(f, 12, C.text)
        f.text:SetPoint("LEFT", f.icon, "RIGHT", 6, 0)
        f.text:SetPoint("RIGHT", -6, 0)
        f:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        Interactive(f, function(self)
            local on = self:IsEnabled()
            local hot = on and self.dropHot
            local hov = on and (self.hover or UI.PopupOwner() == self)
            self:SetBackdropColor(rgba((hot or hov) and C.fieldHover or C.field))
            self:SetBackdropBorderColor(rgba(hot and C.accent or (hov and C.borderHi or C.border)))
        end)
        f:SetScript("OnClick", function(self, button)
            local d = HeadsUpAuras_GetDraft()
            if not d then return end
            if button == "RightButton" then
                def.onClear(d)
                UI.Changed()
            elseif UI.PopupOwner() == self then
                UI.ClosePopup()
            else
                UI.OpenPopup(self, def.items(d), math.max(w, 200))
            end
        end)
        -- while an aura is dragged over the box it lights up
        f:SetScript("OnUpdate", function(self)
            local hot = UI.dragUid ~= nil and self:IsMouseOver() and true or false
            if hot ~= self.dropHot then
                self.dropHot = hot
                self:Paint()
            end
        end)
        function c.Sync(d, on)
            local name, icon, problem = nil, nil, nil
            if d then name, icon, problem = def.info(d) end
            if name then
                f.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
                f.icon:Show()
                f.text:SetText(name)
                f.text:SetTextColor(rgba(on and (problem and C.warn or C.text) or C.disabled))
            else
                f.icon:Hide()
                f.text:SetText("Drop an aura here")
                f.text:SetTextColor(rgba(C.disabled))
            end
            f:SetOn(on)
        end
        UI.drops = UI.drops or {}
        UI.drops[#UI.drops + 1] = { frame = f, drop = function(uid)
            local d = HeadsUpAuras_GetDraft()
            if d and f:IsEnabled() then
                def.onDrop(d, uid)
                UI.Changed()
            end
        end }
    elseif kind == "color" then
        -- a swatch of the colour; clicking it opens the palette. def.get(d) -> { r, g, b }; def.set(d, { r, g, b })
        f = UI.Box(card, C.field, C.border, "Button")
        f:SetSize(w, L.CTRL_H)
        f.swatch = f:CreateTexture(nil, "ARTWORK")
        f.swatch:SetPoint("TOPLEFT", 3, -3)
        f.swatch:SetPoint("BOTTOMRIGHT", -3, 3)
        Interactive(f, function(self)
            local on = self:IsEnabled()
            self:SetBackdropBorderColor(rgba(on and (self.hover and C.borderHi or C.border) or C.border))
            self.swatch:SetDesaturated(not on)
        end)
        f:SetScript("OnClick", function(self)
            local d = HeadsUpAuras_GetDraft()
            if not d then return end
            UI.ClosePopup()
            UI.OpenPalette(self, def.get(d), function(r, g, b)
                def.set(d, { r, g, b })
                UI.Changed()
            end)
        end)
        function c.Sync(d, on)
            local color = d and def.get(d) or { 1, 1, 1 }
            f.swatch:SetColorTexture(color[1], color[2], color[3], 1)
            f:SetOn(on)
        end
    elseif kind == "icon" then
        f = UI.IconButton(card, w, def.text)
        f:SetScript("OnClick", function()
            local d = HeadsUpAuras_GetDraft()
            if d then def.onClick(d, f) end
        end)
        function c.Sync(d, on)
            f.icon:SetTexture(d and def.icon(d) or "Interface\\Icons\\INV_Misc_QuestionMark")
            f.icon:SetDesaturated(not on)
            if def.label and d then f.label:SetText(def.label(d) or "") end   -- (a text that changes: def.label(d))
            f:SetOn(on)
        end
    else
        error("HeadsUp Auras UI: unknown control type " .. tostring(kind))
    end
    f:SetPoint("TOPLEFT", card, "TOPLEFT", x, -y)
    -- (a number box shows its tooltip from the box inside it: the frame around it has no mouse)
    if def.tip then UI.Tip(kind == "input" and f.edit or f, def.tip) end
    c.frame = f
    return c
end

local CardMethods = {}

-- the next row; returns where the top of a control of that row is
function CardMethods:AddRow()
    local y = self.used
    self.used = self.used + L.ROW_H
    self:SetHeight(self.used + 8)
    self.page.y = self.top + self:GetHeight() + L.CARD_GAP
    return y + (L.ROW_H - L.CTRL_H) / 2
end


-- The width of a standard dropdown: just wide enough for the longest word we put in one ("equal or above"),
-- so no letter is ever cut. Every standard dropdown gets this width and sits against the right edge;
-- the room it leaves goes to the label on its left. Measured once, with the game's own font.
function UI.DropdownWidth()
    if not L.DROP_W then
        local fs = UI.Text(UIParent, 12, C.text)
        fs:SetText("equal or above")
        L.DROP_W = math.min(spanW(2), math.ceil(fs:GetStringWidth()) + 36)   -- (8 left + 24 right inside the box + a little)
        fs:Hide()
    end
    return L.DROP_W
end

-- puts the controls of a row on the right, side by side; returns them and the columns they use
local function BuildControls(card, defs, y)
    -- controls with a width of their own (w, in pixels): placed side by side against the right edge
    if defs and #defs > 0 and defs[1].w then
        local total = 0
        for index, cd in ipairs(defs) do
            total = total + cd.w + (index < #defs and (cd.gap or L.GAP) or 0)   -- gap: pixels after it
        end
        local x = L.PAD + L.INNER_W - total
        local list = {}
        for _, cd in ipairs(defs) do
            list[#list + 1] = MakeControl(card, cd, x, card.rowY, cd.w)
            x = x + cd.w + (cd.gap or L.GAP)
        end
        return list, math.max(1, math.floor((L.INNER_W - total) / (L.COL_W + L.GAP))), 0
    end
    -- exactly two controls of two columns: both as wide as a dropdown, the second against the right edge, and the gap
    -- between them exactly L.PAIR_GAP (the same on every row). The label gets the room that is left.
    if defs and #defs == 2 and (defs[1].span or 2) == 2 and (defs[2].span or 2) == 2
        and (defs[1].extra or 0) == 0 and (defs[2].extra or 0) == 0
        and defs[1].type ~= "link" and defs[2].type ~= "link" then
        local boxW = UI.DropdownWidth()
        local x2 = L.PAD + L.INNER_W - boxW
        local x1 = x2 - L.PAIR_GAP - boxW
        local list = {
            MakeControl(card, defs[1], x1, card.rowY, boxW),
            MakeControl(card, defs[2], x2, card.rowY, boxW),
        }
        -- (the label is spanW(1) - GAP + slack wide, so that it ends one GAP before the first box)
        return list, 1, (x1 - L.PAD) - spanW(1)
    end
    local total = 0
    for _, cd in ipairs(defs or {}) do total = total + (cd.span or 2) end
    local col = L.COLS - total + 1
    local list = {}
    local slack = 0   -- the room freed on the left of the first control (for the label)
    for index, cd in ipairs(defs or {}) do
        local span = cd.span or 2
        local extra = cd.extra or 0   -- pixels added on the left (to line up with a wider field above)
        -- every control of two columns (dropdown, number box, button) is as wide as a dropdown: same edges on every row
        local shrink = (span == 2 and cd.type ~= "link") and (spanW(2) - UI.DropdownWidth()) or 0
        if index == 1 then slack = shrink end
        list[#list + 1] = MakeControl(card, cd, colX(col) - extra + shrink, card.rowY, spanW(span) + extra - shrink)
        col = col + span
    end
    return list, L.COLS - total, slack
end

-- label + controls. def = { label, usable = function(d) -> bool, controls = { ... }, tip }
function CardMethods:Field(def)
    self.rowY = self:AddRow()
    for _, cd in ipairs(def.controls or {}) do cd._rowLabel = def.label end   -- (for the automatic tooltip of a dropdown)
    local ctrls, labelSpan, slack = BuildControls(self, def.controls, self.rowY)
    local label = UI.Text(self, 12, C.text)
    label:SetPoint("LEFT", self, "TOPLEFT", L.PAD, -(self.rowY + L.CTRL_H / 2))
    label:SetWidth(spanW(labelSpan) - L.GAP + slack)
    if type(def.label) ~= "function" then label:SetText(def.label or "") end
    local hit
    if def.tip then
        -- the label itself gets the tooltip through a transparent hit area
        hit = CreateFrame("Frame", nil, self)
        hit:EnableMouse(true)
        hit:SetPoint("TOPLEFT", self, "TOPLEFT", L.PAD, -self.rowY)
        hit:SetSize(spanW(labelSpan) + slack, L.CTRL_H)
        UI.Tip(hit, def.tip)
    end
    registry[#registry + 1] = { Sync = function(d)
        local usable = d ~= nil and (def.usable == nil or def.usable(d)) and true or false
        if type(def.label) == "function" then label:SetText(d and def.label(d) or "") end
        label:SetTextColor(rgba(usable and C.text or C.disabled))
        for _, c in ipairs(ctrls) do c.Sync(d, usable) end
    end }
    -- the row: it can be hidden and shown (SetShown), its top is rowY
    local row = { y = self.rowY, label = label, controls = ctrls, hit = hit }
    function row:SetShown(on)
        self.label:SetShown(on)
        if self.hit then self.hit:SetShown(on) end
        for _, c in ipairs(self.controls) do c.frame:SetShown(on) end
    end
    return row
end

-- run fn(d) every time the widgets are synced with the draft (d = nil when no aura is open)
function UI.Register(fn)
    registry[#registry + 1] = { Sync = fn }
end

-- checkbox + label (+ controls that work only while it is ticked).
-- def = { label, key | get / set, usable, controls, tip }
function CardMethods:Condition(def)
    self.rowY = self:AddRow()
    local get, set = Bind(def)
    for _, cd in ipairs(def.controls or {}) do cd._rowLabel = def.label end   -- (for the automatic tooltip of a dropdown)
    local ctrls, labelSpan, slack = BuildControls(self, def.controls, self.rowY)
    local indent = def.indent and 26 or 0   -- a sub-option of the row above it
    local check = UI.Check(self, spanW(labelSpan) - (labelSpan < L.COLS and L.GAP or 0) - indent + slack,
        type(def.label) ~= "function" and def.label or "")
    check:SetPoint("TOPLEFT", self, "TOPLEFT", L.PAD + indent, -self.rowY)
    check:SetScript("OnClick", function()
        local d = HeadsUpAuras_GetDraft()
        if not d then return end
        set(d, not get(d))
        UI.Changed()
    end)
    if def.tip then UI.Tip(check, def.tip) end
    registry[#registry + 1] = { Sync = function(d)
        local usable = d ~= nil and (def.usable == nil or def.usable(d)) and true or false
        if type(def.label) == "function" then check.label:SetText(d and def.label(d) or "") end
        check:SetValue(d and get(d))
        check:SetOn(usable)
        local on = usable and (d and get(d) and true or false)
        for _, c in ipairs(ctrls) do c.Sync(d, on) end
    end }
end

-- one line of small grey text. def = { text = function(d) -> string, color = function(d) -> color }
function CardMethods:Note(def)
    self.rowY = self:AddRow()
    local fs = UI.Text(self, 11, C.muted)
    fs:SetPoint("LEFT", self, "TOPLEFT", L.PAD, -(self.rowY + L.CTRL_H / 2))
    fs:SetWidth(L.INNER_W)
    registry[#registry + 1] = { Sync = function(d)
        fs:SetText(d and def.text(d) or "")
        local c = d and def.color and def.color(d) or C.muted
        fs:SetTextColor(rgba(c))
    end }
end

-- A thin scroll bar of ours (dark and thin; orange and a little wider under the mouse). It is placed by the
-- caller (SetPoint on the returned frame). opts:
--   state()           -> shown (bool), size of the handle (0..1 of the line), position (0..1)
--   setPosition(p)    the handle was dragged to p (0..1)
--   page(direction)   a click on the line above (-1) or below (1) the handle
--   wheel(delta)      the mouse wheel on the line
-- Call bar:Refresh() whenever the state changed.
function UI.ScrollBar(parent, opts)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetWidth(8)
    bar:EnableMouse(true)
    bar:Hide()
    local track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetPoint("TOP")
    track:SetPoint("BOTTOM")
    track:SetWidth(1)
    track:SetColorTexture(0.13, 0.15, 0.20, 1)   -- a thin, dark line
    local thumb = CreateFrame("Button", nil, bar)
    local THUMB_W, THUMB_W_HOVER = 3, 5
    thumb:SetWidth(THUMB_W)
    thumb:SetHeight(40)
    local thumbBg = thumb:CreateTexture(nil, "ARTWORK")
    thumbBg:SetAllPoints()
    thumbBg:SetColorTexture(0.22, 0.25, 0.32, 1)   -- dark while it is not touched

    local dragging, dragStartY, dragStartPosition = false, 0, 0
    local currentPosition = 0

    local function paintThumb(hot)
        thumb:SetWidth(hot and THUMB_W_HOVER or THUMB_W)
        if hot then
            thumbBg:SetColorTexture(rgba(C.accent))
        else
            thumbBg:SetColorTexture(0.22, 0.25, 0.32, 1)
        end
    end

    function bar:Refresh()
        local shown, size, position = opts.state()
        if not shown then
            self:Hide()
            return
        end
        self:Show()
        local trackHeight = self:GetHeight()
        local thumbHeight = math.max(28, math.min(trackHeight, trackHeight * size))
        thumb:SetHeight(thumbHeight)
        currentPosition = position or 0
        thumb:ClearAllPoints()
        thumb:SetPoint("TOP", self, "TOP", 0, -(trackHeight - thumbHeight) * currentPosition)
    end

    local function cursorY()
        return (select(2, GetCursorPosition())) / UIParent:GetEffectiveScale()
    end

    thumb:SetScript("OnMouseDown", function()
        dragging = true
        dragStartY = cursorY()
        dragStartPosition = currentPosition
    end)
    thumb:SetScript("OnMouseUp", function()
        dragging = false
        paintThumb(thumb:IsMouseOver())
    end)
    thumb:SetScript("OnEnter", function() paintThumb(true) end)
    thumb:SetScript("OnLeave", function() if not dragging then paintThumb(false) end end)
    thumb:SetScript("OnUpdate", function()
        if not dragging then return end
        if not IsMouseButtonDown("LeftButton") then
            dragging = false
            paintThumb(thumb:IsMouseOver())
            return
        end
        local free = bar:GetHeight() - thumb:GetHeight()
        if free > 0 then
            opts.setPosition(clamp(dragStartPosition + (dragStartY - cursorY()) / free, 0, 1))
            bar:Refresh()
        end
    end)
    bar:SetScript("OnMouseDown", function()
        opts.page(cursorY() > (thumb:GetTop() or 0) and -1 or 1)
        bar:Refresh()
    end)
    bar:EnableMouseWheel(true)
    bar:SetScript("OnMouseWheel", function(_, delta)
        opts.wheel(delta)
        bar:Refresh()
    end)
    return bar
end

function UI.NewPage(parent)
    local scroll = CreateFrame("ScrollFrame", nil, parent)
    scroll:SetAllPoints(parent)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(L.PAGE_W, 10)
    scroll:SetScrollChild(child)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local range = self:GetVerticalScrollRange() or 0
        self:SetVerticalScroll(clamp(self:GetVerticalScroll() - delta * 40, 0, range))
    end)
    scroll:Hide()

    -- our own thin scroll bar on the right of the page (see UI.ScrollBar)
    local function range() return scroll:GetVerticalScrollRange() or 0 end
    local bar = UI.ScrollBar(parent, {
        state = function()
            local r = range()
            if r <= 1 or not scroll:IsShown() then return false end
            local view = scroll:GetHeight()
            return true, view / (view + r), clamp(scroll:GetVerticalScroll() / r, 0, 1)
        end,
        setPosition = function(position) scroll:SetVerticalScroll(clamp(position, 0, 1) * range()) end,
        page = function(direction)
            scroll:SetVerticalScroll(clamp(scroll:GetVerticalScroll() + direction * scroll:GetHeight() * 0.9, 0, range()))
        end,
        wheel = function(delta) scroll:SetVerticalScroll(clamp(scroll:GetVerticalScroll() - delta * 40, 0, range())) end,
    })
    bar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 11, 0)      -- the same place on every page
    bar:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 11, 0)
    scroll:SetScript("OnVerticalScroll", function() bar:Refresh() end)
    scroll:SetScript("OnScrollRangeChanged", function() bar:Refresh() end)
    scroll:HookScript("OnShow", function()
        bar:Refresh()
        C_Timer.After(0, function() bar:Refresh() end)   -- (the size of the page is known a moment later)
    end)
    scroll:HookScript("OnHide", function() bar:Hide() end)

    local page = { frame = scroll, child = child, y = 0 }

    function page:Card(title)
        local card = UI.Box(child, C.card, C.border)
        for k, v in pairs(CardMethods) do card[k] = v end
        card.page = self
        card.top = self.y
        card.used = L.TITLE_H
        card:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -self.y)
        card:SetWidth(L.PAGE_W)
        card:SetHeight(L.TITLE_H + 8)

        card.title = UI.Text(card, 13, C.accent)
        card.title:SetPoint("TOPLEFT", card, "TOPLEFT", L.PAD, -11)
        card.title:SetText(title or "")

        local line = card:CreateTexture(nil, "ARTWORK")
        line:SetPoint("TOPLEFT", card, "TOPLEFT", L.PAD, -(L.TITLE_H - 6))
        line:SetPoint("TOPRIGHT", card, "TOPRIGHT", -L.PAD, -(L.TITLE_H - 6))
        line:SetHeight(1)
        line:SetColorTexture(rgba(C.border))

        self.y = card.top + card:GetHeight() + L.CARD_GAP
        return card
    end

    function page:Finish()
        child:SetHeight(math.max(self.y - L.CARD_GAP, 10))   -- (no gap after the last card)
    end

    return page
end

-- shift-clicking an item or a currency puts its link into the box that is selected (the ones that accept an item)
local function TakeLink(link)
    if not link then return end
    for _, edit in ipairs(UI.linkBoxes or {}) do
        if edit:HasFocus() then
            edit:SetText(link)
            edit:ClearFocus()   -- (leaving the box takes what is in it)
            return
        end
    end
end
if hooksecurefunc then
    -- (the game has moved this function: both places are hooked, whichever exists)
    if ChatEdit_InsertLink then hooksecurefunc("ChatEdit_InsertLink", TakeLink) end
    if ChatFrameUtil and ChatFrameUtil.InsertLink then hooksecurefunc(ChatFrameUtil, "InsertLink", TakeLink) end
end
