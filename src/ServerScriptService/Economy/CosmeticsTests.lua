--!strict
-- CosmeticsTests.lua: shop purchases (valid / invalid), equipping, the daily rotation and the featured item, catalog
-- sanity, level and weekly rewards, and the v2 -> v3 profile migration.
-- Run (Studio command bar, Edit mode is fine):
--   print(require(game.ServerScriptService.Economy.CosmeticsTests).RunAll(true))
local RS = game:GetService("ReplicatedStorage")
local Progression = require(RS:WaitForChild("Game"):WaitForChild("Progression"))
local Economy = RS:WaitForChild("Economy")
local Catalog = require(Economy:WaitForChild("CosmeticCatalog"))
local ShopRotation = require(Economy:WaitForChild("ShopRotation"))
local DateUtil = require(Economy:WaitForChild("DateUtil"))
local ProfileSchema = require(script.Parent:WaitForChild("ProfileSchema"))
local Inventory = require(script.Parent:WaitForChild("Inventory"))
local Rewards = require(script.Parent:WaitForChild("Rewards"))
local Challenges = require(script.Parent:WaitForChild("Challenges"))

Inventory.Install(Rewards) -- level items + weekly prize, as CosmeticsService does on the server

local Tests = {}
local list: { { name: string, fn: () -> (boolean, string) } } = {}
local function test(name: string, fn: () -> (boolean, string))
	table.insert(list, { name = name, fn = fn })
end

local DAY0 = ShopRotation.ANCHOR_DAY + 10
local NOON = DAY0 * DateUtil.DAY + 12 * 3600

local function fresh(credits: number?): any
	local p = ProfileSchema.Migrate(nil)
	p.credits = credits or 0
	return p
end

local function onSaleItem(now: number, owned: any?): string
	for _, id in ShopRotation.Daily(DateUtil.DayIndex(now)) do
		if not (owned and owned[id]) then return id end
	end
	error("empty rotation")
end

-- ================================================================ purchases
test("compra válida: descuenta el precio exacto y añade el objeto", function()
	local p = fresh(5000)
	local id = onSaleItem(NOON)
	local price = (Catalog.Get(id) :: any).price
	local ok, err, paid = Inventory.Buy(p, id, NOON)
	return ok and err == nil and paid == price and p.credits == 5000 - price and p.owned[id] == NOON and Inventory.Owns(p, id),
		id .. " por " .. tostring(price)
end)

test("compra válida: el destacado de la semana también se vende", function()
	local p = fresh(5000)
	local f = ShopRotation.Featured(DateUtil.WeekIndex(NOON)) :: string
	local ok = Inventory.Buy(p, f, NOON)
	return ok and Inventory.Owns(p, f), f
end)

test("compra inválida: sin créditos (el saldo no cambia)", function()
	local p = fresh(10)
	local id = onSaleItem(NOON)
	local ok, err = Inventory.Buy(p, id, NOON)
	return not ok and err == "CRÉDITOS INSUFICIENTES" and p.credits == 10 and not Inventory.Owns(p, id), tostring(err)
end)

test("compra inválida: ya comprado (la segunda compra falla y no cobra)", function()
	local p = fresh(9000)
	local id = onSaleItem(NOON)
	Inventory.Buy(p, id, NOON)
	local after = p.credits
	local ok, err = Inventory.Buy(p, id, NOON + 1)
	return not ok and err == "YA LO TIENES" and p.credits == after, tostring(err)
end)

test("compra inválida: objeto fuera de la rotación de hoy", function()
	local p = fresh(9000)
	local sale = ShopRotation.OnSale(NOON)
	local outside = nil
	for _, it in Catalog.Items do
		if it.price and not sale[it.id] then
			outside = it.id
			break
		end
	end
	local ok, err = Inventory.Buy(p, outside, NOON)
	return outside ~= nil and not ok and err == "YA NO ESTÁ EN LA TIENDA" and p.credits == 9000, tostring(outside)
end)

