--!strict
-- BotAI.lua: Rocket League bots built on the RocketSim port.
--
-- How the physics engine is used:
--   * BallPrediction (RocketSim BallPredTracker port) gives the future ball path, tick by tick.
--   * Motion tables are measured by simulating the real car model once at load: distance/speed vs time from rest
--     (throttle only and with boost) and jump height vs time (single and double jump). The bot looks these up to
--     know when it can reach a ball and when to jump, instead of using guessed formulas.
--   * Aerials use the classic RLBot controller: required acceleration = 2*(target - pos - vel*T)/T^2 - gravity,
--     point the nose along it with a PD on angular velocity, boost when aligned.
--
-- Difficulties: "noob", "pro", "freestyler". They change reaction time, aim error, speed/boost use, jump shots,
-- aerial height, flips, rotation discipline and flair.
local Phys = script.Parent.Parent.Physics
local C = require(Phys.PhysicsConstants)
local World = require(Phys.World)
local CarPhysics = require(Phys.CarPhysics)
local BallPhysics = require(Phys.BallPhysics)
local Q = require(Phys.Quaternion)

local BT, UU = C.BT_TO_UU, C.UU_TO_BT
local BALL_R = C.BALL_COLLISION_RADIUS_SOCCAR

local BotAI = {}
BotAI.__index = BotAI

BotAI.Difficulties = {
	noob = {
		label = "NOVATO", reaction = 0.45, maxSpeed = 1250, useBoost = false, aimError = 380, steerGain = 2.0,
		jumpShots = false, aerials = false, maxAerialZ = 0, flipHit = 0.15, kickoffBoost = false, kickoffFlip = false,
		rotate = false, recover = 0.6, flair = false, reachSlack = 0.25,
	},
	pro = {
		label = "PRO", reaction = 0.12, maxSpeed = 2300, useBoost = true, aimError = 90, steerGain = 3.2,
		jumpShots = true, aerials = true, maxAerialZ = 1150, flipHit = 0.9, kickoffBoost = true, kickoffFlip = true,
		rotate = true, recover = 1.0, flair = false, reachSlack = 0.05,
	},
	freestyler = {
		label = "FREESTYLER", reaction = 0.07, maxSpeed = 2300, useBoost = true, aimError = 45, steerGain = 3.6,
		jumpShots = true, aerials = true, maxAerialZ = 1900, flipHit = 1.0, kickoffBoost = true, kickoffFlip = true,
		rotate = true, recover = 1.0, flair = true, reachSlack = 0.0, preferAerial = true,
	},
}

-- ===== Motion tables measured with the physics engine =====
local Tables: any = nil

local function buildTables()
	local function straight(boost: boolean)
		local w = World.new({ boostPads = false })
		BallPhysics.SetState(w.ball, Vector3.new(3900, 5000, C.BALL_REST_Z), Vector3.zero, Vector3.zero)
		local car = w:AddCar(0)
		CarPhysics.ResetState(car, Vector3.new(-3800, -4900, 17), math.atan2(9800, 7600), 100, true)
		w:Step(10)
		local dist, speed = { 0 }, { 0 }
		local start = car.body.pos
		for _ = 1, 600 do
			car.controls = { throttle = 1, steer = 0, pitch = 0, yaw = 0, roll = 0, jump = false, boost = boost, handbrake = false }
			car.boost = 100
			w:Step()
			table.insert(dist, (car.body.pos - start).Magnitude * BT)
			table.insert(speed, car.body.vel.Magnitude * BT)
		end
		return { dist = dist, speed = speed }
	end
	local function jump(double: boolean)
		local w = World.new({ boostPads = false })
		BallPhysics.SetState(w.ball, Vector3.new(3900, 5000, C.BALL_REST_Z), Vector3.zero, Vector3.zero)
		local car = w:AddCar(0)
		CarPhysics.ResetState(car, Vector3.new(0, -3000, 17), 0, 100, true)
		w:Step(30)
		local h = { 0 }
		local z0 = car.body.pos.Z
		for i = 1, 180 do
			local j = i <= 24 or (double and i >= 27 and i <= 28)
			car.controls = { throttle = 0, steer = 0, pitch = 0, yaw = 0, roll = 0, jump = j, boost = false, handbrake = false }
			w:Step()
			table.insert(h, (car.body.pos.Z - z0) * BT)
		end
		return h
	end
	Tables = { throttle = straight(false), boost = straight(true), jump1 = jump(false), jump2 = jump(true) }
