--!strict
-- MinigameBotController.lua: base bot for any minigame. A bot sees the round only through the same world state a
-- player sees on screen (positions / velocities), with a reaction delay, and drives with ordinary controls.
-- Minigames subclass it (BotController:Think(dt) -> controls).
local RS = game:GetService("ReplicatedStorage")
local CarPhysics = require(RS.Physics.CarPhysics)
local C = require(RS.Physics.PhysicsConstants)

local MinigameBotController = {}
MinigameBotController.__index = MinigameBotController

local BT = C.BT_TO_UU

function MinigameBotController.new(session: any, member: any, car: any)
	local self = setmetatable({}, MinigameBotController)
	self.session = session
	self.member = member
	self.car = car
	self.rng = Random.new(math.floor(os.clock() * 1000) % 1e6 + #member.id)
	return self
end

function MinigameBotController.Think(self: any, dt: number): any
	return CarPhysics.EmptyControls()
end

-- helpers for subclasses ----------------------------------------------------------
-- steer/throttle toward a ground target (UU). Returns controls, distance.
function MinigameBotController.DriveTo(self: any, target: Vector3, arriveSpeed: number?): (any, number)
	local c = CarPhysics.EmptyControls()
	local b = self.car.body
	local pos = b.pos * BT
	local to = Vector3.new(target.X - pos.X, target.Y - pos.Y, 0)
	local dist = to.Magnitude
	if dist < 1 then
		return c, 0
	end
	local fwd = Vector3.new(b.fwd.X, b.fwd.Y, 0)
	fwd = if fwd.Magnitude > 1e-3 then fwd.Unit else Vector3.new(1, 0, 0)
	local dir = to / dist
	local cross = fwd.X * dir.Y - fwd.Y * dir.X
	local dot = fwd:Dot(dir)
	local ang = math.atan2(cross, dot)
	-- measured on the physics: body.right is +90 deg (counter-clockwise) from fwd in sim axes, and steer +1 turns
	-- toward body.right, so a positive angle to the target needs positive steer
	c.steer = math.clamp(ang * 2.2, -1, 1)
	local speed = (b.vel * BT):Dot(fwd)
	local want = arriveSpeed or 1400
	if math.abs(ang) > 2.2 and dist < 600 and speed < 300 then
		-- target close behind: back up to it. Reversing flips the yaw direction a steer input gives, so steer by the
		-- angle between the REAR and the target, inverted
		local angRear = ang - math.sign(ang) * math.pi
		c.throttle = -1
		c.steer = math.clamp(-angRear * 2.5, -1, 1)
		return c, dist
	end
	c.throttle = math.clamp((want - speed) / 300 + 0.2, -1, 1)
	c.handbrake = math.abs(ang) > 1.6 and speed > 500
	return c, dist
end

-- pushing against something without moving (a goal's back net, a wall corner, another car) for a while:
-- back out, steering the other way, then carry on. Call last in Think with the controls about to be returned.
function MinigameBotController.Unstick(self: any, c: any, dt: number): any
	local b = self.car.body
	local speed = (b.vel * BT).Magnitude
	local grounded = (self.car.numWheelsInContact or 0) > 0
	if self.unstickLeft and self.unstickLeft > 0 then
		self.unstickLeft -= dt
		local r = CarPhysics.EmptyControls()
		r.throttle = -1
		r.steer = -(self.unstickSteer or 1)
		return r
	end
	if grounded and math.abs(c.throttle) > 0.5 and speed < 120 then
		self.stuckFor = (self.stuckFor or 0) + dt
	else
		self.stuckFor = 0
	end
	if (self.stuckFor or 0) > 1.0 then
		self.stuckFor = 0
		self.unstickLeft = 0.9
		self.unstickSteer = if c.steer >= 0 then 1 else -1
	end
	return c
end

return MinigameBotController
