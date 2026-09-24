--!strict
-- Lootboxes.lua (server, pure): box inventory, opening (weighted roll + pity + duplicates), buying with credits,
-- fragments, drops and box rewards (docs/lootboxes.md). No DataStore, no remotes: LootboxService calls these on the
-- player's in-memory profile WITHOUT yielding, then saves before answering the client.
--   * the roll uses the rng it is given (the server passes its Random.new(); tests pass a seeded one)
--   * a request id already answered returns the stored result again: no second roll, no second box spent
--   * every request carries the OddsVersion the client showed; different odds -> refused (nothing rolled)
--   * restricted players (PolicyService) can't buy; in "fragments" mode they can't roll either (Convert instead)
local RS = game:GetService("ReplicatedStorage")
local Economy = RS:WaitForChild("Economy")
local Data = require(Economy:WaitForChild("LootboxData"))
local Config = require(Economy:WaitForChild("LootboxConfig"))
local Inventory = require(script.Parent:WaitForChild("Inventory"))

local Lootboxes = {}

export type Rng = any -- Random (or anything with :NextInteger(lo, hi))
export type Ctx = { now: number, rng: Rng?, restricted: boolean, mode: string? }

local ORDER = Data.ORDER

-- ---------------------------------------------------------------- profile helpers
local function count(map: any, id: string): number
	local v = map[id]
	return if type(v) == "number" and v == v and v > 0 then math.floor(v) else 0
end

local function pityOf(profile: any, boxId: string): { epic: number, legendary: number }
	local p = profile.pity[boxId]
	if type(p) ~= "table" then
		p = { epic = 0, legendary = 0 }
		profile.pity[boxId] = p
	end
	return p
end

function Lootboxes.AddBoxes(profile: any, boxId: string, n: number, b: any?, reason: string?)
	profile.boxes[boxId] = count(profile.boxes, boxId) + n
	if b and b.boxes then table.insert(b.boxes, { box = boxId, n = n, reason = reason }) end
end

local function remember(profile: any, requestId: string, result: any)
	table.insert(profile.boxRequests, { id = requestId, result = result })
	while #profile.boxRequests > Config.REQUEST_MEMORY do table.remove(profile.boxRequests, 1) end
end

local function answered(profile: any, requestId: any): any?
	if type(requestId) ~= "string" then return nil end
	for _, r in profile.boxRequests do
		if r.id == requestId then return r.result end
	end
	return nil
end

local function validRequest(requestId: any): boolean
	return type(requestId) == "string" and #requestId >= 8 and #requestId <= 64
end

local function fail(msg: string): any
	return { ok = false, error = msg }
end

-- common request checks; returns the box or an error result
local function checkBox(boxId: any, oddsVersion: any): (Data.Box?, any?)
	local box = Data.Get(boxId)
	if not box then return nil, fail("ESA CAJA NO EXISTE") end
	if oddsVersion ~= Data.OddsVersion(box) then
		return nil, fail("LAS PROBABILIDADES DE ESTA CAJA HAN CAMBIADO: REVÍSALAS ANTES DE SEGUIR")
	end
	return box, nil
end

