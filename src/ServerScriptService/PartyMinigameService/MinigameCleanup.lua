--!strict
-- MinigameCleanup.lua: collects everything a round creates (connections, instances, threads, callbacks) and
-- releases it all exactly once. Every session and every minigame owns one.
local MinigameCleanup = {}
MinigameCleanup.__index = MinigameCleanup

function MinigameCleanup.new()
	return setmetatable({ items = {}, done = false }, MinigameCleanup)
end

function MinigameCleanup.Add<T>(self: any, item: T): T
	if self.done then
		-- adding after cleanup: release immediately so nothing leaks
		MinigameCleanup._release(item)
		return item
	end
	table.insert(self.items, item)
	return item
end

function MinigameCleanup._release(item: any)
	local t = typeof(item)
	if t == "RBXScriptConnection" then
		item:Disconnect()
	elseif t == "Instance" then
		item:Destroy()
	elseif t == "thread" then
		pcall(task.cancel, item)
	elseif t == "function" then
		local ok, err = pcall(item)
		if not ok then warn("[MinigameCleanup] cleanup callback failed:", err) end
	elseif t == "table" and type(item.Destroy) == "function" then
		pcall(item.Destroy, item)
	end
end

function MinigameCleanup.Clean(self: any)
	if self.done then return end
	self.done = true
	-- reverse order: things created last are released first
	for i = #self.items, 1, -1 do
		MinigameCleanup._release(self.items[i])
	end
	table.clear(self.items)
end

return MinigameCleanup
