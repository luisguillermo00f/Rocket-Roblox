--!strict
-- LootboxData.lua: the box types, their loot tables and EXACT odds (docs/lootboxes.md §3-§4). Shared: the UI shows
-- these numbers before anything is opened or bought, and the server rolls with these same numbers - the client sends
-- OddsVersion(box) with every request and the server refuses a request made against different odds.
--   odds are in basis points (1/100 of a percent) so they add up to exactly 10000 = 100 %
--   P(item) = P(rarity) * weight / (sum of weights of that rarity in that box)
--   pity: at most `epic` - 1 boxes in a row without Épica or better, at most `legendary` - 1 without Legendaria or
--         better (the Nth box is forced into that tier, the tier's own odds renormalised)
local DateUtil = require(script.Parent:WaitForChild("DateUtil"))
local Catalog = require(script.Parent:WaitForChild("CosmeticCatalog"))
local Config = require(script.Parent:WaitForChild("LootboxConfig"))

local LootboxData = {}

LootboxData.RARITIES = { "common", "rare", "epic", "legendary", "exotic" }
local ORDER = { common = 1, rare = 2, epic = 3, legendary = 4, exotic = 5 }
LootboxData.ORDER = ORDER

export type Entry = { id: string, w: number }
export type Box = {
	id: string, name: string, description: string, color: Color3, price: number, season: boolean?,
	odds: { [string]: number }, -- basis points per rarity (sum 10000)
	pity: { epic: number, legendary: number },
	convertFragments: number, -- restricted "fragments" mode: fixed fragments per box
	items: { [string]: { Entry } },
}

local function shopItems(rarity: string, w: number): { Entry }
	local out = {}
	for _, it in Catalog.Items do
		if it.price and it.rarity == rarity then table.insert(out, { id = it.id, w = w }) end
	end
	table.sort(out, function(a, b) return a.id < b.id end)
	return out
end

local function list(w: number, ids: { string }): { Entry }
	local out = {}
	for _, id in ids do table.insert(out, { id = id, w = w }) end
	return out
end

local function concat(a: { Entry }, b: { Entry }): { Entry }
	local out = table.clone(a)
	for _, e in b do table.insert(out, e) end
	return out
end

local BOXES: { [string]: Box } = {
	standard = {
		id = "standard", name = "CAJA ESTÁNDAR", color = Color3.fromRGB(70, 150, 255), price = 450,
		description = "OBJETOS DE LA TIENDA Y 3 EXÓTICOS EXCLUSIVOS",
		odds = { common = 6000, rare = 2700, epic = 1000, legendary = 250, exotic = 50 },
		pity = { epic = 10, legendary = 40 },
		convertFragments = 60,
		items = {
			common = shopItems("common", 1), rare = shopItems("rare", 1), epic = shopItems("epic", 1), legendary = shopItems("legendary", 1),
			exotic = list(1, { "boost_comet", "goal_galaxy", "primary_forcefield" }),
		},
	},
	season1 = {
		id = "season1", name = "CAJA DE TEMPORADA", color = Color3.fromRGB(0, 200, 180), price = 650, season = true,
		description = Config.SEASON.name .. " · OBJETOS EXCLUSIVOS DE LA TEMPORADA",
		odds = { common = 4500, rare = 3200, epic = 1600, legendary = 500, exotic = 200 },
		pity = { epic = 8, legendary = 30 },
		convertFragments = 80,
		items = {
			common = concat(list(2, { "secondary_nitro", "frame_nitro", "title_season1" }), list(1, { "secondary_black", "wheels_black", "boost_vapor", "frame_white" })),
			rare = concat(list(2, { "primary_carbonfiber", "boost_nitro", "wheels_nitro" }), list(1, { "secondary_cyan", "boost_sparks", "frame_blue" })),
			epic = concat(list(2, { "goal_nitro", "title_supersonic" }), list(1, { "boost_plasma", "wheels_gold" })),
			legendary = list(1, { "boost_hyperdrive", "primary_iridescent" }),
			exotic = list(1, { "wheels_hologram", "frame_aurora" }),
		},
	},
	minigames = {
		id = "minigames", name = "CAJA DE MINIJUEGOS", color = Color3.fromRGB(255, 110, 190), price = 350,
		description = "OBJETOS DE FIESTA · SE GANA SOBRE TODO JUGANDO MINIJUEGOS",
		odds = { common = 5500, rare = 3000, epic = 1100, legendary = 350, exotic = 50 },
		pity = { epic = 10, legendary = 40 },
		convertFragments = 50,
		items = {
			common = concat(list(2, { "title_partygoer", "secondary_bubblegum", "frame_confetti" }), list(1, { "frame_white", "secondary_yellow", "goal_shockwave" })),
			rare = concat(list(2, { "boost_bubbles", "wheels_candy" }), list(1, { "goal_confetti", "title_wrecker" })),
			epic = concat(list(2, { "goal_pinata", "title_partychamp" }), list(1, { "goal_fireworks" })),
			legendary = list(1, { "boost_disco", "frame_crown" }),
			exotic = list(1, { "goal_partyblast" }),
		},
	},
}
LootboxData.BOX_ORDER = { "standard", "season1", "minigames" }

function LootboxData.Get(id: any): Box?
	return if type(id) == "string" then BOXES[id] else nil
end

function LootboxData.All(): { Box }
	local out = {}
	for _, id in LootboxData.BOX_ORDER do table.insert(out, BOXES[id]) end
	return out
end

function LootboxData.SeasonActive(now: number): boolean
	return now >= Config.SEASON.startsAt and now < Config.SEASON.endsAt
end

-- a season box can be bought / earned only while its season runs (boxes already owned always open)
function LootboxData.Available(box: Box, now: number): boolean
	return not box.season or LootboxData.SeasonActive(now)
end

local function weightSum(entries: { Entry }): number
	local s = 0
	for _, e in entries do s += e.w end
	return s
end

-- { rarity -> probability 0..1 } per opening (no pity active)
function LootboxData.RarityOdds(box: Box): { [string]: number }
	local out = {}
	for r, bp in box.odds do out[r] = bp / 10000 end
	return out
end

-- every item with its exact probability 0..1 (sorted by rarity desc, then id)
function LootboxData.ItemOdds(box: Box): { { id: string, rarity: string, p: number } }
	local out = {}
	for _, r in LootboxData.RARITIES do
		local entries: { Entry } = box.items[r] or {}
		local total = weightSum(entries)
		for _, e in entries do
			table.insert(out, { id = e.id, rarity = r, p = (box.odds[r] or 0) / 10000 * e.w / total })
		end
	end
	table.sort(out, function(a, b)
		if ORDER[a.rarity] ~= ORDER[b.rarity] then return ORDER[a.rarity] > ORDER[b.rarity] end
		return a.id < b.id
	end)
	return out
end

-- which item a box would give for a rarity (fragments list, restricted mode)
function LootboxData.Contains(box: Box, id: string): string?
	for r, entries in box.items do
		for _, e in entries do
			if e.id == id then return r end
		end
	end
	return nil
end

-- the rarities a roll may land on with a minimum tier (1 = any), and their renormalised probabilities
function LootboxData.TierOdds(box: Box, minOrder: number): { [string]: number }
	local total = 0
	for r, bp in box.odds do
		if ORDER[r] >= minOrder then total += bp end
	end
	local out = {}
	for r, bp in box.odds do
		if ORDER[r] >= minOrder and total > 0 then out[r] = bp / total end
	end
	return out
end

-- Long-run rarity rates WITH pity, exact: stationary distribution of the Markov chain over the pity counters
-- (e = boxes since Épica+, l = boxes since Legendaria+; e <= l always). Cached per box.
local effectiveCache: { [string]: { [string]: number } } = {}
function LootboxData.EffectiveRates(box: Box): { [string]: number }
	if effectiveCache[box.id] then return effectiveCache[box.id] end
	local N, M = box.pity.epic, box.pity.legendary
	local function key(e: number, l: number): number return l * 1000 + e end
	local tierOdds = { [1] = LootboxData.TierOdds(box, 1), [3] = LootboxData.TierOdds(box, 3), [4] = LootboxData.TierOdds(box, 4) }
	local function forced(e: number, l: number): number
		if l >= M - 1 then return 4 end
		if e >= N - 1 then return 3 end
		return 1
	end
	local dist: { [number]: number } = { [key(0, 0)] = 1 }
	local rates: { [string]: number } = {}
	for _ = 1, 5000 do
		local nextDist: { [number]: number } = {}
		local r2: { [string]: number } = {}
		for k, pk in dist do
			local l, e = k // 1000, k % 1000
			for r, pr in tierOdds[forced(e, l)] do
				local o = ORDER[r]
				local ne = if o >= 3 then 0 else e + 1
				local nl = if o >= 4 then 0 else l + 1
				local nk = key(ne, nl)
				nextDist[nk] = (nextDist[nk] or 0) + pk * pr
				r2[r] = (r2[r] or 0) + pk * pr
			end
		end
		local delta = 0
		for k, v in nextDist do delta += math.abs(v - (dist[k] or 0)) end
		dist, rates = nextDist, r2
		if delta < 1e-13 then break end
	end
	effectiveCache[box.id] = rates
	return rates
end

-- fingerprint of everything a player sees before opening / buying (odds, items, weights, pity, price)
function LootboxData.OddsVersion(box: Box): number
	local parts: { any } = { box.id, box.price, box.pity.epic, box.pity.legendary }
	for _, r in LootboxData.RARITIES do
		table.insert(parts, r)
		table.insert(parts, box.odds[r] or 0)
		for _, e in (box.items[r] or {}) :: { Entry } do
			table.insert(parts, e.id)
			table.insert(parts, e.w)
		end
	end
	return DateUtil.Hash(table.unpack(parts))
end

-- "12,50 %" / "0,17 %"
function LootboxData.FormatPct(p: number): string
	local s = string.format("%.2f", p * 100)
	return (string.gsub(s, "%.", ",")) .. " %"
end

return LootboxData
