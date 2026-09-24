--!strict
-- BeachVolleyBotController.lua: a competent, imperfect volley bot.
-- Perception: only what a player sees - ball position / velocity (sampled with a reaction delay and a little noise),
-- its own car, teammates, the net, the bounce count shown on the HUD. No access to the future simulation.
-- Decision: predict the ball's arc with the volley ball's gravity/drag/bounces, list the moments it is low enough for
-- the bumper on our half (before or after its one allowed bounce), take the first one we can reach, wait on a run-up
-- spot behind it and charge through it along the line to the middle of the other half (the volley touch lifts it).
-- Teammates call the ball so only one goes. Balls that will land out without bouncing on our side are left alone.
-- Imperfections: 0.12-0.24 s reaction (projected, like a player does), off-centre contact noise, occasional late jump.
local RS = game:GetService("ReplicatedStorage")
local Phys = RS:WaitForChild("Physics")
local C = require(Phys.PhysicsConstants)
local CarPhysics = require(Phys.CarPhysics)
local Shared = require(RS.Party.MinigameShared:WaitForChild("BeachVolleyShared"))
local Base = require(script.Parent.Parent.MinigameBotController)

local BT = C.BT_TO_UU
local G = -C.GRAVITY_Z * Shared.BALL_OVERRIDE.gravityScale -- positive, uu/s^2
local DRAG = Shared.BALL_OVERRIDE.linearDamping
local REST = Shared.BALL_OVERRIDE.restitution
local R = Shared.BALL_RADIUS
local HIT_Z = 125 -- highest ball centre the bumper of a grounded car still meets (roof ~60 uu + most of a radius)
local RUNUP = 480 -- uu of run-up toward the net before the contact
local RUN_SPEED_MIN = 330 -- uu/s through the ball near the net
local RUN_SPEED_MAX = 850 -- from the back of the court

local Bot = setmetatable({}, { __index = Base })
Bot.__index = Bot

function Bot.new(session: any, member: any, car: any, minigame: any)
	local self = setmetatable(Base.new(session, member, car), Bot) :: any
	self.mg = minigame
	self.team = member.team
	self.sign = Shared.SideSign(member.team)
	self.reaction = self.rng:NextNumber(0.12, 0.24)
	self.history = {}
	self.t = 0
	self.jumpLeft = 0
	self.jumpCooldown = 0
	self.secondJumpAt = -1
	self.noise = Vector3.zero
	self.noiseT = 0
	return self
end

-- ballistic prediction with the volley override (gravity, drag, floor bounces).
-- Collects the moments the ball is playable on our half (hitting height, before it would bounce a second time on
-- our side, not out) as { pos, t }, plus where it first lands.
function Bot.Predict(self: any, p: Vector3, v: Vector3, bouncesSoFar: number): ({ any }, Vector3?)
	local dt = 1 / 60
	local land = nil
	local cands = {}
	local bounces = bouncesSoFar
	local wasOurs = self.sign * p.Y > 0
	for i = 1, 270 do
		v = Vector3.new(v.X, v.Y, v.Z - G * dt) * (1 - DRAG) ^ dt
		p += v * dt
		local ours = self.sign * p.Y > 0
		if ours ~= wasOurs then bounces = 0 end
		wasOurs = ours
		if p.Z <= R then
			p = Vector3.new(p.X, p.Y, R)
			if not land then land = p end
			v = Vector3.new(v.X * 0.9, v.Y * 0.9, -v.Z * REST)
			if ours then
				bounces += 1
				if bounces >= 2 or not Shared.InCourt(p) then break end
			end
		end
		if ours and self.sign * p.Y > 150 and p.Z <= HIT_Z and (i % 2 == 0)
			and math.abs(p.X) < Shared.COURT_HX + 250 and math.abs(p.Y) < Shared.COURT_HY + 250 then
			-- what we saw is `reaction` old: a player projects it to now
			local t = i * dt - self.reaction
			if t > 0 then
				table.insert(cands, { pos = p, t = t })
			end
		end
	end
	return cands, land
end

