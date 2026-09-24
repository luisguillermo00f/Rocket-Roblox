--!strict
-- EconomyTests.lua: XP curve, rewards, anti-farming caps, challenge rotation / progress and profile migration.
-- Run (Studio command bar, Edit mode is fine):
--   print(require(game.ServerScriptService.Economy.EconomyTests).RunAll(true))
-- Pure: no DataStore, no players. `now` is passed explicitly, so day / week changes are tested without waiting.
local RS = game:GetService("ReplicatedStorage")
local Progression = require(RS:WaitForChild("Game"):WaitForChild("Progression"))
local Economy = RS:WaitForChild("Economy")
local Config = require(Economy:WaitForChild("EconomyConfig"))
local DateUtil = require(Economy:WaitForChild("DateUtil"))
local Catalog = require(Economy:WaitForChild("ChallengeCatalog"))
local ProfileSchema = require(script.Parent:WaitForChild("ProfileSchema"))
local Rewards = require(script.Parent:WaitForChild("Rewards"))
local Challenges = require(script.Parent:WaitForChild("Challenges"))

local Tests = {}
local list: { { name: string, fn: () -> (boolean, string) } } = {}

local function test(name: string, fn: () -> (boolean, string))
	table.insert(list, { name = name, fn = fn })
end

local MONDAY = 1704067200 -- 2024-01-01 00:00:00 UTC, a Monday
local NOON = MONDAY + 12 * 3600

local function fresh(): any
	local p = ProfileSchema.Migrate(nil)
	return p
end

local function deepEqual(a: any, b: any): boolean
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for k, v in a do
		if not deepEqual(v, b[k]) then return false end
	end
	for k in b do
		if a[k] == nil then return false end
	end
	return true
end

local function match(result: string, points: number, extra: { [string]: any }?): any
	local r: { [string]: any } = { result = result, points = points, mode = "1v1", goals = 0 }
	for k, v in (extra or {}) :: { [string]: any } do r[k] = v end
	return r
end
local ONLINE = { online = true, humanOpponents = 1, activeSeconds = 300 }

-- the original loop implementation the closed form replaces
local function loopFromXp(xp: number): (number, number, number)
	local level, left = 1, math.max(0, xp)
	while left >= Progression.Cost(level) do
		left -= Progression.Cost(level)
		level += 1
	end
	return level, left, Progression.Cost(level)
end

-- ================================================================ curve
test("curva: forma cerrada = bucle original (niveles 1..300, bordes)", function()
	for L = 1, 300 do
		local t = Progression.TotalFor(L)
		for _, xp in { t - 1, t, t + 1, t + 137 } do
			if xp >= 0 then
				local a1, a2, a3 = Progression.FromXp(xp)
				local b1, b2, b3 = loopFromXp(xp)
				if a1 ~= b1 or a2 ~= b2 or a3 ~= b3 then
					return false, string.format("xp %d: %d/%d/%d vs %d/%d/%d", xp, a1, a2, a3, b1, b2, b3)
				end
			end
		end
	end
	return true, "igual en 1200 puntos"
end)

test("curva: tabla del documento", function()
	local want = { [5] = 1600, [10] = 5850, [20] = 21850, [30] = 47850, [50] = 129850, [100] = 509850 }
	for L, xp in want do
		if Progression.TotalFor(L) ~= xp then return false, "nivel " .. L end
		if (Progression.FromXp(xp)) ~= L or (Progression.FromXp(xp - 1)) ~= L - 1 then return false, "FromXp nivel " .. L end
	end
	return true, "ok"
end)

test("curva: xp 0, negativa o NaN -> nivel 1", function()
	local a = Progression.FromXp(0)
	local b = Progression.FromXp(-50)
	local c = Progression.FromXp(0 / 0)
	return a == 1 and b == 1 and c == 1, string.format("%d %d %d", a, b, c)
end)

-- ================================================================ rewards
test("recompensa: XP por resultado y fuente", function()
	local ok = Progression.MatchXp(400, "win") == 530 and Progression.MatchXp(400, "draw") == 480 and Progression.MatchXp(400, "loss") == 430
	ok = ok and Progression.MatchXp(400, "win", "local") == math.floor(530 * 0.7)
	ok = ok and Progression.MatchXp(400, "win", "ranked") == math.floor(530 * 1.15)
	ok = ok and Progression.MatchXp(400, "win", "training") == 0
	return ok, "530/480/430, local x0.7, ranked x1.15"
end)

