--!strict
-- Policy.lua (server): PolicyService's ArePaidRandomItemsRestricted per player (docs/lootboxes.md §7.2).
-- Fails closed: until PolicyService has answered - or when it errors - the player counts as RESTRICTED (no way to
-- pay for boxes; RESTRICTED_MODE decides what earned boxes do). A failed lookup is retried after POLICY_RETRY s.
-- Policy.Fetch can be replaced in tests.
local Players = game:GetService("Players")
local PolicyService = game:GetService("PolicyService")
local RS = game:GetService("ReplicatedStorage")
local Config = require(RS:WaitForChild("Economy"):WaitForChild("LootboxConfig"))

local Policy = {}

type Entry = { restricted: boolean, ok: boolean, at: number }
local cache: { [Player]: Entry } = {}

Policy.Fetch = function(player: Player): any
	return PolicyService:GetPolicyInfoForPlayerAsync(player)
end

-- pure: fetch -> restricted?, answered?  (errors and odd answers count as restricted)
function Policy.Evaluate(fetch: (Player) -> any, player: Player): (boolean, boolean)
	for _ = 1, 3 do
		local ok, info = pcall(fetch, player)
		if ok and type(info) == "table" and type(info.ArePaidRandomItemsRestricted) == "boolean" then
			return info.ArePaidRandomItemsRestricted, true
		end
	end
	return true, false
end

function Policy.Refresh(player: Player)
	local restricted, ok = Policy.Evaluate(Policy.Fetch, player)
	cache[player] = { restricted = restricted, ok = ok, at = os.clock() }
	if not ok then
		warn("[Policy] PolicyService failed for", player.Name, "- treated as restricted until it answers")
	end
end

function Policy.IsRestricted(player: Player): boolean
	local e = cache[player]
	if not e then return true end
	if not e.ok and os.clock() - e.at > Config.POLICY_RETRY then
		e.at = os.clock() -- one retry at a time
		task.spawn(Policy.Refresh, player)
	end
	return e.restricted
end

local started = false
function Policy.Start()
	if started then return end
	started = true
	Players.PlayerAdded:Connect(function(p) task.spawn(Policy.Refresh, p) end)
	for _, p in Players:GetPlayers() do task.spawn(Policy.Refresh, p) end
	Players.PlayerRemoving:Connect(function(p) cache[p] = nil end)
end

return Policy