test("compra inválida: objeto que no se vende, id inexistente o basura", function()
	local p = fresh(9000)
	local a, ea = Inventory.Buy(p, "primary_pearl", NOON) -- level reward only
	local b, eb = Inventory.Buy(p, "body_octane", NOON) -- default
	local c, ec = Inventory.Buy(p, "no_existe", NOON)
	local d = Inventory.Buy(p, { id = "x" }, NOON)
	local e = Inventory.Buy(p, 42, NOON)
	return not a and not b and not c and not d and not e and ea == "ESE OBJETO NO SE VENDE" and eb == ea and ec == "ESE OBJETO NO EXISTE" and p.credits == 9000, "ok"
end)

test("compra: margen de 60 s tras medianoche para lo de ayer", function()
	local midnight = (DAY0 + 1) * DateUtil.DAY
	local today = ShopRotation.OnSale(midnight + 3600)
	local yesterdayOnly = nil
	for _, id in ShopRotation.Daily(DAY0) do
		if not today[id] then
			yesterdayOnly = id
			break
		end
	end
	if not yesterdayOnly then return false, "sin candidato" end
	local p1, p2 = fresh(9000), fresh(9000)
	local okIn = Inventory.Buy(p1, yesterdayOnly, midnight + 30)
	local okOut = Inventory.Buy(p2, yesterdayOnly, midnight + 120)
	return okIn and not okOut, yesterdayOnly
end)

-- ================================================================ equipping
test("equipar: en su ranura correcta", function()
	local p = fresh(9000)
	local id = onSaleItem(NOON)
	Inventory.Buy(p, id, NOON)
	local slot = (Catalog.Get(id) :: any).slot
	local ok = Inventory.Equip(p, slot, id)
	return ok and Inventory.Loadout(p)[slot] == id, slot .. " = " .. id
end)

test("equipar: ranura equivocada, sin tenerlo o ranura inventada se rechaza", function()
	local p = fresh(9000)
	local id = onSaleItem(NOON)
	Inventory.Buy(p, id, NOON)
	local slot = (Catalog.Get(id) :: any).slot
	local wrong = if slot == "title" then "frame" else "title"
	local a, ea = Inventory.Equip(p, wrong, id)
	local b, eb = Inventory.Equip(p, "goal", "goal_blackhole")
	local c = Inventory.Equip(p, "motor", id)
	return not a and ea == "ESE OBJETO NO VA EN ESA RANURA" and not b and eb == "NO LO TIENES" and not c and p.equipped[wrong] ~= id, "ok"
end)

test("equipar: los objetos por defecto siempre se pueden", function()
	local p = fresh()
	local ok1 = Inventory.Equip(p, "body", "body_troll")
	local ok2 = Inventory.Equip(p, "body", "body_octane")
	return ok1 and ok2 and Inventory.Loadout(p).body == "body_octane", "ok"
end)

test("loadout: ids basura, ajenos o de otra ranura vuelven al valor por defecto", function()
	local p = fresh()
	p.equipped = { primary = "goal_blackhole", secondary = "no_existe", wheels = 5, boost = "boost_rainbow" }
	local l = Inventory.Loadout(p)
	local d = Catalog.Defaults()
	local r = Catalog.Resolve({ goal = "primary_neon", title = {} })
	return l.primary == d.primary and l.secondary == d.secondary and l.wheels == d.wheels and l.boost == d.boost
		and r.goal.id == d.goal and r.title.id == d.title, "ok"
end)

-- ================================================================ rotation
local function checkDay(day: number): (boolean, string)
	local items = ShopRotation.Daily(day)
	if #items ~= 6 then return false, "tamaño " .. #items end
	local seen, perSlot, byRarity = {}, {}, {}
	for _, id in items do
		local it = Catalog.Get(id)
		if not it or not it.price then return false, "no vendible " .. id end
		if seen[id] then return false, "repetido " .. id end
		seen[id] = true
		perSlot[it.slot] = (perSlot[it.slot] or 0) + 1
		byRarity[it.rarity] = (byRarity[it.rarity] or 0) + 1
		if perSlot[it.slot] > 2 then return false, "más de 2 de " .. it.slot end
	end
	if byRarity.common ~= 3 or byRarity.rare ~= 2 or byRarity.epic ~= 1 then return false, "reparto" end
	local f = ShopRotation.Featured(math.floor((day + 3) / 7))
	if f and seen[f] then return false, "destacado repetido" end
	for _, id in ShopRotation.Daily(day - 1) do
		if seen[id] then return false, "repite del día anterior: " .. id end
	end
	return true, ""