-- the first playable moment we can actually get to in time (drive to the run-up spot, then the run-up);
-- if none, the one that leaves us the most slack
function Bot.Choose(self: any, cands: { any }, cpos: Vector3, fwd: Vector3): (Vector3?, number?)
	local best, bestT, bestSlack = nil, nil, -math.huge
	for _, c in cands do
		local p = c.pos
		local to = Vector3.new(p.X - cpos.X, p.Y - cpos.Y, 0)
		local d = math.max(0, to.Magnitude - RUNUP * 0.5)
		local turn = if to.Magnitude > 1 then math.acos(math.clamp(fwd:Dot(to.Unit), -1, 1)) else 0
		local need = d / 1300 + turn * 0.35 + 0.35
		local slack = c.t - need
		if slack >= 0 then
			return p, c.t
		end
		if slack > bestSlack then
			best, bestT, bestSlack = p, c.t, slack
		end
	end
	return best, bestT
end

function Bot.Observe(self: any): (Vector3, Vector3)
	local bb = self.session.world.ball.body
	table.insert(self.history, { t = self.t, p = bb.pos * BT, v = bb.vel * BT })
	while #self.history > 2 and self.history[2].t <= self.t - self.reaction do
		table.remove(self.history, 1)
	end
	local o = self.history[1]
	return o.p, o.v
end

function Bot.Home(self: any): Vector3
	local mates = self.session:MembersOnTeam(self.team)
	local idx, n = 1, #mates
	for i, m in mates do if m.id == self.member.id then idx = i end end
	local xs = if n <= 1 then { 0 } else { -650, 650 }
	return Vector3.new(xs[idx] or 0, self.sign * 1700, 17)
end

