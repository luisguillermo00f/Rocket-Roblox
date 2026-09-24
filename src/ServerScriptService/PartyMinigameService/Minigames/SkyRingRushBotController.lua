--!strict
-- SkyRingRushBotController.lua: a ring-race bot. It sees the rings (they're on screen for everyone), its own car and
-- the HUD's "next ring". It drives the line through the ring's centre along its normal (pure pursuit), jumps for
-- rings a little above the ground and flies with boost for high ones, pointing the nose with the same PD air control
-- measured for the menu cinematic (pitch+ nose up, yaw+ toward body.right, roll+ up toward body.right).
-- Imperfections: takes a shortcut only sometimes, a small aiming error, late take-offs, recovers after misses.
local RS = game:GetService("ReplicatedStorage")
local C = require(RS.Physics.PhysicsConstants)
local CarPhysics = require(RS.Physics.CarPhysics)
local Shared = require(RS.Party.MinigameShared:WaitForChild("SkyRingRushShared"))
local Base = require(script.Parent.Parent.MinigameBotController)

local BT = C.BT_TO_UU
local G = -C.GRAVITY_Z

local Bot = setmetatable({}, { __index = Base })
Bot.__index = Bot

function Bot.new(session: any, member: any, car: any, minigame: any)
	local self = setmetatable(Base.new(session, member, car), Bot) :: any
	self.mg = minigame
	self.t = 0
	self.plan = nil -- { k, ring, sign }
	self.jumpT = -1 -- time since take-off (-1 = on the ground plan)
	self.bold = self.rng:NextNumber(0, 1) -- chance to take shortcuts
	self.aimErr = Vector3.new(self.rng:NextNumber(-40, 40), self.rng:NextNumber(-40, 40), self.rng:NextNumber(-30, 30))
	return self
end

local function aim(car: any, dir: Vector3, up: Vector3?, c: any, kp: number?, kd: number?)
	local b = car.body
	local f, r, u, w = b.fwd, b.right, b.up, b.angVel
	local p, d = kp or 3.2, kd or 0.55
	c.pitch = math.clamp(p * math.atan2(dir:Dot(u), dir:Dot(f)) - d * (-w:Dot(r)), -1, 1)
	c.yaw = math.clamp(p * math.atan2(dir:Dot(r), dir:Dot(f)) - d * w:Dot(u), -1, 1)
	if up then
		c.roll = math.clamp(p * math.atan2(up:Dot(r), up:Dot(u)) - d * (-w:Dot(f)), -1, 1)
	end
end

function Bot.Plan(self: any, k: number)
	local cp = self.mg.route.checkpoints[k]
	if not cp then return nil end
	local cpos = self.car.body.pos * BT
	local ring = cp[1]
	if cp[2] and self.rng:NextNumber() < 0.35 * self.bold then
		ring = cp[2]
	end
	-- go through it from the side we're on
	local sign = if (cpos - ring.c):Dot(ring.n) > 0 then -1 else 1
	return { k = k, ring = ring, sign = sign, since = self.t }
end

function Bot.Think(self: any, dt: number): any
	self.t += dt
	local mg = self.mg
	local k = mg.progress[self.member.id] or 1
	if k > #mg.route.checkpoints then
		return CarPhysics.EmptyControls()
	end
	if not self.plan or self.plan.k ~= k or self.t - self.plan.since > 9 then
		self.plan = self:Plan(k)
		self.jumpT = -1
	end
	local plan = self.plan
	local ring = plan.ring
	local dir = ring.n * plan.sign
	local car = self.car
	local b = car.body
	local p = b.pos * BT
	local v = b.vel * BT
	local grounded = (car.numWheelsInContact or 0) >= 3
	local target = ring.c + self.aimErr
	local rel = p - target
	local along = rel:Dot(dir) -- < 0: before the ring
	local c

	-- in the air (or taking off: the wheels still touch for a few ticks after the jump): fly at the ring
	if self.jumpT >= 0 then self.jumpT += dt end
	if self.jumpT >= 0 and self.jumpT < 0.5 then grounded = false end
	if not grounded then
		c = CarPhysics.EmptyControls()
		local toT = target - p
		local ahead = along < 60
		-- only fly at rings that need it (high ones, or the one we just jumped for); a low ring is taken on the
		-- ground: flying at it with boost overshoots above it
		local wantsAir = target.Z > 260 or (self.jumpT >= 0 and self.jumpT < 1.2)
		if ahead and toT.Magnitude > 60 and wantsAir then
			-- point the nose a bit above the target to cancel the fall, then boost at it
			local tt = toT.Magnitude / math.max(900, v.Magnitude)
			local aimAt = toT + Vector3.new(0, 0, 0.5 * G * tt * tt * 0.55) + dir * 120
			aim(car, aimAt.Unit, Vector3.zAxis, c)
			local facing = b.fwd:Dot(aimAt.Unit)
			c.boost = facing > 0.7
			-- hold the first jump, let go, then a second jump (no stick on that tick, or it becomes a dodge)
			if self.jumpT >= 0 and self.jumpT < 0.15 then
				c.jump = true
			elseif self.jumpT >= 0.2 and self.jumpT < 0.24 and target.Z - p.Z > 220 and not car.hasDoubleJumped then
				c = CarPhysics.EmptyControls()
				c.jump = true
				c.boost = true
			end
		else
			-- past it (or lost): land wheels-down, facing the way we're going
			local flat = Vector3.new(v.X, v.Y, 0)
			local fwd = if flat.Magnitude > 100 then flat.Unit else Vector3.new(b.fwd.X, b.fwd.Y, 0).Unit
			aim(car, (fwd - Vector3.zAxis * 0.15).Unit, Vector3.zAxis, c)
			c.throttle = 1
		end
		return c
	end
	self.jumpT = -1

	-- on the ground: follow the line through the ring along its normal
	local flatDir = Vector3.new(dir.X, dir.Y, 0)
	flatDir = if flatDir.Magnitude > 1e-3 then flatDir.Unit else Vector3.new(b.fwd.X, b.fwd.Y, 0).Unit
	local flatRel = Vector3.new(rel.X, rel.Y, 0)
	local fAlong = flatRel:Dot(flatDir)
	local goal
	if fAlong > 250 then
		-- we went past without scoring: loop back behind it
		goal = target - flatDir * 900
	else
		local lat = flatRel - flatDir * fAlong
		goal = target + flatDir * (fAlong + math.clamp(-fAlong * 0.5, 350, 900)) - lat * 0.2
	end
	goal = Vector3.new(math.clamp(goal.X, -3700, 3700), math.clamp(goal.Y, -4700, 4700), 17)
	-- slow into sharp turns (at full speed the turning circle is wider than the arena's corners)
	local toGoal = Vector3.new(goal.X - p.X, goal.Y - p.Y, 0)
	local fwdFlat = Vector3.new(b.fwd.X, b.fwd.Y, 0)
	local turn = if toGoal.Magnitude > 1 and fwdFlat.Magnitude > 1e-3 then math.acos(math.clamp(fwdFlat.Unit:Dot(toGoal.Unit), -1, 1)) else 0
	local want = 2300 - math.clamp((turn - 0.3) / 0.9, 0, 1) * 1400
	c = self:DriveTo(goal, want)
	local speed = v:Dot(b.fwd)
	c.boost = math.abs(c.steer) < 0.35 and speed < want - 150
	-- take-off: how high is the ring's centre above a grounded car, and how long to get there?
	local h = target.Z - 17
	local aligned = b.fwd:Dot(flatDir) > 0.85 and math.abs(Vector3.new(flatRel.X, flatRel.Y, 0):Dot(Vector3.new(-flatDir.Y, flatDir.X, 0))) < 260
	if h > 230 and aligned and fAlong < 0 then
		local climbT = if h < 420 then 0.45 else 0.35 + h / 1100
		local distNeeded = math.max(300, speed) * climbT
		if -fAlong < distNeeded then
			self.jumpT = 0
			c = CarPhysics.EmptyControls()
			c.jump = true
			c.throttle = 1
			c.boost = true
		end
	end
	return c
end

return Bot
