local _G = _G
local addonName = "SkomsArenaStats"
local SkomsArenaStats = _G.LibStub("AceAddon-3.0"):GetAddon(addonName)
local L = _G.LibStub("AceLocale-3.0"):GetLocale(addonName, true)
local UI = SkomsArenaStats.UI

local DAY = 24 * 60 * 60
local WEEK = 7 * DAY
local BRACKETS = {2, 3, 5}
local HONOR_CAP = 75000
local ARENA_POINTS_CAP = 5000
-- arena points need the team to play 10 weekly games, with you in 30% of them
local MIN_WEEKLY_GAMES = 10
local MIN_WEEKLY_SHARE = 30 -- percent of the team's games
-- WotLK arena point multiplier per team type; Warmane's SoloQ (the 5 slot)
-- pays on the 2v2 scale
local BRACKET_MULTIPLIER = {[2] = 0.76, [3] = 0.88, [5] = 0.76}
-- Warmane rules: double points, ratings up to 1500 pay as 1500, and the
-- personal rating counts when it's more than 150 away from the team rating
local WARMANE_POINTS_RATE = 2
local MIN_POINTS_RATING = 1500
local PERSONAL_RATING_GAP = 150

local weekPage, charactersPage

-- Weekly reset

local RESET_SOURCES = {
    raid = L["a raid lockout (exact)"],
    daily = L["the daily quest reset + reset day option"],
    manual = L["the reset day and hour options"]
}

-- reset times are on the hour or half hour; rounding absorbs the few
-- seconds of drift between readings so every character agrees on the week
local function RoundToHalfHour(timestamp)
    return math.floor((timestamp + 900) / 1800) * 1800
end

-- the reset hour read from the game can move by a few hours between logins
-- (it said 04:00 on one character and 07:00 on the next), so two week starts
-- less than a day apart are the same week
local function SameWeek(a, b)
    return a ~= nil and b ~= nil and math.abs(a - b) < DAY
end

function SkomsArenaStats:GetResetHourMinute()
    local reset = self.db.global.weeklyReset
    if reset.autoHour then
        local seconds = _G.GetQuestResetTime()
        if seconds and seconds > 0 and seconds <= DAY then
            local t = _G.date("*t", RoundToHalfHour(_G.time() + seconds))
            return t.hour, t.min, "daily"
        end
    end
    return reset.hour, 0, "manual"
end

-- Start of the current arena week and where its time came from. From most
-- to least reliable: a weekly raid lockout seen on any character, the daily
-- quest reset hour on the configured day, or the configured day and hour.
function SkomsArenaStats:GetWeekStart(now)
    now = now or _G.time()
    local detected = self.db.global.detectedReset
    if detected then
        return detected - WEEK * math.ceil((detected - now) / WEEK), "raid"
    end

    local hour, minute, source = self:GetResetHourMinute()
    local t = _G.date("*t", now)
    local daysBack = (t.wday - self.db.global.weeklyReset.day) % 7
    local start = _G.time({
        year = t.year,
        month = t.month,
        day = t.day - daysBack,
        hour = hour,
        min = minute,
        sec = 0
    })
    if start > now then start = start - WEEK end
    return start, source
end

function SkomsArenaStats:GetResetStatusText()
    local now = _G.time()
    local weekStart, source = self:GetWeekStart(now)
    local untilReset = weekStart + WEEK - now
    return string.format(L["Resets in %dd %dh"], math.floor(untilReset / DAY),
                         math.floor(untilReset % DAY / 3600)) .. "  ·  " ..
               string.format(L["Reset time from %s"], RESET_SOURCES[source])
end

function SkomsArenaStats:UPDATE_INSTANCE_INFO()
    for index = 1, (_G.GetNumSavedInstances() or 0) do
        local _, _, reset, _, locked, _, _, isRaid = _G.GetSavedInstanceInfo(index)
        -- raid lockouts longer than a day are the weekly ones
        if locked and isRaid and reset and reset > DAY then
            local detected = RoundToHalfHour(_G.time() + reset)
            if detected ~= self.db.global.detectedReset then
                self.db.global.detectedReset = detected
                self:RefreshWeekly()
            end
            return
        end
    end
