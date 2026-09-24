--!strict
-- CodeDirectory.lua: party codes (RR-####) and private-room codes (SL-####) that work from ANY server of the game.
-- Each server writes the codes it hosts to a MemoryStore hash map (code -> place id + server job id), refreshing them
-- while they live and removing them when they close. Joining a code that isn't on this server looks it up and
-- teleports the player straight into the host's server, carrying the code so they're dropped into the group there.
-- Everything is pcall'd: without MemoryStore (Studio with API access off, an outage) codes still work on the server
-- they were created on.
local MemoryStoreService = game:GetService("MemoryStoreService")
local TeleportService = game:GetService("TeleportService")
local RunService = game:GetService("RunService")

local CodeDirectory = {}

local TTL = 60 * 20 -- s a code stays listed without a refresh
local REFRESH = 60 * 5 -- s between refreshes of our live codes

local map: any = nil
pcall(function()
	map = MemoryStoreService:GetHashMap("RocketRobloxCodes_v1")
end)

local owned: { [string]: boolean } = {} -- codes this server hosts
local lastRefresh = 0

local function jobId(): string
	-- Studio play sessions have an empty JobId; give them a stable fake one so lookups never match another server
	return if game.JobId ~= "" then game.JobId else "studio"
end

function CodeDirectory.Available(): boolean
	return map ~= nil and game.JobId ~= ""
end

function CodeDirectory.Register(code: string)
	owned[code] = true
	if not map then return end
	task.spawn(function()
		pcall(function()
			map:SetAsync(code, { placeId = game.PlaceId, jobId = jobId() }, TTL)
		end)
	end)
end

function CodeDirectory.Unregister(code: string)
	owned[code] = nil
	if not map then return end
	task.spawn(function()
		pcall(function()
			map:RemoveAsync(code)
		end)
	end)
end

-- another live server's code? (never answers for our own codes: those are resolved locally first)
function CodeDirectory.Lookup(code: string): any?
	if not map or owned[code] then return nil end
	local ok, v = pcall(function()
		return map:GetAsync(code)
	end)
	if ok and type(v) == "table" and v.jobId ~= jobId() and type(v.placeId) == "number" then
		return v
	end
	return nil
end

-- is a freshly rolled code already taken anywhere?
function CodeDirectory.Taken(code: string): boolean
	if owned[code] then return true end
	return CodeDirectory.Lookup(code) ~= nil
end

-- send the player to the server hosting `code`; `data` arrives as TeleportData (the client re-joins with it)
function CodeDirectory.TeleportTo(player: Player, entry: any, data: any): (boolean, string?)
	if RunService:IsStudio() then
		return false, "ese código es de otro servidor (en Studio no se puede viajar entre servidores)"
	end
	local ok, err = pcall(function()
		local opts = Instance.new("TeleportOptions")
		opts.ServerInstanceId = entry.jobId
		opts:SetTeleportData(data)
		TeleportService:TeleportAsync(entry.placeId, { player }, opts)
	end)
	if not ok then
		return false, "no se pudo viajar al servidor del grupo"
	end
	return true, nil
end

-- keep our codes alive in the directory
function CodeDirectory.Tick()
	if not map then return end
	local now = os.clock()
	if now - lastRefresh < REFRESH then return end
	lastRefresh = now
	for code in owned do
		CodeDirectory.Register(code)
	end
end

-- (pcall: BindToClose only exists on a running server, not when the module is loaded in Studio's edit mode)
pcall(function()
	game:BindToClose(function()
		if not map then return end
		for code in owned do
			pcall(function() map:RemoveAsync(code) end)
		end
	end)
end)

return CodeDirectory