end

-- time (s) to cover `dist` starting at speed v0 (straight line, table lookup from the simulated car)
local function driveTime(dist: number, v0: number, boost: boolean): number
	local tb = if boost then Tables.boost else Tables.throttle
	local sp, ds = tb.speed, tb.dist
	local n = #sp
	local i0 = n
	for i = 1, n do
		if sp[i] >= v0 then
			i0 = i
			break
		end
	end
	if i0 >= n then
		return dist / math.max(v0, 1)
	end
	local base = ds[i0]
	for i = i0, n do
		if ds[i] - base >= dist then
			return (i - i0) / 120
		end
	end
	local vEnd = math.max(sp[n], 1)
	return (n - i0) / 120 + (dist - (ds[n] - base)) / vEnd
end

-- time (s) until a jump reaches `h` uu above the ground (nil if never)
local function jumpTimeFor(h: number, double: boolean): number?
	local tb = if double then Tables.jump2 else Tables.jump1
	for i = 1, #tb do
		if tb[i] >= h then
			return (i - 1) / 120
		end
	end
	return nil
end
local function jumpApex(double: boolean): number
	local tb = if double then Tables.jump2 else Tables.jump1
	local m = 0
	for _, v in tb do m = math.max(m, v) end
	return m
end
BotAI.DriveTime = function(...) if not Tables then buildTables() end return driveTime(...) end

-- ===== Bot =====
function BotAI.new(world: any, car: any, difficulty: string, seed: number?)
	if not Tables then
		buildTables()
	end
	local sk = BotAI.Difficulties[difficulty] or BotAI.Difficulties.pro
	return setmetatable({
		world = world,
		car = car,
		skill = sk,
		difficulty = difficulty,
		rng = Random.new(seed or car.id * 7919),
		plan = nil :: any,
		planAge = 999,
		actions = {} :: { any }, -- queued control overrides (jumps/dodges)
		aerial = nil :: any,
		role = "attack",
		aimOffset = 0,
		lastJumpTick = -1000,
	}, BotAI)
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, v.Y, 0)
end
local function unit(v: Vector3, fb: Vector3?): Vector3
	local m = v.Magnitude
	if m < 1e-6 then
		return fb or Vector3.xAxis
	end
	return v / m
end
local function signedAngle2D(fwd: Vector3, to: Vector3): number
	local a = math.atan2(to.Y, to.X) - math.atan2(fwd.Y, fwd.X)
	return (a + math.pi) % (2 * math.pi) - math.pi
end

function BotAI._state(self: any)
	local b = self.car.body
	return b.pos * BT, b.vel * BT, b.fwd, b.right, b.up
end

function BotAI._goals(self: any): (Vector3, Vector3)
	local sign = if self.car.team == 0 then 1 else -1
	return Vector3.new(0, sign * 5200, 320), Vector3.new(0, -sign * 5120, 0) -- target goal, own goal
end

