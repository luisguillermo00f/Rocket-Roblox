--!strict
-- LootboxTests.lua: odds (100 000 openings per box against the published numbers), pity, duplicates -> fragments /
-- credits, PolicyService restriction, no double opening, save-before-answer, purchases, drops, history, migration.
-- Run (Studio command bar, Edit mode is fine; the frequency tests take a couple of seconds):
--   print(require(game.ServerScriptService.Economy.LootboxTests).RunAll(true))
-- Every roll uses a seeded Random, so a run is reproducible.
local RS = game:GetService("ReplicatedStorage")
local Progression = require(RS:WaitForChild("Game"):WaitForChild("Progression"))
local Economy = RS:WaitForChild("Economy")
local Catalog = require(Economy:WaitForChild("CosmeticCatalog"))
local Data = require(Economy:WaitForChild("LootboxData"))
local Config = require(Economy:WaitForChild("LootboxConfig"))
local DateUtil = require(Economy:WaitForChild("DateUtil"))
local ProfileSchema = require(script.Parent:WaitForChild("ProfileSchema"))
local Rewards = require(script.Parent:WaitForChild("Rewards"))
local Inventory = require(script.Parent:WaitForChild("Inventory"))
local Lootboxes = require(script.Parent:WaitForChild("Lootboxes"))
local LootboxRequests = require(script.Parent:WaitForChild("LootboxRequests"))
local Policy = require(script.Parent:WaitForChild("Policy"))

-- drops go through this rng: "never" (default) or "always" so the tests decide
local dropRng = { mode = "never" }
function dropRng.NextInteger(self: any, lo: number, hi: number): number
	return if self.mode == "always" then lo else hi
end
Inventory.Install(Rewards)
Lootboxes.Install(Rewards, dropRng :: any)

local Tests = {}
local list: { { name: string, fn: () -> (boolean, string) } } = {}
local function test(name: string, fn: () -> (boolean, string))
	table.insert(list, { name = name, fn = fn })
end

local N_SIM = 100000
local TOL = 0.01 -- +-1 percentage point
local NOW = Config.SEASON.startsAt + 5 * 86400 + 12 * 3600 -- inside the season, at noon UTC

local function fresh(): any
	local p = ProfileSchema.Migrate(nil)
	return p
end

local function ctx(extra: { [string]: any }?): any
	local c: { [string]: any } = { now = NOW, rng = Random.new(7), restricted = false, mode = "fragments" }
	for k, v in (extra or {}) :: { [string]: any } do c[k] = v end
	return c
end

local nextId = 0
local function rid(): string
	nextId += 1
	return string.format("req-%08d", nextId)
end

-- rng that always takes the lowest value: rarity "common", first item of the list
local LOWEST = { NextInteger = function(_self: any, lo: number, _hi: number): number return lo end }

-- ================================================================ data
test("datos: probabilidades de cada caja suman 100 % y toda rareza con p > 0 tiene objetos", function()
	for _, box in Data.All() do
		local sum = 0
		for _, r in Data.RARITIES do
			local bp = box.odds[r] or 0
			sum += bp
			if bp > 0 and #(box.items[r] or {}) == 0 then return false, box.id .. " sin objetos " .. r end
		end
		if sum ~= 10000 then return false, box.id .. " suma " .. sum end
		local itemSum = 0
		for _, it in Data.ItemOdds(box) do itemSum += it.p end
		if math.abs(itemSum - 1) > 1e-9 then return false, box.id .. " objetos suman " .. itemSum end
	end
	return true, "3 cajas"
end)

test("datos: cada objeto existe, su rareza coincide y los exóticos no se venden", function()
	for _, box in Data.All() do
		for r, entries in box.items do
			for _, e in entries do
				local it = Catalog.Get(e.id)
				if not it then return false, "no existe " .. e.id end
				if it.rarity ~= r then return false, e.id .. " es " .. it.rarity .. " no " .. r end
				if it.rarity == "exotic" and it.price then return false, "exótico a la venta " .. e.id end
			end
		end
	end
	for _, it in Catalog.Items do
		if it.box and not Data.Get(it.box) then return false, "caja desconocida " .. it.id end
	end
	return true, "ok"
end)

