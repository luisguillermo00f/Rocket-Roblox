--!strict
-- MinigameTimer.lua: phase timing on the shared server clock (workspace:GetServerTimeNow). Clients receive
-- startTime / endTime and compute what they show from the same clock, so displays never drift.
local MinigameTimer = {}
MinigameTimer.__index = MinigameTimer

local function now(): number
	return workspace:GetServerTimeNow()
end

function MinigameTimer.new()
	return setmetatable({ phase = "", startTime = now(), endTime = math.huge }, MinigameTimer)
end

-- duration nil = open ended
function MinigameTimer.Begin(self: any, phase: string, duration: number?)
	self.phase = phase
	self.startTime = now()
	self.endTime = if duration then self.startTime + duration else math.huge
end

function MinigameTimer.Extend(self: any, endTime: number)
	self.endTime = endTime
end

function MinigameTimer.Elapsed(self: any): number
	return now() - self.startTime
end

function MinigameTimer.Remaining(self: any): number
	return math.max(0, self.endTime - now())
end

function MinigameTimer.Expired(self: any): boolean
	return now() >= self.endTime
end

function MinigameTimer.Now(): number
	return now()
end

return MinigameTimer
