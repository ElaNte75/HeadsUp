-- HeadsUp Auras: a button on the minimap that opens and closes the window, and the same action from the
-- add-on menu of the minimap (the list of add-ons under the minimap button).
--   click: open / close the window       drag: move the button around the minimap
--   /hua minimap: hide or show the button

local ICON = "Interface\\AddOns\\HeadsUpAuras\\Media\\icon.tga"
local DEFAULT_ANGLE = 200   -- degrees: lower left of the minimap

local button

local function Settings()
    HeadsUpAurasDB = HeadsUpAurasDB or {}
    return HeadsUpAurasDB
end

local function Angle()
    return math.rad(Settings().minimapAngle or DEFAULT_ANGLE)
end

-- puts the button on the edge of the minimap, at an angle
local function Place()
    if not button then return end
    local angle = Angle()
    local x, y = math.cos(angle), math.sin(angle)
    local half = Minimap:GetWidth() / 2 + 4
    local shape = GetMinimapShape and GetMinimapShape() or "ROUND"
    if shape == "SQUARE" then   -- a square minimap: the edge is the square, not the circle
        local scale = math.max(math.abs(x), math.abs(y))
        x, y = x / scale, y / scale
    end
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", x * half, y * half)
end

local function ShowTooltip(owner)
    GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
    GameTooltip:AddLine("HeadsUp Auras", 1, 0.56, 0.12)
    GameTooltip:AddLine("Click: open or close the window.", 1, 1, 1, true)
    if owner == button then
        GameTooltip:AddLine("Drag: move this button around the minimap.", 0.7, 0.7, 0.7, true)
        GameTooltip:AddLine("/hua minimap: hide or show this button.", 0.7, 0.7, 0.7, true)
    end
    GameTooltip:Show()
end

local function Create()
    if button then return end
    button = CreateFrame("Button", "HeadsUpAurasMinimapButton", Minimap)
    button:SetSize(32, 32)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp")
    button:RegisterForDrag("LeftButton")

    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetSize(22, 22)
    background:SetPoint("CENTER", 0, 0)

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(ICON)
    icon:SetSize(22, 22)
    icon:SetPoint("CENTER", 0, 0)

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(54, 54)
    border:SetPoint("TOPLEFT", 0, 0)

    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    button:SetScript("OnClick", function() HeadsUpAuras_ToggleSettings() end)
    button:SetScript("OnEnter", ShowTooltip)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- dragging: the button follows the mouse around the minimap (only its angle is kept)
    button:SetScript("OnDragStart", function(self)
        GameTooltip:Hide()
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local scale = Minimap:GetEffectiveScale()
            local cx, cy = GetCursorPosition()
            Settings().minimapAngle = math.deg(math.atan2(cy / scale - my, cx / scale - mx)) % 360
            Place()
        end)
    end)
    button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
end

local function Refresh()
    if Settings().minimapHidden then
        if button then button:Hide() end
        return
    end
    Create()
    Place()
    button:Show()
end

-- /hua minimap
function HeadsUpAuras_ToggleMinimapButton()
    Settings().minimapHidden = not Settings().minimapHidden or nil
    Refresh()
end

-- the add-on menu of the minimap (the entries come from the lines AddonCompartment... of HeadsUpAuras.toc)
function HeadsUpAuras_OnCompartmentClick()
    HeadsUpAuras_ToggleSettings()
end
function HeadsUpAuras_OnCompartmentEnter(_, menuButton)
    ShowTooltip(menuButton)
end
function HeadsUpAuras_OnCompartmentLeave()
    GameTooltip:Hide()
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", Refresh)