-- ================================================================ odds
test("frecuencias: 100 000 tiradas por caja (sin garantía) a +-1 punto de 'POR CAJA', rarezas y objetos", function()
	for _, box in Data.All() do
		local rng = Random.new(12345)
		local byRarity, byItem = {}, {}
		for _ = 1, N_SIM do
			local pity = { epic = 0, legendary = 0 } -- never forced
			local id, rarity = Lootboxes.Roll(box, pity, rng)
			byRarity[rarity] = (byRarity[rarity] or 0) + 1
			byItem[id] = (byItem[id] or 0) + 1
		end
		for r, p in Data.RarityOdds(box) do
			local f = (byRarity[r] or 0) / N_SIM
			if math.abs(f - p) > TOL then return false, string.format("%s %s: %.4f vs %.4f", box.id, r, f, p) end
		end
		for _, it in Data.ItemOdds(box) do
			local f = (byItem[it.id] or 0) / N_SIM
			if math.abs(f - it.p) > TOL then return false, string.format("%s %s: %.4f vs %.4f", box.id, it.id, f, it.p) end
		end
	end
	return true, "3 x 100 000"
end)

test("frecuencias: 100 000 aperturas seguidas (con garantía) a +-1 punto de 'MEDIA CON GARANTÍA'", function()
	for _, box in Data.All() do
		local rng = Random.new(999)
		local pity = { epic = 0, legendary = 0 }
		local byRarity = {}
		for _ = 1, N_SIM do
			local _, rarity = Lootboxes.Roll(box, pity, rng)
			byRarity[rarity] = (byRarity[rarity] or 0) + 1
		end
		for r, p in Data.EffectiveRates(box) do
			local f = (byRarity[r] or 0) / N_SIM
			if math.abs(f - p) > TOL then return false, string.format("%s %s: %.4f vs %.4f", box.id, r, f, p) end
		end
	end
	return true, "3 x 100 000"
end)

-- ================================================================ pity
test("garantía: nunca N cajas seguidas sin Épica+ ni M sin Legendaria+ (100 000 por caja)", function()
	for _, box in Data.All() do
		local rng = Random.new(4242)
		local pity = { epic = 0, legendary = 0 }
		local runE, runL, maxE, maxL = 0, 0, 0, 0
		for _ = 1, N_SIM do
			local _, rarity = Lootboxes.Roll(box, pity, rng)
			local o = Data.ORDER[rarity]
			runE = if o >= 3 then 0 else runE + 1
			runL = if o >= 4 then 0 else runL + 1
			maxE, maxL = math.max(maxE, runE), math.max(maxL, runL)
		end
		if maxE > box.pity.epic - 1 or maxL > box.pity.legendary - 1 then
			return false, string.format("%s: racha %d / %d", box.id, maxE, maxL)
		end
	end
	return true, "ok"
end)

test("garantía: con el contador al límite sale siempre la rareza garantizada", function()
	local box = Data.Get("standard") :: Data.Box
	local rng = Random.new(3)
	for _ = 1, 2000 do
		local pity = { epic = 0, legendary = box.pity.legendary - 1 }
		local _, r, forced = Lootboxes.Roll(box, pity, rng)
		if Data.ORDER[r] < 4 or forced ~= "legendary" or pity.legendary ~= 0 or pity.epic ~= 0 then return false, "legendaria " .. r end
		local p2 = { epic = box.pity.epic - 1, legendary = 3 }
		local _, r2, f2 = Lootboxes.Roll(box, p2, rng)
		if Data.ORDER[r2] < 3 or f2 ~= "epic" or p2.epic ~= 0 then return false, "épica " .. r2 end
	end
	return true, "2000 x 2"
end)

