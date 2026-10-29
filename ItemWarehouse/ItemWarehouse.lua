-- ============================================================================
-- ItemWarehouse (IW) by Copper
-- Target: World of Warcraft 3.3.5 (Legacy 32-bit Client)
-- UI Architecture copied from RaidUtilityTracker.lua
-- ============================================================================

local ADDON_NAME = "ItemWarehouse"
local ITEMS_PER_PAGE = 1000

-- Global Database Reference
ItemWarehouseDB = ItemWarehouseDB or {}

-- Internal State
local currentSourceKey = nil
local currentPage = 1
local totalPages = 1
local currentDataList = {}

-- UI Panels
local mainFrame = nil
local optionsPanel = nil
local debugFrame = nil
local exportModal = nil
local guildBankScanBtn = nil

-- Dynamic Row Elements
local sourceRows = {}
local itemButtons = {}

-- Timers & Guild Bank Staging
local bagScanTimerFrame = CreateFrame("Frame")
local isBagScanPending = false
local guildTabStaging = {} -- Per-tab cache: guildTabStaging[tabNum] = { [link] = count }

-- Helper to Get Version from TOC
local function GetAddonVersion()
    return GetAddOnMetadata(ADDON_NAME, "Version") or "1.1"
end

-- ============================================================================
-- DEBUG LOGGING ENGINE
-- ============================================================================

local function DebugLog(msg)
    if not ItemWarehouseDB then return end
    -- Suppress logging if addon or debug mode is disabled
    if ItemWarehouseDB.enabled == false or not ItemWarehouseDB.debugMode then return end

    ItemWarehouseDB.debugLog = ItemWarehouseDB.debugLog or {}
    local t = date("%Y-%m-%d %H:%M:%S")
    table.insert(ItemWarehouseDB.debugLog, string.format("[%s] %s", t, tostring(msg)))
    
    if #ItemWarehouseDB.debugLog > 5000 then
        table.remove(ItemWarehouseDB.debugLog, 1)
    end
    
    if ItemWarehouse.UpdateDebugSizeDisplay then
        ItemWarehouse:UpdateDebugSizeDisplay()
    end
end

local function GetDebugSizeBytes()
    if not ItemWarehouseDB or not ItemWarehouseDB.debugLog then
        return 0
    end
    local bytes = 0
    for _, line in ipairs(ItemWarehouseDB.debugLog) do
        bytes = bytes + string.len(line) + 1
    end
    return bytes
end

local function GetDebugSizeString()
    local bytes = GetDebugSizeBytes()
    if bytes >= 1048576 then
        return string.format("%.2f MB", bytes / 1048576)
    else
        return string.format("%.2f KB", bytes / 1024)
    end
end

local function ClearDebugLog()
    if ItemWarehouseDB then
        ItemWarehouseDB.debugLog = {}
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[ItemWarehouse]|r Debug log cleared.")
        if ItemWarehouse.UpdateDebugSizeDisplay then ItemWarehouse:UpdateDebugSizeDisplay() end
        if ItemWarehouse.debugEditBox then ItemWarehouse.debugEditBox:SetText("") end
    end
end

-- ============================================================================
-- DATA SCANNING ENGINE (FRESH SCAN MODE)
-- ============================================================================

local function GetTimestamp()
    return date("%Y-%m-%d %H:%M")
end

local function GetCharacterName()
    return UnitName("player") or "Unknown"
end

local function GetGuildName()
    return GetGuildInfo("player")
end

local function PrecacheItemLink(link)
    if link then GetItemInfo(link) end
end

-- Fresh Scan Update: Wipes previous snapshot for source and replaces with active items
local function PerformFreshScanUpdate(sourceKey, scannedItems, scanLocations)
    ItemWarehouseDB[sourceKey] = { timestamp = GetTimestamp(), items = {} }
    local sourceData = ItemWarehouseDB[sourceKey]

    local totalItems = 0
    local uniqueTypes = 0

    for link, count in pairs(scannedItems) do
        sourceData.items[link] = count
        totalItems = totalItems + count
        uniqueTypes = uniqueTypes + 1

        if scanLocations[link] then
            DebugLog(string.format("Fresh Scan [%s]: %s x%d at (%s)", sourceKey, link, count, scanLocations[link]))
        end
    end

    return totalItems, uniqueTypes
end

-- Scan Player Inventory (AUTOMATIC FRESH SCAN)
local function PerformInventoryScan()
    isBagScanPending = false
    if not ItemWarehouseDB or ItemWarehouseDB.enabled == false then return end

    local charName = GetCharacterName()
    local sourceKey = charName .. " - Inventory"
    
    local scannedItems = {}
    local scanLocations = {}

    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local _, count = GetContainerItemInfo(bag, slot)
                count = count or 1
                scannedItems[link] = (scannedItems[link] or 0) + count
                scanLocations[link] = format("Bag %d, Slot %d", bag, slot)
                PrecacheItemLink(link)
            end
        end
    end

    local totalItems, uniqueTypes = PerformFreshScanUpdate(sourceKey, scannedItems, scanLocations)
    DebugLog(format("Inventory fresh scan updated (%d items, %d unique types).", totalItems, uniqueTypes))
