local _G = _G
local addonName = "SkomsArenaStats"
local addonTitle = select(2, _G.GetAddOnInfo(addonName))
local SkomsArenaStats = _G.LibStub("AceAddon-3.0"):GetAddon(addonName)
local L = _G.LibStub("AceLocale-3.0"):GetLocale(addonName, true)
local sbyte = _G.string.byte

local filters = {bracket = 0, arenaType = 0, name = ""}
local rows, filtered = {}, {}
local mainFrame, history

function SkomsArenaStats:CSize(char)
    if not char then
        return 0
    elseif char > 240 then
        return 4
    elseif char > 225 then
        return 3
    elseif char > 192 then
        return 2
    else
        return 1
    end
end

function SkomsArenaStats:StrSub(str, startChar, numChars)
    local startIndex = 1
    while startChar > 1 do
        local char = sbyte(str, startIndex)
        startIndex = startIndex + SkomsArenaStats:CSize(char)
        startChar = startChar - 1
    end
    local currentIndex = startIndex
    while numChars > 0 and currentIndex <= #str do
        local char = sbyte(str, currentIndex)
        currentIndex = currentIndex + SkomsArenaStats:CSize(char)
        numChars = numChars - 1
    end
    return str:sub(startIndex, currentIndex - 1)
end

function SkomsArenaStats:CreateShortMapName(mapName)
    local mapNameTemp = {strsplit(" ", mapName)}
    local mapShortName = ""
    for i = 1, #mapNameTemp do
        mapShortName = mapShortName .. SkomsArenaStats:StrSub(mapNameTemp[i], 0, 1)
    end
    return mapShortName
end

-- 3.3.5a's GetRealZoneText takes no map ID, so use fixed names instead
SkomsArenaStats.mapListShortName = {
    [559] = SkomsArenaStats:CreateShortMapName("Nagrand Arena"),
    [562] = SkomsArenaStats:CreateShortMapName("Blade's Edge Arena"),
    [572] = SkomsArenaStats:CreateShortMapName("Ruins of Lordaeron"),
    [617] = SkomsArenaStats:CreateShortMapName("Dalaran Arena"),
    [618] = SkomsArenaStats:CreateShortMapName("The Ring of Valor")
}

-- Class icons come from one atlas in 3.3.5a (no per-class file IDs)
local CLASS_ICON_TEXTURE = "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes"
local CLASS_ICON_COORDS = _G.CLASS_ICON_TCOORDS or {
    WARRIOR = {0, 0.25, 0, 0.25},
    MAGE = {0.25, 0.49609375, 0, 0.25},
    ROGUE = {0.49609375, 0.7421875, 0, 0.25},
    DRUID = {0.7421875, 0.98828125, 0, 0.25},
    HUNTER = {0, 0.25, 0.25, 0.5},
    SHAMAN = {0.25, 0.49609375, 0.25, 0.5},
    PRIEST = {0.49609375, 0.7421875, 0.25, 0.5},
    WARLOCK = {0.7421875, 0.98828125, 0.25, 0.5},
    PALADIN = {0, 0.25, 0.5, 0.75},
    DEATHKNIGHT = {0.25, 0.49609375, 0.5, 0.75}
}