test("garantía: contadores guardados por tipo de caja e independientes", function()
	local p = fresh()
	p.boxes = { standard = 3, minigames = 1 }
	local c = ctx({ rng = LOWEST }) -- always common: counters go up
	for _ = 1, 3 do Lootboxes.Open(p, "standard", rid(), Data.OddsVersion(Data.Get("standard") :: Data.Box), c) end
	return p.pity.standard.epic == 3 and p.pity.standard.legendary == 3 and p.pity.minigames == nil, "ok"
end)

-- ================================================================ duplicates
local function openOne(p: any, boxId: string, c: any): any
	return Lootboxes.Open(p, boxId, rid(), Data.OddsVersion(Data.Get(boxId) :: Data.Box), c)
end

test("duplicados: objeto nuevo -> al inventario, sin fragmentos ni créditos", function()
	local p = fresh()
	p.boxes = { standard = 1 }
	local r = openOne(p, "standard", ctx({ rng = LOWEST }))
	return r.ok and not r.dup and Inventory.Owns(p, r.item) and next(r.gave) == nil and p.boxes.standard == 0 and p.boxesOpened == 1, tostring(r.item)
end)

test("duplicados: modo fragmentos -> fragmentos exactos de esa caja", function()
	local p = fresh()
	p.boxes = { standard = 2 }
	local first = openOne(p, "standard", ctx({ rng = LOWEST }))
	local credits = p.credits
	local r = openOne(p, "standard", ctx({ rng = LOWEST }))
	return r.ok and r.dup and r.item == first.item and r.gave.fragments == Config.DUP_FRAGMENTS[r.rarity] and p.fragments.standard == r.gave.fragments
		and p.credits == credits, string.format("+%d fragmentos", r.gave.fragments or -1)
end)

test("duplicados: modo créditos -> créditos exactos", function()
	local p = fresh()
	p.boxes = { minigames = 2 }
	Lootboxes.SetDupMode(p, "credits")
	openOne(p, "minigames", ctx({ rng = LOWEST }))
	local r = openOne(p, "minigames", ctx({ rng = LOWEST }))
	return r.ok and r.dup and r.gave.credits == Config.DUP_CREDITS[r.rarity] and p.credits == r.gave.credits and (p.fragments.minigames or 0) == 0,
		string.format("+%d créditos", r.gave.credits or -1)
end)

test("fragmentos: canjear un objeto de la caja (y fallos sin cambiar nada)", function()
	local p = fresh()
	p.fragments = { standard = 1000 }
	local ok = Lootboxes.Redeem(p, "standard", "boost_comet", rid(), ctx()) -- exotic: 2000
	local cheap = Lootboxes.Redeem(p, "standard", "secondary_red", rid(), ctx()) -- common: 50
	local again = Lootboxes.Redeem(p, "standard", "secondary_red", rid(), ctx())
	local other = Lootboxes.Redeem(p, "standard", "goal_nitro", rid(), ctx()) -- season box item
	return not ok.ok and ok.error == "FRAGMENTOS INSUFICIENTES" and cheap.ok and p.fragments.standard == 950 and Inventory.Owns(p, "secondary_red")
		and not again.ok and again.error == "YA LO TIENES" and not other.ok, "ok"
end)

-- ================================================================ PolicyService
test("policy: restringido, no restringido, error y respuesta rara (falla hacia restringido)", function()
	local fake: any = {}
	local a = Policy.Evaluate(function() return { ArePaidRandomItemsRestricted = true } end, fake)
	local b, bOk = Policy.Evaluate(function() return { ArePaidRandomItemsRestricted = false } end, fake)
	local c, cOk = Policy.Evaluate(function() error("HTTP 500") end, fake)
	local d = Policy.Evaluate(function() return "nada" end, fake)
	return a == true and b == false and bOk and c == true and not cOk and d == true, "ok"
end)