end

function SkomsArenaStats:ClearDetectedReset()
    self.db.global.detectedReset = nil
    self:RefreshWeekly()
end

-- Tracking

function SkomsArenaStats:GetCharacterRecord()
    local characters = self.db.global.characters
    local key = self.db.keys.char
    local record = characters[key]
    if not record then
        record = {week = {}, teams = {}}
        characters[key] = record
    end

    local _, classToken = _G.UnitClass("player")
    record.name = _G.UnitName("player")
    record.realm = _G.GetRealmName()
    record.class = classToken
    record.level = _G.UnitLevel("player")
    record.lastSeen = _G.time()

    local weekStart = self:GetWeekStart()
    if not SameWeek(record.week.start, weekStart) then
        record.week = {start = weekStart, honorGained = 0}
    end
    return record
end

function SkomsArenaStats:UpdateCharacterSnapshot()
    -- the answer arrives as UPDATE_INSTANCE_INFO
    _G.RequestRaidInfo()
    self:RequestArenaTeams()
    self:UpdateCurrencies()
    self:UpdateArenaTeams()
end

-- The client only gets fresh team stats (weekly games included) when asked;
-- the answer arrives as ARENA_TEAM_ROSTER_UPDATE / ARENA_TEAM_UPDATE
function SkomsArenaStats:RequestArenaTeams()
    for index = 1, (_G.MAX_ARENA_TEAMS or 3) do
        _G.ArenaTeamRoster(index)
    end
end

function SkomsArenaStats:UpdateCurrencies(event)
    local record = self:GetCharacterRecord()
    local honor = _G.GetHonorCurrency() or 0
    local arenaPoints = _G.GetArenaCurrency() or 0

    -- a 0/0 reading while we know better means the currency isn't loaded yet;
    -- a currency event means it is (everything spent)
    if not event and honor == 0 and arenaPoints == 0 and
        ((record.honor or 0) > 0 or (record.arenaPoints or 0) > 0) then
        return
    end

    -- only gains count towards the week; spending just lowers the total
    if record.honor and honor > record.honor then
        record.week.honorGained = record.week.honorGained + honor - record.honor
    end
    record.honor = honor
    record.arenaPoints = arenaPoints

    self:RefreshWeekly()
end

function SkomsArenaStats:UpdateArenaTeams()
    local record = self:GetCharacterRecord()
    local teams = {}
    for index = 1, (_G.MAX_ARENA_TEAMS or 3) do
        local teamName, teamSize, teamRating, weekPlayed, weekWins, _, _,
              playerPlayed, _, _, playerRating = _G.GetArenaTeam(index)
        if teamName and teamSize then
            teams[teamSize] = {
                name = teamName,
                rating = teamRating,
                weekPlayed = weekPlayed,
                weekWins = weekWins,
                playerPlayed = playerPlayed,
                playerRating = playerRating
            }
        end
    end
    -- right after login the team data often isn't there yet; an empty read
    -- then means "not loaded", not "left every team", so keep what we know
    if not next(teams) and next(record.teams or {}) then return end
    record.teams = teams
    record.teamsWeek = record.week.start

    self:RefreshWeekly()
end

-- Results of the arenas recorded for a character since weekStart
function SkomsArenaStats:GetWeeklyArenaResults(charKey, weekStart)
    local results = {games = 0, wins = 0, losses = 0, ratingChange = 0}
    local charData = self.db.sv.char and self.db.sv.char[charKey]
    if not charData or not charData.history then return results end

    for _, row in ipairs(charData.history) do
        if row["endTime"] and row["endTime"] >= weekStart then
            results.games = results.games + 1
            if row["teamColor"] and row["winnerColor"] then
                if row["teamColor"] == row["winnerColor"] then
                    results.wins = results.wins + 1
                else
                    results.losses = results.losses + 1
                end
            end
            if row["isRanked"] then
                results.ratingChange = results.ratingChange +
                                           (row["diffRating"] or 0)
            end
        end
    end
    return results