-- ---------------------------------------------------------------- the roll
local function pickRarity(box: Data.Box, minOrder: number, rng: Rng): string
	local total = 0
	for _, r in Data.RARITIES do
		if ORDER[r] >= minOrder then total += box.odds[r] or 0 end
	end
	local x = rng:NextInteger(1, total)
	for _, r in Data.RARITIES do
		if ORDER[r] >= minOrder then
			x -= box.odds[r] or 0
			if x <= 0 then return r end
		end
	end
	return Data.RARITIES[#Data.RARITIES] -- unreachable (odds are integers that add up to total)
end

local function pickItem(box: Data.Box, rarity: string, rng: Rng): string
	local entries = box.items[rarity]
	local total = 0
	for _, e in entries do total += e.w end
	local x = rng:NextInteger(1, total)
	for _, e in entries do
		x -= e.w
		if x <= 0 then return e.id end
	end
	return entries[#entries].id
end

-- one roll with pity; updates the pity table in place. Returns item id, rarity, "epic" | "legendary" | nil (forced)
function Lootboxes.Roll(box: Data.Box, pity: { epic: number, legendary: number }, rng: Rng): (string, string, string?)
	local minOrder, forced = 1, nil
	if pity.legendary >= box.pity.legendary - 1 then
		minOrder, forced = ORDER.legendary, "legendary"
	elseif pity.epic >= box.pity.epic - 1 then
		minOrder, forced = ORDER.epic, "epic"
	end
	local rarity = pickRarity(box, minOrder, rng)
	local o = ORDER[rarity]
	pity.epic = if o >= ORDER.epic then 0 else pity.epic + 1
	pity.legendary = if o >= ORDER.legendary then 0 else pity.legendary + 1
	return pickItem(box, rarity, rng), rarity, forced
end

-- ---------------------------------------------------------------- actions (each returns { ok, ... })
function Lootboxes.Open(profile: any, boxId: any, requestId: any, oddsVersion: any, ctx: Ctx): any
	local prev = answered(profile, requestId)
	if prev then return prev end
	if not validRequest(requestId) then return fail("PETICIÓN NO VÁLIDA") end
	local box, err = checkBox(boxId, oddsVersion)
	if not box then return err end
	if ctx.restricted and (ctx.mode or Config.RESTRICTED_MODE) == "fragments" then
		return fail("EN TU CUENTA LAS CAJAS SE CANJEAN POR FRAGMENTOS")
	end
	if count(profile.boxes, box.id) < 1 then return fail("NO TIENES CAJAS DE ESTE TIPO") end
	local rng = ctx.rng :: Rng
	-- everything below happens in one go (no yields): the box is spent and the result stored together
	local itemId, rarity, forced = Lootboxes.Roll(box, pityOf(profile, box.id), rng)
	profile.boxes[box.id] = count(profile.boxes, box.id) - 1
	profile.boxesOpened += 1
	local dup = Inventory.Owns(profile, itemId)
	local gave: { [string]: number } = {}
	if dup then
		if profile.dupMode == "credits" then
			local c = Config.DUP_CREDITS[rarity]
			profile.credits += c
			profile.creditsEarned += c
			gave.credits = c
		else
			local f = Config.DUP_FRAGMENTS[rarity]
			profile.fragments[box.id] = count(profile.fragments, box.id) + f
			gave.fragments = f
		end
	else
		profile.owned[itemId] = ctx.now
	end
	local result = {
		ok = true, requestId = requestId, box = box.id, item = itemId, rarity = rarity, dup = dup, gave = gave,
		pity = forced, left = profile.boxes[box.id],
	}
	table.insert(profile.boxHistory, { t = ctx.now, box = box.id, item = itemId, rarity = rarity, dup = dup, gave = gave, pity = forced, seen = false })
	while #profile.boxHistory > Config.HISTORY_SIZE do table.remove(profile.boxHistory, 1) end
	remember(profile, requestId, result)
	return result
end

function Lootboxes.Buy(profile: any, boxId: any, requestId: any, oddsVersion: any, ctx: Ctx): any
	local prev = answered(profile, requestId)
	if prev then return prev end
	if not validRequest(requestId) then return fail("PETICIÓN NO VÁLIDA") end
	if ctx.restricted then return fail("LA COMPRA DE CAJAS NO ESTÁ DISPONIBLE EN TU CUENTA") end
	local box, err = checkBox(boxId, oddsVersion)
	if not box then return err end
	if not Data.Available(box, ctx.now) then return fail("ESTA CAJA NO ESTÁ A LA VENTA AHORA") end
	if count(profile.econ, "boxBuys") >= Config.DAILY_BUY_CAP then return fail("YA HAS COMPRADO " .. Config.DAILY_BUY_CAP .. " CAJAS HOY") end
	if profile.credits < box.price then return fail("CRÉDITOS INSUFICIENTES") end
	profile.credits -= box.price
	profile.econ.boxBuys = count(profile.econ, "boxBuys") + 1
	Lootboxes.AddBoxes(profile, box.id, 1)
	local result = { ok = true, requestId = requestId, box = box.id, price = box.price, boxes = profile.boxes[box.id] }
	remember(profile, requestId, result)
	return result
end

-- pick an item of the box with its fragments (no randomness; allowed for everyone)
function Lootboxes.Redeem(profile: any, boxId: any, itemId: any, requestId: any, ctx: Ctx): any
	local prev = answered(profile, requestId)
	if prev then return prev end
	if not validRequest(requestId) then return fail("PETICIÓN NO VÁLIDA") end
	local box = Data.Get(boxId)
	if not box then return fail("ESA CAJA NO EXISTE") end
	local rarity = type(itemId) == "string" and Data.Contains(box, itemId) or nil
	if not rarity then return fail("ESE OBJETO NO ESTÁ EN ESTA CAJA") end
	if Inventory.Owns(profile, itemId) then return fail("YA LO TIENES") end
	local cost = Config.REDEEM_COST[rarity]
	if count(profile.fragments, box.id) < cost then return fail("FRAGMENTOS INSUFICIENTES") end
	profile.fragments[box.id] = count(profile.fragments, box.id) - cost
	profile.owned[itemId] = ctx.now
	local result = { ok = true, requestId = requestId, box = box.id, item = itemId, rarity = rarity, cost = cost }
	remember(profile, requestId, result)
	return result
end

-- restricted "fragments" mode: a box becomes a fixed amount of its fragments (no roll)
function Lootboxes.Convert(profile: any, boxId: any, requestId: any, ctx: Ctx): any
	local prev = answered(profile, requestId)
	if prev then return prev end
	if not validRequest(requestId) then return fail("PETICIÓN NO VÁLIDA") end
	local box = Data.Get(boxId)
	if not box then return fail("ESA CAJA NO EXISTE") end
	if count(profile.boxes, box.id) < 1 then return fail("NO TIENES CAJAS DE ESTE TIPO") end
	profile.boxes[box.id] = count(profile.boxes, box.id) - 1
	profile.fragments[box.id] = count(profile.fragments, box.id) + box.convertFragments
	local result = { ok = true, requestId = requestId, box = box.id, fragments = box.convertFragments }
	remember(profile, requestId, result)
	return result
end

function Lootboxes.SetDupMode(profile: any, mode: any): any
	if mode ~= "fragments" and mode ~= "credits" then return fail("OPCIÓN NO VÁLIDA") end
	profile.dupMode = mode
	return { ok = true, dupMode = mode }
end

function Lootboxes.Ack(profile: any)
	for _, h in profile.boxHistory do h.seen = true end
end

-- Robux (DISABLED by LootboxConfig.ROBUX_ENABLED): a paid box is only GIVEN, never opened. Idempotent per receipt.
function Lootboxes.GrantPurchasedBox(profile: any, boxId: string, receiptId: string): boolean
	if type(profile.receipts) ~= "table" then profile.receipts = {} end
	if table.find(profile.receipts, receiptId) then return true end
	if not Data.Get(boxId) then return false end
	Lootboxes.AddBoxes(profile, boxId, 1)
	table.insert(profile.receipts, receiptId)
	while #profile.receipts > 100 do table.remove(profile.receipts, 1) end
	return true
end

-- ---------------------------------------------------------------- earning boxes
local function seasonOr(now: number): string
	return if Data.SeasonActive(now) then Config.SEASON.id else "standard"
end

-- end-of-match drop (only called for results that paid a reward: never local / training / abandoned)
function Lootboxes.Drop(profile: any, source: string, b: any, now: number, rng: Rng)
	local chance = Config.DROP_CHANCE[source]
	if not chance then return end
	if count(profile.econ, "drops") >= Config.DAILY_DROP_CAP then return end
	if rng:NextInteger(1, 10000) > math.floor(chance * 10000) then return end
	profile.econ.drops = count(profile.econ, "drops") + 1
	local boxId = if source == "minigame" then "minigames"
		elseif rng:NextInteger(1, 10000) <= math.floor(Config.DROP_SEASON_SHARE * 10000) then seasonOr(now)
		else "standard"
	Lootboxes.AddBoxes(profile, boxId, 1, b, "drop")
end

-- level L reached
function Lootboxes.LevelBoxes(profile: any, level: number, b: any?, now: number)
	if level % Config.LEVEL_BOX_EVERY == 0 then Lootboxes.AddBoxes(profile, "standard", 1, b, "level") end
	if level % Config.LEVEL_SEASON_EVERY == 0 then Lootboxes.AddBoxes(profile, seasonOr(now), 1, b, "level") end
end

-- completed challenges: each weekly of the minigame category -> a minigame box; all weeklies -> a season box
function Lootboxes.ChallengeBoxes(profile: any, done: { any }, allWeekly: boolean, b: any?, now: number)
	for _, c in done do
		if c.kind == "weekly" and c.scope == "minigame" then Lootboxes.AddBoxes(profile, "minigames", 1, b, "challenge") end
	end
	if allWeekly then Lootboxes.AddBoxes(profile, seasonOr(now), 1, b, "challenge") end
end

-- what the client needs (shared data like odds lives in LootboxData; this is the player's part)
function Lootboxes.View(profile: any, restricted: boolean, now: number): any
	local pity = {}
	for _, box in Data.All() do
		local p = profile.pity[box.id]
		local e, l = if type(p) == "table" then p.epic else 0, if type(p) == "table" then p.legendary else 0
		pity[box.id] = { epicIn = box.pity.epic - e, legendaryIn = box.pity.legendary - l }
	end
	local unseen = 0
	for _, h in profile.boxHistory do if not h.seen then unseen += 1 end end
	return {
		boxes = table.clone(profile.boxes), fragments = table.clone(profile.fragments), pity = pity, dupMode = profile.dupMode,
		history = profile.boxHistory, unseen = unseen, restricted = restricted,
		mode = if restricted then Config.RESTRICTED_MODE else "normal",
		buysLeft = math.max(0, Config.DAILY_BUY_CAP - count(profile.econ, "boxBuys")),
		dropsLeft = math.max(0, Config.DAILY_DROP_CAP - count(profile.econ, "drops")),
		seasonActive = Data.SeasonActive(now), credits = profile.credits, robux = Config.ROBUX_ENABLED,
	}
end

-- hooks into Rewards (once). rng: the server's Random for drops.
local installed = false
local dropRng: Rng? = nil
function Lootboxes.Install(Rewards: any, rng: Rng)
	dropRng = rng
	if installed then return end
	installed = true
	table.insert(Rewards.DailyCounters, "drops")
	table.insert(Rewards.DailyCounters, "boxBuys")
	table.insert(Rewards.LevelHooks, function(profile: any, level: number, b: any)
		Lootboxes.LevelBoxes(profile, level, b, b.at or os.time())
	end)
	table.insert(Rewards.ChallengeHooks, function(profile: any, done: { any }, allWeekly: boolean, b: any)
		Lootboxes.ChallengeBoxes(profile, done, allWeekly, b, b.at or os.time())
	end)
	table.insert(Rewards.ResultHooks, function(profile: any, source: string, b: any, now: number)
		if dropRng then Lootboxes.Drop(profile, source, b, now, dropRng :: Rng) end
	end)
end

-- the item a restricted player sees instead of odds: same list, with the fragment price of each rarity
function Lootboxes.RedeemList(box: Data.Box): { { id: string, rarity: string, cost: number } }
	local out = {}
	for _, it in Data.ItemOdds(box) do
		table.insert(out, { id = it.id, rarity = it.rarity, cost = Config.REDEEM_COST[it.rarity] })
	end
	return out
end


return Lootboxes
