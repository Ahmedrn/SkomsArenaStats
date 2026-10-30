local addonName, ns = ...
local addonNotes = select(3, GetAddOnInfo(addonName))
local SkomsArenaStats = LibStub("AceAddon-3.0"):GetAddon(addonName)
local L = LibStub("AceLocale-3.0"):GetLocale(addonName, true)
local AceConfig = LibStub("AceConfig-3.0")
local AceDBOptions = LibStub("AceDBOptions-3.0")
local AceConfigDialog = LibStub("AceConfigDialog-3.0")
local TITLE = "Skom's Arena Stats"   -- name in Interface > AddOns

function SkomsArenaStats:OpenOptions()
    -- the first call only opens the frame in 3.3.5a, the second selects the panel
    _G.InterfaceOptionsFrame_OpenToCategory(TITLE)
    _G.InterfaceOptionsFrame_OpenToCategory(TITLE)
end

function SkomsArenaStats:RegisterOptionsTable()
    AceConfig:RegisterOptionsTable(addonName, {
        name = TITLE,
        descStyle = "inline",
        handler = SkomsArenaStats,
        type = "group",
        args = {
            General = {
                order = 1,
                type = "group",
                name = L["General"],
                args = {
                    intro = {order = 0, type = "description", name = addonNotes},
                    group1 = {
                        order = 10,
                        type = "group",
                        name = L["Database Settings"],
                        inline = true,
                        args = {
                            maxHistory = {
                                order = 11,
                                type = "range",
                                name = L["Maximum history records"],
                                desc = L["The oldest arenas are removed past this number (0 keeps them all)"],
                                min = 0,
                                max = 1000,
                                step = 10,
                                get = function()
                                    return self.db.profile.maxHistory
                                end,
                                set = function(_, val)
                                    self.db.profile.maxHistory = val
                                end
                            },
                            purge = {
                                order = 19,
                                type = "execute",
                                name = L["Purge database"],
                                desc = L["Delete all collected data"],
                                confirm = true,
                                func = function()
                                    self:ResetDatabase()
                                end
                            },
                            restore = {
                                order = 20,
                                type = "execute",
                                name = L["Restore purged data"],
                                desc = L["Bring back the data deleted by the last purge (reloads the UI)"],
                                confirm = true,
                                disabled = function()
                                    return not self:HasPurgeBackup()
                                end,
                                func = function()
                                    self:RestorePurgedData()
                                end
                            }
                        }
                    },
                    group2 = {
                        order = 20,
                        type = "group",
                        name = L["Minimap Button Settings"],
                        inline = true,
                        args = {
                            minimapButton = {
                                order = 21,
                                type = "toggle",
                                name = L["Show minimap button"],
                                get = function()
                                    return
                                        not self.db.profile.minimapButton.hide
                                end,
                                set = 'ToggleMinimapButton'
                            }
                        }
                    },
                    group3 = {
                        order = 30,
                        type = "group",
                        name = L["Interface Settings"],
                        inline = true,
                        args = {
                            characterNamesOnHover = {
                                order = 31,
                                type = "toggle",
                                name = L["Show character names on hover"],
                                get = function()
                                    return not self.db.profile
                                               .characterNamesOnHover.hide
                                end,
                                set = function()
                                    self.db.profile.characterNamesOnHover.hide =
                                        not self.db.profile
                                            .characterNamesOnHover.hide
                                end
                            }
                        }
                    },
                    group4 = {
                        order = 40,
                        type = "group",
                        name = L["Weekly Summary Settings"],
                        inline = true,
                        args = {
                            note = {
                                order = 40,
                                type = "description",
                                name = L["Honor and arena points gained are only counted while the addon is enabled on that character."]
                            },
                            resetSource = {
                                order = 40.5,
                                type = "description",
                                name = function()
                                    return "\n" .. self:GetResetStatusText() ..
                                               "\n" ..
                                               L["A raid lockout on any character gives the exact reset time and overrides the options below."]
                                end
                            },
                            clearDetected = {
                                order = 40.6,
                                type = "execute",
                                name = L["Clear detected reset"],
                                desc = L["Forget the reset time learned from a raid lockout"],
                                disabled = function()
                                    return not self.db.global.detectedReset
                                end,
                                func = function()
                                    self:ClearDetectedReset()
                                end
                            },
                            resetDay = {
                                order = 41,
                                type = "select",
                                name = L["Weekly reset day"],
                                desc = L["Local time at which the arena week resets"],
                                values = {
                                    [1] = _G.WEEKDAY_SUNDAY or "Sunday",
                                    [2] = _G.WEEKDAY_MONDAY or "Monday",
                                    [3] = _G.WEEKDAY_TUESDAY or "Tuesday",
                                    [4] = _G.WEEKDAY_WEDNESDAY or "Wednesday",
                                    [5] = _G.WEEKDAY_THURSDAY or "Thursday",
                                    [6] = _G.WEEKDAY_FRIDAY or "Friday",
                                    [7] = _G.WEEKDAY_SATURDAY or "Saturday"
                                },
                                get = function()
                                    return self.db.global.weeklyReset.day
                                end,
                                set = function(_, val)
                                    self.db.global.weeklyReset.day = val
                                    self:RefreshWeekly()
                                end
                            },
                            autoHour = {
                                order = 41.5,
                                type = "toggle",
                                name = L["Use the daily quest reset hour"],
                                desc = L["The weekly reset happens at the same hour as the daily quest reset"],
                                get = function()
                                    return self.db.global.weeklyReset.autoHour
                                end,
                                set = function(_, val)
                                    self.db.global.weeklyReset.autoHour = val
                                    self:RefreshWeekly()
                                end
                            },
                            resetHour = {
                                order = 42,
                                type = "range",
                                name = L["Weekly reset hour"],
                                desc = L["Local time at which the arena week resets"],
                                disabled = function()
                                    return self.db.global.weeklyReset.autoHour
                                end,
                                min = 0,
                                max = 23,
                                step = 1,
                                get = function()
                                    return self.db.global.weeklyReset.hour
                                end,
                                set = function(_, val)
                                    self.db.global.weeklyReset.hour = val
                                    self:RefreshWeekly()
                                end
                            },
                            forget = {
                                order = 43,
                                type = "select",
                                name = L["Forget character"],
                                desc = L["Remove a deleted or unused character from the weekly summary"],
                                confirm = true,
                                values = function()
                                    local values = {}
                                    for _, key in ipairs(
                                                      self:GetSortedCharacterKeys()) do
                                        values[key] = key
                                    end
                                    return values
                                end,
                                get = function() return nil end,
                                set = function(_, key)
                                    self:ForgetCharacter(key)
                                end
                            }
                        }
                    }
                }
            },
            Profiles = AceDBOptions:GetOptionsTable(SkomsArenaStats.db),
            About = ns.AboutGroup(99)
        }
    })
    AceConfigDialog:AddToBlizOptions(addonName, TITLE, nil, "General")
    AceConfigDialog:AddToBlizOptions(addonName, "Profiles", TITLE,
                                     "Profiles")
    AceConfigDialog:AddToBlizOptions(addonName, "About", TITLE, "About")
end
