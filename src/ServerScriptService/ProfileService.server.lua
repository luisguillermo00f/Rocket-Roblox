-- ProfileService.server.lua: persistent player profile (career stats + XP) in a DataStore.
-- Online matches are run by the server, which reports results itself through the ServerSubmit BindableEvent (child
-- of this script). The old client report (SubmitMatch) is still accepted for local matches: its numbers are
-- sanity-clamped per match and rate-limited either way.
-- If DataStores are unavailable (e.g. Studio without API access) the profile still works for the session and
-- reports persistent = false so the UI can say so.
local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local RS = game:GetService("ReplicatedStorage")

local remotes = RS:FindFirstChild("Remotes") or Instance.new("Folder")
remotes.Name = "Remotes"
remotes.Parent = RS
local function remote(class: string, name: string): Instance
	local r = remotes:FindFirstChild(name)
	if not r then
		r = Instance.new(class)
		r.Name = name
		r.Parent = remotes
	end
	return r
end
local getProfile = remote("RemoteFunction", "GetProfile") :: RemoteFunction
local submitMatch = remote("RemoteEvent", "SubmitMatch") :: RemoteEvent
local saveSettings = remote("RemoteEvent", "SaveSettings") :: RemoteEvent

local store: DataStore? = nil
pcall(function()
	store = DataStoreService:GetDataStore("SupersonicProfile_v1")
end)

local DEFAULT = {
	matches = 0, wins = 0, losses = 0, draws = 0,
	goals = 0, assists = 0, saves = 0, epicSaves = 0, shots = 0, clears = 0, demos = 0, aerials = 0,
	points = 0, xp = 0, bestKmh = 0, streak = 0, bestStreak = 0, pinches = 0, bestPinchKmh = 0,
}
-- per-match ceilings (a 5-minute match can't legitimately exceed these)
local LIMITS = { goals = 40, assists = 40, saves = 60, epicSaves = 40, shots = 100, clears = 100, demos = 60, aerials = 100, pinches = 60, points = 20000 }

local profiles: { [Player]: { [string]: number } } = {}
local persistent: { [Player]: boolean } = {}
local lastSubmit: { [Player]: number } = {}

local function key(p: Player): string
	return "u_" .. p.UserId
end

local function load(p: Player)
	local data = table.clone(DEFAULT)
	local ok = false
	if store then
		local success, res = pcall(function()
			return (store :: DataStore):GetAsync(key(p))
		end)
		if success then
			ok = true
			if type(res) == "table" then
				for k, v in res do
					if DEFAULT[k] ~= nil and type(v) == "number" then
						data[k] = v
					end
				end
				if type(res.settings) == "table" then
					data.settings = res.settings
				end
			end
		else
			warn("[ProfileService] DataStore unavailable, session-only profile:", res)
		end
	end
	profiles[p] = data
	persistent[p] = ok
end

local function save(p: Player)
	local data = profiles[p]
	if not data or not persistent[p] or not store then
		return
	end
	local success, err = pcall(function()
		(store :: DataStore):SetAsync(key(p), data)
	end)
	if not success then
		warn("[ProfileService] save failed:", err)
	end
end

Players.PlayerAdded:Connect(load)
for _, p in Players:GetPlayers() do
	task.spawn(load, p)
end
Players.PlayerRemoving:Connect(function(p)
	save(p)
	profiles[p] = nil
	persistent[p] = nil
	lastSubmit[p] = nil
end)
game:BindToClose(function()
	for _, p in Players:GetPlayers() do
		save(p)
	end
end)

getProfile.OnServerInvoke = function(p: Player)
	local t0 = os.clock()
	while not profiles[p] and os.clock() - t0 < 10 do
		task.wait(0.1)
	end
	local d = profiles[p]
	if not d then
		return nil
	end
	local out: { [string]: any } = table.clone(d)
	out.persistent = persistent[p] == true
	return out
end

local function num(v: any, lo: number, hi: number): number
	if type(v) ~= "number" or v ~= v then
		return 0
	end
	return math.clamp(math.floor(v), lo, hi)
end

local function applyResult(p: Player, r: any, trusted: boolean)
	local d = profiles[p]
	if not d or type(r) ~= "table" then
		return
	end
	local now = os.clock()
	if not trusted and lastSubmit[p] and now - lastSubmit[p] < 20 then
		return -- a real match lasts minutes
	end
	lastSubmit[p] = now
	local result = r.result
	if result ~= "win" and result ~= "loss" and result ~= "draw" then
		return
	end
	d.matches += 1
	if result == "win" then
		d.wins += 1
		d.streak += 1
		d.bestStreak = math.max(d.bestStreak, d.streak)
	elseif result == "loss" then
		d.losses += 1
		d.streak = 0
	else
		d.draws += 1
		d.streak = 0
	end
	for k, lim in LIMITS do
		d[k] += num(r[k], 0, lim)
	end
	d.bestKmh = math.max(d.bestKmh, num(r.bestKmh, 0, 400))
	d.bestPinchKmh = math.max(d.bestPinchKmh, num(r.bestPinchKmh, 0, 400))
	d.xp += num(r.points, 0, 20000) + 30 + (if result == "win" then 100 else 0)
	save(p)
end

submitMatch.OnServerEvent:Connect(function(p: Player, r: any)
	applyResult(p, r, false)
end)

-- server-run matches (PartyMinigameService) report here
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
	local d = profiles[p]
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
end)
Players.PlayerRemoving:Connect(function(p) lastSettings[p] = nil end)