-- Row regions are named (not parentKey'd) in the 3.3.5a template
local ROW_REGIONS = {
    "Date", "Map", "Duration", "IconTeamPlayerClass1", "IconTeamPlayerClass2",
    "IconTeamPlayerClass3", "IconTeamPlayerClass4", "IconTeamPlayerClass5",
    "Rating", "MMR", "IconEnemyPlayer1", "IconEnemyPlayer2", "IconEnemyPlayer3",
    "IconEnemyPlayer4", "IconEnemyPlayer5", "EnemyMMR", "EnemyFaction"
}

-- UI toolkit in the Blizzard / Ace look of the other Skom's addons, shared with
-- Weekly.lua. Sizes use SetWidth/SetHeight: SetSize isn't in every 3.3.5a client.

local UI = {}
SkomsArenaStats.UI = UI

UI.WIDTH, UI.HEIGHT = 920, 560
-- the area inside the tab border that the pages fill
UI.CONTENT_WIDTH, UI.CONTENT_HEIGHT = 872, 440
UI.ROW_HEIGHT = 20
-- Warmane runs Solo Queue in the slot the client still calls the 5v5 team
UI.BRACKET_LABELS = {[2] = "2v2", [3] = "3v3", [5] = "SoloQ"}
UI.colors = {
    accent = {1, 0.82, 0},
    text = {1, 1, 1},
    dim = {0.5, 0.5, 0.5},
    good = {0.1, 1, 0.1},
    bad = {1, 0.25, 0.25}
}

-- the backdrops of AceGUI's Frame and of its inline and tab groups
local DIALOG_BACKDROP = {
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true,
    tileSize = 32,
    edgeSize = 32,
    insets = {left = 8, right = 8, top = 8, bottom = 8}
}
local GROUP_BACKDROP = {
    bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true,
    tileSize = 16,
    edgeSize = 16,
    insets = {left = 3, right = 3, top = 5, bottom = 3}
}

local function SetGroupBackdrop(frame)
    frame:SetBackdrop(GROUP_BACKDROP)
    frame:SetBackdropColor(0.1, 0.1, 0.1, 0.5)
    frame:SetBackdropBorderColor(0.4, 0.4, 0.4)
end

-- Blizzard templates (buttons, edit boxes, scroll bars) want named frames
local nameCount = 0
local function NextName(kind)
    nameCount = nameCount + 1
    return "SkomsArenaStats" .. kind .. nameCount
end

function UI.CreateText(parent, fontObject, justify)
    local text = parent:CreateFontString(nil, "OVERLAY",
                                         fontObject or "GameFontHighlightSmall")
    text:SetJustifyH(justify or "LEFT")
    return text
end

function UI.ClassColor(classToken)
    local color = classToken and _G.RAID_CLASS_COLORS[classToken]
    if color then return color.r, color.g, color.b end
    return 1, 1, 1
end

function UI.SignedNumber(value)
    if value > 0 then return "+" .. value end
    return tostring(value)
end

-- green above zero, red below, plain at zero
function UI.ValueColor(value)
    if not value or value == 0 then return UI.colors.text end
    return value > 0 and UI.colors.good or UI.colors.bad
end

function UI.CreateButton(parent, text, width)
    local button = _G.CreateFrame("Button", NextName("Button"), parent,
                                  "UIPanelButtonTemplate")
    button:SetWidth(width)
    button:SetHeight(22)
    button:SetText(text)
    return button
end

-- A row of buttons where exactly one option is selected (kept highlighted)
function UI.CreateSegmented(parent, options, buttonWidth, onSelect)
    local control = {buttons = {}}
    control.frame = _G.CreateFrame("Frame", nil, parent)
    control.frame:SetWidth(#options * buttonWidth)
    control.frame:SetHeight(22)

    function control:SetValue(value)
        self.value = value
        for _, button in ipairs(self.buttons) do
            if button.value == value then
                button:LockHighlight()
            else
                button:UnlockHighlight()
            end
        end
    end

    for i, option in ipairs(options) do
        local button = UI.CreateButton(control.frame, option.label, buttonWidth)
        button:SetPoint("LEFT", (i - 1) * buttonWidth, 0)
        button.value = option.value
        button:SetScript("OnClick", function()
            control:SetValue(option.value)
            onSelect(option.value)
        end)
        control.buttons[i] = button
    end
    control:SetValue(options[1].value)
    return control
end

function UI.CreateSearchBox(parent, width, placeholder, onChange)
    local box = _G.CreateFrame("EditBox", NextName("Search"), parent,
                               "InputBoxTemplate")
    box:SetWidth(width)
    box:SetHeight(20)
    box:SetAutoFocus(false)

    box.placeholder = UI.CreateText(box, "GameFontDisableSmall")
    box.placeholder:SetPoint("LEFT", 2, 0)
    box.placeholder:SetText(placeholder)

    local function UpdatePlaceholder(self)
        if self:GetText() == "" and not self.hasFocus then
            self.placeholder:Show()
        else
            self.placeholder:Hide()
        end
    end
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEditFocusGained", function(self)
        self.hasFocus = true
        UpdatePlaceholder(self)
    end)
    box:SetScript("OnEditFocusLost", function(self)
        self.hasFocus = false
        UpdatePlaceholder(self)
    end)
    box:SetScript("OnTextChanged", function(self)
        UpdatePlaceholder(self)
        onChange(self:GetText())
    end)
    return box
end

-- Gold column titles over a thin divider; columns = {{title, x}, ...}
function UI.CreateHeaderRow(parent, columns)
    local header = _G.CreateFrame("Frame", nil, parent)
    header:SetWidth(UI.CONTENT_WIDTH)
    header:SetHeight(UI.ROW_HEIGHT)
    for _, column in ipairs(columns) do
        local title = UI.CreateText(header, "GameFontNormalSmall")
        title:SetPoint("LEFT", column[2], 0)
        title:SetText(column[1])
    end
    local divider = header:CreateTexture(nil, "ARTWORK")
    divider:SetTexture(1, 1, 1, 0.15)
    divider:SetHeight(1)
    divider:SetPoint("BOTTOMLEFT")
    divider:SetPoint("BOTTOMRIGHT")
    return header
end

local function CreateTableRow(tbl, index)
    local row = _G.CreateFrame("Button", nil, tbl.child)
    row:SetHeight(UI.ROW_HEIGHT)
    row:SetWidth(tbl.child:GetWidth())
    row:SetPoint("TOPLEFT", 0, -(index - 1) * UI.ROW_HEIGHT)
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    row.cells = {}
    local x = 6
    for i, column in ipairs(tbl.columns) do
        local cell = {}
        if column[3] == "bar" then
            cell.bar = _G.CreateFrame("StatusBar", nil, row)
            cell.bar:SetPoint("LEFT", x, 0)
            cell.bar:SetWidth(column[2] - 16)
            cell.bar:SetHeight(14)
            cell.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
            local barBg = cell.bar:CreateTexture(nil, "BACKGROUND")
            barBg:SetTexture(0, 0, 0, 0.5)
            barBg:SetAllPoints()
            cell.text = UI.CreateText(cell.bar, "GameFontHighlightSmall")
            cell.text:SetPoint("LEFT", 4, 0)
        else
            cell.text = UI.CreateText(row, "GameFontHighlightSmall")
            cell.text:SetPoint("LEFT", x, 0)
            cell.text:SetWidth(column[2] - 8)
        end
        row.cells[i] = cell
        x = x + column[2]
    end

    row:SetScript("OnEnter", function(self)
        if self.onEnter then self.onEnter(self) end
    end)
    row:SetScript("OnLeave", function() _G.GameTooltip:Hide() end)
    return row
end

-- data = {{cells = {{text =, color =, value =, max =, barColor =}, ...},
--          onEnter = function(row)}, ...}
local function SetTableRows(tbl, data)
    for index, rowData in ipairs(data) do
        local row = tbl.rows[index] or CreateTableRow(tbl, index)
        tbl.rows[index] = row
        row.onEnter = rowData.onEnter
        row.bg:SetTexture(1, 1, 1, index % 2 == 0 and 0.04 or 0)
        for i, cell in ipairs(row.cells) do
            local value = rowData.cells[i] or {}
            cell.text:SetText(value.text or "")
            cell.text:SetTextColor(unpack(value.color or UI.colors.text))
            if cell.bar then
                cell.bar:SetMinMaxValues(0, value.max or 1)
                cell.bar:SetValue(value.value or 0)
                local barColor = value.barColor or UI.colors.accent
                cell.bar:SetStatusBarColor(barColor[1], barColor[2], barColor[3],
                                           0.6)
            end
        end
        row:Show()
    end
    for index = #data + 1, #tbl.rows do tbl.rows[index]:Hide() end

    tbl.child:SetHeight(math.max(1, #data * UI.ROW_HEIGHT))
    -- the 3.3.5a scroll template always shows its bar; only show it when needed
    if #data * UI.ROW_HEIGHT > tbl.scroll:GetHeight() then
        tbl.scrollBar:Show()
    else
        tbl.scrollBar:Hide()
        tbl.scroll:SetVerticalScroll(0)
    end
end

-- Header + scrolling rows; columns = {{title, width[, "bar"]}, ...}
function UI.CreateTable(parent, name, columns, height)
    local tbl = {columns = columns, rows = {}, SetRows = SetTableRows}
    local width = UI.CONTENT_WIDTH

    tbl.frame = _G.CreateFrame("Frame", nil, parent)
    tbl.frame:SetWidth(width)
    tbl.frame:SetHeight(height)

    local titles, x = {}, 6
    for i, column in ipairs(columns) do
        titles[i] = {column[1], x}
        x = x + column[2]
    end
    UI.CreateHeaderRow(tbl.frame, titles):SetPoint("TOPLEFT")

    -- UIPanelScrollFrameTemplate puts its bar outside the frame, on the right
    tbl.scroll = _G.CreateFrame("ScrollFrame", name, tbl.frame,
                                "UIPanelScrollFrameTemplate")
    tbl.scroll:SetPoint("TOPLEFT", 0, -UI.ROW_HEIGHT - 4)
    tbl.scroll:SetWidth(width - 24)
    tbl.scroll:SetHeight(height - UI.ROW_HEIGHT - 4)
    tbl.scrollBar = _G[name .. "ScrollBar"]

    tbl.child = _G.CreateFrame("Frame", nil, tbl.scroll)
    tbl.child:SetWidth(width - 24)
    tbl.child:SetHeight(1)
    tbl.scroll:SetScrollChild(tbl.child)
    return tbl
end

-- Main window

local TABS = {
    {
        key = "week",
        label = L["This Week"],
        build = "BuildWeekPage",
        refresh = "RefreshWeekPage"
    }, {
        key = "characters",
        label = L["Characters"],
        build = "BuildCharactersPage",
        refresh = "RefreshCharactersPage"
    }, {
        key = "history",
        label = L["History"],
        build = "BuildHistoryPage",
        refresh = "RefreshHistoryPage"
    }
}

-- One tab in the look of AceGUI's TabGroup (Interface Options tab art)
local function CreateTab(parent, text)
    local tab = _G.CreateFrame("Button", NextName("Tab"), parent)
    tab:SetHeight(24)

    local function Piece(texture, coordLeft, coordRight, width)
        local piece = tab:CreateTexture(nil, "BORDER")
        piece:SetTexture(texture)
        piece:SetTexCoord(coordLeft, coordRight, 0, 1)
        piece:SetWidth(width)
        piece:SetHeight(24)
        return piece
    end
    local active = "Interface\\OptionsFrame\\UI-OptionsFrame-ActiveTab"
    local inactive = "Interface\\OptionsFrame\\UI-OptionsFrame-InActiveTab"

    tab:SetNormalFontObject(_G.GameFontNormalSmall)
    tab:SetHighlightFontObject(_G.GameFontHighlightSmall)
    tab:SetDisabledFontObject(_G.GameFontHighlightSmall)
    tab:SetText(text)
    local textWidth = tab:GetFontString():GetStringWidth()

    tab.activePieces = {
        Piece(active, 0, 0.15625, 20), Piece(active, 0.15625, 0.84375, textWidth),
        Piece(active, 0.84375, 1, 20)
    }
    tab.inactivePieces = {
        Piece(inactive, 0, 0.15625, 20), Piece(inactive, 0.15625, 0.84375, textWidth),
        Piece(inactive, 0.84375, 1, 20)
    }
    -- the active art sits 3px lower so it joins the border below
    tab.activePieces[1]:SetPoint("BOTTOMLEFT", 0, -3)
    tab.inactivePieces[1]:SetPoint("TOPLEFT")
    for _, pieces in ipairs({tab.activePieces, tab.inactivePieces}) do
        pieces[2]:SetPoint("LEFT", pieces[1], "RIGHT")
        pieces[3]:SetPoint("LEFT", pieces[2], "RIGHT")
    end
    tab:SetWidth(textWidth + 40)

    tab:SetHighlightTexture("Interface\\PaperDollInfoFrame\\UI-Character-Tab-Highlight",
                            "ADD")
    local highlight = tab:GetHighlightTexture()
    highlight:ClearAllPoints()
    highlight:SetPoint("LEFT", 10, -4)
    highlight:SetPoint("RIGHT", -10, -4)
    return tab
end

local function SetTabSelected(tab, selected)
    for _, piece in ipairs(tab.activePieces) do
        if selected then piece:Show() else piece:Hide() end
    end
    for _, piece in ipairs(tab.inactivePieces) do
        if selected then piece:Hide() else piece:Show() end
    end
    tab:GetFontString():ClearAllPoints()
    if selected then
        tab:Disable()
        tab:GetFontString():SetPoint("CENTER", 0, -2)
    else
        tab:Enable()
        tab:GetFontString():SetPoint("CENTER", 0, -3)
    end
end

function SkomsArenaStats:SaveWindowPosition(frame)
    local point, _, relativePoint, x, y = frame:GetPoint()
    self.db.profile.window = {
        point = point,
        relativePoint = relativePoint,
        x = x,
        y = y
    }
end

function SkomsArenaStats:RestoreWindowPosition(frame)
    local position = self.db.profile.window
    frame:ClearAllPoints()
    if position and position.point then
        frame:SetPoint(position.point, _G.UIParent, position.relativePoint,
                       position.x, position.y)
    else
        frame:SetPoint("CENTER")
    end
end

function SkomsArenaStats:CreateMainWindow()
    local f = _G.CreateFrame("Frame", "SkomsArenaStatsFrame", _G.UIParent)
    f:SetWidth(UI.WIDTH)
    f:SetHeight(UI.HEIGHT)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetBackdrop(DIALOG_BACKDROP)
    f:SetBackdropColor(0, 0, 0, 1)
    f:Hide()
    table.insert(_G.UISpecialFrames, "SkomsArenaStatsFrame")
    self:RestoreWindowPosition(f)

    -- title on the dialog header, dragging the header moves the window
    local title = UI.CreateText(f, "GameFontNormal", "CENTER")
    title:SetText(addonTitle)
    local titleWidth = title:GetStringWidth() + 10
    local titleBg = f:CreateTexture(nil, "OVERLAY")
    titleBg:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
    titleBg:SetTexCoord(0.31, 0.67, 0, 0.63)
    titleBg:SetPoint("TOP", 0, 12)
    titleBg:SetWidth(titleWidth)
    titleBg:SetHeight(40)
    local titleLeft = f:CreateTexture(nil, "OVERLAY")
    titleLeft:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
    titleLeft:SetTexCoord(0.21, 0.31, 0, 0.63)
    titleLeft:SetPoint("RIGHT", titleBg, "LEFT")
    titleLeft:SetWidth(30)
    titleLeft:SetHeight(40)
    local titleRight = f:CreateTexture(nil, "OVERLAY")
    titleRight:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
    titleRight:SetTexCoord(0.67, 0.77, 0, 0.63)
    titleRight:SetPoint("LEFT", titleBg, "RIGHT")
    titleRight:SetWidth(30)
    titleRight:SetHeight(40)
    title:SetPoint("TOP", titleBg, "TOP", 0, -14)

    local drag = _G.CreateFrame("Frame", nil, f)
    drag:SetPoint("TOPLEFT", titleLeft)
    drag:SetPoint("BOTTOMRIGHT", titleRight)
    drag:EnableMouse(true)
    drag:SetScript("OnMouseDown", function() f:StartMoving() end)
    drag:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
        SkomsArenaStats:SaveWindowPosition(f)
    end)

    -- the tab group: a bordered area with the tabs sitting on its top edge
    f.border = _G.CreateFrame("Frame", nil, f)
    f.border:SetPoint("TOPLEFT", 14, -52)
    f.border:SetPoint("BOTTOMRIGHT", -14, 44)
    SetGroupBackdrop(f.border)

    f.tabs = {}
    local previous
    for _, tab in ipairs(TABS) do
        local button = CreateTab(f, tab.label)
        button:SetFrameLevel(f.border:GetFrameLevel() + 1)
        if previous then
            button:SetPoint("LEFT", previous, "RIGHT", -10, 0)
        else
            button:SetPoint("BOTTOMLEFT", f.border, "TOPLEFT", 4, -4)
        end
        button:SetScript("OnClick", function()
            _G.PlaySound("igCharacterInfoTab")
            SkomsArenaStats:SelectTab(tab.key)
        end)
        SetTabSelected(button, false)
        f.tabs[tab.key] = button
        previous = button
    end

    f.content = _G.CreateFrame("Frame", nil, f.border)
    f.content:SetPoint("TOPLEFT", 10, -10)
    f.content:SetWidth(UI.CONTENT_WIDTH)
    f.content:SetHeight(UI.CONTENT_HEIGHT)

    -- status bar and Close button, as at the bottom of Ace windows
    local statusBg = _G.CreateFrame("Frame", nil, f)
    statusBg:SetPoint("BOTTOMLEFT", 15, 15)
    statusBg:SetPoint("BOTTOMRIGHT", -132, 15)
    statusBg:SetHeight(24)
    statusBg:SetBackdrop(GROUP_BACKDROP)
    statusBg:SetBackdropColor(0.1, 0.1, 0.1)
    statusBg:SetBackdropBorderColor(0.4, 0.4, 0.4)
    f.status = UI.CreateText(statusBg, "GameFontNormal")
    f.status:SetPoint("TOPLEFT", 7, -2)
    f.status:SetPoint("BOTTOMRIGHT", -7, 2)

    local close = UI.CreateButton(f, _G.CLOSE, 100)
    close:SetHeight(20)
    close:SetPoint("BOTTOMRIGHT", -27, 17)
    close:SetScript("OnClick", function() f:Hide() end)

    f.pages = {}
    mainFrame = f
end

function SkomsArenaStats:SetStatusText(text)
    if mainFrame then mainFrame.status:SetText(text) end
end

function SkomsArenaStats:SelectTab(key)
    local selected = TABS[1]
    for _, tab in ipairs(TABS) do
        if tab.key == key then selected = tab end
    end

    for tabKey, button in pairs(mainFrame.tabs) do
        SetTabSelected(button, tabKey == selected.key)
    end
    for _, page in pairs(mainFrame.pages) do page:Hide() end

    local page = mainFrame.pages[selected.key]
    if not page then
        page = _G.CreateFrame("Frame", nil, mainFrame.content)
        page:SetAllPoints(mainFrame.content)
        self[selected.build](self, page)
        mainFrame.pages[selected.key] = page
    end
    page:Show()

    mainFrame.currentTab = selected.key
    self.db.profile.lastTab = selected.key
    self[selected.refresh](self)
end

function SkomsArenaStats:RefreshCurrentTab()
    if not mainFrame or not mainFrame:IsShown() then return end
    self:SelectTab(mainFrame.currentTab)
end

-- Called by the weekly tracking; the history list doesn't depend on it
function SkomsArenaStats:RefreshWeekly()
    if mainFrame and mainFrame.currentTab ~= "history" then
        self:RefreshCurrentTab()
    end
end

function SkomsArenaStats:Show(tabKey)
    if not mainFrame then self:CreateMainWindow() end
    mainFrame:Show()
    self:SelectTab(tabKey or self.db.profile.lastTab)
    -- the tab refreshes again when the up-to-date team stats arrive
    self:RequestArenaTeams()
    self:UpdateCurrencies()
end

function SkomsArenaStats:Hide() if mainFrame then mainFrame:Hide() end end

function SkomsArenaStats:Toggle()
    if mainFrame and mainFrame:IsShown() then
        self:Hide()
    else
        self:Show()
    end
end

function SkomsArenaStats:ToggleWeekly()
    if mainFrame and mainFrame:IsShown() and mainFrame.currentTab == "week" then
        self:Hide()
    else
        self:Show("week")
    end
end

-- History tab

-- x offsets match the row template in HybridScrollFrame.xml
local HISTORY_COLUMNS = {
    {"Date", 4}, {"Map", 154}, {"Duration", 198}, {"Team", 296},
    {"Rating", 400}, {"MMR", 468}, {"Enemy Team", 512}, {"Enemy MMR", 632},
    {"Enemy Faction", 700}
}

function SkomsArenaStats:BuildHistoryPage(page)
    history = {}

    history.bracket = UI.CreateSegmented(page, {
        {value = 0, label = _G.ALL}, {value = 2, label = UI.BRACKET_LABELS[2]},
        {value = 3, label = UI.BRACKET_LABELS[3]},
        {value = 5, label = UI.BRACKET_LABELS[5]}
    }, 64, function(value)
        filters.bracket = value
        SkomsArenaStats:RefreshHistoryList()
    end)
    history.bracket.frame:SetPoint("TOPLEFT", 0, 0)

    history.arenaType = UI.CreateSegmented(page, {
        {value = 0, label = _G.ALL}, {value = true, label = L["Rated"]},
        {value = false, label = L["Skirmish"]}
    }, 80, function(value)
        filters.arenaType = value
        SkomsArenaStats:RefreshHistoryList()
    end)
    history.arenaType.frame:SetPoint("LEFT", history.bracket.frame, "RIGHT", 16, 0)

    history.search = UI.CreateSearchBox(page, 200, L["Filter By Name"],
                                        function(text)
        filters.name = text
        SkomsArenaStats:RefreshHistoryList()
    end)
    history.search:SetPoint("TOPRIGHT", -4, -1)

    local titles = {}
    for i, column in ipairs(HISTORY_COLUMNS) do
        titles[i] = {L[column[1]], column[2]}
    end
    UI.CreateHeaderRow(page, titles):SetPoint("TOPLEFT", 0, -30)

    local listHeight = UI.CONTENT_HEIGHT - 54
    local list = _G.CreateFrame("Frame", nil, page)
    list:SetPoint("TOPLEFT", 0, -54)
    list:SetWidth(UI.CONTENT_WIDTH)
    list:SetHeight(listHeight)

    -- 3.3.5a's HybridScrollFrame_CreateButtons needs a named scroll frame and
    -- a real height, so size it explicitly instead of through the template
    local scrollFrame = _G.CreateFrame("ScrollFrame", "SkomsArenaStatsScrollFrame",
                                       list, "SkomsArenaStatsHybridScrollFrame")
    scrollFrame:ClearAllPoints()
    scrollFrame:SetPoint("TOPLEFT")
    scrollFrame:SetWidth(UI.CONTENT_WIDTH - 24)
    scrollFrame:SetHeight(listHeight)
    scrollFrame.scrollBar = scrollFrame.scrollBar or
                                _G.SkomsArenaStatsScrollFrameScrollBar
    _G.HybridScrollFrame_CreateButtons(scrollFrame,
                                       "SkomsArenaStatsHybridScrollListItemTemplate")
    scrollFrame.scrollChild:SetWidth(UI.CONTENT_WIDTH - 24)
    for _, button in ipairs(scrollFrame.buttons) do
        local buttonName = button:GetName()
        for _, key in ipairs(ROW_REGIONS) do
            button[key] = _G[buttonName .. key]
        end
    end
    scrollFrame.update = function() SkomsArenaStats:RefreshLayout() end
    history.scrollFrame = scrollFrame
end

function SkomsArenaStats:RefreshHistoryPage()
    rows = self:BuildTable()
    self:RefreshHistoryList()
end

function SkomsArenaStats:RefreshHistoryList()
    self:SortTable()
    self:RefreshLayout()
end

function SkomsArenaStats:EnemyNameFilterRow(row)
    if filters.name == "" then
        return false
    end
    for category, val in pairs(row) do
        -- find player names within the row
        if (type(val) == "string" and category:sub(1, #"enemyPlayerName") == "enemyPlayerName") then
            -- if the filter.name value is anywhere within a substring of the player names
            if (string.find(val:lower(), filters.name:lower(), 1, true)) then
                return false
            end
        end
    end
    return true
end

function SkomsArenaStats:FilterRow(row)
    if (filters.bracket ~= 0 and row["teamSize"] ~= filters.bracket) then
        return true
    end
    if (filters.arenaType ~= 0 and row["isRanked"] ~= filters.arenaType) then
        return true
    end
    if (self:EnemyNameFilterRow(row)) then
        return true
    end
    return false
end

function SkomsArenaStats:SortTable()
    filtered = {}
    for i = 1, #rows do
        local row = rows[i]
        if (not self:FilterRow(row)) then table.insert(filtered, row) end
    end
end

function SkomsArenaStats:SortClassTable(a, b)
    -- regular sort, pushes nils to end
    if (not a or not b) then
        return not b
    else
        return a < b
    end
end

function SkomsArenaStats:RefreshLayout()
    local scrollFrame = history.scrollFrame
    local buttons = scrollFrame.buttons
    local offset = _G.HybridScrollFrame_GetOffset(scrollFrame)

    self:SetStatusText(string.format(L["Recorded %i arenas"], #rows))

    for buttonIndex = 1, #buttons do
        local button = buttons[buttonIndex]
        local itemIndex = buttonIndex + offset
        local row = filtered[itemIndex]

        if (itemIndex <= #filtered) then
            button:SetID(itemIndex)
            -- the 3.3.5a client's date() doesn't support %F/%T
            button.Date:SetText(_G.date("%Y-%m-%d %H:%M:%S", row["endTime"]))
            button.Map:SetText(self:GetShortMapName(row["zoneId"],
                                                    row["zoneName"]))
            button.Duration:SetText(self:HumanDuration(row["duration"]))
            local teamClasses = {
                row["teamPlayerClass1"], row["teamPlayerClass2"],
                row["teamPlayerClass3"], row["teamPlayerClass4"],
                row["teamPlayerClass5"]
            }
            table.sort(teamClasses, function(a, b)
                return SkomsArenaStats:SortClassTable(a, b)
            end)

            local teamPlayerNames = {
                row["teamPlayerName1"], row["teamPlayerName2"],
                row["teamPlayerName3"], row["teamPlayerName4"],
                row["teamPlayerName5"]
            }
            local enemyPlayerNames = {
                row["enemyPlayerName1"], row["enemyPlayerName2"],
                row["enemyPlayerName3"], row["enemyPlayerName4"],
                row["enemyPlayerName5"]
            }
            button:SetScript("OnEnter", function(self)
                SkomsArenaStats:ShowTooltip(self, teamPlayerNames, enemyPlayerNames)
            end)
            button:SetScript("OnLeave", function()
                SkomsArenaStats:HideTooltip()
            end)

            self:SetClassIcon(button.IconTeamPlayerClass1, teamClasses[1])
            self:SetClassIcon(button.IconTeamPlayerClass2, teamClasses[2])
            self:SetClassIcon(button.IconTeamPlayerClass3, teamClasses[3])
            self:SetClassIcon(button.IconTeamPlayerClass4, teamClasses[4])
            self:SetClassIcon(button.IconTeamPlayerClass5, teamClasses[5])
            button.Rating:SetText((row["newTeamRating"] or "-") .. " (" ..
                                      ((row["diffRating"] and row["diffRating"] >
                                          0 and "+" .. row["diffRating"] or
                                          row["diffRating"]) or "0") .. ")")
            button.Rating:SetTextColor(unpack(UI.ValueColor(row["diffRating"])))
            if (row["teamColor"] ~= nil and row["winnerColor"] ~= nil) then
                if (row["teamColor"] ~= row["winnerColor"]) then
                    button.Rating:SetTextColor(unpack(UI.colors.bad))
                else
                    button.Rating:SetTextColor(unpack(UI.colors.good))
                end
            end
            button.MMR:SetText(row["mmr"] or "-")

            local enemyClasses = {
                row["enemyPlayerClass1"], row["enemyPlayerClass2"],
                row["enemyPlayerClass3"], row["enemyPlayerClass4"],
                row["enemyPlayerClass5"]
            }
            table.sort(enemyClasses, function(a, b)
                return SkomsArenaStats:SortClassTable(a, b)
            end)

            self:SetClassIcon(button.IconEnemyPlayer1, enemyClasses[1])
            self:SetClassIcon(button.IconEnemyPlayer2, enemyClasses[2])
            self:SetClassIcon(button.IconEnemyPlayer3, enemyClasses[3])
            self:SetClassIcon(button.IconEnemyPlayer4, enemyClasses[4])
            self:SetClassIcon(button.IconEnemyPlayer5, enemyClasses[5])
            button.EnemyMMR:SetText(row["enemyMmr"] or "-")
            button.EnemyFaction:SetTexture(self:FactionIconId(
                                               row["enemyFaction"]))

            button:SetWidth(scrollFrame.scrollChild:GetWidth())
            button:Show()
        else
            button:Hide()
        end
    end

    local buttonHeight = scrollFrame.buttonHeight
    local totalHeight = #filtered * buttonHeight
    local shownHeight = #buttons * buttonHeight

    _G.HybridScrollFrame_Update(scrollFrame, totalHeight, shownHeight)
end

function SkomsArenaStats:HumanDuration(seconds)
    if seconds < 60 then return string.format(L["%is"], seconds) end
    local minutes = math.floor(seconds / 60)
    if minutes < 60 then
        return string.format(L["%im %is"], minutes, (seconds - minutes * 60))
    end
    local hours = math.floor(minutes / 60)
    return string.format(L["%ih %im"], hours, (minutes - hours * 60))
end

function SkomsArenaStats:SetClassIcon(texture, className)
    local coords = className and CLASS_ICON_COORDS[className]
    if not coords then
        texture:SetTexture(nil)
        return
    end
    texture:SetTexture(CLASS_ICON_TEXTURE)
    texture:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
end

function SkomsArenaStats:FactionIconId(factionId)

    if not factionId then return nil end

    if factionId == 0 then
        return "Interface\\Icons\\INV_BannerPVP_01"
    else
        return "Interface\\Icons\\INV_BannerPVP_02"
    end
end

function SkomsArenaStats:GetShortMapName(id, zoneName)
    local name = SkomsArenaStats.mapListShortName[id]
    if name then
        return name
    elseif zoneName and zoneName ~= "" then
        return SkomsArenaStats:CreateShortMapName(zoneName)
    elseif id then
        return "E" .. id
    else
        return "E"
    end
end

function SkomsArenaStats:ShowTooltip(owner, teamPlayerNames, enemyPlayerNames)
    if not SkomsArenaStats:ShowCharacterNamesOnHover() then return end
    local tooltip = _G.GameTooltip
    tooltip:SetOwner(owner, "ANCHOR_TOP")
    tooltip:ClearLines()
    tooltip:AddLine(L["Names"])
    for i, name in ipairs(teamPlayerNames) do
        tooltip:AddLine(name, 0, 1, 0)
    end
    tooltip:AddLine('---------------')
    for i, name in ipairs(enemyPlayerNames) do
        tooltip:AddLine(name, 1, 0, 0)
    end
    tooltip:Show()
end

function SkomsArenaStats:HideTooltip() _G.GameTooltip:Hide() end