function Bot.Think(self: any, dt: number): any
	self.t += dt
	self.jumpCooldown -= dt
	local car = self.car
	local cpos = car.body.pos * BT
	local bp, bv = self:Observe()
	local grounded = (car.numWheelsInContact or 0) > 0

	-- keep a jump going
	if self.jumpLeft > 0 then
		self.jumpLeft -= dt
		local c = CarPhysics.EmptyControls()
		c.jump = true
		c.pitch = 0.25 -- nose slightly up: lifts the ball
		return c
	end
	if self.secondJumpAt > 0 and self.t >= self.secondJumpAt and not grounded then
		self.secondJumpAt = -1
		local c = CarPhysics.EmptyControls()
		c.jump = true -- double jump (no stick on the jump tick)
		return c
	end

	if self.mg.phase ~= "rally" then
		local c = self:DriveTo(self:Home(), 600)
		return c
	end

	-- refresh aiming noise now and then
	if self.t >= self.noiseT then
		self.noiseT = self.t + 0.8
		self.noise = Vector3.new(self.rng:NextNumber(-28, 28), self.rng:NextNumber(-45, 45), 0) -- off-centre = angled shot
	end

	local cands, land = self:Predict(bp, bv, self.mg.bounces)
	local hitP, hitT
	if self.charging and self.hitAt then
		-- committed: stay with the same moment of the arc (only its position is refreshed)
		local bestE = math.huge
		for _, cd in cands do
			local e = math.abs(self.t + cd.t - self.hitAt)
			if e < bestE then bestE, hitP = e, cd.pos end
		end
		if bestE > 0.12 then hitP = nil end
		hitT = if hitP then self.hitAt - self.t else nil
	end
	if not hitP then
		local f = Vector3.new(car.body.fwd.X, car.body.fwd.Y, 0)
		hitP, hitT = self:Choose(cands, cpos, if f.Magnitude > 1e-3 then f.Unit else Vector3.new(0, -self.sign, 0))
		self.hitAt = if hitT then self.t + hitT else nil
	end
	local ballOurs = self.sign * bp.Y > 0
	-- leave it: it will land out without touching our half first
	local leaveIt = land ~= nil and not Shared.InCourt(land) and (self.sign * land.Y > 0) and self.mg.bounces == 0 and ballOurs == false
	local target
	local speed = 900
	local parkDir = nil -- set when we should wait on the run-up spot facing this way
	if hitP and not leaveIt then
		-- one ball, one car: the teammate with the shorter way to it calls it ("¡mía!"). Whoever holds the call keeps
		-- it unless the other is clearly closer; exact ties go to the lower id so both never charge together.
		local myD = (Vector3.new(hitP.X, hitP.Y, 0) - Vector3.new(cpos.X, cpos.Y, 0)).Magnitude
		local mine = true
		for _, m in self.session:MembersOnTeam(self.team) do
			if m.id ~= self.member.id then
				local other = self.session:CarOf(m.id)
				local ob = self.session.bots[m.id]
				if other then
					local op = other.body.pos * BT
					local oD = (Vector3.new(hitP.X - op.X, hitP.Y - op.Y, 0)).Magnitude
					local margin = if self.called then 250 elseif ob and ob.called then -250 else 0
					if oD + margin < myD or (math.abs(oD - myD) < 1 and m.id < self.member.id) then mine = false end
				end
			end
		end
		self.called = mine
		if mine then
			-- hit it moving toward the net: wait at a run-up spot behind the contact point, then charge through it
			-- aim at the middle of the other half (keeps it in)
			local aimAt = Vector3.new(-hitP.X * 0.25,-self.sign * 1300, 0)
			local aimDir = Vector3.new(aimAt.X - hitP.X, aimAt.Y - hitP.Y, 0).Unit
			if self.aimDir and self.aimHitAt and math.abs(self.aimHitAt - self.hitAt) < 0.35 then
				aimDir = self.aimDir -- same play: keep the plan (re-deriving it from where we are chases our own tail)
				self.aimHitAt = self.hitAt
			else
				self.aimHitAt = self.hitAt
				-- like a player: hit it from the direction we are coming, as long as that still sends it over the net
				-- (within ~45 deg of straight); only a car on the wrong side has to go around
				local app = Vector3.new(hitP.X - cpos.X, hitP.Y - cpos.Y, 0)
				if app.Magnitude > 150 then
					app = app.Unit
					local a = math.atan2(aimDir.X * app.Y - aimDir.Y * app.X, aimDir:Dot(app))
					a = math.clamp(a, -0.3, 0.3)
					local ca, sa = math.cos(a), math.sin(a)
					aimDir = Vector3.new(aimDir.X * ca - aimDir.Y * sa, aimDir.X * sa + aimDir.Y * ca, 0)
				end
			end
			self.aimDir = aimDir
			-- where our car's centre is when the bumper meets the ball (half car + ball radius behind it)
			local contact = Vector3.new(hitP.X, hitP.Y, 17) - aimDir * 135 + self.noise
			-- softer when close to the net: the light ball carries far (range ~ v^2 / g)
			-- (a ball already flying at us adds a little: car touches barely bounce it back)
			local incoming = math.max(0, -Vector3.new(bv.X, bv.Y, 0):Dot(aimDir))
			-- measured: with the volley touch the ball flies ~2.9 s and leaves at ~1.6x the car's speed, so to drop it
			-- in the middle of the other half (y ~ 1300 past the net) we run at (distance + 1300) / 4.6
			local runSpeed = math.clamp((math.abs(hitP.Y) + 1300) / 4.6, RUN_SPEED_MIN, RUN_SPEED_MAX)
			runSpeed = math.max(RUN_SPEED_MIN, runSpeed - incoming * 0.15)
			local runTime = RUNUP / runSpeed + 0.25 -- + getting up to speed from a stop
			local t = hitT or 1
			local spot = contact - aimDir * RUNUP
			-- the contact point is behind us (ball carried deeper than we are): turn back to the run-up spot
			local behindUs = (Vector3.new(cpos.X, cpos.Y, 0) - contact):Dot(aimDir) > -40
			if t > runTime + 0.15 or (behindUs and not self.charging) then
				-- approach the spot from behind so we arrive already facing the net
				local rel = Vector3.new(cpos.X - spot.X, cpos.Y - spot.Y, 0)
				local along = rel:Dot(aimDir)
				local lat = (rel - aimDir * along).Magnitude
				if along > -lat * 0.6 and rel.Magnitude > 140 then
					target = spot - aimDir * math.min(420, lat + 120)
				else
					target = spot
				end
				local d = (Vector3.new(target.X - cpos.X, target.Y - cpos.Y, 0)).Magnitude
				speed = math.clamp(d / math.max(t - runTime - 0.1, 0.15), 0, 2000)
				speed = math.min(speed, d * 2.2 + 60) -- ease in
				parkDir = aimDir
				self.charging = false
			else
				-- charge through the contact point, arriving when the ball does (early = the ball drops on the roof
				-- and goes backwards; late = it's gone)
				local d = (Vector3.new(contact.X - cpos.X, contact.Y - cpos.Y, 0)).Magnitude
				-- pure pursuit of the hitting line (through the contact point along aimDir): we meet the ball
				-- centred, so it leaves along aimDir instead of off the corner of the bumper
				local rel = Vector3.new(cpos.X - contact.X, cpos.Y - contact.Y, 0)
				local along = rel:Dot(aimDir)
				target = contact + aimDir * (along + 260)
				speed = math.clamp(d / math.max(t, 0.05), runSpeed * 0.7, runSpeed * 1.25)
				self.charging = true
			end
		end
	else
		self.called = false
	end
	if not target then
		self.charging = false
	end
	target = target or self:Home()
	-- never drive into the net wall
	local minY = 170
	if self.sign * target.Y < minY then
		target = Vector3.new(target.X, self.sign * minY, target.Z)
	end
	target = Vector3.new(math.clamp(target.X, -Shared.COURT_HX - 400, Shared.COURT_HX + 400), target.Y, target.Z)

	local c
	local toT = Vector3.new(target.X - cpos.X, target.Y - cpos.Y, 0)
	local fwdNow = Vector3.new(car.body.fwd.X, car.body.fwd.Y, 0)
	fwdNow = if fwdNow.Magnitude > 1e-3 then fwdNow.Unit else Vector3.new(0, -self.sign, 0)
	if parkDir and toT.Magnitude < 140 and not self.charging and fwdNow:Dot(parkDir) < 0.85 then
		-- on the spot but facing the wrong way: loop out behind it and come back in line
		c = self:DriveTo(target - parkDir * 380, 700)
	elseif toT.Magnitude < 110 and not self.charging then
		-- parked on the run-up spot: stop and keep facing the net instead of dithering
		c = self:DriveTo(cpos + (parkDir or Vector3.new(0, -self.sign, 0)) * 400, 0)
		c.throttle = math.clamp(-(car.body.vel * BT):Dot(car.body.fwd) / 300, -1, 1)
		c.handbrake = false
	else
		c = self:DriveTo(target, speed)
	end
	local fwdSpeed = (car.body.vel * BT):Dot(car.body.fwd)
	c.boost = grounded and math.abs(c.steer) < 0.3 and fwdSpeed < speed - 250 and speed > 1300

	-- jump into the ball when it's close and at a hittable height. We see the ball late (reaction), so like a
	-- player we anticipate: carry the seen state forward by our reaction time.
	local r = self.reaction
	local bpE = bp + bv * r - Vector3.new(0, 0, 0.5 * G * r * r)
	local bvE = bv - Vector3.new(0, 0, G * r)
	local rel = Vector3.new(bpE.X - cpos.X, bpE.Y - cpos.Y, 0)
	local fwd2 = Vector3.new(car.body.fwd.X, car.body.fwd.Y, 0)
	fwd2 = if fwd2.Magnitude > 1e-3 then fwd2.Unit else Vector3.new(0, 1, 0)
	local inFront = rel:Dot(fwd2) > -30
	local relDir = if rel.Magnitude > 1 then rel.Unit else fwd2
	-- closing speed between car and ball along the line joining them; jump ~0.18 s before contact so the car is
	-- rising when it meets the ball (that is what lifts it over the net)
	local closing = (Vector3.new(car.body.vel.X, car.body.vel.Y, 0) * BT - Vector3.new(bvE.X, bvE.Y, 0)):Dot(relDir)
	local ttc = if closing > 60 then math.max(0, rel.Magnitude - 110) / closing else (if rel.Magnitude < 160 then 0 else 9)
	local zc = bpE.Z + bvE.Z * ttc - 0.5 * G * ttc * ttc -- ball height when we get there
	-- a ball flying away from us (over our head, deeper than us) can't be met by jumping now
	local escaping = closing < -250
	if grounded and self.jumpCooldown <= 0 and self.sign * bpE.Y > 0 and inFront and not escaping and ttc < 0.18 and zc > 175 and zc < 430 then
		-- (a lower ball is met with the bumper: the volley touch lifts it, and it keeps the car's push toward the net)
		local late = self.rng:NextNumber() < 0.12
		self.jumpLeft = if late then 0.05 else 0.18
		self.jumpCooldown = 1.2
		-- high ball, or close to the net (needs a steep hit to clear it): second jump
		if (zc > 330 or math.abs(bpE.Y) < 700) and not late then
			self.secondJumpAt = self.t + 0.26
		end
	end
	return c
end

return Bot