end

function SkomsArenaStats:GetSortedCharacterKeys()
    local currentKey = self.db.keys.char
    local keys = {}
    for key in pairs(self.db.global.characters) do
        table.insert(keys, key)
    end
    table.sort(keys, function(a, b)
        if a == currentKey then return true end
        if b == currentKey then return false end
        return a < b
    end)
    return keys
end

-- Expected arena points

-- Warmane's SoloQ team ("3vs3 Solo Queue") is shared by everyone queueing, so
-- its team counters are meaningless: only your own games count there
local SOLO_QUEUE_SIZE = 5

-- Your own games needed for a team's share; whole numbers, so 3 of 10 is enough
local function RequiredPlayerGames(week)
    return math.ceil(week * MIN_WEEKLY_SHARE / 100)
end

local function IsEligible(size, team)
    local played = team.playerPlayed or 0
    if size == SOLO_QUEUE_SIZE then return played >= MIN_WEEKLY_GAMES end
    local week = team.weekPlayed or 0
    return week >= MIN_WEEKLY_GAMES and played >= RequiredPlayerGames(week)
end

-- Games still to play (with you in them) before the team pays out
local function GamesNeeded(size, team)
    local week = team.weekPlayed or 0
    local played = team.playerPlayed or 0
    if size == SOLO_QUEUE_SIZE then
        return math.max(MIN_WEEKLY_GAMES - played, 0)
    end
    -- each game you play adds one to both counts
    return math.max(MIN_WEEKLY_GAMES - week, math.ceil(
                        (week * MIN_WEEKLY_SHARE - played * 100) /
                            (100 - MIN_WEEKLY_SHARE)), 0)
end

function SkomsArenaStats:GetTeamArenaPoints(size, team)
    local rating = team.rating or 0
    -- SoloQ always pays on its team rating
    if size ~= SOLO_QUEUE_SIZE and team.playerRating and
        math.abs(team.playerRating - rating) > PERSONAL_RATING_GAP then
        rating = team.playerRating
    end
    rating = math.max(rating, MIN_POINTS_RATING)

    local base = 1511.26 / (1 + 1639.28 * math.exp(-0.00412 * rating))
    return math.floor(base * (BRACKET_MULTIPLIER[size] or 1)) *
               WARMANE_POINTS_RATE
end

-- Points the next weekly reset should award (only the best eligible team
-- pays out), and what the best team would give once it's eligible; both
-- capped by the room left under the arena points cap
function SkomsArenaStats:GetExpectedArenaPoints(record, isCurrentWeek)
    local expected, potential = 0, 0
    for size, team in pairs(record.teams or {}) do
        local points = self:GetTeamArenaPoints(size, team)
        potential = math.max(potential, points)
        if isCurrentWeek and IsEligible(size, team) then
            expected = math.max(expected, points)
        end
    end
    local room = math.max(0, ARENA_POINTS_CAP - (record.arenaPoints or 0))
    return math.min(expected, room), math.min(potential, room)
end

function SkomsArenaStats:ForgetCharacter(key)
    if not key or not self.db.global.characters[key] then return end
    self.db.global.characters[key] = nil
    self:RefreshWeekly()
end

-- Shared cell helpers

local function NumberCell(value)
    return {
        text = tostring(value),
        color = value == 0 and UI.colors.dim or UI.colors.text
    }
end

local function NameCell(record, key)
    return {text = record.name or key, color = {UI.ClassColor(record.class)}}
end

local function WinRate(wins, losses)
    if wins + losses == 0 then return "-" end
    return string.format("%d%%", math.floor(wins * 100 / (wins + losses) + 0.5))
end

local function TimeAgo(timestamp)
    if not timestamp then return "-" end
    local seconds = _G.time() - timestamp
    if seconds < 3600 then
        return string.format(L["%dm ago"], math.floor(seconds / 60))
    elseif seconds < DAY then
        return string.format(L["%dh ago"], math.floor(seconds / 3600))
    end
    return string.format(L["%dd ago"], math.floor(seconds / DAY))
