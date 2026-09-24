--!strict
-- LootboxRequests.lua (server, pure): one LootboxRequest, given its dependencies (docs/lootboxes.md §8, §11).
--   state | open { box, requestId, oddsVersion } | buy { box, requestId, oddsVersion } | redeem { box, item, requestId }
--   | convert { box, requestId } | dupMode "fragments"|"credits" | ack
-- Order for anything that changes the profile: validate + apply in memory (Lootboxes, no yields) -> SAVE and wait ->
-- answer. If the save fails nothing is undone (undoing would let a player re-roll until they like the result): the
-- change stays in memory and the autosave / leave save writes it. One request at a time per player ("busy" makes the
-- client retry with the SAME requestId, which then returns the stored result instead of rolling again).
-- LootboxService passes the live dependencies (ProfileStore, PolicyService, Random.new()); the tests pass fakes.
local RS = game:GetService("ReplicatedStorage")
local Config = require(RS:WaitForChild("Economy"):WaitForChild("LootboxConfig"))
local Lootboxes = require(script.Parent:WaitForChild("Lootboxes"))

local LootboxRequests = {}

local busy: { [any]: boolean } = {}
local lastOpen: { [any]: number } = {}
local lastBuy: { [any]: number } = {}

export type Deps = {
	profile: (any) -> any?, -- the loaded profile (may wait)
	save: (any) -> boolean, -- persist now (yields)
	push: (any) -> (), -- tell the client its profile changed
	canSpend: (any) -> boolean,
	restricted: (any) -> boolean, -- PolicyService: ArePaidRandomItemsRestricted (fail-closed)
	rng: any,
	now: () -> number,
	clock: () -> number,
}

local function gap(map: { [any]: number }, p: any, seconds: number, now: number): boolean
	if map[p] and now - map[p] < seconds then return false end
	map[p] = now
	return true
end

local function view(deps: Deps, p: any, profile: any): any
	local v = Lootboxes.View(profile, deps.restricted(p), deps.now())
	v.ok = true
	v.canSpend = deps.canSpend(p)
	return v
end

-- one request (pure apart from deps; the tests drive it with fakes)
function LootboxRequests.Handle(deps: Deps, p: any, action: any, arg: any): any
	local profile = deps.profile(p)
	if not profile then return { ok = false, error = "PERFIL NO CARGADO" } end
	if action == "state" then
		return view(deps, p, profile)
	elseif action == "ack" then
		Lootboxes.Ack(profile)
		return { ok = true }
	elseif action == "dupMode" then
		return Lootboxes.SetDupMode(profile, arg)
	end
	if type(arg) ~= "table" then return { ok = false, error = "PETICIÓN NO VÁLIDA" } end
	if not deps.canSpend(p) then
		return { ok = false, error = "TU PERFIL NO SE ESTÁ GUARDANDO: NO SE PUEDE USAR AHORA" }
	end
	local ctx = { now = deps.now(), rng = deps.rng, restricted = deps.restricted(p), mode = Config.RESTRICTED_MODE }
	local res
	if action == "open" then
		if not gap(lastOpen, p, Config.OPEN_GAP, deps.clock()) then return { ok = false, error = "busy" } end
		res = Lootboxes.Open(profile, arg.box, arg.requestId, arg.oddsVersion, ctx)
	elseif action == "buy" then
		if not gap(lastBuy, p, Config.BUY_GAP, deps.clock()) then return { ok = false, error = "busy" } end
		res = Lootboxes.Buy(profile, arg.box, arg.requestId, arg.oddsVersion, ctx)
	elseif action == "redeem" then
		res = Lootboxes.Redeem(profile, arg.box, arg.item, arg.requestId, ctx)
	elseif action == "convert" then
		res = Lootboxes.Convert(profile, arg.box, arg.requestId, ctx)
	else
		return { ok = false, error = "ACCIÓN NO VÁLIDA" }
	end
	if res.ok then
		-- persisted BEFORE the client hears about it (a disconnect mid-animation loses nothing). A failed save undoes
		-- nothing: the result stays in memory for the autosave / leave save.
		deps.save(p)
		deps.push(p)
	end
	local out = table.clone(res)
	out.state = view(deps, p, profile)
	return out
end

-- one request at a time per player: while one waits for its save, any other gets "busy" (the client retries with the
-- same requestId). Errors never leak to the client.
function LootboxRequests.Guarded(deps: Deps, p: any, action: any, arg: any): any
	if busy[p] then return { ok = false, error = "busy" } end
	busy[p] = true
	local ok, res = pcall(LootboxRequests.Handle, deps, p, action, arg)
	busy[p] = nil
	if not ok then
		warn("[LootboxService] request failed:", res)
		return { ok = false, error = "ERROR DEL SERVIDOR" }
	end
	return res
end


function LootboxRequests.Forget(p: any)
	busy[p] = nil
	lastOpen[p] = nil
	lastBuy[p] = nil
end

return LootboxRequests