test("recompensa: los puntos se topan en 1500 para la XP", function()
	return Progression.MatchXp(20000, "loss") == 30 + 1500, tostring(Progression.MatchXp(20000, "loss"))
end)

test("recompensa: créditos por partida en línea", function()
	local p = fresh()
	local b = Rewards.ApplyMatch(p, match("win", 450, ONLINE), true, NOON) :: any
	-- (10 + 20 + 4) credits + 50 first win; (30 + 100 + 450) xp + 200 first win; level 1 -> 3 pays 100 + 100
	local chCredits, chXp = 0, 0
	for _, c in b.challenges do chCredits += c.credits; chXp += c.xp end
	local ok = b.source == "online_pvp" and b.firstWin and p.xp == 580 + 200 + chXp
		and p.credits == 34 + 50 + b.levelCredits + chCredits and b.levelCredits >= 200
	return ok == true, string.format("credits %d xp %d", p.credits, p.xp)
end)

test("recompensa: entrenamiento se rechaza sin tocar nada", function()
	local p = fresh()
	local b = Rewards.ApplyMatch(p, match("win", 500, { mode = "training" }), false, NOON)
	return b == nil and p.matches == 0 and p.xp == 0, "nil"
end)

test("recompensa: resultado inválido se rechaza", function()
	local p = fresh()
	local b = Rewards.ApplyMatch(p, { result = "ganar", points = 9 }, true, NOON)
	local c = Rewards.ApplyMatch(p, "basura", true, NOON)
	return b == nil and c == nil and p.matches == 0, "nil"
end)

test("recompensa: la fuente la decide el servidor", function()
	local a = Rewards.Classify({ online = true, humanOpponents = 3, ranked = true }, false)
	local b = Rewards.Classify({ online = true, humanOpponents = 0 }, true)
	local c = Rewards.Classify({ online = true, humanOpponents = 1, ranked = true }, true)
	local d = Rewards.Classify({ online = true, humanOpponents = 1 }, true)
	return a == "local" and b == "online_bots" and c == "ranked" and d == "online_pvp", table.concat({ a, b, c, d }, " ")
end)

test("recompensa: créditos de subida de nivel una sola vez aunque se suban varios", function()
	local p = fresh()
	local bd: any = { xp = 0, credits = 0, levels = {}, levelCredits = 0, levelTo = 1, items = {}, at = NOON }
	Rewards.Grant(p, Progression.TotalFor(12), 0, bd) -- 1 -> 12 at once
	local want = 0
	for L = 2, 12 do want += Progression.LevelCredits(L) end
	for _, it in bd.items do want += it.refund or 0 end -- (level items are new here: no refunds)
	local once = p.credits == want and #bd.levels == 11
	Rewards.Grant(p, 0, 0, bd) -- nothing new
	return once and p.credits == want and p.rewardedLevel == 12, string.format("%d vs %d", p.credits, want)
end)

test("recompensa: stats de carrera recortadas por partida", function()
	local p = fresh()
	Rewards.ApplyMatch(p, match("win", 100, { goals = 999, demos = -5, bestKmh = 9999 }), false, NOON)
	return p.goals == Rewards.LIMITS.goals and p.demos == 0 and p.bestKmh == 400 and p.wins == 1 and p.streak == 1,
		string.format("goals %d demos %d kmh %d", p.goals, p.demos, p.bestKmh)
end)

-- ================================================================ anti-farming
test("anti-farmeo: tope diario de 400 cortado exacto", function()
	local p = fresh()
	local total = 0
	for i = 1, 30 do
		local b = Rewards.ApplyMatch(p, match("loss", 1000, ONLINE), true, NOON + i) :: any
		total += b.credits - b.levelCredits
		for _, c in b.challenges do total -= c.credits end
	end
	return p.econ.earned == Config.DAILY_CREDIT_CAP and total == Config.DAILY_CREDIT_CAP, string.format("earned %d total %d", p.econ.earned, total)
end)

test("anti-farmeo: partidas que pasan el tope marcan capped y siguen dando XP", function()
	local p = fresh()
	p.econ.day = DateUtil.DayIndex(NOON)
	p.econ.earned = Config.DAILY_CREDIT_CAP
	local b = Rewards.ApplyMatch(p, match("loss", 300, ONLINE), true, NOON) :: any
	return b.capped and b.xp >= 330 and p.econ.earned == Config.DAILY_CREDIT_CAP, string.format("xp %d", b.xp)
end)

