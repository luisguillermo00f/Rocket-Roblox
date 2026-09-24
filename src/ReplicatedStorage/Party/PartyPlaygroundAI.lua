--!strict
-- PartyPlaygroundAI.lua: Autonomous, playful driving behavior for friends/bots in the Party Playground.
-- Patrols ramps, hits the giant party ball, smashes Lucky Blocks, and does stunt jumps.

local PartyConfig = require(script.Parent.PartyConfig)

local PartyPlaygroundAI = {}
PartyPlaygroundAI.__index = PartyPlaygroundAI

local ORIGIN = PartyConfig.ORIGIN

function PartyPlaygroundAI.new(carPhys: any, slotIndex: number)
	local self = setmetatable({}, PartyPlaygroundAI)
	self.car = carPhys
	self.slotIndex = slotIndex
	self.state = "explore"
	self.stateTime = 0
	self.targetPos = ORIGIN + Vector3.new(0, 0, 0)
	self.nextAction = os.clock() + slotIndex * 0.8
	return self
end

function PartyPlaygroundAI:Update(dt: number, partyBall: Part?, luckyBlocks: any?)
	self.stateTime += dt

	-- Pick new playful target every 3-5 seconds
	if os.clock() > self.nextAction then
		self.nextAction = os.clock() + math.random(30, 55) / 10
		local roll = math.random(1, 4)

		if roll == 1 and partyBall and partyBall.Parent then
			-- Chase the giant bouncy ball
			self.state = "ball"
			self.targetPos = partyBall.Position
		elseif roll == 2 and luckyBlocks and #luckyBlocks.blocks > 0 then
			-- Target a nearby lucky block
			self.state = "lucky"
			local b = luckyBlocks.blocks[math.random(1, #luckyBlocks.blocks)]
			if b and b.box then
				self.targetPos = b.box.Position
			end
		elseif roll == 3 then
			-- Hit a stunt ramp
			self.state = "ramp"
			local rampOffsets = { Vector3.new(-55, 0, -10), Vector3.new(55, 0, -10), Vector3.new(0, 0, -60) }
			self.targetPos = ORIGIN + rampOffsets[math.random(1, #rampOffsets)]
		else
			-- Free drift / roam in playground center
			self.state = "explore"
			local rx = math.random(-45, 45)
			local rz = math.random(-40, 40)
			self.targetPos = ORIGIN + Vector3.new(rx, 0, rz)
		end
	end

	-- Steer towards targetPos
	local carPosUU = self.car.body.pos
	local carStudPos = carPosUU / 50
	local toTarget = (self.targetPos - carStudPos)
	local flatToTarget = Vector3.new(toTarget.X, 0, toTarget.Z)
	local dist = flatToTarget.Magnitude

	-- Calculate heading error using car body orientation
	local forward = self.car.body.rot * Vector3.new(1, 0, 0) -- CarPhysics forward
	local flatFwd = Vector3.new(forward.X, 0, forward.Y)
	
	local steer = 0
	if dist > 4 and flatToTarget.Magnitude > 0.1 then
		local cross = flatFwd.X * flatToTarget.Z - flatFwd.Z * flatToTarget.X
		steer = math.clamp(cross * 0.05, -1, 1)
	end

	local throttle = if dist > 6 then 1 else 0.4
	local boost = dist > 25 and (self.state == "ramp" or self.state == "ball")
	local jump = self.state == "ramp" and dist < 12 and (self.car.numWheelsInContact or 0) > 0

	self.car.controls = {
		throttle = throttle,
		steer = steer,
		pitch = 0,
		yaw = steer,
		roll = 0,
		jump = jump,
		boost = boost,
		handbrake = dist < 8 and math.abs(steer) > 0.6,
	}
end

return PartyPlaygroundAI
