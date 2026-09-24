--!strict
-- DerbyBotController.lua: a Demolition Derby bot. A hunter:
--   * picks a prey (the nearest live car, sticking with it for a while, preferring whoever leads the scoreboard)
--   * aims where the prey WILL be (lead by its velocity) and boosts to go supersonic on a straight line
--   * low on boost or just respawned: circles the bowl to build speed first; dodges a hunter coming straight at it
-- Imperfections: ~0.2 s reaction, a bit of aim wobble, sometimes misses the lead.
local RS = game:GetService("ReplicatedStorage")
local C = require(RS.Physics.PhysicsConstants)
local Shared = require(RS.Party.MinigameShared:WaitForChild("DerbyShared"))
local Base = require(script.Parent.Parent.MinigameBotController)

local BT = C.BT_TO_UU

local Bot = setmetatable({}, { __index = Base })
Bot.__index = Bot

function Bot.new(session: any, member: any, car: any, minigame: any)
	local self = setmetatable(Base.new(session, member, car), Bot) :: any
	self.mg = minigame
	self.t = 0
	self.prey = nil
	self.preyUntil = 0
	self.lead = self.rng:NextNumber(0.6, 1.0) -- how well it leads its target
	self.wobble = self.rng:NextNumber(-120, 120)
	return self
end

function Bot.PickPrey(self: any, me: Vector3): any
	local best, bestScore = nil, math.huge
	for _, other in self.session.world.cars do
		local shielded = other.shieldUntil ~= nil and self.session.world.tickCount < other.shieldUntil
		if other ~= self.car and not other.isDemoed and not shielded then
			local d = ((other.body.pos * BT) - me).Magnitude
			local m = self.session:MemberOfCar(other)
			local lead = if m and self.mg.demos then (self.mg.demos[m.id] or 0) else 0
			local s = d - lead * 500 + self.rng:NextNumber(0, 400)
			if s < bestScore then best, bestScore = other, s end
		end
	end
	return best
end

function Bot.Think(self: any, dt: number): any
	self.t += dt
	local car = self.car
	if car.isDemoed then return Base.Think(self, dt) end
	local me = car.body.pos * BT
	local vel = car.body.vel * BT
	if not self.prey or self.prey.isDemoed or self.t > self.preyUntil then
		self.prey = self:PickPrey(me)
		self.preyUntil = self.t + self.rng:NextNumber(3, 6)
		self.wobble = self.rng:NextNumber(-140, 140)
	end
	local c
	local prey = self.prey
	if prey then
		local pp = prey.body.pos * BT
		local pv = prey.body.vel * BT
		local dist = (pp - me).Magnitude
		local closing = math.max(900, vel.Magnitude)
		local tLead = math.clamp(dist / closing, 0, 1.2) * self.lead
		local aim = pp + pv * tLead
		-- stay inside the bowl
		local flat = Vector3.new(aim.X, aim.Y, 0)
		local lim = Shared.APOTHEM - 500
		if flat.Magnitude > lim then flat = flat.Unit * lim end
		local fwd = Vector3.new(car.body.fwd.X, car.body.fwd.Y, 0)
		local right = Vector3.new(-fwd.Y, fwd.X, 0)
		aim = flat + right * self.wobble * math.clamp(dist / 3000, 0, 1)
		c = self:DriveTo(Vector3.new(aim.X, aim.Y, 17), 2400)
		-- boost on a straight line; save it when the turn is sharp
		c.boost = math.abs(c.steer) < 0.35 and (car.boost or 0) > 5
		-- a hunter coming head-on at me and I'm slow: swerve
		for _, other in self.session.world.cars do
			if other ~= car and other ~= prey and not other.isDemoed then
				local op, ov = other.body.pos * BT, other.body.vel * BT
				local to = me - op
				if to.Magnitude < 1400 and ov.Magnitude > 1900 and ov.Unit:Dot(to.Unit) > 0.92 and vel.Magnitude < 1800 then
					c.steer = if right:Dot(ov) > 0 then -1 else 1
					c.boost = true
				end
			end
		end
	else
		-- nobody to hunt: lap the bowl
		local a = math.atan2(me.Y, me.X) + 0.6
		c = self:DriveTo(Vector3.new(math.cos(a) * 3300, math.sin(a) * 3300, 17), 2000)
		c.boost = math.abs(c.steer) < 0.3
	end
	return c -- (the session runs Unstick on every bot)
end

return Bot