test("anti-farmeo: subtope local 90 créditos / 3000 XP", function()
	local p = fresh()
	local t = NOON
	for _ = 1, 60 do
		t += Config.LOCAL_MIN_INTERVAL
		Rewards.ApplyMatch(p, match("win", 1500, {}), false, t)
		if DateUtil.DayIndex(t) ~= DateUtil.DayIndex(NOON) then break end
	end
	return p.econ.localCredits == Config.LOCAL_DAILY_CREDITS and p.econ.localXp == Config.LOCAL_DAILY_XP,
		string.format("credits %d xp %d", p.econ.localCredits, p.econ.localXp)
end)

test("anti-farmeo: ventana de 240 s entre partidas locales", function()
	local p = fresh()
	local a = Rewards.ApplyMatch(p, match("win", 100), false, NOON) :: any
	local b = Rewards.ApplyMatch(p, match("win", 100), false, NOON + 100) :: any
	local c = Rewards.ApplyMatch(p, match("win", 100), false, NOON + Config.LOCAL_MIN_INTERVAL) :: any
	return a.eligible and not b.eligible and b.xp == 0 and b.credits == 0 and c.eligible and p.matches == 3,
		string.format("%s %s %s", tostring(a.eligible), tostring(b.eligible), tostring(c.eligible))
end)

test("anti-farmeo: el tope se reinicia al cambiar el día UTC", function()
	local p = fresh()
	p.econ.day = DateUtil.DayIndex(NOON)
	p.econ.earned = Config.DAILY_CREDIT_CAP
	local b = Rewards.ApplyMatch(p, match("loss", 0, ONLINE), true, MONDAY + 86400 + 5) :: any
	return not b.capped and b.credits > 0 and p.econ.day == DateUtil.DayIndex(MONDAY + 86400), tostring(b.credits)
end)

test("anti-farmeo: primera victoria del día una vez y nunca en local", function()
	local p = fresh()
	local l = Rewards.ApplyMatch(p, match("win", 0), false, NOON) :: any
	local a = Rewards.ApplyMatch(p, match("win", 0, ONLINE), true, NOON + 400) :: any
	local b = Rewards.ApplyMatch(p, match("win", 0, ONLINE), true, NOON + 800) :: any
	local c = Rewards.ApplyMatch(p, match("win", 0, ONLINE), true, MONDAY + 86400 + 1) :: any
	return not l.firstWin and a.firstWin and not b.firstWin and c.firstWin, "local no, 1a si, 2a no, dia siguiente si"
end)

test("anti-farmeo: minijuego solo con bots x0,4 créditos; ronda corta no da nada", function()
	local p = fresh()
	local solo = Rewards.ApplyMinigame(p, { placement = 1, humans = 1, activeSeconds = 60 }, NOON) :: any
	local short = Rewards.ApplyMinigame(p, { placement = 1, humans = 4, activeSeconds = 5 }, NOON) :: any
	local soloBase = solo.credits - solo.levelCredits
	for _, c in solo.challenges do soloBase -= c.credits end
	return solo.source == "minigame_bots" and soloBase == math.floor(12 * 0.4) and not solo.firstWin
		and not short.eligible and short.xp == 0 and p.minigames == 2 and p.minigameWins == 2,
		string.format("solo %d", soloBase)
end)

test("anti-farmeo: partida en línea de menos de 60 s no da recompensa", function()
	local p = fresh()
	local b = Rewards.ApplyMatch(p, match("win", 500, { online = true, humanOpponents = 1, activeSeconds = 20 }), true, NOON) :: any
	return not b.eligible and b.xp == 0 and p.xp == 0 and p.wins == 1, b.reason or "?"
end)

-- ================================================================ rotation
local function checkList(ids: { string }): (boolean, string)
	if #ids ~= 3 then return false, "tamaño " .. #ids end
	local seen, cats, special = {}, {}, 0
	for _, id in ids do
		local d = Catalog.Get(id)
		if not d then return false, "id " .. id end
		if seen[id] then return false, "repetido " .. id end
		if cats[d.cat] then return false, "categoría repetida " .. d.cat end
		seen[id], cats[d.cat] = true, true
		if Catalog.IsSpecial(d) then special += 1 end
	end
	if special > 1 then return false, "más de 1 no jugable sin conexión" end
	return true, ""
end

test("rotación: determinista (mismo día -> misma lista)", function()
	local d0 = DateUtil.DayIndex(MONDAY)
	for d = d0, d0 + 99 do
		if table.concat(Catalog.Rotation(d, "daily"), ",") ~= table.concat(Catalog.Rotation(d, "daily"), ",") then
			return false, "día " .. d
		end
	end
	return true, "100 días"
end)

