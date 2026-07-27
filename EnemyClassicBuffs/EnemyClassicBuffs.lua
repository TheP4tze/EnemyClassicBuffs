local addonName, ECB = ...

local frame = CreateFrame("Frame")
local LCD
local db
local optionsCategoryID
local pendingRefresh
local cooldownFonts = {}

local MAX_COLUMNS = 20
local MAX_ROWS = 10
local TEST_AURA_COUNT = 25

local defaults = {
    databaseVersion = 2,
    welcomeShown = false,
    buffs = {
        enabled = true,
        columns = 8,
        rows = 2,
        size = 28,
        spacing = 3,
        cooldownFontSize = 10,
        unlocked = false,
        point = "TOPLEFT",
        relativePoint = "CENTER",
        x = 0,
        y = 130,
    },
    debuffs = {
        enabled = true,
        columns = 8,
        rows = 2,
        size = 28,
        spacing = 3,
        cooldownFontSize = 10,
        unlocked = false,
        point = "TOPLEFT",
        relativePoint = "CENTER",
        x = 0,
        y = 70,
    },
}

local testBuffSpellIDs = {
    642, 1022, 1044, 6940, 19752,
    20230, 22812, 29166, 17116, 16689,
}

local testDebuffSpellIDs = {
    118, 122, 339, 853, 408,
    2094, 5782, 8122, 15487, 1714,
}

-- Recursively fills missing saved-variable values without overwriting user settings.
local function ApplyDefaults(target, source)
    for key, value in pairs(source) do
        if type(value) == "table" then
            if type(target[key]) ~= "table" then
                target[key] = {}
            end
            ApplyDefaults(target[key], value)
        elseif target[key] == nil then
            target[key] = value
        end
    end
end

-- Rounds a numeric value to the nearest integer.
local function Round(value)
    return math.floor(value + 0.5)
end

-- Restricts a numeric value to the supplied inclusive range.
local function Clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

-- Builds a stable identity key used to merge API and combat-log aura records.
local function AuraKey(aura)
    -- Combat-log reconstruction often has no source unit token, while the
    -- matching Blizzard aura does. Spell identity is therefore the reliable
    -- merge key for this compact display.
    return tostring(aura.spellID or aura.name or "?")
end

-- Reads and normalizes one aura from the newest available Blizzard aura API.
local function ReadAPIAura(unit, index, filter)
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        local aura = C_UnitAuras.GetAuraDataByIndex(unit, index, filter)
        if not aura then return end
        return {
            name = aura.name,
            icon = aura.icon,
            applications = aura.applications or 0,
            dispelName = aura.dispelName,
            duration = aura.duration or 0,
            expirationTime = aura.expirationTime or 0,
            sourceUnit = aura.sourceUnit,
            isStealable = aura.isStealable,
            spellID = aura.spellId,
            fromCombatLog = false,
        }
    end

    local name, icon, applications, dispelName, duration, expirationTime,
        sourceUnit, isStealable, _, spellID = UnitAura(unit, index, filter)
    if not name then return end
    return {
        name = name,
        icon = icon,
        applications = applications or 0,
        dispelName = dispelName,
        duration = duration or 0,
        expirationTime = expirationTime or 0,
        sourceUnit = sourceUnit,
        isStealable = isStealable,
        spellID = spellID,
        fromCombatLog = false,
    }
end

-- Converts the positional LibClassicDurations result into a named aura table.
local function ReadTrackedAura(values)
    if not values then return end
    return {
        name = values[1],
        icon = values[2],
        applications = values[3] or 0,
        dispelName = values[4],
        duration = values[5] or 0,
        expirationTime = values[6] or 0,
        sourceUnit = values[7],
        isStealable = values[8],
        spellID = values[10],
        fromCombatLog = true,
    }
end

