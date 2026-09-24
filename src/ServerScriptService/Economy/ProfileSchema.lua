--!strict
-- ProfileSchema.lua: the saved profile's shape, its defaults and the chain of migrations (docs/progression.md §5).
-- Pure (no DataStore, no Players): ProfileService loads the raw table and passes it through Migrate().
-- Rules:
--   * every stored key is kept, unknown ones included (a newer version's fields survive an older server);
--   * a migration step only ADDS fields with their defaults, it never removes or lowers anything;
--   * corrupt values (NaN, strings, negatives) fall back to their default;
--   * a profile written by a newer schema than this code understands loads read-only (never saved back).
local RS = game:GetService("ReplicatedStorage")
local Progression = require(RS:WaitForChild("Game"):WaitForChild("Progression"))
local Config = require(RS:WaitForChild("Economy"):WaitForChild("EconomyConfig"))
local CosmeticCatalog = require(RS:WaitForChild("Economy"):WaitForChild("CosmeticCatalog"))
local Inventory = require(script.Parent:WaitForChild("Inventory"))
local LootboxConfig = require(RS:WaitForChild("Economy"):WaitForChild("LootboxConfig"))

local ProfileSchema = {}

ProfileSchema.VERSION = 4

-- flat numbers (v1 career stats + v2 economy); all >= 0
local STATS: { [string]: number } = {
	-- v1
	matches = 0, wins = 0, losses = 0, draws = 0,
	goals = 0, assists = 0, saves = 0, epicSaves = 0, shots = 0, clears = 0, demos = 0, aerials = 0,
	points = 0, xp = 0, bestKmh = 0, streak = 0, bestStreak = 0, pinches = 0, bestPinchKmh = 0,
	-- v2
	credits = 0, creditsEarned = 0, rewardedLevel = 1, minigames = 0, minigameWins = 0,
	-- v3
	weeklyPrize = 0, -- week whose weekly prize was already given
	-- v4
	boxesOpened = 0,
}
ProfileSchema.STATS = STATS

-- counters of the current UTC day (Rewards.EnsureDay resets them)
local ECON: { [string]: number } = { day = -1, earned = 0, localCredits = 0, localXp = 0, lastLocal = 0, firstWinDay = -1, drops = 0, boxBuys = 0 }
ProfileSchema.ECON = ECON

local function goodNum(v: any): boolean
	return type(v) == "number" and v == v and v >= 0 and v < 1e15
end
ProfileSchema.GoodNum = goodNum

local function deepCopy(v: any, depth: number): any
	if type(v) ~= "table" or depth > 24 then return v end
	local out = {}
	for k, x in v do
		out[k] = deepCopy(x, depth + 1)
	end
	return out
end
ProfileSchema.DeepCopy = function(v: any): any return deepCopy(v, 0) end

local function emptyChallenges(): any
	return { daily = { period = -1, list = {} }, weekly = { period = -1, list = {} } }
end

function ProfileSchema.Defaults(): { [string]: any }
	local d: { [string]: any } = {}
	for k, v in STATS do d[k] = v end
	d.schema = ProfileSchema.VERSION
	d.econ = table.clone(ECON)
	d.challenges = emptyChallenges()
	d.owned = {}
	d.equipped = CosmeticCatalog.Defaults()
	d.boxes, d.pity, d.fragments, d.boxHistory, d.boxRequests, d.dupMode = {}, {}, {}, {}, {}, "fragments"
	return d
end

local function validChallengeSlot(s: any): boolean
	if type(s) ~= "table" or type(s.period) ~= "number" or type(s.list) ~= "table" then return false end
	for _, e in s.list do
		if type(e) ~= "table" or type(e.id) ~= "string" or not goodNum(e.progress) or type(e.done) ~= "boolean" then return false end
	end
	return true
end

-- fill missing / repair corrupt values of every field this version knows (unknown keys are left alone)
local function fill(d: { [string]: any })
	for k, v in STATS do
		if not goodNum(d[k]) then d[k] = v end
	end
	if d.rewardedLevel < 1 then d.rewardedLevel = 1 end
	if type(d.econ) ~= "table" then d.econ = {} end
	for k, v in ECON do
		local x = d.econ[k]
		if type(x) ~= "number" or x ~= x then d.econ[k] = v end
	end
	if type(d.challenges) ~= "table" then d.challenges = emptyChallenges() end
	for _, kind in { "daily", "weekly" } do
		if not validChallengeSlot(d.challenges[kind]) then d.challenges[kind] = { period = -1, list = {} } end
	end
	if d.settings ~= nil and type(d.settings) ~= "table" then d.settings = nil end
	-- v3: owned = { [id] = time } (unknown ids are kept: an item may come back), equipped = { [slot] = id }
	if type(d.owned) ~= "table" then d.owned = {} end
	for k, v in d.owned do
		if type(k) ~= "string" or type(v) ~= "number" then d.owned[k] = nil end
	end
	local defaults = CosmeticCatalog.Defaults()
	if type(d.equipped) ~= "table" then d.equipped = {} end
	for k, v in d.equipped do
		if type(k) ~= "string" or type(v) ~= "string" then d.equipped[k] = nil end
	end
	for slot, id in defaults do
		if d.equipped[slot] == nil then d.equipped[slot] = id end
	end
	-- v4: boxes / fragments = { [boxId] = n }, pity = { [boxId] = { epic, legendary } }, history + answered requests
	for _, k in { "boxes", "fragments" } do
		if type(d[k]) ~= "table" then d[k] = {} end
		for id, n in d[k] do
			if type(id) ~= "string" or not goodNum(n) then d[k][id] = nil end
		end
	end
	if type(d.pity) ~= "table" then d.pity = {} end
	for id, pt in d.pity do
		if type(id) ~= "string" or type(pt) ~= "table" or not goodNum(pt.epic) or not goodNum(pt.legendary) then d.pity[id] = nil end
	end
	for _, k in { "boxHistory", "boxRequests" } do
		if type(d[k]) ~= "table" then d[k] = {} end
	end
	while #d.boxHistory > LootboxConfig.HISTORY_SIZE do table.remove(d.boxHistory, 1) end
	while #d.boxRequests > LootboxConfig.REQUEST_MEMORY do table.remove(d.boxRequests, 1) end
	if d.dupMode ~= "fragments" and d.dupMode ~= "credits" then d.dupMode = "fragments" end
end

-- MIGRATIONS[v] turns a vN profile into v(N+1). info collects what happened (for logs / the client).
local MIGRATIONS: { [number]: (any, any) -> () } = {}

-- v1 -> v2: credits and challenges. Existing players get a one-time bonus for the levels they already reached
-- (their level-up credits start counting from the current level).
MIGRATIONS[1] = function(d: any, info: any)
	local level = Progression.FromXp(if goodNum(d.xp) then d.xp else 0)
	local bonus = math.min(Config.WELCOME_BONUS.max, Config.WELCOME_BONUS.perLevel * (level - 1))
	d.credits = bonus
	d.creditsEarned = bonus
	d.rewardedLevel = level
	d.welcomeBonus = bonus
	d.econ = table.clone(ECON)
	d.challenges = emptyChallenges()
	info.welcomeBonus = bonus
end

-- v2 -> v3: cosmetics. Everything from the level rewards the player already reached is given now (nobody loses
-- what they had earned); everyone starts with the default loadout.
MIGRATIONS[2] = function(d: any, info: any)
	d.owned = if type(d.owned) == "table" then d.owned else {}
	d.equipped = CosmeticCatalog.Defaults()
	d.weeklyPrize = 0
	local level = Progression.FromXp(if goodNum(d.xp) then d.xp else 0)
	Inventory.GrantLevelItemsUpTo(d, level, 0)
	info.levelItems = level
end

-- v3 -> v4: lootboxes. Levels already reached give their standard boxes (one per 5 levels), at most
-- RETRO_LEVEL_BOXES_MAX; pity starts at 0.
MIGRATIONS[3] = function(d: any, info: any)
	local level = Progression.FromXp(if goodNum(d.xp) then d.xp else 0)
	local retro = math.min(LootboxConfig.RETRO_LEVEL_BOXES_MAX, level // LootboxConfig.LEVEL_BOX_EVERY)
	d.boxes = { standard = retro }
	d.pity, d.fragments, d.boxHistory, d.boxRequests, d.dupMode = {}, {}, {}, {}, "fragments"
	info.retroBoxes = retro
end

ProfileSchema.MIGRATIONS = MIGRATIONS

export type Info = { from: number, fresh: boolean, readOnly: boolean, welcomeBonus: number?, levelItems: number?, retroBoxes: number? }

-- raw: whatever the DataStore returned (nil for a new player). Returns a fresh table (raw is never modified).
function ProfileSchema.Migrate(raw: any): ({ [string]: any }, Info)
	local info: Info = { from = 0, fresh = false, readOnly = false }
	if type(raw) ~= "table" then
		info.fresh = true
		info.from = ProfileSchema.VERSION
		return ProfileSchema.Defaults(), info
	end
	local d = deepCopy(raw, 0)
	d._lock = nil -- session lock lives in the store record only
	local v: number = tonumber(d.schema) or 1
	if v ~= v or v < 1 then v = 1 end
	v = math.floor(v)
	info.from = v
	-- v1 stats first, so a migration reads clean numbers
	for k in STATS do
		if d[k] ~= nil and not goodNum(d[k]) then d[k] = nil end
	end
	if v > ProfileSchema.VERSION then
		info.readOnly = true
		fill(d)
		return d, info
	end
	while v < ProfileSchema.VERSION do
		local step = MIGRATIONS[v]
		if step then step(d, info) end
		v += 1
	end
	d.schema = ProfileSchema.VERSION
	fill(d)
	return d, info
end

return ProfileSchema