end

local function RequestInventoryScan()
    if not ItemWarehouseDB or ItemWarehouseDB.enabled == false then return end
    if not isBagScanPending then
        isBagScanPending = true
        bagScanTimerFrame:SetScript("OnUpdate", function(self, elapsed)
            self:SetScript("OnUpdate", nil)
            PerformInventoryScan()
        end)
    end
end

-- Scan Personal Bank (AUTOMATIC FRESH SCAN)
local function ScanBank()
    if not ItemWarehouseDB or ItemWarehouseDB.enabled == false then return end

    local charName = GetCharacterName()
    local sourceKey = charName .. " - Bank"
    
    local scannedItems = {}
    local scanLocations = {}

    local numSlots = GetContainerNumSlots(-1)
    for slot = 1, numSlots do
        local link = GetContainerItemLink(-1, slot)
        if link then
            local _, count = GetContainerItemInfo(-1, slot)
            count = count or 1
            scannedItems[link] = (scannedItems[link] or 0) + count
            scanLocations[link] = format("Bank Slot %d", slot)
            PrecacheItemLink(link)
        end
    end

    for bag = 5, 11 do
        local bagSlots = GetContainerNumSlots(bag)
        for slot = 1, bagSlots do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local _, count = GetContainerItemInfo(bag, slot)
                count = count or 1
                scannedItems[link] = (scannedItems[link] or 0) + count
                scanLocations[link] = format("Bank Bag %d, Slot %d", bag, slot)
                PrecacheItemLink(link)
            end
        end
    end

    local totalItems, uniqueTypes = PerformFreshScanUpdate(sourceKey, scannedItems, scanLocations)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff00ff00ItemWarehouse:|r Personal bank fresh scan complete (%d total items | %d item types).", totalItems, uniqueTypes))
end

-- Manual Fresh Scan For Active Guild Bank Tab
local function ScanActiveGuildBankTab()
    if not ItemWarehouseDB or ItemWarehouseDB.enabled == false then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000ItemWarehouse:|r Addon is disabled in config.")
        return
    end

    local gName = GetGuildName()
    if not gName then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000ItemWarehouse:|r Guild name not detected.")
        return
    end

    local currentTab = GetCurrentGuildBankTab()
    if not currentTab or currentTab == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000ItemWarehouse:|r No active Guild Bank tab selected.")
        return
    end

    local tabName = GetGuildBankTabInfo(currentTab) or ("Tab " .. currentTab)
    
    guildTabStaging[currentTab] = {}
    local tabItemCount = 0
    local uniqueTypes = 0

    for slot = 1, 98 do
        local link = GetGuildBankItemLink(currentTab, slot)
        if link then
            local _, count = GetGuildBankItemInfo(currentTab, slot)
            count = count or 1
            if not guildTabStaging[currentTab][link] then
                uniqueTypes = uniqueTypes + 1
            end
            guildTabStaging[currentTab][link] = (guildTabStaging[currentTab][link] or 0) + count
            tabItemCount = tabItemCount + count
            PrecacheItemLink(link)
        end
    end

    DebugLog(format("Fresh Tab Scan: Guild Tab [%s] recorded %d items across %d unique types.", tabName, tabItemCount, uniqueTypes))

    local sourceKey = "[Guild Bank] " .. gName
    local aggregateItems = {}
    local scanLocations = {}

    for tabIdx, tabData in pairs(guildTabStaging) do
        local tName = GetGuildBankTabInfo(tabIdx) or ("Tab " .. tabIdx)
        for link, count in pairs(tabData) do
            aggregateItems[link] = (aggregateItems[link] or 0) + count
            scanLocations[link] = format("Guild Tab [%s]", tName)
        end
    end

    local totalItems, totalUnique = PerformFreshScanUpdate(sourceKey, aggregateItems, scanLocations)

    DEFAULT_CHAT_FRAME:AddMessage(format("|cff00ff00ItemWarehouse:|r Fresh scan complete for Guild Bank [%s] (%d items in tab | %d total stored across scanned tabs).", tabName, tabItemCount, totalItems))
end

-- Attach Manual Scan Button to GuildBankFrame
local function AttachGuildBankButton()
    if guildBankScanBtn or not GuildBankFrame then return end

    guildBankScanBtn = CreateFrame("Button", "ItemWarehouseGuildBankScanBtn", GuildBankFrame, "UIPanelButtonTemplate")
    guildBankScanBtn:SetSize(110, 22)
    guildBankScanBtn:SetPoint("TOPRIGHT", GuildBankFrame, "TOPRIGHT", -48, -36)
    guildBankScanBtn:SetText("Scan Tab")

    guildBankScanBtn:SetScript("OnClick", function()
        ScanActiveGuildBankTab()
    end)

    guildBankScanBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("ItemWarehouse Fresh Scan", 0, 1, 0)
        GameTooltip:AddLine("Click to perform a fresh scan of all items", 1, 1, 1)
        GameTooltip:AddLine("and stack sizes currently in this tab.", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)

    guildBankScanBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