end

test("rotación: 6 objetos, 3/2/1 por rareza, <=2 por ranura, sin repetir el día anterior", function()
	for d = ShopRotation.ANCHOR_DAY + 1, ShopRotation.ANCHOR_DAY + 365 do
		local ok, msg = checkDay(d)
		if not ok then return false, "día " .. d .. ": " .. msg end
	end
	return true, "365 días"
end)

test("rotación: determinista (sin caché y en otro orden da lo mismo)", function()
	local first = {}
	for d = ShopRotation.ANCHOR_DAY - 5, ShopRotation.ANCHOR_DAY + 200 do first[d] = table.concat(ShopRotation.Daily(d), ",") end
	ShopRotation.ClearCache()
	for d = ShopRotation.ANCHOR_DAY + 200, ShopRotation.ANCHOR_DAY - 5, -1 do
		if table.concat(ShopRotation.Daily(d), ",") ~= first[d] then return false, "día " .. d end
	end
	return true, "206 días"
end)

test("destacado: legendario, recorre todos antes de repetir y nunca dos semanas seguidas igual", function()
	local legends = {}
	for _, it in Catalog.Items do if it.price and it.rarity == "legendary" then legends[it.id] = true end end
	local n = 0
	for _ in legends do n += 1 end
	local w0 = DateUtil.WeekIndex(NOON)
	w0 -= w0 % n -- start of a cycle
	for c = 0, 20 do
		local seen = {}
		for k = 0, n - 1 do
			local f = ShopRotation.Featured(w0 + c * n + k) :: string
			if not legends[f] then return false, "no legendario " .. f end
			if seen[f] then return false, "repetido en el ciclo" end
			seen[f] = true
		end
	end
	for w = w0, w0 + 200 do
		if ShopRotation.Featured(w) == ShopRotation.Featured(w + 1) then return false, "semana " .. w end
	end
	return true, n .. " legendarios"
end)

-- ================================================================ catalog
test("catálogo: >= 40 objetos, todas las ranuras con objeto por defecto", function()
	local d = Catalog.Defaults()
	for _, slot in Catalog.SLOTS do
		local it = Catalog.Get(d[slot])
		if not it or not it.default or it.slot ~= slot then return false, "sin defecto en " .. slot end
	end
	return #Catalog.Items >= 40, #Catalog.Items .. " objetos"
end)

test("catálogo: precios dentro del rango de su rareza y toda pieza no gratuita tiene fuente", function()
	for _, it in Catalog.Items do
		if not Catalog.RARITIES[it.rarity] then return false, "rareza " .. it.id end
		if not Catalog.IsSlot(it.slot) then return false, "ranura " .. it.id end
		if it.price then
			local r = Catalog.PRICE_RANGE[it.rarity]
			if not r or it.price < r[1] or it.price > r[2] then return false, "precio " .. it.id end
		end
		if not it.default and not it.price and not it.level and not it.challenge and not it.box then return false, "sin fuente " .. it.id end
		if it.default and (it.price or it.level) then return false, "gratis con precio " .. it.id end
	end
	return true, "ok"
end)

-- ================================================================ level / weekly rewards
test("nivel: llegar al nivel 10 da sus objetos (una vez)", function()
	local p = fresh()
	local b: any = { xp = 0, credits = 0, levels = {}, levelCredits = 0, items = {}, at = NOON }
	Rewards.Grant(p, Progression.TotalFor(10), 0, b)
	local ok = Inventory.Owns(p, "primary_pearl") and Inventory.Owns(p, "frame_level") and Inventory.Owns(p, "boost_toxic")
	return ok and #b.items == 3, #b.items .. " objetos"
end)

test("nivel: si ya lo tenías (comprado), recibes créditos a cambio", function()
	local p = fresh()
	p.owned.primary_glass = 1 -- bought in the shop before reaching level 20
	p.xp = Progression.TotalFor(19)
	p.rewardedLevel = 19
	local b: any = { xp = 0, credits = 0, levels = {}, levelCredits = 0, items = {}, at = NOON }
	Rewards.Grant(p, Progression.Cost(19), 0, b)
	local refund = b.items[1] and b.items[1].refund
	return refund == (Catalog.Get("primary_glass") :: any).price and p.credits == refund + Progression.LevelCredits(20), tostring(refund)
end)