test("policy: restringido -> sin compras (ni con créditos) y sin cobrar", function()
	local p = fresh()
	p.credits = 10000
	local box = Data.Get("standard") :: Data.Box
	local r = Lootboxes.Buy(p, "standard", rid(), Data.OddsVersion(box), ctx({ restricted = true }))
	return not r.ok and p.credits == 10000 and (p.boxes.standard or 0) == 0, tostring(r.error)
end)

test("policy: modo fragmentos -> no se tira; la caja se canjea por fragmentos fijos", function()
	local p = fresh()
	p.boxes = { season1 = 1 }
	local box = Data.Get("season1") :: Data.Box
	local o = Lootboxes.Open(p, "season1", rid(), Data.OddsVersion(box), ctx({ restricted = true, mode = "fragments" }))
	local c = Lootboxes.Convert(p, "season1", rid(), ctx({ restricted = true }))
	return not o.ok and c.ok and p.fragments.season1 == box.convertFragments and p.boxes.season1 == 0 and #p.boxHistory == 0, "ok"
end)

test("policy: modo free_only -> las cajas ganadas se abren; la compra sigue bloqueada", function()
	local p = fresh()
	p.boxes = { standard = 1 }
	p.credits = 5000
	local box = Data.Get("standard") :: Data.Box
	local o = Lootboxes.Open(p, "standard", rid(), Data.OddsVersion(box), ctx({ restricted = true, mode = "free_only" }))
	local b = Lootboxes.Buy(p, "standard", rid(), Data.OddsVersion(box), ctx({ restricted = true, mode = "free_only" }))
	return o.ok and not b.ok and p.credits == 5000, "ok"
end)

test("probabilidades: si el cliente no vio las mismas, se rechaza sin tirar", function()
	local p = fresh()
	p.boxes = { standard = 1 }
	local r = Lootboxes.Open(p, "standard", rid(), 12345, ctx())
	return not r.ok and p.boxes.standard == 1 and #p.boxHistory == 0, tostring(r.error)
end)

-- ================================================================ double opening
test("doble apertura: el mismo requestId dos veces -> una tirada, mismo resultado", function()
	local p = fresh()
	p.boxes = { standard = 3 }
	local box = Data.Get("standard") :: Data.Box
	local id = rid()
	local a = Lootboxes.Open(p, "standard", id, Data.OddsVersion(box), ctx({ rng = Random.new(1) }))
	local b = Lootboxes.Open(p, "standard", id, Data.OddsVersion(box), ctx({ rng = Random.new(2) }))
	return a.ok and b == a and p.boxes.standard == 2 and #p.boxHistory == 1 and p.boxesOpened == 1, a.item
end)

test("doble apertura: 10 peticiones distintas con 1 caja -> 1 éxito", function()
	local p = fresh()
	p.boxes = { standard = 1 }
	local box = Data.Get("standard") :: Data.Box
	local okN, noBox = 0, 0
	for _ = 1, 10 do
		local r = Lootboxes.Open(p, "standard", rid(), Data.OddsVersion(box), ctx())
		if r.ok then okN += 1 elseif r.error == "NO TIENES CAJAS DE ESTE TIPO" then noBox += 1 end
	end
	return okN == 1 and noBox == 9 and p.boxes.standard == 0, okN .. " / " .. noBox
end)

test("doble apertura: petición mientras otra espera su guardado -> busy; el anillo guarda <= 20", function()
	local p = fresh()
	p.boxes = { standard = 30 }
	local player = {}
	local box = Data.Get("standard") :: Data.Box
	local inner: any = nil
	local clock = 0
	local deps: any
	deps = {
		profile = function() return p end,
		save = function()
			inner = LootboxRequests.Guarded(deps, player, "open", { box = "standard", requestId = rid(), oddsVersion = Data.OddsVersion(box) })
			return true
		end,
		push = function() end, canSpend = function() return true end, restricted = function() return false end,
		rng = Random.new(5), now = function() return NOW end, clock = function() clock += 5; return clock end,
	}
	local outer = LootboxRequests.Guarded(deps, player, "open", { box = "standard", requestId = rid(), oddsVersion = Data.OddsVersion(box) })
	deps.save = function() return true end
	for _ = 1, 25 do
		LootboxRequests.Guarded(deps, player, "open", { box = "standard", requestId = rid(), oddsVersion = Data.OddsVersion(box) })
	end
	LootboxRequests.Forget(player)
	return outer.ok and inner and not inner.ok and inner.error == "busy" and #p.boxRequests == Config.REQUEST_MEMORY and p.boxes.standard == 4, "ok"
end)