end

local function GetCleanItemName(hyperlink)
    local name = hyperlink:match("%[(.-)%]")
    if not name or name == "" then
        local fetchedName = GetItemInfo(hyperlink)
        return fetchedName or hyperlink
    end
    return name
end

local function TrimString(str)
    return str:match("^%s*(.-)%s*$")
end

local function InsertLinkToChat(link)
    local editBox = LAST_ACTIVE_CHAT_EDIT_BOX
    if not editBox or not editBox:IsShown() then
        ChatFrame_OpenChat("")
        editBox = LAST_ACTIVE_CHAT_EDIT_BOX
    end
    if editBox and editBox:IsShown() then
        editBox:Insert(link)
    end
end

-- ============================================================================
-- EXPORT MODAL PANEL
-- ============================================================================

local function CreateExportModal()
    if exportModal then return end

    exportModal = CreateFrame("Frame", "ItemWarehouseExportModal", UIParent)
    exportModal:SetSize(560, 450)
    exportModal:SetPoint("CENTER", 0, 0)
    exportModal:SetFrameStrata("DIALOG")
    exportModal:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    exportModal:SetMovable(true)
    exportModal:EnableMouse(true)
    exportModal:RegisterForDrag("LeftButton")
    exportModal:SetScript("OnDragStart", exportModal.StartMoving)
    exportModal:SetScript("OnDragStop", exportModal.StopMovingOrSizing)
    exportModal:Hide()

    tinsert(UISpecialFrames, "ItemWarehouseExportModal")

    local titleBg = exportModal:CreateTexture(nil, "HIGH")
    titleBg:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
    titleBg:SetWidth(320)
    titleBg:SetHeight(64)
    titleBg:SetPoint("TOP", 0, 12)

    local titleText = exportModal:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleText:SetPoint("TOP", titleBg, "TOP", 0, -14)
    titleText:SetText("ItemWarehouse Export")

    local closeBtn = CreateFrame("Button", nil, exportModal, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -5, -5)

    -- Discord Markdown Checkbox
    local discordCheck = CreateFrame("CheckButton", "ItemWarehouseDiscordCheck", exportModal, "UICheckButtonTemplate")
    discordCheck:SetPoint("TOPLEFT", 20, -32)
    _G[discordCheck:GetName() .. "Text"]:SetText("Discord Markdown")
    discordCheck:SetChecked(false)

    -- Spreadsheet Format Checkbox
    local sheetCheck = CreateFrame("CheckButton", "ItemWarehouseSheetCheck", exportModal, "UICheckButtonTemplate")
    sheetCheck:SetPoint("LEFT", discordCheck, "RIGHT", 110, 0)
    _G[sheetCheck:GetName() .. "Text"]:SetText("Spreadsheet Format")
    sheetCheck:SetChecked(false)

    -- Back to Current Inventory Button
    local backToInvBtn = CreateFrame("Button", nil, exportModal, "UIPanelButtonTemplate")
    backToInvBtn:SetSize(160, 22)
    backToInvBtn:SetPoint("TOPRIGHT", -25, -34)
    backToInvBtn:SetText("Back to Current Inventory")

    local exportBorder = CreateFrame("Frame", nil, exportModal)
    exportBorder:SetPoint("TOPLEFT", 18, -62)
    exportBorder:SetPoint("BOTTOMRIGHT", -18, 45)
    exportBorder:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    exportBorder:SetBackdropColor(0, 0, 0, 0.85)

    local scrollFrame = CreateFrame("ScrollFrame", "ItemWarehouseExportScroll", exportBorder, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 8, -8)
    scrollFrame:SetPoint("BOTTOMRIGHT", -26, 8)

    local editBox = CreateFrame("EditBox", "ItemWarehouseExportEditBox", scrollFrame)
    editBox:SetMultiLine(true)
    editBox:SetMaxLetters(0)
    editBox:EnableMouse(true)
    editBox:SetAutoFocus(true)
    editBox:SetFontObject(ChatFontNormal)
    editBox:SetWidth(480)
    scrollFrame:SetScrollChild(editBox)

    exportModal.editBox = editBox
    exportModal.discordCheck = discordCheck
    exportModal.sheetCheck = sheetCheck

    editBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        exportModal:Hide()
    end)

    backToInvBtn:SetScript("OnClick", function()
        exportModal:Hide()
        if mainFrame then
            mainFrame:Show()
            if currentSourceKey then
                mainFrame.ShowItemPanel(currentSourceKey)
            else
                mainFrame.ShowSourcePanel()
            end
        end
    end)

    local function GenerateExportText()
        if not currentSourceKey or currentSourceKey == "CONFIG" then return end

        local lines = {}
        local useDiscord = discordCheck:GetChecked()
        local useSheet = sheetCheck:GetChecked()
        local itemsTable = ItemWarehouseDB[currentSourceKey] and ItemWarehouseDB[currentSourceKey].items or {}

        local sortedLinks = {}
        for link in pairs(itemsTable) do table.insert(sortedLinks, link) end
        table.sort(sortedLinks, function(a, b)
            return GetCleanItemName(a) < GetCleanItemName(b)
        end)

        if useSheet then
            for _, link in ipairs(sortedLinks) do
                local cleanName = GetCleanItemName(link)
                local count = itemsTable[link]
                table.insert(lines, format("%s\t%d", cleanName, count))
            end
        elseif useDiscord then
            table.insert(lines, format("**%s**", currentSourceKey))
            for _, link in ipairs(sortedLinks) do
                local cleanName = GetCleanItemName(link)
                local count = itemsTable[link]
                table.insert(lines, format("* %s x%d", cleanName, count))
            end
        else
            table.insert(lines, format("Source: %s", currentSourceKey))
            table.insert(lines, "--------------------------------------------------")
            for _, link in ipairs(sortedLinks) do
                local cleanName = GetCleanItemName(link)
                local count = itemsTable[link]
                table.insert(lines, format("%s x%d", cleanName, count))
            end
        end

        local textData = table.concat(lines, "\n")
        editBox:SetText(textData)
        editBox:HighlightText()
    end

    discordCheck:SetScript("OnClick", function(self)
        if self:GetChecked() then
            sheetCheck:SetChecked(false)
        end
        GenerateExportText()
    end)

    sheetCheck:SetScript("OnClick", function(self)
        if self:GetChecked() then
            discordCheck:SetChecked(false)
        end
        GenerateExportText()
    end)

    exportModal.OpenForCurrentSource = function()
        if mainFrame and mainFrame:IsShown() then
            mainFrame:Hide()
        end
        exportModal:Show()
        GenerateExportText()
    end
