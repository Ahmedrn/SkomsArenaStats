local addonName = "SkomsArenaStats"
local addonTitle = select(2, _G.GetAddOnInfo(addonName))
local SkomsArenaStats = _G.LibStub("AceAddon-3.0"):NewAddon(addonName,
                                                       "AceConsole-3.0",
                                                       "AceEvent-3.0")
local L = _G.LibStub("AceLocale-3.0"):GetLocale(addonName, true)
local libDBIcon = _G.LibStub("LibDBIcon-1.0")
local LibRaces = _G.LibStub("LibRaces-1.0")
local IsActiveBattlefieldArena = IsActiveBattlefieldArena
local GetBattlefieldStatus, GetBattlefieldTeamInfo, GetNumBattlefieldScores,
      GetBattlefieldScore, GetBattlefieldWinner, IsInInstance, GetRealZoneText =
    GetBattlefieldStatus, GetBattlefieldTeamInfo, GetNumBattlefieldScores,
    GetBattlefieldScore, GetBattlefieldWinner, IsInInstance, GetRealZoneText
local UnitName = UnitName

-- 3.3.5a's GetInstanceInfo has no instance ID, so arenas are resolved from
-- their (enUS) zone name to the instance IDs the Classic version recorded
SkomsArenaStats.arenaZoneIds = {
    ["Nagrand Arena"] = 559,
    ["Blade's Edge Arena"] = 562,
    ["Ruins of Lordaeron"] = 572,
    ["Dalaran Arena"] = 617,
    ["Dalaran Sewers"] = 617,
    ["The Ring of Valor"] = 618,
    ["Ring of Valor"] = 618
}

-- Setup runs in OnEnable (PLAYER_LOGIN): on 3.3.5a, AceAddon can call
-- OnInitialize on another addon's ADDON_LOADED before our other files and
-- SavedVariables are loaded
function SkomsArenaStats:OnEnable()
    self.db = _G.LibStub("AceDB-3.0"):New(addonName, {
        profile = {
            minimapButton = {hide = false},
            maxHistory = 0,
            characterNamesOnHover = {hide = false},
            window = {},
            lastTab = "week"
        },
        char = {history = {}},
        -- account-wide so every character can see the others (Weekly.lua)
        global = {
            characters = {},
            weeklyReset = {day = 4, hour = 6, autoHour = true}
        }
    })

    self:RegisterChatCommand("as", "ChatCommand")
    self:RegisterChatCommand("sas", "ChatCommand")
    self:RegisterChatCommand("skomsarenastats", "ChatCommand")

    self:RegisterEvent("UPDATE_BATTLEFIELD_STATUS")
    self:RegisterEvent("UPDATE_BATTLEFIELD_SCORE")
    self:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    self:RegisterEvent("PLAYER_ENTERING_WORLD")
    self:RegisterEvent("HONOR_CURRENCY_UPDATE", "UpdateCurrencies")
    self:RegisterEvent("CURRENCY_DISPLAY_UPDATE", "UpdateCurrencies")
    self:RegisterEvent("ARENA_TEAM_UPDATE", "UpdateArenaTeams")
    self:RegisterEvent("ARENA_TEAM_ROSTER_UPDATE", "UpdateArenaTeams")
    self:RegisterEvent("UPDATE_INSTANCE_INFO")

    self:TagRecordedSoloQueue()
    self:DrawMinimapIcon()
    self:RegisterOptionsTable()

    self.arenaEnded = false
    self.current = {status = "none", stats = {}}
    -- A match in progress is kept in the saved variables, so a /reload or a
    -- disconnect during the arena keeps its start time and still records it
    local pending = self.db.char.pending
    if type(pending) == "table" and pending.startTime then
        self.current.status = "active"
        self.current.stats = pending
    else
        self:Reset()
    end
end

function SkomsArenaStats:PLAYER_ENTERING_WORLD()
    self:CheckArenaLeft()
    self:UpdateCharacterSnapshot()
end

-- Outside an arena, an unfinished match (left early, or a pending one from a
-- previous session) is dropped so the next arena starts clean
function SkomsArenaStats:CheckArenaLeft()
    local _, instanceType = IsInInstance()
    if instanceType ~= "arena" and self.current.status ~= "none" then
        self:Reset()
    end