test("guardado antes de responder; si el guardado falla el objeto se queda", function()
	local p = fresh()
	p.boxes = { standard = 1 }
	local box = Data.Get("standard") :: Data.Box
	local log = {}
	local player = {}
	local deps: any = {
		profile = function() return p end,
		save = function()
			table.insert(log, if p.boxes.standard == 0 and #p.boxHistory == 1 then "save:applied" else "save:early")
			return false -- DataStore down
		end,
		push = function() table.insert(log, "push") end, canSpend = function() return true end, restricted = function() return false end,
		rng = Random.new(8), now = function() return NOW end, clock = function() return 1000 end,
	}
	local r = LootboxRequests.Guarded(deps, player, "open", { box = "standard", requestId = rid(), oddsVersion = Data.OddsVersion(box) })
	table.insert(log, "answer")
	LootboxRequests.Forget(player)
	return r.ok and table.concat(log, ",") == "save:applied,push,answer" and Inventory.Owns(p, r.item) and p.boxes.standard == 0, table.concat(log, ",")
end)

-- ================================================================ buying
test("compra: descuenta el precio y da la caja; sin créditos falla sin cambiar nada", function()
	local p = fresh()
	p.credits = 500
	local box = Data.Get("standard") :: Data.Box
	local a = Lootboxes.Buy(p, "standard", rid(), Data.OddsVersion(box), ctx())
	local b = Lootboxes.Buy(p, "standard", rid(), Data.OddsVersion(box), ctx())
	return a.ok and p.credits == 500 - box.price and p.boxes.standard == 1 and not b.ok and b.error == "CRÉDITOS INSUFICIENTES", "ok"
end)

test("compra: tope de 10 al día y se reinicia al cambiar el día UTC", function()
	local p = fresh()
	p.credits = 100000
	local box = Data.Get("minigames") :: Data.Box
	Rewards.EnsureDay(p, NOW)
	local okN = 0
	for _ = 1, 12 do
		if Lootboxes.Buy(p, "minigames", rid(), Data.OddsVersion(box), ctx()).ok then okN += 1 end
	end
	Rewards.EnsureDay(p, NOW + 86400)
	local next = Lootboxes.Buy(p, "minigames", rid(), Data.OddsVersion(box), ctx({ now = NOW + 86400 }))
	return okN == Config.DAILY_BUY_CAP and next.ok, okN .. " compras"
end)

test("compra: la caja de temporada no se vende fuera de la temporada", function()
	local p = fresh()
	p.credits = 5000
	local box = Data.Get("season1") :: Data.Box
	local r = Lootboxes.Buy(p, "season1", rid(), Data.OddsVersion(box), ctx({ now = Config.SEASON.endsAt + 10 }))
	return not r.ok and p.credits == 5000, tostring(r.error)
end)

-- ================================================================ earning
local ONLINE = { result = "win", points = 300, online = true, humanOpponents = 1, activeSeconds = 300 }

test("drops: como mucho 2 al día y solo en resultados en línea con recompensa", function()
	local p = fresh()
	dropRng.mode = "always"
	local got = 0
	for i = 1, 6 do
		local b = Rewards.ApplyMatch(p, ONLINE, true, NOW + i) :: any
		for _, bx in b.boxes do if bx.reason == "drop" then got += 1 end end
	end
	local q = fresh()
	local localB = Rewards.ApplyMatch(q, { result = "win", points = 300 }, false, NOW) :: any
	local training = Rewards.ApplyMatch(q, { result = "win", mode = "training" }, false, NOW + 500)
	local short = Rewards.ApplyMatch(q, { result = "win", online = true, humanOpponents = 1, activeSeconds = 5 }, true, NOW + 900) :: any
	local soloMg = Rewards.ApplyMinigame(q, { placement = 1, humans = 1, activeSeconds = 60 }, NOW + 1200) :: any
	dropRng.mode = "never"
	local qBoxes = 0
	for _, n in q.boxes do qBoxes += n end
	return got == Config.DAILY_DROP_CAP and #localB.boxes == 0 and training == nil and #short.boxes == 0 and #soloMg.boxes == 0 and qBoxes == 0, got .. " drops"
end)

test("niveles: nivel 5 -> Estándar; nivel 10 -> Estándar + Temporada", function()
	local p = fresh()
	local b = Rewards.ApplyMatch(p, { result = "loss", points = 0, online = true, humanOpponents = 1, activeSeconds = 300 }, true, NOW) :: any
	Rewards.Grant(p, Progression.TotalFor(10) - p.xp, 0, b)
	return (p.boxes.standard or 0) == 2 and (p.boxes.season1 or 0) == 1, string.format("std %d temp %d", p.boxes.standard or 0, p.boxes.season1 or 0)
end)

test("semanales: el de minijuegos da Caja de Minijuegos; los 3 dan Caja de Temporada", function()
	local p = fresh()
	p.challenges.weekly = { period = DateUtil.WeekIndex(NOW), list = {
		{ id = "mgPlay", progress = 14, done = false }, { id = "goals", progress = 15, done = true }, { id = "points", progress = 8000, done = true } } }
	p.challenges.daily = { period = DateUtil.DayIndex(NOW), list = {} }
	Rewards.ApplyMinigame(p, { placement = 2, humans = 3, activeSeconds = 60 }, NOW)
	return (p.boxes.minigames or 0) == 1 and (p.boxes.season1 or 0) == 1, "ok"
end)

-- ================================================================ history + migration
test("historial: nunca más de 50, sale primero el más antiguo", function()
	local p = fresh()
	p.boxes = { minigames = 60 }
	local first
	for i = 1, 60 do
		local r = openOne(p, "minigames", ctx({ rng = Random.new(i) }))
		if i == 11 then first = r end
	end
	return #p.boxHistory == Config.HISTORY_SIZE and p.boxHistory[1].item == first.item and p.boxHistory[1].t == NOW, "50"
end)

test("migración: v3 -> v4 conserva todo; cajas retroactivas como máximo 5", function()
	local v3 = { schema = 3, xp = Progression.TotalFor(17), credits = 321, owned = { boost_blue = 3 }, equipped = { boost = "boost_blue" }, weeklyPrize = 7 }
	local d, info = ProfileSchema.Migrate(v3)
	local big = ProfileSchema.Migrate({ schema = 3, xp = Progression.TotalFor(90) })
	return d.credits == 321 and d.owned.boost_blue == 3 and d.equipped.boost == "boost_blue" and d.weeklyPrize == 7 and d.boxes.standard == 3
		and info.retroBoxes == 3 and big.boxes.standard == Config.RETRO_LEVEL_BOXES_MAX and d.dupMode == "fragments", "nivel 17 -> 3"
end)

test("migración: v1 -> v4 en cadena y valores corruptos saneados", function()
	local d = ProfileSchema.Migrate({ xp = Progression.TotalFor(12), goals = 4 })
	local bad = ProfileSchema.Migrate({ schema = 4, boxes = { standard = -2, season1 = 3, [7] = 1 }, pity = { standard = { epic = "x" } }, dupMode = "robux", boxHistory = 5 })
	return d.goals == 4 and d.credits == 1100 and Inventory.Owns(d, "primary_pearl") and d.boxes.standard == 2
		and bad.boxes.standard == nil and bad.boxes.season1 == 3 and bad.pity.standard == nil and bad.dupMode == "fragments" and type(bad.boxHistory) == "table", "ok"
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