-- Earliest reachable ball on the predicted path
function BotAI._findIntercept(self: any, pred: { any })
	local sk = self.skill
	local pos, vel, fwd = self:_state()
	local speed = flat(vel).Magnitude
	local targetGoal = self:_goals()
	local boostOk = sk.useBoost and self.car.boost > 5
	local jumpReach = if sk.jumpShots then jumpApex(true) + BALL_R * 0.6 else 150
	local maxZ = if sk.aerials then sk.maxAerialZ else jumpReach
	local n = #pred
	local best = nil
	for i = 6, n, 4 do
		local s = pred[i]
		local p = s.pos
		local t = (i - 1) / 120
		if p.Z <= maxZ and math.abs(p.Y) < 5100 then
			local aim = targetGoal + Vector3.new(self.aimOffset, 0, 0)
			local dir = unit(flat(aim - p), Vector3.new(0, 1, 0))
			local carTarget = p - dir * (BALL_R + 70)
			local to = flat(carTarget - pos)
			local d = to.Magnitude
			local ang = math.abs(signedAngle2D(fwd, to))
			local turnT = ang * 0.42
			local driveT = driveTime(d, speed, boostOk)
			if sk.maxSpeed < 2300 then
				driveT = math.max(driveT, d / sk.maxSpeed)
			end
			local total = turnT + driveT + sk.reachSlack
			if p.Z > jumpReach then
				-- aerial: rise time from the jump impulse (~845 uu/s from the measured jump) plus net boost
				-- acceleration against gravity; while rising the car also covers ground at its current speed
				local h = p.Z - 17
				local a = C.BOOST_ACCEL_AIR * 0.9 + C.GRAVITY_Z
				local rise = (-845 + math.sqrt(845 * 845 + 2 * a * (h + 60))) / a
				local groundD = math.max(0, d - math.max(speed, 600) * rise * 0.85)
				total = turnT + driveTime(groundD, speed, boostOk) + rise + sk.reachSlack
			end
			if total <= t then
				best = { t = t, ball = p, carTarget = carTarget, dir = dir, tick = i, height = p.Z }
				break
			end
		end
	end
	if not best and n > 0 then
		local s = pred[math.min(n, 240)]
		local dir = unit(flat(targetGoal - s.pos), Vector3.new(0, 1, 0))
		best = { t = math.min(n, 240) / 120, ball = s.pos, carTarget = s.pos - dir * (BALL_R + 70), dir = dir, tick = math.min(n, 240), height = s.pos.Z, late = true }
	end
	return best
end

-- Air orientation PD: point `fwdTarget`, keep `upTarget`; returns pitch, yaw, roll inputs
function BotAI._orient(self: any, fwdTarget: Vector3, upTarget: Vector3, gain: number?)
	local b = self.car.body
	local k = gain or 1
	-- rotation error (axis * ~angle) toward the target frame; up only matters around the forward axis
	local err = b.fwd:Cross(fwdTarget) + b.up:Cross(upTarget - fwdTarget * upTarget:Dot(fwdTarget)) * 0.35
	local w = b.angVel
	-- desired angular acceleration (critically-ish damped PD), then divide by each axis' authority
	local alpha = err * (38 * k) - w * (8.5 * math.sqrt(k))
	local pitch = math.clamp(alpha:Dot(-b.right) / (C.CAR_AIR_CONTROL_TORQUE.X * C.CAR_TORQUE_SCALE), -1, 1)
	local yaw = math.clamp(alpha:Dot(b.up) / (C.CAR_AIR_CONTROL_TORQUE.Y * C.CAR_TORQUE_SCALE), -1, 1)
	local roll = math.clamp(alpha:Dot(-b.fwd) / (C.CAR_AIR_CONTROL_TORQUE.Z * C.CAR_TORQUE_SCALE), -1, 1)
	return pitch, yaw, roll
end

local function blank()
	return { throttle = 0, steer = 0, pitch = 0, yaw = 0, roll = 0, jump = false, boost = false, handbrake = false }
end

-- Would an aerial started now reach `target` in T seconds? Returns the required average acceleration (uu/s^2).
-- Accounts for gravity and the upward velocity a jump + double jump adds (measured jump table).
function BotAI._aerialAccel(self: any, target: Vector3, T: number): number
	local pos, vel = self:_state()
	local g = Vector3.new(0, 0, C.GRAVITY_Z)
	local jumpLift = Vector3.new(0, 0, math.min(T, 0.25) * 0 + (2 * C.JUMP_IMMEDIATE_FORCE + C.JUMP_ACCEL * 0.18) * T - 60)
	local delta = target - (pos + vel * T + g * (0.5 * T * T) + jumpLift)
	return 2 * delta.Magnitude / (T * T)
