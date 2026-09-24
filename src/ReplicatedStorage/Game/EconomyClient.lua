--!strict
-- EconomyClient.lua: the client's view of the server profile (XP, Créditos, challenges; later inventory and boxes).
-- It never decides anything: it caches what the server sends (GetProfile / ProfileUpdate) and forwards requests to
-- the server's RemoteFunctions, returning their { ok, error?, ... } answer.
local RS = game:GetService("ReplicatedStorage")

local EconomyClient = {}

local profile: { [string]: any }? = nil
local offset = 0 -- server os.time() - local os.time() (countdowns to the UTC reset)
local listeners: { (any, any) -> () } = {}
local started = false

local function remotes(): Instance?
	return RS:FindFirstChild("Remotes") or RS:WaitForChild("Remotes", 8)
end

local function notify(p: any, reward: any)
	for _, fn in table.clone(listeners) do
		task.spawn(fn, p, reward)
	end
end

function EconomyClient.Set(p: { [string]: any })
	profile = p
	if type(p.serverTime) == "number" then
		offset = p.serverTime - os.time()
	end
end

function EconomyClient.Get(): { [string]: any }?
	return profile
end

-- server-aligned unix time
function EconomyClient.Now(): number
	return os.time() + offset
end

-- fn(profile, reward?) on every server push; returns a disconnect function
function EconomyClient.OnUpdate(fn: (any, any) -> ()): () -> ()
	table.insert(listeners, fn)
	return function()
		local i = table.find(listeners, fn)
		if i then table.remove(listeners, i) end
	end
end

-- fetch the profile now (yields); also notifies listeners
function EconomyClient.Refresh(): { [string]: any }?
	local rem = remotes()
	local rf = rem and rem:WaitForChild("GetProfile", 5) :: RemoteFunction?
	if not rf then return nil end
	local ok, data = pcall(function() return (rf :: RemoteFunction):InvokeServer() end)
	if ok and type(data) == "table" then
		EconomyClient.Set(data)
		notify(data, nil)
		return data
	end
	return nil
end

-- RemoteFunction request (CosmeticsRequest / LootboxRequest ...). Never throws.
function EconomyClient.Request(remoteName: string, action: string, arg: any?): { [string]: any }
	local rem = remotes()
	local rf = rem and rem:WaitForChild(remoteName, 5) :: RemoteFunction?
	if not rf then return { ok = false, error = "SIN CONEXIÓN CON EL SERVIDOR" } end
	local ok, res = pcall(function() return (rf :: RemoteFunction):InvokeServer(action, arg) end)
	if not ok or type(res) ~= "table" then
		return { ok = false, error = "ERROR DEL SERVIDOR" }
	end
	return res
end

function EconomyClient.Start()
	if started then return end
	started = true
	task.spawn(function()
		local rem = remotes()
		local ev = rem and rem:WaitForChild("ProfileUpdate", 15) :: RemoteEvent?
		if not ev then return end
		(ev :: RemoteEvent).OnClientEvent:Connect(function(msg: any)
			if type(msg) == "table" and type(msg.profile) == "table" then
				EconomyClient.Set(msg.profile)
				notify(msg.profile, msg.reward)
			end
		end)
	end)
end

return EconomyClient
