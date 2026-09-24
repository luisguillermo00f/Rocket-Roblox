--!strict
-- SumoRemixBotController.lua: a sumo bot that plays like a person.
-- Perception: the zone drawn on the floor (current + announced next), the phase clock on the HUD, the other cars'
-- positions / velocities seen with a reaction delay, its own car.
-- Decision: be inside the announced zone before it closes (with a margin that grows as the clock runs down); with
-- time to spare, pick the most exposed rival (closest to the edge, nearby) and ram it from the inside so it gets
-- pushed outward. Imperfections: 0.15-0.3 s reaction, aim noise, the occasional over-committed charge.
local RS = game:GetService("ReplicatedStorage")
local C = require(RS.Physics.PhysicsConstants)
local Shared = require(RS.Party.MinigameShared:WaitForChild("SumoRemixShared"))
local Base = require(script.Parent.Parent.MinigameBotController)

local BT = C.BT_TO_UU

local Bot = setmetatable({}, { __index = Base })
Bot.__index = Bot

function Bot.new(session: any, member: any, car: any, minigame: any)
	local self = setmetatable(Base.new(session, member, car), Bot) :: any
	self.mg = minigame
	self.t = 0
	self.reaction = self.rng:NextNumber(0.15, 0.3)
	self.seen = {} -- member id -> { { t, p, v } } history
	self.target = nil
	self.retarget = 0
	self.greed = self.rng:NextNumber(0.6, 1.4) -- how late it dares to stay out attacking
	return self
end

-- a rival as we perceive it (reaction delay), projected forward by that delay like a player would
function Bot.See(self: any, id: string, car: any): (Vector3, Vector3)
	local h = self.seen[id]
	if not h then
		h = {}
		self.seen[id] = h
	end
	table.insert(h, { t = self.t, p = car.body.pos * BT, v = car.body.vel * BT })
	while #h > 2 and h[2].t <= self.t - self.reaction do
		table.remove(h, 1)
	end
	local o = h[1]
	return o.p + o.v * self.reaction, o.v
end

function Bot.Think(self: any, dt: number): any
	self.t += dt
	local mg = self.mg
	local car = self.car
	local cpos = car.body.pos * BT
	local me2 = Vector2.new(cpos.X, cpos.Y)
	if mg.phase < 1 or not mg.zones[mg.phase] then
		return self:DriveTo(Vector3.zero, 0)
	end
	local t = mg.elapsed - mg.phaseStart
	local nextZ = mg.zones[mg.phase + 1] or mg.zones[mg.phase]
	local nc, nr = nextZ.c, nextZ.r
	local toCheck = Shared.PHASE - t
	local speed = (car.body.vel * BT).Magnitude
	local fromNext = (me2 - nc).Magnitude
	if t < 0.05 then self.returning = false end -- new phase, new plan

	-- safety first: how long do I need to get well inside the next zone? A car flying outward needs time to turn.
	local vel2 = Vector2.new(car.body.vel.X, car.body.vel.Y) * BT
	local outDir = if fromNext > 1 then (me2 - nc) / fromNext else Vector2.new(1, 0)
	local radial = vel2:Dot(outDir) -- > 0 moving away from the centre
	local need = math.max(0, fromNext - nr * 0.5) / 1200 + 1.0 + math.max(0, radial) / 1500
	if self.returning then
		if fromNext < nr * 0.45 and toCheck > need + 3 then self.returning = false end
	elseif (fromNext > nr * 0.7 and toCheck < need + 2.5 * self.greed) or (fromNext > nr * 0.6 and toCheck < 2.5) then
		self.returning = true
	end
	if self.returning then
		local c = self:DriveTo(Vector3.new(nc.X, nc.Y, 17), if fromNext > nr * 0.5 then 2300 else 500)
		c.boost = math.abs(c.steer) < 0.35 and fromNext > nr * 0.5
		self.target = nil
		return c
	end

	-- pick a victim now and then: someone still inside, close to me and close to the edge of the next zone
	self.retarget -= dt
	if self.retarget <= 0 or not (self.target and mg.alive[self.target]) then
		self.retarget = self.rng:NextNumber(0.8, 1.6)
		local best, bestScore = nil, math.huge
		for id in mg.alive do
			if id ~= self.member.id then
				local other = self.session:CarOf(id)
				if other then
					local op = other.body.pos * BT
					local o2 = Vector2.new(op.X, op.Y)
					local fromC = (o2 - nc).Magnitude
					if fromC < nr + 150 then -- not worth chasing someone already out
						local edge = nr - fromC -- smaller = more exposed
						local score = (o2 - me2).Magnitude * 0.6 + edge + self.rng:NextNumber(0, 300)
						if score < bestScore then best, bestScore = id, score end
					end
				end
			end
		end
		self.target = best
	end
	if not self.target then
		-- nobody to push: circle the middle, ready to react
		local a = self.t * 0.6 + self.member.id:len()
		return self:DriveTo(Vector3.new(nc.X + math.cos(a) * nr * 0.3, nc.Y + math.sin(a) * nr * 0.3, 17), 700)
	end

	local other = self.session:CarOf(self.target)
	local op = self:See(self.target, other)
	local o2 = Vector2.new(op.X, op.Y)
	local out = o2 - nc
	out = if out.Magnitude > 1 then out.Unit else Vector2.new(1, 0)
	-- come from the inside: first get between the centre and the victim, then drive through it outward
	local inner = o2 - out * 450
	local rel = me2 - o2
	local behind = rel:Dot(out) < -150 -- we're on the centre side
	local aim
	if behind then
		aim = o2 + out * 250 + Vector2.new(self.rng:NextNumber(-60, 60), self.rng:NextNumber(-60, 60))
	else
		aim = inner
	end
	local c = self:DriveTo(Vector3.new(aim.X, aim.Y, 17), if behind then 2300 else 1400)
	c.boost = behind and math.abs(c.steer) < 0.3 and speed < 2200
	-- don't follow a victim over the edge: near it and still flying outward, brake and turn back
	if fromNext > nr - 350 and radial > 400 then
		c = self:DriveTo(Vector3.new(nc.X, nc.Y, 17), 600)
		c.boost = false
	end
	return c
end

return Bot