end

-- Queue a flip toward a world direction (jump, release, second jump with stick)
function BotAI._queueFlip(self: any, dirWorld: Vector3)
	local b = self.car.body
	local f = flat(b.fwd).Unit
	local r = Vector3.new(-f.Y, f.X, 0)
	local d = unit(flat(dirWorld), f)
	local fx, fy = d:Dot(f), d:Dot(r)
	self.actions = {
		{ ticks = 6, c = { jump = true } },
		{ ticks = 2, c = { jump = false } },
		{ ticks = 3, c = { jump = true, pitch = -fx, yaw = fy } },
		{ ticks = 40, c = { pitch = -fx * 0.3, yaw = fy * 0.3 } },
	}
end

function BotAI._drive(self: any, c: any, target: Vector3, arriveIn: number?, allowBoost: boolean)
	local sk = self.skill
	local pos, vel, fwd = self:_state()
	local to = flat(target - pos)
	local d = to.Magnitude
	local ang = signedAngle2D(flat(fwd), to)
	local speed = vel:Dot(fwd)
	c.steer = math.clamp(ang * sk.steerGain, -1, 1)
	local desired = sk.maxSpeed
	if arriveIn and arriveIn > 0.05 then
		desired = math.min(sk.maxSpeed, d / arriveIn * 1.05)
	end
	if math.abs(ang) > 1.2 then
		desired = math.min(desired, 900)
	end
	if speed < desired - 60 then
		c.throttle = 1
		if allowBoost and sk.useBoost and desired > 1400 and math.abs(ang) < 0.35 and self.car.isOnGround then
			c.boost = true
		end
	elseif speed > desired + 200 then
		c.throttle = -0.4
	else
		c.throttle = 0.15
	end
	-- powerslide into sharp turns at speed
	if math.abs(ang) > 1.7 and speed > 700 and self.car.isOnGround then
		c.handbrake = true
	end
	return d, ang
end

