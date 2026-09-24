--!strict
-- CosmeticsService.lua (server): the CosmeticsRequest RemoteFunction (state / buy / equip) and the loadout other
-- server code sends to clients (docs/cosmetics.md §6, §7). All rules live in Inventory; this adds the player-level
-- guards: one request at a time per player, a rate limit, and spending only on a profile that is really saved.
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local Economy = RS:WaitForChild("Economy")
local Catalog = require(Economy:WaitForChild("CosmeticCatalog"))
local ShopRotation = require(Economy:WaitForChild("ShopRotation"))
local ProfileStore = require(script.Parent:WaitForChild("ProfileStore"))
local Inventory = require(script.Parent:WaitForChild("Inventory"))
local Rewards = require(script.Parent:WaitForChild("Rewards"))

local CosmeticsService = {}

local BUY_GAP = 1 -- s between purchases
local EQUIP_BUDGET = 5 -- equips per second

local busy: { [Player]: boolean } = {}
local lastBuy: { [Player]: number } = {}
local equipWindow: { [Player]: { t: number, n: number } } = {}

-- loadout ids of a player (defaults when the profile isn't loaded); bots have none (clients use the defaults)
function CosmeticsService.LoadoutFor(player: Player?): { [string]: string }
	local profile = player and ProfileStore.Get(player)
	return Inventory.Loadout(profile)
end

-- the body template ("Octane" / "Troll") of a loadout, for code that still passes a skin name
function CosmeticsService.SkinOf(loadout: { [string]: string }): string
	local it = Catalog.Get(loadout.body)
	return if it then it.params.template else "Octane"
end

local function state(p: Player, profile: any): { [string]: any }
	return {
		ok = true, credits = profile.credits, owned = Inventory.OwnedList(profile), equipped = Inventory.Loadout(profile),
		shop = ShopRotation.View(os.time()), canSpend = ProfileStore.CanSpend(p),
	}
end

local function handle(p: Player, action: any, arg: any): { [string]: any }
	local profile = ProfileStore.WaitFor(p, 10)
	if not profile then return { ok = false, error = "PERFIL NO CARGADO" } end
	if action == "state" then
		return state(p, profile)
	elseif action == "buy" then
		if not ProfileStore.CanSpend(p) then
			return { ok = false, error = "TU PERFIL NO SE ESTÁ GUARDANDO: NO SE PUEDE COMPRAR AHORA" }
		end
		local now = os.clock()
		if lastBuy[p] and now - lastBuy[p] < BUY_GAP then return { ok = false, error = "ESPERA UN MOMENTO" } end
		lastBuy[p] = now
		local ok, err, price = Inventory.Buy(profile, arg, os.time())
		if not ok then return { ok = false, error = err } end
		ProfileStore.SaveNow(p) -- the credits are gone: persist before answering
		ProfileStore.Push(p, nil)
		local out = state(p, profile)
		out.bought, out.price = arg, price
		return out
	elseif action == "equip" then
		local now = os.clock()
		local w = equipWindow[p]
		if not w or now - w.t > 1 then
			w = { t = now, n = 0 }
			equipWindow[p] = w :: any
		end
		local win = w :: { t: number, n: number }
		win.n += 1
		if win.n > EQUIP_BUDGET then return { ok = false, error = "ESPERA UN MOMENTO" } end
		if type(arg) ~= "table" then return { ok = false, error = "PETICIÓN NO VÁLIDA" } end
		local ok, err = Inventory.Equip(profile, arg.slot, arg.id)
		if not ok then return { ok = false, error = err } end
		ProfileStore.MarkDirty(p)
		ProfileStore.Push(p, nil) -- every client-side copy of the loadout (menu car, next match) follows at once
		return { ok = true, equipped = Inventory.Loadout(profile) }
	end
	return { ok = false, error = "ACCIÓN NO VÁLIDA" }
end

local started = false
function CosmeticsService.Init()
	if started then return end
	started = true
	Inventory.Install(Rewards)
	-- the summary (GetProfile / ProfileUpdate) carries the inventory too
	table.insert(ProfileStore.SummaryHooks, function(_p: Player, profile: any, out: any)
		out.owned = Inventory.OwnedList(profile)
		out.equipped = Inventory.Loadout(profile)
	end)
	local rf = ProfileStore.Remote("RemoteFunction", "CosmeticsRequest") :: RemoteFunction
	rf.OnServerInvoke = function(p: Player, action: any, arg: any)
		if busy[p] then return { ok = false, error = "busy" } end
		busy[p] = true
		local ok, res = pcall(handle, p, action, arg)
		busy[p] = nil
		if not ok then
			warn("[CosmeticsService] request failed:", res)
			return { ok = false, error = "ERROR DEL SERVIDOR" }
		end
		return res
	end
	Players.PlayerRemoving:Connect(function(p)
		busy[p] = nil
		lastBuy[p] = nil
		equipWindow[p] = nil
	end)
end

return CosmeticsService