end

-- ============================================================================
-- DEBUG LOG VIEWER FRAME
-- ============================================================================

local function CreateDebugFrame()
    if debugFrame then return end

    local f = CreateFrame("Frame", "ItemWarehouseDebugFrame", UIParent)
    f:SetWidth(640)
    f:SetHeight(440)
    f:SetPoint("CENTER", 0, 0)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()

    tinsert(UISpecialFrames, "ItemWarehouseDebugFrame")
    debugFrame = f

    local titleBg = f:CreateTexture(nil, "HIGH")
    titleBg:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
    titleBg:SetWidth(280)
    titleBg:SetHeight(64)
    titleBg:SetPoint("TOP", 0, 12)

    local titleText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleText:SetPoint("TOP", titleBg, "TOP", 0, -14)
    titleText:SetText("ItemWarehouse Debug Log")

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -5, -5)

    local scrollFrame = CreateFrame("ScrollFrame", "IWDebugScrollFrame", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetWidth(580)
    scrollFrame:SetHeight(340)
    scrollFrame:SetPoint("TOPLEFT", 20, -45)

    local editBox = CreateFrame("EditBox", nil, scrollFrame)
    editBox:SetWidth(580)
    editBox:SetHeight(340)
    editBox:SetMultiLine(true)
    editBox:SetFontObject(GameFontHighlightSmall)
    editBox:SetMaxLetters(0)
    editBox:SetAutoFocus(false)
    scrollFrame:SetScrollChild(editBox)
    ItemWarehouse.debugEditBox = editBox

    f:SetScript("OnShow", function()
        if mainFrame and mainFrame:IsShown() then mainFrame:Hide() end
        if optionsPanel and optionsPanel:IsShown() then optionsPanel:Hide() end

        if ItemWarehouseDB and ItemWarehouseDB.debugLog then
            editBox:SetText(table.concat(ItemWarehouseDB.debugLog, "\n"))
        else
            editBox:SetText("No debug data recorded.")
        end
    end)
end

-- ============================================================================
-- OPTIONS & CONFIG PANEL FRAME
-- ============================================================================

local function CreateOptionsPanel()
    if optionsPanel then return end

    local f = CreateFrame("Frame", "ItemWarehouseOptionsFrame", UIParent)
    f:SetWidth(380)
    f:SetHeight(360)
    f:SetPoint("CENTER", 0, 0)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()

    tinsert(UISpecialFrames, "ItemWarehouseOptionsFrame")
    optionsPanel = f

    local titleBg = f:CreateTexture(nil, "HIGH")
    titleBg:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
    titleBg:SetWidth(280)
    titleBg:SetHeight(64)
    titleBg:SetPoint("TOP", 0, 12)

    local titleText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleText:SetPoint("TOP", titleBg, "TOP", 0, -14)
    titleText:SetText("ItemWarehouse Config")

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -5, -5)

    -- 1. Enable Addon Checkbox (Positioned at Very Top)
    local enabledCheck = CreateFrame("CheckButton", "IW_ConfigEnabledCheck", f, "UICheckButtonTemplate")
    enabledCheck:SetPoint("TOPLEFT", 25, -45)
    _G[enabledCheck:GetName() .. "Text"]:SetText("Enable ItemWarehouse addon.")
    enabledCheck:SetScript("OnClick", function(self)
        local isChecked = self:GetChecked()
        ItemWarehouseDB.enabled = isChecked
        if isChecked then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[ItemWarehouse]|r Addon enabled.")
            DebugLog("Addon enabled.")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[ItemWarehouse]|r Addon disabled.")
        end
    end)

    -- Purge Stored Data Button
    local purgeBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    purgeBtn:SetPoint("TOP", 0, -85)
    purgeBtn:SetWidth(220)
    purgeBtn:SetHeight(24)
    purgeBtn:SetText("Purge All Stored Data")
    purgeBtn:SetScript("OnClick", function()
        ItemWarehouseDB = { minimapPos = ItemWarehouseDB.minimapPos, debugLog = {}, enabled = ItemWarehouseDB.enabled, debugMode = ItemWarehouseDB.debugMode }
        guildTabStaging = {}
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000ItemWarehouse: All stored scan data purged.|r")
        if mainFrame and mainFrame:IsShown() then mainFrame.ShowSourcePanel() end
    end)

    -- 2. Enable Debug Mode Checkbox
    local debugCheck = CreateFrame("CheckButton", "IW_ConfigDebugCheck", f, "UICheckButtonTemplate")
    debugCheck:SetPoint("TOPLEFT", 25, -125)
    _G[debugCheck:GetName() .. "Text"]:SetText("Enable Debug Mode")
    debugCheck:SetScript("OnClick", function(self)
        local isChecked = self:GetChecked()
        ItemWarehouseDB.debugMode = isChecked
        if isChecked then
            DebugLog("Debug mode enabled.")
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[ItemWarehouse]|r Debug mode enabled.")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[ItemWarehouse]|r Debug mode disabled.")
        end
        ItemWarehouse:UpdateDebugSizeDisplay()
    end)

    -- Debug Size Label
    local debugSizeText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    debugSizeText:SetPoint("TOPLEFT", 25, -160)
    debugSizeText:SetText("Debug Log Data: 0.00 KB")

    -- 3. Memory Warning Notice
    local debugWarnText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    debugWarnText:SetPoint("TOPLEFT", 25, -180)
    debugWarnText:SetWidth(330)
    debugWarnText:SetJustifyH("LEFT")
    debugWarnText:SetText("")

    function ItemWarehouse:UpdateDebugSizeDisplay()
        if debugSizeText then
            local sizeStr = GetDebugSizeString()
            debugSizeText:SetText("Debug Log Data: " .. sizeStr)

            local bytes = GetDebugSizeBytes()
            if bytes >= 1048576 then -- Over 1MB
                debugWarnText:SetText("|cffff0000Warning: Debug log size exceeds 1.00 MB! Please clear or purge debug data to maintain client performance.|r")
            else
                debugWarnText:SetText("|cff888888Notice: Clear debug data periodically if usage gets too high.|r")
            end
        end
    end

    -- View Debug Log Button
    local viewDebugBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    viewDebugBtn:SetPoint("TOPLEFT", 25, -235)
    viewDebugBtn:SetWidth(150)
    viewDebugBtn:SetHeight(24)
    viewDebugBtn:SetText("View Debug Log")
    viewDebugBtn:SetScript("OnClick", function()
        CreateDebugFrame()
        if debugFrame:IsShown() then debugFrame:Hide() else debugFrame:Show() end
    end)

    -- Clear Debug Log Button
    local clearDebugBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    clearDebugBtn:SetPoint("TOPRIGHT", -25, -235)
    clearDebugBtn:SetWidth(150)
    clearDebugBtn:SetHeight(24)
    clearDebugBtn:SetText("Clear Debug Log")
    clearDebugBtn:SetScript("OnClick", function() ClearDebugLog() end)

    -- 4. Version Footer Notice on Config Panel
    local configVersionText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    configVersionText:SetPoint("BOTTOMRIGHT", -20, 15)
    configVersionText:SetText(format("|cff808080ItemWarehouse v%s|r", GetAddonVersion()))

    f:SetScript("OnShow", function()
        if mainFrame and mainFrame:IsShown() then mainFrame:Hide() end
        if debugFrame and debugFrame:IsShown() then debugFrame:Hide() end

        if enabledCheck then
            enabledCheck:SetChecked(ItemWarehouseDB and ItemWarehouseDB.enabled ~= false)
        end
        if debugCheck then
            debugCheck:SetChecked(ItemWarehouseDB and ItemWarehouseDB.debugMode or false)
        end

        ItemWarehouse:UpdateDebugSizeDisplay()
    end)
