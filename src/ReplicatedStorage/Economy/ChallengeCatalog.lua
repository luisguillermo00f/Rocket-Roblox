--!strict
-- ChallengeCatalog.lua: the daily / weekly challenge types and their deterministic rotation (docs/progression.md §3).
-- Every type reads a stat that already exists (MatchEvents / Soccar / minigame placements). The server normalises each
-- result into a record r before it reaches Value():
--   r = { kind = "match" | "minigame", source, online, ranked, mode, result = "win" | "loss" | "draw",
--         goals, assists, saves, epicSaves, shots, clears, demos, aerials, pinches, points, bestKmh,
--         scoreFor?, scoreAgainst?, streak, placement? }
-- kinds:  sum   -> progress += r[stat]
--         count -> progress += 1 when cond(r)
--         best  -> progress = max(progress, r[stat])      (reach it in a single match)
-- scope:  "match" (any non-training match), "online" (server-run matches only), "minigame" (party rounds)
local DateUtil = require(script.Parent:WaitForChild("DateUtil"))
local Config = require(script.Parent:WaitForChild("EconomyConfig"))

local ChallengeCatalog = {}

export type Def = {
	id: string,
	text: string, -- "{n}" = target
	one: string?, -- text when the target is 1
	cat: string,
	kind: string,
	stat: string?,
	cond: ((any) -> boolean)?,
	scope: string,
	daily: number,
	weekly: number,
	diff: number, -- 1..3 -> reward tier
}

local function isWin(r: any): boolean
	return r.result == "win"
end

local LIST: { Def } = {
	{ id = "goals", text = "MARCA {n} GOLES", cat = "ataque", kind = "sum", stat = "goals", scope = "match", daily = 3, weekly = 15, diff = 2 },
	{ id = "assists", text = "DA {n} ASISTENCIAS", cat = "ataque", kind = "sum", stat = "assists", scope = "match", daily = 2, weekly = 10, diff = 2 },
	{ id = "shots", text = "HAZ {n} TIROS A PUERTA", cat = "ataque", kind = "sum", stat = "shots", scope = "match", daily = 6, weekly = 30, diff = 1 },
	{ id = "hatTrick", text = "MARCA 3 GOLES EN UN PARTIDO ({n} VECES)", one = "MARCA 3 GOLES EN UN PARTIDO", cat = "ataque", kind = "count",
		cond = function(r) return (r.goals or 0) >= 3 end, scope = "match", daily = 1, weekly = 3, diff = 3 },
	{ id = "saves", text = "HAZ {n} ATAJADAS", cat = "defensa", kind = "sum", stat = "saves", scope = "match", daily = 3, weekly = 15, diff = 2 },
	{ id = "epicSaves", text = "HAZ {n} ATAJADAS ÉPICAS", one = "HAZ 1 ATAJADA ÉPICA", cat = "defensa", kind = "sum", stat = "epicSaves", scope = "match", daily = 1, weekly = 5, diff = 3 },
	{ id = "clears", text = "HAZ {n} DESPEJES", cat = "defensa", kind = "sum", stat = "clears", scope = "match", daily = 5, weekly = 25, diff = 1 },
	{ id = "cleanSheet", text = "GANA {n} PARTIDOS SIN RECIBIR GOLES", one = "GANA 1 PARTIDO SIN RECIBIR GOLES", cat = "defensa", kind = "count",
		cond = function(r) return isWin(r) and r.scoreAgainst == 0 end, scope = "match", daily = 1, weekly = 3, diff = 3 },
	{ id = "demos", text = "HAZ {n} DEMOLICIONES", cat = "físico", kind = "sum", stat = "demos", scope = "match", daily = 3, weekly = 15, diff = 2 },
	{ id = "aerials", text = "HAZ {n} GOLPES AÉREOS", cat = "mecánica", kind = "sum", stat = "aerials", scope = "match", daily = 4, weekly = 20, diff = 2 },
	{ id = "pinches", text = "HAZ {n} PINCHES", one = "HAZ 1 PINCH", cat = "mecánica", kind = "sum", stat = "pinches", scope = "match", daily = 1, weekly = 5, diff = 3 },
	{ id = "hardHit", text = "GOLPEA EL BALÓN A {n} KM/H", cat = "mecánica", kind = "best", stat = "bestKmh", scope = "match", daily = 110, weekly = 130, diff = 2 },
	{ id = "points", text = "CONSIGUE {n} PUNTOS", cat = "general", kind = "sum", stat = "points", scope = "match", daily = 1500, weekly = 8000, diff = 1 },
	{ id = "bigGame", text = "CONSIGUE {n} PUNTOS EN UN PARTIDO", cat = "general", kind = "best", stat = "points", scope = "match", daily = 600, weekly = 900, diff = 2 },
	{ id = "play", text = "JUEGA {n} PARTIDOS", cat = "general", kind = "count", cond = function() return true end, scope = "match", daily = 3, weekly = 15, diff = 1 },
	{ id = "wins", text = "GANA {n} PARTIDOS", cat = "victoria", kind = "count", cond = isWin, scope = "match", daily = 2, weekly = 10, diff = 2 },
	{ id = "streak", text = "GANA {n} PARTIDOS SEGUIDOS", cat = "victoria", kind = "best", stat = "streak", scope = "match", daily = 2, weekly = 4, diff = 3 },
	{ id = "wins2v2", text = "GANA {n} PARTIDOS 2V2", one = "GANA 1 PARTIDO 2V2", cat = "victoria", kind = "count",
		cond = function(r) return isWin(r) and r.mode == "2v2" end, scope = "match", daily = 1, weekly = 5, diff = 2 },
	{ id = "onlinePlay", text = "JUEGA {n} PARTIDOS EN LÍNEA", cat = "en línea", kind = "count", cond = function() return true end, scope = "online", daily = 2, weekly = 10, diff = 1 },
	{ id = "onlineWins", text = "GANA {n} PARTIDOS EN LÍNEA", one = "GANA 1 PARTIDO EN LÍNEA", cat = "en línea", kind = "count", cond = isWin, scope = "online", daily = 1, weekly = 5, diff = 2 },
	{ id = "rankedPlay", text = "JUEGA {n} PARTIDOS RANKED", one = "JUEGA 1 PARTIDO RANKED", cat = "en línea", kind = "count",
		cond = function(r) return r.ranked == true end, scope = "online", daily = 1, weekly = 5, diff = 2 },
	{ id = "mgPlay", text = "JUEGA {n} MINIJUEGOS", cat = "minijuegos", kind = "count", cond = function() return true end, scope = "minigame", daily = 3, weekly = 15, diff = 1 },
	{ id = "mgWins", text = "GANA {n} MINIJUEGOS", one = "GANA 1 MINIJUEGO", cat = "minijuegos", kind = "count",
		cond = function(r) return r.placement == 1 end, scope = "minigame", daily = 1, weekly = 6, diff = 2 },
	{ id = "mgPodium", text = "QUEDA ENTRE LOS 2 PRIMEROS EN {n} MINIJUEGOS", cat = "minijuegos", kind = "count",
		cond = function(r) return (r.placement or 99) <= 2 end, scope = "minigame", daily = 2, weekly = 10, diff = 2 },
}