end

function SkomsArenaStats:ShowCharacterTooltip(owner, record, isCurrentWeek)
    local tooltip = _G.GameTooltip
    tooltip:SetOwner(owner, "ANCHOR_RIGHT")
    tooltip:ClearLines()
    tooltip:AddLine(record.name .. " - " .. record.realm, UI.ClassColor(record.class))
    tooltip:AddLine(string.format("%s %s", _G.LEVEL, record.level or "?"), 1, 1, 1)
    tooltip:AddLine(string.format("%s: %s", L["Last seen"],
                                  _G.date("%Y-%m-%d %H:%M", record.lastSeen)),
                    0.7, 0.7, 0.7)
    for _, size in ipairs(BRACKETS) do
        local team = record.teams and record.teams[size]
        if team then
            local line = string.format("%s %s - %d (%s %d)",
                                       UI.BRACKET_LABELS[size] or size,
                                       team.name, team.rating or 0,
                                       L["personal"], team.playerRating or 0)
            -- the shared SoloQ team's W-L isn't yours, so leave it out
            if isCurrentWeek and size ~= SOLO_QUEUE_SIZE then
                line = line ..
                           string.format("  %d-%d", team.weekWins or 0,
                                         (team.weekPlayed or 0) -
                                             (team.weekWins or 0))
            end
            tooltip:AddLine(line, 1, 0.82, 0)

            local points = string.format(L["%d arena points"],
                                         self:GetTeamArenaPoints(size, team))
            if not isCurrentWeek then
                tooltip:AddLine("   " .. points, 0.5, 0.5, 0.55)
            elseif IsEligible(size, team) then
                tooltip:AddLine("   " .. points, 0.25, 0.9, 0.35)
            else
                tooltip:AddLine("   " .. points .. " - " ..
                                    string.format(L["%d more games needed"],
                                                  GamesNeeded(size, team)), 0.5,
                                0.5, 0.55)
            end
        end
    end
    tooltip:Show()
end

-- This Week tab

local WEEK_COLUMNS = {
    {L["Character"], 155}, {L["Games"], 50}, {L["W - L"], 60},
    {L["Win %"], 50}, {L["Rating +/-"], 75}, {L["Honor earned"], 90},
    {L["Expected Points"], 110}, {UI.BRACKET_LABELS[2], 80},
    {UI.BRACKET_LABELS[3], 80}, {UI.BRACKET_LABELS[5], 80}
}