end

-- ============================================================================
-- MAIN DASHBOARD FRAME
-- ============================================================================

local function CreateMainUI()
    if mainFrame then return end

    mainFrame = CreateFrame("Frame", "ItemWarehouseMainFrame", UIParent)
    mainFrame:SetSize(720, 520)
    mainFrame:SetPoint("CENTER", 0, 0)
    mainFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    mainFrame:SetMovable(true)
    mainFrame:EnableMouse(true)
    mainFrame:RegisterForDrag("LeftButton")
    mainFrame:SetScript("OnDragStart", mainFrame.StartMoving)
    mainFrame:SetScript("OnDragStop", mainFrame.StopMovingOrSizing)
    mainFrame:Hide()

    tinsert(UISpecialFrames, "ItemWarehouseMainFrame")

    local titleBg = mainFrame:CreateTexture(nil, "HIGH")
    titleBg:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
    titleBg:SetWidth(424)
    titleBg:SetHeight(64)
    titleBg:SetPoint("TOP", 0, 12)

    local titleText = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleText:SetPoint("TOP", titleBg, "TOP", 0, -14)
    titleText:SetText("ItemWarehouse addon by Copper")

    local closeBtn = CreateFrame("Button", nil, mainFrame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -5, -5)

    local prevBtn = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    prevBtn:SetSize(30, 22)
    prevBtn:SetPoint("TOPLEFT", 20, -36)
    prevBtn:SetText("<")

    local nextBtn = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    nextBtn:SetSize(30, 22)
    nextBtn:SetPoint("TOPRIGHT", -20, -36)
    nextBtn:SetText(">")

    local pageText = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pageText:SetPoint("CENTER", mainFrame, "TOP", 0, -47)
    pageText:SetText("Page 1 of 1")

    mainFrame.prevBtn = prevBtn
    mainFrame.nextBtn = nextBtn
    mainFrame.pageText = pageText

    local backBtn = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    backBtn:SetSize(130, 22)
    backBtn:SetPoint("LEFT", prevBtn, "RIGHT", 10, 0)
    backBtn:SetText("< Back to Sources")
    backBtn:Hide()
    mainFrame.backBtn = backBtn

    local exportViewBtn = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    exportViewBtn:SetSize(120, 22)
    exportViewBtn:SetPoint("RIGHT", nextBtn, "LEFT", -10, 0)
    exportViewBtn:SetText("Export View")
    exportViewBtn:Hide()
    mainFrame.exportViewBtn = exportViewBtn

    local sourceSubHeader = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    sourceSubHeader:SetPoint("TOPLEFT", 22, -66)
    sourceSubHeader:SetText("")
    mainFrame.sourceSubHeader = sourceSubHeader

    local configBtn = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    configBtn:SetSize(120, 22)
    configBtn:SetPoint("BOTTOMLEFT", 20, 16)
    configBtn:SetText("Config Panel")
    mainFrame.configBtn = configBtn

    -- 4. Version Footer Notice on Main Dashboard Panel
    local mainVersionText = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    mainVersionText:SetPoint("BOTTOMRIGHT", -20, 15)
    mainVersionText:SetText(format("|cff808080ItemWarehouse v%s|r", GetAddonVersion()))

    local contentBox = CreateFrame("Frame", nil, mainFrame)
    contentBox:SetWidth(680)
    contentBox:SetHeight(380)
    contentBox:SetPoint("TOPLEFT", 20, -88)
    contentBox:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    contentBox:SetBackdropColor(0, 0, 0, 0.6)

    local scrollFrame = CreateFrame("ScrollFrame", "IWMainScrollFrame", contentBox, "UIPanelScrollFrameTemplate")
    scrollFrame:SetWidth(640)
    scrollFrame:SetHeight(360)
    scrollFrame:SetPoint("TOPLEFT", 10, -10)

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(640, 20000)
    scrollFrame:SetScrollChild(scrollChild)

    for i = 1, ITEMS_PER_PAGE do
        local rowFrame = CreateFrame("Frame", nil, scrollChild)
        rowFrame:SetSize(630, 20)
        rowFrame:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 2, -((i - 1) * 21))
        rowFrame:Hide()

        local sBtn = CreateFrame("Button", nil, rowFrame, "UIPanelButtonTemplate")
        sBtn:SetSize(380, 20)
        sBtn:SetPoint("LEFT", rowFrame, "LEFT", 0, 0)
        sBtn:SetNormalFontObject(GameFontHighlightSmall)
        sBtn:SetHighlightFontObject(GameFontNormalSmall)
        rowFrame.btn = sBtn

        local tsText = rowFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        tsText:SetPoint("LEFT", sBtn, "RIGHT", 15, 0)
        tsText:SetJustifyH("LEFT")
        rowFrame.tsText = tsText

        sourceRows[i] = rowFrame

        local iBtn = CreateFrame("Button", nil, scrollChild)
        iBtn:SetSize(630, 20)
        iBtn:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 2, -((i - 1) * 21))
        
        local btnText = iBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        btnText:SetAllPoints(iBtn)
        btnText:SetJustifyH("LEFT")
        iBtn.text = btnText

        local highlight = iBtn:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        highlight:SetAllPoints(iBtn)

        iBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        iBtn:Hide()
        itemButtons[i] = iBtn
    end

    exportViewBtn:SetScript("OnClick", function()
        CreateExportModal()
        exportModal.OpenForCurrentSource()
    end)

    local function UpdatePaginationControls()
        totalPages = math.ceil(#currentDataList / ITEMS_PER_PAGE)
        if totalPages < 1 then totalPages = 1 end
        if currentPage > totalPages then currentPage = totalPages end
        if currentPage < 1 then currentPage = 1 end

        pageText:SetText(format("Page %d of %d", currentPage, totalPages))

        if currentPage <= 1 then prevBtn:Disable() else prevBtn:Enable() end
        if currentPage >= totalPages then nextBtn:Disable() else nextBtn:Enable() end
    end

    local function ClearContentRows()
        for i = 1, ITEMS_PER_PAGE do
            sourceRows[i]:Hide()
            itemButtons[i]:Hide()
        end
    end

    local function RenderSourcePage()
        ClearContentRows()
        prevBtn:Hide()
        nextBtn:Hide()
        pageText:Hide()

        local rowIndex = 1
        for _, itemData in ipairs(currentDataList) do
            local row = sourceRows[rowIndex]
            row.btn:SetText(itemData.key)
            row.tsText:SetText(format("|cff888888Scanned: %s|r", itemData.ts))
            
            row.btn:SetScript("OnClick", function()
                mainFrame.ShowItemPanel(itemData.key)
            end)

            row:Show()
            rowIndex = rowIndex + 1
            if rowIndex > ITEMS_PER_PAGE then break end
        end

        scrollChild:SetHeight(math.max(rowIndex * 21, 360))
    end

    local function RenderItemPage()
        ClearContentRows()
        prevBtn:Show()
        nextBtn:Show()
        pageText:Show()
        UpdatePaginationControls()

        local startIndex = ((currentPage - 1) * ITEMS_PER_PAGE) + 1
        local endIndex = math.min(currentPage * ITEMS_PER_PAGE, #currentDataList)
        local rowIndex = 1

        for i = startIndex, endIndex do
            local itemData = currentDataList[i]
            local btn = itemButtons[rowIndex]
            btn.text:SetText(format("%s  x%d", itemData.link, itemData.count))

            btn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink(itemData.link)
                GameTooltip:Show()
            end)
            btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

            btn:SetScript("OnClick", function(self, button)
                if button == "RightButton" or IsShiftKeyDown() then
                    InsertLinkToChat(itemData.link)
                end
            end)

            btn:Show()
            rowIndex = rowIndex + 1
        end

        scrollChild:SetHeight(math.max(rowIndex * 21, 360))
    end

    prevBtn:SetScript("OnClick", function()
        if currentPage > 1 then
            currentPage = currentPage - 1
            RenderItemPage()
        end
    end)

    nextBtn:SetScript("OnClick", function()
        if currentPage < totalPages then
            currentPage = currentPage + 1
            RenderItemPage()
        end
    end)

    local function ShowSourcePanel()
        currentSourceKey = nil
        backBtn:Hide()
        exportViewBtn:Hide()
        configBtn:Show()
        sourceSubHeader:SetText("Select a scanned inventory source:")
        currentPage = 1
        currentDataList = {}

        local sources = {}
        for key in pairs(ItemWarehouseDB) do
            if key ~= "minimapPos" and key ~= "debugLog" and key ~= "enabled" and key ~= "debugMode" then 
                table.insert(sources, key) 
            end
        end
        table.sort(sources)

        for _, key in ipairs(sources) do
            local ts = ItemWarehouseDB[key].timestamp or "Unknown"
            table.insert(currentDataList, { key = key, ts = ts })
        end

        RenderSourcePage()
    end

    local function ShowItemPanel(sourceKey)
        currentSourceKey = sourceKey
        backBtn:Show()
        exportViewBtn:Show()
        configBtn:Hide()
        sourceSubHeader:SetText(format("Source: %s", sourceKey))
        currentPage = 1
        currentDataList = {}

        local itemsTable = ItemWarehouseDB[sourceKey] and ItemWarehouseDB[sourceKey].items
        if itemsTable then
            local sortedLinks = {}
            for link in pairs(itemsTable) do table.insert(sortedLinks, link) end
            table.sort(sortedLinks, function(a, b)
                return GetCleanItemName(a) < GetCleanItemName(b)
            end)

            for _, link in ipairs(sortedLinks) do
                table.insert(currentDataList, { link = link, count = itemsTable[link] })
            end
        end

        RenderItemPage()
    end

    backBtn:SetScript("OnClick", ShowSourcePanel)
    configBtn:SetScript("OnClick", function()
        CreateOptionsPanel()
        if optionsPanel:IsShown() then optionsPanel:Hide() else optionsPanel:Show() end
    end)

    mainFrame.ShowSourcePanel = ShowSourcePanel
    mainFrame.ShowItemPanel = ShowItemPanel
    mainFrame.RenderItemPage = RenderItemPage
end

-- ============================================================================
-- MINIMAP BUTTON (FISH FEAST ICON)
-- ============================================================================

local function CreateMinimapButton()
    ItemWarehouseDB.minimapPos = ItemWarehouseDB.minimapPos or 45

    local miniBtn = CreateFrame("Button", "ItemWarehouseMinimapButton", Minimap)
    miniBtn:SetSize(31, 31)
    miniBtn:SetFrameStrata("MEDIUM")
    miniBtn:SetToplevel(true)

    local icon = miniBtn:CreateTexture(nil, "BACKGROUND")
    icon:SetTexture("Interface\\Icons\\INV_Misc_Fish_52")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER")

    local overlay = miniBtn:CreateTexture(nil, "OVERLAY")
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetSize(53, 53)
    overlay:SetPoint("TOPLEFT")

    local function UpdatePosition()
        local angle = math.rad(ItemWarehouseDB.minimapPos)
        local x = math.cos(angle) * 80
        local y = math.sin(angle) * 80
        miniBtn:SetPoint("CENTER", Minimap, "CENTER", x, y)
    end

    miniBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    miniBtn:RegisterForDrag("LeftButton")
    
    miniBtn:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local xpos, ypos = GetCursorPosition()
            local xmin, ymin = Minimap:GetLeft(), Minimap:GetBottom()
            local scale = Minimap:GetEffectiveScale()
            xpos = (xpos / scale) - xmin - 70
            ypos = (ypos / scale) - ymin - 70
            ItemWarehouseDB.minimapPos = math.deg(math.atan2(ypos, xpos))
            UpdatePosition()
        end)
    end)

    miniBtn:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    miniBtn:SetScript("OnClick", function(self, button)
        CreateMainUI()
        if button == "RightButton" then
            CreateOptionsPanel()
            if optionsPanel:IsShown() then optionsPanel:Hide() else optionsPanel:Show() end
        else
            if mainFrame:IsShown() then mainFrame:Hide() else mainFrame:Show() mainFrame.ShowSourcePanel() end
        end
    end)

    miniBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("ItemWarehouse addon by Copper", 0, 1, 0)
        GameTooltip:AddLine("Left-Click: Open ItemWarehouse", 1, 1, 1)
        GameTooltip:AddLine("Right-Click: Open Config Panel", 0.8, 0.8, 1)
        GameTooltip:Show()
    end)

    miniBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    UpdatePosition()
