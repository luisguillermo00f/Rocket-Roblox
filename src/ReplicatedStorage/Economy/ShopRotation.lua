--!strict
-- ShopRotation.lua: which shop items are on sale (docs/cosmetics.md §5). Same for everyone and computed the same
-- way by the server (which re-checks every purchase) and the client (which only shows it).
--   * Daily(day): 6 items - 3 common, 2 rare, 1 epic (a missing rarity is filled from the one below), at most 2 of
--     the same slot, none of the previous day's 6 when there's an alternative.
--   * Featured(week): 1 legendary (epic if there are none), cycling through all of them before repeating.
-- "Previous day" is exact: days are computed forward from ANCHOR_DAY and memoised, so Daily(d) always avoids the list
-- that was really shown on d - 1 (a few thousand cheap steps at most, done once per server).
local DateUtil = require(script.Parent:WaitForChild("DateUtil"))
local Catalog = require(script.Parent:WaitForChild("CosmeticCatalog"))

local ShopRotation = {}

ShopRotation.ANCHOR_DAY = 20717 -- Monday 2026-09-21 (UTC); days before it are computed without the previous-day rule
ShopRotation.QUOTA = { { rarity = "epic", n = 1 }, { rarity = "rare", n = 2 }, { rarity = "common", n = 3 } } -- shown in this order
ShopRotation.MAX_PER_SLOT = 2
ShopRotation.GRACE = 60 -- s after midnight during which yesterday's items can still be bought

local LOWER = { epic = "rare", rare = "common", legendary = "epic" }

local function pool(rarity: string): { string }
	local out = {}
	for _, it in Catalog.Items do
		if it.price and it.rarity == rarity then table.insert(out, it.id) end
	end
	table.sort(out)
	return out
end

-- featured: legendaries in a fresh shuffled order every cycle of #legendaries weeks
function ShopRotation.Featured(week: number): string?
	local list = pool("legendary")
	if #list == 0 then list = pool("epic") end
	local n = #list
	if n == 0 then return nil end
	local function cycleOrder(c: number): { string }
		return DateUtil.Shuffled(list, DateUtil.Rng(DateUtil.Hash(c, "featured")))
	end
	local cycle, pos = week // n, week % n + 1
	local order = cycleOrder(cycle)
	-- no repeat across the cycle boundary (last of one cycle = first of the next)
	if n > 1 and pos <= 2 then
		local prevLast = cycleOrder(cycle - 1)[n]
		if order[1] == prevLast then order[1], order[2] = order[2], order[1] end
	end
	return order[pos]
end

local function pick(day: number, avoid: { [string]: boolean }, exclude: string?): { string }
	local rng = DateUtil.Rng(DateUtil.Hash(day, "shop"))
	local out: { string } = {}
	local taken: { [string]: boolean } = {}
	local perSlot: { [string]: number } = {}
	local function fits(id: string, allowAvoided: boolean): boolean
		if taken[id] or id == exclude then return false end
		if avoid[id] and not allowAvoided then return false end
		local it = Catalog.Get(id) :: Catalog.Item
		return (perSlot[it.slot] or 0) < ShopRotation.MAX_PER_SLOT
	end
	local function take(id: string)
		taken[id] = true
		table.insert(out, id)
		local it = Catalog.Get(id) :: Catalog.Item
		perSlot[it.slot] = (perSlot[it.slot] or 0) + 1
	end
	for _, q in ShopRotation.QUOTA do
		local need = q.n
		local rarity: string? = q.rarity
		while need > 0 and rarity do
			local order = DateUtil.Shuffled(pool(rarity :: string), rng)
			for _, allowAvoided in { false, true } do
				for _, id in order do
					if need > 0 and fits(id, allowAvoided) then
						take(id)
						need -= 1
					end
				end
			end
			rarity = LOWER[rarity :: string]
		end
	end
	return out
end

local memo: { [number]: { string } } = {}
local memoTop = -1

function ShopRotation.Daily(day: number): { string }
	if memo[day] then return memo[day] end
	local featuredOf = function(d: number): string?
		return ShopRotation.Featured(math.floor((d + 3) / 7))
	end
	if day <= ShopRotation.ANCHOR_DAY then
		local list = pick(day, {}, featuredOf(day))
		memo[day] = list
		return list
	end
	-- walk forward from the last memoised day (or the anchor)
	local start = if memoTop >= ShopRotation.ANCHOR_DAY and memoTop < day then memoTop else ShopRotation.ANCHOR_DAY
	if not memo[start] then memo[start] = pick(start, {}, featuredOf(start)) end
	for d = start + 1, day do
		if not memo[d] then
			local avoid = {}
			for _, id in memo[d - 1] do avoid[id] = true end
			memo[d] = pick(d, avoid, featuredOf(d))
		end
	end
	memoTop = math.max(memoTop, day)
	return memo[day]
end

-- tests: forget the memoised days (proves the result doesn't depend on the order days were asked for)
function ShopRotation.ClearCache()
	table.clear(memo)
	memoTop = -1
end

-- everything on sale at `now` (the grace window keeps yesterday's items for GRACE seconds after midnight)
function ShopRotation.OnSale(now: number): { [string]: boolean }
	local out = {}
	local day = DateUtil.DayIndex(now)
	for _, id in ShopRotation.Daily(day) do out[id] = true end
	local f = ShopRotation.Featured(DateUtil.WeekIndex(now))
	if f then out[f] = true end
	if now - day * DateUtil.DAY < ShopRotation.GRACE then
		for _, id in ShopRotation.Daily(day - 1) do out[id] = true end
		local pf = ShopRotation.Featured(DateUtil.WeekIndex(now - ShopRotation.GRACE))
		if pf then out[pf] = true end
	end
	return out
end

-- what the client shows
function ShopRotation.View(now: number): any
	local day, week = DateUtil.DayIndex(now), DateUtil.WeekIndex(now)
	return {
		day = day, week = week, items = ShopRotation.Daily(day), featured = ShopRotation.Featured(week),
		resetIn = DateUtil.SecondsToNextDay(now), featuredResetIn = DateUtil.SecondsToNextWeek(now),
	}
end

return ShopRotation
