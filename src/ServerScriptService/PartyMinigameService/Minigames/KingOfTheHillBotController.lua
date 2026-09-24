--!strict
-- KingOfTheHillBotController.lua: a king-of-the-hill bot. It sees the hill (and the announced next one), the other
-- cars (with a reaction delay) and its own car. On the hill alone: stay near the middle, facing the nearest threat.
-- Someone else on it: ram them off, from the middle outward. Next hill announced and not worth staying: head there
-- early. Imperfections: 0.15-0.3 s reaction, some bots leave late, aim noise.
local RS = game:GetService("ReplicatedStorage")
local C = require(RS.Physics.PhysicsConstants)
local Shared = require(RS.Party.MinigameShared:WaitForChild("KingOfTheHillShared"))
local Base = require(script.Parent.Parent.MinigameBotController)

local BT = C.BT_TO_UU

local Bot = setmetatable({}, { __index = Base })
Bot.__index = Bot

function Bot.new(session: any, member: any, car: any, minigame: any)
	local self = setmetatable(Base.new(session, member, car), Bot) :: any
	self.mg = minigame
	self.t = 0
	self.reaction = self.rng:NextNumber(0.15, 0.3)
	self.seen = {}
	self.leaveEarly = self.rng:NextNumber(0.5, 2.5) -- s before the move it starts for the next hill
	return self
end

function Bot.See(self: any, id: string, car: any): Vector3
	local h = self.seen[id]
	if not h then h = {}; self.seen[id] = h end
	table.insert(h, { t = self.t, p = car.body.pos * BT, v = car.body.vel * BT })
	while #h > 2 and h[2].t <= self.t - self.reaction do table.remove(h, 1) end
	local o = h[1]
	return o.p + o.v * self.reaction
end

function Bot.Think(self: any, dt: number): any
	self.t += dt
	local mg = self.mg
	local car = self.car
	local p = car.body.pos * BT
	local me2 = Vector2.new(p.X, p.Y)
	if mg.index < 1 then return self:DriveTo(Vector3.zero, 0) end
	local hill = mg.hills[mg.index]
	local t = mg.elapsed - mg.hillStart
	local left = Shared.HILL_TIME - t
	local nextHill = mg.hills[mg.index + 1]

	-- go early to the next hill when this one is nearly over and the trip is long
	if nextHill and left < Shared.NEXT_WARN then
		local trip = (nextHill - me2).Magnitude / 1500
		if left < trip + self.leaveEarly then
			local c = self:DriveTo(Vector3.new(nextHill.X, nextHill.Y, 17), 2300)
			c.boost = math.abs(c.steer) < 0.3
			return c
		end
	end

	-- who else is on the hill?
	local rival, rd = nil, math.huge
	for _, m in self.session.members do
		if m.id ~= self.member.id then
			local other = self.session:CarOf(m.id)
			if other and not other.netHidden then
				local op = self:See(m.id, other)
				local o2 = Vector2.new(op.X, op.Y)
				local fromC = (o2 - hill).Magnitude
				if fromC < Shared.RADIUS + 250 then
					local d = (o2 - me2).Magnitude
					if d < rd then rival, rd = o2, d end
				end
			end
		end
	end

	local fromHill = (me2 - hill).Magnitude
	if rival then
		-- ram them outward: get between the centre and them, then drive through
		local out = rival - hill
		out = if out.Magnitude > 1 then out.Unit else Vector2.new(1, 0)
		local rel = me2 - rival
		local behind = rel:Dot(out) < -100
		local aim = if behind then rival + out * 300 else rival - out * 350
		local c = self:DriveTo(Vector3.new(aim.X, aim.Y, 17), if behind then 2300 else 1500)
		c.boost = behind and math.abs(c.steer) < 0.3
		-- don't fly off the hill chasing them
		if fromHill > Shared.RADIUS - 100 and (Vector2.new(car.body.vel.X, car.body.vel.Y) * BT):Dot((me2 - hill).Unit) > 500 then
			c = self:DriveTo(Vector3.new(hill.X, hill.Y, 17), 500)
		end
		return c
	end
	-- alone (or empty hill): get to the middle and hover there
	if fromHill > Shared.RADIUS * 0.35 then
		local c = self:DriveTo(Vector3.new(hill.X, hill.Y, 17), math.clamp(fromHill * 1.2, 400, 2300))
		c.boost = fromHill > 1500 and math.abs(c.steer) < 0.3
		return c
	end
	local a = self.t * 0.9 + #self.member.id
	return self:DriveTo(Vector3.new(hill.X + math.cos(a) * 220, hill.Y + math.sin(a) * 220, 17), 450)
end

return Bot
