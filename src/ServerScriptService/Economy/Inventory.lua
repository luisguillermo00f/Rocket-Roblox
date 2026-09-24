--!strict
-- Inventory.lua (server, pure): what a player owns and wears (docs/cosmetics.md §3, §6, §8).
--   profile.owned    = { [itemId] = unix time it was obtained }   (default items are never stored: always owned)
--   profile.equipped = { [slot] = itemId }
-- Buy / Equip validate EVERYTHING here; the client only asks. They mutate the table in one go (no yields between the
-- checks and the change), so two requests can't both pass the checks.
-- Install(Rewards) hooks level rewards and the weekly prize into the reward pipeline (once).
local RS = game:GetService("ReplicatedStorage")
local Economy = RS:WaitForChild("Economy")
local Catalog = require(Economy:WaitForChild("CosmeticCatalog"))
local ShopRotation = require(Economy:WaitForChild("ShopRotation"))
local DateUtil = require(Economy:WaitForChild("DateUtil"))

local Inventory = {}

Inventory.WEEKLY_PRIZE_FALLBACK = 500 -- credits when every weekly prize is already owned

function Inventory.Owns(profile: any, id: any): boolean
	local it = Catalog.Get(id)
	if not it then return false end
	return it.default == true or profile.owned[id] ~= nil
end

-- give an item (level reward, prize, box...). Already owned -> its price (or DUPLICATE_REFUND) in credits instead.
-- b: reward breakdown (optional) collecting what the client is told.
function Inventory.Grant(profile: any, id: string, now: number, b: any?): boolean
	local it = Catalog.Get(id)
	if not it then return false end
	if Inventory.Owns(profile, id) then
		local refund = it.price or Catalog.DUPLICATE_REFUND
		profile.credits += refund
		profile.creditsEarned += refund
		if b then
			b.credits += refund
			if b.items then table.insert(b.items, { id = id, refund = refund }) end
		end
		return false
	end
	profile.owned[id] = now
	if b and b.items then table.insert(b.items, { id = id }) end
	return true
end

-- returns ok, error text (UI, Spanish), price paid
function Inventory.Buy(profile: any, id: any, now: number): (boolean, string?, number?)
	local it = Catalog.Get(id)
	if not it then return false, "ESE OBJETO NO EXISTE", nil end
	if not it.price then return false, "ESE OBJETO NO SE VENDE", nil end
	if not ShopRotation.OnSale(now)[it.id] then return false, "YA NO ESTÁ EN LA TIENDA", nil end
	if Inventory.Owns(profile, it.id) then return false, "YA LO TIENES", nil end
	local price = it.price :: number
	if profile.credits < price then return false, "CRÉDITOS INSUFICIENTES", nil end
	profile.credits -= price
	profile.owned[it.id] = now
	return true, nil, price
end

function Inventory.Equip(profile: any, slot: any, id: any): (boolean, string?)
	if not Catalog.IsSlot(slot) then return false, "RANURA NO VÁLIDA" end
	local it = Catalog.Get(id)
	if not it then return false, "ESE OBJETO NO EXISTE" end
	if it.slot ~= slot then return false, "ESE OBJETO NO VA EN ESA RANURA" end
	if not Inventory.Owns(profile, it.id) then return false, "NO LO TIENES" end
	profile.equipped[slot] = it.id
	return true, nil
end

-- what the player wears, valid and complete (an unknown / unowned / wrong-slot id falls back to the default)
function Inventory.Loadout(profile: any): { [string]: string }
	local out = Catalog.Defaults()
	local eq = profile and profile.equipped
	if type(eq) == "table" then
		for _, slot in Catalog.SLOTS do
			local it = Catalog.Get(eq[slot])
			if it and it.slot == slot and Inventory.Owns(profile, it.id) then out[slot] = it.id end
		end
	end
	return out
end

-- owned ids the catalog still knows (defaults included), for the client
function Inventory.OwnedList(profile: any): { string }
	local out = {}
	for _, it in Catalog.Items do
		if Inventory.Owns(profile, it.id) then table.insert(out, it.id) end
	end
	return out
end

-- every level item up to `level` (migration of existing players; idempotent: owned ones are skipped, no refund)
function Inventory.GrantLevelItemsUpTo(profile: any, level: number, now: number)
	for L = 2, level do
		for _, id in Catalog.LevelItems(L) do
			if not Inventory.Owns(profile, id) then profile.owned[id] = now end
		end
	end
end

-- the weekly prize: an item from the challenge pool the player doesn't have yet (hash of the week), else credits
function Inventory.WeeklyPrize(profile: any, now: number, b: any?)
	local week = DateUtil.WeekIndex(now)
	if profile.weeklyPrize == week then return end
	profile.weeklyPrize = week
	local pool = {}
	for _, it in Catalog.Items do
		if it.challenge and not Inventory.Owns(profile, it.id) then table.insert(pool, it.id) end
	end
	table.sort(pool)
	if #pool == 0 then
		profile.credits += Inventory.WEEKLY_PRIZE_FALLBACK
		profile.creditsEarned += Inventory.WEEKLY_PRIZE_FALLBACK
		if b then b.credits += Inventory.WEEKLY_PRIZE_FALLBACK end
		return
	end
	Inventory.Grant(profile, pool[DateUtil.Hash(week, "chreward", #pool) % #pool + 1], now, b)
end

local installed = false
function Inventory.Install(Rewards: any)
	if installed then return end
	installed = true
	table.insert(Rewards.LevelHooks, function(profile: any, level: number, b: any)
		for _, id in Catalog.LevelItems(level) do
			Inventory.Grant(profile, id, b.at or os.time(), b)
		end
	end)
	table.insert(Rewards.ChallengeHooks, function(profile: any, _done: any, allWeekly: boolean, b: any)
		if allWeekly then Inventory.WeeklyPrize(profile, b.at or os.time(), b) end
	end)
end

return Inventory