end

function SkomsArenaStats:ChatCommand(input)
    local command = string.lower(strtrim(input or ""))
    if command == "" then
        self:Toggle()
    elseif command == "weekly" or command == "week" then
        self:ToggleWeekly()
    elseif command == "characters" or command == "history" then
        self:Show(command)
    elseif command == "options" or command == "config" then
        self:OpenOptions()
    else
        self:Print(L["/as - open or close the window"])
        self:Print(L["/as weekly, /as characters, /as history - open that tab"])
        self:Print(L["/as options - open the options"])
    end
end

function SkomsArenaStats:ZONE_CHANGED_NEW_AREA()
    local _, instanceType = IsInInstance()
    if (instanceType == "arena") then
        self.arenaEnded = false
    else
        self:CheckArenaLeft()
    end
end

function SkomsArenaStats:UPDATE_BATTLEFIELD_STATUS()
    -- 3.3.5a fires this event without a queue index, so check every slot
    for index = 1, (_G.MAX_BATTLEFIELD_QUEUES or 3) do
        local status, mapName, instanceID, levelRangeMin, levelRangeMax,
              teamSize, registeredMatch = GetBattlefieldStatus(index)
        if (status == "active" and teamSize and teamSize > 0 and
            IsActiveBattlefieldArena()) then
            self.current["status"] = status
            self.current["stats"]["teamSize"] = teamSize
            -- IsArenaSkirmish doesn't exist in 3.3.5a
            self.current["stats"]["isRanked"] = registeredMatch and true or
                                                    false
            if (self.current["stats"]["startTime"] == nil or
                self.current["stats"]["startTime"] == '') then
                self.current["stats"]["startTime"] = _G.time()
            end
            self.db.char.pending = self.current["stats"]
        end
    end
end

