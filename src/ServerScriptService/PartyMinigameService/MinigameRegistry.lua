--!strict
-- MinigameRegistry.lua (server): the minigames the server can run. Each entry is a minigame module that implements
-- the common interface:
--   Id, DisplayName, Description, MinPlayers, MaxPlayers, MaxDuration, SharedModule (name in Party.MinigameShared),
--   BotController (optional), new(session) -> instance with
--   AssignTeams(members), Setup(), Start(), Update(dt), PreTick(dt), HandlePlayerJoin(member), HandlePlayerLeave(member),
--   HandlePlayerEliminated(member), End(), Cleanup(), GetScore(member), IsFinished(), GetPlacements(),
--   ControlsLocked(), BallVisible(), PublicState()
-- Adding a minigame = one module in Minigames + one line here.
local Minigames = script.Parent:WaitForChild("Minigames")

local MinigameRegistry = {}
local ORDER: { string } = {}
local DEFS: { [string]: any } = {}

local REQUIRED = { "Id", "DisplayName", "Description", "MinPlayers", "MaxPlayers", "MaxDuration", "SharedModule", "new" }

function MinigameRegistry.Register(def: any)
	for _, k in REQUIRED do
		assert(def[k] ~= nil, ("minigame %s is missing %s"):format(tostring(def.Id), k))
	end
	assert(def.MaxDuration <= 80, def.Id .. ": minigames last 80 s at most")
	if not DEFS[def.Id] then
		table.insert(ORDER, def.Id)
	end
	DEFS[def.Id] = def
end

function MinigameRegistry.Get(id: string): any
	return DEFS[id]
end

function MinigameRegistry.All(): { any }
	local out = {}
	for _, id in ORDER do
		table.insert(out, DEFS[id])
	end
	return out
end

-- public catalogue for clients
function MinigameRegistry.Catalogue(): { any }
	local out = {}
	for _, id in ORDER do
		local d = DEFS[id]
		table.insert(out, { id = d.Id, name = d.DisplayName, description = d.Description, minPlayers = d.MinPlayers, maxPlayers = d.MaxPlayers, maxDuration = d.MaxDuration })
	end
	return out
end

MinigameRegistry.Register(require(Minigames:WaitForChild("BeachVolley")))
MinigameRegistry.Register(require(Minigames:WaitForChild("SumoRemix")))
MinigameRegistry.Register(require(Minigames:WaitForChild("SkyRingRush")))
MinigameRegistry.Register(require(Minigames:WaitForChild("KingOfTheHill")))
for _, name in { "Heatseeker", "Derby", "Infection", "Minigolf" } do
	local mod = Minigames:FindFirstChild(name)
	if mod then
		local ok, def = pcall(require, mod)
		if ok then MinigameRegistry.Register(def) else warn("[MinigameRegistry] " .. name .. ": " .. tostring(def)) end
	end
end

return MinigameRegistry
