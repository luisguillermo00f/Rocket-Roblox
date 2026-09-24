--!strict
-- Progression.lua: XP -> level. Level n -> n+1 costs 250 + 100*(n-1) XP (250, 350, 450, ...).
-- XP per match (server side): points earned + 30 for playing + 100 for a win.
local Progression = {}

function Progression.Cost(level: number): number
	return 250 + 100 * (level - 1)
end

-- returns level, xp into the current level, xp needed for the next one
function Progression.FromXp(xp: number): (number, number, number)
	local level, left = 1, math.max(0, xp)
	while left >= Progression.Cost(level) do
		left -= Progression.Cost(level)
		level += 1
	end
	return level, left, Progression.Cost(level)
end

function Progression.MatchXp(points: number, result: string): number
	return math.max(0, math.floor(points)) + 30 + (if result == "win" then 100 else 0)
end

return Progression