-- Collects target auras and merges Blizzard API data with combat-log records.
local function CollectMergedAuras(auraType)
    if not UnitExists("target") then
        return {}
    end

    local filter = auraType == "BUFF" and "HELPFUL" or "HARMFUL"
    local merged = {}
    local lookup = {}

    for index = 1, 100 do
        local aura = ReadAPIAura("target", index, filter)
        if not aura then break end
        local key = AuraKey(aura)
        lookup[key] = aura
        merged[#merged + 1] = aura
    end

    -- Blizzard's API data is valid for every target, including the player and
    -- friendly units. Combat-log reconstruction is used for attackable units,
    -- which also includes same-faction opponents during an active duel.
    if LCD and LCD.GetTrackedEnemyAuras
        and UnitCanAttack("player", "target")
    then
        local tracked = LCD:GetTrackedEnemyAuras("target", auraType)
        local now = GetTime()
        for _, values in ipairs(tracked) do
            local aura = ReadTrackedAura(values)
            if aura and aura.spellID then
                local key = AuraKey(aura)
                local existing = lookup[key]

                -- The API entry wins for identity and stacks, but combat-log
                -- timing fills gaps that the current client intentionally
                -- leaves at zero.
                if existing then
                    if (existing.duration or 0) <= 0
                        and (aura.duration or 0) > 0
                    then
                        existing.duration = aura.duration
                        existing.expirationTime = aura.expirationTime
                    end
                elseif (aura.duration or 0) > 0
                    and (aura.expirationTime or 0) > now
                then
                    lookup[key] = aura
                    merged[#merged + 1] = aura
                end
            end
        end
    end

    -- Sorts timed auras by expiration and permanent auras last.
    table.sort(merged, function(left, right)
        local leftExpiration = left.expirationTime or 0
        local rightExpiration = right.expirationTime or 0
        if leftExpiration == 0 then leftExpiration = math.huge end
        if rightExpiration == 0 then rightExpiration = math.huge end
        if leftExpiration == rightExpiration then
            return (left.spellID or 0) < (right.spellID or 0)
        end
        return leftExpiration < rightExpiration
    end)

    return merged
end

-- Stores an aura frame's current screen position in SavedVariables.
local function SavePosition(auraFrame)
    local config = db[auraFrame.configKey]
    local point, _, relativePoint, x, y = auraFrame:GetPoint(1)
    config.point = point
    config.relativePoint = relativePoint
    config.x = Round(x)
    config.y = Round(y)
end

-- Creates one reusable aura icon including cooldown, stack count, and tooltip.
local function CreateAuraButton(auraFrame)
    local button = CreateFrame("Button", nil, auraFrame)

    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetAllPoints()
    button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    button.cooldown = CreateFrame(
        "Cooldown",
        nil,
        button,
        "CooldownFrameTemplate"
    )
    button.cooldown:SetAllPoints()
    button.cooldown:SetDrawEdge(false)
    button.cooldown:SetDrawSwipe(true)
    button.cooldown:SetReverse(true)

    button.count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    button.count:SetPoint("BOTTOMRIGHT", 1, 1)

    button.logMarker = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    button.logMarker:SetPoint("TOPLEFT", 1, -1)
    button.logMarker:SetText("|cff66ccffL|r")

    -- Displays the spell tooltip for the aura under the mouse cursor.
    button:SetScript("OnEnter", function(self)
        if not self.spellID then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if GameTooltip.SetSpellByID then
            GameTooltip:SetSpellByID(self.spellID)
        else
            GameTooltip:SetText(self.auraName or ("Spell " .. self.spellID))
        end
        if self.fromCombatLog then
            GameTooltip:AddLine(
                "Reconstructed from combat log",
                0.4, 0.8, 1
            )
        end
        GameTooltip:Show()
    end)
    -- Hides the aura tooltip when the cursor leaves the icon.
    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    auraFrame.buttons[#auraFrame.buttons + 1] = button
    return button
end

-- Expands a frame's reusable button pool to the requested size.
local function EnsureButtons(auraFrame, amount)
    while #auraFrame.buttons < amount do
        CreateAuraButton(auraFrame)
    end
end

-- Applies the configured outlined countdown font to a cooldown widget.
local function ApplyCooldownFont(button, fontSize)
    fontSize = Clamp(Round(fontSize or 10), 6, 32)
    local fontPath = "Fonts\\FRIZQT__.TTF"

    if button.cooldown.SetCountdownFont then
        local fontName = "EnemyClassicBuffsCooldownFont" .. fontSize
        if not cooldownFonts[fontSize] then
            local fontObject = _G[fontName] or CreateFont(fontName)
            fontObject:SetFont(fontPath, fontSize, "OUTLINE")
            cooldownFonts[fontSize] = fontObject
        end
        button.cooldown:SetCountdownFont(fontName)
    end

    -- Compatibility fallback for Classic clients that expose the generated
    -- countdown text only as a region of the Cooldown frame.
    for _, region in ipairs({ button.cooldown:GetRegions() }) do
        if region.GetObjectType
            and region:GetObjectType() == "FontString"
        then
            region:SetFont(fontPath, fontSize, "OUTLINE")
        end
    end
end

-- Calculates frame dimensions and positions icons from left to right.
local function LayoutFrame(auraFrame, displayCount)
    local config = db[auraFrame.configKey]
    local columns = Clamp(Round(config.columns), 1, MAX_COLUMNS)
    local configuredRows = Clamp(Round(config.rows), 1, MAX_ROWS)
    local rows

    if config.unlocked then
        rows = math.max(configuredRows, math.ceil(TEST_AURA_COUNT / columns))
    else
        rows = configuredRows
    end

    local capacity = columns * rows
    local size = Clamp(Round(config.size), 16, 64)
    local gap = Clamp(Round(config.spacing or 3), 0, 20)
    local titleHeight = config.unlocked and 18 or 0
    local width = columns * size + math.max(columns - 1, 0) * gap
    local height = rows * size + math.max(rows - 1, 0) * gap + titleHeight

    auraFrame:SetSize(math.max(width, 1), math.max(height, 1))
    EnsureButtons(auraFrame, math.max(capacity, displayCount or 0))

    for index, button in ipairs(auraFrame.buttons) do
        button:ClearAllPoints()
        button:SetSize(size, size)

        -- The first icon starts at the frame's left edge. Every following
        -- column grows to the right in normal reading order.
        local column = (index - 1) % columns
        local row = math.floor((index - 1) / columns)
        button:SetPoint(
            "TOPLEFT",
            auraFrame,
            "TOPLEFT",
            column * (size + gap),
            -titleHeight - row * (size + gap)
        )

        button.count:SetFont(
            "Fonts\\FRIZQT__.TTF",
            math.max(9, math.floor(size * 0.42)),
            "OUTLINE"
        )
        ApplyCooldownFont(button, config.cooldownFontSize)
    end

    auraFrame.title:SetHeight(18)
    auraFrame.title:SetShown(config.unlocked)
    auraFrame:EnableMouse(config.unlocked)
    return capacity
end

-- Populates one icon button from a normalized aura record.
local function SetButtonAura(button, aura)
    button.spellID = aura.spellID
    button.auraName = aura.name
    button.fromCombatLog = aura.fromCombatLog
    button.icon:SetTexture(aura.icon or 134400)

    if (aura.applications or 0) > 1 then
        button.count:SetText(aura.applications)
    else
        button.count:SetText("")
    end

    button.logMarker:SetShown(aura.fromCombatLog)

    local duration = aura.duration or 0
    local expirationTime = aura.expirationTime or 0
    if duration > 0 and expirationTime > 0 then
        button.cooldown:SetCooldown(expirationTime - duration, duration)
        ApplyCooldownFont(
            button,
            db[button:GetParent().configKey].cooldownFontSize
        )
        button.cooldown:Show()
    else
        button.cooldown:Clear()
        button.cooldown:Hide()
    end

    button:Show()
end

-- Generates 25 deterministic preview auras for frame positioning.
local function FillTestAuras(auraFrame)
    local spellIDs = auraFrame.auraType == "BUFF"
        and testBuffSpellIDs
        or testDebuffSpellIDs
    local results = {}

    for index = 1, TEST_AURA_COUNT do
        local spellID = spellIDs[((index - 1) % #spellIDs) + 1]
        results[index] = {
            name = GetSpellInfo(spellID) or ("Test " .. index),
            icon = GetSpellTexture(spellID) or 134400,
            applications = (index % 5 == 0) and 3 or 0,
            duration = 120,
            expirationTime = GetTime() + 120,
            spellID = spellID,
            fromCombatLog = index % 2 == 0,
        }
    end

    return results
end

-- Refreshes one aura frame from live data or preview data.
local function UpdateAuraFrame(auraFrame)
    local config = db[auraFrame.configKey]
    if not config.enabled then
        auraFrame:Hide()
        return
    end

    local auras = config.unlocked
        and FillTestAuras(auraFrame)
        or CollectMergedAuras(auraFrame.auraType)
    local capacity = LayoutFrame(auraFrame, #auras)
    local visibleCount = config.unlocked
        and TEST_AURA_COUNT
        or math.min(#auras, capacity)

    for index, button in ipairs(auraFrame.buttons) do
        if index <= visibleCount and auras[index] then
            SetButtonAura(button, auras[index])
        else
            button.spellID = nil
            button:Hide()
        end
    end

    if config.unlocked then
        auraFrame:Show()
    elseif visibleCount > 0 and UnitExists("target") then
        auraFrame:Show()
    else
        auraFrame:Hide()
    end
end

-- Creates a movable transparent frame for either buffs or debuffs.
local function CreateAuraFrame(configKey, auraType, title)
    local auraFrame = CreateFrame("Frame", nil, UIParent)
    auraFrame.configKey = configKey
    auraFrame.auraType = auraType
    auraFrame.buttons = {}
    auraFrame:SetMovable(true)
    auraFrame:SetClampedToScreen(true)
    auraFrame:SetFrameStrata("MEDIUM")

    local config = db[configKey]
    auraFrame:SetPoint(
        config.point,
        UIParent,
        config.relativePoint,
        config.x,
        config.y
    )

    auraFrame.title = CreateFrame("Frame", nil, auraFrame)
    auraFrame.title:SetPoint("TOPLEFT")
    auraFrame.title:SetPoint("TOPRIGHT")
    auraFrame.title:EnableMouse(true)
    auraFrame.title:RegisterForDrag("LeftButton")
    -- Starts moving the frame only while its configuration is unlocked.
    auraFrame.title:SetScript("OnDragStart", function()
        if db[configKey].unlocked then
            auraFrame:StartMoving()
        end
    end)
    -- Stops moving the frame and persists the resulting position.
    auraFrame.title:SetScript("OnDragStop", function()
        auraFrame:StopMovingOrSizing()
        SavePosition(auraFrame)
    end)

    local titleText = auraFrame.title:CreateFontString(
        nil,
        "OVERLAY",
        "GameFontNormalSmall"
    )
    titleText:SetPoint("RIGHT", -2, 0)
    titleText:SetText(title .. " - UNLOCKED (drag here)")

    return auraFrame
end

-- Refreshes both the buff and debuff displays.
local function RefreshAll()
    if not ECB.buffFrame or not ECB.debuffFrame then return end
    UpdateAuraFrame(ECB.buffFrame)
    UpdateAuraFrame(ECB.debuffFrame)
end

-- Coalesces multiple game events into one refresh on the next frame.
local function QueueRefresh()
    if pendingRefresh then return end
    pendingRefresh = true
    -- Executes the deferred refresh after all handlers for the current event.
    C_Timer.After(0, function()
        pendingRefresh = false
        RefreshAll()
    end)
end

-- Creates a consistently positioned options-panel label.
local function MakeLabel(parent, text, x, y, template)
    local label = parent:CreateFontString(
        nil,
        "ARTWORK",
        template or "GameFontNormal"
    )
    label:SetPoint("TOPLEFT", x, y)
    label:SetText(text)
    return label
end

-- Creates a numeric slider that immediately applies its setting.
local function MakeSlider(parent, labelText, x, y, minimum, maximum, step, getter, setter)
    MakeLabel(parent, labelText, x, y)

    local valueText = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    valueText:SetPoint("TOPLEFT", x + 255, y)

    local slider = CreateFrame("Slider", nil, parent)
    slider:SetOrientation("HORIZONTAL")
    slider:SetPoint("TOPLEFT", x, y - 22)
    slider:SetSize(280, 18)
    slider:SetMinMaxValues(minimum, maximum)
    slider:SetValueStep(step)
    slider:SetObeyStepOnDrag(true)

    local background = slider:CreateTexture(nil, "BACKGROUND")
    background:SetPoint("LEFT")
    background:SetPoint("RIGHT")
    background:SetHeight(4)
    background:SetColorTexture(0.25, 0.25, 0.25, 1)

    local thumb = slider:CreateTexture(nil, "ARTWORK")
    thumb:SetTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    thumb:SetSize(16, 16)
    slider:SetThumbTexture(thumb)

    -- Rounds, stores, and immediately applies a slider value.
    slider:SetScript("OnValueChanged", function(self, value)
        value = Round(value)
        valueText:SetText(value)
        setter(value)
        RefreshAll()
    end)

    -- Synchronizes the slider and its value label from SavedVariables.
    slider.Refresh = function(self)
        self:SetValue(getter())
        valueText:SetText(getter())
    end
    return slider
end

-- Creates a checkbox backed by getter and setter callbacks.
local function MakeCheckbox(parent, labelText, x, y, getter, setter)
    local checkbox = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    checkbox:SetPoint("TOPLEFT", x, y)
    checkbox:SetSize(26, 26)

    local label = checkbox:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    label:SetPoint("LEFT", checkbox, "RIGHT", 4, 0)
    label:SetText(labelText)

    -- Stores the checkbox state and refreshes the affected frames.
    checkbox:SetScript("OnClick", function(self)
        setter(self:GetChecked() and true or false)
        RefreshAll()
    end)
    -- Synchronizes the checkbox state from SavedVariables.
    checkbox.Refresh = function(self)
        self:SetChecked(getter())
    end
    return checkbox
end

-- Builds and registers the complete Blizzard Settings panel.
local function CreateOptionsPanel()
    local panel = CreateFrame("Frame")
    panel.name = addonName

    MakeLabel(panel, "EnemyClassicBuffs", 16, -16, "GameFontNormalLarge")
    MakeLabel(
        panel,
        "Target auras from the Blizzard API and combat log. Icons grow from the left anchor toward the right.",
        16,
        -44,
        "GameFontHighlight"
    )

    MakeLabel(panel, "Buff Frame", 16, -82, "GameFontNormalLarge")
    local buffEnabled = MakeCheckbox(
        panel,
        "Enable Buff Frame",
        16,
        -106,
        -- Returns whether the buff frame is enabled.
        function() return db.buffs.enabled end,
        -- Stores whether the buff frame is enabled.
        function(value) db.buffs.enabled = value end
    )
    local buffColumns = MakeSlider(
        panel, "Buffs per Row", 20, -154, 1, MAX_COLUMNS, 1,
        -- Returns the configured buff column count.
        function() return db.buffs.columns end,
        -- Stores the configured buff column count.
        function(value) db.buffs.columns = value end
    )
    local buffRows = MakeSlider(
        panel, "Buff Rows", 20, -210, 1, MAX_ROWS, 1,
        -- Returns the configured buff row count.
        function() return db.buffs.rows end,
        -- Stores the configured buff row count.
        function(value) db.buffs.rows = value end
    )
    local buffSize = MakeSlider(
        panel, "Buff Size", 20, -266, 16, 64, 1,
        -- Returns the configured buff icon size.
        function() return db.buffs.size end,
        -- Stores the configured buff icon size.
        function(value) db.buffs.size = value end
    )
    local buffSpacing = MakeSlider(
        panel, "Buff Spacing", 20, -322, 0, 20, 1,
        -- Returns the configured spacing between buff icons.
        function() return db.buffs.spacing end,
        -- Stores the configured spacing between buff icons.
        function(value) db.buffs.spacing = value end
    )
    local buffFontSize = MakeSlider(
        panel, "Cooldown Font Size", 20, -378, 6, 32, 1,
        -- Returns the configured buff countdown font size.
        function() return db.buffs.cooldownFontSize end,
        -- Stores the configured buff countdown font size.
        function(value) db.buffs.cooldownFontSize = value end
    )
    local buffUnlock = MakeCheckbox(
        panel,
        "Unlock Buff Frame (shows 25 test buffs)",
        16,
        -430,
        -- Returns whether the buff frame is unlocked.
        function() return db.buffs.unlocked end,
        -- Stores whether the buff frame is unlocked.
        function(value) db.buffs.unlocked = value end
    )

    MakeLabel(panel, "Debuff Frame", 370, -82, "GameFontNormalLarge")
    local debuffEnabled = MakeCheckbox(
        panel,
        "Enable Debuff Frame",
        370,
        -106,
        -- Returns whether the debuff frame is enabled.
        function() return db.debuffs.enabled end,
        -- Stores whether the debuff frame is enabled.
        function(value) db.debuffs.enabled = value end
    )
    local debuffColumns = MakeSlider(
        panel, "Debuffs per Row", 374, -154, 1, MAX_COLUMNS, 1,
        -- Returns the configured debuff column count.
        function() return db.debuffs.columns end,
        -- Stores the configured debuff column count.
        function(value) db.debuffs.columns = value end
    )
    local debuffRows = MakeSlider(
        panel, "Debuff Rows", 374, -210, 1, MAX_ROWS, 1,
        -- Returns the configured debuff row count.
        function() return db.debuffs.rows end,
        -- Stores the configured debuff row count.
        function(value) db.debuffs.rows = value end
    )
    local debuffSize = MakeSlider(
        panel, "Debuff Size", 374, -266, 16, 64, 1,
        -- Returns the configured debuff icon size.
        function() return db.debuffs.size end,
        -- Stores the configured debuff icon size.
        function(value) db.debuffs.size = value end
    )
    local debuffSpacing = MakeSlider(
        panel, "Debuff Spacing", 374, -322, 0, 20, 1,
        -- Returns the configured spacing between debuff icons.
        function() return db.debuffs.spacing end,
        -- Stores the configured spacing between debuff icons.
        function(value) db.debuffs.spacing = value end
    )
    local debuffFontSize = MakeSlider(
        panel, "Cooldown Font Size", 374, -378, 6, 32, 1,
        -- Returns the configured debuff countdown font size.
        function() return db.debuffs.cooldownFontSize end,
        -- Stores the configured debuff countdown font size.
        function(value) db.debuffs.cooldownFontSize = value end
    )
    local debuffUnlock = MakeCheckbox(
        panel,
        "Unlock Debuff Frame (shows 25 test debuffs)",
        370,
        -430,
        -- Returns whether the debuff frame is unlocked.
        function() return db.debuffs.unlocked end,
        -- Stores whether the debuff frame is unlocked.
        function(value) db.debuffs.unlocked = value end
    )

    panel.controls = {
        buffEnabled, buffColumns, buffRows, buffSize, buffSpacing,
        buffFontSize, buffUnlock,
        debuffEnabled, debuffColumns, debuffRows, debuffSize,
        debuffSpacing, debuffFontSize, debuffUnlock,
    }
    -- Refreshes every control whenever the Blizzard settings panel is shown.
    panel:SetScript("OnShow", function(self)
        for _, control in ipairs(self.controls) do
            control:Refresh()
        end
    end)

    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, addonName)
        Settings.RegisterAddOnCategory(category)
        optionsCategoryID = category.ID
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end

-- Opens the addon's category in the current or legacy Blizzard options UI.
local function OpenOptions()
    if Settings and Settings.OpenToCategory and optionsCategoryID then
        Settings.OpenToCategory(optionsCategoryID)
    elseif InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory(addonName)
        InterfaceOptionsFrame_OpenToCategory(addonName)
    end
end

-- Initializes the addon and routes all registered game events.
frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...
        if loadedAddon ~= addonName then return end

        EnemyClassicBuffsDB = EnemyClassicBuffsDB or {}

        -- Version 1 anchored the frames on their right edge and therefore
        -- expanded them in the wrong direction. Reset only the two positions
        -- once; all size/row/column settings remain untouched.
        if (EnemyClassicBuffsDB.databaseVersion or 0) < 2 then
            EnemyClassicBuffsDB.buffs = EnemyClassicBuffsDB.buffs or {}
            EnemyClassicBuffsDB.debuffs = EnemyClassicBuffsDB.debuffs or {}

            EnemyClassicBuffsDB.buffs.point = defaults.buffs.point
            EnemyClassicBuffsDB.buffs.relativePoint = defaults.buffs.relativePoint
            EnemyClassicBuffsDB.buffs.x = defaults.buffs.x
            EnemyClassicBuffsDB.buffs.y = defaults.buffs.y

            EnemyClassicBuffsDB.debuffs.point = defaults.debuffs.point
            EnemyClassicBuffsDB.debuffs.relativePoint = defaults.debuffs.relativePoint
            EnemyClassicBuffsDB.debuffs.x = defaults.debuffs.x
            EnemyClassicBuffsDB.debuffs.y = defaults.debuffs.y
            EnemyClassicBuffsDB.databaseVersion = 2
        end

        ApplyDefaults(EnemyClassicBuffsDB, defaults)
        db = EnemyClassicBuffsDB

        LCD = LibStub("EnemyClassicBuffs-LibClassicDurations", true)
        if LCD then
            LCD:RegisterFrame(ECB)
            -- Refreshes the displays when the tracker reconstructs a buff.
            LCD.RegisterCallback(ECB, "UNIT_BUFF", function()
                QueueRefresh()
            end)
        end

        ECB.buffFrame = CreateAuraFrame("buffs", "BUFF", "Target Buffs")
        ECB.debuffFrame = CreateAuraFrame("debuffs", "DEBUFF", "Target Debuffs")

        CreateOptionsPanel()

        SLASH_ENEMYCLASSICBUFFS1 = "/ecb"
        -- Opens options or toggles either frame's positioning preview.
        SlashCmdList.ENEMYCLASSICBUFFS = function(message)
            message = strtrim(message or ""):lower()
            if message == "buffs" then
                db.buffs.unlocked = not db.buffs.unlocked
                RefreshAll()
            elseif message == "debuffs" then
                db.debuffs.unlocked = not db.debuffs.unlocked
                RefreshAll()
            else
                OpenOptions()
            end
        end

        if not db.welcomeShown then
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cff66ccffEnemyClassicBuffs|r loaded."
            )
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cffffffff/ecb|r - Open the addon settings."
            )
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cffffffff/ecb buffs|r - Toggle the buff-frame positioning preview."
            )
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cffffffff/ecb debuffs|r - Toggle the debuff-frame positioning preview."
            )
            db.welcomeShown = true
        end

        self:RegisterEvent("PLAYER_TARGET_CHANGED")
        self:RegisterEvent("UNIT_AURA")
        self:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
        self:RegisterEvent("PLAYER_ENTERING_WORLD")

        RefreshAll()
    elseif event == "UNIT_AURA" then
        local unit = ...
        if unit == "target" then
            QueueRefresh()
        end
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        local _, _, _, _, _, _, _, destinationGUID =
            CombatLogGetCurrentEventInfo()
        if destinationGUID and destinationGUID == UnitGUID("target") then
            QueueRefresh()
        end
    else
        QueueRefresh()
    end
end)

frame.elapsed = 0
-- Periodically removes expired auras and updates countdown states.
frame:SetScript("OnUpdate", function(self, elapsed)
    if not db or not UnitExists("target") then return end
    self.elapsed = self.elapsed + elapsed
    if self.elapsed >= 0.25 then
        self.elapsed = 0
        RefreshAll()
    end
end)

frame:RegisterEvent("ADDON_LOADED")