test("rotación: 3 distintos, categorías distintas, <=1 en línea/minijuego", function()
	local d0 = DateUtil.DayIndex(MONDAY)
	for d = d0, d0 + 999 do
		local ok, msg = checkList(Catalog.Rotation(d, "daily"))
		if not ok then return false, "día " .. d .. ": " .. msg end
	end
	for w = 2800, 3000 do
		local ok, msg = checkList(Catalog.Rotation(w, "weekly"))
		if not ok then return false, "semana " .. w .. ": " .. msg end
	end
	return true, "1000 días + 200 semanas"
end)

test("rotación: cambia entre días consecutivos", function()
	local d0 = DateUtil.DayIndex(MONDAY)
	local changed = 0
	for d = d0, d0 + 364 do
		if table.concat(Catalog.Rotation(d, "daily"), ",") ~= table.concat(Catalog.Rotation(d + 1, "daily"), ",") then changed += 1 end
	end
	return changed >= 355, changed .. " / 365"
end)

test("rotación: la semana empieza el lunes 00:00 UTC", function()
	local w = DateUtil.WeekIndex(MONDAY)
	return DateUtil.WeekIndex(MONDAY - 1) == w - 1 and DateUtil.WeekStart(w) == MONDAY and DateUtil.WeekIndex(MONDAY + 7 * 86400 - 1) == w
		and DateUtil.SecondsToNextWeek(MONDAY + 3600) == 7 * 86400 - 3600, "semana " .. w
end)

test("rotación: todos los tipos pueden salir (catálogo >= 20)", function()
	local seen, n = {}, 0
	local d0 = DateUtil.DayIndex(MONDAY)
	for d = d0, d0 + 999 do
		for _, id in Catalog.Rotation(d, "daily") do
			if not seen[id] then seen[id] = true; n += 1 end
		end
	end
	return #Catalog.List >= 20 and n == #Catalog.List, string.format("%d de %d", n, #Catalog.List)
end)

-- ================================================================ progress
local function forceList(p: any, kind: string, ids: { string }, now: number)
	Challenges.Ensure(p, now)
	local list = {}
	for _, id in ids do table.insert(list, { id = id, progress = 0, done = false }) end
	p.challenges[kind].list = list
end

test("progreso: sum, count y best", function()
	local p = fresh()
	forceList(p, "daily", { "goals", "wins", "hardHit" }, NOON)
	forceList(p, "weekly", { "clears", "mgPlay", "points" }, NOON)
	local r = { kind = "match", result = "win", goals = 2, bestKmh = 95, points = 100 }
	Challenges.Apply(p, r, NOON)
	local l = p.challenges.daily.list
	local ok = l[1].progress == 2 and l[2].progress == 1 and l[3].progress == 95
	Challenges.Apply(p, { kind = "match", result = "loss", goals = 0, bestKmh = 80 }, NOON)
	ok = ok and l[3].progress == 95 and l[2].progress == 1
	return ok, string.format("%d %d %d", l[1].progress, l[2].progress, l[3].progress)
end)