-- Warmane plays Solo Queue as 3v3 matches between teams named "Solo Queue";
-- file them under the SoloQ bracket (the client's 5v5 team slot) instead
local SOLO_QUEUE_TEAM_NAME = "Solo Queue"

function SkomsArenaStats:TagSoloQueue(stats)
    if stats["teamName"] == SOLO_QUEUE_TEAM_NAME or stats["enemyTeamName"] ==
        SOLO_QUEUE_TEAM_NAME then
        stats["teamSize"] = 5
        stats["isSoloQueue"] = true
    end
end

-- Fix games recorded before Solo Queue detection existed, on every character
function SkomsArenaStats:TagRecordedSoloQueue()
    for _, charData in pairs(self.db.sv.char or {}) do
        for _, row in ipairs(charData.history or {}) do
            if not row["isSoloQueue"] then self:TagSoloQueue(row) end
        end
    end
end

function SkomsArenaStats:SetLastArenaRankingData()

    local playerTeam = ''
    local greenTeam = {}
    local goldTeam = {}
    local myName = UnitName("player")
    local numScores = GetNumBattlefieldScores()

    for i = 1, numScores do
        local data = {GetBattlefieldScore(i)}
        local teamIndex = data[6]
        if data[1] == myName then
            if teamIndex == 0 then
                playerTeam = 'GREEN'
            else
                playerTeam = 'GOLD'
            end
        end

        if teamIndex == 0 then
            table.insert(greenTeam, data)
        else
            table.insert(goldTeam, data)
        end
    end

    self.current["stats"]["teamColor"] = playerTeam

    for i = 0, 1 do
        local teamName, oldTeamRating, newTeamRating, teamMMR =
            GetBattlefieldTeamInfo(i)
        if teamMMR and teamMMR > 0 then
            if ((i == 0 and playerTeam == 'GREEN') or
                (i == 1 and playerTeam == 'GOLD')) then
                self.current["stats"]["teamName"] = teamName
                self.current["stats"]["oldTeamRating"] = oldTeamRating
                self.current["stats"]["newTeamRating"] = newTeamRating
                self.current["stats"]["diffRating"] = newTeamRating -
                                                          oldTeamRating
                self.current["stats"]["mmr"] = teamMMR
            else
                self.current["stats"]["enemyTeamName"] = teamName
                self.current["stats"]["enemyOldTeamRating"] = oldTeamRating
                self.current["stats"]["enemyNewTeamRating"] = newTeamRating
                self.current["stats"]["enemyDiffRating"] = newTeamRating -
                                                               oldTeamRating
                self.current["stats"]["enemyMmr"] = teamMMR
            end
        end
    end
    self:TagSoloQueue(self.current["stats"])

    self.current["stats"]["teamClass"] = {}
    self.current["stats"]["teamCharName"] = {}
    self.current["stats"]["teamRace"] = {}

    self.current["stats"]["enemyClass"] = {}
    self.current["stats"]["enemyName"] = {}
    self.current["stats"]["enemyRace"] = {}

    local playerTeamTable = goldTeam
    local enemyTeamTable = greenTeam
    if (playerTeam == 'GREEN') then
        playerTeamTable = greenTeam
        enemyTeamTable = goldTeam
    end

    -- playerName, killingBlows, honorKills, deaths, honorGained, faction, rank, race, class, classToken, damageDone, healingDone
    for i = 1, #playerTeamTable do
        local row = playerTeamTable[i]
        local race = LibRaces:GetRaceToken(row[8])
        local raceUpper
        if race == nil then
            raceUpper = ''
        else
            raceUpper = race:upper()
        end
        self.current["stats"]["teamClass"][i - 1] = row[10]:upper()
        self.current["stats"]["teamCharName"][i - 1] = row[1]
        self.current["stats"]["teamRace"][i - 1] = raceUpper
    end

    for i = 1, #enemyTeamTable do
        local row = enemyTeamTable[i]

        local race = LibRaces:GetRaceToken(row[8])
        local raceUpper
        if race == nil then
            raceUpper = ''
        else
            raceUpper = race:upper()
        end
        self.current["stats"]["enemyClass"][i - 1] = row[10]:upper()
        self.current["stats"]["enemyName"][i - 1] = row[1]
        self.current["stats"]["enemyRace"][i - 1] = race
        self.current["stats"]["enemyFaction"] = self:RaceToFaction(raceUpper)
    end
end

function SkomsArenaStats:RaceToFaction(race)
    if race == "HUMAN" then
        return 1
    elseif race == "GNOME" then
        return 1
    elseif race == "NIGHTELF" then
        return 1
    elseif race == "DRAENEI" then
        return 1
    elseif race == "DWARF" then
        return 1
    else
        return 0
    end

end

function SkomsArenaStats:UPDATE_BATTLEFIELD_SCORE()
    local battlefieldWinner = GetBattlefieldWinner()
    if battlefieldWinner == nil or self.arenaEnded then return end

    if self.current.status ~= 'none' then
        -- The winner can be known before the scoreboard and the rating
        -- changes arrive: ask again instead of losing the game or its rating
        -- (a few tries, then the game is recorded with what is there)
        if not self:ScoreDataReady() and (self.scoreTries or 0) < 5 then
            self.scoreTries = (self.scoreTries or 0) + 1
            _G.RequestBattlefieldScoreData()
            return
        end
        local zoneName = GetRealZoneText()
        self.current["stats"]["zoneId"] = self.arenaZoneIds[zoneName]
        self.current["stats"]["zoneName"] = zoneName
        self.current["stats"]["endTime"] = _G.time()
        self.arenaEnded = true
        if (battlefieldWinner == 0) then
            self.current["stats"]["winnerColor"] = "GREEN";
        elseif (battlefieldWinner == 1) then
            self.current["stats"]["winnerColor"] = "GOLD";
        end
        self:SetLastArenaRankingData()
        if GetNumBattlefieldScores() ~= 0 then self:RecordArena() end
    end
end

function SkomsArenaStats:ScoreDataReady()
    if GetNumBattlefieldScores() == 0 then return false end
    if not self.current["stats"]["isRanked"] then return true end
    for i = 0, 1 do
        local _, _, _, teamMMR = GetBattlefieldTeamInfo(i)
        if teamMMR and teamMMR > 0 then return true end
    end
    return false
end

function SkomsArenaStats:Reset()
    self.current["status"] = "none"

    self.current["stats"] = {}
    self.scoreTries = 0
    if self.db then self.db.char.pending = nil end
end

function SkomsArenaStats:RecordArena()
    self:AddEntryToHistory(self.current["stats"])
    self:Print("Arena recorded")
    self:Reset()
    self:RefreshCurrentTab()
end

function SkomsArenaStats:AddEntryToHistory(stats)
    table.insert(self.db.char.history, stats)
    if self.db.profile.maxHistory > 0 then
        while (#self.db.char.history > self.db.profile.maxHistory) do
            table.remove(self.db.char.history, 1)
        end
    end
end

function SkomsArenaStats:DrawMinimapIcon()
    libDBIcon:Register(addonName,
                       _G.LibStub("LibDataBroker-1.1"):NewDataObject(addonName,
                                                                     {
        type = "data source",
        text = addonName,
        icon = "interface/icons/achievement_arena_2v2_7",
        OnClick = function(self, button)
            if button == "RightButton" then
                SkomsArenaStats:OpenOptions()
            elseif _G.IsShiftKeyDown() then
                SkomsArenaStats:ToggleWeekly()
            else
                SkomsArenaStats:Toggle()
            end
        end,
        OnTooltipShow = function(tooltip)
            tooltip:AddLine(string.format("%s |cff777777v%s|r", addonTitle,
                                          _G.GetAddOnMetadata(addonName,
                                                              "Version")))
            tooltip:AddLine(string.format("|cFFCFCFCF%s|r %s", L["Left Click"],
                                          L["to open the main window"]))
            tooltip:AddLine(string.format("|cFFCFCFCF%s|r %s",
                                          L["Shift-Left Click"],
                                          L["to open the weekly summary"]))
            tooltip:AddLine(string.format("|cFFCFCFCF%s|r %s", L["Right Click"],
                                          L["to open options"]))
            tooltip:AddLine(string.format("|cFFCFCFCF%s|r %s", L["Drag"],
                                          L["to move this button"]))
        end
    }), self.db.profile.minimapButton)
end

function SkomsArenaStats:ToggleMinimapButton()
    self.db.profile.minimapButton.hide = not self.db.profile.minimapButton.hide
    if self.db.profile.minimapButton.hide then
        libDBIcon:Hide(addonName)
    else
        libDBIcon:Show(addonName)
    end
end

function SkomsArenaStats:CalculateTeamSize(row)
    if (row["teamSize"] ~= nil or row["teamClass"] == nil) then
        return row["teamSize"]
    end

    local teamSize = 0
    for i = 0, 5 do
        if row["teamClass"][i] ~= nil then teamSize = teamSize + 1 end
    end
    return teamSize
end

function SkomsArenaStats:BuildTable()
    local tbl = {}

    local tableLength = #self.db.char.history

    for i = 1, tableLength do
        local row = self.db.char.history[tableLength + 1 - i]
        table.insert(tbl, {

            -- Common stats

            ["startTime"] = row["startTime"],
            ["endTime"] = row["endTime"],
            ["zoneId"] = SkomsArenaStats:RemapZoneId(row["zoneId"]),
            ["zoneName"] = row["zoneName"],
            ["isRanked"] = row["isRanked"],
            ["teamSize"] = SkomsArenaStats:CalculateTeamSize(row),
            ["duration"] = (row["endTime"] and row["startTime"] and
                (row["endTime"] - row["startTime"]) or 0),

            -- Player's team

            ["teamName"] = row["teamName"],

            ["teamPlayerClass1"] = row["teamClass"] and row["teamClass"][0] or
                nil,
            ["teamPlayerClass2"] = row["teamClass"] and row["teamClass"][1] or
                nil,
            ["teamPlayerClass3"] = row["teamClass"] and row["teamClass"][2] or
                nil,
            ["teamPlayerClass4"] = row["teamClass"] and row["teamClass"][3] or
                nil,
            ["teamPlayerClass5"] = row["teamClass"] and row["teamClass"][4] or
                nil,
            ["teamPlayerName1"] = row["teamCharName"] and row["teamCharName"][0] or
                nil,
            ["teamPlayerName2"] = row["teamCharName"] and row["teamCharName"][1] or
                nil,
            ["teamPlayerName3"] = row["teamCharName"] and row["teamCharName"][2] or
                nil,
            ["teamPlayerName4"] = row["teamCharName"] and row["teamCharName"][3] or
                nil,
            ["teamPlayerName5"] = row["teamCharName"] and row["teamCharName"][4] or
                nil,
            ["teamPlayerRace1"] = row["teamRace"] and row["teamRace"][0] or nil,
            ["teamPlayerRace2"] = row["teamRace"] and row["teamRace"][1] or nil,
            ["teamPlayerRace3"] = row["teamRace"] and row["teamRace"][2] or nil,
            ["teamPlayerRace4"] = row["teamRace"] and row["teamRace"][3] or nil,
            ["teamPlayerRace5"] = row["teamRace"] and row["teamRace"][4] or nil,

            ["oldTeamRating"] = row["oldTeamRating"],
            ["newTeamRating"] = row["newTeamRating"],
            ["diffRating"] = row["diffRating"],
            ["mmr"] = row["mmr"],
            ["teamColor"] = row["teamColor"],
            ["winnerColor"] = row["winnerColor"],

            -- Enemy team

            ["enemyTeamName"] = row["enemyTeamName"],

            ["enemyPlayerClass1"] = row["enemyClass"] and row["enemyClass"][0] or
                nil,
            ["enemyPlayerClass2"] = row["enemyClass"] and row["enemyClass"][1] or
                nil,
            ["enemyPlayerClass3"] = row["enemyClass"] and row["enemyClass"][2] or
                nil,
            ["enemyPlayerClass4"] = row["enemyClass"] and row["enemyClass"][3] or
                nil,
            ["enemyPlayerClass5"] = row["enemyClass"] and row["enemyClass"][4] or
                nil,
            ["enemyPlayerName1"] = row["enemyName"] and row["enemyName"][0] or
                nil,
            ["enemyPlayerName2"] = row["enemyName"] and row["enemyName"][1] or
                nil,
            ["enemyPlayerName3"] = row["enemyName"] and row["enemyName"][2] or
                nil,
            ["enemyPlayerName4"] = row["enemyName"] and row["enemyName"][3] or
                nil,
            ["enemyPlayerName5"] = row["enemyName"] and row["enemyName"][4] or
                nil,
            ["enemyPlayerRace1"] = row["enemyRace"] and row["enemyRace"][0] or
                nil,
            ["enemyPlayerRace2"] = row["enemyRace"] and row["enemyRace"][1] or
                nil,
            ["enemyPlayerRace3"] = row["enemyRace"] and row["enemyRace"][2] or
                nil,
            ["enemyPlayerRace4"] = row["enemyRace"] and row["enemyRace"][3] or
                nil,
            ["enemyPlayerRace5"] = row["enemyRace"] and row["enemyRace"][4] or
                nil,
            ["enemyFaction"] = row["enemyFaction"],

            ["enemyOldTeamRating"] = row["enemyOldTeamRating"],
            ["enemyNewTeamRating"] = row["enemyNewTeamRating"],
            ["enemyDiffRating"] = row["enemyDiffRating"],
            ["enemyMmr"] = row["enemyMmr"]

        })
    end
    return tbl
end

function SkomsArenaStats:RemapZoneId(mapAreaId)
    -- remap old mapAreaId to instanceids (for backward compatibility)
    if mapAreaId == 3698 then
        return 559
    elseif mapAreaId == 3702 then
        return 562
    elseif mapAreaId == 3968 then
        return 572
    end
    return mapAreaId
end

-- The purged history and characters are kept as a backup until the next
-- purge, so a purge by mistake can be undone
function SkomsArenaStats:ResetDatabase()
    local backup = {char = self.db.sv.char, global = self.db.sv.global}
    if backup.global then backup.global.purgeBackup = nil end
    self.db:ResetDB()
    self.db.global.purgeBackup = backup
    self:Reset()
    self:RefreshCurrentTab()
    self:Print(L["Database reset"])
end

function SkomsArenaStats:HasPurgeBackup()
    return self.db.global.purgeBackup ~= nil
end

function SkomsArenaStats:RestorePurgedData()
    local backup = self.db.global.purgeBackup
    if not backup then return end
    self.db.sv.char = backup.char
    self.db.sv.global = backup.global
    _G.ReloadUI()
end

function SkomsArenaStats:ShowCharacterNamesOnHover()
    return not self.db.profile.characterNamesOnHover.hide
end
