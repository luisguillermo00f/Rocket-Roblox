--!strict
-- MinigameRegistry.lua (client): how each Party minigame is presented in the lobby (name, tag, colours, blurb).
-- The server's registry is the authority on what can actually be played: the lobby receives its catalogue in the
-- party state and only offers the ids that are in it (the rest show as "PRÓXIMAMENTE").
export type MinigameDef = {
	id: string,
	name: string,
	subtitle: string,
	tag: string,
	tagColor: Color3,
	description: string,
	minPlayers: number,
	maxPlayers: number,
	estimatedSeconds: number,
	enabledByDefault: boolean,
}

local MinigameRegistry = {}
local REGISTRY: { [string]: MinigameDef } = {}
local ORDER: { string } = {}

function MinigameRegistry.Register(def: MinigameDef)
	if not REGISTRY[def.id] then
		table.insert(ORDER, def.id)
	end
	REGISTRY[def.id] = def
end

function MinigameRegistry.GetAll(): { MinigameDef }
	local list = {}
	for _, id in ipairs(ORDER) do
		table.insert(list, REGISTRY[id])
	end
	return list
end

function MinigameRegistry.Get(id: string): MinigameDef?
	return REGISTRY[id]
end

function MinigameRegistry.GetRandom(count: number, poolIds: { string }?): { MinigameDef }
	local sourceIds = poolIds or ORDER
	if #sourceIds == 0 then sourceIds = ORDER end
	local cloned = table.clone(sourceIds)
	local rng = Random.new()
	for i = #cloned, 2, -1 do
		local j = rng:NextInteger(1, i)
		cloned[i], cloned[j] = cloned[j], cloned[i]
	end
	local res = {}
	local n = math.min(count, #cloned)
	for i = 1, n do
		local def = REGISTRY[cloned[i]]
		if def then table.insert(res, def) end
	end
	return res
end

MinigameRegistry.Register({
	id = "beach_volley",
	name = "BEACH VOLLEY",
	subtitle = "UN BOTE Y PASA",
	tag = "EQUIPOS",
	tagColor = Color3.fromRGB(255, 176, 40),
	description = "Voleibol con tu coche. El balón puede tocar la arena una vez por lado: el segundo bote es punto del rival.",
	minPlayers = 2,
	maxPlayers = 4,
	estimatedSeconds = 60,
	enabledByDefault = true,
})

MinigameRegistry.Register({
	id = "sumo_remix",
	name = "SUMO REMIX",
	subtitle = "QUE NO TE SAQUEN",
	tag = "SUPERVIVENCIA",
	tagColor = Color3.fromRGB(255, 75, 75),
	description = "La zona segura se encoge por fases. Quien esté fuera al cerrarse queda eliminado. Gana el último.",
	minPlayers = 2,
	maxPlayers = 4,
	estimatedSeconds = 70,
	enabledByDefault = true,
})

MinigameRegistry.Register({
	id = "sky_ring_rush",
	name = "SKY RING RUSH",
	subtitle = "ANILLOS EN EL CIELO",
	tag = "CARRERA",
	tagColor = Color3.fromRGB(45, 150, 255),
	description = "Carrera aérea por anillos en orden. Atajos para los valientes. Gana quien llegue más lejos.",
	minPlayers = 2,
	maxPlayers = 4,
	estimatedSeconds = 75,
	enabledByDefault = true,
})

MinigameRegistry.Register({
	id = "king_of_the_hill",
	name = "REY DE LA COLINA",
	subtitle = "DOMINA LA ZONA",
	tag = "CONTROL",
	tagColor = Color3.fromRGB(180, 70, 255),
	description = "Suma segundos dentro de la colina. Si hay dos dentro, nadie suma. La colina cambia de sitio.",
	minPlayers = 2,
	maxPlayers = 4,
	estimatedSeconds = 70,
	enabledByDefault = true,
})

MinigameRegistry.Register({
	id = "heatseeker",
	name = "HEATSEEKER",
	subtitle = "EL BALÓN TE BUSCA",
	tag = "EQUIPOS",
	tagColor = Color3.fromRGB(255, 90, 40),
	description = "Cada toque manda el balón solo hacia la portería rival y lo acelera. Ponte en medio y devuélvelo. Mapa: Cúpula Neón.",
	minPlayers = 2,
	maxPlayers = 4,
	estimatedSeconds = 75,
	enabledByDefault = true,
})

MinigameRegistry.Register({
	id = "derby",
	name = "DERBI DE DEMOLICIONES",
	subtitle = "CHOCA A TODA VELOCIDAD",
	tag = "TODOS CONTRA TODOS",
	tagColor = Color3.fromRGB(255, 60, 60),
	description = "Sin balón: demuele a los demás yendo supersónico. Cada demolición suma. Mapa: el Coliseo.",
	minPlayers = 2,
	maxPlayers = 4,
	estimatedSeconds = 75,
	enabledByDefault = true,
})

MinigameRegistry.Register({
	id = "infection",
	name = "PILLA-PILLA INFECCIÓN",
	subtitle = "QUE NO TE TOQUEN",
	tag = "PERSECUCIÓN",
	tagColor = Color3.fromRGB(120, 255, 90),
	description = "Uno empieza infectado y contagia al chocar. Los sanos suman puntos cada segundo; los infectados, por contagio. Mapa: Ciudad Neón.",
	minPlayers = 2,
	maxPlayers = 4,
	estimatedSeconds = 70,
	enabledByDefault = true,
})

MinigameRegistry.Register({
	id = "minigolf",
	name = "MINIGOLF GIGANTE",
	subtitle = "MENOS TOQUES GANA",
	tag = "PRECISIÓN",
	tagColor = Color3.fromRGB(60, 210, 120),
	description = "Tres hoyos gigantes con rampas, curvas y puentes. Cada toque a tu balón es un golpe. Gana quien use menos.",
	minPlayers = 2,
	maxPlayers = 4,
	estimatedSeconds = 78,
	enabledByDefault = true,
})

return MinigameRegistry
