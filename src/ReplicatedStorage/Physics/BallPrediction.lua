--!strict
-- BallPrediction.lua: port of RocketSim BallPredTracker.
-- Keeps a ball-only world and a buffer of predicted ball states (one per tick). When the real ball still
-- matches the prediction for the elapsed ticks, the buffer is shifted and only the tail is simulated;
-- otherwise the whole horizon is re-simulated.
local C = require(script.Parent.PhysicsConstants)
local World = require(script.Parent.World)
local BallPhysics = require(script.Parent.BallPhysics)

local BT = C.BT_TO_UU

local BallPrediction = {}
BallPrediction.__index = BallPrediction

export type PredState = { pos: Vector3, vel: Vector3, angVel: Vector3 } -- UU

function BallPrediction.new(numPredTicks: number?)
	return setmetatable({
		numPredTicks = numPredTicks or 720, -- 6 s at 120 Hz
		predData = {} :: { PredState },
		world = World.new({ boostPads = false }),
		lastUpdateTickCount = 0,
	}, BallPrediction)
end

local function snapshot(ball: any): PredState
	local b = ball.body
	return { pos = b.pos * BT, vel = b.vel * BT, angVel = b.angVel }
end

-- BallState::Matches with RocketSim's default margins
local function matches(a: PredState, b: PredState): boolean
	return (a.pos - b.pos).Magnitude < 4 and (a.vel - b.vel).Magnitude < 1 and (a.angVel - b.angVel).Magnitude < 0.02
end

function BallPrediction.ForceUpdateAll(self: any, s: PredState)
	local w = self.world
	BallPhysics.SetState(w.ball, s.pos, s.vel, s.angVel)
	table.clear(self.predData)
	self.predData[1] = s
	for i = 2, self.numPredTicks do
		w:Step()
		self.predData[i] = snapshot(w.ball)
	end
end

function BallPrediction.Update(self: any, realWorld: any)
	local cur = snapshot(realWorld.ball)
	local ticksSince = realWorld.tickCount - self.lastUpdateTickCount
	local data = self.predData
	local needsFull = true
	if ticksSince >= 0 and ticksSince < #data then
		local idx = ticksSince + 1
		if matches(data[idx], cur) then
			needsFull = false
			if ticksSince > 0 then
				local shifted = table.move(data, idx, #data, 1, {})
				self.predData = shifted
				local w = self.world
				local last = shifted[#shifted]
				BallPhysics.SetState(w.ball, last.pos, last.vel, last.angVel)
				while #shifted < self.numPredTicks do
					w:Step()
					table.insert(shifted, snapshot(w.ball))
				end
			end
		end
	end
	if needsFull then
		BallPrediction.ForceUpdateAll(self, cur)
	end
	self.lastUpdateTickCount = realWorld.tickCount
end

function BallPrediction.GetStateForTime(self: any, t: number): PredState?
	local n = #self.predData
	if n == 0 then
		return nil
	end
	local idx = math.clamp(math.floor(t / C.TICK_TIME), 0, n - 1) + 1
	return self.predData[idx]
end

return BallPrediction
