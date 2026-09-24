--!strict
-- MinigameScore.lua: per-member and per-team scores + stats for one round, and a generic placement builder.
-- Placements are what a minigame returns; PartyServer turns them into Party Points (the minigame never does).
local MinigameScore = {}
MinigameScore.__index = MinigameScore

function MinigameScore.new()
	return setmetatable({ members = {}, teams = {} }, MinigameScore)
end

function MinigameScore.Member(self: any, id: string): any
	local m = self.members[id]
	if not m then
		m = { score = 0, stats = {} }
		self.members[id] = m
	end
	return m
end

function MinigameScore.Add(self: any, id: string, n: number)
	local m = MinigameScore.Member(self, id)
	m.score += n
end

function MinigameScore.Get(self: any, id: string): number
	local m = self.members[id]
	return if m then m.score else 0
end

function MinigameScore.Stat(self: any, id: string, key: string, delta: number)
	local m = MinigameScore.Member(self, id)
	m.stats[key] = (m.stats[key] or 0) + delta
end

function MinigameScore.TeamAdd(self: any, team: number, n: number)
	self.teams[team] = (self.teams[team] or 0) + n
end

function MinigameScore.TeamGet(self: any, team: number): number
	return self.teams[team] or 0
end

-- entries: { { id, keys = { primary, secondary, ... } } } higher is better. Equal keys share a placement.
-- returns { { id, placement } } sorted by placement
function MinigameScore.Rank(entries: { any }): { any }
	table.sort(entries, function(a, b)
		for i = 1, math.max(#a.keys, #b.keys) do
			local x, y = a.keys[i] or 0, b.keys[i] or 0
			if x ~= y then return x > y end
		end
		return tostring(a.id) < tostring(b.id)
	end)
	local out = {}
	local place = 0
	for i, e in entries do
		local same = i > 1
		if same then
			local prev = entries[i - 1]
			for k = 1, math.max(#e.keys, #prev.keys) do
				if (e.keys[k] or 0) ~= (prev.keys[k] or 0) then same = false break end
			end
		end
		if not same then place = i end
		table.insert(out, { id = e.id, placement = place })
	end
	return out
end

return MinigameScore
