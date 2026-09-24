--!strict
-- Progression.lua: XP -> level, and the reward formulas (docs/progression.md). Shared: the SERVER
-- (ServerScriptService.Economy.Rewards) decides every XP / credit; the client only uses this for estimates.
-- Level n -> n+1 costs 250 + 100*(n-1) XP (250, 350, 450, ...), so reaching level L takes 50*(L-1)*(L+3) XP in total.
local Config = require(script.Parent.Parent:WaitForChild("Economy"):WaitForChild("EconomyConfig"))

local Progression = {}

local MAX_XP = 1e12

function Progression.Cost(level: number): number
	return 250 + 100 * (level - 1)
end

-- total XP needed to reach `level` from 0
function Progression.TotalFor(level: number): number
	return 50 * (level - 1) * (level + 3)
end

-- returns level, xp into the current level, xp needed for the next one. Closed form (a profile with 500k XP would
-- loop hundreds of times); the +-1 fix-up absorbs floating point error in the square root.
function Progression.FromXp(xp: number): (number, number, number)
	if type(xp) ~= "number" or xp ~= xp or xp < 0 then xp = 0 end
	xp = math.min(xp, MAX_XP)
	local level = math.max(1, math.floor(-1 + math.sqrt(4 + xp / 50)))
	while level > 1 and Progression.TotalFor(level) > xp do
		level -= 1
	end
	while Progression.TotalFor(level + 1) <= xp do
		level += 1
	end
	return level, xp - Progression.TotalFor(level), Progression.Cost(level)
end

local function sourceMult(source: string?, key: string): number
	local s = Config.SOURCES[source or "online_pvp"]
	return if s then (s :: any)[key] else 1
end

-- XP for a finished match. source: see EconomyConfig.SOURCES (the estimate on the client assumes online_pvp).
function Progression.MatchXp(points: number, result: string, source: string?): number
	local c = Config.MATCH_XP
	local pts = math.clamp(math.floor(tonumber(points) or 0), 0, c.pointsCap)
	local res = if result == "win" then c.win elseif result == "draw" then c.draw else c.loss
	return math.floor((c.base + res + pts) * sourceMult(source, "xp"))
end

function Progression.MatchCredits(points: number, result: string, source: string?): number
	local c = Config.MATCH_CREDITS
	local bonus = math.clamp(math.floor((tonumber(points) or 0) / c.perPoints), 0, c.pointsBonusCap)
	local res = if result == "win" then c.win elseif result == "draw" then c.draw else c.loss
	return math.floor((c.base + res + bonus) * sourceMult(source, "credits"))
end

-- minigame round by placement (1 = first)
function Progression.MinigameXp(placement: number, source: string?): number
	local c = Config.MINIGAME_XP
	local by = c.byPlacement[math.clamp(math.floor(placement), 1, #c.byPlacement)]
	return math.floor((c.base + by) * sourceMult(source, "xp"))
end

function Progression.MinigameCredits(placement: number, source: string?): number
	local list = Config.MINIGAME_CREDITS
	return math.floor(list[math.clamp(math.floor(placement), 1, #list)] * sourceMult(source, "credits"))
end

-- credits for REACHING `level`
function Progression.LevelCredits(level: number): number
	return Config.LEVEL_CREDITS.base + Config.LEVEL_CREDITS.per5 * math.floor(level / 5)
end

return Progression