function BotAI.Tick(self: any, dt: number, ctx: any)
	local car = self.car
	local sk = self.skill
	local c = blank()
	if car.isDemoed then
		car.controls = c
		return
	end
	local pos, vel, fwd, right, up = self:_state()
	local ball = self.world.ball.body
	local ballPos = ball.pos * BT
	local ballVel = ball.vel * BT
	local targetGoal, ownGoal = self:_goals()

	-- queued jump/dodge actions take priority
	if #self.actions > 0 then
		local a = self.actions[1]
		for k, v in a.c do
			c[k] = v
		end
		a.ticks -= 1
		if a.ticks <= 0 then
			table.remove(self.actions, 1)
		end
		if not car.isOnGround and a.c.pitch == nil and a.c.yaw == nil and a.c.jump ~= true then
			local p, y, r = self:_orient(unit(flat(vel), fwd), Vector3.zAxis)
			c.pitch, c.yaw, c.roll = p, y, r
		end
		car.controls = c
		return
	end

	-- kickoff
	local isKickoff = ballVel.Magnitude < 1 and flat(ballPos).Magnitude < 5 and ballPos.Z < 100
	if isKickoff then
		local goesForBall = ctx.kickoffTaker[car.team] == car
		if goesForBall then
			local d = self:_drive(c, Vector3.new(0, 0, 0) - unit(flat(-pos), Vector3.yAxis) * 0, nil, sk.kickoffBoost)
			c.boost = sk.kickoffBoost and c.steer < 0.5 and car.isOnGround
			if not sk.kickoffBoost then
				c.throttle = 1
			end
			if sk.kickoffFlip and d < 520 and car.isOnGround then
				self:_queueFlip(flat(-pos))
			end
		else
			-- second man: take the back position facing the ball
			self:_drive(c, Vector3.new(0, ownGoal.Y * 0.8, 0), 1.5, false)
		end
		car.controls = c
		return
	end

	-- (re)plan
	self.planAge += dt
	if not self.plan or self.planAge >= sk.reaction then
		self.planAge = 0
		self.aimOffset = self.rng:NextNumber(-1, 1) * sk.aimError
		self.plan = self:_findIntercept(ctx.pred)
		self.planStart = ctx.time
	end
	local plan = self.plan
	local remaining = if plan then plan.t - (ctx.time - self.planStart) else 1

	-- role
	local role = "attack"
	if ctx.attacker[car.team] ~= car then
		role = "support"
	end
	if role == "attack" and sk.rotate then
		-- not goal-side of the ball and ball rolling at our net: rotate back first
		local sideSign = if car.team == 0 then 1 else -1
		local behind = (ballPos.Y - pos.Y) * sideSign
		if behind < -400 and ballVel.Y * sideSign < -300 then
			role = "retreat"
		end
	end

	-- AERIAL in progress
	if self.aerial then
		local ae = self.aerial
		ae.time += dt
		local T = math.max(ae.hitTime - ae.time, 0.02)
		local g = Vector3.new(0, 0, C.GRAVITY_Z)
		local target = ae.target
		local delta = target - pos - vel * T - g * (0.5 * T * T)
		local dir = unit(delta, fwd)
		local p, y, r = self:_orient(dir, Vector3.zAxis, 1.1)
		c.pitch, c.yaw, c.roll = p, y, r
		if sk.flair and fwd:Dot(dir) > 0.9 then
			c.roll = 1 -- freestyler air-roll spin while lined up
		end
		local needAcc = 2 * delta.Magnitude / (T * T)
		c.boost = fwd:Dot(dir) > 0.75 and needAcc > 220 and car.boost > 0
		c.jump = ae.time < 0.18 or (ae.time > 0.22 and ae.time < 0.25)
		if ae.time > 0.2 and ae.time < 0.26 then
			c.pitch, c.yaw, c.roll = 0, 0, 0 -- a stick input here would turn the double jump into a dodge
		end
		local dBall = (ballPos - pos).Magnitude
		if car.isOnGround and ae.time > 0.4 or ae.time > ae.hitTime + 0.5 or car.boost <= 0 and T > 1.2 then
			self.aerial = nil
		elseif dBall < 190 and sk.flipHit >= 1 and car.hasJumped and not car.hasFlipped and not car.hasDoubleJumped then
			self.aerial = nil
			self.actions = { { ticks = 2, c = { jump = false } }, { ticks = 3, c = { jump = true, pitch = -1 } } }
		end
		car.controls = c
		return
	end

	-- AIRBORNE recovery (not aerialing)
	if not car.isOnGround and car.numWheelsInContact == 0 then
		local p, y, r = self:_orient(unit(flat(vel), unit(flat(fwd), Vector3.yAxis)), Vector3.zAxis, sk.recover)
		c.pitch, c.yaw, c.roll = p, y, r
		c.throttle = 1
		car.controls = c
		return
	end

	if role == "support" or role == "retreat" then
		-- sit between ball and own net; grab big boost when low
		local sideSign = if car.team == 0 then 1 else -1
		local spot = Vector3.new(ballPos.X * 0.45, math.clamp(ballPos.Y - sideSign * 2400, -4700, 4700), 0)
		if role == "retreat" then
			spot = Vector3.new(math.sign(ballPos.X) * -600, ownGoal.Y + sideSign * 400, 0)
		elseif car.boost < 30 and sk.useBoost then
			local bestPad, bestD = nil, math.huge
			for _, pad in self.world.pads do
				if pad.isBig and pad.isActive and pad.pos.Y * sideSign < 1000 then
					local dd = (flat(pad.pos) - flat(pos)).Magnitude
					if dd < bestD then bestPad, bestD = pad, dd end
				end
			end
			if bestPad then
				spot = Vector3.new(bestPad.pos.X, bestPad.pos.Y, 0)
			end
		end
		local d = self:_drive(c, spot, nil, role == "retreat")
		if d < 250 and role == "support" then
			-- face the ball while waiting
			c.throttle = 0
			local ang = signedAngle2D(flat(fwd), flat(ballPos - pos))
			if math.abs(ang) > 0.4 then
				c.throttle = 0.4
				c.steer = math.sign(ang)
			end
		end
		car.controls = c
		return
	end

	-- ATTACK
	if not plan then
		car.controls = c
		return
	end
	local jumpReach = jumpApex(true) + BALL_R * 0.6
	local z = plan.height
	local approach = plan.carTarget
	-- curve around the ball when badly aligned with the shot: aim for a point further behind it
	local toBallCar = flat(plan.ball - pos)
	local misalign = 1 - math.clamp(unit(toBallCar):Dot(plan.dir), -1, 1)
	if toBallCar.Magnitude > 900 and misalign > 0.35 then
		approach = plan.ball - plan.dir * (BALL_R + 70 + 500 * math.min(misalign, 1))
	end
	local d, ang = self:_drive(c, approach, remaining, true)

	-- aerial trigger: take off as late as the boost can still make it (RLBot criterion)
	local aerialMinZ = if sk.preferAerial then 260 else jumpReach - 40
	if sk.aerials and z > aerialMinZ and z <= sk.maxAerialZ and car.isOnGround and math.abs(ang) < 0.35 and car.boost > 20 then
		local target = plan.ball - plan.dir * (BALL_R * 0.9)
		local need = self:_aerialAccel(target, math.max(remaining, 0.1))
		if need < C.BOOST_ACCEL_AIR * 0.85 and need > C.BOOST_ACCEL_AIR * 0.45 then
			self.aerial = { time = 0, hitTime = remaining, target = target }
			c.jump = true
		else
			-- wait under the ball: aim the drive at the point below it
			self:_drive(c, flat(target) - plan.dir * 120, remaining + 0.25, true)
		end
	elseif sk.jumpShots and z > 170 and z <= jumpReach and car.isOnGround and math.abs(ang) < 0.3 then
		local double = z > jumpApex(false) + BALL_R * 0.5
		local jt = jumpTimeFor(z - BALL_R * 0.5 - 17, double)
		if jt and remaining <= jt + 0.02 then
			if double then
				self.actions = { { ticks = 24, c = { jump = true } }, { ticks = 2, c = { jump = false } }, { ticks = 2, c = { jump = true } } }
			else
				self.actions = { { ticks = 24, c = { jump = true } } }
			end
		end
	elseif z <= 170 and car.isOnGround then
		-- ground ball: dodge into it
		local dBall = flat(plan.ball - pos).Magnitude
		local speed = flat(vel).Magnitude
		if dBall < 280 + speed * 0.12 and remaining < 0.3 and math.abs(ang) < 0.5 and self.rng:NextNumber() < sk.flipHit * 0.2 then
			self:_queueFlip(flat(plan.ball - pos) + plan.dir * 60)
		end
	end
	car.controls = c
end

-- Shared per-tick context for all bots (prediction, roles, kickoff takers)
function BotAI.BuildContext(world: any, prediction: any, time: number)
	local ctx = { pred = prediction.predData, time = time, attacker = {}, kickoffTaker = {} }
	local ballPos = world.ball.body.pos * BT
	for team = 0, 1 do
		local bestCar, bestScore = nil, math.huge
		local closest, closestD = nil, math.huge
		for _, car in world.cars do
			if car.team == team and not car.isDemoed then
				local p = car.body.pos * BT
				local d = (flat(ballPos) - flat(p)).Magnitude
				-- prefer players that are goal-side (between ball and own net)
				local sideSign = if team == 0 then 1 else -1
				local goalSide = (ballPos.Y - p.Y) * sideSign > 0
				local score = d + (if goalSide then 0 else 1500)
				if score < bestScore then bestCar, bestScore = car, score end
				if d < closestD then closest, closestD = car, d end
			end
		end
		ctx.attacker[team] = bestCar
		ctx.kickoffTaker[team] = closest
	end
	return ctx
end

return BotAI
