--!strict
-- CosmeticCatalog.lua: every cosmetic in the game (docs/cosmetics.md §4). Pure data + lookups, shared by the server
-- (ownership, prices, rotation) and the client (how to draw it). Everything is built by code from these params:
-- colours, materials, ParticleEmitters, Trails, Beams, UIStroke / UIGradient. No external assets (particle textures
-- are the engine's built-in rbxasset:// ones).
-- Cosmetics are visual only: nothing here touches physics, hitboxes or match rules.
--
-- item = { id, slot, name, rarity, default?, price? (shop), level? (level reward), challenge? (weekly prize pool),
--          box? (lootbox only), params }
local CosmeticCatalog = {}

local rgb = Color3.fromRGB
local M = Enum.Material

CosmeticCatalog.SLOTS = { "body", "primary", "secondary", "wheels", "boost", "goal", "title", "frame" }
CosmeticCatalog.SLOT_NAMES = {
	body = "CARRO", primary = "PINTURA", secondary = "ACENTO", wheels = "LLANTAS", boost = "TURBO", goal = "GOL",
	title = "TÍTULO", frame = "MARCO",
}

CosmeticCatalog.RARITIES = {
	common = { name = "COMÚN", color = rgb(200, 200, 196), order = 1 },
	rare = { name = "RARA", color = rgb(70, 150, 255), order = 2 },
	epic = { name = "ÉPICA", color = rgb(170, 90, 255), order = 3 },
	legendary = { name = "LEGENDARIA", color = rgb(255, 196, 64), order = 4 },
}
CosmeticCatalog.RARITY_ORDER = { "common", "rare", "epic", "legendary" }

-- shop price range per rarity (a test checks every price against it)
CosmeticCatalog.PRICE_RANGE = {
	common = { 150, 250 }, rare = { 400, 600 }, epic = { 1000, 1400 }, legendary = { 2200, 3000 },
}

-- credits for a level / prize item you already own (bought it before reaching the level)
CosmeticCatalog.DUPLICATE_REFUND = 300

export type Item = {
	id: string, slot: string, name: string, rarity: string,
	default: boolean?, price: number?, level: number?, challenge: boolean?, box: string?,
	params: { [string]: any },
}

local ITEMS: { Item } = {
	-- ---------------------------------------------------------------- body (the existing skins, both free)
	{ id = "body_octane", slot = "body", name = "OCTANE", rarity = "common", default = true, params = { template = "Octane" } },
	{ id = "body_troll", slot = "body", name = "CARRITO TROLL", rarity = "common", default = true, params = { template = "Troll" } },

	-- ---------------------------------------------------------------- primary: a finish of the TEAM colour
	-- shade -1..1 darkens / lightens, sat scales saturation; the team colour is always kept
	{ id = "primary_standard", slot = "primary", name = "ESTÁNDAR", rarity = "common", default = true, params = { shade = 0, sat = 1, material = M.SmoothPlastic, reflectance = 0.06 } },
	{ id = "primary_shadow", slot = "primary", name = "SOMBRA", rarity = "common", price = 150, params = { shade = -0.35, sat = 1, material = M.SmoothPlastic, reflectance = 0.06 } },
	{ id = "primary_dawn", slot = "primary", name = "ALBA", rarity = "common", price = 150, params = { shade = 0.3, sat = 1, material = M.SmoothPlastic, reflectance = 0.06 } },
	{ id = "primary_matte", slot = "primary", name = "MATE", rarity = "common", price = 200, params = { shade = 0, sat = 0.8, material = M.SmoothPlastic, reflectance = 0 } },
	{ id = "primary_pearl", slot = "primary", name = "PERLADO", rarity = "rare", level = 10, params = { shade = 0.15, sat = 1, material = M.SmoothPlastic, reflectance = 0.25 } },
	{ id = "primary_metal", slot = "primary", name = "METALIZADO", rarity = "rare", price = 450, params = { shade = 0, sat = 1, material = M.Metal, reflectance = 0.2 } },
	{ id = "primary_glass", slot = "primary", name = "CRISTAL", rarity = "epic", level = 20, price = 1200, params = { shade = 0.05, sat = 1, material = M.Glass, reflectance = 0.3 } },
	{ id = "primary_neon", slot = "primary", name = "NEÓN", rarity = "epic", price = 1300, params = { shade = -0.2, sat = 1, material = M.Neon, reflectance = 0 } },
	{ id = "primary_chrome", slot = "primary", name = "CROMO", rarity = "legendary", price = 2600, params = { shade = 0.1, sat = 1, material = M.Foil, reflectance = 0.45 } },

	-- ---------------------------------------------------------------- secondary: free accent colour
	{ id = "secondary_white", slot = "secondary", name = "BLANCO", rarity = "common", default = true, params = { color = rgb(240, 240, 240) } },
	{ id = "secondary_black", slot = "secondary", name = "NEGRO", rarity = "common", price = 150, params = { color = rgb(24, 24, 28) } },
	{ id = "secondary_red", slot = "secondary", name = "ROJO", rarity = "common", price = 150, params = { color = rgb(220, 40, 50) } },
	{ id = "secondary_green", slot = "secondary", name = "VERDE", rarity = "common", price = 150, params = { color = rgb(40, 190, 90) } },
	{ id = "secondary_yellow", slot = "secondary", name = "AMARILLO", rarity = "common", price = 200, params = { color = rgb(250, 215, 40) } },
	{ id = "secondary_purple", slot = "secondary", name = "MORADO", rarity = "rare", price = 400, params = { color = rgb(140, 70, 230) } },
	{ id = "secondary_pink", slot = "secondary", name = "ROSA", rarity = "rare", price = 400, params = { color = rgb(255, 110, 190) } },
	{ id = "secondary_cyan", slot = "secondary", name = "CIAN", rarity = "rare", price = 450, params = { color = rgb(40, 220, 235) } },
	{ id = "secondary_lime", slot = "secondary", name = "LIMA", rarity = "rare", challenge = true, params = { color = rgb(170, 255, 60) } },
	{ id = "secondary_gold", slot = "secondary", name = "ORO", rarity = "epic", price = 1100, params = { color = rgb(255, 196, 64), material = M.Metal } },
	{ id = "secondary_titanium", slot = "secondary", name = "TITANIO", rarity = "epic", level = 30, params = { color = rgb(170, 176, 186), material = M.Foil } },

	-- ---------------------------------------------------------------- wheels (rims; the tyre stays black)
	{ id = "wheels_standard", slot = "wheels", name = "PLATA", rarity = "common", default = true, params = { color = rgb(150, 155, 165), material = M.Metal } },
	{ id = "wheels_black", slot = "wheels", name = "NEGRO MATE", rarity = "common", price = 150, params = { color = rgb(30, 30, 34), material = M.SmoothPlastic } },
	{ id = "wheels_red", slot = "wheels", name = "ROJO", rarity = "common", price = 200, params = { color = rgb(200, 40, 40), material = M.Metal } },
	{ id = "wheels_chrome", slot = "wheels", name = "CROMADAS", rarity = "rare", price = 500, params = { color = rgb(220, 224, 232), material = M.Foil } },
	{ id = "wheels_team", slot = "wheels", name = "EQUIPO NEÓN", rarity = "rare", level = 15, params = { teamAccent = true, material = M.Neon } },
	{ id = "wheels_gold", slot = "wheels", name = "DORADAS", rarity = "epic", price = 1200, params = { color = rgb(255, 196, 64), material = M.Metal } },
	{ id = "wheels_carbon", slot = "wheels", name = "CARBONO", rarity = "epic", challenge = true, params = { color = rgb(40, 42, 48), material = M.Foil } },
	{ id = "wheels_plasma", slot = "wheels", name = "PLASMA", rarity = "legendary", price = 2400, params = { color = rgb(120, 200, 255), material = M.Neon, glow = true, sparkle = true } },

	-- ---------------------------------------------------------------- boost: flame + ribbon + light
	-- flame / trail = { c0, c1 } (nil trail c1 = team accent), flameSize / trailWidth multipliers (<= 1.5 so the view
	-- is never blocked), texture = built-in particle ("fire" | "smoke" | "sparkles"), extra = second emitter
	{ id = "boost_standard", slot = "boost", name = "ESTÁNDAR", rarity = "common", default = true, params = {
		flame = { rgb(255, 236, 170), rgb(255, 110, 30) }, trail = { rgb(255, 220, 150) }, light = rgb(255, 160, 70) } },
	{ id = "boost_team", slot = "boost", name = "EQUIPO", rarity = "common", price = 200, params = {
		team = true, flame = { rgb(255, 255, 255) }, trail = { rgb(255, 255, 255) }, light = rgb(255, 255, 255) } },
	{ id = "boost_vapor", slot = "boost", name = "VAPOR", rarity = "common", price = 250, params = {
		flame = { rgb(255, 255, 255), rgb(200, 205, 215) }, trail = { rgb(255, 255, 255), rgb(190, 195, 205) }, texture = "smoke", flameSize = 1.2, light = false } },
	{ id = "boost_blue", slot = "boost", name = "LLAMA AZUL", rarity = "rare", price = 500, params = {
		flame = { rgb(200, 240, 255), rgb(40, 120, 255) }, trail = { rgb(200, 240, 255), rgb(40, 120, 255) }, light = rgb(80, 150, 255) } },
	{ id = "boost_toxic", slot = "boost", name = "TÓXICO", rarity = "rare", level = 5, params = {
		flame = { rgb(220, 255, 160), rgb(60, 220, 40) }, trail = { rgb(220, 255, 160), rgb(60, 220, 40) }, light = rgb(120, 255, 90) } },
	{ id = "boost_sparks", slot = "boost", name = "CHISPAS", rarity = "rare", price = 550, params = {
		flame = { rgb(255, 236, 170), rgb(255, 110, 30) }, trail = { rgb(255, 220, 150) }, light = rgb(255, 180, 70), extra = { texture = "sparkles", color = rgb(255, 210, 90) } } },
	{ id = "boost_plasma", slot = "boost", name = "PLASMA", rarity = "epic", price = 1200, params = {
		flame = { rgb(255, 200, 255), rgb(170, 60, 255) }, trail = { rgb(255, 200, 255), rgb(170, 60, 255) }, trailWidth = 1.3, light = rgb(190, 90, 255) } },
	{ id = "boost_gold", slot = "boost", name = "ORO", rarity = "epic", challenge = true, params = {
		flame = { rgb(255, 250, 210), rgb(255, 190, 40) }, trail = { rgb(255, 250, 210), rgb(255, 190, 40) }, light = rgb(255, 200, 80), extra = { texture = "sparkles", color = rgb(255, 215, 90) } } },
	{ id = "boost_rainbow", slot = "boost", name = "ARCOÍRIS", rarity = "legendary", price = 2800, params = {
		flame = { rgb(255, 255, 255), rgb(255, 120, 200) }, rainbow = true, trailLife = 0.5, light = rgb(255, 255, 255) } },
	{ id = "boost_inferno", slot = "boost", name = "INFIERNO", rarity = "legendary", level = 40, params = {
		flame = { rgb(255, 240, 120), rgb(230, 30, 10) }, trail = { rgb(255, 200, 80), rgb(200, 20, 10) }, texture = "fire", flameSize = 1.4, light = rgb(255, 60, 30) } },

	-- ---------------------------------------------------------------- goal explosions (Effects.Goal styles)
	{ id = "goal_standard", slot = "goal", name = "CLÁSICA", rarity = "common", default = true, params = { style = "classic" } },
	{ id = "goal_shockwave", slot = "goal", name = "ONDA", rarity = "common", price = 250, params = { style = "shockwave" } },
	{ id = "goal_confetti", slot = "goal", name = "CONFETI", rarity = "rare", price = 550, params = { style = "confetti",
		colors = { rgb(255, 80, 80), rgb(255, 210, 60), rgb(80, 220, 120), rgb(80, 160, 255), rgb(220, 110, 255) } } },
	{ id = "goal_frost", slot = "goal", name = "ESCARCHA", rarity = "rare", level = 25, params = { style = "frost", color = rgb(170, 225, 255) } },
	{ id = "goal_fireworks", slot = "goal", name = "FUEGOS ARTIFICIALES", rarity = "epic", price = 1300, params = { style = "fireworks",
		colors = { rgb(255, 90, 90), rgb(255, 220, 90), rgb(120, 255, 160), rgb(120, 180, 255), rgb(255, 140, 255) } } },
	{ id = "goal_supernova", slot = "goal", name = "SUPERNOVA", rarity = "epic", challenge = true, params = { style = "supernova" } },
	{ id = "goal_blackhole", slot = "goal", name = "AGUJERO NEGRO", rarity = "legendary", price = 3000, params = { style = "blackhole", color = rgb(150, 80, 255) } },
	{ id = "goal_lightning", slot = "goal", name = "RELÁMPAGO", rarity = "legendary", level = 50, params = { style = "lightning", color = rgb(200, 230, 255) } },

	-- ---------------------------------------------------------------- titles (second line of the nameplate)
	{ id = "title_rookie", slot = "title", name = "NOVATO", rarity = "common", default = true, params = { text = "NOVATO", color = rgb(210, 210, 210) } },
	{ id = "title_scorer", slot = "title", name = "GOLEADOR", rarity = "rare", challenge = true, params = { text = "GOLEADOR", color = rgb(120, 190, 255) } },
	{ id = "title_wall", slot = "title", name = "EL MURO", rarity = "rare", challenge = true, params = { text = "EL MURO", color = rgb(120, 190, 255) } },
	{ id = "title_wrecker", slot = "title", name = "DEMOLEDOR", rarity = "rare", price = 400, params = { text = "DEMOLEDOR", color = rgb(255, 140, 90) } },
	{ id = "title_pilot", slot = "title", name = "AVIADOR", rarity = "epic", price = 1000, params = { text = "AVIADOR", color = rgb(200, 150, 255) } },
	{ id = "title_partyking", slot = "title", name = "REY DE LA FIESTA", rarity = "epic", challenge = true, params = { text = "REY DE LA FIESTA", color = rgb(255, 140, 220) } },
	{ id = "title_veteran", slot = "title", name = "VETERANO", rarity = "epic", level = 35, params = { text = "VETERANO", color = rgb(200, 150, 255) } },
	{ id = "title_legend", slot = "title", name = "LEYENDA", rarity = "legendary", level = 60, params = { text = "LEYENDA", color = rgb(255, 196, 64), glow = true } },

	-- ---------------------------------------------------------------- avatar frames (UIStroke on the avatar)
	{ id = "frame_none", slot = "frame", name = "SIN MARCO", rarity = "common", default = true, params = { color = rgb(255, 255, 255), transparency = 0.55, thickness = 1.5 } },
	{ id = "frame_white", slot = "frame", name = "BLANCO", rarity = "common", price = 150, params = { color = rgb(255, 255, 255), thickness = 3 } },
	{ id = "frame_blue", slot = "frame", name = "AZUL ELÉCTRICO", rarity = "rare", price = 450, params = { color = rgb(60, 150, 255), thickness = 4 } },
	{ id = "frame_level", slot = "frame", name = "ESTRELLA", rarity = "rare", level = 10, params = { gradient = { rgb(255, 255, 255), rgb(255, 196, 64) }, thickness = 4 } },
	{ id = "frame_gold", slot = "frame", name = "DORADO", rarity = "epic", price = 1100, params = { color = rgb(255, 196, 64), thickness = 5 } },
	{ id = "frame_neon", slot = "frame", name = "NEÓN", rarity = "epic", challenge = true, params = { gradient = { rgb(40, 230, 255), rgb(170, 80, 255) }, thickness = 5, spin = true } },
	{ id = "frame_fire", slot = "frame", name = "EN LLAMAS", rarity = "legendary", price = 2400, params = { gradient = { rgb(255, 60, 20), rgb(255, 220, 60) }, thickness = 6, spin = true } },
}

local BY_ID: { [string]: Item } = {}
local DEFAULTS: { [string]: string } = {}
for _, it in ITEMS do
	assert(BY_ID[it.id] == nil, "duplicate cosmetic " .. it.id)
	BY_ID[it.id] = it
	if it.default and not DEFAULTS[it.slot] then DEFAULTS[it.slot] = it.id end
end

CosmeticCatalog.Items = ITEMS

function CosmeticCatalog.Get(id: any): Item?
	return if type(id) == "string" then BY_ID[id] else nil
end

-- later phases (lootboxes) add their items here
function CosmeticCatalog.Add(it: Item)
	assert(BY_ID[it.id] == nil, "duplicate cosmetic " .. it.id)
	table.insert(ITEMS, it)
	BY_ID[it.id] = it
end

function CosmeticCatalog.IsSlot(slot: any): boolean
	return type(slot) == "string" and CosmeticCatalog.SLOT_NAMES[slot] ~= nil
end

-- the default item id of each slot
function CosmeticCatalog.Defaults(): { [string]: string }
	return table.clone(DEFAULTS)
end

-- items a level reaches (sorted by id for determinism)
function CosmeticCatalog.LevelItems(level: number): { string }
	local out = {}
	for _, it in ITEMS do
		if it.level == level then table.insert(out, it.id) end
	end
	table.sort(out)
	return out
end

function CosmeticCatalog.OfSlot(slot: string): { Item }
	local out = {}
	for _, it in ITEMS do
		if it.slot == slot then table.insert(out, it) end
	end
	table.sort(out, function(a, b)
		local ra, rb = CosmeticCatalog.RARITIES[a.rarity], CosmeticCatalog.RARITIES[b.rarity]
		if a.default ~= b.default then return a.default == true end
		if ra.order ~= rb.order then return ra.order < rb.order end
		return a.id < b.id
	end)
	return out
end

-- loadout (slot -> id, from the network: may be nil, partial or garbage) -> slot -> Item, always complete and valid
function CosmeticCatalog.Resolve(loadout: any): { [string]: Item }
	local out: { [string]: Item } = {}
	for _, slot in CosmeticCatalog.SLOTS do
		local it = type(loadout) == "table" and CosmeticCatalog.Get(loadout[slot]) or nil
		if not it or it.slot ~= slot then
			it = BY_ID[DEFAULTS[slot]]
		end
		out[slot] = it :: Item
	end
	return out
end

-- "how you get it" line for the UI
function CosmeticCatalog.SourceText(it: Item): string
	if it.default then return "GRATIS" end
	local parts = {}
	if it.price then table.insert(parts, "TIENDA") end
	if it.level then table.insert(parts, "NIVEL " .. it.level) end
	if it.challenge then table.insert(parts, "PREMIO DE SEMANALES") end
	if it.box then table.insert(parts, "CAJAS") end
	return table.concat(parts, " · ")
end

return CosmeticCatalog