test("semanales: completar los 3 da un objeto del premio que no tienes; una vez por semana", function()
	local p = fresh()
	Challenges.Ensure(p, NOON)
	for _, e in p.challenges.weekly.list do e.progress = 0; e.done = false end
	p.challenges.weekly.list = { { id = "play", progress = 14, done = false }, { id = "mgPlay", progress = 15, done = true }, { id = "points", progress = 8000, done = true } }
	local b = Rewards.ApplyMatch(p, { result = "loss", points = 0, online = true, humanOpponents = 1, activeSeconds = 300 }, true, NOON) :: any
	local got = nil
	for _, it in b.items do if not it.refund then got = it.id end end
	local gotIt = got and Catalog.Get(got)
	local firstOk = gotIt ~= nil and gotIt.challenge == true and p.weeklyPrize == DateUtil.WeekIndex(NOON)
	local before = 0
	for _ in p.owned do before += 1 end
	Inventory.WeeklyPrize(p, NOON + 60, nil)
	local after = 0
	for _ in p.owned do after += 1 end
	return firstOk and before == after, tostring(got)
end)

test("semanales: con todo el premio ya conseguido se pagan créditos", function()
	local p = fresh()
	for _, it in Catalog.Items do if it.challenge then p.owned[it.id] = 1 end end
	Inventory.WeeklyPrize(p, NOON, nil)
	return p.credits == Inventory.WEEKLY_PRIZE_FALLBACK, tostring(p.credits)
end)

-- ================================================================ migration
test("migración: v2 -> v3 conserva todo y da los objetos de nivel ya alcanzados", function()
	local v2 = { schema = 2, xp = Progression.TotalFor(26) + 5, credits = 777, creditsEarned = 900, rewardedLevel = 26, wins = 12,
		challenges = { daily = { period = 5, list = { { id = "goals", progress = 2, done = false } } }, weekly = { period = 1, list = {} } },
		econ = { day = 5, earned = 50, localCredits = 0, localXp = 0, lastLocal = 0, firstWinDay = 5 } }
	local d, info = ProfileSchema.Migrate(v2)
	local lv = { "boost_toxic", "primary_pearl", "frame_level", "wheels_team", "primary_glass", "goal_frost" }
	for _, id in lv do
		if not Inventory.Owns(d, id) then return false, "falta " .. id end
	end
	return d.schema == ProfileSchema.VERSION and d.credits == 777 and d.wins == 12 and d.challenges.daily.list[1].progress == 2
		and not Inventory.Owns(d, "secondary_titanium") and info.from == 2 and d.equipped.body == "body_octane", "nivel 26"
end)

test("migración: v1 -> v3 en cadena (bono + objetos de nivel)", function()
	local d = ProfileSchema.Migrate({ xp = Progression.TotalFor(11), goals = 9 })
	return d.goals == 9 and d.credits == 1000 and Inventory.Owns(d, "primary_pearl") and d.rewardedLevel == 11, tostring(d.credits)
end)

test("migración: equipado inválido y objetos retirados se conservan sin romper nada", function()
	local d = ProfileSchema.Migrate({ schema = 3, owned = { old_item = 5, boost_rainbow = 9, [3] = true }, equipped = { boost = "old_item", goal = 7 } })
	local l = Inventory.Loadout(d)
	return d.owned.old_item == 5 and d.owned[3] == nil and l.boost == Catalog.Defaults().boost and l.goal == Catalog.Defaults().goal
		and d.equipped.goal == Catalog.Defaults().goal, "ok"
end)

function Tests.RunAll(verbose: boolean?): (number, number, string)
	local passed, lines = 0, {}
	for _, t in list do
		local ok, res, msg = pcall(t.fn)
		local good = ok and res == true
		if good then
			passed += 1
		end
		local line = string.format("[%s] %s: %s", if good then "PASS" else "FAIL", t.name, if ok then tostring(msg) else ("ERROR " .. tostring(res)))
		table.insert(lines, line)
		if verbose then
			print(line)
		end
	end
	local summary = string.format("%d / %d tests passed", passed, #list)
	table.insert(lines, summary)
	return passed, #list, table.concat(lines, "\n")
end

return Tests