-- your games / the games you need this week: green once the week pays arena
-- points (the team's own count is in the tooltip)
local function WeeklyTeamCell(size, team, isCurrentWeek)
    if not team or not isCurrentWeek then
        return {text = "-", color = UI.colors.dim}
    end
    local played = team.playerPlayed or 0
    local text = string.format("%d/%d", played, played + GamesNeeded(size, team))
    return {
        text = text,
        color = IsEligible(size, team) and UI.colors.good or UI.colors.text
    }
end

-- 0 until a team is eligible; what it would pay is in the tooltip
local function ExpectedPointsCell(expected)
    if expected > 0 then
        return {text = tostring(expected), color = UI.colors.good}
    end
    return {text = "0", color = UI.colors.dim}
end

function SkomsArenaStats:BuildWeekPage(page)
    weekPage = {}

    weekPage.subtitle = UI.CreateText(page, "GameFontHighlightSmall")
    weekPage.subtitle:SetPoint("TOPLEFT", 0, 0)

    weekPage.table = UI.CreateTable(page, "SkomsArenaStatsWeekTable",
                                    WEEK_COLUMNS, UI.CONTENT_HEIGHT - 22)
    weekPage.table.frame:SetPoint("TOPLEFT", 0, -22)
end

function SkomsArenaStats:RefreshWeekPage()
    local weekStart = self:GetWeekStart()
    weekPage.subtitle:SetText(string.format(L["Week of %s"], _G.date(
                                                "%A %Y-%m-%d %H:%M", weekStart)) ..
                                  "  ·  " ..
                                  string.format(L["Arena points paid on %s"],
                                                _G.date("%A %H:%M",
                                                        weekStart + WEEK)))
    self:SetStatusText(self:GetResetStatusText())

    local data = {}
    for _, key in ipairs(self:GetSortedCharacterKeys()) do
        local record = self.db.global.characters[key]
        local isCurrentWeek = record.week and SameWeek(record.week.start, weekStart)
        local honor = isCurrentWeek and record.week.honorGained or 0
        local results = self:GetWeeklyArenaResults(key, weekStart)
        local teamsCurrent = SameWeek(record.teamsWeek, weekStart)
        local expected = self:GetExpectedArenaPoints(record,
                                                                teamsCurrent)

        local cells = {
            NameCell(record, key), NumberCell(results.games),
            {text = string.format("%d - %d", results.wins, results.losses)},
            {text = WinRate(results.wins, results.losses)}, {
                text = UI.SignedNumber(results.ratingChange),
                color = UI.ValueColor(results.ratingChange)
            }, NumberCell(honor), ExpectedPointsCell(expected)
        }
        for _, size in ipairs(BRACKETS) do
            table.insert(cells, WeeklyTeamCell(size, record.teams and
                                                   record.teams[size],
                                               teamsCurrent))
        end
        table.insert(data, {
            cells = cells,
            onEnter = function(row)
                SkomsArenaStats:ShowCharacterTooltip(row, record, teamsCurrent)
            end
        })
    end
    weekPage.table:SetRows(data)
end

-- Characters tab

local CHARACTER_COLUMNS = {
    {L["Character"], 140}, {L["Level"], 50}, {L["Honor"], 160, "bar"},
    {L["Arena Points"], 140, "bar"}, {UI.BRACKET_LABELS[2], 80},
    {UI.BRACKET_LABELS[3], 80}, {UI.BRACKET_LABELS[5], 80},
    {L["Last seen"], 100}
}

-- "team rating (personal rating)"
local function CharacterTeamCell(team)
    if not team then return {text = "-", color = UI.colors.dim} end
    return {
        text = string.format("%d (%d)", team.rating or 0, team.playerRating or 0)
    }
end

local function CurrencyCell(value, cap)
    value = value or 0
    return {
        text = tostring(value),
        value = value,
        max = cap,
        barColor = value >= cap and UI.colors.bad or UI.colors.accent
    }
end

function SkomsArenaStats:BuildCharactersPage(page)
    charactersPage = {}

    charactersPage.table = UI.CreateTable(page, "SkomsArenaStatsCharactersTable",
                                          CHARACTER_COLUMNS, UI.CONTENT_HEIGHT)
    charactersPage.table.frame:SetPoint("TOPLEFT", 0, 0)
end

function SkomsArenaStats:RefreshCharactersPage()
    local weekStart = self:GetWeekStart()
    local currentKey = self.db.keys.char
    self:SetStatusText(self:GetResetStatusText())

    local data = {}
    for _, key in ipairs(self:GetSortedCharacterKeys()) do
        local record = self.db.global.characters[key]
        local teamsCurrent = SameWeek(record.teamsWeek, weekStart)
        local lastSeen = {text = TimeAgo(record.lastSeen), color = UI.colors.dim}
        if key == currentKey then
            lastSeen = {text = L["Online"], color = UI.colors.good}
        end

        local cells = {
            NameCell(record, key), {text = record.level or "?"},
            CurrencyCell(record.honor, HONOR_CAP),
            CurrencyCell(record.arenaPoints, ARENA_POINTS_CAP)
        }
        for _, size in ipairs(BRACKETS) do
            table.insert(cells, CharacterTeamCell(record.teams and
                                                      record.teams[size]))
        end
        table.insert(cells, lastSeen)
        table.insert(data, {
            cells = cells,
            onEnter = function(row)
                SkomsArenaStats:ShowCharacterTooltip(row, record, teamsCurrent)
            end
        })
    end
    charactersPage.table:SetRows(data)
end