local BY_ID: { [string]: Def } = {}
for _, d in LIST do
	assert(BY_ID[d.id] == nil, "duplicate challenge " .. d.id)
	BY_ID[d.id] = d
end

ChallengeCatalog.List = LIST

function ChallengeCatalog.Get(id: any): Def?
	return if type(id) == "string" then BY_ID[id] else nil
end

-- periodKind: "daily" | "weekly"
function ChallengeCatalog.Target(def: Def, periodKind: string): number
	return if periodKind == "weekly" then def.weekly else def.daily
end

function ChallengeCatalog.Text(def: Def, periodKind: string): string
	local n = ChallengeCatalog.Target(def, periodKind)
	if n == 1 and def.one then return def.one end
	local s = string.gsub(def.text, "{n}", tostring(n))
	return s
end

function ChallengeCatalog.Reward(def: Def, periodKind: string): { credits: number, xp: number }
	local tiers = Config.CHALLENGE_REWARDS[periodKind] or Config.CHALLENGE_REWARDS.daily
	return tiers[math.clamp(def.diff, 1, #tiers)]
end

-- a challenge whose scope is not "match" can't be completed by someone who only plays offline
function ChallengeCatalog.IsSpecial(def: Def): boolean
	return def.scope ~= "match"
end

function ChallengeCatalog.InScope(def: Def, r: any): boolean
	if def.scope == "minigame" then return r.kind == "minigame" end
	if r.kind ~= "match" then return false end
	if def.scope == "online" then return r.online == true end
	return true
end

-- amount this result contributes (sum / count) or reaches (best); 0 when it doesn't apply
function ChallengeCatalog.Value(def: Def, r: any): number
	if not ChallengeCatalog.InScope(def, r) then return 0 end
	if def.kind == "count" then
		return if def.cond and def.cond(r) then 1 else 0
	end
	local v = def.stat and r[def.stat]
	if type(v) ~= "number" or v ~= v then return 0 end
	return math.max(0, math.floor(v))
end

-- The ids for a period (day index for "daily", week index for "weekly"): same inputs -> same list, on any server.
-- 3 distinct types, all from different categories, and at most ONE that isn't playable offline (online / minigame),
-- so a player who only plays against bots can always finish at least 2 of the 3.
function ChallengeCatalog.Rotation(period: number, periodKind: string): { string }
	local count = if periodKind == "weekly" then Config.WEEKLY_COUNT else Config.DAILY_COUNT
	local rng = DateUtil.Rng(DateUtil.Hash(period, periodKind, "challenges"))
	local order = DateUtil.Shuffled(LIST, rng)
	local out, cats, special = {}, {}, 0
	for _, d in order do
		if #out >= count then break end
		local isSpecial = ChallengeCatalog.IsSpecial(d)
		if not cats[d.cat] and not (isSpecial and special >= 1) then
			table.insert(out, d.id)
			cats[d.cat] = true
			if isSpecial then special += 1 end
		end
	end
	return out
end

return ChallengeCatalog
