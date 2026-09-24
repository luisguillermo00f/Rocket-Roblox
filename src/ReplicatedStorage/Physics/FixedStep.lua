--!strict
-- FixedStep.lua: framerate-independent 120 Hz accumulator. Returns the render interpolation alpha.
local C = require(script.Parent.PhysicsConstants)

local FixedStep = {}
FixedStep.__index = FixedStep

local MAX_TICKS_PER_FRAME = 8 -- avoids a spiral of death after a hitch

function FixedStep.new()
	return setmetatable({ accumulator = 0, tickCount = 0 }, FixedStep)
end

function FixedStep.Advance(self: any, frameDt: number, tick: (number) -> ()): number
	self.accumulator += math.min(frameDt, C.TICK_TIME * MAX_TICKS_PER_FRAME)
	while self.accumulator >= C.TICK_TIME do
		self.accumulator -= C.TICK_TIME
		self.tickCount += 1
		tick(self.tickCount)
	end
	return self.accumulator / C.TICK_TIME
end

return FixedStep
