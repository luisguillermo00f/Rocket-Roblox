-- ProfileService.server.lua: persistent player profile (career stats, XP, Créditos, challenges) - see
-- docs/progression.md. Loading / saving lives in Economy.ProfileStore, the reward rules in Economy.Rewards; this script
-- wires players and remotes to them.
-- Online matches and party minigames are run by the server, which reports results itself through the ServerSubmit
-- BindableEvent (child of this script). The old client report (SubmitMatch) is still accepted for local matches
-- against bots: its numbers are sanity-clamped, it's always classified as the "local" source (low rewards, own daily
-- sub-cap) and rate-limited. The client never sends XP or credits.
-- If DataStores are unavailable (e.g. Studio without API access) the profile still works for the session and
-- reports persistent = false so the UI can say so.
local Players = game:GetService("Players")

local Economy = script.Parent:WaitForChild("Economy")
local ProfileStore = require(Economy:WaitForChild("ProfileStore"))
local Rewards = require(Economy:WaitForChild("Rewards"))
require(Economy:WaitForChild("CosmeticsService")).Init() -- inventory, shop, equip (docs/cosmetics.md)
require(Economy:WaitForChild("LootboxService")).Init() -- lootboxes, PolicyService (docs/lootboxes.md)

local getProfile = ProfileStore.Remote("RemoteFunction", "GetProfile") :: RemoteFunction
local submitMatch = ProfileStore.Remote("RemoteEvent", "SubmitMatch") :: RemoteEvent
local saveSettings = ProfileStore.Remote("RemoteEvent", "SaveSettings") :: RemoteEvent
-- server -> client: { profile = summary, reward = breakdown? } after every reward / purchase (ProfileStore.Push)
ProfileStore.Remote("RemoteEvent", "ProfileUpdate")

local lastSubmit: { [Player]: number } = {}

Players.PlayerAdded:Connect(ProfileStore.Load)
for _, p in Players:GetPlayers() do
	task.spawn(ProfileStore.Load, p)
end
Players.PlayerRemoving:Connect(function(p)
	lastSubmit[p] = nil
	ProfileStore.Release(p)
end)
game:BindToClose(function()
	local pending = 0
	for _, p in ProfileStore.All() do
		pending += 1
		task.spawn(function()
			ProfileStore.Save(p, true)
			pending -= 1
		end)
	end
	local t0 = os.clock()
	while pending > 0 and os.clock() - t0 < 25 do
		task.wait(0.1)
	end
end)

getProfile.OnServerInvoke = function(p: Player)
	if not ProfileStore.WaitFor(p, 10) then
		return nil
	end
	return ProfileStore.Summary(p)
end

local function applyResult(p: Player, r: any, trusted: boolean)
	local d = ProfileStore.Get(p)
	if not d or type(r) ~= "table" then
		return
	end
	if not trusted then
		local now = os.clock()
		if lastSubmit[p] and now - lastSubmit[p] < 20 then
			return -- a real match lasts minutes
		end
		lastSubmit[p] = now
	end
	local breakdown
	if trusted and r.kind == "minigame" then
		breakdown = Rewards.ApplyMinigame(d, r, os.time())
	else
		breakdown = Rewards.ApplyMatch(d, r, trusted, os.time())
	end
	if breakdown then
		ProfileStore.SaveSoon(p)
		ProfileStore.Push(p, breakdown)
	end
end

submitMatch.OnServerEvent:Connect(function(p: Player, r: any)
	applyResult(p, r, false)
end)

-- server-run matches and minigame rounds (PartyMinigameService) report here
local serverSubmit = script:FindFirstChild("ServerSubmit") or Instance.new("BindableEvent")
serverSubmit.Name = "ServerSubmit"
serverSubmit.Parent = script
serverSubmit.Event:Connect(function(p: Player, r: any)
	applyResult(p, r, true)
end)

-- client graphics + camera settings + control bindings: { gfx = {k = bool|string|number}, cam = {...}, binds = {kb, pad} }
local lastSettings: { [Player]: number } = {}
local function cleanTable(t: any, maxKeys: number): { [string]: any }?
	if type(t) ~= "table" then return nil end
	local out, n = {}, 0
	for k, v in t do
		if type(k) ~= "string" or #k > 24 then return nil end
		local tv = type(v)
		if tv == "boolean" or (tv == "number" and v == v and math.abs(v) < 1e4) or (tv == "string" and #v <= 16) then
			out[k] = v
			n += 1
			if n > maxKeys then return nil end
		end
	end
	return out
end
saveSettings.OnServerEvent:Connect(function(p: Player, blob: any)
	local d = ProfileStore.Get(p)
	if not d or type(blob) ~= "table" then return end
	local now = os.clock()
	if lastSettings[p] and now - lastSettings[p] < 1 then return end
	lastSettings[p] = now
	local gfx, cam = cleanTable(blob.gfx, 20), cleanTable(blob.cam, 12)
	if not gfx or not cam then return end
	-- control bindings: { kb = { action = input name }, pad = { ... } } (validated again by the client on load)
	local binds = nil
	if type(blob.binds) == "table" then
		local kb, pad = cleanTable(blob.binds.kb, 32), cleanTable(blob.binds.pad, 32)
		if kb and pad then binds = { kb = kb, pad = pad } end
	end
	d.settings = { gfx = gfx, cam = cam, binds = binds }
	ProfileStore.MarkDirty(p)
end)
Players.PlayerRemoving:Connect(function(p) lastSettings[p] = nil end)
