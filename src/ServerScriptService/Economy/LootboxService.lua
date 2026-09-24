--!strict
-- LootboxService.lua (server): wires the LootboxRequest RemoteFunction to LootboxRequests with the live
-- dependencies (ProfileStore, PolicyService, the server's Random), installs the box rewards into Rewards and adds the
-- boxes to the profile summary (docs/lootboxes.md §8, §11).
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local Config = require(RS:WaitForChild("Economy"):WaitForChild("LootboxConfig"))
local ProfileStore = require(script.Parent:WaitForChild("ProfileStore"))
local Rewards = require(script.Parent:WaitForChild("Rewards"))
local Lootboxes = require(script.Parent:WaitForChild("Lootboxes"))
local LootboxRequests = require(script.Parent:WaitForChild("LootboxRequests"))
local Policy = require(script.Parent:WaitForChild("Policy"))

local LootboxService = {}

local rng = Random.new() -- seeded by the engine; the client never influences a roll

local LIVE: LootboxRequests.Deps = {
	profile = function(p: Player) return ProfileStore.WaitFor(p, 10) end,
	save = function(p: Player) return ProfileStore.SaveNow(p) end,
	push = function(p: Player) ProfileStore.Push(p, nil) end,
	canSpend = ProfileStore.CanSpend,
	restricted = Policy.IsRestricted,
	rng = rng,
	now = os.time,
	clock = os.clock,
}

local started = false
function LootboxService.Init()
	if started then return end
	started = true
	Policy.Start()
	Lootboxes.Install(Rewards, rng)
	table.insert(ProfileStore.SummaryHooks, function(_p: Player, profile: any, out: any)
		out.boxes = table.clone(profile.boxes)
	end)
	local rf = ProfileStore.Remote("RemoteFunction", "LootboxRequest") :: RemoteFunction
	rf.OnServerInvoke = function(p: Player, action: any, arg: any)
		local res = LootboxRequests.Guarded(LIVE, p, action, arg)
		if (action == "ack" or action == "dupMode") and type(res) == "table" and res.ok then ProfileStore.MarkDirty(p) end
		return res
	end
	-- Robux: prepared, DISABLED (LootboxConfig.ROBUX_ENABLED). Enabling needs docs/lootboxes.md §7.3 first.
	if Config.ROBUX_ENABLED then
		warn("[LootboxService] ROBUX_ENABLED is set but no ProcessReceipt is wired: see docs/lootboxes.md §7.3")
	end
	Players.PlayerRemoving:Connect(LootboxRequests.Forget)
end

return LootboxService