test("progreso: completar paga una vez (fuera del tope diario)", function()
	local p = fresh()
	forceList(p, "daily", { "goals", "wins", "clears" }, NOON)
	p.econ.day = DateUtil.DayIndex(NOON)
	p.econ.earned = Config.DAILY_CREDIT_CAP
	local b1 = Rewards.ApplyMatch(p, match("loss", 0, { online = true, humanOpponents = 1, activeSeconds = 300, goals = 5 }), true, NOON) :: any
	local b2 = Rewards.ApplyMatch(p, match("loss", 0, { online = true, humanOpponents = 1, activeSeconds = 300, goals = 5 }), true, NOON + 1) :: any
	local e = p.challenges.daily.list[1]
	return #b1.challenges == 1 and b1.challenges[1].credits > 0 and b1.credits >= b1.challenges[1].credits and #b2.challenges == 0
		and e.done and e.progress == 3, string.format("b1 %d b2 %d", #b1.challenges, #b2.challenges)
end)

test("progreso: al cambiar de periodo se regenera sin arrastrar progreso", function()
	local p = fresh()
	Challenges.Ensure(p, NOON)
	for _, e in p.challenges.daily.list do e.progress = 1 end
	local weeklyBefore = p.challenges.weekly.period
	Challenges.Ensure(p, NOON + 86400)
	local zero = true
	for _, e in p.challenges.daily.list do if e.progress ~= 0 or e.done then zero = false end end
	return zero and p.challenges.daily.period == DateUtil.DayIndex(NOON) + 1 and p.challenges.weekly.period == weeklyBefore, "ok"
end)

test("progreso: minijuegos solo cuentan en retos de minijuegos", function()
	local p = fresh()
	forceList(p, "daily", { "mgWins", "wins", "play" }, NOON)
	Rewards.ApplyMinigame(p, { placement = 1, humans = 3, activeSeconds = 40 }, NOON)
	local l = p.challenges.daily.list
	return l[1].done and l[2].progress == 0 and l[3].progress == 0, "ok"
end)

test("progreso: partidas locales no cuentan en retos en línea", function()
	local p = fresh()
	forceList(p, "daily", { "onlineWins", "wins", "play" }, NOON)
	Rewards.ApplyMatch(p, match("win", 0), false, NOON)
	local l = p.challenges.daily.list
	return l[1].progress == 0 and l[2].progress == 1 and l[3].progress == 1, "ok"
end)

-- ================================================================ migration
local V1: { [string]: any } = {
	matches = 42, wins = 20, losses = 18, draws = 4, goals = 61, assists = 12, saves = 30, epicSaves = 3, shots = 90,
	clears = 40, demos = 7, aerials = 33, points = 21000, xp = 21850 + 10, bestKmh = 131, streak = 2, bestStreak = 6,
	pinches = 2, bestPinchKmh = 140,
	settings = { gfx = { shadows = true }, cam = { FOV = 110 }, binds = { kb = { jump = "Space" }, pad = {} } },
}

test("migración: v1 -> v2 sin perder nada, mismo nivel", function()
	local d, info = ProfileSchema.Migrate(V1)
	for k, v in V1 do
		if k ~= "settings" and d[k] ~= v then return false, k end
	end
	local sameLevel = (Progression.FromXp(d.xp)) == (Progression.FromXp(V1.xp :: number))
	return sameLevel and deepEqual(d.settings, V1.settings) and d.schema == ProfileSchema.VERSION and info.from == 1 and V1.schema == nil,
		"nivel " .. Progression.FromXp(d.xp)
end)

test("migración: bono único de bienvenida por niveles ya alcanzados", function()
	local d = ProfileSchema.Migrate(V1)
	local level = Progression.FromXp(V1.xp :: number)
	local want = math.min(Config.WELCOME_BONUS.max, Config.WELCOME_BONUS.perLevel * (level - 1))
	local big = ProfileSchema.Migrate({ xp = Progression.TotalFor(80) })
	local new = ProfileSchema.Migrate(nil)
	return d.credits == want and d.rewardedLevel == level and big.credits == Config.WELCOME_BONUS.max and new.credits == 0,
		string.format("%d (nivel %d)", d.credits, level)
end)

test("migración: conserva claves desconocidas", function()
	local raw = table.clone(V1)
	raw.futureThing = { a = 1 }
	raw.anotherNumber = 7
	local d = ProfileSchema.Migrate(raw)
	return deepEqual(d.futureThing, { a = 1 }) and d.anotherNumber == 7, "ok"
end)

test("migración: valores corruptos -> valores por defecto", function()
	local d = ProfileSchema.Migrate({ xp = 0 / 0, goals = "muchos", wins = -3, matches = math.huge, credits = "x", schema = 2,
		econ = "roto", challenges = { daily = { period = "hoy" } }, settings = 5 })
	return d.xp == 0 and d.goals == 0 and d.wins == 0 and d.matches == 0 and d.credits == 0 and type(d.econ) == "table"
		and d.challenges.daily.period == -1 and d.settings == nil, "ok"
end)

test("migración: esquema futuro -> solo lectura, sin tocar sus campos", function()
	local d, info = ProfileSchema.Migrate({ schema = ProfileSchema.VERSION + 5, xp = 100, newField = true })
	return info.readOnly and d.schema == ProfileSchema.VERSION + 5 and d.newField == true and d.xp == 100, "ok"
end)

test("migración: migrar dos veces = migrar una (y no modifica la entrada)", function()
	local before = ProfileSchema.DeepCopy(V1)
	local once = ProfileSchema.Migrate(V1)
	local twice = ProfileSchema.Migrate(once)
	return deepEqual(once, twice) and deepEqual(V1, before), "ok"
end)

test("migración: el bloqueo de sesión no entra en el perfil", function()
	local raw = table.clone(V1)
	raw._lock = { job = "x", t = 1 }
	local d = ProfileSchema.Migrate(raw)
	return d._lock == nil, "ok"
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
