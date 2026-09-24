--!strict
-- Challenges.lua (server, pure): the player's daily / weekly challenge lists and their progress.
-- Lists come from ChallengeCatalog.Rotation(period); a list whose period isn't the current one is replaced (progress
-- that wasn't finished is lost, like in RL). A challenge pays out the moment it's completed (no claim button).
local RS = game:GetService("ReplicatedStorage")
local Economy = RS:WaitForChild("Economy")
local Catalog = require(Economy:WaitForChild("ChallengeCatalog"))
local DateUtil = require(Economy:WaitForChild("DateUtil"))

local Challenges = {}

local KINDS = { "daily", "weekly" }

local function periodOf(kind: string, now: number): number
	return if kind == "weekly" then DateUtil.WeekIndex(now) else DateUtil.DayIndex(now)
end

-- make sure both lists belong to the current period. Returns true when something was regenerated.
function Challenges.Ensure(profile: any, now: number): boolean
	local changed = false
	for _, kind in KINDS do
		local period = periodOf(kind, now)
		local slot = profile.challenges[kind]
		if slot.period ~= period then
			local list = {}
			for _, id in Catalog.Rotation(period, kind) do
				table.insert(list, { id = id, progress = 0, done = false })
			end
			profile.challenges[kind] = { period = period, list = list }
			changed = true
		end
	end
	return changed
end

export type Completion = { kind: string, id: string, text: string, credits: number, xp: number, scope: string }

-- r: normalised result record (see ChallengeCatalog). Returns the challenges completed by this result and whether
-- this result finished the LAST weekly one (all weeklies done).
function Challenges.Apply(profile: any, r: any, now: number): ({ Completion }, boolean)
	Challenges.Ensure(profile, now)
	local out: { Completion } = {}
	local weeklyNow = false
	for _, kind in KINDS do
		for _, e in profile.challenges[kind].list do
			local def = Catalog.Get(e.id)
			if def and not e.done then
				local v = Catalog.Value(def, r)
				if v > 0 then
					local target = Catalog.Target(def, kind)
					if def.kind == "best" then
						e.progress = math.max(e.progress, v)
					else
						e.progress += v
					end
					if e.progress >= target then
						e.progress = target
						e.done = true
						local rw = Catalog.Reward(def, kind)
						table.insert(out, { kind = kind, id = e.id, text = Catalog.Text(def, kind), credits = rw.credits, xp = rw.xp, scope = def.scope })
						if kind == "weekly" then weeklyNow = true end
					end
				end
			end
		end
	end
	local allWeekly = weeklyNow
	if allWeekly then
		for _, e in profile.challenges.weekly.list do
			if not e.done then allWeekly = false end
		end
	end
	return out, allWeekly
end

-- what the client shows (texts resolved here so the UI never has to know the catalog rules)
function Challenges.View(profile: any, now: number): any
	local out = {}
	for _, kind in KINDS do
		local items = {}
		for _, e in profile.challenges[kind].list do
			local def = Catalog.Get(e.id)
			if def then
				local rw = Catalog.Reward(def, kind)
				table.insert(items, {
					id = e.id, text = Catalog.Text(def, kind), cat = def.cat, scope = def.scope,
					progress = e.progress, target = Catalog.Target(def, kind), done = e.done,
					credits = rw.credits, xp = rw.xp,
				})
			end
		end
		out[kind] = {
			items = items,
			resetIn = if kind == "weekly" then DateUtil.SecondsToNextWeek(now) else DateUtil.SecondsToNextDay(now),
		}
	end
	return out
end

return Challenges