end

-- ============================================================================
-- EVENT REGISTRATION & SLASH COMMANDS
-- ============================================================================

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("BAG_UPDATE")
eventFrame:RegisterEvent("BANKFRAME_OPENED")
eventFrame:RegisterEvent("GUILDBANKFRAME_OPENED")
eventFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        if ItemWarehouseDB.enabled == nil then
            ItemWarehouseDB.enabled = true
        end
        if ItemWarehouseDB.debugMode == nil then
            ItemWarehouseDB.debugMode = false
        end

        CreateMinimapButton()
        DEFAULT_CHAT_FRAME:AddMessage(format("|cff00ff00ItemWarehouse v%s by Copper loaded. Left-click minimap or type /iw to open.|r", GetAddonVersion()))
    elseif event == "BAG_UPDATE" then
        RequestInventoryScan()
    elseif event == "BANKFRAME_OPENED" then
        ScanBank()
    elseif event == "GUILDBANKFRAME_OPENED" then
        AttachGuildBankButton()
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        if mainFrame and mainFrame:IsShown() and currentSourceKey then
            mainFrame.RenderItemPage()
        end
    end
end)

-- Slash Command Handler
SLASH_ITEMWAREHOUSE1 = "/iw"
SLASH_ITEMWAREHOUSE2 = "/itemwarehouse"

SlashCmdList["ITEMWAREHOUSE"] = function(msg)
    local cmd = TrimString(msg:lower())
    
    CreateMainUI()

    if cmd == "config" or cmd == "options" or cmd == "opt" then
        CreateOptionsPanel()
        if optionsPanel:IsShown() then optionsPanel:Hide() else optionsPanel:Show() end
    elseif cmd == "debug" then
        CreateDebugFrame()
        if debugFrame:IsShown() then debugFrame:Hide() else debugFrame:Show() end
    elseif cmd == "purge" then
        ItemWarehouseDB = { minimapPos = ItemWarehouseDB.minimapPos, debugLog = {}, enabled = ItemWarehouseDB.enabled, debugMode = ItemWarehouseDB.debugMode }
        guildTabStaging = {}
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000ItemWarehouse: All stored scan data purged.|r")
        if mainFrame:IsShown() then mainFrame.ShowSourcePanel() end
    else
        if mainFrame:IsShown() then mainFrame:Hide() else mainFrame:Show() mainFrame.ShowSourcePanel() end
    end
end

-- Global API Table Export
_G["ItemWarehouse"] = {
    UpdateDebugSizeDisplay = function() end
}
